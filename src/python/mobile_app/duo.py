"""The angel and the devil: one language model writes both characters' lines, SpellSpeak Audience directs.

Each of the human's turns gets a short exchange (docs/architecture.md, "The angel and the devil"). Audience reads
who each line is for, which picks who speaks next; each line is written in its speaker's view of the conversation
while the one before it plays. The host hears who each line is for (`addressed`) and which lines nobody will say
(`dropped`); only an exchange that cannot begin is reported as an error.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Any

from contracts.schemas.addressee import PLAYER, AddresseeAnswer
from contracts.schemas.person_card import PersonCard
from harness.addressee.rules import is_opener, is_simple
from loguru import logger
from pipecat.frames.frames import Frame
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.frame_processor import FrameDirection
from pipecat_apple.frames import AppleInputFrame
from pipecat_apple.llm import AppleFoundationLLMService

from mobile_app.audience import FLOOR, Audience, Line, addressees, normalize
from mobile_app.prompts import NAMES, line_instructions, other


@dataclass(frozen=True)
class Character:
    """A character: their Phonon voice and what the others can see of them."""

    id: str
    voice: str
    card: PersonCard


def _card(cid: str, appearance: str) -> PersonCard:
    # Plain words: Audience's word matcher reads "should" as a match for "shoulder".
    return PersonCard.model_validate(
        {
            "id": cid,
            "label": NAMES[cid],
            "features": [{"key": "role", "value": cid}, {"key": "appearance", "value": appearance}],
        }
    )


CAST = {
    "angel": Character(
        "angel", "Angel_F01", _card("angel", "white robe, feathered wings and a golden halo")
    ),
    "devil": Character(
        "devil", "Devil_01", _card("devil", "red skin, little horns and a pointy tail")
    ),
}
PLAYER_CARD = PersonCard(id=PLAYER, label="the human")

MAX_LINES = 6  # the most lines one exchange has
DEBATE_LINES = 4  # after this many, whoever still owes the human a verdict gives it
HISTORY_LINES = 32  # the most of the conversation a character is shown
MAX_PROMPT = 1900  # the native model reads at most 2,000 characters of prompt
HEARD_TIMEOUT_S = 60.0  # a line not acknowledged by then no longer holds up the next
DECLINED = "[LLM_DECLINED]"  # the category the host gives a line the model declines to write

NOTES = {
    "opening": "The human asked you both. It's your turn: answer first, in your own way.",
    "addressed": "The human asked you. It's your turn: answer them in your own way.",
    "reply": "The {other} has answered. It's your turn: make your own case in one or two short "
    "sentences, and answer the {other} directly if you disagree.",
    "rebuttal": "The {other} just spoke to you. It's your turn: answer the {other} in one or two "
    "short sentences, with the human listening.",
    "verdict": "The exchange is ending. It's your turn: give the human your final advice in one "
    "short sentence, and ask nothing new.",
    "greeting": "It's your turn: answer the human in a few friendly words, in your own way.",
    "who_me": "The human said that to one of you, but it isn't clear who. It's your turn: react in "
    'a few words, starting with "Who, me?"',
}


@dataclass
class Take:
    """One line for a character to say, and the note that tells them what the moment needs."""

    speaker: str
    kind: str

    def note(self) -> str:
        return NOTES[self.kind].format(other=NAMES[other(self.speaker)])


@dataclass(frozen=True)
class Said:
    """A line of the exchange: its take, and whether Audience read it as aimed at the other character."""

    take: Take
    aimed_at_other: bool


@dataclass
class Exchange:
    """Who speaks in one of the human's turns, in what order, and when the floor goes back."""

    question: str
    reading: AddresseeAnswer
    tie_opener: str = "angel"
    max_lines: int = MAX_LINES
    queue: list[Take] = field(default_factory=list)
    tied: bool = False  # the reading favoured neither character, so `tie_opener` went first
    said: list[Said] = field(default_factory=list)
    declined: set[str] = field(default_factory=set)  # characters whose opening the model declined

    def first(self) -> Take:
        """The opening take."""
        a = self.reading
        order = sorted(a.addressed, key=lambda c: (-round(a.addressed[c], 2), c != self.tie_opener))
        self.tied = round(a.addressed[order[0]], 2) == round(a.addressed[order[1]], 2)
        alone = (
            a.unclear < FLOOR
            and a.to_group < FLOOR
            and a.addressed[order[0]] >= FLOOR
            and a.addressed[order[1]] < FLOOR
        )
        question = self.question.rstrip().endswith("?")
        if a.unclear >= FLOOR and not question:
            self.queue = [Take(c, "who_me") for c in order]
        elif is_opener(self.question) or (is_simple(self.question) and not question):
            self.queue = [Take(c, "greeting") for c in order]
        else:
            return Take(order[0], "addressed" if alone else "opening")
        return self.queue.pop(0)

    def after(self, take: Take, aimed_at_other: bool) -> Take | None:
        """The next take after `take`'s line, or None when the floor goes back to the human."""
        self.said.append(Said(take, aimed_at_other))
        if len(self.said) >= self.max_lines:
            return None
        if take.kind in ("who_me", "greeting"):
            return self.queue.pop(0) if self.queue else None
        speaker, listener = take.speaker, other(take.speaker)
        if not any(said.take.speaker == listener for said in self.said):
            return Take(listener, "reply")
        if take.kind != "verdict" and aimed_at_other and len(self.said) < DEBATE_LINES:
            return Take(listener, "rebuttal")
        for character in (listener, speaker):
            if self._owes_verdict(character):
                return Take(character, "verdict")
        return None

    def instead(self, take: Take) -> Take | None:
        """The take in place of a declined opening: the other character's, or None once both
        have declined or a line has been said."""
        self.declined.add(take.speaker)
        if self.said:
            return None
        if self.queue:
            return self.queue.pop(0)
        stand_in = other(take.speaker)
        return None if stand_in in self.declined else Take(stand_in, "opening")

    def _owes_verdict(self, character: str) -> bool:
        """Whether a character's last word went to the other character, not the human."""
        last = next((said for said in reversed(self.said) if said.take.speaker == character), None)
        return last is not None and last.take.kind != "verdict" and last.aimed_at_other


class Room:
    """The conversation as everyone heard it, from which each character's view is drawn."""

    def __init__(self) -> None:
        self.lines: list[Line] = []
        self._changed = asyncio.Condition()

    def add(self, line: Line) -> Line:
        self.lines.append(line)
        del self.lines[:-HISTORY_LINES]
        # Whole exchanges only: everyone's view starts with a line of the human's.
        while len(self.lines) > 1 and self.lines[0].speaker != PLAYER:
            del self.lines[0]
        return line

    def forget_unheard(self) -> None:
        """Drop lines that were written but never played: nobody will hear them now."""
        self.lines = [line for line in self.lines if line.heard]

    async def heard(self, content: str, interrupted: bool) -> None:
        """Record the oldest unplayed line as played as `content`, or cut short at it. Lines after
        a cut one, and a line of which nothing played, are dropped."""
        async with self._changed:
            line = next((line for line in self.lines if not line.heard), None)
            if line is not None:
                line.heard, line.cut, line.text = True, interrupted, normalize(content)
                if interrupted:
                    self.forget_unheard()
                if not line.text:
                    self.lines.remove(line)
            self._changed.notify_all()

    async def wait_heard(self, line: Line) -> None:
        """Wait until `line` has been played (or dropped), for at most HEARD_TIMEOUT_S."""
        async with self._changed:
            try:
                await asyncio.wait_for(
                    self._changed.wait_for(lambda: line.heard or line not in self.lines),
                    HEARD_TIMEOUT_S,
                )
            except TimeoutError:
                logger.warning("Duo: a line was never acknowledged as played; continuing")

    def view(self, me: str, note: str | None = None) -> list[dict[str, Any]]:
        """`me`'s view: their own lines as theirs, everyone else's tagged with a name, then the note.

        Args:
            me: Whose view.
            note: What the moment needs, as a note after the last line.
        """
        messages: list[dict[str, Any]] = []

        def say(role: str, text: str) -> None:
            if messages and messages[-1]["role"] == role:
                messages[-1]["content"] += "\n" + text
            else:
                messages.append({"role": role, "content": text})

        for line in self.lines:
            if not line.text:
                continue
            if line.speaker == me:
                say("assistant", line.text + ("…" if line.cut else ""))
            else:
                name = "Human" if line.speaker == PLAYER else NAMES[line.speaker]
                say("user", f"[{name}] {line.text}" + (" (cut off)" if line.cut else ""))
        if messages and messages[0]["role"] == "assistant":
            messages.insert(0, {"role": "user", "content": "[Note: The human joins you.]"})
        if note is not None:
            say("user", f"[Note: {note}]")
            prompt = messages[-1]["content"]
            if len(prompt) > MAX_PROMPT:
                messages[-1]["content"] = "…" + prompt[-(MAX_PROMPT - 1) :]
        return messages


class DuoLLMService(AppleFoundationLLMService):
    """The angel and the devil on the on-device language model, with Audience directing the turns.

    The service's system instruction holds the session's notes, added to each character's instructions.
    """

    def __init__(self, bridge, *, max_lines: int = MAX_LINES, **kwargs: Any) -> None:
        """Initialize the duo.

        Args:
            bridge: Native request bridge.
            max_lines: The most lines one exchange has.
            **kwargs: AppleFoundationLLMService configuration.
        """
        super().__init__(bridge, **kwargs)
        self.max_lines = max_lines
        self.audience = Audience(bridge, {c.id: c.card for c in CAST.values()}, PLAYER_CARD)
        self.room = Room()
        self._tie_opener = "angel"
        self._responding = False
        self._session: str | None = None

    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        """Forget the conversation when the human clears it, then process as usual."""
        if isinstance(frame, AppleInputFrame) and frame.event.get("type") == "reset_context":
            self._forget()
        await super().process_frame(frame, direction)

    def _forget(self) -> None:
        self.room = Room()
        self._tie_opener = "angel"

    def _follow_session(self) -> None:
        """Each session is a new conversation: nothing said in an earlier one carries over."""
        if self.bridge.session != self._session:
            self._session = self.bridge.session
            self._forget()

    def prepare_context(self, context: LLMContext) -> None:
        """Prewarm the likely next opener with the conversation up to their last line, which is
        the next request's history."""
        self._follow_session()
        if self._responding or any(not line.heard for line in self.room.lines):
            return
        opener = self._tie_opener
        history = self.room.view(opener)
        while history and history[-1]["role"] == "user":
            history.pop()
        self.prewarm(LLMContext(messages=history), self.instructions(opener))

    async def heard(self, content: str, interrupted: bool) -> None:
        """Record a line as the assistant aggregator heard it played, then prewarm if all are."""
        await self.room.heard(content, interrupted)
        if self.bridge.context is not None:
            self.prepare_context(self.bridge.context)

    def instructions(self, character: str) -> str:
        """A character's instructions for their next line, with the session's notes."""
        return line_instructions(character, self.system_instruction or "")

    def _tell(self, event: dict[str, Any]) -> None:
        """Send the host an event about the current turn, unless the turn has moved on."""
        if self.bridge.turn == event["turn"] and self.bridge.active:
            self.bridge.emit({**event, "session": self.bridge.session})

    def _addressed(self, turn: str, to: list[str], line: int | None = None) -> None:
        """Tell the host who a line of the turn is for (the human's when `line` is None)."""
        self._tell({"type": "addressed", "turn": turn, "line": line, "to": to})

    async def respond(self, context: LLMContext, turn: str) -> None:
        """Answer the human's line with an exchange between the angel and the devil.

        Args:
            context: The user turn's context; its last message is the human's line.
            turn: The native turn the exchange belongs to.
        """
        messages = context.messages
        text = messages[-1].get("content") if messages else None
        if not isinstance(text, str) or not text.strip():
            return
        self._responding = True
        try:
            ended_early = await self._exchange(turn, text)
        finally:
            self._responding = False
        if ended_early and self.bridge.turn == turn and self.bridge.active:
            # The lines written before the one that failed have played: the floor is the human's.
            self._tell({"type": "state", "state": "listening", "turn": turn})
            self.prepare_context(context)

    async def _exchange(self, turn: str, text: str) -> bool:
        """Play an exchange in answer to the human's `text`.

        Returns:
            True when a line after the first failed and the lines before it have played, so the
            exchange ended early; False otherwise.
        """
        self._follow_session()
        self.room.forget_unheard()
        # The human said it whatever happens next, so it joins the conversation at once.
        said = self.room.add(Line(PLAYER, normalize(text)))
        reading = await self.audience.read(PLAYER, text, self.room.lines[:-1], turn)
        if self.bridge.turn != turn or not self.bridge.active:
            return False
        said.to = addressees(reading)
        exchange = Exchange(
            normalize(text), reading, tie_opener=self._tie_opener, max_lines=self.max_lines
        )
        take: Take | None = exchange.first()
        # A line the characters tie for is for both, however close Audience's likeliest came.
        self._addressed(turn, list(CAST) if exchange.tied and len(said.to) == 1 else said.to)
        if exchange.tied:
            self._tie_opener = other(self._tie_opener)
        written: list[Line] = []
        number = 0
        while take is not None:
            if len(written) >= 2:
                # One line ahead of the one playing, so little is thrown away when the human cuts in.
                await self.room.wait_heard(written[-2])
                if self.bridge.turn != turn:
                    return False
            try:
                said = await self._say(take, number, exchange, turn)
            except Exception as exc:
                if self.bridge.turn != turn or not self.bridge.active:
                    return False
                if written:
                    # A later line failed: nobody will say it, and the lines already written play out.
                    logger.warning(f"Duo: the {take.speaker}'s line {number} failed: {exc}")
                    self._tell({"type": "dropped", "turn": turn, "line": number})
                    await self.room.wait_heard(written[-1])
                    return self.bridge.turn == turn
                # The model declined the opening: the other character answers instead.
                stand_in = exchange.instead(take) if DECLINED in str(exc) else None
                if stand_in is None:
                    await self.push_response_error(exc, turn)
                    return False
                logger.warning(f"Duo: the {take.speaker}'s opening was declined: {exc}")
                take = stand_in
                continue
            if said is None:
                return False
            line, take = said
            written.append(line)
            number += 1
        return False

    async def _say(
        self, take: Take, number: int, exchange: Exchange, turn: str
    ) -> tuple[Line, Take | None] | None:
        """Write and speak one line; Audience's reading of it picks the next take.

        Returns:
            The line and the take after it (None when the floor goes back to the human), or None
            when the turn moved on.

        Raises:
            Exception: The model's failure to write the line, for the exchange to handle.
        """
        said: tuple[Line, Take | None] | None = None
        view = LLMContext(messages=self.room.view(take.speaker, take.note()))
        before = list(self.room.lines)
        # The line joins the room as it starts, so each response the pipeline closes, said or not,
        # is heard as one line in order.
        line = self.room.add(Line(take.speaker, "", heard=False))

        async def finish(spoken: str) -> dict[str, Any]:
            nonlocal said
            read = await self.audience.read(take.speaker, spoken, before, turn)
            line.text, line.to = normalize(spoken), addressees(read)
            self._addressed(turn, line.to, line=number)
            following = exchange.after(take, line.to == [other(take.speaker)])
            said = (line, following)
            return {"continues": following is not None}

        spoken = await self.generate(
            view,
            turn,
            instructions=self.instructions(take.speaker),
            metadata={"speaker": take.speaker, "voice": CAST[take.speaker].voice, "line": number},
            finish=finish,
            report_errors=False,
        )
        return said if spoken is not None else None

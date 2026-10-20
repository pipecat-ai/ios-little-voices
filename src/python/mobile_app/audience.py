"""Pipecat Audience in the conversation: who each line is for.

Requests are built with Audience's reference runtime (`pipecat_audience`) from the line, who said it, the
cards of everyone present and the recent lines; the host scores them on Core ML (the `audience` operation). When
the host can't answer, the runtime's rules baseline does.
"""

from __future__ import annotations

import unicodedata
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from contracts.schemas.addressee import (
    MAX_HISTORY,
    PLAYER,
    AddresseeAnswer,
    AddresseeRequest,
    HistoryLine,
)
from contracts.schemas.person_card import PersonCard, SpatialFacts
from harness.addressee.features import card_only, line_features, line_input, person_features
from harness.addressee.rules import rules_answer
from loguru import logger

if TYPE_CHECKING:
    from pipecat_apple.bridge import AppleNativeBridge

MAX_TEXT = 400  # the longest line the model reads
FLOOR = 0.5  # a probability this high reads as yes: addressed, unclear, or for the group


def normalize(text: str) -> str:
    """A line as the conversation keeps it: NFC, whitespace collapsed."""
    return " ".join(unicodedata.normalize("NFC", text).split())


def clean(text: str) -> str:
    """A line as the model reads it: normalized, at most 400 characters."""
    return normalize(text)[:MAX_TEXT]


@dataclass
class Line:
    """A line of the conversation.

    Parameters:
        speaker: ``player``, or a character's id.
        text: What was said; for a line cut short, as far as it was heard.
        to: Who Audience read it was for: one id, several, or none when unclear.
        heard: False while a character's line waits to be played.
        cut: The line was interrupted.
    """

    speaker: str
    text: str
    to: list[str] = field(default_factory=list)
    heard: bool = True
    cut: bool = False


def addressees(answer: AddresseeAnswer) -> list[str]:
    """Who a reading says the line was for: everyone for a group line, nobody when it is unclear,
    otherwise the likeliest person."""
    if answer.unclear >= FLOOR:
        return []
    if answer.to_group >= FLOOR:
        return list(answer.addressed)
    return [answer.top()]


class Audience:
    """Ask the native host who a line is for."""

    def __init__(
        self, bridge: AppleNativeBridge, cards: dict[str, PersonCard], player: PersonCard
    ) -> None:
        """Initialize Audience.

        Args:
            bridge: Native request bridge.
            cards: Each character's card, by id.
            player: The human's card, read when a character speaks.
        """
        self.bridge = bridge
        self.cards = cards
        self.player = player.model_copy(update={"id": PLAYER})

    def request(self, speaker: str, text: str, history: Sequence[Line]) -> AddresseeRequest:
        """The model's input for `text`, said by `speaker` after `history`.

        Everyone shares the human's shoulders, so the people are all near and in the conversation.
        The facts say who the speaker spoke with last, and who just asked the speaker something.
        """
        said = [line for line in history if line.text][-MAX_HISTORY:]
        everyone = [PLAYER, *self.cards]
        present = [pid for pid in everyone if pid != speaker]
        mine = next((line for line in reversed(history) if line.speaker == speaker), None)
        partner = mine.to[0] if mine is not None and len(mine.to) == 1 else None
        latest = said[-1] if said else None
        cards = []
        for pid in present:
            asked = (
                latest is not None
                and latest.speaker == pid
                and (speaker in latest.to or not latest.to)
                and latest.text.rstrip().endswith("?")
            )
            facts = SpatialFacts(
                distance="near",
                in_group=True,
                last_spoke_with_you=None if partner is None else pid == partner,
                asked_you=asked,
            )
            card = self.player if pid == PLAYER else self.cards[pid]
            cards.append(card.model_copy(update={"spatial": facts}))
        known = set(everyone)
        return AddresseeRequest(
            speaker=speaker,
            speaker_label=None if speaker == PLAYER else self.cards[speaker].label,
            text=clean(text) or "...",
            present=cards,
            history=[
                HistoryLine(
                    speaker=line.speaker,
                    to=[t for t in line.to if t != line.speaker and t in known],
                    text=clean(line.text) or "...",
                )
                for line in said
            ],
        )

    async def read(
        self, speaker: str, text: str, history: Sequence[Line], turn: str
    ) -> AddresseeAnswer:
        """Who `text`, said by `speaker` after `history`, is for."""
        request = self.request(speaker, text, history)
        line, current = line_input(request)
        payload = {
            "cards": [card_only(card) for card in request.present],
            "utterance": line,
            "current": current,
            "people": person_features(request),
            "features": line_features(request),
        }
        try:
            value = None
            async for event in self.bridge.stream("audience", turn, **payload):
                value = event.get("value", value)
            if not isinstance(value, dict):
                raise RuntimeError("Audience returned no answer")
            return AddresseeAnswer(
                addressed=dict(zip(request.ids, value["person"], strict=True)),
                unclear=value["unclear"],
                to_group=value["group"],
            )
        except Exception as exc:  # The rules baseline reads the line instead.
            if self.bridge.turn != turn:
                raise
            logger.warning(f"Audience: the model didn't answer ({exc}); using the rules baseline")
            return rules_answer(request)

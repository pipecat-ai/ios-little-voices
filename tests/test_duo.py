"""The angel and the devil: SpellSpeak Audience's requests, the director, and a debate end to end."""

import hashlib

import pytest
import spellspeak_audience
from contracts.schemas.addressee import AddresseeAnswer
from mobile_app.audience import Audience, Line, addressees
from mobile_app.duo import CAST, DEBATE_LINES, MAX_LINES, PLAYER_CARD, Exchange, Room, Take
from support import audience_answer, human, reply, respond, rtvi_type, session


def answer(angel=0.0, devil=0.0, *, unclear=0.0, group=0.0, player=None):
    addressed = {"angel": angel, "devil": devil} if player is None else {"player": player}
    if player is not None:
        addressed[{0: "angel", 1: "devil"}[int(angel == 0)]] = max(angel, devil)
    return AddresseeAnswer(addressed=addressed, unclear=unclear, to_group=group)


def test_vendored_runtime_is_the_release_byte_for_byte():
    for name, digest in spellspeak_audience.RUNTIME_SHA256.items():
        data = (spellspeak_audience.RUNTIME / name).read_bytes()
        assert hashlib.sha256(data).hexdigest() == digest, name


def test_a_question_for_both_is_debated_and_ends_with_verdicts():
    exchange = Exchange("Should I skip the gym today?", answer(0.9, 0.9, group=0.9))
    take = exchange.first()
    assert (take.speaker, take.kind) == ("angel", "opening") and exchange.tied
    take = exchange.after(take, aimed_at_other=False)
    assert (take.speaker, take.kind) == ("devil", "reply")
    take = exchange.after(take, aimed_at_other=True)  # "Oh, please, Angel..."
    assert (take.speaker, take.kind) == ("angel", "rebuttal")
    take = exchange.after(take, aimed_at_other=False)  # the angel turns to the human
    # The devil's last word went to the angel, so the devil owes the human a verdict.
    assert (take.speaker, take.kind) == ("devil", "verdict")
    assert exchange.after(take, aimed_at_other=False) is None


def test_a_debate_is_capped_then_each_still_turned_away_gives_a_verdict():
    exchange = Exchange("Is lying ever okay?", answer(0.9, 0.9, group=0.9))
    take = exchange.first()
    kinds = []
    while take is not None:
        kinds.append((take.speaker, take.kind))
        take = exchange.after(take, aimed_at_other=True)  # they only ever argue
    assert kinds[:DEBATE_LINES] == [
        ("angel", "opening"),
        ("devil", "reply"),
        ("angel", "rebuttal"),
        ("devil", "rebuttal"),
    ]
    assert kinds[DEBATE_LINES:] == [("angel", "verdict"), ("devil", "verdict")]
    assert len(kinds) == MAX_LINES


def test_who_opens_follows_who_was_asked_and_ties_alternate():
    devil = Exchange("Devil, tempt me.", answer(0.01, 0.99)).first()
    assert (devil.speaker, devil.kind) == ("devil", "addressed")
    tied = Exchange("What do you think?", answer(0.9, 0.9, group=0.9), tie_opener="devil")
    assert tied.first().speaker == "devil" and tied.tied
    likelier = Exchange("What do you think?", answer(0.6, 0.8))
    assert likelier.first().speaker == "devil" and not likelier.tied


def test_an_unclear_accusation_gets_a_who_me_from_each_and_greetings_a_line_each():
    exchange = Exchange("You lied to me.", answer(0.77, 0.79, unclear=0.99))
    first = exchange.first()
    assert (first.speaker, first.kind) == ("devil", "who_me")
    second = exchange.after(first, aimed_at_other=False)
    assert (second.speaker, second.kind) == ("angel", "who_me")
    assert exchange.after(second, aimed_at_other=False) is None
    assert 'starting with "Who, me?"' in second.note()
    hello = Exchange("Hello.", answer(0.98, 0.98, group=0.98))
    take = hello.first()
    assert take.kind == "greeting"
    assert hello.after(take, aimed_at_other=False).kind == "greeting"
    # An unclear question is still a question for them both to take on.
    question = Exchange("I found a wallet. What should I do?", answer(0.84, 0.84, unclear=0.95))
    assert question.first().kind == "opening"


def test_one_line_exchanges_stop_after_the_first_line():
    exchange = Exchange("Hello.", answer(0.98, 0.98, group=0.98), max_lines=1)
    assert exchange.after(exchange.first(), aimed_at_other=False) is None


def test_views_tag_others_merge_lines_and_end_with_the_note():
    room = Room()
    room.add(Line("player", "Should I skip the gym?", to=["angel", "devil"]))
    room.add(Line("angel", "Go, you'll feel great.", to=["player"]))
    room.add(Line("devil", "Angel, one lazy day never hurt.", to=["angel"], cut=True))
    note = Take("angel", "rebuttal").note()
    assert room.view("angel", note) == [
        {"role": "user", "content": "[Human] Should I skip the gym?"},
        {"role": "assistant", "content": "Go, you'll feel great."},
        {
            "role": "user",
            "content": "[Devil] Angel, one lazy day never hurt. (cut off)\n[Note: " + note + "]",
        },
    ]
    devil = room.view("devil", "Speak.")
    assert devil[0]["content"] == ("[Human] Should I skip the gym?\n[Angel] Go, you'll feel great.")
    assert devil[1] == {"role": "assistant", "content": "Angel, one lazy day never hurt.…"}


def test_rooms_keep_whole_exchanges_and_bound_the_prompt():
    room = Room()
    for number in range(40):
        room.add(Line("player", f"Question {number}"))
        room.add(Line("angel", f"Answer {number}"))
        room.add(Line("devil", f"Retort {number}"))
    assert room.lines[0].speaker == "player"
    assert len(room.lines) <= 32
    room.add(Line("player", "x" * 5000))
    prompt = room.view("angel", "Speak.")[-1]["content"]
    assert len(prompt) <= 1900 and prompt.endswith("[Note: Speak.]")


async def test_heard_lines_are_confirmed_cut_or_dropped_in_order():
    room = Room()
    room.add(Line("player", "Tell me a story"))
    first = room.add(Line("angel", "Once upon a time. There was a cat.", heard=False))
    second = room.add(Line("devil", "And it was MY cat.", heard=False))
    await room.heard("Once upon a time.", interrupted=True)
    assert first.heard and first.cut and first.text == "Once upon a time."
    # Nothing after an interruption is heard.
    assert second not in room.lines
    room.add(Line("player", "And then?"))
    silent = room.add(Line("devil", "Cut before a word.", heard=False))
    await room.heard("", interrupted=True)
    assert silent not in room.lines
    unheard = room.add(Line("angel", "Unplayed.", heard=False))
    room.forget_unheard()
    assert unheard not in room.lines


def test_audience_requests_carry_cards_history_and_conversation_facts():
    audience = Audience(None, {c.id: c.card for c in CAST.values()}, PLAYER_CARD)
    history = [
        Line("player", "Should I skip the gym?", to=["angel"]),
        Line("angel", "Go! Will you go?", to=["player"]),
    ]
    request = audience.request("player", "  I  don't   know.  ", history)
    assert request.text == "I don't know." and request.ids == ["angel", "devil"]
    facts = {card.id: card.spatial for card in request.present}
    assert facts["angel"].asked_you and facts["angel"].last_spoke_with_you
    assert not facts["devil"].asked_you and facts["devil"].last_spoke_with_you is False
    assert [line.to for line in request.history] == [["angel"], ["player"]]
    spoken = audience.request("devil", "Oh, please, Angel.", history)
    assert spoken.speaker_label == "Devil"
    assert spoken.ids == ["player", "angel"]
    assert addressees(
        AddresseeAnswer(addressed={"player": 0.9, "angel": 0.95}, unclear=0.1, to_group=0.0)
    ) == ["angel"]
    assert addressees(
        AddresseeAnswer(addressed={"angel": 0.9, "devil": 0.9}, unclear=0.0, to_group=0.9)
    ) == ["angel", "devil"]
    assert (
        addressees(
            AddresseeAnswer(addressed={"angel": 0.8, "devil": 0.8}, unclear=0.9, to_group=0.0)
        )
        == []
    )


async def test_audience_falls_back_to_the_rules_when_the_host_cannot_answer():
    async with session() as (bridge, host):
        bridge.turn = "a-turn"
        host.audience = None
        events = []

        class Failing:
            turn = "a-turn"

            async def stream(self, operation, turn, **payload):
                events.append((operation, payload))
                raise RuntimeError("no model")
                yield  # pragma: no cover

        audience = Audience(Failing(), {c.id: c.card for c in CAST.values()}, PLAYER_CARD)
        reading = await audience.read("player", "Angel, help me out.", [], "a-turn")
        assert events and events[0][0] == "audience"
        assert set(events[0][1]) == {"cards", "utterance", "current", "people", "features"}
        assert reading.top() == "angel" and reading.addressed["angel"] == 1.0


def both_unless_named(event):
    """The human's lines are for both of them unless they name one."""
    standing = audience_answer(event)
    if not any(card.startswith("the human") for card in event["cards"]):
        line = event["utterance"][: event["current"]]
        if "Angel" not in line and "Devil" not in line:
            return {"person": [0.9, 0.9], "unclear": 0.0, "group": 0.9}
    return standing


async def write(bridge, generation, text):
    """The native model writes a whole line."""
    await respond(bridge, generation, delta=text)
    await respond(bridge, generation, done=True)


async def next_request(host, operation, after):
    return await host.wait(lambda event: event.get("operation") == operation, after=after)


async def test_a_debate_plays_in_turn_in_each_voice_and_then_the_floor_is_the_humans():
    async with session(lines=MAX_LINES) as (bridge, host):
        host.audience = both_unless_named
        script = [
            "Go to the gym tonight.",
            "Oh, please, Angel, one lazy day never hurt anyone.",
            "Habits slip one day at a time, so go.",
            "Fine, go, and have a treat after.",
        ]
        generations = [await host.say(bridge, "Should I skip the gym today?")]
        marker = len(host.events)
        await write(bridge, generations[0], script[0])
        speeches = [await next_request(host, "speak", marker)]
        # The devil's line is written while the angel's plays.
        generations.append(await next_request(host, "generate", marker))
        for number in (1, 2, 3):
            await write(bridge, generations[number], script[number])
            marker = len(host.events)
            await host.play(bridge, speeches[-1])
            speeches.append(await next_request(host, "speak", marker))
            if number < 3:
                generations.append(await next_request(host, "generate", marker))
        assert [g["instructions"].split(":", 1)[0] for g in generations] == [
            "You are the Angel on the human's shoulder",
            "You are the Devil on the human's other shoulder",
            "You are the Angel on the human's shoulder",
            "You are the Devil on the human's other shoulder",
        ]
        assert "It's your turn: answer first" in generations[0]["prompt"]
        assert "make your own case" in generations[1]["prompt"]
        assert "The Devil just spoke to you" in generations[2]["prompt"]
        assert "final advice in one short sentence" in generations[3]["prompt"]
        assert [(s["speaker"], s["voice"], s["line"], s["text"]) for s in speeches] == [
            ("angel", "en_gb_Freya", 0, script[0]),
            ("devil", "en_gb_Reuben", 1, script[1]),
            ("angel", "en_gb_Freya", 2, script[2]),
            ("devil", "en_gb_Reuben", 3, script[3]),
        ]
        assert not any(event.get("state") == "listening" for event in host.events)
        marker = len(host.events)
        await host.play(bridge, speeches[-1])
        await host.wait(lambda event: event.get("state") == "listening", after=marker)
        assert not any(event.get("operation") == "generate" for event in host.events[marker:])
        texts = {
            (event.get("speaker"), event.get("line"))
            for event in host.events
            if rtvi_type(event) == "bot-llm-text"
        }
        assert texts == {("angel", 0), ("devil", 1), ("angel", 2), ("devil", 3)}
        # The host hears who each line is for: the human's question, then each line in turn.
        addressed = [event for event in host.events if event.get("type") == "addressed"]
        assert [(event["line"], event["to"]) for event in addressed] == [
            (None, ["angel", "devil"]),
            (0, ["player"]),
            (1, ["angel"]),
            (2, ["player"]),
            (3, ["player"]),
        ]
        assert {(event["turn"], event["session"]) for event in addressed} == {
            (generations[0]["turn"], host.session)
        }
        # The angel opened a tie, so the devil opens the next one, after its own verdict.
        later = await host.say(bridge, "Thanks, both of you.")
        assert later["instructions"].startswith("You are the Devil")
        assert later["history"][-1] == {"role": "assistant", "content": script[3]}


async def test_the_next_line_waits_until_the_one_before_the_last_is_heard():
    async with session(lines=MAX_LINES) as (bridge, host):
        host.audience = both_unless_named
        first = await host.say(bridge, "Should I skip the gym today?")
        marker = len(host.events)
        await write(bridge, first, "You will feel great after the gym.")
        speech = await next_request(host, "speak", marker)
        second = await next_request(host, "generate", marker)
        marker = len(host.events)
        await write(bridge, second, "Angel, one lazy day never hurt.")
        # The angel's line has not been heard, so the third line is not written yet.
        with pytest.raises(pytest.fail.Exception):
            await host.wait(
                lambda event: event.get("operation") == "generate", after=marker, timeout=0.3
            )
        await host.play(bridge, speech)
        third = await next_request(host, "generate", marker)
        assert "The Devil just spoke to you" in third["prompt"]


async def test_cutting_in_drops_unheard_lines_from_the_conversation():
    async with session(lines=MAX_LINES) as (bridge, host):
        host.audience = both_unless_named
        first = await host.say(bridge, "Should I skip the gym today?")
        marker = len(host.events)
        await write(bridge, first, "Go. You will feel great.")
        speech = await next_request(host, "speak", marker)
        second = await next_request(host, "generate", marker)
        await write(bridge, second, "Angel, one lazy day never hurt.")
        await host.playback(bridge, speech, speaking=True)
        following = await host.say(bridge, "Angel, are you sure?")
        # Nothing of the angel's reply was acknowledged and the devil's was never played.
        assert following["history"] == []
        assert following["prompt"].startswith(
            "[Human] Should I skip the gym today?\n[Human] Angel, are you sure?\n[Note: "
        )


async def test_a_new_conversation_forgets_the_room_and_who_opens_a_tie():
    async with session() as (bridge, host):
        host.audience = both_unless_named
        first = await host.say(bridge, "Should I skip the gym today?")
        assert first["instructions"].startswith("You are the Angel")
        await host.play(bridge, await reply(bridge, host, first, "Go to the gym tonight."))
        await host.wait(lambda event: event.get("state") == "listening")
        await bridge.receive({"type": "reset", "session": host.session})
        # The angel opened the last tie, but a new conversation starts again from the angel,
        # with nothing said before.
        again = await host.say(bridge, "Should I skip the gym today?")
        assert again["instructions"].startswith("You are the Angel")
        assert again["history"] == []
        assert human(again) == "Should I skip the gym today?"


async def test_a_later_line_that_fails_ends_the_exchange_once_the_lines_before_it_play():
    async with session(lines=MAX_LINES) as (bridge, host):
        host.audience = both_unless_named
        first = await host.say(bridge, "Should I skip the gym today?")
        marker = len(host.events)
        await write(bridge, first, "Go to the gym tonight. You will feel great.")
        speech = await next_request(host, "speak", marker)
        second = await next_request(host, "generate", marker)
        await respond(bridge, second, error="Apple's language model declined this request.")
        dropped = await host.wait(lambda event: event.get("type") == "dropped", after=marker)
        assert (dropped["turn"], dropped["session"], dropped["line"]) == (
            first["turn"],
            host.session,
            1,
        )
        # The angel's line plays out, and the host is not asked to show the devil's failure.
        played = len(host.events)
        await host.play(bridge, speech)
        rest = await next_request(host, "speak", played)
        assert rest["text"] == "You will feel great."
        played = len(host.events)
        await host.play(bridge, rest)
        await host.wait(
            lambda event: event.get("state") == "listening" and event.get("turn") == first["turn"],
            after=played,
        )
        assert not any(event.get("type") == "error" for event in host.events[marker:])
        assert any(event.get("type") == "prewarm" for event in host.events[played:])
        assert [line.speaker for line in bridge.llm.room.lines] == ["player", "angel"]
        later = await host.say(bridge, "Thanks, both of you.")
        # The devil opens this tie, and sees what the angel said.
        assert later["instructions"].startswith("You are the Devil")
        assert (
            "[Angel] Go to the gym tonight. You will feel great.\n[Human] Thanks" in later["prompt"]
        )


DECLINED_LINE = (
    "Apple's language model declined this request. Please try a different question. [LLM_DECLINED]"
)


def test_a_declined_opening_passes_to_the_other_character_once():
    exchange = Exchange("Can I keep the wallet I found?", answer(0.2, 0.9))
    declined = exchange.first()
    assert (declined.speaker, declined.kind) == ("devil", "addressed")
    stand_in = exchange.instead(declined)
    assert (stand_in.speaker, stand_in.kind) == ("angel", "opening")
    assert exchange.instead(stand_in) is None
    greetings = Exchange("Hello.", answer(0.98, 0.98, group=0.98))
    assert greetings.instead(greetings.first()).kind == "greeting"


async def test_a_declined_opening_is_answered_by_the_other_character_without_an_error():
    async with session(lines=1) as (bridge, host):
        host.audience = both_unless_named
        first = await host.say(bridge, "I found a wallet. Can I keep it?")
        assert first["instructions"].startswith("You are the Angel")
        marker = len(host.events)
        await respond(bridge, first, error=DECLINED_LINE)
        stand_in = await next_request(host, "generate", marker)
        assert stand_in["instructions"].startswith("You are the Devil")
        assert human(stand_in) == "I found a wallet. Can I keep it?"
        await host.play(
            bridge, await reply(bridge, host, stand_in, "Return it, then treat yourself.")
        )
        await host.wait(lambda event: event.get("state") == "listening", after=marker)
        assert not any(event.get("type") == "error" for event in host.events)
        assert [line.speaker for line in bridge.llm.room.lines] == ["player", "devil"]


async def test_an_exchange_that_cannot_begin_is_reported():
    async with session(lines=1) as (bridge, host):
        host.audience = both_unless_named
        first = await host.say(bridge, "I found a wallet. Can I keep it?")
        marker = len(host.events)
        await respond(bridge, first, error=DECLINED_LINE)
        stand_in = await next_request(host, "generate", marker)
        await respond(bridge, stand_in, error=DECLINED_LINE)
        error = await host.wait(lambda event: event.get("type") == "error", after=marker)
        assert error["operation"] == "generate" and error["recoverable"] is True
        assert "[LLM_DECLINED]" in error["message"]
        # Any other failure of the opening is reported at once.
        await bridge.receive({"type": "interrupt", "session": host.session})
        again = await host.say(bridge, "Okay, what should I do instead?")
        marker = len(host.events)
        await respond(bridge, again, error="Apple's language model took too long. [LLM_TIMEOUT]")
        error = await host.wait(lambda event: event.get("type") == "error", after=marker)
        assert "[LLM_TIMEOUT]" in error["message"]
        assert not [
            e
            for e in host.events[marker:]
            if e.get("type") == "request" and e["operation"] == "generate"
        ]


async def test_a_line_with_nothing_to_say_aloud_is_skipped_and_forgotten():
    async with session(lines=2) as (bridge, host):
        first = await host.say(bridge, "Hello!")
        marker = len(host.events)
        await write(bridge, first, "😇")
        second = await next_request(host, "generate", marker)
        await host.play(bridge, await reply(bridge, host, second, "Hello there."))
        await host.wait(lambda event: event.get("state") == "listening", after=marker)
        spoken = [event["text"] for event in host.events if event.get("operation") == "speak"]
        assert spoken == ["Hello there."]
        assert [line.speaker for line in bridge.llm.room.lines] == ["player", "devil"]
        assert not any(event.get("type") == "error" for event in host.events)


async def test_a_question_the_characters_tie_for_is_for_both_whoever_is_a_hair_likelier():
    async with session() as (bridge, host):

        def nearly_tied(event):
            if any(card.startswith("the human") for card in event["cards"]):
                return audience_answer(event)
            return {"person": [0.801, 0.804], "unclear": 0.0, "group": 0.0}

        host.audience = nearly_tied
        first = await host.say(bridge, "What do you think?")
        addressed = next(event for event in host.events if event.get("type") == "addressed")
        assert addressed["line"] is None and addressed["to"] == ["angel", "devil"]
        # The angel opens a tie, which the seam shows as a question for both.
        assert first["instructions"].startswith("You are the Angel")

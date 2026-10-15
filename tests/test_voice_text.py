"""Keep generated Markdown out of native speech and played conversation context."""

import pytest
from pipecat.utils.text.markdown_text_filter import MarkdownTextFilter
from pipecat_apple.text import PlainSpeechTextFilter
from support import human, respond, session


@pytest.mark.parametrize(
    "raw, expected",
    [
        ("**Hello**, *there*!", "Hello, there!"),
        (
            "## Your plan\n• Lunch at noon.\n• A walk at two.",
            "Your plan Lunch at noon. A walk at two.",
        ),
        ("1. Lunch.\n2. A walk.", "Lunch. A walk."),
        ("1.", ""),
        ("<b>Hello</b>, there.", "Hello, there."),
        ("**Unclosed emphasis and `code`.", "Unclosed emphasis and code."),
        ("The value is 1.5, with a -5 adjustment.", "The value is 1.5, with a -5 adjustment."),
        ("2<3 and 5>=-1.", "2 less than 3 and 5 greater than or equal to -1."),
        ("2<=3 and 5>1.", "2 less than or equal to 3 and 5 greater than 1."),
        (
            "You're welcome — it's on Saturday, September 12.",
            "You're welcome — it's on Saturday, September 12.",
        ),
        # Speaker labels from the characters' views, and stage directions, are never read out.
        ("[Angel]: Movement nurtures strength.", "Movement nurtures strength."),
        ("[Me]: Oh, come on, angel!", "Oh, come on, angel!"),
        ("[laughs] Fine, have the cake.", "Fine, have the cake."),
        ("[Note: speak now]", ""),
        # Emoji and symbols have no spoken form.
        ("Treat yourself 🍰✨!", "Treat yourself!"),
        ("Go on 😈 — just this once.", "Go on — just this once."),
        ("Flags 🇬🇧, keycaps 1️⃣ and families 👨‍👩‍👧 go.", "Flags, keycaps 1 and families go."),
        ("Breathe → relax ~ rest | sleep ♥ dream ★.", "Breathe relax rest sleep dream."),
        ("Hearts ❤️ and thumbs 👍🏽 vanish.", "Hearts and thumbs vanish."),
        ("Fine {really} ^^", "Fine really"),
        ("It's 20° outside.", "It's 20° outside."),
        ("✨🎉", ""),
    ],
)
async def test_plain_speech_filters_preserve_words_and_normal_punctuation(raw, expected):
    filtered = await MarkdownTextFilter().filter(raw)
    assert await PlainSpeechTextFilter().filter(filtered) == expected


async def test_split_markdown_deltas_are_cleaned_before_speech_and_context():
    async with session() as (bridge, host):
        generation = await host.say(bridge, "Hello")
        for delta in ("*", "*Hello", "*", "*, <b>friend", "</b>! ", "• Enjoy your day."):
            await respond(bridge, generation, delta=delta)
        await respond(bridge, generation, done=True)
        marker = 0
        for text in ("Hello, friend!", "Enjoy your day."):
            speech = await host.wait(lambda event: event.get("operation") == "speak", after=marker)
            assert speech["text"] == text
            marker = len(host.events)
            await host.play(bridge, speech)
        await host.wait(lambda event: event.get("state") == "listening", after=marker)
        assert bridge.context.messages[-1] == {
            "role": "assistant",
            "content": "Hello, friend! Enjoy your day.",
        }
        following = await host.say(bridge, "Continue")
        assert following["history"][-1]["content"] == "Hello, friend! Enjoy your day."


async def test_interruption_drops_unplayed_filtered_text_before_the_next_reply():
    async with session() as (bridge, host):
        generation = await host.say(bridge, "Hello")
        await respond(bridge, generation, delta="**This is unplayed**.")
        await respond(bridge, generation, done=True)
        await host.wait(lambda event: event.get("operation") == "speak")
        following = await host.say(bridge, "Stop")
        # Nothing of the reply was played, so "Hello" is still unanswered.
        assert human(following) == "Hello\nStop"
        assert following["history"] == []
        marker = len(host.events)
        await respond(bridge, following, delta="**A clean new reply**.")
        await respond(bridge, following, done=True)
        speech = await host.wait(lambda event: event.get("operation") == "speak", after=marker)
        assert speech["text"] == "A clean new reply."

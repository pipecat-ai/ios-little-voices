"""Check native preparation against real Pipecat playback and turn ordering."""

from pipecat_apple.context import bounded_history
from support import plain, reply, respond, session


def test_history_bound_keeps_whole_recent_turns_without_mutating_messages():
    messages = [{"role": "assistant", "content": "Orphan"}]
    for number in range(34):
        messages.extend(
            [
                {"role": "user", "content": f"Question {number}"},
                {"role": "assistant", "content": f"Played answer {number}"},
            ]
        )
    result = bounded_history(messages)
    assert result == messages[-64:]
    assert result[0]["content"] == "Question 2"
    result[0]["content"] = "A copied envelope"
    assert messages[-64]["content"] == "Question 2"


def test_character_bound_drops_complete_turns_and_keeps_unanswered_user():
    old = [{"role": "user", "content": "Old"}, {"role": "assistant", "content": "x" * 31_000}]
    recent = [
        {"role": "user", "content": "Recent"},
        {"role": "assistant", "content": "y" * 1_000},
        {"role": "assistant", "content": "Another played sentence"},
        {"role": "user", "content": "Interrupted before any speech"},
    ]
    assert bounded_history(old + recent) == recent
    assert bounded_history([{"role": "user", "content": "x" * 32_001}]) == []


async def test_completed_playback_prepares_the_exact_next_generation_history():
    async with session() as (bridge, host):
        initial = await host.wait(lambda event: event.get("type") == "prewarm")
        assert initial["history"] == []
        assert initial["session"] == host.session
        generation = await host.say(bridge, "Hello")
        speech = await reply(bridge, host, generation, "A played answer.")
        marker = len(host.events)
        await host.play(bridge, speech)
        prepared = await host.wait(lambda event: event.get("type") == "prewarm", after=marker)
        assert plain(prepared["history"]) == [
            {"role": "user", "content": "Hello"},
            {"role": "assistant", "content": "A played answer."},
        ]
        following = await host.say(bridge, "Continue")
        assert following["history"] == prepared["history"]
        assert following["instructions"] == prepared["instructions"]


async def test_interruption_prepares_played_sentences_without_pending_tts_text():
    async with session() as (bridge, host):
        generation = await host.say(bridge, "Explain")
        first = await reply(bridge, host, generation, "Played sentence. Unplayed sentence.")
        marker = len(host.events)
        await host.play(bridge, first)
        second = await host.wait(lambda event: event.get("operation") == "speak", after=marker)
        assert second["text"] == "Unplayed sentence."
        assert not any(event.get("type") == "prewarm" for event in host.events[marker:])
        await host.playback(bridge, second, speaking=True)
        marker, start = await host.begin_speech(bridge, text="Stop")
        prepared = await host.wait(lambda event: event.get("type") == "prewarm", after=marker)
        assert plain(prepared["history"]) == [
            {"role": "user", "content": "Explain"},
            {"role": "assistant", "content": "Played sentence.…"},
        ]
        await respond(bridge, second, done=True)
        await host.end_speech(bridge, "Stop", start=start, after=marker)
        following = await host.wait(
            lambda event: event.get("operation") == "generate", after=marker
        )
        assert following["history"] == prepared["history"]
        assert not any(
            "Unplayed" in message["content"]
            for event in host.events[marker:]
            if event.get("type") == "prewarm"
            for message in event["history"]
        )


async def test_noise_does_not_replace_prepared_context_or_trigger_a_new_turn():
    async with session() as (bridge, host):
        await host.wait(lambda event: event.get("type") == "prewarm")
        marker = len(host.events)
        await host.vad(bridge, 0.95)
        for _ in range(6):
            await host.vad(bridge, 0.05)
        endpoint = await host.wait(
            lambda event: event.get("operation") == "finalize_asr", after=marker
        )
        await respond(bridge, endpoint, done=True)
        # A following confirmed utterance is a deterministic input-queue barrier.
        generation = await host.say(bridge, "Actual words")
        events = host.events[marker:]
        next_turn = next(
            index for index, event in enumerate(events) if event.get("type") == "user_turn"
        )
        assert not any(event.get("type") == "prewarm" for event in events[:next_turn])
        assert generation["history"] == []
        assert [event for event in events if event.get("operation") == "generate"] == [generation]

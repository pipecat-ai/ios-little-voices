import asyncio

import pytest
from pipecat.frames.frames import TranscriptionFrame
from pipecat_apple.bridge import AppleNativeBridge
from pipecat_apple.frames import AppleControlFrame, AppleInputFrame
from support import (
    assistant_messages,
    human,
    plain,
    reply,
    respond,
    rtvi_type,
    session,
    speech_service,
)


async def test_real_turn_emits_rtvi_speech_events_and_waits_for_playback():
    async with session() as (bridge, host):
        request = await host.say(bridge, "Hello")
        assert human(request) == "Hello"
        speech = await reply(bridge, host, request, "Hello there.")
        assert speech["text"] == "Hello there."
        assert assistant_messages(bridge) == []
        assert not any(rtvi_type(event) == "bot-started-speaking" for event in host.events)
        await host.playback(bridge, speech, speaking=True)
        await host.wait(lambda event: rtvi_type(event) == "bot-started-speaking")
        assert assistant_messages(bridge) == []
        await host.playback(bridge, speech, speaking=False)
        await respond(bridge, speech, done=True)
        await host.wait(lambda event: event.get("state") == "listening")
        assert assistant_messages(bridge) == [{"role": "assistant", "content": "Hello there."}]
        await host.wait(lambda event: rtvi_type(event) == "bot-stopped-speaking")
        expected = [
            "user-started-speaking",
            "user-stopped-speaking",
            "bot-started-speaking",
            "bot-stopped-speaking",
        ]
        assert [
            rtvi_type(event) for event in host.events if rtvi_type(event) in expected
        ] == expected
        following = await host.say(bridge, "Another question")
        assert plain(following["history"]) == [
            {"role": "user", "content": "Hello"},
            {"role": "assistant", "content": "Hello there."},
        ]
        speech_types = [rtvi_type(event) for event in host.events]
        assert (
            speech_types.index("user-started-speaking")
            < speech_types.index("user-stopped-speaking")
            < speech_types.index("bot-started-speaking")
            < speech_types.index("bot-stopped-speaking")
        )


async def test_restarted_session_cancels_old_speech_and_answers_the_next_conversation():
    async with session() as (bridge, host):
        request = await host.say(bridge, "Old question")
        old_speech = await reply(bridge, host, request, "Unfinished answer.")
        await host.playback(bridge, old_speech, speaking=True)
        marker = len(host.events)
        await bridge.receive({"type": "stop", "session": host.session})
        host.session = "replacement-session"
        host.time = 0.0
        await bridge.receive({"type": "start", "session": host.session})
        await host.wait(
            lambda event: (
                event.get("type") == "cancel_request"
                and event.get("request") == old_speech["request"]
            ),
            after=marker,
        )
        await respond(bridge, old_speech, done=True)
        following = await host.say(bridge, "New question")
        new_speech = await reply(bridge, host, following, "Phonon answers.")
        assert new_speech["session"] == host.session
        assert new_speech["turn"] != old_speech["turn"]
        await host.play(bridge, new_speech)
        await host.wait(
            lambda event: (
                event.get("state") == "listening" and event.get("session") == host.session
            ),
            after=marker,
        )
        assert assistant_messages(bridge) == [{"role": "assistant", "content": "Phonon answers."}]


async def test_spoken_barge_in_cancels_generation_and_discards_late_results():
    async with session() as (bridge, host):
        old = await host.say(bridge, "Old question")
        marker, start = await host.begin_speech(bridge)
        await host.wait(
            lambda event: (
                event.get("type") == "cancel_request" and event.get("request") == old["request"]
            ),
            after=marker,
        )
        await respond(bridge, old, delta="This must never be spoken.")
        await respond(bridge, old, done=True)
        await host.end_speech(bridge, "New question", start=start, after=marker)
        new = await host.wait(
            lambda event: (
                event.get("operation") == "generate" and event.get("request") != old["request"]
            ),
            after=marker,
        )
        # The unanswered question stays in the conversation, in the same block as the new one.
        assert human(new) == "Old question\nNew question"
        assert new["turn"] != old["turn"]
        assert new["history"] == []
        speech = await reply(bridge, host, new, "New answer.")
        assert speech["turn"] == new["turn"]
        assert speech["text"] == "New answer."
        assert all(
            "never be spoken" not in event.get("text", "")
            for event in host.events
            if event.get("operation") == "speak"
        )


async def test_spoken_barge_in_preserves_only_played_sentences_in_context():
    async with session() as (bridge, host):
        request = await host.say(bridge, "Explain")
        first = await reply(bridge, host, request, "First sentence. Second sentence.")
        assert first["text"] == "First sentence."
        await host.play(bridge, first)
        second = await host.wait(
            lambda event: (
                event.get("operation") == "speak" and event.get("text") == "Second sentence."
            )
        )
        playback_marker = len(host.events)
        await host.playback(bridge, second, speaking=True)
        await host.wait(
            lambda event: rtvi_type(event) == "bot-started-speaking", after=playback_marker
        )
        marker, start = await host.begin_speech(bridge)
        await host.wait(
            lambda event: (
                event.get("type") == "cancel_request" and event.get("request") == second["request"]
            ),
            after=marker,
        )
        await host.wait(lambda event: rtvi_type(event) == "bot-stopped-speaking", after=marker)
        await respond(bridge, second, done=True)
        await host.playback(bridge, second, speaking=True)
        await host.end_speech(bridge, "Another question", start=start, after=marker)
        following = await host.wait(
            lambda event: event.get("operation") == "generate", after=marker
        )
        # The interrupted line is kept as far as it was heard, marked as cut off.
        assert plain(following["history"]) == [
            {"role": "user", "content": "Explain"},
            {"role": "assistant", "content": "First sentence.…"},
        ]
        assert not any(rtvi_type(event) == "bot-started-speaking" for event in host.events[marker:])


async def test_tts_failure_reports_error_and_next_user_turn_can_recover():
    async with session() as (bridge, host):
        request = await host.say(bridge, "Hello")
        speech = await reply(bridge, host, request, "Hello.")
        await respond(bridge, speech, error="Phonon could not synthesize the sentence")
        error = await host.wait(lambda event: event.get("type") == "error")
        assert "Phonon could not synthesize" in error["message"]
        assert assistant_messages(bridge) == []
        following = await host.say(bridge, "Try again")
        # Nothing of the reply was heard, so "Hello" is still unanswered.
        assert human(following) == "Hello\nTry again"
        assert following["history"] == []


async def test_empty_llm_response_reports_error_without_speech_or_assistant_context():
    async with session() as (bridge, host):
        request = await host.say(bridge, "Hello")
        await respond(bridge, request, done=True)
        error = await host.wait(lambda event: event.get("type") == "error")
        assert "empty response" in error["message"]
        assert assistant_messages(bridge) == []
        assert not any(event.get("operation") == "speak" for event in host.events)


async def test_vad_episode_without_transcript_does_not_trigger_generation():
    async with session() as (bridge, host):
        marker = len(host.events)
        await host.vad(bridge, 0.95)
        for _ in range(6):
            await host.vad(bridge, 0.05)
        endpoint = await host.wait(
            lambda event: event.get("operation") == "finalize_asr", after=marker
        )
        assert endpoint["turn"] is None
        await respond(bridge, endpoint, done=True)
        # A following valid endpoint is an ordering barrier for the acoustic span.
        request = await host.say(bridge, "An actual question")
        assert human(request) == "An actual question"
        assert [human(event) for event in host.events if event.get("operation") == "generate"] == [
            "An actual question"
        ]
        assert plain(request["history"]) == []
        assert len([event for event in host.events if event.get("type") == "user_turn"]) == 1


async def test_barge_in_without_final_words_keeps_the_native_context_usable():
    async with session() as (bridge, host):
        generation = await host.say(bridge, "Tell me a story")
        speech = await reply(bridge, host, generation, "Once upon a time.")
        await host.playback(bridge, speech, speaking=True)
        marker, start = await host.begin_speech(bridge, text="Um")
        # The interim word interrupted the reply, but ASR finalized no text.
        await host.end_speech(bridge, "", start=start, after=marker)
        await respond(bridge, speech, done=True)
        following = await host.say(bridge, "Hello again")
        # Nothing of the reply was heard, so the story request is still unanswered.
        assert human(following) == "Tell me a story\nHello again"
        assert [human(event) for event in host.events[marker:] if "prompt" in event] == [
            "Tell me a story\nHello again"
        ]
        assert {message["role"] for message in bridge.context.messages} <= {"user", "assistant"}
        assert not any(event.get("type") == "error" for event in host.events[marker:])


async def test_muted_and_previous_session_audio_cannot_create_user_turns():
    async with session() as (bridge, host):
        await bridge.receive({"type": "mute", "session": host.session})
        await host.vad(bridge, 0.95)
        await host.transcribe(bridge, "Muted words", start=0, final=True)
        await bridge.receive({"type": "unmute", "session": host.session})
        await host.vad(bridge, 0.95, session="previous")
        await host.transcribe(bridge, "Stale words", start=0, final=True, session="previous")
        request = await host.say(bridge, "Current speech")
        assert human(request) == "Current speech"
        assert plain(request["history"]) == []
        assert len([event for event in host.events if event.get("type") == "user_turn"]) == 1


async def test_new_vad_start_waits_for_the_previous_queued_endpoint_to_close():
    async with session() as (bridge, host):
        user = bridge.aggregators.user()
        stt = speech_service(bridge)
        transcript_received, endpoint_received, next_vad_received = (
            asyncio.Event(),
            asyncio.Event(),
            asyncio.Event(),
        )

        @user.event_handler("on_after_process_frame")
        async def received_transcript(processor, frame):
            if isinstance(frame, TranscriptionFrame) and frame.text == "First question":
                transcript_received.set()

        @stt.event_handler("on_before_process_frame")
        async def received_native_event(processor, frame):
            if isinstance(frame, AppleInputFrame) and frame.event.get("type") == "endpoint":
                endpoint_received.set()
            if (
                isinstance(frame, AppleControlFrame)
                and frame.event.get("type") == "vad"
                and frame.event.get("confidence", 0) > 0.9
                and endpoint_received.is_set()
            ):
                next_vad_received.set()

        marker, start = await host.begin_speech(bridge)
        await host.transcribe(bridge, "First question", start=start, final=True)
        await asyncio.wait_for(transcript_received.wait(), 5)
        # Hold the ordered turn-stop queue while system-priority VAD stays live.
        await user.pause_processing_frames()
        try:
            for _ in range(6):
                await host.vad(bridge, 0.05)
            endpoint = await host.wait(
                lambda event: event.get("operation") == "finalize_asr", after=marker
            )
            await respond(bridge, endpoint, done=True)
            await asyncio.wait_for(endpoint_received.wait(), 5)
            next_marker = len(host.events)
            await host.vad(bridge, 0.95)
            next_start = host.time
            await host.transcribe(bridge, "Second question", start=next_start, final=False)
            await asyncio.wait_for(next_vad_received.wait(), 5)
        finally:
            await user.resume_processing_frames()
        await host.wait(
            lambda event: rtvi_type(event) == "user-started-speaking", after=next_marker
        )
        await host.end_speech(bridge, "Second question", start=next_start, after=next_marker)
        following = await host.wait(
            lambda event: (
                event.get("operation") == "generate"
                and human(event) == "First question\nSecond question"
            ),
            after=next_marker,
        )
        assert following["history"] == []
        speech_types = [
            rtvi_type(event)
            for event in host.events
            if rtvi_type(event) in {"user-started-speaking", "user-stopped-speaking"}
        ]
        assert speech_types == [
            "user-started-speaking",
            "user-stopped-speaking",
            "user-started-speaking",
            "user-stopped-speaking",
        ]


async def test_muting_an_open_utterance_discards_its_already_finalized_segments():
    async with session() as (bridge, host):
        marker, start = await host.begin_speech(bridge)
        await host.transcribe(bridge, "Discard these words", start=start, final=True)
        await host.wait(lambda event: rtvi_type(event) == "user-transcription", after=marker)
        await bridge.receive({"type": "mute", "session": host.session})
        await bridge.receive({"type": "unmute", "session": host.session})
        following = await host.say(bridge, "Keep these words")
        assert human(following) == "Keep these words"
        assert plain(following["history"]) == []
        assert [human(event) for event in host.events if event.get("operation") == "generate"] == [
            "Keep these words"
        ]


async def test_muting_microphone_does_not_cancel_the_current_bot_response():
    async with session() as (bridge, host):
        request = await host.say(bridge, "Hello")
        speech = await reply(bridge, host, request, "Hello there.")
        await bridge.receive({"type": "mute", "session": host.session})
        await host.vad(bridge, 0.95)
        await host.transcribe(bridge, "Muted words", start=0, final=True)
        await host.play(bridge, speech)
        await host.wait(lambda event: event.get("state") == "listening")
        assert assistant_messages(bridge) == [{"role": "assistant", "content": "Hello there."}]
        assert not any(
            event.get("type") == "cancel_request" and event.get("request") == speech["request"]
            for event in host.events
        )


async def test_final_asr_segments_are_combined_once_before_inference():
    async with session() as (bridge, host):
        marker, start = await host.begin_speech(bridge)
        await host.transcribe(bridge, "The first sentence.", start=start, final=True)
        await host.transcribe(bridge, "The first sentence.", start=start, final=True)
        host.time += 0.1
        await host.transcribe(bridge, "The second sentence.", start=host.time, final=True)
        await host.end_speech(bridge, "", start=start, after=marker)
        request = await host.wait(lambda event: event.get("operation") == "generate", after=marker)
        assert human(request) == "The first sentence. The second sentence."
        assert plain(request["history"]) == []


async def test_restarting_session_cancels_old_generation_and_fences_old_audio():
    async with session() as (bridge, host):
        old = await host.say(bridge, "Before restart")
        old_session = host.session
        host.session = "new-session"
        marker = len(host.events)
        await bridge.receive({"type": "start", "session": host.session})
        await host.wait(
            lambda event: (
                event.get("type") == "cancel_request" and event.get("request") == old["request"]
            ),
            after=marker,
        )
        await respond(bridge, old, delta="Late answer.")
        await respond(bridge, old, done=True)
        await host.vad(bridge, 0.95, session=old_session)
        await host.transcribe(bridge, "Old audio", start=0, final=True, session=old_session)
        new = await host.say(bridge, "After restart")
        # A new session is a new conversation: the line from before it is gone.
        assert human(new) == "After restart"
        assert new["session"] == host.session
        assert new["turn"] != old["turn"]
        assert (
            len([event for event in host.events[marker:] if event.get("type") == "user_turn"]) == 1
        )
        assert not any(event.get("operation") == "speak" for event in host.events[marker:])


async def test_transcript_queued_before_session_restart_cannot_enter_the_new_turn():
    async with session() as (bridge, host):
        await host.transcribe(bridge, "A queued old transcript", start=0, final=True)
        host.session = "restarted"
        await bridge.receive({"type": "start", "session": host.session})
        request = await host.say(bridge, "Only current speech")
        assert human(request) == "Only current speech"
        assert plain(request["history"]) == []


async def test_transcript_queued_before_mute_cannot_enter_the_unmuted_turn():
    async with session() as (bridge, host):
        await host.transcribe(bridge, "A queued pre-mute transcript", start=0, final=True)
        await bridge.receive({"type": "mute", "session": host.session})
        await bridge.receive({"type": "unmute", "session": host.session})
        host.time = 0
        request = await host.say(bridge, "Only unmuted speech")
        assert human(request) == "Only unmuted speech"
        assert plain(request["history"]) == []


async def test_vad_queued_before_mute_cannot_start_a_turn_after_unmute():
    async with session() as (bridge, host):
        await host.vad(bridge, 0.95)
        await bridge.receive({"type": "mute", "session": host.session})
        await bridge.receive({"type": "unmute", "session": host.session})
        host.time = 0
        request = await host.say(bridge, "An unmuted question")
        assert human(request) == "An unmuted question"
        assert len([event for event in host.events if event.get("type") == "user_turn"]) == 1
        assert (
            len([event for event in host.events if rtvi_type(event) == "user-started-speaking"])
            == 1
        )


async def test_stopping_session_cancels_playback_and_ignores_late_completion():
    async with session() as (bridge, host):
        request = await host.say(bridge, "Hello")
        speech = await reply(bridge, host, request, "Hello there.")
        await host.playback(bridge, speech, speaking=True)
        await host.wait(lambda event: rtvi_type(event) == "bot-started-speaking")
        marker = len(host.events)
        await bridge.receive({"type": "stop", "session": host.session})
        await host.wait(
            lambda event: (
                event.get("type") == "cancel_request" and event.get("request") == speech["request"]
            ),
            after=marker,
        )
        await respond(bridge, speech, done=True)
        await host.playback(bridge, speech, speaking=True)
        assert assistant_messages(bridge) == []
        assert not any(rtvi_type(event) == "bot-started-speaking" for event in host.events[marker:])


@pytest.mark.parametrize(
    "long_questions, total_turns, retained_turns", [(False, 40, 32), (True, 30, 24)]
)
async def test_completed_conversations_keep_bounded_recent_turns(
    long_questions, total_turns, retained_turns
):
    async with session() as (bridge, host):
        completed = []
        for index in range(total_turns):
            question = f"Question {index:02d}: " + ("word " * 260 if long_questions else "Hello")
            question = question.strip()
            answer = f"Answer {index:02d}."
            request = await host.say(bridge, question)
            speech = await reply(bridge, host, request, answer)
            await host.play(bridge, speech)
            await host.wait(
                lambda event: (
                    event.get("state") == "listening" and event.get("turn") == request["turn"]
                )
            )
            completed.extend(
                [
                    {"role": "user", "content": question},
                    {"role": "assistant", "content": answer},
                ]
            )
            assert len(bridge.context.messages) <= 64
            assert sum(len(message["content"]) for message in bridge.context.messages) <= 32_000
        assert bridge.context.messages == completed[-retained_turns * 2 :]
        following = await host.say(bridge, "What next?")
        history = following["history"]
        assert 2 <= len(history) <= 64
        assert len(history) % 2 == 0
        assert sum(len(message["content"]) for message in history) <= 32_000
        assert plain(history) == completed[-len(history) :]


async def test_cancelled_native_request_cleans_up_operation():
    events = []
    bridge = AppleNativeBridge(events.append)

    async def consume():
        async for _ in bridge.stream("generate", "one"):
            pass

    task = asyncio.create_task(consume())
    await asyncio.sleep(0)
    request = events[0]["request"]
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert bridge.pending == {}
    assert bridge.operations == {}
    assert events[-1] == {
        "type": "cancel_request",
        "request": request,
        "turn": "one",
        "session": None,
    }


async def test_native_request_timeout_reports_operation_and_cancels_it():
    events = []
    bridge = AppleNativeBridge(events.append, timeout=0.01)
    with pytest.raises(TimeoutError, match="took too long to answer"):
        async for _ in bridge.stream("speak", "one"):
            pass
    assert bridge.pending == {}
    assert bridge.operations == {}
    assert events[-1]["type"] == "cancel_request"

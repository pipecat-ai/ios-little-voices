"""Acoustic candidates must contain native ASR words before interrupting the bot."""

import asyncio

import pytest
from pipecat_apple.frames import AppleInputFrame
from support import human, plain, reply, respond, rtvi_type, session, speech_service


async def transcribe_and_wait(bridge, host, text, *, start, final):
    service = speech_service(bridge)
    processed = asyncio.Event()

    async def received(processor, frame):
        if isinstance(frame, AppleInputFrame) and frame.event.get("text") == text:
            processed.set()

    service.add_event_handler("on_after_process_frame", received)
    try:
        await host.transcribe(bridge, text, start=start, final=final)
        await asyncio.wait_for(processed.wait(), 5)
    finally:
        service.remove_event_handler("on_after_process_frame", received)


async def finish_endpoint(bridge, request):
    service = speech_service(bridge)
    processed = asyncio.Event()

    async def received(processor, frame):
        if isinstance(frame, AppleInputFrame) and frame.event.get("type") == "endpoint":
            processed.set()

    service.add_event_handler("on_after_process_frame", received)
    try:
        await respond(bridge, request, done=True)
        await asyncio.wait_for(processed.wait(), 5)
    finally:
        service.remove_event_handler("on_after_process_frame", received)


async def quiet_endpoint(bridge, host, *, after):
    for _ in range(6):
        await host.vad(bridge, 0.05)
    return await host.wait(lambda event: event.get("operation") == "finalize_asr", after=after)


@pytest.mark.parametrize("phase", ["thinking", "playback", "sentence_gap"])
async def test_noise_without_asr_words_never_interrupts_the_bot(phase):
    async with session() as (bridge, host):
        generation = await host.say(bridge, "Keep talking")
        pending = generation
        if phase != "thinking":
            pending = await reply(bridge, host, generation, "First sentence. Second sentence.")
            await host.playback(bridge, pending, speaking=True)
            if phase == "sentence_gap":
                marker = len(host.events)
                await host.playback(bridge, pending, speaking=False)
                await respond(bridge, pending, done=True)
                pending = await host.wait(
                    lambda event: event.get("operation") == "speak", after=marker
                )
        turn, marker = bridge.turn, len(host.events)
        # Even a sustained false-positive classification is not a spoken turn.
        for _ in range(4):
            await host.vad(bridge, 0.95)
        await transcribe_and_wait(bridge, host, "...", start=host.time, final=False)
        endpoint = await quiet_endpoint(bridge, host, after=marker)
        await finish_endpoint(bridge, endpoint)
        assert bridge.turn == turn
        assert pending["request"] in bridge.pending
        assert not any(
            event.get("type") in {"user_turn", "cancel_request"}
            or rtvi_type(event) in {"user-started-speaking", "user-stopped-speaking"}
            for event in host.events[marker:]
        )

        # One recognized word is enough, including in a gap between sentences.
        marker, _ = await host.begin_speech(bridge, text="Stop")
        await host.wait(
            lambda event: (
                event.get("type") == "cancel_request" and event.get("request") == pending["request"]
            ),
            after=marker,
        )
        assert bridge.turn != turn


async def test_delayed_final_words_confirm_a_quiet_span_after_asr_finishes():
    async with session() as (bridge, host):
        marker = len(host.events)
        await host.vad(bridge, 0.95)
        start = host.time
        endpoint = await quiet_endpoint(bridge, host, after=marker)
        assert endpoint["turn"] is None
        await transcribe_and_wait(bridge, host, "Stop", start=start, final=True)
        assert bridge.turn is None
        assert not any(event.get("type") == "user_turn" for event in host.events[marker:])
        await finish_endpoint(bridge, endpoint)
        generated = await host.wait(
            lambda event: event.get("operation") == "generate", after=marker
        )
        assert human(generated) == "Stop"
        assert plain(generated["history"]) == []
        assert [
            rtvi_type(event)
            for event in host.events[marker:]
            if rtvi_type(event) in {"user-started-speaking", "user-stopped-speaking"}
        ] == ["user-started-speaking", "user-stopped-speaking"]
        assert not any(
            event.get("type") == "cancel_request" and event.get("request") == endpoint["request"]
            for event in host.events[marker:]
        )


async def test_early_asr_words_wait_for_an_acoustic_span():
    async with session() as (bridge, host):
        marker, start = len(host.events), host.time
        await transcribe_and_wait(bridge, host, "Hello", start=start, final=True)
        assert bridge.turn is None
        await host.vad(bridge, 0.95)
        await host.wait(lambda event: rtvi_type(event) == "user-started-speaking", after=marker)
        endpoint = await quiet_endpoint(bridge, host, after=marker)
        await finish_endpoint(bridge, endpoint)
        generated = await host.wait(
            lambda event: event.get("operation") == "generate", after=marker
        )
        assert human(generated) == "Hello"


async def test_unmatched_old_asr_cannot_confirm_later_unrelated_noise():
    async with session() as (bridge, host):
        marker = len(host.events)
        await transcribe_and_wait(bridge, host, "An old hypothesis", start=0, final=True)
        for _ in range(10):
            await host.vad(bridge, 0.05)
        await host.vad(bridge, 0.95)
        endpoint = await quiet_endpoint(bridge, host, after=marker)
        await finish_endpoint(bridge, endpoint)
        assert bridge.turn is None
        assert not any(event.get("type") == "user_turn" for event in host.events[marker:])
        generated = await host.say(bridge, "Current speech")
        assert human(generated) == "Current speech"
        assert plain(generated["history"]) == []


async def test_resumed_span_preserves_delayed_final_words_without_duplicates():
    async with session() as (bridge, host):
        marker = len(host.events)
        await host.vad(bridge, 0.95)
        start = host.time
        first_endpoint = await quiet_endpoint(bridge, host, after=marker)
        await transcribe_and_wait(bridge, host, "First half", start=start, final=True)
        await transcribe_and_wait(bridge, host, "First half", start=start, final=True)
        assert bridge.turn is None
        await host.vad(bridge, 0.95)
        await host.wait(lambda event: rtvi_type(event) == "user-started-speaking", after=marker)
        assert first_endpoint["request"] not in bridge.pending
        await respond(bridge, first_endpoint, done=True)
        marker = len(host.events)
        second_endpoint = await quiet_endpoint(bridge, host, after=marker)
        await host.transcribe(bridge, "second half", start=start, final=True)
        await finish_endpoint(bridge, second_endpoint)
        generated = await host.wait(
            lambda event: event.get("operation") == "generate", after=marker
        )
        assert human(generated) == "First half second half"
        assert len([event for event in host.events if event.get("type") == "user_turn"]) == 1


async def test_confirming_interim_cannot_discard_queued_final_transcripts():
    async with session() as (bridge, host):
        old = await host.say(bridge, "An earlier question")
        marker = len(host.events)
        await host.vad(bridge, 0.95)
        start = host.time
        await host.transcribe(bridge, "Please", start=start, final=False)
        await host.transcribe(bridge, "Please continue", start=start, final=True)
        await host.transcribe(bridge, "Please continue", start=start, final=True)
        await host.wait(lambda event: rtvi_type(event) == "user-started-speaking", after=marker)
        endpoint = await quiet_endpoint(bridge, host, after=marker)
        await finish_endpoint(bridge, endpoint)
        generated = await host.wait(
            lambda event: event.get("operation") == "generate", after=marker
        )
        # The earlier question was never answered, so it opens the human's block.
        assert human(generated) == "An earlier question\nPlease continue"
        assert old["request"] not in bridge.pending


async def test_queued_old_endpoint_cannot_close_a_new_acoustic_span():
    async with session() as (bridge, host):
        service = speech_service(bridge)
        old_endpoint_waiting, release_old_endpoint = asyncio.Event(), asyncio.Event()

        async def pause_first_endpoint(processor, frame):
            if (
                isinstance(frame, AppleInputFrame)
                and frame.event.get("type") == "endpoint"
                and not old_endpoint_waiting.is_set()
            ):
                old_endpoint_waiting.set()
                await release_old_endpoint.wait()

        service.add_event_handler("on_before_process_frame", pause_first_endpoint)
        marker = len(host.events)
        await host.vad(bridge, 0.95)
        first_endpoint = await quiet_endpoint(bridge, host, after=marker)
        await respond(bridge, first_endpoint, done=True)
        await asyncio.wait_for(old_endpoint_waiting.wait(), 5)
        try:
            marker = len(host.events)
            await host.vad(bridge, 0.95)
            start = host.time
            second_endpoint = await quiet_endpoint(bridge, host, after=marker)
            assert second_endpoint["request"] != first_endpoint["request"]
            await host.transcribe(bridge, "A new utterance", start=start, final=True)
            await respond(bridge, second_endpoint, done=True)
        finally:
            release_old_endpoint.set()
        generated = await host.wait(
            lambda event: event.get("operation") == "generate", after=marker
        )
        assert human(generated) == "A new utterance"
        assert len([event for event in host.events if event.get("type") == "user_turn"]) == 1

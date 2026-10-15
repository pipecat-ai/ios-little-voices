"""A microphone held to talk marks the human's turns in place of VAD."""

import asyncio

from pipecat_apple.frames import AppleInputFrame
from support import human, respond, rtvi_type, session, speech_service


async def endpoint_acknowledged(bridge, request):
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


async def test_held_words_are_a_turn_once_the_microphone_is_released():
    async with session() as (bridge, host):
        marker = len(host.events)
        await host.talk(bridge, True)
        host.time = 0.4
        await host.transcribe(bridge, "Should I", start=0.1, final=False)
        await host.wait(lambda event: rtvi_type(event) == "user-started-speaking", after=marker)
        host.time = 1.2
        await host.transcribe(bridge, "Should I go out", start=0.1, final=False)
        # Silence while it is held never ends the turn.
        await asyncio.sleep(0.2)
        assert not any(event.get("operation") == "finalize_asr" for event in host.events[marker:])
        await host.talk(bridge, False)
        endpoint = await host.wait(
            lambda event: event.get("operation") == "finalize_asr", after=marker
        )
        await host.transcribe(bridge, "Should I go out tonight?", start=0.1, final=True)
        await endpoint_acknowledged(bridge, endpoint)
        generated = await host.wait(
            lambda event: event.get("operation") == "generate", after=marker
        )
        assert human(generated) == "Should I go out tonight?"


async def test_a_press_without_words_starts_no_turn():
    async with session() as (bridge, host):
        marker = len(host.events)
        await host.talk(bridge, True)
        await host.talk(bridge, False)
        endpoint = await host.wait(
            lambda event: event.get("operation") == "finalize_asr", after=marker
        )
        await endpoint_acknowledged(bridge, endpoint)
        assert bridge.turn is None
        assert not any(
            event.get("type") == "user_turn" or event.get("operation") == "generate"
            for event in host.events[marker:]
        )

        # The next held question is heard as usual.
        marker = len(host.events)
        await host.talk(bridge, True)
        host.time = 3.0
        await host.transcribe(bridge, "Hello", start=2.5, final=True)
        await host.talk(bridge, False)
        endpoint = await host.wait(
            lambda event: event.get("operation") == "finalize_asr", after=marker
        )
        await endpoint_acknowledged(bridge, endpoint)
        generated = await host.wait(
            lambda event: event.get("operation") == "generate", after=marker
        )
        assert human(generated) == "Hello"


async def test_pressing_again_before_the_endpoint_continues_the_turn():
    async with session() as (bridge, host):
        marker = len(host.events)
        await host.talk(bridge, True)
        host.time = 0.6
        await host.transcribe(bridge, "Should I go out", start=0.1, final=True)
        await host.talk(bridge, False)
        first = await host.wait(
            lambda event: event.get("operation") == "finalize_asr", after=marker
        )
        await host.talk(bridge, True)
        await host.wait(
            lambda event: (
                event.get("type") == "cancel_request" and event.get("request") == first["request"]
            ),
            after=marker,
        )
        host.time = 1.4
        await host.transcribe(bridge, "tonight?", start=0.9, final=True)
        resumed = len(host.events)
        await host.talk(bridge, False)
        second = await host.wait(
            lambda event: event.get("operation") == "finalize_asr", after=resumed
        )
        await endpoint_acknowledged(bridge, second)
        generated = await host.wait(
            lambda event: event.get("operation") == "generate", after=marker
        )
        assert human(generated) == "Should I go out tonight?"
        assert [event for event in host.events[marker:] if event.get("type") == "user_turn"] == [
            {"type": "user_turn", "turn": bridge.turn, "session": host.session}
        ]


async def test_talk_is_ignored_while_muted():
    async with session() as (bridge, host):
        await bridge.receive({"type": "mute", "session": host.session})
        marker = len(host.events)
        await host.talk(bridge, True)
        await host.transcribe(bridge, "Hello", start=0, final=True)
        await host.talk(bridge, False)
        await asyncio.sleep(0.2)
        assert not any(
            event.get("operation") == "finalize_asr" or event.get("type") == "user_turn"
            for event in host.events[marker:]
        )

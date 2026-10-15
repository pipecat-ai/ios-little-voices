"""Reject stale native errors and preserve generation boundaries between replies."""

import pytest
from pipecat.frames.frames import ErrorFrame
from support import reply, respond, session


async def finish_reply(bridge, host, generation, text):
    speech = await reply(bridge, host, generation, text)
    marker = len(host.events)
    await host.play(bridge, speech)
    await host.wait(lambda event: event.get("state") == "listening", after=marker)


@pytest.mark.parametrize("transition", ["completed", "interrupted", "restarted"])
async def test_old_native_and_queued_pipeline_errors_cannot_fail_the_next_reply(transition):
    async with session() as (bridge, host):
        old = await host.say(bridge, "The earlier question")
        if transition == "completed":
            await finish_reply(bridge, host, old, "The earlier reply.")
        elif transition == "restarted":
            host.session = "replacement-session"
            host.time = 0
            await bridge.receive({"type": "start", "session": host.session})
        # A confirmed new utterance also interrupts an unfinished old generation.
        following = await host.say(bridge, "The next question")
        marker = len(host.events)
        await respond(bridge, old, error="Old native failure [LLM_FAILED]")
        await respond(bridge, old, delta="Stale text.")
        await respond(bridge, old, done=True)

        # Model a worker error callback that was delayed after leaving its service.
        error = ErrorFrame("Old queued failure [LLM_FAILED]")
        error.metadata.update(
            turn=old["turn"], session=old["session"], operation="generate", recoverable=True
        )
        await bridge.worker._call_event_handler("on_pipeline_error", error)
        await finish_reply(bridge, host, following, "The new reply succeeds.")
        assert not any(event.get("type") == "error" for event in host.events[marker:])
        assert not any(
            event.get("operation") == "speak" and "Stale" in event["text"]
            for event in host.events[marker:]
        )
        assert (
            len(
                [
                    event
                    for event in host.events
                    if event.get("type") == "request" and event.get("operation") == "generate"
                ]
            )
            == 2
        )


async def test_repeated_turns_recover_without_duplicate_generations_or_errors_between_turns():
    async with session() as (bridge, host):
        warm_during_generation = []
        emit = bridge.emit

        def observe(event):
            if event.get("type") == "prewarm" and any(
                operation == "generate" for operation, _ in bridge.operations.values()
            ):
                warm_during_generation.append(event)
            emit(event)

        bridge.emit = observe
        failed_turns = {2, 7}
        for index in range(12):
            generation = await host.say(bridge, f"Question {index}")
            marker = len(host.events)
            if index in failed_turns:
                await respond(bridge, generation, error="Injected native failure [LLM_FAILED]")
                error = await host.wait(lambda event: event.get("type") == "error", after=marker)
                assert error["turn"] == generation["turn"]
                assert error["operation"] == "generate" and error["recoverable"]
                await bridge.receive({"type": "interrupt", "session": host.session})
                await host.wait(lambda event: event.get("state") == "listening", after=marker)
            else:
                await finish_reply(bridge, host, generation, f"Reply {index} succeeds.")
            # Model delayed callbacks and a little quiet microphone activity while idle.
            await respond(bridge, generation, error="Late native failure [LLM_FAILED]")
            for _ in range(6):
                await host.vad(bridge, 0.05)

        assert len([event for event in host.events if event.get("type") == "error"]) == len(
            failed_turns
        )
        assert (
            len(
                [
                    event
                    for event in host.events
                    if event.get("type") == "request" and event.get("operation") == "generate"
                ]
            )
            == 12
        )
        assert not warm_during_generation
        assert not bridge.pending

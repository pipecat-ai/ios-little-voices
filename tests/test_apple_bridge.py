"""Session identity and playback timing across the asynchronous RTVI observer."""

import asyncio
from contextlib import asynccontextmanager

import pytest
from pipecat.frames.frames import (
    AggregatedTextFrame,
    AggregationType,
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    ErrorFrame,
    InterruptionFrame,
    LLMFullResponseStartFrame,
    TTSTextFrame,
    UserStartedSpeakingFrame,
)
from pipecat.observers.base_observer import FramePushed
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineWorker
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor
from pipecat.turns.user_turn_strategies import ExternalUserTurnStrategies
from pipecat.workers.runner import WorkerRunner
from pipecat_apple.bridge import AppleNativeBridge
from pipecat_apple.transport import AppleRTVIObserver, AppleTransport


@asynccontextmanager
async def running_bridge(observer_type=AppleRTVIObserver):
    events = []
    bridge = AppleNativeBridge(events.append)
    bridge.active = True
    bridge.session = "original-session"
    bridge.begin_turn()
    transport = AppleTransport(bridge)
    context = LLMContext()
    aggregators = LLMContextAggregatorPair(
        context,
        user_params=LLMUserAggregatorParams(user_turn_strategies=ExternalUserTurnStrategies()),
    )
    observer = observer_type(bridge)
    worker = PipelineWorker(
        Pipeline(
            [transport.input(), aggregators.user(), transport.output(), aggregators.assistant()]
        ),
        enable_rtvi=False,
        enable_turn_tracking=False,
        idle_timeout_secs=None,
    )
    worker.add_observer(observer)
    bridge.bind(worker, transport, context, aggregators)
    runner = WorkerRunner(handle_sigint=False, handle_sigterm=False)
    await runner.add_workers(worker)
    task = asyncio.create_task(runner.run())
    try:
        await asyncio.wait_for(bridge.ready.wait(), timeout=1)
        yield bridge, transport, observer, events
    finally:
        await runner.cancel()
        await task


@pytest.mark.asyncio
async def test_queued_observer_retains_the_session_and_turn_at_actual_frame_push():
    class PausedObserver(AppleRTVIObserver):
        def __init__(self, bridge):
            super().__init__(bridge)
            self.waiting = asyncio.Event()
            self.release = asyncio.Event()

        async def on_push_frame(self, data):
            if isinstance(data.frame, UserStartedSpeakingFrame) and not self.waiting.is_set():
                self.waiting.set()
                await self.release.wait()
            await super().on_push_frame(data)

    async with running_bridge(PausedObserver) as (bridge, transport, observer, events):
        turn = bridge.turn
        await bridge.worker.queue_frame(UserStartedSpeakingFrame())
        await asyncio.wait_for(observer.waiting.wait(), timeout=1)
        bridge.session = "replacement-session"
        bridge.begin_turn()
        observer.release.set()
        async with asyncio.timeout(1):
            while not any(event.get("type") == "rtvi" for event in events):
                await asyncio.sleep(0)
        messages = [event for event in events if event.get("type") == "rtvi"]
        started = next(
            event for event in messages if event["message"]["type"] == "user-started-speaking"
        )
        assert started["turn"] == turn
        assert started["session"] == "original-session"


def observer_fixture():
    events = []
    bridge = AppleNativeBridge(events.append)
    bridge.turn, bridge.session = "new-turn", "new-session"
    output = AppleTransport(bridge).output()
    return AppleRTVIObserver(bridge), output, events


async def observe(observer, source, frame, *, turn="old-turn", session="old-session"):
    frame.metadata.update(turn=turn, session=session)
    await observer.on_push_frame(
        FramePushed(
            source=source,
            destination=FrameProcessor(),
            frame=frame,
            direction=FrameDirection.DOWNSTREAM,
            timestamp=0,
        )
    )


@pytest.mark.asyncio
async def test_native_played_text_emits_after_bot_stop_without_waiting_for_another_reply():
    observer, output, events = observer_fixture()
    await observe(observer, output, BotStartedSpeakingFrame())
    await observe(observer, output, BotStoppedSpeakingFrame())
    played = TTSTextFrame("Already audible.", aggregated_by=AggregationType.SENTENCE)
    played.will_be_spoken = True
    await observe(observer, output, played)
    completed = next(event for event in events if event["message"]["type"] == "bot-output")
    assert completed["message"]["data"]["spoken_status"] == "completed"
    assert completed["turn"] == "old-turn"
    assert completed["session"] == "old-session"


@pytest.mark.asyncio
async def test_buffered_announcement_keeps_its_own_origin_when_playback_starts():
    observer, output, events = observer_fixture()
    announced = AggregatedTextFrame("Earlier reply.", aggregated_by=AggregationType.SENTENCE)
    announced.will_be_spoken = True
    await observe(observer, output, announced)
    await observe(
        observer, output, BotStartedSpeakingFrame(), turn="new-turn", session="new-session"
    )
    announced_event = next(event for event in events if event["message"]["type"] == "bot-output")
    assert announced_event["turn"] == "old-turn"
    assert announced_event["session"] == "old-session"


@pytest.mark.asyncio
async def test_interruption_discards_unplayed_rtvi_announcements():
    observer, output, events = observer_fixture()
    await observe(
        observer,
        output,
        AggregatedTextFrame("Cancelled reply.", aggregated_by=AggregationType.SENTENCE),
    )
    await observe(observer, output, InterruptionFrame())
    await observe(
        observer, output, BotStartedSpeakingFrame(), turn="new-turn", session="new-session"
    )
    assert not [event for event in events if event["message"]["type"] == "bot-output"]


@pytest.mark.asyncio
async def test_old_native_errors_cannot_fail_a_new_turn_or_session():
    async with running_bridge() as (bridge, transport, observer, events):
        old_turn = bridge.turn
        bridge.session = "new-session"
        bridge.begin_turn()
        processed = asyncio.Event()

        @bridge.worker.event_handler("on_pipeline_error")
        async def handled(worker, frame):
            processed.set()

        cases = [
            (old_turn, "new-session"),
            (bridge.turn, "original-session"),
            (bridge.turn, bridge.session),
        ]
        for turn, session in cases:
            processed.clear()
            frame = ErrorFrame("Native error")
            frame.metadata.update(turn=turn, session=session)
            await transport.output().push_error_frame(frame)
            await asyncio.wait_for(processed.wait(), timeout=1)
        errors = [event for event in events if event.get("type") == "error"]
        assert errors == [
            {
                "type": "error",
                "message": "Native error",
                "turn": bridge.turn,
                "session": "new-session",
                "operation": None,
                "recoverable": False,
            }
        ]


@pytest.mark.asyncio
async def test_rtvi_messages_name_the_speaker_and_line_of_their_response():
    observer, output, events = observer_fixture()
    started = LLMFullResponseStartFrame()
    started.metadata.update(speaker="devil", voice="Damon", line=1)
    await observe(observer, FrameProcessor(), started)
    (event,) = [event for event in events if event["message"]["type"] == "bot-llm-started"]
    assert (event["speaker"], event["line"], event["turn"]) == ("devil", 1, "old-turn")
    assert "voice" not in event

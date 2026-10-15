"""Service settings and native response identity through standard Pipecat services."""

import asyncio
from collections.abc import AsyncIterator
from typing import Any

import pytest
from loguru import logger
from pipecat.adapters.schemas.function_schema import FunctionSchema
from pipecat.adapters.schemas.tools_schema import ToolsSchema
from pipecat.frames.frames import (
    AggregatedTextFrame,
    ErrorFrame,
    InterruptionFrame,
    LLMContextFrame,
    LLMFullResponseEndFrame,
    LLMFullResponseStartFrame,
    LLMTextFrame,
    LLMUpdateSettingsFrame,
    ProposedUserStartedSpeakingFrame,
    ProposedUserStoppedSpeakingFrame,
    TTSStartedFrame,
    TTSStoppedFrame,
    TTSTextFrame,
    UserStartedSpeakingFrame,
    UserStoppedSpeakingFrame,
)
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineWorker
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.processors.aggregators.llm_text_processor import LLMTextProcessor
from pipecat.processors.frame_processor import FrameProcessor
from pipecat.services.settings import LLMSettings, STTSettings, TTSSettings
from pipecat.tests.utils import SleepFrame, run_test
from pipecat.transcriptions.language import Language
from pipecat.turns.user_start import ExternalUserTurnStartStrategy
from pipecat.turns.user_stop import ExternalUserTurnStopStrategy
from pipecat.turns.user_turn_strategies import UserTurnStrategies
from pipecat.utils.text.simple_text_aggregator import SimpleTextAggregator
from pipecat_apple.bridge import AppleNativeBridge
from pipecat_apple.frames import TTSAudioPlayedFrame
from pipecat_apple.llm import AppleFoundationLLMService, AppleLLMAdapter
from pipecat_apple.phonon import PhononTTSService
from pipecat_apple.stt import AppleSpeechSTTService
from pipecat_apple.transport import AppleRTVIObserver
from pipecat_apple.vad import AppleVADAnalyzer


class NativeHost(AppleNativeBridge):
    """A local host that records operations and acknowledges complete playback."""

    def __init__(self, *, change_turn_during_playback: bool = False):
        super().__init__(lambda event: None)
        self.active = True
        self.turn = "original-turn"
        self.requests: list[dict[str, Any]] = []
        self.change_turn_during_playback = change_turn_during_playback

    async def stream(self, operation: str, turn: str | None, **payload) -> AsyncIterator[dict]:
        self.requests.append({"operation": operation, "turn": turn, **payload})
        await asyncio.sleep(0.005)
        if operation == "generate":
            yield {"delta": "First sentence. Second sentence."}
        elif self.change_turn_during_playback:
            self.turn = "new-turn"


def sentences() -> LLMTextProcessor:
    """Sentences split where the host's tokenizer would split them."""
    return LLMTextProcessor(
        text_aggregator=SimpleTextAggregator(
            sentence_boundary_matcher=lambda text: text.find(".") + 1
        )
    )


@pytest.mark.asyncio
async def test_service_settings_update_the_native_system_instruction():
    host = NativeHost()
    service = AppleFoundationLLMService(
        host,
        system_instruction="Argument instruction",
        settings=LLMSettings(system_instruction="Settings instruction"),
    )
    assert service._settings.system_instruction == "Settings instruction"
    context = LLMContext([{"role": "user", "content": "Hello"}])
    await run_test(
        service,
        frames_to_send=[
            LLMUpdateSettingsFrame(delta=LLMSettings(system_instruction="Updated instruction")),
            LLMContextFrame(context),
            SleepFrame(sleep=0.03),
        ],
    )
    assert host.requests[0]["instructions"] == "Updated instruction"


@pytest.mark.asyncio
async def test_settings_frame_for_another_service_is_forwarded_once():
    host = NativeHost()
    service = AppleFoundationLLMService(host)
    other = AppleFoundationLLMService(host)
    settings = LLMUpdateSettingsFrame(delta=LLMSettings(system_instruction="Other"), service=other)
    down, _ = await run_test(service, frames_to_send=[settings, SleepFrame(sleep=0.01)])
    assert [frame for frame in down if isinstance(frame, LLMUpdateSettingsFrame)] == [settings]
    assert service._settings.system_instruction is None


def test_adapter_resolves_system_context_without_mutating_conversation():
    messages = [
        {"role": "system", "content": "Context instruction"},
        {"role": "user", "content": "Question"},
    ]
    context = LLMContext(messages.copy())
    with pytest.warns(DeprecationWarning, match="system prompt"):
        params = AppleLLMAdapter().get_llm_invocation_params(
            context, system_instruction="Service instruction"
        )
    assert params == {
        "prompt": "Question",
        "history": [],
        "instructions": "Service instruction",
    }
    assert context.messages == messages


def test_adapter_refuses_a_context_with_tools():
    tool = FunctionSchema(name="get_weather", description="The weather", properties={}, required=[])
    context = LLMContext([{"role": "user", "content": "Is it sunny?"}], tools=[tool])
    with pytest.raises(NotImplementedError, match="runs no tools"):
        AppleLLMAdapter().get_llm_invocation_params(context, system_instruction="Rules")
    plain = LLMContext([{"role": "user", "content": "Is it sunny?"}], tools=ToolsSchema([]))
    assert "tools" not in AppleLLMAdapter().get_llm_invocation_params(
        plain, system_instruction="Rules"
    )


def test_adapter_rejects_overlong_turns_instead_of_silently_truncating():
    context = LLMContext([{"role": "user", "content": "x" * 2001}])
    with pytest.raises(ValueError, match="2,000"):
        AppleLLMAdapter().get_llm_invocation_params(context)


def test_service_settings_reject_options_the_native_host_cannot_apply():
    host = NativeHost()
    with pytest.raises(ValueError, match="temperature"):
        AppleFoundationLLMService(host, settings=LLMSettings(temperature=0.2))
    with pytest.raises(ValueError, match="voice"):
        PhononTTSService(host, settings=TTSSettings(voice="another-voice"))


@pytest.mark.asyncio
async def test_speech_recognition_accepts_only_its_own_model_and_language():
    service = AppleSpeechSTTService(NativeHost(), vad_analyzer=AppleVADAnalyzer())
    assert await service._update_settings(STTSettings(language=Language.EN_US)) == {}
    with pytest.raises(ValueError, match="language"):
        await service._update_settings(STTSettings(language=Language.FR))
    with pytest.raises(ValueError, match="model"):
        await service._update_settings(STTSettings(model="another-model"))


@pytest.mark.asyncio
async def test_native_response_identity_survives_tts_aggregation_and_playback():
    host = NativeHost()
    service = PhononTTSService(host)
    down, up = await run_test(
        Pipeline([AppleFoundationLLMService(host), sentences(), service]),
        frames_to_send=[
            LLMContextFrame(LLMContext([{"role": "user", "content": "Hello"}])),
            SleepFrame(sleep=0.05),
        ],
    )
    assert not [frame for frame in up if isinstance(frame, ErrorFrame)]
    assert [request["turn"] for request in host.requests] == ["original-turn"] * 3
    speech = [
        frame
        for frame in down
        if isinstance(
            frame, (AggregatedTextFrame, TTSAudioPlayedFrame, TTSStartedFrame, TTSStoppedFrame)
        )
    ]
    assert len([frame for frame in speech if isinstance(frame, TTSTextFrame)]) == 2
    assert all(frame.metadata["turn"] == "original-turn" for frame in speech)
    assert service._context_turns == {}


@pytest.mark.asyncio
async def test_old_queued_sentences_never_use_a_new_native_turn():
    host = NativeHost(change_turn_during_playback=True)
    service = PhononTTSService(host)
    frames = [
        LLMFullResponseStartFrame(),
        LLMTextFrame("Old first sentence. Old second sentence."),
        LLMFullResponseEndFrame(),
    ]
    for frame in frames:
        frame.metadata["turn"] = "original-turn"
    down, up = await run_test(
        Pipeline([sentences(), service]),
        frames_to_send=[
            *frames,
            SleepFrame(sleep=0.03),
            InterruptionFrame(),
            SleepFrame(sleep=0.01),
        ],
    )
    assert [request["turn"] for request in host.requests] == ["original-turn"]
    assert not [frame for frame in down if isinstance(frame, TTSTextFrame)]
    assert not [frame for frame in up if isinstance(frame, ErrorFrame)]
    assert service._context_turns == {}


def test_native_rtvi_needs_no_rtvi_processor():
    errors = []
    handler = logger.add(errors.append, level="ERROR")
    try:
        worker = PipelineWorker(Pipeline([FrameProcessor()]), enable_rtvi=False)
        worker.add_observer(AppleRTVIObserver(NativeHost()))
    finally:
        logger.remove(handler)
    assert not errors


@pytest.mark.asyncio
async def test_native_rtvi_sends_llm_text_without_loading_sentencex(monkeypatch):
    def unavailable(text):
        raise AssertionError("Native RTVI must not load sentencex")

    monkeypatch.setattr(
        "pipecat.processors.frameworks.rtvi.observer.match_endofsentence", unavailable
    )
    events = []
    observer = AppleRTVIObserver(AppleNativeBridge(events.append))
    await observer._handle_llm_text_frame(LLMTextFrame("A native sentence."))
    assert [event["message"]["type"] for event in events] == ["bot-llm-text"]


@pytest.mark.asyncio
async def test_native_endpoint_can_end_a_turn_without_recognized_words():
    context = LLMContext()
    aggregators = LLMContextAggregatorPair(
        context,
        user_params=LLMUserAggregatorParams(
            user_turn_strategies=UserTurnStrategies(
                start=[ExternalUserTurnStartStrategy()],
                stop=[ExternalUserTurnStopStrategy(wait_for_transcript=False)],
            ),
            # Native hosts reject developer messages, so recovery prompts are disabled.
            empty_user_turn=None,
        ),
    )
    down, _ = await run_test(
        aggregators.user(),
        frames_to_send=[
            ProposedUserStartedSpeakingFrame(),
            SleepFrame(sleep=0.02),
            ProposedUserStoppedSpeakingFrame(),
            SleepFrame(sleep=0.02),
        ],
    )
    assert [
        type(frame)
        for frame in down
        if isinstance(frame, (UserStartedSpeakingFrame, UserStoppedSpeakingFrame))
    ] == [UserStartedSpeakingFrame, UserStoppedSpeakingFrame]
    assert context.messages == []


class TwoVoices(AppleFoundationLLMService):
    """Answer each turn with two responses; the first continues to the second."""

    async def respond(self, context: LLMContext, turn: str) -> None:
        for line, (speaker, voice) in enumerate([("angel", "Angel_F01"), ("devil", "Devil_01")]):

            async def finish(text: str, last: bool = line == 1) -> dict[str, Any]:
                return {"continues": not last}

            await self.generate(
                context,
                turn,
                instructions=f"You are the {speaker}.",
                metadata={"speaker": speaker, "voice": voice, "line": line},
                finish=finish,
            )


@pytest.mark.asyncio
async def test_one_turn_speaks_several_responses_each_in_its_own_voice():
    host = NativeHost()
    down, up = await run_test(
        Pipeline([TwoVoices(host), sentences(), PhononTTSService(host)]),
        frames_to_send=[
            LLMContextFrame(LLMContext([{"role": "user", "content": "Hello"}])),
            SleepFrame(sleep=0.1),
        ],
    )
    assert not [frame for frame in up if isinstance(frame, ErrorFrame)]
    generations = [request for request in host.requests if request["operation"] == "generate"]
    assert [request["instructions"] for request in generations] == [
        "You are the angel.",
        "You are the devil.",
    ]
    speeches = [
        (request["speaker"], request["voice"], request["line"], request["text"])
        for request in host.requests
        if request["operation"] == "speak"
    ]
    assert speeches == [
        ("angel", "Angel_F01", 0, "First sentence."),
        ("angel", "Angel_F01", 0, "Second sentence."),
        ("devil", "Devil_01", 1, "First sentence."),
        ("devil", "Devil_01", 1, "Second sentence."),
    ]
    ends = [frame for frame in down if isinstance(frame, LLMFullResponseEndFrame)]
    assert [frame.metadata["continues"] for frame in ends] == [True, False]


class FailingHost(NativeHost):
    """A host whose language model fails every generation."""

    async def stream(self, operation: str, turn: str | None, **payload) -> AsyncIterator[dict]:
        self.requests.append({"operation": operation, "turn": turn, **payload})
        raise RuntimeError("The model declined.")
        yield  # An async generator, like the bridge's.


class Unreported(AppleFoundationLLMService):
    """Answer each turn with one response, handling its failure itself."""

    async def respond(self, context: LLMContext, turn: str) -> None:
        try:
            await self.generate(context, turn, metadata={"line": 0}, report_errors=False)
        except RuntimeError as exc:
            self.failure = exc


@pytest.mark.asyncio
async def test_a_failure_left_unreported_is_raised_and_its_response_closed():
    host = FailingHost()
    service = Unreported(host)
    down, up = await run_test(
        service,
        frames_to_send=[LLMContextFrame(LLMContext([{"role": "user", "content": "Hello"}]))],
    )
    assert [request["operation"] for request in host.requests] == ["generate"]
    assert str(service.failure) == "The model declined."
    assert not [frame for frame in up if isinstance(frame, ErrorFrame)]
    # The response is closed, keeping the turn, so a following response starts afresh.
    ends = [frame for frame in down if isinstance(frame, LLMFullResponseEndFrame)]
    assert [(frame.metadata["line"], frame.metadata["continues"]) for frame in ends] == [(0, True)]


@pytest.mark.asyncio
async def test_sentences_with_nothing_to_say_aloud_are_not_spoken():
    host = NativeHost()
    frames = [
        LLMFullResponseStartFrame(),
        LLMTextFrame("Hi there. 😇. Bye now."),
        LLMFullResponseEndFrame(),
    ]
    for frame in frames:
        frame.metadata["turn"] = "original-turn"
    down, up = await run_test(
        Pipeline([sentences(), PhononTTSService(host)]),
        frames_to_send=[*frames, SleepFrame(sleep=0.05)],
    )
    assert [request["text"] for request in host.requests] == ["Hi there.", "Bye now."]
    assert not [frame for frame in up if isinstance(frame, ErrorFrame)]
    played = [frame.text for frame in down if isinstance(frame, TTSTextFrame)]
    assert played == ["Hi there.", "Bye now."]

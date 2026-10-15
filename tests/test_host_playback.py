"""Speech the native host plays, acknowledged through Pipecat's TTS service."""

import asyncio
from collections.abc import AsyncGenerator

import pytest
from pipecat.frames.frames import (
    ErrorFrame,
    Frame,
    InterruptionFrame,
    LLMFullResponseEndFrame,
    LLMFullResponseStartFrame,
    LLMTextFrame,
    TTSStartedFrame,
    TTSStoppedFrame,
    TTSTextFrame,
)
from pipecat.pipeline.pipeline import Pipeline
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.processors.aggregators.llm_text_processor import LLMTextProcessor
from pipecat.services.settings import TTSSettings
from pipecat.tests.utils import SleepFrame, run_test
from pipecat.turns.user_turn_strategies import ExternalUserTurnStrategies
from pipecat.utils.text.simple_text_aggregator import SimpleTextAggregator
from pipecat_apple.frames import TTSAudioPlayedFrame
from pipecat_apple.playback import NativePlaybackTTSService


def sentences() -> LLMTextProcessor:
    """Sentences split where the host's tokenizer would split them, at full stops."""
    return LLMTextProcessor(
        text_aggregator=SimpleTextAggregator(
            sentence_boundary_matcher=lambda text: text.find(".") + 1
        )
    )


class NativeTTS(NativePlaybackTTSService):
    """Play each sentence before acknowledging it, without sending Python PCM."""

    def __init__(self, *, outcome="played", delay=0.04):
        super().__init__(settings=TTSSettings(model="native", voice=None, language=None))
        self.outcome = outcome
        self.delay = delay
        self.requests = []
        self.cancelled = False

    async def run_tts(self, text: str, context_id: str) -> AsyncGenerator[Frame]:
        self.requests.append(text)
        try:
            await asyncio.sleep(self.delay)
            if self.outcome == "error":
                yield ErrorFrame("Native playback failed")
            elif self.outcome == "raise":
                raise RuntimeError("Native audio engine stopped")
            elif self.outcome == "wrong_context":
                yield TTSAudioPlayedFrame(context_id="another-request")
            elif self.outcome == "played":
                yield TTSAudioPlayedFrame(context_id=context_id)
            elif self.outcome == "error_after_ack":
                yield TTSAudioPlayedFrame(context_id=context_id)
                yield ErrorFrame("Native request failed after reporting playback")
        except asyncio.CancelledError:
            self.cancelled = True
            raise


async def test_each_sentence_waits_for_its_playback_and_keeps_its_text_in_order():
    service = NativeTTS()
    down, up = await run_test(
        Pipeline([sentences(), service]),
        frames_to_send=[
            LLMFullResponseStartFrame(),
            LLMTextFrame("First sentence. Second sentence."),
            LLMFullResponseEndFrame(),
            SleepFrame(sleep=0.15),
        ],
    )
    assert not [frame for frame in up if isinstance(frame, ErrorFrame)]
    assert service.requests == ["First sentence.", "Second sentence."]
    spoken = [frame for frame in down if isinstance(frame, TTSTextFrame)]
    assert [frame.text for frame in spoken] == service.requests
    assert sum(isinstance(frame, TTSStartedFrame) for frame in down) == 1
    assert sum(isinstance(frame, TTSStoppedFrame) for frame in down) == 1
    for index, frame in enumerate(down):
        if isinstance(frame, TTSTextFrame):
            assert isinstance(down[index - 1], TTSAudioPlayedFrame)
    assert down.index(spoken[-1]) < next(
        i for i, frame in enumerate(down) if isinstance(frame, LLMFullResponseEndFrame)
    )


@pytest.mark.parametrize("outcome", ["error", "raise", "wrong_context", "error_after_ack"])
async def test_failed_playback_never_commits_unplayed_text(outcome):
    service = NativeTTS(outcome=outcome)
    down, up = await run_test(
        Pipeline([sentences(), service]),
        frames_to_send=[
            LLMFullResponseStartFrame(),
            LLMTextFrame("This sentence did not play."),
            LLMFullResponseEndFrame(),
            SleepFrame(sleep=0.08),
        ],
    )
    assert not [frame for frame in down if isinstance(frame, TTSTextFrame)]
    assert len([frame for frame in up if isinstance(frame, ErrorFrame)]) == 1
    assert [frame for frame in down if isinstance(frame, LLMFullResponseEndFrame)]


async def test_a_sentence_the_host_skips_commits_nothing_and_reports_nothing():
    service = NativeTTS(outcome="skipped")
    down, up = await run_test(
        Pipeline([sentences(), service]),
        frames_to_send=[
            LLMFullResponseStartFrame(),
            LLMTextFrame("This sentence was no longer wanted."),
            LLMFullResponseEndFrame(),
            SleepFrame(sleep=0.08),
        ],
    )
    assert not [frame for frame in down if isinstance(frame, TTSTextFrame)]
    assert not [frame for frame in up if isinstance(frame, ErrorFrame)]
    assert [frame for frame in down if isinstance(frame, LLMFullResponseEndFrame)]
    assert service._consecutive_zero_audio_contexts == 0


async def test_interruption_cancels_playback_without_acknowledging_text():
    service = NativeTTS(delay=1)
    down, _ = await run_test(
        Pipeline([sentences(), service]),
        frames_to_send=[
            LLMFullResponseStartFrame(),
            LLMTextFrame("This sentence is interrupted."),
            LLMFullResponseEndFrame(),
            SleepFrame(sleep=0.03),
            InterruptionFrame(),
            SleepFrame(sleep=0.03),
        ],
    )
    assert service.cancelled
    assert not [frame for frame in down if isinstance(frame, (TTSAudioPlayedFrame, TTSTextFrame))]


async def test_the_assistant_context_keeps_only_played_sentences_on_interruption():
    class InterruptedNativeTTS(NativeTTS):
        async def run_tts(self, text, context_id):
            self.delay = 1 if self.requests else 0.01
            async for frame in super().run_tts(text, context_id):
                yield frame

    context = LLMContext()
    aggregators = LLMContextAggregatorPair(
        context,
        user_params=LLMUserAggregatorParams(user_turn_strategies=ExternalUserTurnStrategies()),
    )
    service = InterruptedNativeTTS()
    await run_test(
        Pipeline([sentences(), service, aggregators.assistant()]),
        frames_to_send=[
            LLMFullResponseStartFrame(),
            LLMTextFrame("This sentence played. This sentence was interrupted."),
            LLMFullResponseEndFrame(),
            SleepFrame(sleep=0.05),
            InterruptionFrame(),
            SleepFrame(sleep=0.02),
        ],
    )
    assert service.cancelled
    assert context.messages == [{"role": "assistant", "content": "This sentence played."}]

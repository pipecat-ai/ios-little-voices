"""The angel and the devil: a native iOS voice agent built from standard Pipecat services and turns."""

from collections.abc import Callable

from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineParams, PipelineWorker
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.processors.aggregators.llm_text_processor import LLMTextProcessor
from pipecat.turns.user_start import ExternalUserTurnStartStrategy
from pipecat.turns.user_stop import ExternalUserTurnStopStrategy
from pipecat.turns.user_turn_strategies import UserTurnStrategies
from pipecat.utils.text.simple_text_aggregator import SimpleTextAggregator
from pipecat_apple.bridge import AppleNativeBridge
from pipecat_apple.phonon import PhononTTSService
from pipecat_apple.stt import AppleSpeechSTTService
from pipecat_apple.transport import AppleRTVIObserver, AppleTransport
from pipecat_apple.vad import AppleVADAnalyzer

from mobile_app.duo import MAX_LINES, DuoLLMService
from mobile_app.prompts import session_instructions


def create_bot(
    bridge: AppleNativeBridge,
    *,
    sentence_boundary_matcher: Callable[[str], int],
    max_lines: int = MAX_LINES,
) -> PipelineWorker:
    """Configure the native providers and the standard Pipecat voice pipeline.

    Args:
        bridge: Native request bridge.
        sentence_boundary_matcher: The native sentence tokenizer's boundary function.
        max_lines: The most lines the angel and the devil say in answer to one turn.
    """
    transport = AppleTransport(bridge)
    stt = AppleSpeechSTTService(bridge, vad_analyzer=AppleVADAnalyzer())
    llm = DuoLLMService(bridge, max_lines=max_lines)
    # Phonon speaks a sentence at a time, split where the host's tokenizer finds the ends.
    sentences = LLMTextProcessor(
        text_aggregator=SimpleTextAggregator(
            sentence_boundary_matcher=sentence_boundary_matcher, max_buffer_chars=420
        )
    )
    tts = PhononTTSService(bridge)
    context = LLMContext()
    context_aggregator = LLMContextAggregatorPair(
        context,
        user_params=LLMUserAggregatorParams(
            # The host proposes each turn's start and stop, finalizing its transcript first.
            user_turn_strategies=UserTurnStrategies(
                start=[ExternalUserTurnStartStrategy()],
                stop=[ExternalUserTurnStopStrategy(wait_for_transcript=False)],
            ),
            # Apple Foundation Models accepts no developer messages, which Pipecat's
            # empty-turn recovery would add. Unrecognized speech gets no reply.
            empty_user_turn=None,
        ),
    )

    @context_aggregator.assistant().event_handler("on_assistant_turn_stopped")
    async def heard(aggregator, message):
        await llm.heard(message.content, message.interrupted)

    pipeline = Pipeline(
        [
            transport.input(),
            stt,
            context_aggregator.user(),
            llm,
            sentences,
            tts,
            transport.output(),
            context_aggregator.assistant(),
        ]
    )
    worker = PipelineWorker(
        pipeline,
        params=PipelineParams(audio_in_sample_rate=16000, audio_out_sample_rate=24000),
        enable_rtvi=False,
        enable_turn_tracking=False,
        idle_timeout_secs=None,
    )
    # RTVI messages reach the host over the bridge, without an RTVIProcessor.
    worker.add_observer(AppleRTVIObserver(bridge))
    bridge.bind(
        worker,
        transport,
        context,
        context_aggregator,
        tts=tts,
        llm=llm,
        system_instruction_factory=session_instructions,
    )
    return worker

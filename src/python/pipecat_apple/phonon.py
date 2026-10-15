"""Gradium Phonon speech synthesized and played by the native Apple host."""

from collections.abc import AsyncGenerator, Sequence
from typing import TYPE_CHECKING, Any

from pipecat.frames.frames import (
    AggregatedTextFrame,
    CancelFrame,
    EndFrame,
    ErrorFrame,
    Frame,
    InterruptionFrame,
    LLMFullResponseEndFrame,
    LLMFullResponseStartFrame,
    LLMTextFrame,
    TTSSpeakFrame,
)
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.settings import TTSSettings
from pipecat.utils.text.base_text_filter import BaseTextFilter
from pipecat.utils.text.markdown_text_filter import MarkdownTextFilter

from pipecat_apple.frames import TTSAudioPlayedFrame
from pipecat_apple.playback import NativePlaybackTTSService
from pipecat_apple.text import PlainSpeechTextFilter

if TYPE_CHECKING:
    from pipecat_apple.bridge import AppleNativeBridge

MODEL = "gradium-phonon"

# A response's speaker, voice and line, from its start frame's metadata. They go with each
# sentence's speak request (the voice selects one of the host's loaded voices) and label the
# spoken text, so the host can show and animate each line as its speaker says it.
SPEECH_TAGS = ("speaker", "voice", "line")


def _validate_native_settings(settings: TTSSettings) -> None:
    unsupported = [
        key
        for key, value in settings.given_fields().items()
        if value is not None and not (key == "model" and value == MODEL)
    ]
    if unsupported:
        raise ValueError(
            f"Phonon's voice comes from each response, not settings: {', '.join(unsupported)}"
        )


class PhononTTSService(NativePlaybackTTSService):
    """Request Gradium Phonon speech from the native host and await its playback.

    The host runs Phonon on-device and owns model loading, the voices and PCM
    playback. Each speak request completes only after its audio has finished
    playing. A response may name one of the host's voices, its speaker and its
    line in its start frame's metadata (``voice``, ``speaker``, ``line``);
    without a voice, the host uses its first. A sentence with nothing to say
    aloud, such as emoji alone, is skipped.

    Text arrives as sentences: put an :class:`LLMTextProcessor` with the host's
    sentence boundaries ahead of this service.
    """

    Settings = TTSSettings

    def __init__(
        self,
        bridge: "AppleNativeBridge",
        *,
        text_filters: Sequence[BaseTextFilter] | None = None,
        settings: TTSSettings | None = None,
        **kwargs: Any,
    ) -> None:
        """Initialize the Phonon service.

        Args:
            bridge: Native request bridge.
            text_filters: Spoken-sentence filters; defaults to plain speech cleanup.
            settings: Service settings; only the model may be given.
            **kwargs: Additional NativePlaybackTTSService configuration.
        """
        defaults = TTSSettings(model=MODEL, voice=None, language=None)
        if settings is not None:
            _validate_native_settings(settings)
            defaults.apply_update(settings)
        super().__init__(
            text_filters=list(text_filters)
            if text_filters is not None
            else [MarkdownTextFilter(), PlainSpeechTextFilter()],
            sample_rate=24000,
            settings=defaults,
            **kwargs,
        )
        self.bridge = bridge
        self._response_turn: str | None = None
        self._response_tags: dict[str, Any] = {}
        self._context_turns: dict[str, str] = {}
        self._context_tags: dict[str, dict[str, Any]] = {}

    async def _update_settings(self, delta: TTSSettings) -> dict[str, Any]:
        _validate_native_settings(delta)
        return await super()._update_settings(delta)

    def create_context_id(self) -> str:
        """Bind a Pipecat audio context to the response that supplied its text.

        Returns:
            The new audio context's identifier.
        """
        context_id = super().create_context_id()
        if self._response_turn is not None:
            self._context_turns.setdefault(context_id, self._response_turn)
            self._context_tags.setdefault(context_id, dict(self._response_tags))
        return context_id

    async def on_audio_context_completed(self, context_id: str) -> None:
        """Release the response identity after its acknowledged output is drained.

        Args:
            context_id: The audio context that completed.
        """
        self._context_turns.pop(context_id, None)
        self._context_tags.pop(context_id, None)
        await super().on_audio_context_completed(context_id)

    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        """Reject stale response text before base TTS aggregation or native playback.

        Args:
            frame: Incoming Pipecat frame. Standalone TTSSpeakFrame requests must
                include their owning user turn in metadata["turn"].
            direction: Direction of travel through the pipeline.
        """
        if direction == FrameDirection.DOWNSTREAM:
            if isinstance(frame, (LLMFullResponseStartFrame, TTSSpeakFrame)):
                turn = frame.metadata.get("turn")
                if not turn or turn != self.bridge.turn or not self.bridge.active:
                    return
                self._response_turn = turn
                self._response_tags = {
                    key: frame.metadata[key] for key in SPEECH_TAGS if key in frame.metadata
                }
            elif isinstance(frame, (LLMTextFrame, AggregatedTextFrame, LLMFullResponseEndFrame)):
                turn = frame.metadata.get("turn", self._response_turn)
                if (
                    not turn
                    or turn != self._response_turn
                    or turn != self.bridge.turn
                    or not self.bridge.active
                ):
                    return
        context_id = self._turn_context_id
        await super().process_frame(frame, direction)
        if isinstance(frame, (InterruptionFrame, CancelFrame, EndFrame)):
            self._response_turn = None
            self._response_tags = {}
            self._context_turns.clear()
            self._context_tags.clear()
        elif isinstance(frame, LLMFullResponseEndFrame):
            self._response_turn = None
            self._response_tags = {}
            if context_id and not self.audio_context_available(context_id):
                self._context_turns.pop(context_id, None)
                self._context_tags.pop(context_id, None)

    async def push_frame(
        self, frame: Frame, direction: FrameDirection = FrameDirection.DOWNSTREAM
    ) -> None:
        """Keep native response identities on aggregated and acknowledged output.

        Args:
            frame: The frame to push.
            direction: The direction to push it in.
        """
        context_id = getattr(frame, "context_id", None)
        if isinstance(context_id, str) and (turn := self._context_turns.get(context_id)):
            frame.metadata.setdefault("turn", turn)
            for key, value in self._context_tags.get(context_id, {}).items():
                frame.metadata.setdefault(key, value)
        await super().push_frame(frame, direction)

    async def run_tts(self, text: str, context_id: str) -> AsyncGenerator[Frame]:
        """Await native playback and acknowledge only the original response's audio.

        Args:
            text: Sentence supplied by Pipecat's text aggregator.
            context_id: Pipecat audio context bound to the response's turn.

        Yields:
            A playback acknowledgement or a tagged native error frame; nothing for a
            sentence whose turn has ended or that has no letters or digits to say.
        """
        turn = self._context_turns.get(context_id)
        if not self._current(turn) or not any(character.isalnum() for character in text):
            return
        tags = self._context_tags.get(context_id, {})
        try:
            async for _ in self.bridge.stream("speak", turn, text=text, **tags):
                pass
        except Exception as exc:
            if self._current(turn):
                error = ErrorFrame(str(exc), exception=exc)
                error.metadata["turn"] = turn
                yield error
            return
        if self._current(turn):
            yield TTSAudioPlayedFrame(context_id=context_id)

    def _current(self, turn: str | None) -> bool:
        """Whether a response's turn is still the active session's turn."""
        return turn is not None and turn == self.bridge.turn and self.bridge.active

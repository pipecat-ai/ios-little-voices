"""Pipecat speech whose audio the native host plays."""

import math
from collections.abc import AsyncGenerator
from typing import Any

from pipecat.frames.frames import ErrorFrame, Frame, TTSStoppedFrame, TTSTextFrame
from pipecat.services.tts_service import TextAggregationMode, TTSService

from pipecat_apple.frames import TTSAudioPlayedFrame


class NativePlaybackTTSService(TTSService):
    """A TTSService whose audio never reaches Python: the native host plays it.

    ``run_tts`` awaits each sentence's playback and yields a
    :class:`TTSAudioPlayedFrame` once the host has played it, an ``ErrorFrame``
    if it failed, or nothing for a sentence no longer wanted. A sentence's text
    goes downstream, and so into the assistant context, only once it has
    played. Implementations bound their native requests and cancel them when
    ``run_tts`` is cancelled.
    """

    def __init__(self, **kwargs: Any) -> None:
        """Initialize the service.

        Args:
            **kwargs: Additional TTSService configuration.
        """
        super().__init__(
            text_aggregation_mode=TextAggregationMode.SENTENCE,
            push_text_frames=True,
            push_start_frame=True,
            push_stop_frames=True,
            # A sentence's request ends only once the host has played it, however long that
            # takes, so its audio context waits for it rather than timing out.
            stop_frame_timeout_s=math.inf,
            **kwargs,
        )
        # Contexts whose latest sentence the host played, until that sentence's text is queued.
        self._played: set[str] = set()

    async def start_ttfb_metrics(self, *, start_time: float | None = None) -> None:
        """Measure nothing: the host plays the audio, so its first byte is never seen here.

        Args:
            start_time: Unused.
        """

    async def tts_process_generator(
        self, context_id: str, generator: AsyncGenerator[Frame | None]
    ) -> None:
        """Queue a sentence's frames in its audio context, noting whether the host played it.

        Args:
            context_id: The sentence's audio context.
            generator: The sentence's ``run_tts`` frames.
        """
        played = failed = False
        try:
            async for frame in generator:
                if isinstance(frame, TTSAudioPlayedFrame):
                    if frame.context_id != context_id:
                        raise ValueError("Playback acknowledged for another audio context")
                    played = True
                elif isinstance(frame, ErrorFrame):
                    failed = True
                if frame:
                    await self.append_to_audio_context(context_id, frame)
        except Exception as exc:
            failed = True
            await self.append_to_audio_context(
                context_id, ErrorFrame(f"Native playback failed: {exc}", exception=exc)
            )
        if played and not failed:
            self._played.add(context_id)
        else:
            self._played.discard(context_id)

    async def append_to_audio_context(self, context_id: str | None, frame: Any) -> None:
        """Queue a frame in an audio context, leaving out the text of a sentence never played.

        Pipecat queues each sentence's text after the sentence's request, for
        the assistant context to commit once it is pushed.

        Args:
            context_id: The audio context.
            frame: The frame, a word timestamp, or None to close the context.
        """
        if isinstance(frame, TTSTextFrame):
            if context_id not in self._played:
                return
            self._played.discard(context_id)
        await super().append_to_audio_context(context_id, frame)

    async def on_turn_context_completed(self) -> None:
        """Close the turn's audio context, whose sentences have all played by now."""
        context_id = self._turn_context_id
        if context_id is not None and self.audio_context_available(context_id):
            await self.append_to_audio_context(context_id, TTSStoppedFrame(context_id=context_id))
            await self.remove_audio_context(context_id)
        await super().on_turn_context_completed()

    async def on_audio_context_interrupted(self, context_id: str) -> None:
        """Forget an interrupted context's playback.

        Args:
            context_id: The interrupted audio context.
        """
        self._played.discard(context_id)
        await super().on_audio_context_interrupted(context_id)

    async def _record_context_audio_outcome(self, context_id: str, received_audio: bool) -> None:
        # Pipecat counts a context without PCM against the service, but no PCM ever arrives here:
        # the host reports its own failures, and a sentence it skips plays nothing on purpose.
        pass

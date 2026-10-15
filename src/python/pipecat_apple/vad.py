"""Apple SoundAnalysis speech confidence with Pipecat VAD debouncing."""

import math

from pipecat.audio.vad.vad_analyzer import VADAnalyzer, VADParams, VADState


class AppleVADAnalyzer(VADAnalyzer):
    """Apply Pipecat VAD parameters to speech scores produced on an Apple device.

    The native SoundAnalysis classifier uses a 0.5-second analysis window with
    a 0.1-second hop. Each score represents one hop for Pipecat's start/stop
    debounce counters. Classification and microphone audio remain native;
    this analyzer only receives confidence values, optional normalized volume,
    and native audio timestamps.

    Call :meth:`reset` when the native audio session or its timeline restarts.
    Deliver scores serially in audio order on the pipeline's event loop.
    """

    def __init__(self, *, params: VADParams | None = None):
        """Initialize the native confidence analyzer.

        Args:
            params: VAD configuration. Defaults to confidence 0.65, 0.1 seconds
                to start, 0.6 seconds to stop, and disabled volume gating.
        """
        super().__init__(
            sample_rate=16000,
            params=params
            or VADParams(confidence=0.65, start_secs=0.1, stop_secs=0.6, min_volume=0.0),
        )
        self._last_timestamp: float | None = None
        self.set_sample_rate(16000)

    def num_frames_required(self) -> int:
        """Return the 1600 samples corresponding to the native 0.1-second hop."""
        return 1600

    def analyze_confidence(
        self, confidence: float, *, volume: float = 1.0, timestamp: float | None = None
    ) -> VADState:
        """Advance VAD using one native classification result.

        Args:
            confidence: Speech probability between zero and one.
            volume: Normalized volume between zero and one. The default disables
                additional volume gating; SoundAnalysis handles classification.
            timestamp: Native audio timestamp in seconds. Duplicate or older
                timestamps are ignored without advancing the debounce counters.

        Returns:
            Current Pipecat VAD state, including pending start/stop transitions.

        Raises:
            ValueError: Confidence or volume is outside zero to one or is not
                finite, or the supplied timestamp is not finite.
        """
        for name, value in (("confidence", confidence), ("volume", volume)):
            if not math.isfinite(value) or not 0 <= value <= 1:
                raise ValueError(f"{name} must be finite and between zero and one")
        if timestamp is not None:
            if not math.isfinite(timestamp):
                raise ValueError("timestamp must be finite")
            if self._last_timestamp is not None and timestamp <= self._last_timestamp:
                return self._vad_state
            self._last_timestamp = timestamp

        self._update_vad_state(confidence, volume)
        return self._finalize_vad_state()

    def reset(self) -> None:
        """Clear debounce state and timestamps for a new native audio session."""
        self.set_params(self.params)
        self._last_timestamp = None

    def voice_confidence(self, buffer: bytes) -> float:
        """Reject PCM input: classification runs in the native SoundAnalysis host.

        Args:
            buffer: PCM audio, which this analyzer never receives.

        Returns:
            Nothing; the call always raises.
        """
        raise NotImplementedError("Use analyze_confidence() with native SoundAnalysis scores")

    async def analyze_audio(self, buffer: bytes) -> VADState:
        """Reject PCM input: native scores arrive through :meth:`analyze_confidence`.

        Args:
            buffer: PCM audio, which this analyzer never receives.

        Returns:
            Nothing; the call always raises.
        """
        raise NotImplementedError("Use analyze_confidence() with native SoundAnalysis scores")

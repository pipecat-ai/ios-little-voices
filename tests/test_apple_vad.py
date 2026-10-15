"""Apple SoundAnalysis scores through Pipecat's VAD debouncing."""

import pytest
from pipecat.audio.vad.vad_analyzer import VADAnalyzer, VADParams, VADState
from pipecat_apple.vad import AppleVADAnalyzer


def analyzer(**overrides) -> AppleVADAnalyzer:
    return AppleVADAnalyzer(
        params=VADParams(
            **dict(confidence=0.7, start_secs=0.2, stop_secs=0.3, min_volume=0.0) | overrides
        )
    )


def test_sustained_speech_starts_and_silence_stops_after_debounce():
    vad = analyzer()
    assert vad.analyze_confidence(0.7) == VADState.STARTING
    assert vad.analyze_confidence(0.9) == VADState.SPEAKING
    assert vad.analyze_confidence(0.1) == VADState.STOPPING
    assert vad.analyze_confidence(0.1) == VADState.STOPPING
    assert vad.analyze_confidence(0.1) == VADState.QUIET


def test_noise_spikes_and_brief_pauses_do_not_change_confirmed_speaking():
    vad = analyzer()
    for _ in range(8):
        assert vad.analyze_confidence(0.95) == VADState.STARTING
        assert vad.analyze_confidence(0.2) == VADState.QUIET
    assert vad.analyze_confidence(0.9) == VADState.STARTING
    assert vad.analyze_confidence(0.9) == VADState.SPEAKING
    for _ in range(8):
        assert vad.analyze_confidence(0.1) == VADState.STOPPING
        assert vad.analyze_confidence(0.9) == VADState.SPEAKING
    assert vad.analyze_confidence(0.1) == VADState.STOPPING
    assert vad.analyze_confidence(0.1) == VADState.STOPPING
    assert vad.analyze_confidence(0.1) == VADState.QUIET


def test_duplicate_and_stale_results_do_not_advance_start_or_stop():
    vad = analyzer()
    assert vad.analyze_confidence(0.9, timestamp=100.0) == VADState.STARTING
    assert vad.analyze_confidence(0.9, timestamp=100.0) == VADState.STARTING
    assert vad.analyze_confidence(0.1, timestamp=99.9) == VADState.STARTING
    assert vad.analyze_confidence(0.9, timestamp=100.1) == VADState.SPEAKING
    assert vad.analyze_confidence(0.1, timestamp=100.2) == VADState.STOPPING
    for _ in range(8):
        assert vad.analyze_confidence(0.1, timestamp=100.2) == VADState.STOPPING
        assert vad.analyze_confidence(0.9, timestamp=99.0) == VADState.STOPPING
    assert vad.analyze_confidence(0.1, timestamp=100.3) == VADState.STOPPING
    assert vad.analyze_confidence(0.1, timestamp=100.4) == VADState.QUIET


def test_reset_accepts_a_new_timeline_and_clears_pending_counts():
    vad = analyzer()
    assert vad.analyze_confidence(0.9, timestamp=10) == VADState.STARTING
    vad.reset()
    assert vad.analyze_confidence(0.9, timestamp=0) == VADState.STARTING
    assert vad.analyze_confidence(0.9, timestamp=0.1) == VADState.SPEAKING
    vad.reset()
    assert vad.analyze_confidence(0.1, timestamp=0) == VADState.QUIET


def test_optional_native_volume_uses_normal_pipecat_threshold():
    vad = analyzer(min_volume=0.3)
    for _ in range(8):
        assert vad.analyze_confidence(1.0, volume=0.29) == VADState.QUIET
    assert vad.analyze_confidence(0.9, volume=0.3) == VADState.STARTING
    assert vad.analyze_confidence(0.9, volume=0.3) == VADState.SPEAKING


@pytest.mark.parametrize("value", [float("nan"), float("inf"), -float("inf"), -0.1, 1.1])
@pytest.mark.parametrize("field", ["confidence", "volume"])
def test_invalid_native_scores_are_rejected_without_advancing_state(field, value):
    vad = analyzer()
    values = {"confidence": 0.9, "volume": 1.0, field: value}
    with pytest.raises(ValueError, match=field):
        vad.analyze_confidence(**values, timestamp=10)
    assert vad.analyze_confidence(0.9, timestamp=10) == VADState.STARTING


@pytest.mark.parametrize("timestamp", [float("nan"), float("inf"), -float("inf")])
def test_invalid_timestamp_is_rejected_without_consuming_a_speech_score(timestamp):
    vad = analyzer()
    with pytest.raises(ValueError, match="timestamp"):
        vad.analyze_confidence(0.9, timestamp=timestamp)
    assert vad.analyze_confidence(0.9, timestamp=10) == VADState.STARTING


@pytest.mark.asyncio
async def test_pcm_is_rejected_and_resources_can_be_cleaned_up():
    vad = AppleVADAnalyzer()
    with pytest.raises(NotImplementedError, match="analyze_confidence"):
        vad.voice_confidence(b"\0" * 3200)
    with pytest.raises(NotImplementedError, match="analyze_confidence"):
        await vad.analyze_audio(b"\0" * 3200)
    await vad.cleanup()


def test_default_native_hop_and_stop_duration():
    vad = AppleVADAnalyzer()
    vad.set_sample_rate(48000)
    assert vad.sample_rate == 16000
    assert vad.num_frames_required() == 1600
    assert vad.analyze_confidence(0.65) == VADState.SPEAKING
    for _ in range(5):
        assert vad.analyze_confidence(0) == VADState.STOPPING
    assert vad.analyze_confidence(0) == VADState.QUIET


class BytesVADAnalyzer(VADAnalyzer):
    """Deterministic score source exercising the real desktop audio batch loop."""

    def __init__(self):
        super().__init__(params=VADParams(start_secs=0.2, stop_secs=0.2))
        self.set_sample_rate(10)

    def num_frames_required(self) -> int:
        return 1

    def voice_confidence(self, buffer: bytes) -> float:
        return buffer[0] / 255

    def _get_smoothed_volume(self, audio: bytes) -> float:
        return 1.0


def test_desktop_batch_finalizes_once_after_all_samples():
    vad = BytesVADAnalyzer()
    speech, silence = b"\xff\x00", b"\x00\x00"
    # Two speech hops followed by silence cancel the pending start in this batch.
    assert vad._run_analyzer(speech + speech + silence) == VADState.QUIET
    assert vad._run_analyzer(speech + speech) == VADState.SPEAKING
    # Likewise, resumed speech cancels a pending stop before batch finalization.
    assert vad._run_analyzer(silence + silence + speech) == VADState.SPEAKING


def test_desktop_audio_carries_partial_buffers_between_calls():
    vad = BytesVADAnalyzer()
    assert vad._run_analyzer(b"\xff") == VADState.QUIET
    assert vad._run_analyzer(b"\x00") == VADState.STARTING
    assert vad._run_analyzer(b"\xff") == VADState.STARTING
    assert vad._run_analyzer(b"\x00") == VADState.SPEAKING

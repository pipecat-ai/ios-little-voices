"""The app's patch to the pinned Pipecat release, and what it makes possible on a phone."""

import subprocess
import sys
from collections.abc import AsyncGenerator
from pathlib import Path

import pytest
from pipecat.frames.frames import Frame
from pipecat.services.settings import TTSSettings
from pipecat.services.tts_service import TTSService
from pipecat_package import PATCH, PIPECAT_DIR, PIPECAT_URL, patch_pipecat, validate_pipecat
from setup import DOWNLOADS

ROOT = Path(__file__).resolve().parents[1]
WHEEL = DOWNLOADS / PIPECAT_URL.rsplit("/", 1)[1]


def files(directory: Path) -> dict[str, bytes]:
    return {
        path.relative_to(directory).as_posix(): path.read_bytes()
        for path in directory.rglob("*")
        if path.is_file()
    }


def repository(tmp_path: Path, patch: str) -> Path:
    (tmp_path / PATCH).parent.mkdir(parents=True)
    (tmp_path / PATCH).write_text(patch)
    return tmp_path


def test_the_patch_applies_to_the_pinned_release(tmp_path):
    root = repository(tmp_path, (ROOT / PATCH).read_text())
    patched = patch_pipecat(WHEEL, root)
    assert validate_pipecat(root) == patched
    # The tests and the app use this patched release as it stands.
    assert files(patched) == files(validate_pipecat())


def test_a_patch_that_does_not_apply_fails_clearly(tmp_path):
    patch = (ROOT / PATCH).read_text().replace("\n import io\n", "\n import iox\n", 1)
    root = repository(tmp_path, patch)
    with pytest.raises(RuntimeError, match="does not apply to pipecat-ai 1.12.0"):
        patch_pipecat(WHEEL, root)
    assert not (root / PIPECAT_DIR).exists()


def test_only_the_pinned_release_is_patched(tmp_path):
    wheel = tmp_path / WHEEL.name
    wheel.write_bytes(WHEEL.read_bytes() + b"\0")
    with pytest.raises(RuntimeError, match="not the pipecat-ai 1.12.0 release"):
        patch_pipecat(wheel, repository(tmp_path, (ROOT / PATCH).read_text()))


def test_a_changed_patch_needs_pipecat_prepared_again(tmp_path):
    root = repository(tmp_path, (ROOT / PATCH).read_text())
    patch_pipecat(WHEEL, root)
    (root / PATCH).write_text((root / PATCH).read_text() + "\n")
    with pytest.raises(RuntimeError, match="setup.py --pipecat-only"):
        validate_pipecat(root)


def test_the_patched_modules_import_without_desktop_packages():
    script = """
import importlib.abc, sys
DESKTOP = {
    'aiofiles', 'aiohttp', 'audioop', 'dotenv', 'google', 'loudness', 'num2words', 'numba',
    'numpy', 'onnxruntime', 'openai', 'PIL', 'resampy', 'sentencex', 'soundfile', 'soxr', 'yaml',
    'ssl', '_ssl', '_hashlib',
}
class NoDesktop(importlib.abc.MetaPathFinder):
    # As on a phone: Pipecat's desktop requirements, and OpenSSL, are missing.
    def find_spec(self, fullname, path=None, target=None):
        if fullname.split('.')[0] in DESKTOP:
            raise ModuleNotFoundError('Desktop dependency imported: ' + fullname)
sys.meta_path.insert(0, NoDesktop())
sys.path[:0] = sys.argv[1:]
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair, LLMUserAggregatorParams,
)
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.turns.user_turn_strategies import ExternalUserTurnStrategies
from pipecat.services.tts_service import TTSService
from pipecat.services.stt_service import STTService
from pipecat.services.llm_service import LLMService
from pipecat.transports.base_input import BaseInputTransport
from pipecat.transports.base_output import BaseOutputTransport
from pipecat.transports.base_transport import TransportParams
from pipecat.processors.frameworks.rtvi import RTVIObserver
from pipecat.pipeline.worker import PipelineWorker
from pipecat.processors.aggregators.llm_text_processor import LLMTextProcessor
from pipecat.utils.text.simple_text_aggregator import SimpleTextAggregator
from pipecat.audio.vad.vad_analyzer import VADState
from pipecat_apple.bridge import AppleNativeBridge
from pipecat_apple.llm import AppleFoundationLLMService
from pipecat_apple.phonon import PhononTTSService
from pipecat_apple.stt import AppleSpeechSTTService
from pipecat_apple.transport import AppleRTVIObserver, AppleTransport
from pipecat_apple.vad import AppleVADAnalyzer
LLMContextAggregatorPair(
    LLMContext(),
    user_params=LLMUserAggregatorParams(user_turn_strategies=ExternalUserTurnStrategies()),
)
BaseInputTransport(TransportParams())
BaseOutputTransport(TransportParams())
class Speech(TTSService):
    async def run_tts(self, text, context_id):
        yield None
Speech()
bridge = AppleNativeBridge(lambda event: None)
LLMTextProcessor(text_aggregator=SimpleTextAggregator(sentence_boundary_matcher=lambda text: 0))
PhononTTSService(bridge)
vad = AppleVADAnalyzer()
assert vad.analyze_confidence(0.9) == VADState.SPEAKING
vad.reset()
assert vad.analyze_confidence(0.0) == VADState.QUIET
"""
    result = subprocess.run(
        [sys.executable, "-c", script, str(ROOT / PIPECAT_DIR), str(ROOT / "src/python")],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


class Speech(TTSService):
    def __init__(self):
        super().__init__(settings=TTSSettings(model="native", voice=None, language=None))

    async def run_tts(self, text: str, context_id: str) -> AsyncGenerator[Frame]:
        yield None


def test_the_default_resampler_is_created_on_first_use_and_can_be_replaced(monkeypatch):
    created = []

    def create():
        created.append(object())
        return created[-1]

    monkeypatch.setattr("pipecat.services.tts_service.create_stream_resampler", create)
    service = Speech()
    assert not created
    resampler = service._resampler
    assert created == [resampler]
    assert service._resampler is resampler
    replacement = object()
    service._resampler = replacement
    assert service._resampler is replacement


async def test_matching_sample_rates_never_load_the_resampler(monkeypatch):
    def unavailable():
        raise AssertionError("Resampling must not load for matching audio formats")

    monkeypatch.setattr("pipecat.services.tts_service.create_stream_resampler", unavailable)
    service = Speech()
    service._sample_rate = 16000

    async def audio():
        yield b"\x00\x01" * 160

    frames = [
        frame
        async for frame in service._stream_audio_frames_from_iterator(audio(), in_sample_rate=16000)
    ]
    assert b"".join(frame.audio for frame in frames) == b"\x00\x01" * 160

"""SpellSpeak Audience on Core ML: the native tokenizer and models against the reference runtime."""

import re
import subprocess

import audience_package
import pytest
from mobile_app.duo import CAST
from support import CHECKS, ROOT, SOURCES, build_swift, needs_swift

FIXTURES = ROOT / "tests/fixtures/audience"
needs_models = pytest.mark.skipif(
    not (ROOT / audience_package.AUDIENCE_DIR / "coreml.json").exists(),
    reason="models/audience required",
)


def build(tmp_path, check, *sources):
    files = [*(SOURCES / name for name in sources), SOURCES / "SpeechSynthesis.swift"]
    return build_swift(tmp_path / check, [*files, CHECKS / f"{check}.swift"], "-O")


@needs_swift
@needs_models
def test_native_tokenizer_matches_the_tokenizers_library(tmp_path):
    binary = build(tmp_path, "AudienceTokenizerChecks", "AudienceTokenizer.swift")
    result = subprocess.run(
        [
            str(binary),
            str(ROOT / audience_package.AUDIENCE_DIR / "tokenizer.json"),
            str(FIXTURES / "tokenization.json"),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert "AUDIENCE_TOKENIZER_CHECKS_PASSED" in result.stdout


@needs_swift
@needs_models
def test_core_ml_answers_match_the_reference_runtime(tmp_path):
    compiled = audience_package.compile_audience(ROOT)
    binary = build(
        tmp_path, "AudienceModelChecks", "AudienceTokenizer.swift", "AudienceModel.swift"
    )
    result = subprocess.run(
        [str(binary), str(compiled), str(FIXTURES / "answers.json")],
        check=True,
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert "AUDIENCE_MODEL_CHECKS_PASSED" in result.stdout


def test_the_swift_cast_speaks_in_the_voices_python_chooses():
    source = (SOURCES / "DuoCharacter.swift").read_text()
    match = re.search(r'var voice: String \{ self == \.angel \? "([^"]+)" : "([^"]+)"', source)
    assert match is not None
    assert match.groups() == (CAST["angel"].voice, CAST["devil"].voice)

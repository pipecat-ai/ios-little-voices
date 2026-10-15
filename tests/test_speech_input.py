"""Exercise production microphone buffering with deterministic model stalls."""

import subprocess

from support import CHECKS, SOURCES, build_swift, needs_swift


@needs_swift
def test_microphone_asr_remains_independent_of_slow_vad(tmp_path):
    binary = build_swift(
        tmp_path / "speech-input-checks",
        [
            SOURCES / "SpeechAudioInput.swift",
            CHECKS / "SpeechInputChecks.swift",
        ],
        "-D",
        "DEBUG",
    )
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=15)
    assert "SPEECH_INPUT_CHECKS_PASSED" in result.stdout

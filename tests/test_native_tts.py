"""Run the platform-independent Swift TTS contract checks on macOS."""

import subprocess

from support import CHECKS, SOURCES, build_swift, needs_swift


@needs_swift
def test_swift_phonon_settings_and_cancellation(tmp_path):
    binary = build_swift(
        tmp_path / "tts-checks",
        [
            SOURCES / "SpeechSynthesis.swift",
            SOURCES / "VoiceSettings.swift",
            SOURCES / "DuoCharacter.swift",
            CHECKS / "TTSChecks.swift",
        ],
    )
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
    assert "Native TTS checks passed" in result.stdout

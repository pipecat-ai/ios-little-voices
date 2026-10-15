"""The human's words as recognized, through the app's Swift transcript model."""

import subprocess

from support import CHECKS, SOURCES, build_swift, needs_swift


@needs_swift
def test_live_and_final_speech_join_into_the_turns_words(tmp_path):
    binary = build_swift(
        tmp_path / "transcript-checks",
        [
            SOURCES / "ConversationTranscript.swift",
            CHECKS / "TranscriptChecks.swift",
        ],
    )
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
    assert "Native transcript checks passed" in result.stdout

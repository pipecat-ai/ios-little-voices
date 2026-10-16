"""Saved conversations: transcripts as heard, kept in files on the device."""

import subprocess

from support import CHECKS, SOURCES, build_swift, needs_swift


@needs_swift
def test_conversations_are_recorded_saved_and_deleted(tmp_path):
    binary = build_swift(
        tmp_path / "history-checks",
        [
            SOURCES / "DuoCharacter.swift",
            SOURCES / "ConversationHistory.swift",
            CHECKS / "HistoryChecks.swift",
        ],
        "-D",
        "DEBUG",
    )
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=30)
    assert "HISTORY_CHECKS_PASSED" in result.stdout

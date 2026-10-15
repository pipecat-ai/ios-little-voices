"""Verify foreground shortcut readiness and cancellation without microphone access."""

import subprocess

from support import CHECKS, SOURCES, build_swift, needs_swift


@needs_swift
def test_transient_conversation_launch_requests(tmp_path):
    binary = build_swift(
        tmp_path / "conversation-launch-checks",
        [
            SOURCES / "ConversationLaunchRequests.swift",
            CHECKS / "ConversationLaunchChecks.swift",
        ],
    )
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
    assert "Conversation launch checks passed" in result.stdout

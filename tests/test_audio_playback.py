"""Exercise native playback with an offline AVAudioEngine."""

import subprocess

from support import CHECKS, SOURCES, build_swift, needs_swift


@needs_swift
def test_playback_is_continuous_and_stops_and_restarts_cleanly(tmp_path):
    binary = build_swift(
        tmp_path / "playback-checks",
        [
            SOURCES / "PCMPlayer.swift",
            CHECKS / "PlaybackChecks.swift",
        ],
    )
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=20)
    assert "Native playback checks passed" in result.stdout

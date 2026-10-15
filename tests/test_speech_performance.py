"""Exercise native streaming measurements."""

import subprocess

import pytest
from support import CHECKS, SOURCES, build_swift, needs_swift


@needs_swift
@pytest.mark.parametrize("optimized", [False, True], ids=["debug", "optimized-debug"])
def test_streaming_performance_measurements(tmp_path, optimized):
    binary = build_swift(
        tmp_path / "performance-checks",
        [SOURCES / "SpeechStreamMetrics.swift", CHECKS / "PerformanceChecks.swift"],
        "-D",
        "DEBUG",
        "-O" if optimized else "-Onone",
    )
    result = subprocess.run(
        [str(binary), *([] if optimized else ["--expect-assertions"])],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert "Speech performance checks passed" in result.stdout

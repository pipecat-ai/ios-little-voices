"""Exercise cancellation-resistant native model work without model inference."""

import subprocess

from support import CHECKS, SOURCES, build_swift, needs_swift


@needs_swift
def test_native_model_work_drains_before_replacement(tmp_path):
    binary = build_swift(
        tmp_path / "model-work-checks",
        [
            SOURCES / "NativeModelWorkCoordinator.swift",
            CHECKS / "ModelWorkCoordinatorChecks.swift",
        ],
    )
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
    assert "MODEL_WORK_COORDINATOR_CHECKS_PASSED" in result.stdout

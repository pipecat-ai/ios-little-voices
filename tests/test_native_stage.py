"""Check the stage rig: springs, geometry, choreography, layout, pacing, cues, palette,
seeded random conversations, smoothness and the launch intro."""

import re
import subprocess

import pytest
from support import CHECKS, SOURCES, build_swift, needs_swift

# The Foundation-only rig sources, compiled together with the checks. The scripted
# conversations (StageScripts.swift) are DEBUG-only, so the checks build as DEBUG.
RIG = [
    "DuoCharacter.swift",
    "RigMath.swift",
    "FaceGeometry.swift",
    "FaceParameters.swift",
    "FaceExpressions.swift",
    "CaptionCues.swift",
    "CharacterDirector.swift",
    "FaceRig.swift",
    "SeamRig.swift",
    "StageLayout.swift",
    "StageIntro.swift",
    "StageSimulation.swift",
    "StageColors.swift",
    "StageScripts.swift",
]


@pytest.mark.parametrize("source", RIG)
def test_rig_sources_are_foundation_only(source):
    # Attributes (`@preconcurrency`, `@_exported`) and import kinds (`import struct …`) count too.
    pattern = r"^\s*(?:@\w+\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?(\w+)"
    imports = re.findall(pattern, (SOURCES / source).read_text(), re.MULTILINE)
    assert imports == ["Foundation"]


@needs_swift
def test_stage_rig(tmp_path):
    files = [*(SOURCES / source for source in RIG), CHECKS / "StageRigChecks.swift"]
    binary = build_swift(tmp_path / "stage-rig-checks", files, "-O", "-D", "DEBUG")
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stderr
    passed = re.search(r"^STAGE_RIG_CHECKS_PASSED: (.*)$", result.stdout, re.MULTILINE)
    assert passed, result.stdout
    sections = passed.group(1).split(", ")
    for section in [
        "springs",
        "cadence and determinism",
        "seam and anchor fidelity",
        "choreography",
        "layout matrix",
        "caption cues",
        "activity and idle",
        "idle drift",
        "Reduce Motion",
        "palette",
        "face fidelity",
        "squash and volume",
        "lip sync",
        "behaviour",
        "seeded stress",
        "smoothness",
        "intro",
    ]:
        assert section in sections

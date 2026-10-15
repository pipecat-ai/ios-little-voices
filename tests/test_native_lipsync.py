"""Check the Swift lip-sync port against the pipecat-visemes reference, its timeline, the
text-informed mouth (pronunciations, visemes and, given the Phonon clips, alignment), and the
mouth the stage draws from it."""

import subprocess

import pytest
from support import CHECKS, ROOT, SOURCES, build_swift, needs_swift

FIXTURE = ROOT / "tests/fixtures/lipsync"
# Phonon-voiced, so not in the repository: scripts/lipsync/make_fixtures.py writes them.
PHONON_CLIPS = [FIXTURE / "who-knew.wav", FIXTURE / "maybe-my-mommy.wav"]
LEXICON = SOURCES / "Assets.xcassets/Pronunciations.dataset/cmudict.lzma"
ANALYZER = ["LipsyncDSP.swift", "FormantLipsyncAnalyzer.swift"]
TEXT = [
    "LipsyncPhones.swift",
    "LipsyncAligner.swift",
    "LipsyncAlignerModel.swift",
    "LipsyncVisemes.swift",
]
TIMELINE = [*ANALYZER, "LipsyncResampler.swift", "LipsyncTimeline.swift", *TEXT]
# The stage's Foundation-only rig, which eases the lips and maps a pose onto each mouth.
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
    "StageSimulation.swift",
    "StageColors.swift",
]

pytestmark = needs_swift


def build(tmp_path, name, sources, checks, *flags):
    files = [*(SOURCES / source for source in sources), CHECKS / checks]
    # Accelerate's current LAPACK interface, as the app uses it.
    return build_swift(tmp_path / name, files, "-Xcc", "-DACCELERATE_NEW_LAPACK", *flags)


# The reference's defaults, and the dead band the app runs the analyzer with (every hop).
@pytest.mark.parametrize("expected", ["expected.json", "expected-dead-band-0.json"])
def test_swift_analyzer_matches_the_python_reference(tmp_path, expected):
    binary = build(tmp_path, "lipsync-checks", ANALYZER, "LipsyncChecks.swift")
    result = subprocess.run(
        [str(binary), str(FIXTURE / "speech.wav"), str(FIXTURE / expected)],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert "LIPSYNC_CHECKS_PASSED" in result.stdout


def test_lipsync_resampling_and_timeline(tmp_path):
    binary = build(tmp_path, "lipsync-timeline-checks", TIMELINE, "LipsyncTimelineChecks.swift")
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=30)
    assert "LIPSYNC_TIMELINE_CHECKS_PASSED" in result.stdout


def test_lipsync_drawn_mouth(tmp_path):
    binary = build(
        tmp_path, "lipsync-mouth-checks", [*TIMELINE, *RIG], "LipsyncMouthChecks.swift", "-O"
    )
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
    assert "LIPSYNC_MOUTH_CHECKS_PASSED" in result.stdout


@pytest.fixture(scope="module")
def text_checks(tmp_path_factory):
    tmp_path = tmp_path_factory.mktemp("text")
    return build(
        tmp_path, "lipsync-text-checks", [*TIMELINE, *RIG], "LipsyncTextChecks.swift", "-O"
    )


def run_text_checks(binary, *arguments):
    command = [str(binary), str(LEXICON), *map(str, arguments)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stderr
    return result.stdout


def test_lipsync_text(text_checks):
    """Pronunciations and visemes."""
    assert "LIPSYNC_TEXT_CHECKS_PASSED" in run_text_checks(text_checks)


@pytest.mark.skipif(
    not all(clip.exists() for clip in PHONON_CLIPS),
    reason="the Phonon-voiced clips are not in the repository: "
    "write them with `uv run --no-sync python scripts/lipsync/make_fixtures.py`",
)
def test_lipsync_alignment(text_checks):
    """Alignment of two Phonon sentences, the text track and the fallback to formants."""
    assert "LIPSYNC_ALIGNMENT_CHECKS_PASSED" in run_text_checks(text_checks, FIXTURE)

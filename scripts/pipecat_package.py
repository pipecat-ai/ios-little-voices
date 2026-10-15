"""Apply the app's patch to the pinned Pipecat release, for the tests and the app bundle."""

import hashlib
import json
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIPECAT_VERSION = "1.12.0"
PIPECAT_URL = (
    "https://files.pythonhosted.org/packages/10/fe/"
    "566fd73f43e66ce48b9a7e5dfa9cf79c713184978681708ac5c109c233ee/"
    "pipecat_ai-1.12.0-py3-none-any.whl"
)
PIPECAT_SHA256 = "4cd3dc071b7b64da7ac700a26a224b773ae6ef8d6694a4566332d2e5e39ed6d9"
PATCH = f"patches/pipecat-ai-{PIPECAT_VERSION}.patch"
# The patched package and its distribution metadata, on the tests' path and bundled by the app.
PIPECAT_DIR = ".build/pipecat-ai"
DIST_INFO = f"pipecat_ai-{PIPECAT_VERSION}.dist-info"
STAMP = ".patched.json"
PREPARE = "uv run --no-sync python scripts/setup.py --pipecat-only"


def _stamp(root: Path) -> dict:
    return {
        "release": PIPECAT_SHA256,
        "patch": hashlib.sha256((root / PATCH).read_bytes()).hexdigest(),
    }


def patch_pipecat(wheel: Path, root: Path = ROOT) -> Path:
    """Unpack the release wheel into .build/pipecat-ai and apply the app's patch to it.

    Args:
        wheel: The downloaded release wheel.
        root: The repository.

    Returns:
        The patched package's directory.
    """
    if hashlib.sha256(wheel.read_bytes()).hexdigest() != PIPECAT_SHA256:
        raise RuntimeError(
            f"{wheel} is not the pipecat-ai {PIPECAT_VERSION} release this app pins. "
            "Delete it and run setup again."
        )
    target = root / PIPECAT_DIR
    staging = target.with_name(target.name + ".partial")
    shutil.rmtree(staging, ignore_errors=True)
    with zipfile.ZipFile(wheel) as archive:
        archive.extractall(staging)
    result = subprocess.run(
        ["patch", "--batch", "--fuzz=0", "-p1", "-d", str(staging), "-i", str(root / PATCH)],
        capture_output=True,
        text=True,
    )
    if result.returncode:
        shutil.rmtree(staging)
        raise RuntimeError(
            f"{PATCH} does not apply to pipecat-ai {PIPECAT_VERSION}:\n"
            f"{result.stdout}{result.stderr}"
        )
    (staging / STAMP).write_text(json.dumps(_stamp(root), indent=2) + "\n")
    shutil.rmtree(target, ignore_errors=True)
    staging.rename(target)
    return target


def validate_pipecat(root: Path = ROOT) -> Path:
    """Return the patched package's directory, or explain how to prepare it.

    Args:
        root: The repository.
    """
    target = root / PIPECAT_DIR
    try:
        stamp = json.loads((target / STAMP).read_text())
    except (OSError, ValueError):
        stamp = None
    if stamp != _stamp(root):
        raise RuntimeError(
            f"{PIPECAT_DIR} is missing, or predates {PATCH} or the pinned release. Run: {PREPARE}"
        )
    return target

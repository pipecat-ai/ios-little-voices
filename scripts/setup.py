#!/usr/bin/env python3
"""Fetch pinned dependencies, patch Pipecat, cross-compile native code, and prepare Xcode."""

import argparse
import hashlib
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

from audience_package import validate_audience
from build_native import PYDANTIC_CORE_VERSION, TARGETS
from phonon_package import validate_phonon
from pipecat_package import PIPECAT_SHA256, PIPECAT_URL, patch_pipecat

ROOT = Path(__file__).resolve().parents[1]
DOWNLOADS = ROOT / ".build/downloads"
PYTHON_URL = "https://github.com/beeware/Python-Apple-support/releases/download/3.13-b14/Python-3.13-iOS-support.b14.tar.gz"
PYTHON_SHA256 = "8b5cb76ef8d8a2946052479358eeec9d54b4496cb60920e175ec1489b5cf7963"
CORE_URL = "https://files.pythonhosted.org/packages/af/f9/8a06bea35ef8daf588f707784c973a7046e0034c8d8cfb08828eeffb8b75/pydantic_core-2.46.5.tar.gz"
CORE_SHA256 = "10416c15b8839ecc4ef4d0885da76da6fd0f67333a0eb8aff6d93c4b8f2910fc"


def fetch(url: str, digest: str) -> Path:
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    archive = DOWNLOADS / url.rsplit("/", 1)[1]
    if not archive.exists():
        print(f"Downloading {archive.name}", flush=True)
        temporary = archive.with_suffix(".partial")
        urllib.request.urlretrieve(url, temporary)
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise SystemExit(f"{archive} does not match its pinned SHA-256. Delete it and run again.")
    return archive


def run(*args):
    subprocess.run(list(map(str, args)), cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["device", "simulator", "all"], default="all")
    parser.add_argument(
        "--pipecat-only", action="store_true", help="prepare only the patched Pipecat the tests use"
    )
    args = parser.parse_args()
    if sys.version_info[:2] != (3, 13):
        raise SystemExit("Run with Python 3.13: uv run --no-sync python scripts/setup.py")
    try:
        patch_pipecat(fetch(PIPECAT_URL, PIPECAT_SHA256), ROOT)
    except RuntimeError as exc:
        raise SystemExit(str(exc)) from exc
    if args.pipecat_only:
        return
    try:
        validate_phonon(ROOT)
        validate_audience(ROOT)
    except RuntimeError as exc:
        raise SystemExit(str(exc)) from exc
    if not (ROOT / "Vendor/Python.xcframework").exists():
        (ROOT / "Vendor").mkdir(exist_ok=True)
        with tarfile.open(fetch(PYTHON_URL, PYTHON_SHA256)) as archive:
            members = [
                member
                for member in archive.getmembers()
                if member.name.startswith("Python.xcframework/") or member.name == "VERSIONS"
            ]
            archive.extractall(ROOT / "Vendor", members=members, filter="data")
    if not (ROOT / f".build/pydantic_core-{PYDANTIC_CORE_VERSION}").exists():
        with tarfile.open(fetch(CORE_URL, CORE_SHA256)) as archive:
            archive.extractall(ROOT / ".build", filter="data")
    run("rustup", "target", "add", *(target for target, _, _ in TARGETS.values()))
    run(sys.executable, ROOT / "scripts/build_native.py", "--platform", args.platform)
    run(sys.executable, ROOT / "scripts/stage_python.py")
    run(sys.executable, ROOT / "scripts/generate_project.py")
    print("Ready: open PipecatVoice.xcodeproj, select your development team, and run on an iPhone.")


if __name__ == "__main__":
    main()

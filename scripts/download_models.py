#!/usr/bin/env python3
"""Download the app's models from Hugging Face, each pinned to one commit: Gradium's Phonon 31m
into models/phonon, and Pipecat Audience's Core ML package into models/audience.

    python3 scripts/download_models.py

Only the files the app runs are fetched, and each is checked against its pinned SHA-256. Files
already in place and matching are kept, so running it again downloads nothing.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import urllib.request
from pathlib import Path

from audience_package import AUDIENCE_DIR, AUDIENCE_RELEASE, AUDIENCE_REPO, AUDIENCE_REVISION
from phonon_package import PHONON_MODEL, PHONON_REPO, PHONON_REVISION

ROOT = Path(__file__).resolve().parents[1]
# Each model's repo, commit, folder in the repo and folder here, with the SHA-256 at that commit
# of each file the app needs.
MODELS = {
    PHONON_MODEL: (
        PHONON_REPO,
        PHONON_REVISION,
        "",
        "models/phonon",
        {
            "config.json": "7062ea376e6b158543c8abec8e5af67df171c49ad70eb7e2a0fb25c16f265e06",
            "model.q8.gguf": "a7d9aad2cd6dc66473f24a08bc6d2939030ef4d751ef82349361fbef3272dbae",
            "tokenizer.json": "691a00068fa7b989f2f3e5ae5daa2d1a5bb319f2d5360deafcfb19a8bb6e7936",
        },
    ),
    f"Pipecat Audience {AUDIENCE_RELEASE}": (
        AUDIENCE_REPO,
        AUDIENCE_REVISION,
        "coreml/",
        AUDIENCE_DIR,
        {
            "AudienceEncoder.mlpackage/Manifest.json": (
                "db5e801993d66912a5599f522b3539cc3e40926ee2e6e3dd4043611b811f1534"
            ),
            "AudienceEncoder.mlpackage/Data/com.apple.CoreML/model.mlmodel": (
                "93176efd4db7844b6d04f0b936ab2f2a5c3b480c5de2daf2b4174e27e160b213"
            ),
            "AudienceEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin": (
                "50ec1d5363b580019111ae26ed920532ed0c20baa3ac81bb63bbefdc8a1d0ee0"
            ),
            "AudienceHead.mlpackage/Manifest.json": (
                "3cf61dd9ada58a6b34086bf1796482b41be14f1ccbef921670c864d2b84cd31e"
            ),
            "AudienceHead.mlpackage/Data/com.apple.CoreML/model.mlmodel": (
                "9caaa51e0d593d753fddb03a53e62b85db871933231cb518cbbd2c1f5d43fe65"
            ),
            "AudienceHead.mlpackage/Data/com.apple.CoreML/weights/weight.bin": (
                "3d5cd2e1211b2edcbae5dcfc6c7760f9b6a3aa629cb50220b976caa9e99673e4"
            ),
            "config.json": "91460ca6cff39af841f0cf6396aacd834b5acc81d485d1daa7a767d04471cbfd",
            "coreml.json": "2417a8a982bc55fa9454b6c9170ca610d75043f2d27aab3bc85d1be39ea83fa2",
            "tokenizer.json": "82d1ca5ef2019321c91a01b78653345e6fe8ef25a38b7d83f7857c380649c7cf",
        },
    ),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while chunk := file.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def model_id(config: Path) -> str | None:
    """A Phonon checkpoint's `sig@epoch`, as its config records it."""
    try:
        identity = json.loads(config.read_text())["model_id"]
        return f"{identity['sig']}@{identity['epoch']}"
    except (OSError, ValueError, KeyError, TypeError):
        return None


def download(url: str, target: Path, digest: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f"{target.name}.partial")
    with urllib.request.urlopen(url) as response, temporary.open("wb") as file:
        shutil.copyfileobj(response, file, 1 << 20)
    if sha256(temporary) != digest:
        temporary.unlink()
        raise SystemExit(f"{url} does not match its pinned SHA-256.")
    temporary.replace(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument(
        "--replace", action="store_true", help="overwrite another model in the models' folders"
    )
    args = parser.parse_args()
    # A folder that holds another model is left alone, unless --replace, before anything downloads.
    for _, _, _, folder, files in MODELS.values():
        config = ROOT / folder / "config.json"
        if config.is_file() and sha256(config) != files["config.json"] and not args.replace:
            found = model_id(config)
            raise SystemExit(
                f"{folder}/ holds another model{f' ({found})' if found else ''}. "
                "Move it aside, or pass --replace to overwrite its files."
            )
    for name, (repo, revision, prefix, folder, files) in MODELS.items():
        for path, digest in files.items():
            target = ROOT / folder / path
            if not (target.is_file() and sha256(target) == digest):
                print(f"Downloading {folder}/{path}", flush=True)
                url = f"https://huggingface.co/{repo}/resolve/{revision}/{prefix}{path}"
                download(url, target, digest)
        print(f"{name} ({repo}@{revision[:8]}) is in {folder}/.")


if __name__ == "__main__":
    main()

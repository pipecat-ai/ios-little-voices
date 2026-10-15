"""Phonon speech for the lip-sync scripts, measured exactly as the app measures it: Speech.swift is
compiled with the app's own lip-sync sources and drives a build of the app's phonon-ffi for this
Mac. Needs Xcode, a Rust toolchain and the Phonon checkpoint in models/phonon.
"""

import json
import os
import platform
import subprocess
import sys
from array import array
from functools import cache
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CHECKPOINT = ROOT / "models/phonon"
LEXICON = ROOT / "src/ios/PipecatVoice/Assets.xcassets/Pronunciations.dataset/cmudict.lzma"
BUILD = ROOT / ".build/lipsync"
RUST = ROOT / ".build/rust"
APP_SOURCES = [
    "LipsyncDSP",
    "LipsyncResampler",
    "LipsyncPhones",
    "LipsyncAligner",
    "LipsyncAlignerModel",
]


@cache
def tool() -> Path:
    """Build phonon-ffi for this Mac, then Speech.swift against it unless the build is current."""
    if not (CHECKPOINT / "config.json").exists():
        sys.exit(f"No Phonon checkpoint in {CHECKPOINT}; see models/README.txt.")
    manifest = ROOT / "native/phonon-ffi/Cargo.toml"
    env = {**os.environ, "CARGO_TARGET_DIR": str(RUST)}
    cargo = ["cargo", "build", "--release", "--locked", "--manifest-path", str(manifest)]
    subprocess.run(cargo, env=env, check=True)
    library = RUST / "release/libphonon_ffi.a"
    sources = [ROOT / f"src/ios/PipecatVoice/{name}.swift" for name in APP_SOURCES]
    sources.append(HERE / "Speech.swift")
    binary = BUILD / "speech"
    newest = max(path.stat().st_mtime for path in [*sources, library])
    if binary.exists() and binary.stat().st_mtime > newest:
        return binary
    BUILD.mkdir(parents=True, exist_ok=True)
    swiftc = [
        *("xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library"),
        *("-target", f"{platform.machine()}-apple-macos27.0"),
        *("-module-cache-path", str(BUILD / "ModuleCache"), "-Xcc", "-DACCELERATE_NEW_LAPACK"),
        *("-import-objc-header", str(ROOT / "native/phonon-ffi/include/phonon.h")),
        *map(str, sources),
        *(str(library), "-framework", "Metal", "-framework", "Security", "-lc++"),
        *("-o", str(binary)),
    ]
    subprocess.run(swiftc, check=True)
    return binary


def pcm(voice: str, text: str) -> array:
    """`text` spoken in `voice`: 24 kHz mono float samples."""
    command = [tool(), "pcm", CHECKPOINT, voice, text]
    samples = array("f")
    samples.frombytes(subprocess.run(command, stdout=subprocess.PIPE, check=True).stdout)
    return samples


def features(voice: str, sentences: list[str]) -> list[dict]:
    """For each sentence spoken in `voice`: its words (`phones`, `pause`) and `hops`, each hop's
    level, zero-crossing rate and cepstra c1…c12 as LipsyncAlignerFeatures measures them."""
    command = [tool(), "features", CHECKPOINT, LEXICON, voice, *sentences]
    return json.loads(subprocess.run(command, stdout=subprocess.PIPE, check=True).stdout)

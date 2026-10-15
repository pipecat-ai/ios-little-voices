#!/usr/bin/env python3
"""Stage Pipecat's mobile dependency closure using the resolved host versions.

Only pydantic-core needs a native extension. Its host binary is excluded here
and replaced with the iOS binary by bundle_runtime.py, which also adds the
patched Pipecat.
"""

import importlib.metadata
import json
import shutil
from pathlib import Path

from build_native import PYDANTIC_CORE_VERSION

ROOT = Path(__file__).resolve().parents[1]
DISTRIBUTIONS = [
    "annotated-types",
    # Pipecat's worker observer imports attrs, which pipecat-ai doesn't declare.
    "attrs",
    "docstring-parser",
    "loguru",
    "Markdown",
    "pydantic",
    "pydantic-core",
    "typing-extensions",
    "typing-inspection",
    "websockets",
]


def main():
    destination = ROOT / ".build/python-packages"
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    manifest = {}
    for name in DISTRIBUTIONS:
        dist = importlib.metadata.distribution(name)
        manifest[name] = dist.version
        for file in dist.files or []:
            path = Path(str(file))
            if ".." in path.parts or path.suffix in {".so", ".dylib", ".pyc"}:
                continue
            source = Path(dist.locate_file(file))
            if source.is_file():
                target = destination / path
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
    if manifest["pydantic-core"] != PYDANTIC_CORE_VERSION:
        raise RuntimeError("Update the native pydantic-core build to match the locked dependency.")
    (ROOT / ".build/mobile-package-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Staged {len(manifest)} mobile dependencies")


if __name__ == "__main__":
    main()

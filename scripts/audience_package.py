"""Validate Pipecat Audience's Core ML package and compile it for the app."""

import hashlib
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUDIENCE_RELEASE = "rc2.1"
# The release's commit in its Hugging Face repo, whose coreml/ holds the Core ML package
# (scripts/download_models.py fetches it).
AUDIENCE_REPO = "pipecat-ai/audience"
AUDIENCE_REVISION = "979a299867fffd08093bcfb52ab821f5688c48cd"
AUDIENCE_DIR = "models/audience"
MODELS = ("AudienceEncoder.mlpackage", "AudienceHead.mlpackage")
DATA = ("tokenizer.json", "config.json", "coreml.json")
DOWNLOAD = "To download it, run python3 scripts/download_models.py"


def validate_audience(root: Path = ROOT) -> dict:
    """Return the package's Core ML manifest, or explain what is missing."""
    package = root / AUDIENCE_DIR
    missing = [name for name in MODELS if not (package / name).is_dir()]
    missing += [name for name in DATA if not (package / name).is_file()]
    if missing:
        raise RuntimeError(
            f"Pipecat Audience {AUDIENCE_RELEASE} on Core ML is required in {AUDIENCE_DIR}/. "
            f"Missing: {', '.join(missing)}. {DOWNLOAD}"
        )
    manifest = json.loads((package / "coreml.json").read_text())
    config = json.loads((package / "config.json").read_text())
    if (
        manifest.get("release") != AUDIENCE_RELEASE
        or config.get("render_version") != "addressee-tt-0.6"
    ):
        raise RuntimeError(
            f"{AUDIENCE_DIR}/ holds Audience {manifest.get('release')!r}; the app's request code is "
            f"{AUDIENCE_RELEASE}'s. {DOWNLOAD}"
        )
    return manifest


def compile_audience(root: Path = ROOT) -> Path:
    """The package with its models compiled (`.mlmodelc`), reused while the package is unchanged."""
    validate_audience(root)
    package = root / AUDIENCE_DIR
    digest = hashlib.sha256((package / "coreml.json").read_bytes()).hexdigest()[:16]
    out = root / ".build/audience" / digest
    if not (out / "complete").exists():
        if out.exists():
            shutil.rmtree(out)
        out.mkdir(parents=True)
        for name in MODELS:
            subprocess.run(
                ["xcrun", "coremlcompiler", "compile", str(package / name), str(out)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        for name in DATA:
            shutil.copy2(package / name, out / name)
        (out / "complete").write_text(digest + "\n")
    return out


def bundle_audience(bundle: Path, root: Path = ROOT) -> None:
    """Copy the compiled models and their tokenizer and config into the app as `audience/`."""
    compiled = compile_audience(root)
    target = bundle / "audience"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(compiled, target, ignore=shutil.ignore_patterns("complete"))

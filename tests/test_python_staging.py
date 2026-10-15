"""Reject stale dependency snapshots before app builds overlay new Pipecat code."""

import json

import bundle_runtime
import pytest


@pytest.fixture
def staged(tmp_path, monkeypatch):
    monkeypatch.setattr(bundle_runtime, "DISTRIBUTIONS", ["Markdown", "typing-extensions"])
    packages = tmp_path / ".build/python-packages"
    packages.mkdir(parents=True)
    manifest = {"Markdown": "3.10.3", "typing-extensions": "4.16.0"}
    for name, version, module in [
        ("Markdown", "3.10.3", "markdown/__init__.py"),
        ("typing_extensions", "4.16.0", "typing_extensions.py"),
    ]:
        source = packages / module
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text("# Fixture Python module\n")
        info = packages / f"{name}-{version}.dist-info"
        info.mkdir()
        (info / "METADATA").write_text(f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n")
        (info / "RECORD").write_text(f"{module},,\n{module}c,,\n../../bin/tool.py,,\n")
    manifest_path = tmp_path / ".build/mobile-package-manifest.json"
    manifest_path.write_text(json.dumps(manifest))
    return tmp_path, packages, manifest_path, manifest


def test_staged_versions_and_python_files_accept_the_declared_dependency_closure(staged):
    root, _, _, _ = staged
    bundle_runtime.validate_staged_packages(root=root)


def test_new_declared_dependency_requires_restaging_even_if_snapshot_exists(staged):
    root, _, manifest_path, manifest = staged
    del manifest["Markdown"]
    manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(SystemExit, match="Markdown.*scripts/stage_python.py"):
        bundle_runtime.validate_staged_packages(root=root)


@pytest.mark.parametrize("failure", ["metadata_missing", "version_changed", "python_missing"])
def test_incomplete_snapshot_is_rejected_before_bundling(staged, failure):
    root, packages, _, _ = staged
    info = packages / "Markdown-3.10.3.dist-info/METADATA"
    if failure == "metadata_missing":
        info.unlink()
    elif failure == "version_changed":
        info.write_text("Metadata-Version: 2.1\nName: Markdown\nVersion: 3.9\n")
    else:
        (packages / "markdown/__init__.py").unlink()
    with pytest.raises(SystemExit, match="Markdown.*scripts/stage_python.py"):
        bundle_runtime.validate_staged_packages(root=root)


@pytest.mark.parametrize("contents", [None, "not JSON", "[]"])
def test_missing_or_invalid_staging_manifest_reports_rebuild_command(staged, contents):
    root, _, manifest_path, _ = staged
    if contents is None:
        manifest_path.unlink()
    else:
        manifest_path.write_text(contents)
    with pytest.raises(SystemExit, match="scripts/stage_python.py"):
        bundle_runtime.validate_staged_packages(root=root)


def test_the_bundle_leaves_out_the_standard_library_the_app_never_imports(tmp_path):
    python = tmp_path / "Python.xcframework"
    stdlib = python / "lib/python3.13"
    for module in [
        "json/__init__.py",
        "asyncio/__init__.py",
        "asyncio/sslproto.py",
        "zipfile/__init__.py",
        "ssl.py",
        "bz2.py",
        "unittest/__init__.py",
        "sqlite3/__init__.py",
        "test/test_json.py",
        "idlelib/idle.py",
        "email/test.py",
    ]:
        (stdlib / module).parent.mkdir(parents=True, exist_ok=True)
        (stdlib / module).write_text("# Fixture Python module\n")
    dynload = python / "ios-arm64/lib-arm64/python3.13/lib-dynload"
    dynload.mkdir(parents=True)
    for name in ["_json", "_sha2", "_ssl", "_hashlib", "_bz2", "_codecs_jp", "_testcapi"]:
        (dynload / f"{name}.cpython-313-iphoneos.so").write_bytes(b"")

    target = tmp_path / "bundle/python/lib"
    bundle_runtime.copy_stdlib(python, "ios-arm64", target)

    copied = sorted(
        path.relative_to(target / "python3.13").as_posix()
        for path in target.rglob("*")
        if path.is_file()
    )
    # Only top-level names are left out: a package's own module named like one stays.
    assert copied == [
        "asyncio/__init__.py",
        "asyncio/sslproto.py",
        "email/test.py",
        "json/__init__.py",
        "lib-dynload/_json.cpython-313-iphoneos.so",
        "lib-dynload/_sha2.cpython-313-iphoneos.so",
        "zipfile/__init__.py",
    ]


def test_the_bundle_keeps_the_pipecat_modules_the_app_could_import(tmp_path):
    app = tmp_path / "src/python/mobile_app"
    pipecat = tmp_path / ".build/pipecat-ai/pipecat"
    for module, source in {
        "__init__.py": "from pipecat.version import VERSION\n",
        "version.py": "VERSION = 1\n",
        "services/__init__.py": "",
        "services/llm.py": (
            "from typing import TYPE_CHECKING\n"
            "from .settings import Settings\n"
            "if TYPE_CHECKING:\n"
            "    from pipecat.services.openai import Client\n"
            "def resample():\n"
            "    from ..audio import soxr\n"
        ),
        "services/settings.py": "",
        "services/openai.py": "",
        "audio/__init__.py": "",
        "audio/soxr.py": "",
        "runner/__init__.py": "",
        "runner/run.py": "import pipecat.services.llm\n",
    }.items():
        (pipecat / module).parent.mkdir(parents=True, exist_ok=True)
        (pipecat / module).write_text(source)
    app.mkdir(parents=True)
    (app / "bot.py").write_text("from pipecat.services.llm import LLM\n")

    kept = bundle_runtime.pipecat_modules(tmp_path / "src/python", pipecat)

    assert sorted(path.relative_to(pipecat).as_posix() for path in kept) == [
        "__init__.py",
        "audio/__init__.py",
        "audio/soxr.py",
        "services/__init__.py",
        "services/llm.py",
        "services/settings.py",
        "version.py",
    ]

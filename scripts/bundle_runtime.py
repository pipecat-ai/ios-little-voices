#!/usr/bin/env python3
"""Xcode build phase: bundle the Python the app imports, with extensions as signed frameworks."""

from __future__ import annotations

import ast
import csv
import json
import os
import plistlib
import re
import shutil
import subprocess
import time
from importlib import metadata
from pathlib import Path

from audience_package import bundle_audience
from build_native import TARGETS
from phonon_package import PHONON_FILES, validate_phonon, voice_files
from pipecat_package import DIST_INFO, validate_pipecat
from stage_python import DISTRIBUTIONS

ROOT = Path(__file__).resolve().parents[1]


def validate_staged_packages(*, root: Path = ROOT) -> None:
    """Reject stale or incomplete dependencies before copying current Python code."""
    command = "uv run --no-sync python scripts/stage_python.py"
    manifest_path = root / ".build/mobile-package-manifest.json"
    packages = root / ".build/python-packages"
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, ValueError) as exc:
        raise SystemExit(f"Missing or invalid staged Python manifest. Run: {command}") from exc
    if not isinstance(manifest, dict):
        raise SystemExit(f"Invalid staged Python manifest. Run: {command}")

    def normalized(name: str) -> str:
        return re.sub(r"[-_.]+", "-", name).lower()

    recorded = {normalized(name): version for name, version in manifest.items()}
    staged = list(metadata.distributions(path=[str(packages)]))
    problems = []
    for name in DISTRIBUTIONS:
        version = recorded.get(normalized(name))
        matches = [
            dist for dist in staged if normalized(dist.metadata.get("Name", "")) == normalized(name)
        ]
        if not isinstance(version, str) or len(matches) != 1 or matches[0].version != version:
            problems.append(f"{name}: missing or mismatched staged version")
            continue
        record = matches[0].read_text("RECORD")
        if record is None:
            problems.append(f"{name}: missing staged file record")
            continue
        for entry in csv.reader(record.splitlines()):
            if not entry:
                continue
            path = Path(entry[0])
            if path.suffix == ".py" and not path.is_absolute() and ".." not in path.parts:
                if not (packages / path).is_file():
                    problems.append(f"{name}: missing {path}")
    if problems:
        raise SystemExit(
            f"Staged Python dependencies are stale or incomplete: {'; '.join(problems)}. "
            f"Run: {command}"
        )


COPY_IGNORED = (
    *("__pycache__", "*.pyc", ".DS_Store", "libpython*.dylib"),
    # Sources, stubs, docs and build records that nothing imports.
    *("*.pyi", "*.c", "*.rst", "*.bat", "README.ctypes", "fetch_macholib", "sboms"),
)
# Standard-library modules the app never imports (check with PYTHON_MODULES, docs/native-tts.md).
# The modules it does import reach these only from features it never calls (help(), breakpoint(),
# FTP URLs, compressed logs, command-line interfaces), or import them only if they can (bz2, lzma).
UNUSED_STDLIB = frozenset(
    {
        *("test", "idlelib", "tkinter", "turtle", "turtledemo", "ensurepip", "venv"),
        *("__hello__", "__phello__", "antigravity", "this", "_android_support"),
        "ssl",
        *("bz2", "lzma", "gzip", "tarfile", "_compression", "zipapp"),
        *("pydoc", "pydoc_data", "pdb", "bdb", "doctest", "unittest", "_pyrepl", "rlcompleter"),
        *("code", "codeop", "cmd", "curses", "tty", "pty", "timeit", "trace", "profile"),
        *("cProfile", "pstats", "tabnanny", "pyclbr", "symtable", "modulefinder", "compileall"),
        *("py_compile", "runpy", "pkgutil", "argparse", "optparse", "getopt", "gettext"),
        *("pprint", "pickletools", "shlex", "_pyio", "sre_compile", "sre_constants", "sre_parse"),
        *("sqlite3", "dbm", "shelve", "smtplib", "imaplib", "poplib", "mailbox", "ftplib"),
        *("netrc", "getpass", "socketserver", "wsgiref", "xmlrpc", "mimetypes", "webbrowser"),
        *("configparser", "tomllib", "graphlib", "sched", "filecmp", "fileinput", "colorsys"),
        "statistics",
    }
)
# Extension modules the app never imports. Without _hashlib, hashlib uses CPython's own hashes; the
# app's text is UTF-8, so it needs no CJK codecs.
UNUSED_EXTENSIONS = frozenset(
    {
        *("_ssl", "_hashlib", "_bz2", "_lzma", "_sqlite3", "_dbm", "_lsprof", "_statistics"),
        *("_codecs_cn", "_codecs_hk", "_codecs_iso2022", "_codecs_jp", "_codecs_kr"),
        *("_codecs_tw", "_multibytecodec", "_interpchannels", "_interpqueues", "_interpreters"),
        *("cmath", "resource", "termios", "_ctypes_test", "_xxtestfuzz", "xxlimited"),
        *("xxlimited_35", "xxsubtype"),
    }
)


def copy_tree(source: Path, target: Path):
    shutil.copytree(
        source, target, dirs_exist_ok=True, ignore=shutil.ignore_patterns(*COPY_IGNORED)
    )


def copy_stdlib(python: Path, slice_name: str, target: Path) -> None:
    """Copy the standard library and the slice's extension modules, without the unused parts."""
    ignored = shutil.ignore_patterns(*COPY_IGNORED)

    def ignore(directory: str, names: list[str]) -> set[str]:
        skipped = set(ignored(directory, names))
        if Path(directory).name == "python3.13":
            skipped.update(name for name in names if name.removesuffix(".py") in UNUSED_STDLIB)
        elif Path(directory).name == "lib-dynload":
            for name in names:
                module = name.split(".")[0]
                if module in UNUSED_EXTENSIONS or module.startswith("_test"):
                    skipped.add(name)
        return skipped

    for source in (python / "lib", python / slice_name / "lib-arm64"):
        shutil.copytree(source, target, dirs_exist_ok=True, ignore=ignore)


def imported_modules(path: Path, package: str) -> set[str]:
    """Every name a source file imports, at any depth except under ``if TYPE_CHECKING:``.

    Args:
        path: The source file.
        package: The package its relative imports resolve against.

    Returns:
        Each imported module, and each name imported from one, which may be a module too.
    """
    found: set[str] = set()

    def visit(node: ast.AST) -> None:
        if isinstance(node, ast.If) and "TYPE_CHECKING" in {
            getattr(node.test, "id", None),
            getattr(node.test, "attr", None),
        }:
            for child in node.orelse:
                visit(child)
            return
        if isinstance(node, ast.Import):
            found.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            base = node.module or ""
            if node.level:
                parts = package.split(".")
                parts = parts[: len(parts) - node.level + 1]
                base = ".".join([*parts, *([node.module] if node.module else [])])
            found.add(base)
            found.update(f"{base}.{alias.name}" for alias in node.names)
        for child in ast.iter_child_nodes(node):
            visit(child)

    visit(ast.parse(path.read_text(encoding="utf-8")))
    return found


def pipecat_modules(app: Path, pipecat: Path) -> set[Path]:
    """Pipecat's source files the app could import.

    Follows every import of the app's own modules into Pipecat, and every import of those
    Pipecat modules in turn, including those inside functions, so a module imported only on
    use is kept; the packages containing each module come with it.

    Args:
        app: The app's Python source (``src/python``).
        pipecat: Pipecat's package directory.

    Returns:
        The Pipecat source files to bundle.
    """
    files: dict[str, Path] = {}
    for path in pipecat.rglob("*.py"):
        parts = list(path.relative_to(pipecat.parent).with_suffix("").parts)
        if parts[-1] == "__init__":
            parts.pop()
        files[".".join(parts)] = path
    pending = [name for path in app.rglob("*.py") for name in imported_modules(path, "")]
    kept: set[str] = set()
    while pending:
        parts = pending.pop().split(".")
        if parts[0] != pipecat.name:
            continue
        for end in range(1, len(parts) + 1):
            name = ".".join(parts[:end])
            if name in files and name not in kept:
                kept.add(name)
                package = name if files[name].name == "__init__.py" else name.rpartition(".")[0]
                pending.extend(imported_modules(files[name], package))
    return {files[name] for name in kept}


def bundle_models(bundle: Path, *, root: Path = ROOT) -> None:
    """Copy the Phonon checkpoint with only the cast's voices, from src/voices."""
    validate_phonon(root)
    target = bundle / "phonon"
    if target.exists():
        shutil.rmtree(target)
    (target / "voices").mkdir(parents=True)
    for name in PHONON_FILES:
        shutil.copy2(root / "models/phonon" / name, target / name)
    for voice in voice_files(root):
        shutil.copy2(voice, target / "voices" / voice.name)


def main():
    bundle = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["WRAPPER_NAME"]
    simulator = os.environ["PLATFORM_NAME"] == "iphonesimulator"
    rust_target, sdk, slice_name = TARGETS["simulator" if simulator else "device"]
    python = ROOT / "Vendor/Python.xcframework"
    required = [
        ROOT / ".build/python-packages",
        python,
        ROOT / f".build/rust/{rust_target}/release/lib_pydantic_core.dylib",
    ]
    for path in required:
        if not path.exists():
            raise SystemExit(f"Missing {path}. Run: uv run --no-sync python scripts/setup.py")
    validate_staged_packages()
    try:
        source = validate_pipecat()
        bundle_models(bundle)
        bundle_audience(bundle)
    except RuntimeError as exc:
        raise SystemExit(str(exc)) from exc
    shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", bundle / "THIRD_PARTY_NOTICES.md")
    for name in ["python", "python-app", "python-packages"]:
        path = bundle / name
        if path.exists():
            shutil.rmtree(path)
    copy_stdlib(python, slice_name, bundle / "python/lib")
    copy_tree(ROOT / "src/python", bundle / "python-app")
    copy_tree(ROOT / ".build/python-packages", bundle / "python-packages")
    # The patched Pipecat, but only the modules the app could import.
    copy_tree(source / DIST_INFO, bundle / "python-packages" / DIST_INFO)
    for module in pipecat_modules(ROOT / "src/python", source / "pipecat"):
        target = bundle / "python-packages" / module.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(module, target)
    core = bundle / f"python-packages/pydantic_core/_pydantic_core.cpython-313-{sdk}.so"
    shutil.copy2(required[-1], core)

    frameworks = bundle / "Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    # An earlier build's extension frameworks, which may hold modules no longer bundled.
    for framework in frameworks.glob("*.framework"):
        if (framework / f"{framework.stem}.origin").exists():
            shutil.rmtree(framework)
    for base in [bundle / "python/lib/python3.13/lib-dynload", bundle / "python-packages"]:
        for extension in base.rglob("*.so"):
            relative = extension.relative_to(base)
            name = ".".join([*relative.parts[:-1], relative.name.split(".")[0]])
            framework = frameworks / f"{name}.framework"
            framework.mkdir(exist_ok=True)
            executable = framework / name
            shutil.move(extension, executable)
            marker = extension.with_suffix(".fwork")
            marker.write_text(str(executable.relative_to(bundle)) + "\n")
            (framework / f"{name}.origin").write_text(str(marker.relative_to(bundle)) + "\n")
            info = {
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": name,
                "CFBundleIdentifier": f"ai.pipecat.littlevoices.python.{name.replace('_', '-')}",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": name,
                "CFBundlePackageType": "FMWK",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "MinimumOSVersion": os.environ["IPHONEOS_DEPLOYMENT_TARGET"],
                "CFBundleSupportedPlatforms": ["iPhoneSimulator" if simulator else "iPhoneOS"],
            }
            (framework / "Info.plist").write_bytes(plistlib.dumps(info))
            subprocess.run(
                ["install_name_tool", "-id", f"@rpath/{name}.framework/{name}", str(executable)],
                check=True,
            )
            identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
            if simulator or os.environ.get("CODE_SIGNING_ALLOWED") != "NO":
                subprocess.run(
                    ["codesign", "--force", "--sign", identity, "--timestamp=none", str(framework)],
                    check=True,
                    stderr=subprocess.DEVNULL,
                )
    # Declared as a build-phase output inside the app so Xcode signs the changed
    # resources even when no Swift/Objective-C compilation or linking was needed.
    (bundle / "PythonRuntime.stamp").write_text(f"{time.time_ns()}\n")
    print("Bundled embedded Python, Pipecat mobile runtime, Phonon voice assets and Audience")


if __name__ == "__main__":
    main()

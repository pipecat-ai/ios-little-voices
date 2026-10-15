#!/usr/bin/env python3
"""Build native runtime libraries for Apple silicon iPhone/simulator targets."""

import argparse
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS_DEPLOYMENT_TARGET = "27.0"
# The pinned release setup.py fetches; stage_python.py checks the lock resolves the same one.
PYDANTIC_CORE_VERSION = "2.46.5"
TARGETS = {
    "device": ("aarch64-apple-ios", "iphoneos", "ios-arm64"),
    "simulator": ("aarch64-apple-ios-sim", "iphonesimulator", "ios-arm64_x86_64-simulator"),
}


def run(args, **kwargs):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, **kwargs)


def build(platform):
    (ROOT / ".build").mkdir(exist_ok=True)
    target, sdk, slice_name = TARGETS[platform]
    sdk_path = subprocess.check_output(
        ["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True
    ).strip()
    env = os.environ.copy()
    env["PATH"] = str(ROOT / ".venv/bin") + os.pathsep + env["PATH"]
    env["CARGO_TARGET_DIR"] = str(ROOT / ".build/rust")
    env["SDKROOT"] = sdk_path
    env["IPHONEOS_DEPLOYMENT_TARGET"] = IOS_DEPLOYMENT_TARGET
    run(
        [
            "cargo",
            "build",
            "--manifest-path",
            ROOT / "native/phonon-ffi/Cargo.toml",
            "--release",
            "--locked",
            "--target",
            target,
        ],
        env=env,
    )
    config = ROOT / f".build/pyo3-{platform}.txt"
    config.write_text(
        "\n".join(
            [
                "implementation=CPython",
                "version=3.13",
                "shared=true",
                "abi3=false",
                "pointer_width=64",
                "suppress_build_script_link_lines=true",
                "build_flags=",
            ]
        )
        + "\n"
    )
    framework = ROOT / "Vendor/Python.xcframework" / slice_name
    env["PYO3_CONFIG_FILE"] = str(config)
    env["PYO3_PYTHON"] = str(ROOT / ".venv/bin/python")
    # Link against the actual iOS Python framework, never the host libpython.
    env["RUSTFLAGS"] = (
        f"-L framework={framework} -l framework=Python -C link-arg=-Wl,-headerpad_max_install_names"
    )
    run(
        [
            "cargo",
            "build",
            "--manifest-path",
            ROOT / f".build/pydantic_core-{PYDANTIC_CORE_VERSION}/Cargo.toml",
            "--release",
            "--locked",
            "--target",
            target,
        ],
        env=env,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=[*TARGETS, "all"], default="all")
    args = parser.parse_args()
    for platform in TARGETS if args.platform == "all" else [args.platform]:
        build(platform)

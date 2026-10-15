"""Check the local profile contract without reading any Contacts data."""

import subprocess

from support import CHECKS, SOURCES, build_swift, needs_swift


@needs_swift
def test_native_profile_normalization_and_persistence(tmp_path):
    binary = build_swift(
        tmp_path / "profile-checks",
        [
            SOURCES / "UserProfile.swift",
            SOURCES / "DuoCharacter.swift",
            CHECKS / "ProfileChecks.swift",
        ],
    )
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
    assert "PROFILE_CHECKS_PASSED" in result.stdout

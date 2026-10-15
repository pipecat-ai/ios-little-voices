"""Exercise native token-budget selection and prewarmed-session lifecycle rules."""

import json
import os
import subprocess

import pytest
from support import CHECKS, SOURCES, build_swift, needs_swift


@needs_swift
def test_native_language_model_context_and_cache(tmp_path):
    binary = build_swift(
        tmp_path / "language-model-checks",
        [SOURCES / "LanguageModelContext.swift", CHECKS / "LanguageModelChecks.swift"],
    )
    from mobile_app.duo import NOTES
    from mobile_app.prompts import CHARACTERS, line_instructions, session_instructions

    configured = tmp_path / "configured-prompts.json"
    configured.write_text(
        json.dumps(
            [
                {
                    "instructions": line_instructions(
                        character, session_instructions({"user_name": name})
                    ),
                    "prompt": "[Human] Hello. Should I skip the gym today and go for a short "
                    "walk afterwards instead?\n[Note: " + NOTES["opening"] + "]",
                }
                for name in ("", "Alex", "𓀀" * 80)
                for character in CHARACTERS
            ]
        )
    )
    result = subprocess.run(
        [str(binary), str(configured)], check=True, capture_output=True, text=True, timeout=10
    )
    assert "Native language model checks passed" in result.stdout


@needs_swift
@pytest.mark.skipif(
    not os.environ.get("FOUNDATION_MODELS_RUNTIME"),
    reason="Set FOUNDATION_MODELS_RUNTIME=1 on a Mac with Apple Intelligence to use its model",
)
def test_apple_language_model_streams_cancels_and_recovers_on_the_runtime(tmp_path):
    binary = build_swift(
        tmp_path / "language-model-runtime-checks",
        [
            *(
                SOURCES / name
                for name in [
                    "AppleLanguageModel.swift",
                    "LanguageModelContext.swift",
                    "NativeGenerationError.swift",
                    "SpeechSynthesis.swift",
                ]
            ),
            CHECKS / "LanguageModelRuntimeChecks.swift",
        ],
    )
    result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=300)
    if result.stdout.startswith("SKIP"):
        pytest.skip(result.stdout.strip())
    assert "PASS fresh native generation after cancellation" in result.stdout

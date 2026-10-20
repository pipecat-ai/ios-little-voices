"""Pipecat Audience's reference runtime (release rc2.1), as released under Apache-2.0.

`runtime/` holds the release's request types, input rendering, rules of evidence, rules baseline and features, byte
for byte (`RUNTIME_SHA256`); the model itself runs natively on Core ML (AudienceModel.swift). `runtime/` is on the
import path, in the app and in tests, so its modules import as `contracts` and `harness`, as in the release.
"""

from pathlib import Path

RUNTIME = Path(__file__).resolve().parent / "runtime"
# From the release's MANIFEST.json.
RUNTIME_SHA256 = {
    "contracts/__init__.py": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "contracts/schemas/__init__.py": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "contracts/schemas/addressee.py": "6210209bbe1b0b6d5ab9a8b5f3d9b7282a4e63425d7fd4bfd04865f5e8dc26e3",
    "contracts/schemas/person_card.py": "976d6673c7ad9b2d60728b1ad0f6b9c29377bcc3fef8d282ef3bcf5c93fa96dc",
    "harness/__init__.py": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "harness/addressee/__init__.py": "80b06f6e5874814a85d7cd348d3f417b138c8692d764d9317357b8998a8ea518",
    "harness/addressee/evidence.py": "d0f1a83c832af531ae080e41ad37d51297e9ca09f470c5705829636c25283f96",
    "harness/addressee/features.py": "1cb5b89b1a3f9299a3cf3d2fc70e733ae96e705438add85aef9caa74d5cea6d4",
    "harness/addressee/render.py": "264534ad4b75f408c6eb3248733d64741890f8ebb7ef06e61f35f8fec45c308a",
    "harness/addressee/rules.py": "baaa75ec8f6b95673824c942db61e1664d43f6793c3041798cb5fa8b2a511ce2",
}

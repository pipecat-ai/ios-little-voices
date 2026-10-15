"""Validate the Gradium Phonon checkpoint that the app's speech engine requires."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# The voices the cast speaks in (mobile_app.duo.CAST); the app loads and bundles only these.
PHONON_VOICES = ("en_gb_Freya", "en_gb_Reuben")
# What app builds need from the Gradium checkpoint in models/phonon.
PHONON_FILES = (
    "config.json",
    "model.q8.gguf",
    "tokenizer.json",
    *(f"voices/{voice}.safetensors" for voice in PHONON_VOICES),
)


def validate_phonon(root: Path = ROOT) -> None:
    """Raise unless models/phonon holds every file app builds need."""
    package = root / "models/phonon"
    missing = [name for name in PHONON_FILES if not (package / name).is_file()]
    if missing:
        raise RuntimeError(
            "Gradium Phonon requires its checkpoint in models/phonon/. "
            f"Missing: {', '.join(missing)}"
        )

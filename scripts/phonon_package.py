"""Validate the Gradium Phonon checkpoint and the characters' voices that the app's speech engine
requires."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# The voices the cast speaks in (mobile_app.duo.CAST), kept in src/voices; the app loads and
# bundles only these.
PHONON_VOICES = ("Angel_F01", "Devil_01")
# What app builds need from the Gradium checkpoint in models/phonon.
PHONON_FILES = ("config.json", "model.q8.gguf", "tokenizer.json")


def voice_files(root: Path = ROOT) -> list[Path]:
    """The characters' voices, in the repository."""
    return [root / "src/voices" / f"{voice}.safetensors" for voice in PHONON_VOICES]


def validate_phonon(root: Path = ROOT) -> None:
    """Raise unless models/phonon holds the checkpoint and src/voices the characters' voices."""
    package = root / "models/phonon"
    missing = [f"models/phonon/{name}" for name in PHONON_FILES if not (package / name).is_file()]
    missing += [str(path.relative_to(root)) for path in voice_files(root) if not path.is_file()]
    if missing:
        raise RuntimeError(
            "Gradium Phonon requires its checkpoint in models/phonon/ and the characters' voices "
            f"in src/voices/. Missing: {', '.join(missing)}"
        )

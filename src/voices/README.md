# Voices

The characters' Gradium Phonon voices, made for the checkpoint `phonon-0e03182e.200` (see
[models/README.txt](../../models/README.txt)):

- `Angel_F01.safetensors`: the angel.
- `Devil_01.safetensors`: the devil.

App builds bundle these two with the checkpoint (`scripts/bundle_runtime.py`), and the lip-sync
scripts speak in them as well as in Gradium's voices. To give a character another voice, add it
here and name it in `DuoCharacter.voice` (Swift), `CAST` (`src/python/mobile_app/duo.py`) and
`PHONON_VOICES` (`scripts/phonon_package.py`).

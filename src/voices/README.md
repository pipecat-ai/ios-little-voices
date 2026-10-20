# Voices

The characters' Gradium Phonon voices: `Angel_F01.safetensors` for the angel and
`Devil_01.safetensors` for the devil. App builds bundle them with Phonon 31m.

Any Phonon voice can speak for a character: one from
[gradium/phonon-voices](https://huggingface.co/gradium/phonon-voices), or one you design or clone
in [Gradium Studio](https://studio.gradium.ai) and save with **Download for Phonon**. Put it here
and name it in `DuoCharacter.voice` (Swift), `CAST` (`src/python/mobile_app/duo.py`) and
`PHONON_VOICES` (`scripts/phonon_package.py`).

The voices are used under Gradium's terms, not this repository's licence (see
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md)).

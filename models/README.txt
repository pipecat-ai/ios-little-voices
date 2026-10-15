Gradium Phonon's model is supplied by Gradium (https://gradium.ai) and is not
committed to Git. Obtain the checkpoint from Gradium (currently
phonon-0e03182e.200) and place its contents in models/phonon/.

Setup requires:
  models/phonon/config.json
  models/phonon/model.q8.gguf
  models/phonon/tokenizer.json
  models/phonon/voices/<name>.safetensors for the characters' voices,
    en_gb_Freya and en_gb_Reuben, which ship with the checkpoint

Voices must be made for the same checkpoint: the runtime rejects a voice whose
model_ext differs from config.json's model_id. To give a character another voice,
such as a custom one, put it in models/phonon/voices/ and name it in
DuoCharacter.voice (Swift), CAST (src/python/mobile_app/duo.py) and PHONON_VOICES
(scripts/phonon_package.py).

Run setup:
  uv run --no-sync python scripts/setup.py

Setup checks these files first and stops with a list of any that are missing,
then builds native/phonon-ffi, which runs the checkpoint with Gradium's
open-source ptts crate from crates.io. Xcode builds copy only config.json,
model.q8.gguf, tokenizer.json and those two voices into the app.

SpellSpeak Audience (https://huggingface.co/spellspeak/audience), release rc2.1,
runs on Core ML. Convert it with spellspeak-models' converter, which fetches the
release from Hugging Face:

  cd /path/to/spellspeak-models/audience/coreml
  uv run convert.py --out /path/to/this/repo/models/audience

Setup requires:
  models/audience/AudienceEncoder.mlpackage
  models/audience/AudienceHead.mlpackage
  models/audience/tokenizer.json
  models/audience/config.json
  models/audience/coreml.json (release rc2.1)

Xcode builds compile the two models (cached in .build/audience/) and copy them,
the tokenizer and the config into the app.

Everything in models/ except this note is ignored by Git. Phonon is used under
Gradium's terms; see THIRD_PARTY_NOTICES.md.

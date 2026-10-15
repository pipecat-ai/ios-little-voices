Gradium Phonon's model is supplied by Gradium (https://gradium.ai) and is not
committed to Git. Obtain the checkpoint from Gradium (currently
phonon-0e03182e.200) and place its contents in models/phonon/.

Setup requires:
  models/phonon/config.json
  models/phonon/model.q8.gguf
  models/phonon/tokenizer.json
The characters' voices, made for this checkpoint, are in the repository, in
src/voices/; see src/voices/README.md. The checkpoint's own voices, in
models/phonon/voices/, are optional: the lip-sync scripts train on several of them.

Run setup:
  uv run --no-sync python scripts/setup.py

Setup checks these files first and stops with a list of any that are missing,
then builds native/phonon-ffi, which runs the checkpoint with Gradium's
open-source ptts crate from crates.io. Xcode builds copy only config.json,
model.q8.gguf and tokenizer.json, with the characters' two voices, into the app.

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

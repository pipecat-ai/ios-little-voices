The app's models, which are not in Git. Download them, each pinned to one commit
of its Hugging Face repo and checked against pinned SHA-256s:

  python3 scripts/download_models.py

models/phonon/    Gradium's Phonon 31m (https://huggingface.co/gradium/phonon-31m-en,
                  Apache-2.0): config.json, model.q8.gguf, tokenizer.json
models/audience/  Pipecat Audience rc2.1 on Core ML
                  (https://huggingface.co/pipecat-ai/audience, Apache-2.0):
                  AudienceEncoder.mlpackage, AudienceHead.mlpackage,
                  tokenizer.json, config.json, coreml.json

Setup checks these files and stops with a list of any that are missing. App
builds bundle only these, with the characters' voices from src/voices/, and
compile the Audience models (cached in .build/audience/).

models/phonon/voices/ is optional: the lip-sync scripts also train on eight of
Gradium's voices there, named as its pre-release checkpoint named them. Four are
in https://huggingface.co/gradium/phonon-voices, filed by ID: en_gb_Freya is
GgfEkEJtxZR7gnpy, en_us_Harper 4SZHfMpw-p46Ywgs, en_gb_Toby dME3IWyZBvmh1n1q and
en_us_Russell _6Aslh2DxfmnRLmP. To train on others, pass --voices.

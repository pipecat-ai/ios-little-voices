# Validation

What to check before a release, and what the latest checks found.

## Automated

The README's test commands run the Python pipeline against a fake native host (turns,
barge-in, muting, the director, Audience's requests, failures and the speech filters), check
setup, packaging, the model download and the Pipecat patch, and compile the Swift checks in
`tests/native/` for macOS (speech capture, playback, Phonon, the context budget, Audience against
its reference fixtures, lip sync, history and the stage rig).
`FOUNDATION_MODELS_RUNTIME=1 uv run --no-sync pytest tests/test_language_model.py` also streams
from Apple's model, on a Mac with Apple Intelligence.

## Builds

Build the Simulator Debug app and unsigned iPhone Debug and Release apps
(`CODE_SIGNING_ALLOWED=NO`); none should warn. In the Release app, `phonon/` holds only
`config.json`, `model.q8.gguf`, `tokenizer.json` and the two voices; the standard library has no
`ssl`; and `strings PipecatVoice | grep preview-duo` finds nothing.

## In the Simulator

Launch a Debug build with each argument
(`xcrun simctl launch --console-pty booted ai.pipecat.littlevoices <argument>`):

| Argument | Expect |
| --- | --- |
| `--verify-phonon` | `PHONON_PASS` |
| `--verify-phonon-playback` | `PHONON_VERIFIED` |
| `--verify-audience` | `AUDIENCE_VERIFIED`, the largest difference under 1e-4 |
| `--preview-duo <scenario>`, each of the ten | `DUO_PREVIEW_DONE: <scenario>, 0 issues` |
| `--demo-question "Should I skip the gym today?"` | An exchange plays and `DEMO_DONE` (the Mac needs Apple Intelligence) |

## On an iPhone

- [ ] A live conversation: each character in their own voice; a question for both is debated
      and ends with verdicts; "Angel, …" picks who opens; "You lied to me." gets a "Who, me?".
- [ ] Cutting in stops a line quickly; on the speaker, the characters' voices never start a turn.
- [ ] The speaker, wired and Bluetooth headsets: each mouth keeps time with its voice.
- [ ] A call ends the conversation with a message; denied microphone access and Apple
      Intelligence turned off each say what to do.
- [ ] Conversations are kept, read back, and deleted from Settings.
- [ ] `--benchmark-phonon` (built with `SWIFT_OPTIMIZATION_LEVEL=-O`) and a live exchange log no
      `PLAYBACK_UNDERRUN`.
- [ ] A Release build ignores the debug launch arguments.

## Latest results

20 October 2026, Xcode 27, iPhone 18 Pro Simulator on iOS 27, with Phonon 31m and Audience rc2.1
from `scripts/download_models.py`:

- **Automated:** 241 passed, 1 skipped (the live model); ruff clean.
- **Builds:** Simulator Debug and unsigned iPhone Release, no warnings. The Release app is
  174 MB, with no debug launch arguments and no `ssl`.
- **Simulator:** Phonon loads both voices in 0.08 s and starts speaking in 0.15 s; Audience
  matches the reference within 5e-8, at 44 ms a line in Debug; `PHONON_VERIFIED`. Every
  `--preview-duo` scenario ends with 0 issues and no underruns, importing 559 Python modules.
- **Lip sync:** the aligner was trained on Gradium's pre-release checkpoint, where it kept its
  alignment through 39 of 40 test sentences in the characters' voices. It has not been
  retrained or measured on Phonon 31m.
- **Not yet run:** anything on a physical iPhone, and `--demo-question` with these models.

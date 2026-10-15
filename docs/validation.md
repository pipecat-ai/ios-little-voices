# Validation

How to check Little Voices, and what the latest checks found. Older reports are in the git
history.

## Automated checks

```sh
uv run --no-sync pytest -q
uv run --no-sync ruff check src/python scripts tests
uv run --no-sync ruff format --check src/python scripts tests
```

- The Python pipeline runs end to end against a fake native host: turns, barge-in, muting,
  the director and its debates, Audience's requests, failed and declined lines, and the
  speech text filters (`tests/test_bot.py`, `tests/test_duo.py` and others).
- Swift checks compiled for macOS (`tests/native/`) cover speech capture under stalls,
  playback, Phonon's settings and cancellation, the language model's context budget,
  Audience's tokenizer and models against the reference runtime's fixtures, lip sync against
  its reference analyzer and its alignment, and the stage rig.
- Setup, packaging and project generation are checked, and a real pipeline turn completes
  with only the Python the app bundles importable (`tests/test_mobile_dependencies.py`).
- The patch applies to the pinned Pipecat release, and fails clearly when it doesn't; the
  patched modules import without Pipecat's desktop dependencies or OpenSSL
  (`tests/test_pipecat_patch.py`).
- `FOUNDATION_MODELS_RUNTIME=1 uv run --no-sync pytest tests/test_language_model.py` also
  streams from Apple's model, on a Mac with Apple Intelligence.

## Builds

Build the Simulator Debug app and unsigned iPhone Debug and Release apps
(`CODE_SIGNING_ALLOWED=NO`); none should warn. In the Release app:

- `phonon/` holds only `config.json`, `model.q8.gguf`, `tokenizer.json` and the two voices;
  `audience/`, `PrivacyInfo.xcprivacy` and `THIRD_PARTY_NOTICES.md` are present.
- The standard library has no `ssl`, `_ssl` or `_hashlib`, and `python-packages/pipecat`
  only the modules the app can import.
- The binary holds none of the debug launch arguments (`strings PipecatVoice | grep
  preview-duo` finds nothing).

## In the Simulator

Launch a Debug build with an argument, for example
`xcrun simctl launch --console-pty booted ai.pipecat.voice --verify-phonon`:

| Argument | Expect |
| --- | --- |
| (none) | `PIPECAT_PYTHON_READY` |
| `--verify-voice-settings` | `PHONON_SETTINGS: voices=Angel_F01,Devil_01` |
| `--verify-phonon` | `PHONON_PASS`, and speech in `Documents/phonon-check.wav` |
| `--verify-phonon-playback` | `PHONON_VERIFIED: load, playback, cancellation, restart and continuous capture` |
| `--verify-audience` | `AUDIENCE_VERIFIED`, the largest difference under 1e-4 |
| `--preview-duo <scenario>`, for each of the eight | `DUO_PREVIEW_DONE: <scenario>, 0 issues` and `DUO_PREVIEW_RESTING: true`; screenshots at each `DUO_PREVIEW_STATE` moment look right |
| `--demo-question "Should I skip the gym today?"` | An exchange plays and `DEMO_DONE` (the Mac needs Apple Intelligence) |
| `--stage-script <name>`, `--stage-pose <pose>` | The stage as the script or pose describes it |

Apple's speech recognition doesn't run in the Simulator, so talking to the app needs an
iPhone. `PLAYBACK_UNDERRUN` lines mean Phonon fell behind playback: likely on a busy Mac, not
expected on an iPhone.

## On an iPhone

None of these has been run against the current app yet:

- [ ] A signed, optimized Debug build installs and runs.
- [ ] A live conversation: each character speaks in their own voice; a turn with no words gets
      no reply; a question for both is debated and ends with verdicts; "Angel, …" and "you
      with the horns" pick who opens; "You lied to me." gets a "Who, me?" from each.
- [ ] Cutting in: a single word stops the line quickly, and lines not yet heard are dropped.
- [ ] Echo: on the speaker, the characters' voices never start a turn; a noisy room makes no
      false starts.
- [ ] Routes: the speaker, wired and Bluetooth headsets, and the microphone picker; each mouth
      keeps time with its voice on each.
- [ ] Interruptions and failures: a call ends the conversation with a message; denied
      microphone or speech access and Apple Intelligence turned off each say what to do.
- [ ] Every `--preview-duo` scenario ends with 0 issues, and a live exchange logs no
      `PLAYBACK_UNDERRUN`.
- [ ] `--benchmark-phonon`, built with `SWIFT_OPTIMIZATION_LEVEL=-O`, logs
      `PHONON_BENCHMARK_COMPLETE`.
- [ ] A Release build ignores the debug launch arguments.
- [ ] Settings: your name and contact, the voices (Angel F01 and Devil 01), the credits, and
      "Hey Little Voices" with Vocal Shortcuts.
- [ ] With the system in Dark Mode, the stage, the dock and Settings stay light.
- [ ] Control Center screen recording captures the characters with its microphone off, and
      you too with it on.

## Latest results

October 2026, Xcode 27 on an Apple silicon Mac, iPhone 18 Pro Simulator with iOS 27:

- **Automated:** pytest 225 passed and 1 skipped (the live-model check); ruff clean.
- **Builds:** the Simulator Debug and unsigned iPhone Debug and Release builds have no
  warnings; the unsigned Release app is 241 MB.
- **Simulator diagnostics:** Phonon loads both voices in about 0.1 s and starts speaking in
  about 0.3 s; Audience on Core ML matches the reference runtime within 5e-8, at about 45 ms a
  line in a Debug build.
- **Scripted conversations:** every `--preview-duo` scenario ends with 0 issues.
- **Live model:** `--demo-question` exchanges have played with the Mac's Apple Intelligence, but
  the latest runs stopped at token counting (`LLM_FAILED`) because the Mac had no model assets
  ("There are no underlying assets"). Run it again once Apple Intelligence is ready.
- **Bundled Python:** every scripted run imports the same 559 modules; the bundle leaves out
  the rest, OpenSSL included.
- **Lip sync:** across eight of Phonon's stock voices, vowels take their mouth shape 86% of the
  time and the lips close on 99–100% of M, B and P (see [lip sync](architecture.md#lip-sync)).
- **Not yet run:** anything on a physical iPhone.

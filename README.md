# Little Voices

An angel and a devil sit on your shoulders. Ask them anything out loud: they debate it, then
each gives you a verdict, in their own voices, with faces that mouth their words. Everything
runs on the iPhone, with no server and no API keys:

- **Apple Speech** hears you, and Apple's echo cancellation lets you talk over them.
- **[Pipecat](https://github.com/pipecat-ai/pipecat)**, embedded in Python on the device, runs
  the conversation.
- **Apple Foundation Models** writes both characters' lines.
- **[SpellSpeak Audience](https://huggingface.co/spellspeak/audience)** reads who each line is
  for, which decides who speaks next.
- **Gradium Phonon** speaks each character in their own voice, and lip sync shapes the words.

The interface is one squishy stage: whoever speaks swells into the other's half, their words
appear a sentence at a time, and a character writing their next line shows typing dots. Light
and dark appearance, Dynamic Type, VoiceOver, Reduce Transparency and Reduce Motion are
supported. The characters speak and understand English.

## Requirements

- A Mac with Apple silicon, macOS 27 and Xcode 27.
- [uv](https://docs.astral.sh/uv/) and [Rust](https://rustup.rs) (setup adds the iOS targets).
- An iPhone with iOS 27 that supports Apple Intelligence, with Apple Intelligence turned on and
  its model downloaded.
- The two models below, which are not in this repository.

## Get the models

Both go in `models/`, which Git ignores apart from [models/README.txt](models/README.txt).

**Gradium Phonon.** The checkpoint and its voices are not in this repository: obtain them
from [Gradium](https://gradium.ai) (currently `phonon-0e03182e.200`) and place them in
`models/phonon/`: `config.json`, `model.q8.gguf`, `tokenizer.json`, and the characters' voices
`voices/en_gb_Freya.safetensors` and `voices/en_gb_Reuben.safetensors`, which ship with it. A
script to download them will follow.

**SpellSpeak Audience.** Convert release rc2.1 to Core ML with the converter in
[spellspeak-models](https://github.com/spellspeak/models), which fetches the release:

```sh
cd /path/to/spellspeak-models/audience/coreml
uv run convert.py --out /path/to/little-voices/models/audience
```

**Other voices.** Any voice made for the same Phonon checkpoint can speak for a character: put
it in `models/phonon/voices/` and name it in `DuoCharacter.voice` (Swift), `CAST` in
`src/python/mobile_app/duo.py` and `PHONON_VOICES` in `scripts/phonon_package.py`.

## Set up

```sh
uv sync --locked
uv run --no-sync python scripts/setup.py
```

Setup downloads the pipecat-ai 1.12.0 release from PyPI, checks it against its pinned SHA-256
and applies [the app's patch](patches/README.md) to it in `.build/pipecat-ai/`. It then checks
both models, fetches checksum-pinned Python 3.13 for iOS (BeeWare's Python-Apple-support),
cross-compiles pydantic-core and the Phonon runtime (`native/phonon-ffi`), stages the app's
Python packages and generates the Xcode project. Builds need no network after that. Add
`--platform device` or `--platform simulator` to prepare one target, or `--pipecat-only` to
prepare only the patched Pipecat, which is all the tests need from setup. After adding or
removing app source files, run `python3 scripts/generate_project.py`; after changing the app's
Python dependencies, `uv run --no-sync python scripts/stage_python.py`; after changing the
patch, `uv run --no-sync python scripts/setup.py --pipecat-only`.

## Run

**On an iPhone.** Open `PipecatVoice.xcodeproj`, choose your signing team for the
**PipecatVoice** target, and run. Tap the microphone and ask a question; pause to finish your
turn. Speak at any time to cut in. Tap the microphone again to mute, End to finish, and New
conversation to start afresh. In Settings, give your name (or pick your contact) so the
characters can greet you, switch the stage to dark mode, and set up "Hey Little Voices" with
Apple's Vocal Shortcuts. The button beside the microphone opens Apple's microphone picker.

**In the Simulator.** Apple's on-device speech recognition doesn't run there, so you can't
talk to the characters. The scripted conversations run the rest of the app instead:

```sh
xcodebuild -project PipecatVoice.xcodeproj -scheme PipecatVoice -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath .build/DerivedData build
xcrun simctl install booted .build/DerivedData/Build/Products/Debug-iphonesimulator/PipecatVoice.app
xcrun simctl launch --console-pty booted ai.pipecat.voice --preview-duo barge-in
```

`--demo-question` also works in the Simulator when the Mac has Apple Intelligence turned on.

**Debug launch arguments.** Debug builds accept these; Release builds compile none of them in.
[docs/native-tts.md](docs/native-tts.md#diagnostics) has the details and log lines.

| Argument | What it does |
| --- | --- |
| `--preview-duo [scenario]` | Plays a scripted conversation through the whole app, with stand-ins for the microphone and the language model, and flags anything the screen should never show: `gym` (the default), `barge-in`, `new-conversation`, `background`, `mute`, `long-and-short`, `markup`, `error`, `debate`. |
| `--record-audio`, `--preview-buffered` | With `--preview-duo`: record what plays; synthesize each sentence in full before it plays. |
| `--demo-question "…"` | Asks the live language model a question for you and records what plays. |
| `--verify-phonon`, `--verify-phonon-playback` | Check Phonon synthesis, and playback, cancellation and restart. |
| `--verify-audience`, `--verify-voice-settings` | Check Audience on Core ML against its reference runtime; print the voices. |
| `--benchmark-phonon` | Phonon's streaming benchmark (build with `SWIFT_OPTIMIZATION_LEVEL=-O`). |
| `--stage-pose <pose>` | Holds a settled pose on the stage: `neutral`, `lean-angel`, `lean-devil`, `angel-talking`, `devil-talking`; `--no-captions` hides the captions. |
| `--stage-script <name>` | Plays a scripted conversation on the stage with synthetic mouths, without the model: `intro` (the launch intro), `idle`, `handovers`, `interrupt`, `captions` and more. |
| `--expression-gallery [rNcM]`, `--mouth-sheet` | Shows the faces' expressions, or one of them; every mouth shape. |
| `--rig-seed N`, `--rig-trace` | Sets the stage's random seed; logs its events and frame rate. |
| `--lipsync-trace`, `--lipsync-formant-only` | Logs each mouth's frames; shapes the mouths from the sound alone, without the words. |
| `--reduce-motion` | Shows the stage's Reduce Motion mode. |

**Recording the screen with sound.** Start Control Center's screen recording with its
microphone off to capture the characters' voices; turn it on to include yours.

## How the conversation works

When you finish speaking, Audience reads who your line was for. The character you name or
describe ("Angel, …", "you with the horns") answers first; otherwise the likelier one does.
Then the other replies, and they debate: a line aimed at the other character gets an answer,
and whoever's last word went to the other turns to you with a verdict. An exchange has at most
six lines, each written while the one before it plays. A line for either of them that asks
nothing ("You lied to me.") gets a "Who, me?" from each.

The characters' instructions are in `src/python/mobile_app/prompts.py` and the director in
`src/python/mobile_app/duo.py`. To see how Apple's model plays them, run
`uv run --no-sync python scripts/persona_eval.py` on a Mac with Apple Intelligence.
[docs/architecture.md](docs/architecture.md) describes the pipeline, the native services and
the stage.

## Tests

```sh
uv run --no-sync pytest -q
uv run --no-sync ruff check src/python scripts tests
uv run --no-sync ruff format --check src/python scripts tests
```

The tests import the patched Pipecat that setup prepares. They run the whole Python pipeline
against a fake native host, check that the patch applies to the pinned release, and compile
Swift checks for macOS from `tests/native/`. [docs/validation.md](docs/validation.md) lists
what to check on the Simulator and on an iPhone.

## Project layout

```text
src/ios/PipecatVoice/            the SwiftUI app: the stage, the conversation, the native
                                 services and the embedded Python host
src/python/mobile_app/           the Pipecat bot, the director and the characters
src/python/pipecat_apple/        Pipecat services for the native host: the bridge, speech
                                 recognition, the language model, Phonon, transport and VAD
src/python/spellspeak_audience/  SpellSpeak Audience's reference runtime (vendored)
patches/                         the app's patch to the Pipecat release (patches/README.md)
native/phonon-ffi/               a C interface to Gradium's ptts runtime, in Rust
scripts/                         setup, native builds, packaging, project generation
tests/                           Python tests, and Swift checks in tests/native/
models/                          the Phonon checkpoint and Audience models (not in Git)
docs/                            architecture, native speech, validation
```

## Credits and licences

Little Voices is released under the BSD 2-Clause License; see [LICENSE](LICENSE).

Speech is by Gradium's Phonon, used under Gradium's terms, on its `ptts` runtime (MIT or
Apache-2.0). Who each line is for is read by SpellSpeak Audience (Apache-2.0; its base model,
Ettin, is MIT). Pipecat, which the app embeds as the pipecat-ai release with a patch for iOS,
and pipecat-visemes, whose formant analysis the lip sync ports, are Daily's (BSD 2-Clause),
and the lip sync's pronunciations come from the CMU Pronouncing Dictionary (BSD-style).
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) has every component's notice, including the
embedded Python and its packages. The app icon and launch artwork are described in
[src/branding/README.md](src/branding/README.md).

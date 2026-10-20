# Native speech

The characters speak with Gradium Phonon 31m, on the device. Python never handles audio.

## Phonon in the app

`PhononTTSService` (`pipecat_apple.phonon`) is a Pipecat TTS service whose audio the host
plays (`NativePlaybackTTSService`): it sends each sentence to the host and yields
`TTSAudioPlayedFrame` once the host reports it played, so the assistant aggregator commits only
played text. The host owns the model and voices; settings that try to change them are refused.

Swift's `PhononSynthesizer` runs the checkpoint through `native/phonon-ffi`, a static Rust
library around Gradium's `ptts` runtime (0.4.0):

- `prepare(voices:)` loads the model with both voices (`Angel_F01`, `Devil_01`), and
  `phonon_speak` takes a voice index, so the voice changes per sentence without reloading.
- `synthesize(_:voice:)` streams mono Float32 at 24 kHz; each request owns its stream,
  cancellation and completion.
- The model loads as the app comes to the front, stays loaded between conversations, and is
  freed in the background.

`ptts` normalizes text as English and runs the q8 weights on the CPU with a fixed seed (42) and
temperature 0.3. Requests are capped at 420 characters by the sentence aggregator (600 by
`ptts`); a sentence with no letters or digits is never sent. Cancellation stops generation at
the next chunk.

## Bridge contract

- The native `start` event opens a session; the bridge first cancels the previous session's
  speech.
- Each `speak` request carries `request`, `session`, `turn`, `text`, `speaker`, `voice` and
  `line`. The host plays it through `PCMPlayer` on the shared `VoiceAudioEngine` (echo
  cancellation needs playback on the engine that captures), reports playback starting and
  draining, and sends `result` with `done: true` once the whole sentence has played.
- Cancellation stops playback at once, then inference; capture and VAD keep running, and
  results from older requests, sessions and turns are dropped.
- Native operations time out after 90 seconds.

## Bundled assets

App builds bundle only what `ptts` reads (checked by `scripts/phonon_package.py`):

```text
phonon/
  config.json
  model.q8.gguf
  tokenizer.json
  voices/
    Angel_F01.safetensors
    Devil_01.safetensors
```

Nothing is downloaded at runtime.

## Diagnostics

Debug builds accept these launch arguments; Release builds compile none of them in.

| Argument | What it does |
| --- | --- |
| `--verify-phonon` | Synthesizes a sentence to `Documents/phonon-check.wav`: `PHONON_PASS` or `PHONON_FAILED`. |
| `--verify-phonon-playback` | Load, playback, cancellation, restart and continuous capture: `PHONON_VERIFIED` or `PHONON_FAILED`. |
| `--verify-voice-settings` | `PHONON_SETTINGS: voices=Angel_F01,Devil_01`. |
| `--verify-audience` | Scores a request on Core ML against the reference runtime's ONNX answer: `AUDIENCE_VERIFIED`, `AUDIENCE_MISMATCH` or `AUDIENCE_FAILED`. |
| `--benchmark-phonon` | First-chunk latency, real-time factor and chunk gaps over four passes, to `Documents/phonon-benchmark.json` (`PHONON_BENCHMARK_COMPLETE`). Build with `SWIFT_OPTIMIZATION_LEVEL=-O` and run on an iPhone. |
| `--preview-duo [scenario]` | A scripted conversation through the whole app, with stand-ins for the microphone and the language model (below). |
| `--record-audio`, `--preview-buffered` | With `--preview-duo`: record what plays; synthesize each sentence in full before it plays. |
| `--demo-question "…"` | Asks the live language model a question and records what plays to `tmp/demo-audio.caf` (`DEMO_DONE`). Needs Apple Intelligence. |
| `--showreel [scene]` | The characters play a scene from `ConversationModel.showreels` without the header and dock, for recordings. |
| `--stage-pose <pose>` | Holds a pose: `neutral`, `lean-angel`, `lean-devil`, `angel-talking`, `devil-talking`; `--no-captions` hides captions. |
| `--stage-script <name>` | A scripted conversation on the stage with synthetic mouths and no model: `intro`, `idle`, `handovers`, `interrupt`, `captions` and the rest of `scenarioNames` in `StageScripts.swift`. |
| `--expression-gallery [rNcM]`, `--mouth-sheet` | The faces' expressions, or one cell; every mouth shape. |
| `--mic-sheet [press]`, `--welcome` | The microphone's states, or one pressed repeatedly; the first launch's welcome card again. |
| `--rig-seed N`, `--rig-trace` | The stage's random seed; log its events (`STAGE_EVENT`) and frame rate. |
| `--lipsync-trace`, `--lipsync-formant-only` | Log each mouth's frames, phones and alignment (`LIPSYNC_*`); shape mouths from the sound alone. |
| `--reduce-motion` | The stage's Reduce Motion mode. |

**Scripted conversations** (`ConversationPreview.swift`). Everything but the microphone and
the language model runs as in a conversation: the director, Audience, the text filters, Phonon,
playback, lip sync and the stage.

| Scenario | What happens |
| --- | --- |
| `gym` (default) | "Angel, should I go to the gym tonight?", debated, with verdicts. |
| `barge-in` | The human cuts in while the devil speaks. |
| `new-conversation` | New conversation mid-line, then a fresh conversation. |
| `background` | The app goes to the background and back between questions. |
| `mute` | Muting and unmuting mid-line. |
| `long-and-short` | One-word greetings, a six-sentence line and a one-word reply. |
| `markup` | Emoji, Markdown, odd punctuation, and lines with nothing to say aloud. |
| `error` | A declined opening, an exchange neither can begin, and a later line that fails. |
| `debate` | The characters argue up to the six-line limit. |
| `hold` | Hold to talk: a question, a press that cuts the devil off, a tap, and a last question. |

Each logs `DUO_PREVIEW_STATE` at each moment and `DUO_PREVIEW_ISSUE` for anything the screen
should never show (a mouth out of step with its audio, captions or typing dots left behind,
audio after New conversation), and ends with `DUO_PREVIEW_DONE: <scenario>, <n> issues`. It
also logs `PYTHON_MODULES:`, every Python module imported, since app builds leave out the ones
the app never imports (`scripts/bundle_runtime.py`). `PLAYBACK_UNDERRUN` means playback ran dry
mid-sentence.

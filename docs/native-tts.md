# Native speech

The characters speak with Gradium Phonon, on the device. Python never handles audio.

## Phonon in the app

`PhononTTSService` (`pipecat_apple.phonon`) is a Pipecat TTS service whose audio the host
plays (`NativePlaybackTTSService`): it sends each sentence to the host and yields
`TTSAudioPlayedFrame` once the host reports it played, so the assistant aggregator commits
only played text. Its model setting is fixed to `gradium-phonon`; each response's metadata
names its voice, and the host owns the model, so settings that try to change either are
refused.

Swift's `PhononSynthesizer` runs the bundled checkpoint through `native/phonon-ffi`, a static
Rust library around Gradium's open-source `ptts` runtime (0.4.0-rc.1):

- `prepare(voices:)` loads the model with every voice of the cast (`VoiceSettings.voices`: the
  angel's `en_gb_Freya`, then the devil's `en_gb_Reuben`); `phonon_speak` takes the index of a
  request's voice, so the voice changes per sentence without reloading.
- `synthesize(_:voice:)` streams mono Float32 at 24 kHz; each `SpeechSynthesis` request owns
  its stream, cancellation and completion.
- `unload()` waits for the runtime, so a model still running is never released.

The app loads the model as it comes to the front, keeps it between conversations, and frees it
in the background.

The runtime normalizes text as English, runs the q8 weights on the CPU with a fixed seed (42)
and `ptts`'s default temperature (0.3), and rejects requests over 600 characters; the sentence
aggregator ahead of it limits requests to 420. Text that normalizes to nothing gives no audio,
and a sentence with no letters or digits is never sent. Cancellation stops generation at the
next PCM chunk. Phonon makes no network requests.

## Bridge contract

- The native `start` event opens a session. Before admitting it, the bridge interrupts the
  Phonon service and waits for the previous session's speech to cancel.
- Each `speak` request carries `request`, `session`, `turn`, `text`, and from its line's start
  frame `speaker`, `voice` and `line`: the voice picks one the host loaded, the speaker the
  mouth that moves, and the line what the screen shows as the sentence's audio starts.
- The host plays the samples through `PCMPlayer` on the shared `VoiceAudioEngine`, reports
  playback starting and draining, and sends `result` with `done: true` only once the whole
  sentence has played. `PCMPlayer` hands each scheduled chunk to lip sync (see
  [lip sync](architecture.md#lip-sync)).
- Cancellation stops the request's playback at once, then its inference. Capture and VAD keep
  running, and samples, errors and completions from older requests, sessions and turns are
  dropped. Playback never uses a second player or reconfigures the audio session, since echo
  cancellation relies on playback going through the engine that captures the microphone.
- Native operations time out after 90 seconds.

## Bundled assets

`models/phonon/` holds the checkpoint from Gradium (currently `phonon-0e03182e.200`), checked
by `scripts/phonon_package.py`. App builds bundle only what the runtime reads and the cast's
voices (`PHONON_VOICES`):

```text
phonon/
  config.json
  model.q8.gguf
  tokenizer.json
  voices/
    en_gb_Freya.safetensors
    en_gb_Reuben.safetensors
```

`ptts` rejects a voice stamped for another checkpoint. Nothing is downloaded at runtime.

## Diagnostics

Debug builds accept these launch arguments; Release builds compile none of them in.

**Native services**

- `--verify-voice-settings`: `PHONON_SETTINGS: voices=en_gb_Freya,en_gb_Reuben`.
- `--verify-phonon`: synthesizes a fixed sentence without the audio session, writes
  `Documents/phonon-check.wav`, and logs `PHONON_PREPARED`, `PHONON_FIRST_PCM`,
  `PHONON_SYNTHESIZED` and `PHONON_PASS: microphone=off, playback=not_tested`, or
  `PHONON_FAILED` with the stage and error.
- `--verify-phonon-playback`: loads the model, plays through the shared engine, cancels,
  restarts and keeps capturing; writes `Documents/phonon-playback-check.wav` and logs
  `PHONON_VERIFIED: load, playback, cancellation, restart and continuous capture` or
  `PHONON_FAILED`.
- `--verify-audience`: scores a request the SpellSpeak reference runtime rendered
  (`AudienceSample.swift`) on the bundled Core ML models and compares it with ONNX Runtime's
  answer: `AUDIENCE_VERIFIED` or `AUDIENCE_MISMATCH`, with the largest difference, load time
  and time per line, or `AUDIENCE_FAILED`.
- `--benchmark-phonon`: a first pass and three warm passes in the angel's voice, without the
  microphone or playback. It writes `Documents/phonon-benchmark.json` and logs
  `PHONON_BENCHMARK_RUN` per pass (first-chunk latency, real-time factor, chunk gaps and
  potential underflows, which assume playback from the first chunk with no prebuffer) and
  `PHONON_BENCHMARK_COMPLETE`. Build with `SWIFT_OPTIMIZATION_LEVEL=-O` and run on an iPhone
  for meaningful timings.

**Scripted conversations** (`ConversationPreview.swift`)

- `--preview-duo [scenario]` stands in for the microphone and the language model; everything
  else (Python's director, Audience, the text filters, Phonon, playback, lip sync and the
  stage) runs as in a conversation. Scenarios:

  | Scenario | What happens |
  | --- | --- |
  | `gym` (default) | "Angel, should I go to the gym tonight?", debated, with verdicts. |
  | `barge-in` | The human cuts in while the devil speaks. |
  | `new-conversation` | New conversation mid-line, then a fresh conversation. |
  | `background` | The app goes to the background between questions; back in front, it loads the models again and a fresh conversation starts. |
  | `mute` | Muting and unmuting mid-line, with speech while muted. |
  | `long-and-short` | One-word greetings, then a six-sentence line and a one-word reply. |
  | `markup` | Emoji, Markdown and odd punctuation, and lines with nothing to say aloud. |
  | `error` | A declined opening the other character takes, an exchange neither can begin, and a later line that fails. |
  | `debate` | The characters argue up to the six-line limit. |

  It logs `DUO_PREVIEW_STATE: <moment> (t=<s>)` at each moment, `DUO_PREVIEW_TRACE` when what
  the screen shows changes, `DUO_PREVIEW_MODEL` for each scripted line, `DUO_PREVIEW_CHECK`
  after New conversation and the microphone, and `DUO_PREVIEW_ISSUE` for anything the screen
  should never show: a mouth moving after its audio or still while its character speaks,
  audio with nobody on the floor, captions or typing dots left behind, the human's words over
  a character's, audio after New conversation, or the conversation stopping. It ends with
  `DUO_PREVIEW_PLAYED` per character, `DUO_PREVIEW_RESTING` and
  `DUO_PREVIEW_DONE: <scenario>, <n> issues` (`DUO_PREVIEW_FAILED` for an unknown scenario).
  `--record-audio` also records what plays; `--preview-buffered` synthesizes each sentence in
  full before it plays, so a busy machine can't starve playback.
- `--demo-question "<question>"` asks the live language model a question for you, through the
  same microphone stand-in, records what plays to `tmp/demo-audio.caf` (`DEMO_AUDIO: <start>
  <output latency> <path>`) and logs `DEMO_DONE`. It needs Apple Intelligence: an iPhone, or a
  Simulator on a Mac with it turned on. Lay the recording over a Simulator screen recording
  (`xcrun simctl io <device> recordVideo`) for a demo with sound.
- Both end by logging `PYTHON_MODULES:` with every Python module imported. App builds leave
  out the standard library and Pipecat modules the app never imports
  (`scripts/bundle_runtime.py`), so this shows whether a change needs one of them.
- `PLAYBACK_UNDERRUN: <character> line <n> after <s> s of audio` is logged whenever playback
  runs dry mid-sentence, heard as a gap.

**The stage and lip sync**

- `--stage-pose <neutral|lean-angel|lean-devil|angel-talking|devil-talking>` holds a settled
  pose on the stage with sample captions (`--no-captions` for none): `STAGE_POSE_READY`.
- `--stage-script <name>` plays a scripted conversation on the stage with synthetic mouths
  and microphone level, without the model: `STAGE_SCRIPT_START`, `STAGE_SCRIPT` per step,
  `STAGE_SCRIPT_DONE`. `intro` replays the launch intro, with a `STAGE_SCRIPT` mark per beat,
  and `intro-handover` starts a conversation during it.
- `--expression-gallery [rNcM]` shows the faces' expression sheet, or one cell
  (`EXPRESSION_GALLERY_READY`); `--mouth-sheet` every mouth state (`MOUTH_SHEET_READY`).
- `--rig-seed N` sets the stage's seed (1 for the gallery, poses and scripts; random
  otherwise). `--rig-trace` logs stage events (`STAGE_EVENT`) and frame rates
  (`STAGE_LINK`, `STAGE_DRAWS`).
- `--lipsync-trace` logs each talking mouth per frame (`LIPSYNC_FRAME`); each sentence's
  text (`LIPSYNC_TEXT`); each chunk it analyzes (`LIPSYNC_CHUNK`: player time, audio time,
  samples and the player time last drawn, with the samples appended to
  `tmp/lipsync-<character>.f32`); whether each alignment held or was lost
  (`LIPSYNC_ALIGNMENT`) and each phone or pause as heard, with its word (`LIPSYNC_PHONE`);
  and the analyzer's keyframes and events (`LIPSYNC_KEY`, `LIPSYNC_EVENT`).
  `--lipsync-formant-only` shapes the mouths from the sound alone, without the words.
- `--reduce-motion` shows the stage's Reduce Motion mode.

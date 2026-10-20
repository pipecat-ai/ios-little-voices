# Architecture

```mermaid
flowchart LR
    Mic[Microphone] --> Audio[Shared echo-cancelled AVAudioEngine]
    Audio --> ASR[Apple SpeechAnalyzer]
    Audio --> VAD[Apple SoundAnalysis]
    ASR -->|partial and final text| Python[Pipecat Python pipeline]
    VAD -->|speech confidence| Python
    Python -->|who each line is for| Audience[Pipecat Audience on Core ML]
    Audience -->|scores| Python
    Python -->|each character's line| LLM[Apple Foundation Models]
    LLM -->|text deltas| Python
    Python -->|sentence, speaker and voice| TTS[Gradium Phonon]
    TTS -->|24 kHz PCM| Audio
    Audio -->|playback start, drain, and cancellation| Python
    Python -->|RTVI transcripts, who is addressed, turn state| UI[SwiftUI]
    Audio -->|scheduled PCM and playhead| Lipsync[Lip sync]
    Lipsync -->|each character's mouth pose| UI
```

`PCPythonRuntime.m` runs CPython 3.13 on its own thread. The built-in `_pipecat_native` module
carries JSON events both ways: Python polls a thread-safe inbox, and its events reach Swift on
the main queue. There is no socket, subprocess or server, and no code is downloaded.

As the app comes to the front, `ConversationModel` loads Phonon, Audience and the speech model
(at launch, after the intro, so loading doesn't drop its frames). Phonon and Audience stay
loaded between conversations and are freed in the background.

## The pipeline

`src/python/mobile_app/bot.py` builds a `PipelineWorker`:

```text
AppleTransport.input() → AppleSpeechSTTService → context_aggregator.user()
                      → DuoLLMService → LLMTextProcessor → PhononTTSService
                      → AppleTransport.output() → context_aggregator.assistant()
```

The native services are the `pipecat_apple` package, built on pipecat-ai 1.12.0 with a small
patch ([patches/README.md](../patches/README.md)), so another embedded Apple bot can reuse them:

| Module | Service | Pipecat base |
| --- | --- | --- |
| `pipecat_apple.stt` | `AppleSpeechSTTService` | `STTService` |
| `pipecat_apple.llm` | `AppleFoundationLLMService`, `AppleLLMAdapter` | `LLMService`, `BaseLLMAdapter` |
| `pipecat_apple.playback` | `NativePlaybackTTSService` | `TTSService`, played by the host |
| `pipecat_apple.phonon` | `PhononTTSService` | `NativePlaybackTTSService` |
| `pipecat_apple.vad` | `AppleVADAnalyzer` | `VADAnalyzer` |
| `pipecat_apple.transport` | `AppleTransport`, `AppleRTVIObserver` | transport bases, `RTVIObserver` |
| `pipecat_apple.bridge` | `AppleNativeBridge` | request correlation and sessions |

- **Text.** `LLMTextProcessor` splits replies into sentences with Apple's `NLTokenizer`
  (sentencex has no iOS wheel), at most 420 characters each. `MarkdownTextFilter` and
  `PlainSpeechTextFilter` clean each sentence, so what Phonon says is what the caption shows and
  what enters the context.
- **Speech.** Each sentence goes to the host with its speaker, voice and line; its text is
  committed only once the host has played it, so an interruption drops the rest
  ([native speech](native-tts.md)).
- **The language model** writes text only (no tools). `bot.py` passes `empty_user_turn=None`, so
  a turn with no words gets no reply. Your name from Settings is added to each character's
  instructions with an `LLMUpdateSettingsFrame`.
- **Failures.** An exchange that can't begin cancels the turn, keeps the conversation and shows
  the error. Other failures end the conversation with a message saying what to do. Foundation
  Models errors map to stable codes (`LLM_DECLINED`, `LLM_ASSETS`, `LLM_FAILED`, …), logged
  without prompt text. If Audience fails to load, its rules baseline reads the lines.

## Turns

**Hold to talk** is the default (`InputMode`). Capture runs throughout, but ASR hears only a
held microphone. A press replays the last 0.3 s of audio so a word begun with it is heard
whole, and stops the characters at once. Python gets `talk` events in place of VAD; a turn
still needs a recognized word, so a tap starts none. Listening continues 0.35 s after release,
then ASR is finalized.

**Hands-free** uses voice activity. SoundAnalysis's built-in classifier (`speech` class, 0.5 s
window, a score every 0.1 s) feeds `AppleVADAnalyzer`, which debounces it with Pipecat's state
machine (confidence 0.65, start 0.1 s, stop 0.6 s). A turn starts only with speech and at least
one recognized word, so noise can't cut the characters off but "stop" can. For a firm end of
turn, `finalize_asr` ends the current ASR input, waits for its final results and starts a new
transcriber, replaying up to 4 s of audio.

**Voice activation.** `StartConversationIntent` is an App Intent, so a "Hey Little Voices" Vocal
Shortcut can start a hands-free conversation.

## Audio

`VoiceAudioEngine` owns one `AVAudioEngine` for capture and playback: `.playAndRecord` with
echo-cancelled input, or `.voiceChat` with voice processing as a fallback. Capture stays on while
the characters speak, so you can cut in. The default mode also lets Control Center's screen
recording capture the characters.

Settings chooses the microphone with Apple's input menu (`MicrophoneInputPicker`), remembered
for the next conversation; Voice Isolation and the other Mic Modes are the user's choice there.
On a route change mid-conversation, the host suspends capture, restores echo cancellation on the
new input and carries on. Stopping a reply stops the player, not the engine; muting stops capture and ASR.
`PCMPlayer` reports playback starting, draining and cancelled, which become
`BotStartedSpeakingFrame` and `BotStoppedSpeakingFrame`.

## The angel and the devil

One Foundation Models session plays both characters. `DuoLLMService`
(`src/python/mobile_app/duo.py`) answers each turn with an exchange of lines, each a separate
generation with its speaker's instructions and view of the conversation.

**Audience** reads who each line is for. Requests are built with Audience's reference runtime,
release rc2.1, vendored byte for byte in `src/python/pipecat_audience/runtime/`: a card for each
person the line could be for, who spoke to whom last, and the last four lines. The host scores
them on Core ML (`AudienceTokenizer` reproduces the `tokenizers` encoding; `AudienceModel` runs
the encoder and head, caching each card). A line is for everyone (group ≥ 0.5), for nobody in
particular (unclear ≥ 0.5), or for the likeliest person. About 5 ms a line.

**Who speaks** (`Exchange`):

- A line for one character is theirs to answer first; otherwise the likelier one opens, and ties
  alternate.
- An unclear line that asks nothing ("You lied to me.") gets a "Who, me?" from each; a greeting
  gets a few words from each.
- The other character replies, and while lines are aimed at each other they debate, for up to
  four lines. Whoever's last word went to the other then gives you a verdict. Six lines at most.

**Views** (`Room`). Each speaker sees their own lines as assistant messages and everyone else's
as user messages tagged `[Human]`, `[Angel]` or `[Devil]`, with a closing `[Note: …]` on what the
moment needs. Interrupted lines keep what was heard; lines nobody heard are dropped. The room
keeps the last 32 lines.

**Timing.** Each line is written while the one before it plays, so at most one line waits. Each
line's end frame says whether another `continues`, so the human's turn is reported only after
the last. A declined opening (`LLM_DECLINED`) passes to the other character; a later line that
fails is dropped and the floor returns. Once an exchange settles, the likely next opener is
prewarmed.

## The stage

`DuoStageView` draws both characters in one full-screen `Canvas`, from a seeded simulation
stepped at 240 Hz (`StageSimulation`). Whoever speaks swells into the other's half and squishes
them, with a jelly ripple on each handover; at rest the seam between them drifts as a slow S.
Captions, typing dots, the human's words and the dock are SwiftUI on a shared glass
(`SoftGlass`) and never wobble.

- **Faces.** `FaceRig` springs every feature; `CharacterDirector` gives each character a role
  (speaking, squished, thinking, listening, resting) with blinks, glances and gestures, and
  `CaptionCues` adds reactions to what is said (laughing along, shock, an eye roll).
- **Who is addressed.** `DuoLLMService` emits `addressed` events with Audience's reading, and
  the seam leans toward whoever your question is for.
- **The intro** (`StageIntro`) plays while Python and the models load: the characters pop in,
  shove each other, make up, and the logo drops in. On the first launch the welcome card
  (`WelcomeCard`) follows.
- **Pacing.** The stage runs at the display's rate during handovers, 60 Hz while a mouth moves,
  30 Hz while only breathing, and sleeps when everything settles.
- **Accessibility.** VoiceOver reads each half as the character and what they're saying;
  captions grow with Dynamic Type; Reduce Motion holds every pose and cross-fades changes;
  Reduce Transparency makes the glass solid. The app is always light.
- **Scripted runs.** `--stage-script` plays conversations on the real stage without the model,
  and the rig checks in `tests/native/` play seeded random ones, checking every frame.

## Lip sync

Each character's mouth shapes the words it speaks, natively; Python never sees audio or poses.
Each speak request's audio goes to its speaker's `LipsyncTimeline`, with the sentence's text
first, and the timeline aligns the phones to the audio as it streams.

- `LipsyncLexicon` and `LipsyncText` turn text into phones: the CMU Pronouncing Dictionary
  (packed by `scripts/pack_cmudict.py`), read as `ptts` normalizes text (numbers, symbols,
  initialisms), with letter-to-sound rules for anything else.
- `LipsyncAligner` aligns them with a hidden semi-Markov model over loudness, zero crossings and
  12 mel cepstra per 20 ms hop, with a Gaussian and a duration per phone
  (`LipsyncAlignerModel`). Five decoders cover speaking rates from 0.8× to 1.75×, and the
  current phone is predicted 40 ms ahead. If the alignment stops explaining the audio, the
  sentence falls back to formants.
- `FormantLipsyncAnalyzer` is a Swift port of the formant analyzer from Daily's
  pipecat-visemes, which reads the mouth from the sound alone (LPC formants, pitch, energy).
- `LipsyncVisemes` gives each phone a target (openness, width, rounding) with coarticulation
  (after Cohen and Massaro); M, B and P close the lips.
- `LipsyncTimeline` places keyframes 20 ms ahead of their audio on the player clock, scales
  openness with loudness, and rests in pauses. `DuoStageView` samples the pose each frame from
  `PCMPlayer.playbackTime`, which accounts for output latency (Bluetooth included).

The aligner is retrained with `uv run --no-sync --with numpy python
scripts/lipsync/train_aligner.py`, which speaks `scripts/lipsync/sentences.txt` in the
characters' voices (and Gradium's, if present) with the local checkpoint. The checks in
`tests/native/Lipsync*Checks.swift` compare the port with the Python reference and the
alignment with hand-placed landmarks; `scripts/lipsync/make_fixtures.py` writes the two clips
they need.

## Context and the language model

`AppleRTVIObserver` delivers Pipecat's RTVI messages through the native callback. SwiftUI reads
`user-transcription` and `bot-llm-started`; the bridge's `state` events and `DuoLLMService`'s
`addressed` and `dropped` events drive the rest.

Every native operation has a request ID and every utterance a turn ID; an interruption stops
native work and playback at once, then sends an `InterruptionFrame` through Pipecat. Only
played sentences enter the context: at most 32 turns and 32,000 characters, with each human
line capped at 2,000. `LanguageModelContext` keeps the most recent turns that fit the model's
`contextSize`, counted with `tokenCount(for:)`, less 160 response and 128 safety tokens. After
each turn the host prewarms a `LanguageModelSession` for the next; `NativeModelWorkCoordinator`
serializes preparation, token counting and generation.

The context lives in Python for one session; New conversation starts afresh. Separately, the
app keeps each conversation's transcript (`ConversationHistory.swift`): a JSON file per
conversation in Application Support, excluded from backups, with no audio. Settings can stop
keeping them or delete them all.

## Build

`scripts/setup.py` downloads the pipecat-ai wheel, checks its SHA-256 and applies the patch in
`.build/pipecat-ai/`. It checks the models (`scripts/phonon_package.py`,
`scripts/audience_package.py`), fetches BeeWare's Python for iOS into `Vendor/`, cross-compiles
pydantic-core and `native/phonon-ffi` for the device and the Simulator (`scripts/build_native.py`),
stages the Python packages pinned by `uv.lock` (`scripts/stage_python.py`) and generates the
Xcode project (`scripts/generate_project.py`), which uses no Swift packages.

The "Bundle Python, Phonon and Audience" build phase runs `scripts/bundle_runtime.py`:

- **Python:** the standard library without what the app never imports (`ssl` and OpenSSL
  included, so `hashlib` uses CPython's own hashes), and only the Pipecat modules the app's code
  can import. Native modules become signed frameworks.
- **Models:** Phonon's `config.json`, `model.q8.gguf` and `tokenizer.json` with the characters'
  voices into `phonon/`, and the compiled Audience models into `audience/`.

The privacy manifest declares no tracking and no collected data, with reasons for user defaults,
system boot time and file timestamps.

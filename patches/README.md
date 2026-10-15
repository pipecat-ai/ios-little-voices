# Pipecat patch

The app runs the official [pipecat-ai](https://pypi.org/project/pipecat-ai/) 1.12.0 release
with `pipecat-ai-1.12.0.patch` applied. `scripts/setup.py` downloads the release wheel, checks
it against the SHA-256 pinned in `scripts/pipecat_package.py`, applies the patch and leaves the
result in `.build/pipecat-ai/`: the tests import Pipecat from there, and the app bundles the
modules it could import from there. The app's own Apple services live in
`src/python/pipecat_apple/` and import Pipecat like any application.

Each change is a candidate to propose upstream, after which it leaves the patch.

## What the patch changes

The phone has none of Pipecat's desktop dependencies (numpy, Pillow, soxr, sentencex,
num2words, audioop-lts, loudness) and no OpenSSL, so these modules import them only where
they are used:

| File | Imported on use |
| --- | --- |
| `audio/utils.py` | numpy, loudness, audioop and the soxr resamplers |
| `processors/aggregators/llm_context.py` | Pillow |
| `transports/base_output.py` | Pillow and the DTMF audio |
| `utils/string.py` | sentencex |
| `utils/text/transforms/{currency,dates,numbers,percentages}.py` | num2words |
| `services/websocket_service.py` | the websocket client, which imports `ssl` |
| `services/tts_service.py` | the default resampler, created on first use |

And these give the app what it needs from Pipecat's own classes:

| File | Change | Why |
| --- | --- | --- |
| `utils/text/simple_text_aggregator.py` | `sentence_boundary_matcher` and `max_buffer_chars` | Sentences end where the host's tokenizer ends them, and a speech request has a bounded length. |
| `audio/vad/vad_analyzer.py` | `_update_vad_state()` and `_finalize_vad_state()` | `AppleVADAnalyzer` debounces the native classifier's scores with Pipecat's state machine. |
| `processors/aggregators/llm_text_processor.py` | Aggregated text keeps its source frames' metadata | The turn and speaker tags reach the TTS service. |

Pipecat's worker observer imports `attrs`, which pipecat-ai doesn't declare; the app bundles
attrs rather than patching the import.

## Moving to a new release

Apply the patch to a clone of [pipecat](https://github.com/pipecat-ai/pipecat) at the new
release's tag (`patch -p1 -d src -i <this patch>`), resolve what no longer applies, and save
the clone's `git diff --relative=src` as `pipecat-ai-<version>.patch`. Then update
`PIPECAT_VERSION`, `PIPECAT_URL` and `PIPECAT_SHA256` in `scripts/pipecat_package.py`, run
`uv run --no-sync python scripts/setup.py --pipecat-only` and the tests.

`pipecat_apple` also relies on these private Pipecat APIs, which a new release can change:

- `TTSService._turn_context_id` and `_record_context_audio_outcome()`
- `RTVIObserver._handle_llm_text_frame()`, `_handle_aggregated_llm_text()`,
  `_send_aggregated_llm_text()` and `_queued_aggregated_text_frames`
- `LLMService._settings`
- `BaseLLMAdapter._extract_initial_system()` and `_resolve_system_instruction()`
- `FrameProcessor.process_frame()`, called directly to bypass a subclass's handling

//! Streaming C ABI for Gradium Phonon, run by the open-source `ptts` runtime.
use ptts::checkpoint::read_config;
use ptts::preprocess::Lang;
use ptts::synth::{DeviceKind, Quant, SpeechOptions, Synth};
use std::ffi::{CStr, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};

// The same text and voice always produce the same audio. Temperature is ptts's default.
const SEED: u64 = 42;

pub struct PhononModel {
    synth: Synth,
    voices: Vec<String>,
}
pub struct PhononCancellation(AtomicBool);
type AudioCallback = unsafe extern "C" fn(*const f32, usize, *mut c_void) -> bool;

unsafe fn string(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("A required string is missing".into());
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(str::to_owned)
        .map_err(|e| e.to_string())
}

unsafe fn write_error(ptr: *mut c_char, capacity: usize, message: &str) {
    if !ptr.is_null() && capacity > 0 {
        let bytes = message.as_bytes();
        let n = bytes.len().min(capacity - 1);
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr.cast(), n);
            *ptr.add(n) = 0;
        }
    }
}

// `root` is a Phonon checkpoint: config.json, model.q8.gguf, tokenizer.json and
// voices/<name>.safetensors. `voices` names one or more of those voices, one per line;
// phonon_speak selects one by its index.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn phonon_load(
    root: *const c_char,
    voices: *const c_char,
    error: *mut c_char,
    capacity: usize,
) -> *mut PhononModel {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<PhononModel, String> {
        let root = PathBuf::from(unsafe { string(root)? });
        let voices: Vec<String> = unsafe { string(voices)? }.lines().map(str::to_owned).collect();
        let config = read_config(root.join("config.json")).map_err(|e| e.to_string())?;
        let mut builder = Synth::builder(config, root.join("model.q8.gguf"), Lang::En)
            .tokenizer_file(root.join("tokenizer.json"))
            .device(DeviceKind::Cpu)
            .quant(Quant::Q80)
            .seed(SEED);
        for voice in &voices {
            // Voice selection is a file name, never a caller-supplied path.
            if voice.is_empty() || voice.contains('/') || voice.contains('\\') || voice.contains("..") {
                return Err("Invalid voice name".into());
            }
            builder = builder.add_voice(voice, root.join("voices").join(format!("{voice}.safetensors")));
        }
        if voices.is_empty() {
            return Err("No voice to load".into());
        }
        let synth = builder.build().map_err(|e| e.to_string())?;
        Ok(PhononModel { synth, voices })
    }));
    match result {
        Ok(Ok(model)) => Box::into_raw(Box::new(model)),
        other => {
            let message = match other {
                Ok(Err(e)) => e,
                _ => "Phonon panicked while loading the model".into(),
            };
            unsafe {
                write_error(error, capacity, &message);
            }
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn phonon_free(model: *mut PhononModel) {
    if !model.is_null() {
        drop(unsafe { Box::from_raw(model) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn phonon_cancellation_new() -> *mut PhononCancellation {
    Box::into_raw(Box::new(PhononCancellation(AtomicBool::new(false))))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn phonon_cancel(token: *mut PhononCancellation) {
    if let Some(token) = unsafe { token.as_ref() } {
        token.0.store(true, Ordering::Release);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn phonon_cancellation_free(token: *mut PhononCancellation) {
    if !token.is_null() {
        drop(unsafe { Box::from_raw(token) });
    }
}

// Speaks `text` in the voice at index `voice` of those loaded. Returns 0 on success, 1 on
// cancellation, and -1 on error; text with nothing to say aloud succeeds with no audio. Panics
// never unwind into Swift. Cancellation stops generation at its next PCM chunk and returns once
// ptts's workers have stopped.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn phonon_speak(
    model: *const PhononModel,
    text: *const c_char,
    voice: usize,
    token: *const PhononCancellation,
    callback: AudioCallback,
    context: *mut c_void,
    error: *mut c_char,
    capacity: usize,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<i32, String> {
        let model = unsafe { model.as_ref() }.ok_or("Model is not loaded")?;
        let token = unsafe { token.as_ref() }.ok_or("Cancellation token is missing")?;
        let text = unsafe { string(text)? };
        if text.chars().count() > 600 {
            return Err("Speech text exceeds 600 characters".into());
        }
        let voice = model.voices.get(voice).ok_or_else(|| format!("invalid voice id: {voice}"))?;
        if token.0.load(Ordering::Acquire) {
            return Ok(1);
        }
        let options = SpeechOptions::default().voice(voice.as_str());
        // Dropping the stream on any return below stops and joins its workers.
        let stream = match model.synth.stream_with(&text, &options) {
            Ok(stream) => stream,
            // Text that normalizes to nothing, such as emoji alone, is silence rather than a failure.
            Err(ptts::Error::InvalidArgument(message)) if message.starts_with("nothing to synthesize") => {
                return Ok(0);
            }
            Err(e) => return Err(e.to_string()),
        };
        for pcm in stream {
            let pcm = pcm.map_err(|e| e.to_string())?;
            if token.0.load(Ordering::Acquire)
                || !unsafe { callback(pcm.as_ptr(), pcm.len(), context) }
            {
                token.0.store(true, Ordering::Release);
                return Ok(1);
            }
        }
        Ok(if token.0.load(Ordering::Acquire) { 1 } else { 0 })
    }));
    match result {
        Ok(Ok(status)) => status,
        other => {
            let message = match other {
                Ok(Err(e)) => e,
                _ => "Phonon panicked during speech generation".into(),
            };
            unsafe {
                write_error(error, capacity, &message);
            }
            -1
        }
    }
}

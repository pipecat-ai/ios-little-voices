"""Regenerate the lipsync golden fixture from the pipecat-visemes reference analyzer.

The app's Swift analyzer is a port of pipecat-visemes' FormantLipsyncAnalyzer. This
script synthesizes deterministic speech-like audio with that project's test
synthesizer, runs the Python analyzer over it, and writes the audio and the expected
keyframes and events that tests/native/LipsyncChecks.swift compares against:

    /path/to/pipecat-visemes/server/.venv/bin/python make_fixture.py /path/to/pipecat-visemes

Pass --input to analyze an existing 16 kHz mono WAV instead (no fixture is written
unless --output is given). --dead-band analyzes with that dead band instead of the
reference default, as the app runs it, and writes expected-dead-band-<value>.json:

    .../python make_fixture.py /path/to/pipecat-visemes --input speech.wav --dead-band 0 --output .
"""

import argparse
import asyncio
import json
import subprocess
import sys
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHUNK = 1280  # 80 ms at 16 kHz, like one Phonon frame after resampling.


def synthesize(synth_vowel):
    import numpy as np

    rng = np.random.default_rng(7)
    fs = 16000

    def silence(secs):
        return (rng.standard_normal(int(secs * fs)) * 2e-4).astype(np.float32)

    def segment(f1, f2, secs, gain, f0=120, **kwargs):
        x = synth_vowel(f1, f2, f0=f0, secs=secs, **kwargs) * gain
        fade = int(0.008 * fs)
        ramp = np.linspace(0.0, 1.0, fade, dtype=np.float32)
        x[:fade] *= ramp
        x[-fade:] *= ramp[::-1]
        return x

    parts = [
        silence(0.3),
        segment(750, 1200, 0.35, 0.5),  # /a/
        silence(0.08) * 10,  # bilabial closure inside speech
        segment(300, 2300, 0.3, 0.45),  # /i/
        segment(320, 800, 0.3, 0.45),  # /u/
        segment(250, 1950, 0.25, 0.3, bandwidths=(60, 450, 450)),  # nasal-like murmur
        silence(0.3),
        segment(500, 900, 0.3, 0.5, f0=190),  # /o/, higher pitch
        segment(650, 1700, 0.3, 0.5, f0=190),  # /ɛ/
        silence(0.5),
    ]
    return np.concatenate(parts).astype(np.float32)


def read_wav(path):
    import numpy as np

    with wave.open(str(path)) as handle:
        assert handle.getframerate() == 16000 and handle.getnchannels() == 1
        assert handle.getsampwidth() == 2
        data = handle.readframes(handle.getnframes())
    return np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0


def write_wav(path, samples):
    import numpy as np

    pcm = np.clip(np.round(samples * 32767.0), -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16000)
        handle.writeframes(pcm.tobytes())


async def analyze(samples, FormantLipsyncAnalyzer, LipsyncAnalysisContext, dead_band=None):
    options = {} if dead_band is None else {"dead_band": dead_band}
    analyzer = FormantLipsyncAnalyzer(**options)
    await analyzer.start(16000)
    context = LipsyncAnalysisContext(context_id="fixture", sample_rate=16000)
    keyframes, events = [], []
    for start in range(0, len(samples), CHUNK):
        result = await analyzer.analyze(samples[start : start + CHUNK], context)
        keyframes += result.keyframes
        events += result.events
    result = await analyzer.flush(context)
    keyframes += result.keyframes
    events += result.events
    return keyframes, events


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("visemes", type=Path, help="Path to a pipecat-visemes checkout")
    parser.add_argument("--input", type=Path, help="Analyze this 16 kHz mono WAV instead")
    parser.add_argument("--output", type=Path, help="Directory for speech.wav and expected.json")
    parser.add_argument(
        "--dead-band", type=float, help="Analyzer dead band (default: the reference's)"
    )
    args = parser.parse_args()
    server = args.visemes / "server"
    sys.path[:0] = [str(server), str(server / "tests")]
    from lipsync.base_lipsync_analyzer import LipsyncAnalysisContext
    from lipsync.formant_lipsync_analyzer import FormantLipsyncAnalyzer
    from synth import synth_vowel

    # An --input analysis is printed unless --output names a directory.
    output = args.output or (None if args.input else HERE)
    if args.input:
        samples = read_wav(args.input)
    else:
        write_wav(output / "speech.wav", synthesize(synth_vowel))
        # Analyze exactly what the Swift check reads back: the 16-bit WAV.
        samples = read_wav(output / "speech.wav")
    keyframes, events = asyncio.run(
        analyze(samples, FormantLipsyncAnalyzer, LipsyncAnalysisContext, args.dead_band)
    )
    commit = subprocess.run(
        ["git", "-C", str(args.visemes), "rev-parse", "--short", "HEAD"],
        capture_output=True,
        text=True,
    ).stdout.strip()
    expected = {
        "source": f"pipecat-visemes {commit}",
        "chunk": CHUNK,
        "keyframes": [
            [k.offset, k.openness, k.width, k.rounding, k.energy, k.pitch, k.confidence]
            for k in keyframes
        ],
        "events": [[e.offset, str(e.kind), e.duration, e.confidence] for e in events],
    }
    name = "expected.json"
    if args.dead_band is not None:
        expected["dead_band"] = args.dead_band
        name = f"expected-dead-band-{args.dead_band:g}.json"
    text = json.dumps(expected, indent=1)
    if output is not None:
        (output / name).write_text(text + "\n")
    else:
        print(text)
    print(f"{len(keyframes)} keyframes, {len(events)} events", file=sys.stderr)


if __name__ == "__main__":
    main()

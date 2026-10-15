"""Write the Phonon-voiced clips LipsyncTextChecks aligns, which the repository cannot hold, from
the local checkpoint (models/phonon): 24 kHz 16-bit mono, trimmed 0.25 s after the last sound.

    uv run --no-sync python scripts/lipsync/make_fixtures.py

phonon-ffi seeds Phonon, so the clips come out the same every time, give or take a least
significant bit from floating-point order.
"""

import wave

from speech import ROOT, pcm

FIXTURES = ROOT / "tests/fixtures/lipsync"
CLIPS = [
    ("who-knew.wav", "en_gb_Freya", "Who knew? You too, Sue?"),
    ("maybe-my-mommy.wav", "en_gb_Reuben", "Maybe my mommy may buy a puppy."),
]
BLOCK = 240  # 10 ms
SOUND = 0.01  # RMS of a block of speech, -40 dBFS


def main() -> None:
    for name, voice, text in CLIPS:
        samples = pcm(voice, text)
        loud = [
            k
            for k in range(len(samples) // BLOCK)
            if sum(x * x for x in samples[k * BLOCK : (k + 1) * BLOCK]) >= SOUND**2 * BLOCK
        ]
        end = min(len(samples), (loud[-1] + 1) * BLOCK + 6000)
        pcm16 = b"".join(
            round(max(-1.0, min(1.0, x)) * 32767).to_bytes(2, "little", signed=True)
            for x in samples[:end]
        )
        with wave.open(str(FIXTURES / name), "wb") as clip:
            clip.setnchannels(1)
            clip.setsampwidth(2)
            clip.setframerate(24_000)
            clip.writeframes(pcm16)
        print(f"{name}: {voice}, {end / 24_000:.2f} s")


if __name__ == "__main__":
    main()

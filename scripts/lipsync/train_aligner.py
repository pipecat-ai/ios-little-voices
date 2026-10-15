"""Train the lip-sync aligner's phone models on Phonon speech and write LipsyncAlignerModel.swift.

    uv run --no-sync --with numpy python scripts/lipsync/train_aligner.py [--voices A,B] [--output F]

Each sentence in sentences.txt is spoken in each voice by the local Phonon checkpoint and measured
as the app measures it (speech.py). Starting from phones spread evenly over each sentence's speech,
eight rounds of Viterbi alignment and re-estimation fit every phone a diagonal Gaussian over the
app's per-hop features and a log-normal duration. Alignment walks each sentence as LipsyncAligner
does: silence, each word's phones, an optional pause after each word, silence.
"""

import argparse
import textwrap
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import speech

HERE = Path(__file__).resolve().parent
OUTPUT = speech.ROOT / "src/ios/PipecatVoice/LipsyncAlignerModel.swift"
VOICES = ["en_gb_Freya", "en_gb_Reuben", "en_us_Brooklyn", "en_us_Harper"]
VOICES += ["en_gb_Tilly", "en_gb_Toby", "en_us_Marlowe", "en_us_Russell"]
ROUNDS = 8
EMISSION_WEIGHT = 0.15  # against durations, as LipsyncAligner weighs them
MAX_PHONE, MAX_SILENCE = 30, 400  # hops
NEG = -1e18
VOWELS = {"AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW"}
CONSONANTS = "B CH D DH F G HH JH K L M N NG P R S SH T TH V W Y Z ZH".split()
NAMES = sorted([*VOWELS, *CONSONANTS, "AX", "AXR", "IX", "SIL", "SP"])
PAUSE = {"": 0.12, ",": 0.75, ".": 0.9}  # how likely a pause follows a word, by its punctuation
# Flat-start durations in hops, the defaults until a phone has its own.
START = {
    **{"AA": 6, "AE": 6, "AH": 4.5, "AO": 6, "AW": 7.5, "AY": 7.5, "EH": 4.5, "ER": 5.5, "EY": 6.5},
    **{"IH": 3.5, "IY": 5, "OW": 7, "OY": 8, "UH": 4, "UW": 5.5, "AX": 2.5, "AXR": 3, "IX": 2.5},
    **{"B": 3, "D": 2.5, "G": 3, "P": 4, "T": 3.5, "K": 4, "CH": 5, "JH": 4.5, "F": 4.5, "V": 2.5},
    **{"TH": 4, "DH": 2, "S": 5, "Z": 3.5, "SH": 5.5, "ZH": 4, "HH": 3, "M": 3.5, "N": 3},
    **{"NG": 3.5, "L": 3, "R": 3, "W": 3, "Y": 2.5, "SP": 8},
}
# A model to borrow while a phone has too few hops of its own.
BACKOFF = {
    **{"SP": "SIL", "ZH": "SH", "OY": "AO", "AXR": "ER", "IX": "IH", "AX": "AH", "UH": "UW"},
    **{"NG": "N", "TH": "F", "DH": "D", "JH": "CH", "CH": "SH", "Y": "IY", "AW": "AA", "G": "K"},
}
REDUCED = {"AH": "AX", "ER": "AXR", "IH": "IX"}  # the unstressed vowels with models of their own
SWIFT = """\
{header}

/// The text aligner's phone models: a diagonal Gaussian over each hop's features (level, zero
/// crossings, c1…c12, level slope) and a log-normal duration.
enum LipsyncAlignerModel {{
    /// ARPAbet without stress, with AX, AXR and IX for unstressed AH, ER and IH, SIL for the
    /// silence around a sentence and SP for a pause between words.
    static let names: [String] = [
{names}
    ]
    static let means: [[Double]] = [
{means}
    ]
    static let variances: [[Double]] = [
{variances}
    ]
    /// Mean duration (hops) and log-normal spread, at least 0.35. `SP` is a pause between words,
    /// `SP,` one after a comma and `SP.` one after a full stop.
    static let durations: [String: (mean: Double, sigma: Double)] = [
{durations}
    ]
    /// The training voices' average c1…c12 mean and deviation, where a new voice's normalization
    /// starts.
    static let cepstralMean: [Double] = {cepstral_mean}
    static let cepstralDeviation: [Double] = {cepstral_deviation}
}}
"""


@dataclass
class State:
    key: str  # its model
    pause: str | None  # a pause's punctuation
    reduced: bool = False  # an unstressed full vowel, shorter

    @property
    def skippable(self) -> bool:
        return self.key in ("SIL", "SP")


def states(words: list[dict]) -> list[State]:
    """Silence, each word's phones and a possible pause after it, silence."""
    out = [State("SIL", None)]
    for w, word in enumerate(words):
        for phone in word["phones"]:
            symbol, stress = phone.rstrip("012"), phone[-1]
            key = REDUCED.get(symbol, symbol) if stress == "0" else symbol
            out.append(State(key, None, stress == "0" and key in VOWELS))
        if w < len(words) - 1:
            out.append(State("SP", word["pause"]))
    return [*out, State("SIL", None)]


def vectors(hops: np.ndarray, mean: np.ndarray, deviation: np.ndarray) -> np.ndarray:
    """LipsyncAligner's features: level, 4 × zero crossings, normalized cepstra, level slope."""
    level = hops[:, 0]
    slope = np.zeros(len(level))
    slope[1:-1] = (level[2:] - level[:-2]) / 2
    return np.column_stack([level, hops[:, 1] * 4, (hops[:, 2:] - mean) / deviation, slope])


def model(models: dict, key: str) -> tuple[np.ndarray, np.ndarray]:
    while key not in models:
        key = BACKOFF[key]
    return models[key]


def duration_logs(sentence: list[State], durations: dict, rate: float) -> np.ndarray:
    """log P(d) for d = 1… per state: log-normal over 1…MAX_PHONE, free for silence."""
    table = np.full((len(sentence), MAX_SILENCE), NEG)
    d = np.arange(1, MAX_PHONE + 1, dtype=float)
    for i, state in enumerate(sentence):
        if state.key == "SIL":
            table[i] = 0.0
            continue
        if state.key == "SP" and state.pause:
            mean, sigma = durations.get("SP" + state.pause, (15, 0.6))
        else:
            mean, sigma = durations.get(state.key, (START.get(state.key, 4), 0.5))
        mu = np.log(mean * (0.75 if state.reduced else 1) * rate) - sigma**2 / 2
        logs = -np.log(d * sigma * np.sqrt(2 * np.pi)) - (np.log(d) - mu) ** 2 / (2 * sigma**2)
        table[i, :MAX_PHONE] = logs - np.logaddexp.reduce(logs)
    return table


def viterbi(scores: np.ndarray, sentence: list[State], table: np.ndarray) -> list[tuple]:
    """The likeliest segmentation of the hops (rows of `scores`, the states' emission
    log-likelihoods; `table` from duration_logs) into the sentence's states, as (state, start,
    end) hops."""
    T, S = scores.shape
    cumulative = np.vstack([np.zeros(S), np.cumsum(scores, axis=0)])
    skippable = [state.skippable for state in sentence]
    enter, skip = np.zeros(S), np.full(S, NEG)
    for i, state in enumerate(sentence):
        if state.skippable:
            p = 0.5 if state.key == "SIL" else PAUSE[state.pause]
            enter[i], skip[i] = np.log(p), np.log(1 - p)
    # delta[t, s]: the best score of state s ending at hop t; entry[t, s]: of it starting there.
    delta, length = np.full((T + 1, S), NEG), np.zeros((T + 1, S), dtype=int)
    entry, source = np.full((T + 1, S), NEG), np.full((T + 1, S), -1)
    total = 0.0
    for s in range(S):  # the first state, or a later one when those before are skipped
        entry[0, s], source[0, s] = total + enter[s], -2
        if not skippable[s]:
            break
        total += skip[s]
    for t in range(1, T + 1):
        d = np.arange(1, min(t, MAX_SILENCE) + 1)
        candidates = entry[t - d] + table[:, : len(d)].T + (cumulative[t] - cumulative[t - d])
        best = np.argmax(candidates, axis=0)
        delta[t], length[t] = candidates[best, np.arange(S)], best + 1
        for s in range(1, S):  # from the state before, or across skipped ones
            top, origin, total = delta[t, s - 1], s - 1, 0.0
            for j in range(s - 1, 0, -1):
                if not skippable[j]:
                    break
                total += skip[j]
                if delta[t, j - 1] + total > top:
                    top, origin = delta[t, j - 1] + total, j - 1
            entry[t, s], source[t, s] = top + enter[s], origin
    ends, total = [], 0.0
    for s in range(S - 1, -1, -1):  # the last state, or an earlier one when those after are skipped
        ends.append((delta[T, s] + total, s))
        if not skippable[s]:
            break
        total += skip[s]
    _, s = max(ends)
    segments, t = [], T
    while t > 0 and s >= 0:
        start = t - length[t, s]
        segments.append((s, start, t))
        if source[start, s] == -2:
            break
        t, s = start, source[start, s]
    return segments[::-1]


def align(
    features: np.ndarray, sentence: list[State], models: dict, durations: dict
) -> tuple[list[tuple], float]:
    """The sentence's segments and speaking rate (its phones' time over their mean durations);
    the second alignment uses the rate the first found."""
    scores = {}
    for key in {state.key for state in sentence}:
        mean, var = model(models, key)
        scores[key] = -0.5 * ((features - mean) ** 2 / var + np.log(2 * np.pi * var)).sum(axis=1)
    emissions = np.stack([scores[state.key] * EMISSION_WEIGHT for state in sentence], axis=1)
    phones = [state for state in sentence if not state.skippable]
    expected = sum(durations.get(s.key, (START.get(s.key, 4), 0))[0] for s in phones)
    rate = 1.0
    for _ in range(2):
        segments = viterbi(emissions, sentence, duration_logs(sentence, durations, rate))
        spoken = sum(end - start for s, start, end in segments if not sentence[s].skippable)
        rate = float(np.clip(spoken / max(expected, 1), 0.6, 1.6))
    return segments, rate


def flat_start(sentence: list[State], level: np.ndarray) -> list[tuple]:
    """The phones spread over the sentence's speech in proportion to their usual durations."""
    speech_hops = np.flatnonzero(level > 0.55)
    first, last = (speech_hops[0], speech_hops[-1] + 1) if len(speech_hops) else (0, len(level))
    phones = [i for i, state in enumerate(sentence) if not state.skippable]
    weights = np.array([START[sentence[i].key] for i in phones], dtype=float)
    bounds = first + np.concatenate([[0], np.cumsum(weights)]) / weights.sum() * (last - first)
    segments = [(0, 0, first)] if first > 0 else []
    for k, i in enumerate(phones):
        start, end = int(round(bounds[k])), int(round(bounds[k + 1]))
        if end > start:
            segments.append((i, start, end))
    if last < len(level):
        segments.append((len(sentence) - 1, last, len(level)))
    return segments


def estimate(frames: dict, lengths: dict) -> tuple[dict, dict]:
    """Gaussians from each model's hops (variances floored at 2% of the overall variance) and
    log-normal durations from each model's lengths, where there are at least five."""
    floor = 0.02 * np.vstack([np.vstack(chunks) for chunks in frames.values()]).var(axis=0)
    models = {}
    for key, chunks in frames.items():
        hops = np.vstack(chunks)
        if len(hops) >= 5:
            models[key] = (hops.mean(axis=0), np.maximum(hops.var(axis=0), floor))
    durations = {}
    for key, values in lengths.items():
        if len(values) >= 5:
            logs = np.log(values)
            mean = float(np.exp(logs.mean() + logs.var() / 2))
            durations[key] = (mean, max(float(logs.std()), 0.25))
    return models, durations


def train(corpus: list[tuple[np.ndarray, list[State]]]) -> tuple[dict, dict]:
    """Models and durations from a flat start, then ROUNDS of alignment and re-estimation."""
    frames = {}
    for features, sentence in corpus:
        for s, start, end in flat_start(sentence, features[:, 0]):
            frames.setdefault(sentence[s].key, []).append(features[start:end])
    models, durations = estimate(frames, {})
    for round_ in range(ROUNDS):
        frames, lengths = {}, {}
        for features, sentence in corpus:
            segments, rate = align(features, sentence, models, durations)
            for s, start, end in segments:
                state = sentence[s]
                frames.setdefault(state.key, []).append(features[start:end])
                if state.key != "SIL":
                    key = state.key + (state.pause or "")
                    lengths.setdefault(key, []).append((end - start) / rate)
        models, durations = estimate(frames, lengths)
        print(f"round {round_ + 1} of {ROUNDS}", flush=True)
    return models, durations


def number(x: float) -> str:
    """Four significant digits, as a Swift Double literal."""
    text = f"{x:.4g}"
    if "e" in text:
        text = f"{x:.6f}".rstrip("0").rstrip(".")
    return text if "." in text else text + ".0"


def row(values) -> str:
    return "[" + ", ".join(number(v) for v in values) + "]"


def swift(models: dict, durations: dict, prior: tuple, voices: list[str]) -> str:
    names = f"{', '.join(voices[:-1])} and {voices[-1]}" if len(voices) > 1 else voices[0]
    source = (
        "Generated by scripts/lipsync/train_aligner.py, from Phonon speaking the sentences in"
        f" scripts/lipsync/sentences.txt in {names}. Regenerate it rather than edit it:"
    )
    header = [f"// {line}" for line in textwrap.wrap(source, 97)]
    header.append("//   uv run --no-sync --with numpy python scripts/lipsync/train_aligner.py")
    return SWIFT.format(
        header="\n".join(header),
        names="\n".join(
            "        " + ", ".join(f'"{k}"' for k in NAMES[i : i + 15]) + ","
            for i in range(0, len(NAMES), 15)
        ),
        means="\n".join(f"        {row(model(models, k)[0])},  // {k}" for k in NAMES),
        variances="\n".join(f"        {row(model(models, k)[1])},  // {k}" for k in NAMES),
        durations="\n".join(
            f'        "{k}": ({number(mean)}, {number(max(sigma, 0.35))}),'
            for k, (mean, sigma) in sorted(durations.items())
        ),
        cepstral_mean=row(prior[0]),
        cepstral_deviation=row(prior[1]),
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--voices", default=",".join(VOICES), help="voices in models/phonon/voices")
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()
    voices = args.voices.split(",")
    text = (HERE / "sentences.txt").read_text().splitlines()
    sentences = [line for line in text if line.strip() and not line.startswith("#")]
    began = time.monotonic()
    corpus, means, variances = [], [], []
    for voice in voices:
        spoken = speech.features(voice, sentences)
        hops = [np.array(sentence["hops"]) for sentence in spoken]
        # Cepstra normalized over each voice's loud hops, where the app's running normalization
        # settles for that voice.
        loud = np.vstack([h[h[:, 0] > 0.5, 2:] for h in hops])
        mean, deviation = loud.mean(axis=0), loud.std(axis=0)
        means.append(mean)
        variances.append(deviation**2)
        corpus += [(vectors(h, mean, deviation), states(s["words"])) for h, s in zip(hops, spoken)]
        print(f"{voice}: {len(spoken)} sentences, {time.monotonic() - began:.0f} s", flush=True)
    models, durations = train(corpus)
    prior = (np.mean(means, axis=0), np.sqrt(np.mean(variances, axis=0)))
    args.output.write_text(swift(models, durations, prior, voices))
    print(f"wrote {args.output} in {time.monotonic() - began:.0f} s")


if __name__ == "__main__":
    main()

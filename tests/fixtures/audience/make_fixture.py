"""Regenerate the Audience fixtures from the SpellSpeak reference runtime.

The app tokenizes and runs SpellSpeak Audience natively (AudienceTokenizer.swift, AudienceModel.swift). This
records what the reference does on the same inputs:

- `tokenization.json`: the `tokenizers` library's ids and offsets for every card and line text the Core ML check's
  requests render, plus edge cases (whitespace runs, special-token text, emoji, accents, truncation).
- `answers.json`: for a set of requests, the inputs the app's Python side computes (card texts, the line, the
  current line's length, the features) and ONNX Runtime's answer.

Run it with the Core ML converter's environment, which has the runtime's dependencies:

    uv run --project /path/to/spellspeak-models/audience/coreml python make_fixture.py \\
        /path/to/spellspeak-models [--model-dir DIR]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
RELEASE = "rc2.1"
EDGE_CASES = [
    "",
    "a  b   c",
    "  lead",
    "end  ",
    "tabs\tand\nnewlines\r\n",
    "nbsp and em space",
    "vertical\x0btab",
    "café naïve résumé",
    "emoji 😀 and 👍🏽 and 🧑‍🚀",
    "Tomas: it's 12.5 [CLS] ok",
    "[SEP][PAD]",
    "|||EMAIL_ADDRESS|||",
    "don't, won't, I'll, we've, they're, she'd",
    "CAPS 'S 'T",
    "curly ‘quotes’ and “doubles” – dash — em",
    "数字 和 中文",
    "x" * 300,
    " ".join(["word"] * 120),
    "1234567890 3.14159 1,000,000",
    "Ṡupercalifragilistic",
    "á combining",
]


def main() -> None:
    parser = argparse.ArgumentParser(description="Regenerate the Audience fixtures.")
    parser.add_argument("spellspeak", type=pathlib.Path, help="a spellspeak-models checkout")
    parser.add_argument("--model-dir", type=pathlib.Path, help=f"{RELEASE}'s 16-bit model files")
    parser.add_argument("--requests", type=int, default=160)
    args = parser.parse_args()
    sys.path.insert(0, str(args.spellspeak / "audience" / "coreml"))
    sys.path.insert(0, str(args.spellspeak / "audience" / "releases" / RELEASE / "runtime"))
    import check  # the Core ML check's request generator
    from harness.addressee.classifier import load_classifier
    from harness.addressee.features import card_only, line_features, line_input, person_features
    from tokenizers import Tokenizer

    source = args.model_dir
    if source is None:
        from huggingface_hub import snapshot_download

        source = pathlib.Path(
            snapshot_download(
                "spellspeak/audience",
                revision=RELEASE,
                allow_patterns=[
                    "encoder_fp16.onnx",
                    "head_fp16.onnx",
                    "tokenizer.json",
                    "config.json",
                ],
            )
        )
    config = json.loads((source / "config.json").read_text())
    reference = load_classifier(source, threads=1, precision="fp16")
    tokenizer = Tokenizer.from_file(str(source / "tokenizer.json"))
    tokenizer.no_padding()

    requests = check.requests(args.requests, seed=11)
    texts: dict[str, int] = {}
    for req in requests:
        for card in req.present:
            texts[card_only(card)] = config["card_len"]
        texts[line_input(req)[0]] = config["line_len"]
    for text in EDGE_CASES:
        texts[text] = config["line_len"]
        texts[text + " "] = config["card_len"]
    cases = []
    for text, limit in texts.items():
        tokenizer.enable_truncation(limit)
        enc = tokenizer.encode(text)
        cases.append(
            {
                "text": text,
                "max_length": limit,
                "ids": enc.ids,
                "offsets": [list(o) for o in enc.offsets],
            }
        )

    answers = []
    for req in requests:
        line, current = line_input(req)
        answer = reference.answer(req)
        answers.append(
            {
                "cards": [card_only(c) for c in req.present],
                "line": line,
                "current": current,
                "people": person_features(req, config["render_version"]),
                "features": line_features(req, config["render_version"]),
                "person": [answer.addressed[i] for i in req.ids],
                "unclear": answer.unclear,
                "group": answer.to_group,
            }
        )
    commit = subprocess.run(
        ["git", "-C", str(args.spellspeak), "rev-parse", "--short", "HEAD"],
        capture_output=True,
        text=True,
    ).stdout.strip()
    stamp = {
        "source": f"spellspeak-models {commit}, Audience {RELEASE} (16-bit), onnxruntime reference"
    }
    (HERE / "tokenization.json").write_text(
        json.dumps({**stamp, "cases": cases}, ensure_ascii=False) + "\n"
    )
    (HERE / "answers.json").write_text(
        json.dumps({**stamp, "requests": answers}, ensure_ascii=False) + "\n"
    )
    print(f"{len(cases)} tokenizer cases, {len(answers)} answers")


if __name__ == "__main__":
    main()

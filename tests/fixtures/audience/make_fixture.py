"""Regenerate the Audience fixtures from Pipecat Audience's reference runtime.

The app tokenizes and runs Pipecat Audience natively (AudienceTokenizer.swift, AudienceModel.swift). This
records what the reference does on the same inputs:

- `tokenization.json`: the `tokenizers` library's ids and offsets for every card and line text the Core ML check's
  requests render, plus edge cases (whitespace runs, special-token text, emoji, accents, truncation).
- `answers.json`: for a set of requests, the inputs the app's Python side computes (card texts, the line, the
  current line's length, the features) and ONNX Runtime's answer.

The release's runtime and 16-bit model come from its Hugging Face repo, at the commit the app pins. Run it with the
runtime's dependencies:

    uv run --no-project --with onnxruntime --with tokenizers --with numpy --with pydantic \\
        --with huggingface_hub python tests/fixtures/audience/make_fixture.py [--model-dir DIR]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import random
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from audience_package import AUDIENCE_RELEASE, AUDIENCE_REPO, AUDIENCE_REVISION  # noqa: E402

RELEASE = AUDIENCE_RELEASE
EDGE_CASES = [
    "",
    "a  b   c",
    "  lead",
    "end  ",
    "tabs\tand\nnewlines\r\n",
    "nbsp\xa0and\u2003em space",
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
    "a\u0301 combining",
]

# The Core ML check's requests: the release example's tavern, the Pipecat example's garage, a pair, and crowds of
# up to eight; the player or a character speaking; with and without spatial facts; with up to four lines of history.
PLAYER_LINES = [
    "You in the red hat, another round.", "Hello.", "You lied to me.", "Who knows where the mill key is?",
    "Tomas, another round.", "Wren, were you there last night?", "Hey, all of you!", "Listen up, everyone.",
    "Anyone seen my horse?", "Does anybody here sell rope?", "Good evening.", "Yes.", "No idea, sorry.",
    "What's your name?", "How much for a room?", "You're useless.", "Get out of my way.", "Thanks, both of you.",
    "Nova and Kai, what's the plan?", "Bruno, can you fix my bike?", "Oi, you!", "You in the orange jumpsuit, wait up.",
    "The robot by the door, what do you see?", "Kai, can you get into that terminal?", "Which of you is the mechanic?",
    "Who's got a light?", "Should I skip the gym today?", "Is it wrong to eat cake for breakfast?", "Angel, help me out.",
    "Devil, tempt me.", "Hey, you with the horns, what should I eat?", "Tell me, halo, should I go?", "What do you think?",
    "I don't know, it feels greedy.", "Can any of you help me?", "Excuse me.", "Sorry, I didn't mean that.",
    "You there, with the longbow.", "Old man, where's the harbour?", "Can I buy you a drink?", "That's not fair.",
    "I'll take two.", "Right, listen to me, all of you.", "You two, stop arguing.", "Bruno, ask Atlas if the door's locked.",
    "Nova, who can fix my bike?", "Is there anyone here who can read this?", "Where am I?", "Goodbye.",
    "Atlas, scan the room.", "Hey, barkeep!", "Tell Wren I said thanks.", "You, talking to the barkeep.", "Why?",
    "Come with me.", "Have you seen anyone suspicious?", "Who are you?", "Do you two know each other?", "Cheers.",
]  # fmt: skip
CHARACTER_LINES = [
    "No idea, sorry.", "Wren, were you there?", "You're no fun at all.", "Don't listen to them.", "Ask Bruno, he fixes bikes.",
    "Why are you always so serious?", "Because I care about them.", "Go to the gym. You'll thank yourself tonight.",
    "Oh, please, Angel. One lazy day won't ruin anything.", "Here you go, another round.", "I saw nothing.",
    "Can I help you?", "Keep your voice down.", "Says the one with a halo.", "Fine, I'll do it.", "Is that so?",
]  # fmt: skip


def card(pid: str, label: str, features: dict[str, str], aliases: tuple[str, ...] = ()):
    from contracts.schemas.person_card import PersonCard

    return PersonCard.model_validate(
        {
            "id": pid,
            "label": label,
            "aliases": list(aliases),
            "features": [{"key": k, "value": v} for k, v in features.items()],
        }
    )


def casts() -> dict[str, list]:
    tavern = [
        card(
            "tomas",
            "Tomas",
            {"role": "barkeep", "headwear": "red hat", "holding": "a tankard"},
            ("barkeep",),
        ),
        card("wren", "Wren", {"role": "mercenary", "race": "elf", "carrying": "a longbow"}),
        card("oskar", "the old sailor", {"build": "stout", "holding": "a pipe"}),
    ]
    garage = [
        card(
            "nova",
            "Nova",
            {
                "role": "courier",
                "appearance": "young woman, a girl",
                "hair": "long purple ponytail",
                "clothing": "orange jumpsuit (a flight suit) and boots",
                "near": "a dirt bike, one hand on the handlebar",
            },
        ),
        card(
            "bruno",
            "Bruno",
            {
                "role": "engineer",
                "appearance": "bearded man",
                "headwear": "lime-green cap",
                "clothing": "lime-green hoodie and a tool belt",
                "doing": "crouched on a stool, fixing a machine",
            },
        ),
        card(
            "atlas",
            "Atlas",
            {
                "role": "robot",
                "appearance": "tall humanoid robot",
                "build": "gunmetal armour plating",
                "eyes": "glowing red eyes",
                "near": "the doorway at the back",
            },
        ),
        card(
            "kai",
            "Kai",
            {
                "role": "hacker",
                "appearance": "woman in black",
                "hair": "hidden",
                "clothing": "black jacket with patches",
                "headwear": "black helmet with a visor",
                "near": "the terminals and screens, half turned away",
            },
        ),
    ]
    pair = [
        card(
            "angel",
            "Angel",
            {"role": "angel", "appearance": "white robe, feathered wings and a golden halo"},
        ),
        card(
            "devil",
            "Devil",
            {"role": "devil", "appearance": "red skin, little horns and a pointy tail"},
        ),
    ]
    everyone = tavern + garage + pair
    return {"tavern": tavern, "garage": garage, "pair": pair, "everyone": everyone}


def requests(count: int, seed: int = 7):
    from contracts.schemas.addressee import PLAYER, AddresseeRequest, HistoryLine
    from contracts.schemas.person_card import SpatialFacts

    rng = random.Random(seed)
    groups = casts()
    player_card = card("player", "the traveller", {"clothing": "a green cloak"})
    out = []
    while len(out) < count:
        name = rng.choice(["tavern", "garage", "pair", "crowd", "one"])
        if name == "crowd":
            people = rng.sample(groups["everyone"], rng.randint(4, 8))
        elif name == "one":
            people = [rng.choice(groups["everyone"])]
        else:
            people = list(groups[name])
        speaker = PLAYER
        if rng.random() < 0.3 and len(people) >= 1:
            speaker_card = rng.choice(people)
            speaker = speaker_card.id
            people = [player_card] + [c for c in people if c.id != speaker]
        facts = rng.random() < 0.5
        if facts:
            last = rng.choice([None] + [c.id for c in people])
            people = [
                c.model_copy(
                    update={
                        "spatial": SpatialFacts(
                            distance=rng.choice(["near", "mid", "far", None]),
                            in_view=rng.choice([True, False, None]),
                            in_group=rng.choice([True, False, None]),
                            following=rng.random() < 0.1,
                            asked_you=rng.random() < 0.1,
                            last_spoke_with_you=None if last is None else c.id == last,
                        )
                    }
                )
                for c in people
            ]
        ids = [c.id for c in people]
        known = ids + [PLAYER] if speaker != PLAYER else ids
        history = []
        for _ in range(rng.randint(0, 4)):
            who = rng.choice(known + ([speaker] if speaker != PLAYER else [PLAYER]))
            pool = known + [speaker] if speaker != PLAYER else known + [PLAYER]
            to = [t for t in rng.sample(pool, rng.randint(0, 2)) if t != who]
            history.append(
                HistoryLine(speaker=who, to=to, text=rng.choice(PLAYER_LINES + CHARACTER_LINES))
            )
        try:
            if speaker == PLAYER:
                req = AddresseeRequest(
                    text=rng.choice(PLAYER_LINES), present=people, history=history
                )
            else:
                req = AddresseeRequest(
                    speaker=speaker,
                    speaker_label=speaker_card.label,
                    text=rng.choice(CHARACTER_LINES),
                    present=people,
                    history=history,
                )
        except ValueError:
            continue  # a combination the schema refuses, such as a history naming someone absent
        out.append(req)
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description="Regenerate the Audience fixtures.")
    parser.add_argument(
        "--model-dir",
        type=pathlib.Path,
        help=f"a copy of {RELEASE}: its runtime/ and 16-bit model files",
    )
    parser.add_argument("--requests", type=int, default=160)
    args = parser.parse_args()
    source = args.model_dir
    if source is None:
        from huggingface_hub import snapshot_download

        source = pathlib.Path(
            snapshot_download(
                AUDIENCE_REPO,
                revision=AUDIENCE_REVISION,
                allow_patterns=[
                    "runtime/**",
                    "encoder_fp16.onnx",
                    "head_fp16.onnx",
                    "tokenizer.json",
                    "config.json",
                ],
            )
        )
    sys.path.insert(0, str(source / "runtime"))
    from harness.addressee.classifier import load_classifier
    from harness.addressee.features import card_only, line_features, line_input, person_features
    from tokenizers import Tokenizer

    config = json.loads((source / "config.json").read_text())
    reference = load_classifier(source, threads=1, precision="fp16")
    tokenizer = Tokenizer.from_file(str(source / "tokenizer.json"))
    tokenizer.no_padding()

    requests_ = requests(args.requests, seed=11)
    texts: dict[str, int] = {}
    for req in requests_:
        for card_ in req.present:
            texts[card_only(card_)] = config["card_len"]
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
    for req in requests_:
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
    stamp = {
        "source": f"{AUDIENCE_REPO}@{AUDIENCE_REVISION[:7]}, Audience {RELEASE} (16-bit), onnxruntime reference"
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

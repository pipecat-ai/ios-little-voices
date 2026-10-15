"""Inputs for the cached-cards addressee model (`TT_VERSION`). Shared by training and the runtime.

The single-pass model reads every card with every line (harness/addressee/render.py), which cost 18 to 65 ms on our
test Mac for one to eight people. This model splits the work:

- A card's text, without its spatial facts, is encoded once and cached. It changes only when what the player can see
  of that person changes (an item picked up, a hood raised, walking over to the fire).
- The line is encoded on every utterance, with the line before it as context: a few dozen tokens.
- The spatial facts and the conversation state become a small vector per person, so moving people around never
  re-encodes anything.

Per-person vector (addressee-tt-0.5, 25): distance near, mid, far, unknown; in view yes, no, unknown; in group yes,
no, unknown; following; asked you (fact); spoke with you last (fact); the last history line was theirs to the speaker;
it was a question; the speaker's last line was to them; they spoke at all in the history; the speaker spoke to them at
all; one over the number of people present; then the rules baseline's word matcher and answer: their name or alias
used to call them, only mentioned, their best feature match (share of three words), they have the top match, pointed
at by who they are with, the rules' probability for them.
Line vector (addressee-tt-0.5, 16): number of people present (one-hot, 1 to 8), any spatial fact known, any history;
group words, pair words ("you two"), the rules call the line unclear, the rules call it a group line; a simple harmless
line and an opener by the word lists (rule 5 in harness/addressee/evidence.py).

addressee-tt-0.6 (rc2) reads the same things under version 0.3 of the rules, and adds, per person, whether they are
the one the speaker was answering (rule 6), and for the line, whether a character is speaking and whether the words
open it to the room (rule 2b). "The speaker" is the player in every tt-0.5 request, so a tt-0.5 model reads exactly what
it was trained on: its inputs use version 0.2 of the rules, byte for byte as before.
"""
from __future__ import annotations

from contracts.schemas.addressee import AddresseeRequest
from contracts.schemas.person_card import PersonCard
from harness.addressee.render import card_text

TT_05 = "addressee-tt-0.5"
TT_06 = "addressee-tt-0.6"
TT_VERSION = TT_06
TT_VERSIONS: tuple[str, ...] = (TT_05, TT_06)
DIMS = {TT_05: (25, 16), TT_06: (26, 18)}   # (per person, per line)
GUIDE_OF = {TT_05: "0.2", TT_06: "0.3"}     # the rules each version's inputs are built with
PERSON_DIM, LINE_DIM = DIMS[TT_VERSION]


def card_only(c: PersonCard) -> str:
    """The cached part of a card: what the speaker can see, without where the person is."""
    return card_text(c.without_spatial())


def line_input(req: AddresseeRequest) -> tuple[str, int]:
    """The text the line encoder reads and the character length of the current line within it. Names of earlier
    speakers are left out: who said what is in the per-person vector, so a name in the history is never mistaken for
    a name in the line."""
    cur = f"\"{req.text}\""
    if req.history:
        return cur + f" Before: \"{req.history[-1].text}\"", len(cur)
    return cur, len(cur)


def _three(v: bool | None) -> list[float]:
    return [1.0 if v is True else 0.0, 1.0 if v is False else 0.0, 1.0 if v is None else 0.0]


def person_features(req: AddresseeRequest, version: str = TT_VERSION) -> list[list[float]]:
    from harness.addressee.evidence import answered
    from harness.addressee.rules import match_signals, rules_answer

    guide = GUIDE_OF[version]
    me = req.speaker
    per, _ = match_signals(req, guide)
    rules = rules_answer(req, guide).addressed
    last = req.history[-1] if req.history else None
    my_last = next((h for h in reversed(req.history) if h.speaker == me), None)
    n = len(req.present)
    was_answering = answered(req) if version != TT_05 else None
    out = []
    for c in req.present:
        s = c.spatial
        d = s.distance if s else None
        v = [1.0 if d == "near" else 0.0, 1.0 if d == "mid" else 0.0, 1.0 if d == "far" else 0.0, 1.0 if d is None else 0.0]
        v += _three(s.in_view if s else None) + _three(s.in_group if s else None)
        v += [float(bool(s and s.following)), float(bool(s and s.asked_you)), float(bool(s and s.last_spoke_with_you))]
        theirs = last is not None and last.speaker == c.id and (me in last.to or not last.to)
        v += [float(theirs), float(theirs and last.text.rstrip().rstrip('"\'').endswith("?")),
              float(my_last is not None and my_last.to == [c.id]),
              float(any(h.speaker == c.id for h in req.history)),
              float(any(h.speaker == me and c.id in h.to for h in req.history)),
              1.0 / n]
        v += [*per[len(out)], rules[c.id]]
        if version != TT_05:
            v.append(float(was_answering == c.id))
        out.append(v)
    return out


def line_features(req: AddresseeRequest, version: str = TT_VERSION) -> list[float]:
    from harness.addressee.rules import match_signals, room_words, rules_answer

    guide = GUIDE_OF[version]
    n = min(len(req.present), 8)
    _, (group_words, pair_words, simple, opener) = match_signals(req, guide)
    ra = rules_answer(req, guide)
    out = [1.0 if i == n else 0.0 for i in range(1, 9)] + [float(req.has_spatial), float(bool(req.history)),
                                                          group_words, pair_words, ra.unclear, ra.to_group, simple, opener]
    if version != TT_05:
        out += [float(req.npc_speaker), float(room_words(req.text))]
    return out

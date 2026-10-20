"""How the addressee model reads a request (render addressee-input-0.1). Shared by training and the runtime.

Everyone present comes first, one bracketed marker each holding what the player can see of them and, when the game
knows, where they are. Then the player's line. Then the history, newest first, so truncation cuts the oldest line
and never a person or the line itself:

    People: [Tomas (the barkeep). role: barkeep; headwear: red hat; holding: a tankard. near you, in view, spoke with
    you last] [Wren. role: mercenary; hair: hidden. mid-range, out of view]. The player: "You in the red hat, a word."
    Before: Tomas to the player: "Another round?" | The player to Tomas: "Go on then."

A person's head reads the tokens of their marker, brackets included. Features keep the caller's order; a card over
`MAX_CARD_CHARS` loses features from the end, so put the most telling features first.
Spatial facts are never cut. Unknown facts are left out; known negatives that matter are said ("out of view").

When a character speaks (addressee 0.2), the line is theirs ("Tomas: ...") and the player is a person with a card,
called by that card's label in the history. A request with the player speaking renders exactly as before.
"""
from __future__ import annotations

from contracts.schemas.addressee import PLAYER, AddresseeRequest, HistoryLine
from contracts.schemas.person_card import PersonCard, SpatialFacts


def span_mask(offsets: list[tuple[int, int]], spans: list[tuple[int, int]]) -> list[list[float]]:
    """Per target, which tokens belong to its marker (special tokens have empty offsets and never do). The same mask as
    the line classifier's (harness/expression/render.py), kept here so this runtime stands alone."""
    rows = []
    for a, b in spans:
        row = [1.0 if (t > s and s >= a and t <= b) else 0.0 for s, t in offsets]
        if not any(row):
            row[0] = 1.0
        rows.append(row)
    return rows


RENDER_VERSION = "addressee-input-0.1"
MAX_CARD_CHARS = 240

DISTANCE_WORDS = {"near": "near you", "mid": "mid-range", "far": "far away"}


def spatial_words(s: SpatialFacts | None) -> list[str]:
    if s is None:
        return []
    out = []
    if s.distance is not None:
        out.append(DISTANCE_WORDS[s.distance])
    if s.in_view is not None:
        out.append("in view" if s.in_view else "out of view")
    if s.in_group is not None:
        out.append("in your group" if s.in_group else "not in your group")
    if s.following:
        out.append("following you")
    if s.asked_you:
        out.append("asked you something")
    if s.last_spoke_with_you:
        out.append("spoke with you last")
    return out


def card_text(c: PersonCard, max_chars: int = MAX_CARD_CHARS) -> str:
    """The inside of one person's marker."""
    head = c.label + (f" ({', '.join(c.aliases)})" if c.aliases else "")
    tail = ", ".join(spatial_words(c.spatial))
    budget = max_chars - len(head) - (len(tail) + 2 if tail else 0)
    feats: list[str] = []
    used = 0
    for f in c.features:
        piece = f"{f.key}: {f.value}"
        if used + len(piece) + 2 > budget:
            break
        feats.append(piece)
        used += len(piece) + 2
    text = head + (". " + "; ".join(feats) if feats else "")
    return text + (". " + tail if tail else "")


def who(req: AddresseeRequest, pid: str) -> str:
    if pid == PLAYER:
        return req.card(PLAYER).label if PLAYER in req.ids else "the player"
    if pid == req.speaker:
        return req.speaker_label or pid
    return req.card(pid).label


def speaker_name(req: AddresseeRequest) -> str:
    """Who said the line, as the input names them: "The player", or the character's label."""
    return "The player" if req.speaker == PLAYER else (req.speaker_label or req.speaker)


def history_text(req: AddresseeRequest, h: HistoryLine) -> str:
    to = " and ".join(who(req, t) for t in h.to)
    speaker = who(req, h.speaker)
    speaker = speaker[0].upper() + speaker[1:]
    return f"{speaker}{' to ' + to if to else ''}: \"{h.text}\""


def render(req: AddresseeRequest, order: list[str] | None = None) -> tuple[str, list[tuple[int, int]]]:
    """The input text and, per person in `req.present` order, the character span of their marker (brackets
    included). `order` is the order the people are written in (training shuffles it); default: as given."""
    order = order or req.ids
    if sorted(order) != sorted(req.ids):
        raise ValueError("order must be a permutation of the people present")
    text, at = "People:", {}
    for pid in order:
        start = len(text) + 1
        text += f" [{card_text(req.card(pid))}]"
        at[pid] = (start, len(text))
    text += f". {speaker_name(req)}: \"{req.text}\""
    if req.history:
        text += " Before: " + " | ".join(history_text(req, h) for h in reversed(req.history))
    return text, [at[pid] for pid in req.ids]

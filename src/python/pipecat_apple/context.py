"""Bound native history without guessing the Foundation Models token budget."""

from collections.abc import Mapping, Sequence
from typing import Any

# The longest user turn the native host accepts, in characters.
MAX_TURN_CHARACTERS = 2000
MAX_HISTORY_TURNS = 32
MAX_HISTORY_CHARACTERS = 32_000


def bounded_history(messages: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    """Keep a bounded suffix of whole user turns for native token selection.

    Args:
        messages: Committed conversation messages, excluding instructions.

    Returns:
        Recent user turns with their associated assistant messages. A user turn
        can lack a response after interruption; an orphan assistant is omitted.
        These limits bound bridge memory, not the language model's context size.
    """
    turns: list[list[dict[str, Any]]] = []
    for message in messages:
        if message.get("role") == "user":
            turns.append([])
        if turns and message.get("role") in {"user", "assistant"}:
            turns[-1].append(dict(message))
    kept: list[list[dict[str, Any]]] = []
    characters = 0
    for turn in reversed(turns[-MAX_HISTORY_TURNS:]):
        size = sum(len(str(message.get("content", ""))) for message in turn)
        if characters + size > MAX_HISTORY_CHARACTERS:
            break
        kept.append(turn)
        characters += size
    return [message for turn in reversed(kept) for message in turn]

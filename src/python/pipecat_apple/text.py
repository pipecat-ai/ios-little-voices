"""Plain speech cleanup after Pipecat's Markdown text filter."""

import re
import unicodedata

from pipecat.utils.text.base_text_filter import BaseTextFilter

# Characters with no spoken form: emoji and other pictographs, dingbats, modifier symbols and
# private-use glyphs, by Unicode category. The degree sign stays, since it reads as a word.
_UNSPOKEN_CATEGORIES = frozenset({"So", "Sk", "Co", "Cs"})
_SPOKEN_SYMBOLS = frozenset("°")
# What builds emoji sequences: the zero-width joiner, variation selectors, the keycap mark
# and tag characters.
_EMOJI_PARTS = re.compile("[\u200d\ufe0e\ufe0f\u20e3\U000e0020-\U000e007f]")
_ARROWS = re.compile("[\u2190-\u21ff\u27f0-\u27ff\u2900-\u297f\u2b00-\u2bff]")


class PlainSpeechTextFilter(BaseTextFilter):
    """Remove residual presentation markers from complete spoken sentences.

    Use after ``MarkdownTextFilter`` in a TTS service's ``text_filters``. The
    standard filter handles Markdown/HTML; this enforces the voice-only surface
    for malformed emphasis, Unicode bullets, numbered-list prefixes, bracketed
    tags such as speaker labels (``[Angel]:``) and stage directions
    (``[laughs]``), emoji, arrows and other symbols that have no spoken form.
    """

    async def filter(self, text: str) -> str:
        """Clean a sentence while preserving ordinary spoken punctuation.

        Args:
            text: Sentence after standard Markdown filtering.

        Returns:
            Plain speech with layout markers removed.
        """
        text = re.sub(r"\[[^\[\]]*\]\s*:?", " ", text)
        text = re.sub(r"(?m)^\s*(?:[-+•◦▪●]+|\d+[.)])(?:\s+|$)", "", text)
        text = re.sub(r"[•◦▪●]", "; ", text)
        comparisons = {
            "<": " less than ",
            ">": " greater than ",
            "<=": " less than or equal to ",
            ">=": " greater than or equal to ",
        }
        text = re.sub(
            r"(?<=\d)\s*(<=|>=|<|>)\s*(?=[+-]?\d)",
            lambda match: comparisons[match.group(1)],
            text,
        )
        text = re.sub(r"[<>]", " ", text)
        text = re.sub(r"[*`_#]", "", text)
        text = _EMOJI_PARTS.sub("", text)
        text = "".join(
            " "
            if unicodedata.category(character) in _UNSPOKEN_CATEGORIES
            and character not in _SPOKEN_SYMBOLS
            else character
            for character in text
        )
        text = _ARROWS.sub(" ", text)
        text = re.sub(r"[~|^\\{}\[\]]", " ", text)
        text = re.sub(r"\s+", " ", text)
        # A symbol dropped before punctuation leaves no space in front of it.
        return re.sub(r"\s+([,.;:!?…])", r"\1", text).strip()

"""Sentences where the host's tokenizer ends them, through Pipecat's text aggregator."""

import importlib.util
import subprocess
import sys
import sysconfig
from pathlib import Path

import pytest
from pipecat.utils.text.simple_text_aggregator import SimpleTextAggregator


@pytest.fixture(scope="module")
def apple_boundary(tmp_path_factory):
    if sys.platform != "darwin":
        pytest.skip("Apple Foundation sentence tokenization requires macOS")
    root = Path(__file__).resolve().parents[1]
    source = (root / "src/ios/PipecatVoice/PCPythonRuntime.m").read_text()
    function = source.split("static PyObject *native_sentence_boundary", 1)[1].split(
        "static PyMethodDef methods[]", 1
    )[0]
    directory = tmp_path_factory.mktemp("apple-sentences")
    harness = directory / "sentences.m"
    harness.write_text(
        "#import <Foundation/Foundation.h>\n#import <NaturalLanguage/NaturalLanguage.h>\n#include <Python.h>\n"
        + "static PyObject *native_sentence_boundary"
        + function
        + """
static PyMethodDef methods[] = {
    {"boundary", native_sentence_boundary, METH_VARARGS, NULL},
    {NULL, NULL, 0, NULL}
};
static struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "_apple_sentence_test", NULL, -1, methods};
PyMODINIT_FUNC PyInit__apple_sentence_test(void) { return PyModule_Create(&module); }
"""
    )
    extension = directory / ("_apple_sentence_test" + sysconfig.get_config_var("EXT_SUFFIX"))
    subprocess.run(
        [
            "xcrun",
            "clang",
            "-bundle",
            "-fobjc-arc",
            "-fblocks",
            "-framework",
            "Foundation",
            "-framework",
            "NaturalLanguage",
            "-undefined",
            "dynamic_lookup",
            "-I",
            sysconfig.get_path("include"),
            str(harness),
            "-o",
            str(extension),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    spec = importlib.util.spec_from_file_location("_apple_sentence_test", extension)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.boundary


async def aggregate(aggregator: SimpleTextAggregator, *chunks: str) -> list[str]:
    sentences = [a.text for chunk in chunks async for a in aggregator.aggregate(chunk)]
    if remaining := await aggregator.flush():
        sentences.append(remaining.text)
    return sentences


def first_full_stop(text: str) -> int:
    """A host tokenizer that ends sentences at full stops only."""
    return text.find(".") + 1


async def test_the_host_decides_where_sentences_end():
    aggregator = SimpleTextAggregator(sentence_boundary_matcher=first_full_stop)
    sentences = await aggregate(aggregator, "Is it? Yes. It is", " done.")
    assert sentences == ["Is it? Yes.", "It is done."]


async def test_a_boundary_outside_the_text_is_rejected():
    aggregator = SimpleTextAggregator(sentence_boundary_matcher=lambda text: len(text) + 1)
    with pytest.raises(ValueError, match="outside the buffered text"):
        await aggregate(aggregator, "One. Two.")


async def test_long_text_is_released_at_a_space_or_at_the_limit():
    aggregator = SimpleTextAggregator(
        sentence_boundary_matcher=first_full_stop, max_buffer_chars=12
    )
    # Released as soon as the buffer reaches the limit, at its last space.
    assert await aggregate(aggregator, "No full stop here at all") == [
        "No full",
        "stop here",
        "at all",
    ]
    aggregator = SimpleTextAggregator(sentence_boundary_matcher=first_full_stop, max_buffer_chars=4)
    assert await aggregate(aggregator, "Unbroken") == ["Unbr", "oken"]


async def test_streaming_decimals_abbreviations_and_unicode(apple_boundary):
    aggregator = SimpleTextAggregator(sentence_boundary_matcher=apple_boundary)
    assert [part async for part in aggregator.aggregate("😀 Dr. Smith paid 3.")] == []
    parts = [part.text async for part in aggregator.aggregate("14 dollars. Next")]
    assert parts == ["😀 Dr. Smith paid 3.14 dollars."]
    assert [part async for part in aggregator.aggregate(" sentence!")] == []
    assert (await aggregator.flush()).text == "Next sentence!"


async def test_long_text_is_bounded_without_losing_words():
    aggregator = SimpleTextAggregator(sentence_boundary_matcher=lambda _: 0, max_buffer_chars=420)
    text = "long " * 300
    pieces = [part.text async for part in aggregator.aggregate(text)]
    if tail := await aggregator.flush():
        pieces.append(tail.text)
    assert all(len(piece) <= 420 for piece in pieces)
    assert " ".join(pieces) == text.strip()


async def test_unbroken_text_is_bounded_without_loss():
    aggregator = SimpleTextAggregator(sentence_boundary_matcher=lambda _: 0, max_buffer_chars=420)
    text = "x" * 1300
    pieces = [part.text async for part in aggregator.aggregate(text)]
    pieces.append((await aggregator.flush()).text)
    assert max(map(len, pieces)) <= 420
    assert "".join(pieces) == text


async def test_interruption_discards_buffered_sentence_and_lookahead(apple_boundary):
    aggregator = SimpleTextAggregator(sentence_boundary_matcher=apple_boundary)
    assert [part async for part in aggregator.aggregate("Unspoken old answer.")] == []
    await aggregator.handle_interruption()
    assert [part async for part in aggregator.aggregate("New answer!")] == []
    assert (await aggregator.flush()).text == "New answer!"


def test_invalid_limit_rejected():
    with pytest.raises(ValueError, match="positive"):
        SimpleTextAggregator(max_buffer_chars=0)

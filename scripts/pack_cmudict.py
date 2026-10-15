"""Pack the CMU Pronouncing Dictionary into the app's compact pronunciation lexicon.

    uv run --no-sync python scripts/pack_cmudict.py /path/to/cmudict.dict

The source must be `cmudict.dict` at the pinned revision of github.com/cmusphinx/cmudict (its
SHA-256 is checked). The lexicon keeps each ASCII word's or contraction's first pronunciation,
stress included, one byte per phone, sorted for binary search (the app indexes the records as it
loads them), and is compressed with LZMA (an XZ stream with a CRC32 check, which Foundation's
`NSData.decompressed(using: .lzma)` reads):

    "LVCMU1\\0\\0", UInt32 count, then a word \\0 phones \\0 record for each word

Phone codes start at 1: the 15 vowels in `VOWELS` order with stress 0, 1, 2 (1 + 3 * vowel +
stress), then the 24 consonants in `CONSONANTS` order. LipsyncPhones.swift reads it.
"""

import hashlib
import json
import lzma
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REVISION = "74790861f652b15e4ac49015a90074ad62a27690"
SOURCE_SHA256 = "81917843c7f44ce2b094ac63873c2c7a4cf802040792c455ba3ca406891c3d22"
VOWELS = "AA AE AH AO AW AY EH ER EY IH IY OW OY UH UW".split()
CONSONANTS = "B CH D DH F G HH JH K L M N NG P R S SH T TH V W Y Z ZH".split()
MAGIC = b"LVCMU1\0\0"
DATASET = ROOT / "src/ios/PipecatVoice/Assets.xcassets/Pronunciations.dataset"


def code(phone: str) -> int:
    if phone[-1].isdigit():
        return 1 + 3 * VOWELS.index(phone[:-1]) + int(phone[-1])
    return 1 + 3 * len(VOWELS) + CONSONANTS.index(phone)


def pack(source: bytes) -> bytes:
    entries: dict[str, bytes] = {}
    for line in source.decode().splitlines():
        fields = line.split("#", 1)[0].split()
        if not fields or not re.fullmatch(r"[a-z]+(?:'[a-z]+)*", fields[0]):
            continue
        entries.setdefault(fields[0], bytes(code(phone) for phone in fields[1:]))
    records = bytearray()
    for word, phones in sorted(entries.items()):
        records.extend(word.encode() + b"\0" + phones + b"\0")
    return MAGIC + struct.pack("<I", len(entries)) + bytes(records)


def main() -> None:
    source = Path(sys.argv[1]).read_bytes()
    digest = hashlib.sha256(source).hexdigest()
    if digest != SOURCE_SHA256:
        raise SystemExit(f"cmudict.dict is not revision {REVISION} (SHA-256 {digest})")
    packed = pack(source)
    compressed = lzma.compress(
        packed, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC32, preset=9 | lzma.PRESET_EXTREME
    )
    DATASET.mkdir(parents=True, exist_ok=True)
    (DATASET / "cmudict.lzma").write_bytes(compressed)
    contents = {
        "data": [{"filename": "cmudict.lzma", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }
    (DATASET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    count = struct.unpack_from("<I", packed, len(MAGIC))[0]
    print(f"{count} words, {len(packed)} bytes packed, {len(compressed)} bytes compressed")


if __name__ == "__main__":
    main()

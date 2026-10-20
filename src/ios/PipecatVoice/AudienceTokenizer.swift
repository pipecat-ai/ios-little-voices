import Foundation

/// Pipecat Audience's tokenizer (`tokenizer.json`: byte-level BPE on the Ettin vocabulary), encoding as the
/// `tokenizers` library does, offsets included. Offsets count Unicode scalars, as Python counts characters, so the
/// request's character spans from the Python runtime line up with the tokens. Inputs are expected in NFC, as the
/// runtime renders them; the tokenizer's own normalizer is NFC too.
struct AudienceTokenizer: Sendable {
    struct Encoding: Equatable, Sendable {
        var ids: [Int32]
        /// Start and end of each token in Unicode scalars; the template's [CLS] and [SEP] are (0, 0).
        var offsets: [Offsets]
    }

    struct Offsets: Equatable, Sendable {
        var start: Int
        var end: Int
    }

    private struct AddedToken: Sendable {
        let scalars: [Unicode.Scalar]
        let id: Int32
    }

    private let vocab: [String: Int32]
    private let ranks: [String: Int]
    /// Special tokens match the raw text; the others match after normalization (runs of spaces, placeholders).
    private let special: [AddedToken]
    private let normalized: [AddedToken]
    private let cls: Int32
    private let sep: Int32
    /// GPT-2's byte-to-character table: every byte as a printable character.
    private static let byteCharacters: [Unicode.Scalar] = {
        let printable = Set(Array(33...126) + Array(161...172) + Array(174...255))
        var table = [UInt32](repeating: 0, count: 256)
        var next: UInt32 = 256
        for byte in 0..<256 {
            if printable.contains(byte) {
                table[byte] = UInt32(byte)
            } else {
                table[byte] = next
                next += 1
            }
        }
        return table.map { Unicode.Scalar($0)! }
    }()
    // GPT-2's pre-tokenizer pattern, as the ByteLevel pre-tokenizer uses it. ICU's \s leaves out some of the
    // Unicode White_Space the tokenizers library's regex counts, so the property is spelled out.
    private static let pattern =
        #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\p{White_Space}\p{L}\p{N}]+|\p{White_Space}+(?!\P{White_Space})|\p{White_Space}+"#
    private let splitter: NSRegularExpression

    init(contentsOf url: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let model = json?["model"] as? [String: Any], model["type"] as? String == "BPE",
              let vocab = model["vocab"] as? [String: Int], let merges = model["merges"] as? [Any],
              let added = json?["added_tokens"] as? [[String: Any]] else {
            throw VoiceError(message: "Audience's tokenizer.json is not a byte-level BPE tokenizer.")
        }
        var table = [String: Int32](minimumCapacity: vocab.count + added.count)
        for (token, id) in vocab { table[token] = Int32(id) }
        var ranks = [String: Int](minimumCapacity: merges.count)
        for (rank, merge) in merges.enumerated() {
            if let pair = merge as? [String], pair.count == 2 {
                ranks[pair[0] + " " + pair[1]] = rank
            } else if let pair = merge as? String {
                ranks[pair] = rank
            }
        }
        var special: [AddedToken] = []
        var normalized: [AddedToken] = []
        for token in added {
            guard let content = token["content"] as? String, let id = token["id"] as? Int else { continue }
            table[content] = Int32(id)
            let entry = AddedToken(scalars: Array(content.unicodeScalars), id: Int32(id))
            if token["special"] as? Bool == true { special.append(entry) } else { normalized.append(entry) }
        }
        guard let cls = table["[CLS]"], let sep = table["[SEP]"] else {
            throw VoiceError(message: "Audience's tokenizer.json lacks [CLS] or [SEP].")
        }
        self.vocab = table
        self.ranks = ranks
        self.special = special
        self.normalized = normalized
        self.cls = cls
        self.sep = sep
        splitter = try NSRegularExpression(pattern: Self.pattern)
    }

    /// Encode `text` as [CLS] text [SEP], keeping at most `maxLength` tokens in all (right truncation).
    func encode(_ text: String, maxLength: Int) -> Encoding {
        // NFC, remembering where each normalized scalar came from: a composed character takes the position of
        // its first original scalar, as the tokenizers library aligns it. Composition stays within a character.
        var scalars: [Unicode.Scalar] = []
        var origin: [Int] = []
        var position = 0
        for character in text {
            let original = character.unicodeScalars.count
            let normalized = String(character).precomposedStringWithCanonicalMapping.unicodeScalars
            for (k, scalar) in normalized.enumerated() {
                scalars.append(scalar)
                origin.append(position + min(k, original - 1))
            }
            position += original
        }
        var encoding = encodeNormalized(scalars, maxLength: maxLength)
        for i in encoding.offsets.indices where encoding.offsets[i].end > encoding.offsets[i].start {
            let span = encoding.offsets[i]
            encoding.offsets[i] = Offsets(start: origin[span.start], end: origin[span.end - 1] + 1)
        }
        return encoding
    }

    private func encodeNormalized(_ scalars: [Unicode.Scalar], maxLength: Int) -> Encoding {
        var ids: [Int32] = []
        var offsets: [Offsets] = []
        for (start, end, token) in Self.split(scalars, 0..<scalars.count, on: special) {
            if let token {
                ids.append(token)
                offsets.append(Offsets(start: start, end: end))
                continue
            }
            for (start, end, token) in Self.split(scalars, start..<end, on: normalized) {
                if let token {
                    ids.append(token)
                    offsets.append(Offsets(start: start, end: end))
                } else {
                    encodeWords(scalars, start..<end, ids: &ids, offsets: &offsets)
                }
            }
        }
        let keep = max(0, maxLength - 2)
        if ids.count > keep {
            ids.removeLast(ids.count - keep)
            offsets.removeLast(offsets.count - keep)
        }
        return Encoding(ids: [cls] + ids + [sep],
                        offsets: [Offsets(start: 0, end: 0)] + offsets + [Offsets(start: 0, end: 0)])
    }

    /// Pieces of `range` split on `tokens`, leftmost-longest; matched pieces carry their token's id.
    private static func split(_ scalars: [Unicode.Scalar], _ range: Range<Int>,
                              on tokens: [AddedToken]) -> [(Int, Int, Int32?)] {
        var pieces: [(Int, Int, Int32?)] = []
        var plain = range.lowerBound
        var i = range.lowerBound
        while i < range.upperBound {
            var best: AddedToken?
            for token in tokens where token.scalars.first == scalars[i]
                && token.scalars.count > (best?.scalars.count ?? 0)
                && i + token.scalars.count <= range.upperBound
                && scalars[i..<(i + token.scalars.count)].elementsEqual(token.scalars) {
                best = token
            }
            if let best {
                if plain < i { pieces.append((plain, i, nil)) }
                pieces.append((i, i + best.scalars.count, best.id))
                i += best.scalars.count
                plain = i
            } else {
                i += 1
            }
        }
        if plain < range.upperBound { pieces.append((plain, range.upperBound, nil)) }
        return pieces
    }

    /// Pre-tokenize with GPT-2's pattern, then BPE each word over its UTF-8 bytes.
    private func encodeWords(_ scalars: [Unicode.Scalar], _ range: Range<Int>, ids: inout [Int32],
                             offsets: inout [Offsets]) {
        var piece = String.UnicodeScalarView()
        piece.append(contentsOf: scalars[range])
        let text = String(piece)
        // NSRegularExpression works in UTF-16; map its offsets back to scalar indices.
        var utf16ToScalar: [Int] = []
        for (index, scalar) in scalars[range].enumerated() {
            utf16ToScalar.append(contentsOf: repeatElement(index, count: scalar.utf16.count))
        }
        utf16ToScalar.append(range.count)
        let utf16 = text.utf16.count
        for match in splitter.matches(in: text, range: NSRange(location: 0, length: utf16)) {
            let start = utf16ToScalar[match.range.location]
            let end = utf16ToScalar[match.range.location + match.range.length]
            encodeWord(scalars, (range.lowerBound + start)..<(range.lowerBound + end), ids: &ids, offsets: &offsets)
        }
    }

    private func encodeWord(_ scalars: [Unicode.Scalar], _ range: Range<Int>, ids: inout [Int32],
                            offsets: inout [Offsets]) {
        // One symbol per UTF-8 byte, each remembering the scalar it came from.
        var symbols: [String] = []
        var spans: [(first: Int, last: Int)] = []
        for index in range {
            for byte in String(scalars[index]).utf8 {
                symbols.append(String(Self.byteCharacters[Int(byte)]))
                spans.append((index, index))
            }
        }
        while symbols.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(symbols.count - 1) {
                if let rank = ranks[symbols[i] + " " + symbols[i + 1]], rank < (best?.rank ?? .max) {
                    best = (rank, i)
                }
            }
            guard let best else { break }
            symbols[best.index] += symbols[best.index + 1]
            spans[best.index].last = spans[best.index + 1].last
            symbols.remove(at: best.index + 1)
            spans.remove(at: best.index + 1)
        }
        for (symbol, span) in zip(symbols, spans) {
            // Every single byte is in the vocabulary, so a symbol is always known.
            ids.append(vocab[symbol] ?? 0)
            offsets.append(Offsets(start: span.first, end: span.last + 1))
        }
    }
}

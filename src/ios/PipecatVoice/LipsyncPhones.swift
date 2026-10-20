import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An ARPAbet phone as CMUdict spells it; vowels carry their stress.
struct LipsyncPhone: Hashable, Sendable, CustomStringConvertible {
    enum Symbol: String, CaseIterable, Sendable {
        case aa = "AA", ae = "AE", ah = "AH", ao = "AO", aw = "AW", ay = "AY", eh = "EH", er = "ER", ey = "EY"
        case ih = "IH", iy = "IY", ow = "OW", oy = "OY", uh = "UH", uw = "UW"
        case b = "B", ch = "CH", d = "D", dh = "DH", f = "F", g = "G", hh = "HH", jh = "JH", k = "K", l = "L"
        case m = "M", n = "N", ng = "NG", p = "P", r = "R", s = "S", sh = "SH", t = "T", th = "TH", v = "V"
        case w = "W", y = "Y", z = "Z", zh = "ZH"

        /// The 15 vowels come first, as in the packed lexicon.
        static let vowels = Array(allCases.prefix(15))
        var isVowel: Bool { Self.vowelSet.contains(self) }
        private static let vowelSet = Set(vowels)
    }

    var symbol: Symbol
    /// For vowels 0 unstressed, 1 primary, 2 secondary; 0 for consonants.
    var stress: Int

    init(_ symbol: Symbol, stress: Int = 0) {
        self.symbol = symbol
        self.stress = symbol.isVowel ? stress : 0
    }

    var isVowel: Bool { symbol.isVowel }

    var description: String { isVowel ? "\(symbol.rawValue)\(stress)" : symbol.rawValue }

    /// The packed lexicon's byte: 1 + 3 × vowel + stress, then the consonants after the vowels.
    init?(code: UInt8) {
        let index = Int(code) - 1
        if index >= 0 && index < 45 {
            self.init(Symbol.vowels[index / 3], stress: index % 3)
        } else if index >= 45 && index < 45 + Symbol.allCases.count - 15 {
            self.init(Symbol.allCases[15 + index - 45])
        } else {
            return nil
        }
    }
}

/// A word as the voice will say it.
struct LipsyncWord: Equatable, Sendable {
    enum Pause: Sendable {
        case none
        /// A comma, colon, semicolon or dash: the voice may pause.
        case comma
        /// A full stop, question or exclamation mark: the voice pauses.
        case stop
    }

    var spelling: String
    var phones: [LipsyncPhone]
    var pause: Pause = .none
}

/// English text to phones: words from CMUdict (`Assets.xcassets/Pronunciations`, packed by
/// scripts/pack_cmudict.py), numbers, amounts and symbols spelled out as Phonon reads them, and
/// letter-to-sound rules for anything else.
final class LipsyncLexicon: Sendable {
    /// The app's lexicon, decompressed on first use; nil outside the app.
    static let bundled: LipsyncLexicon? = NSDataAsset(name: "Pronunciations").flatMap { LipsyncLexicon(compressed: $0.data) }

    private static let magic = Array("LVCMU1\0\0".utf8)
    /// The decompressed lexicon: magic, UInt32 count, then word \0 phone codes \0 records.
    private let packed: [UInt8]
    /// Where each record starts, in word order.
    private let offsets: [UInt32]

    /// The lexicon from the packed, LZMA-compressed resource.
    init?(compressed: Data) {
        guard let data = try? (compressed as NSData).decompressed(using: .lzma) as Data else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count > 12, Array(bytes[0..<8]) == Self.magic else { return nil }
        let count = Int(UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24)
        var offsets: [UInt32] = []
        offsets.reserveCapacity(count)
        var index = 12
        while index < bytes.count && offsets.count < count {
            offsets.append(UInt32(index))
            // Skip the word and its phones, each ended by a zero byte.
            while index < bytes.count && bytes[index] != 0 { index += 1 }
            index += 1
            while index < bytes.count && bytes[index] != 0 { index += 1 }
            index += 1
        }
        guard offsets.count == count else { return nil }
        packed = bytes
        self.offsets = offsets
    }

    var count: Int { offsets.count }

    /// Words CMUdict lacks that the app's characters say about themselves, as Phonon says them.
    private static let additions: [String: [LipsyncPhone]] = [
        "pipecat": "P AY1 P K AE2 T",
        "gradium": "G R EY1 D IY0 AH0 M",
        "phonon": "F OW1 N AA0 N",
    ].mapValues(arpabet)

    /// Phones spelled as CMUdict spells them, such as "F OW1 N AA0 N".
    private static func arpabet(_ text: String) -> [LipsyncPhone] {
        text.split(separator: " ").compactMap { part in
            let stress = part.last?.wholeNumberValue
            return LipsyncPhone.Symbol(rawValue: String(stress == nil ? part : part.dropLast()))
                .map { LipsyncPhone($0, stress: stress ?? 0) }
        }
    }

    /// A lowercase word's dictionary phones (its first pronunciation), or nil.
    func lookup(_ word: String) -> [LipsyncPhone]? {
        if let phones = Self.additions[word] { return phones }
        let key = Array(word.utf8)
        var low = 0, high = offsets.count
        while low < high {
            let middle = (low + high) / 2
            switch compare(key, record: Int(offsets[middle])) {
            case .orderedAscending: high = middle
            case .orderedDescending: low = middle + 1
            case .orderedSame:
                var index = Int(offsets[middle]) + key.count + 1
                var phones: [LipsyncPhone] = []
                while index < packed.count && packed[index] != 0 {
                    if let phone = LipsyncPhone(code: packed[index]) { phones.append(phone) }
                    index += 1
                }
                return phones
            }
        }
        return nil
    }

    /// How `key` sorts against the word of the record at `offset`, byte by byte.
    private func compare(_ key: [UInt8], record offset: Int) -> ComparisonResult {
        var index = 0
        while true {
            let byte = packed[offset + index]
            if index == key.count { return byte == 0 ? .orderedSame : .orderedAscending }
            if byte == 0 { return .orderedDescending }
            if key[index] != byte { return key[index] < byte ? .orderedAscending : .orderedDescending }
            index += 1
        }
    }

    /// The words of a sentence as the voice says them, with their phones.
    func words(_ text: String) -> [LipsyncWord] {
        LipsyncText.tokens(text).flatMap { token in
            var words = pronounce(token.text)
            if !words.isEmpty { words[words.count - 1].pause = token.pause }
            return words
        }
    }

    /// One token's words: a dictionary word, a contraction or possessive, letters to spell,
    /// or a guess from the letter-to-sound rules.
    private func pronounce(_ token: String) -> [LipsyncWord] {
        // Short initialisms, such as "AI" or "TV", are spelled out.
        if (2...3).contains(token.count), token.allSatisfy({ $0.isUppercase }), let spelled = spelled(token) {
            return spelled
        }
        let word = token.lowercased()
        if let phones = lookup(word) { return [LipsyncWord(spelling: token, phones: phones)] }
        // A drawn-out word ("Sooo", "Wheee", "Reeeally", "Mmm") is the word, held: a run of three or
        // more letters is one letter, or else two; a lone letter would be read as its name.
        for limit in [1, 2] {
            var shortened = "", run = 0
            var previous: Character?
            for letter in word + " " {
                if letter == previous {
                    run += 1
                    continue
                }
                if let previous { shortened += String(repeating: previous, count: run >= 3 ? limit : run) }
                previous = letter
                run = 1
            }
            if shortened != word, shortened.count > 1, let phones = lookup(shortened) {
                return [LipsyncWord(spelling: token, phones: phones)]
            }
        }
        // Possessives and plurals the dictionary lacks: the base word with an S or Z.
        for suffix in ["'s", "s"] where word.hasSuffix(suffix) && word.count > suffix.count + 1 {
            if let base = lookup(String(word.dropLast(suffix.count))), let last = base.last {
                let sibilant: Set<LipsyncPhone.Symbol> = [.s, .z, .sh, .zh, .ch, .jh]
                let voiceless: Set<LipsyncPhone.Symbol> = [.p, .t, .k, .f, .th]
                let ending: [LipsyncPhone] = sibilant.contains(last.symbol) ? [LipsyncPhone(.ih), LipsyncPhone(.z)]
                    : [LipsyncPhone(voiceless.contains(last.symbol) ? .s : .z)]
                return [LipsyncWord(spelling: token, phones: base + ending)]
            }
        }
        // Four capitals the dictionary lacks are spelled out too.
        if token.count == 4, token.allSatisfy({ $0.isUppercase }), let spelled = spelled(token) {
            return spelled
        }
        return [LipsyncWord(spelling: token, phones: LipsyncLetterToSound.phones(word))]
    }

    /// Letters as their names; the dictionary's first "a" is the article, so A is spelled EY.
    private func spelled(_ token: String) -> [LipsyncWord]? {
        var words: [LipsyncWord] = []
        for letter in token.lowercased().map(String.init) {
            guard let phones = letter == "a" ? [LipsyncPhone(.ey, stress: 1)] : lookup(letter) else { return nil }
            words.append(LipsyncWord(spelling: letter, phones: phones))
        }
        return words
    }
}

/// Sentence text to the words a voice speaks: punctuation becomes pauses, numbers, amounts,
/// ordinals and symbols become words, hyphenated words split. Numbers follow Phonon's `ptts`
/// normalization, which leaves values under a thousand, and years, for the model to read.
enum LipsyncText {
    struct Token: Equatable, Sendable {
        var text: String
        var pause: LipsyncWord.Pause
    }

    static func tokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        for raw in normalized(text).split(separator: " ") {
            var word = String(raw)
            var pause = LipsyncWord.Pause.none
            while let last = word.last, ",.;:!?\"'".contains(last) {
                if ".!?".contains(last) { pause = .stop } else if ",;:".contains(last), pause == .none { pause = .comma }
                word.removeLast()
            }
            while let first = word.first, "\"'".contains(first) { word.removeFirst() }
            guard !word.isEmpty else {
                if pause != .none, !tokens.isEmpty, tokens[tokens.count - 1].pause == .none {
                    tokens[tokens.count - 1].pause = pause
                }
                continue
            }
            let words = expand(word)
            for (index, spoken) in words.enumerated() where !spoken.isEmpty {
                tokens.append(Token(text: spoken, pause: index == words.count - 1 ? pause : .none))
            }
        }
        return tokens
    }

    /// Typographic quotes and dashes folded as `ptts` folds them; brackets, colons and
    /// semicolons read as commas.
    static func normalized(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\u{2018}", "\u{2019}", "\u{201B}", "\u{2032}", "`", "\u{00B4}": out.append("'")
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{00AB}", "\u{00BB}": out.append("\"")
            case "\u{2013}", "\u{2014}", "\u{2015}": out.append(", ")
            case "\u{2010}", "\u{2011}": out.append("-")
            case "\u{2026}": out.append(".")
            case "(", ")", "[", "]", "{", "}", ";": out.append(", ")
            case "&": out.append(" and ")
            case "=": out.append(" equals ")
            case "%": out.append(" percent")
            case "@": out.append(" at ")
            case "\n", "\t", "\r": out.append(" ")
            default: out.append(character)
            }
        }
        return out
    }

    /// One whitespace-separated word as spoken words.
    static func expand(_ word: String) -> [String] {
        // Amounts: "$5", "5$", "£50", "$4.59".
        for (symbol, name) in [("$", "dollars"), ("£", "pounds"), ("€", "euros")] where word.contains(symbol) {
            let amount = word.replacingOccurrences(of: symbol, with: "")
            if let spoken = amountWords(amount, currency: name) { return spoken }
        }
        if let spoken = timeWords(word) { return spoken }
        if word.first?.isNumber == true || (word.first == "-" && word.dropFirst().first?.isNumber == true) {
            if let spoken = numberWords(word) { return spoken }
        }
        if word.contains("+") { return Array(word.split(separator: "+").flatMap { expand(String($0)) + ["plus"] }.dropLast()) }
        if word.contains("-") || word.contains("/") {
            return word.split(whereSeparator: { $0 == "-" || $0 == "/" }).flatMap { expand(String($0)) }
        }
        let letters = word.filter { $0.isLetter || $0 == "'" }
        return letters.isEmpty ? [] : [letters]
    }

    /// A time of day as `ptts` has it read: "3:45pm" is "three forty-five P M", "7:00" is "seven",
    /// "9:05" is "nine oh five", "6pm" is "six P M".
    static func timeWords(_ word: String) -> [String]? {
        var body = Substring(word)
        var meridiem: [String] = []
        for suffix in ["am", "pm"] where body.lowercased().hasSuffix(suffix) {
            meridiem = [suffix.uppercased()]
            body = body.dropLast(2)
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard let hourText = parts.first, (1...2).contains(hourText.count), hourText.allSatisfy(\.isNumber),
              let hour = Int(hourText), hour < 24 else { return nil }
        if parts.count == 1 { return meridiem.isEmpty ? nil : cardinal(hour) + meridiem }
        guard parts.count == 2, parts[1].count == 2, parts[1].allSatisfy(\.isNumber), let minutes = Int(parts[1]),
              minutes < 60 else { return nil }
        let spokenMinutes = minutes == 0 ? [] : (minutes < 10 ? ["oh", ones[minutes]] : cardinal(minutes))
        return cardinal(hour) + spokenMinutes + meridiem
    }

    /// "4.59" with a currency: "4 dollars and 59 cents"; whole amounts as `ptts` reads them.
    static func amountWords(_ amount: String, currency: String) -> [String]? {
        let parts = amount.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 2, parts[1].count == 2, let units = numberWords(String(parts[0])),
           let cents = Int(parts[1]) {
            return units + [currency, "and"] + cardinal(cents) + ["cents"]
        }
        guard let units = numberWords(amount) else { return nil }
        return units + [currency]
    }

    /// Integers, decimals, negatives and ordinals ("1st", "22nd") as words.
    static func numberWords(_ text: String) -> [String]? {
        var body = text.replacingOccurrences(of: ",", with: "")
        var words: [String] = []
        if body.hasPrefix("-") {
            words.append("minus")
            body.removeFirst()
        }
        for suffix in ["st", "nd", "rd", "th"] where body.lowercased().hasSuffix(suffix) {
            if let value = Int(body.dropLast(2)) { return words + ordinal(value) }
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty, first.allSatisfy(\.isNumber), let value = Int(first),
              parts.count <= 2 else { return nil }
        words += (1900..<2100).contains(value) && parts.count == 1 && first.count == 4 ? year(value) : cardinal(value)
        if parts.count == 2 {
            guard parts[1].allSatisfy(\.isNumber) else { return nil }
            words.append("point")
            words += parts[1].compactMap { Int(String($0)) }.flatMap { cardinal($0) }
        }
        return words
    }

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                               "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// A cardinal number's words, with the scale words `ptts` puts in ("1 thousand 234").
    static func cardinal(_ value: Int) -> [String] {
        if value < 0 { return ["minus"] + cardinal(-value) }
        if value < 20 { return [ones[value]] }
        if value < 100 { return [tens[value / 10]] + (value % 10 == 0 ? [] : [ones[value % 10]]) }
        if value < 1000 {
            return [ones[value / 100], "hundred"] + (value % 100 == 0 ? [] : ["and"] + cardinal(value % 100))
        }
        var words: [String] = []
        var rest = value
        for (scale, name) in [(1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand")] where rest >= scale {
            words += cardinal(rest / scale) + [name]
            rest %= scale
        }
        return rest == 0 ? words : words + cardinal(rest)
    }

    /// A year as it is read: "nineteen ninety-nine", "two thousand five", "twenty twenty-four".
    static func year(_ value: Int) -> [String] {
        let century = value / 100, rest = value % 100
        if value >= 2000 && value < 2010 { return cardinal(value) }
        if rest == 0 { return cardinal(century) + ["hundred"] }
        return cardinal(century) + (rest < 10 ? ["oh", ones[rest]] : cardinal(rest))
    }

    static func ordinal(_ value: Int) -> [String] {
        var words = cardinal(value)
        guard let last = words.popLast() else { return [] }
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        if let word = irregular[last] {
            words.append(word)
        } else if last.hasSuffix("y") {
            words.append(String(last.dropLast()) + "ieth")
        } else {
            words.append(last + "th")
        }
        return words
    }
}

/// English spelling-to-sound rules for words the dictionary lacks, such as names: common
/// letter groups, silent letters, a final silent e lengthening the vowel before it, and the
/// first vowel stressed. A guess, good enough to shape a mouth.
enum LipsyncLetterToSound {
    private typealias P = LipsyncPhone.Symbol

    static func phones(_ word: String) -> [LipsyncPhone] {
        let w = Array(word.lowercased().filter { $0.isASCII && $0.isLetter })
        var out: [LipsyncPhone] = []
        var stressed = false
        func vowel(_ symbol: P, reduced: Bool = false) {
            out.append(LipsyncPhone(symbol, stress: reduced || stressed ? 0 : 1))
            if !reduced { stressed = true }
        }
        func consonant(_ symbols: P...) { out += symbols.map { LipsyncPhone($0) } }
        func at(_ k: Int) -> Character? { k >= 0 && k < w.count ? w[k] : nil }
        func isVowel(_ c: Character?) -> Bool { c.map { "aeiou".contains($0) } ?? false }
        func next(_ i: Int, _ s: String) -> Bool {
            let chars = Array(s)
            return i + chars.count <= w.count && Array(w[i..<(i + chars.count)]) == chars
        }
        /// A vowel letter followed by one consonant and a final e is long, as in "made".
        func magicE(_ i: Int) -> Bool {
            i + 2 == w.count - 1 && w.last == "e" && !isVowel(at(i + 1)) && at(i + 1) != "r"
        }
        var i = 0
        while i < w.count {
            let c = w[i]
            let first = i == 0, last = i == w.count - 1
            // Letter groups first, longest first.
            if next(i, "tch") { consonant(.ch); i += 3; continue }
            if next(i, "sch") { consonant(.s, .k); i += 3; continue }
            if next(i, "igh") { vowel(.ay); i += 3; continue }
            if next(i, "ough") || next(i, "augh") { vowel(.ao); i += 4; continue }
            if next(i, "eigh") { vowel(.ey); i += 4; continue }
            if next(i, "tion") { consonant(.sh); vowel(.ah, reduced: true); consonant(.n); i += 4; continue }
            if next(i, "sion") { consonant(.zh); vowel(.ah, reduced: true); consonant(.n); i += 4; continue }
            if next(i, "ture") { consonant(.ch); vowel(.er, reduced: true); i += 4; continue }
            if next(i, "dge") { consonant(.jh); i += 3; continue }
            if next(i, "air") || (next(i, "are") && i + 3 == w.count) { vowel(.eh); consonant(.r); i += 3; continue }
            if next(i, "ear") { vowel(.ih); consonant(.r); i += 3; continue }
            if next(i, "ph") { consonant(.f); i += 2; continue }
            if next(i, "sh") { consonant(.sh); i += 2; continue }
            if next(i, "ch") { consonant(.ch); i += 2; continue }
            if next(i, "th") { consonant(.th); i += 2; continue }
            if next(i, "wh") { consonant(.w); i += 2; continue }
            if next(i, "ck") { consonant(.k); i += 2; continue }
            if next(i, "ng") { consonant(.ng); i += 2; continue }
            if next(i, "nk") { consonant(.ng, .k); i += 2; continue }
            if next(i, "qu") { consonant(.k, .w); i += 2; continue }
            if first && (next(i, "kn") || next(i, "gn")) { consonant(.n); i += 2; continue }
            if first && next(i, "wr") { consonant(.r); i += 2; continue }
            if next(i, "mb") && i + 2 == w.count { consonant(.m); i += 2; continue }
            if next(i, "gh") { if first { consonant(.g) }; i += 2; continue }
            if next(i, "ee") || next(i, "ea") { vowel(.iy); i += 2; continue }
            if next(i, "oo") { vowel(.uw); i += 2; continue }
            if next(i, "ou") { vowel(.aw); i += 2; continue }
            if next(i, "ow") { vowel(i + 2 == w.count ? .ow : .aw); i += 2; continue }
            if next(i, "oa") { vowel(.ow); i += 2; continue }
            if next(i, "ai") || next(i, "ay") || next(i, "ei") || next(i, "ey") { vowel(.ey); i += 2; continue }
            if next(i, "ie") { vowel(i + 2 == w.count && w.count <= 3 ? .ay : .iy); i += 2; continue }
            if next(i, "au") || next(i, "aw") { vowel(.ao); i += 2; continue }
            if next(i, "oi") || next(i, "oy") { vowel(.oy); i += 2; continue }
            if next(i, "ue") || next(i, "ew") || next(i, "ui") { vowel(.uw); i += 2; continue }
            if next(i, "ar") && !isVowel(at(i + 2)) { vowel(.aa); consonant(.r); i += 2; continue }
            if next(i, "or") && !isVowel(at(i + 2)) { vowel(.ao); consonant(.r); i += 2; continue }
            if (next(i, "er") || next(i, "ir") || next(i, "ur")) && !isVowel(at(i + 2)) {
                vowel(.er, reduced: stressed)
                i += 2
                continue
            }
            // A doubled consonant is one sound.
            if i > 0, c == w[i - 1], !isVowel(c), c != "c" {
                i += 1
                continue
            }
            switch c {
            case "a": magicE(i) ? vowel(.ey) : vowel(stressed ? .ah : .ae, reduced: stressed)
            case "e":
                // A final e after a vowel sound is silent.
                if last && i > 0 && out.contains(where: \.isVowel) { break }
                magicE(i) ? vowel(.iy) : vowel(stressed ? .ih : .eh, reduced: stressed)
            case "i": magicE(i) ? vowel(.ay) : vowel(.ih, reduced: stressed)
            case "o": magicE(i) || last ? vowel(.ow) : vowel(stressed ? .ah : .aa, reduced: stressed)
            case "u": magicE(i) ? vowel(.uw) : vowel(.ah, reduced: stressed)
            case "y":
                if first {
                    consonant(.y)
                } else if last {
                    w.count <= 3 ? vowel(.ay) : vowel(.iy, reduced: true)
                } else {
                    vowel(.ih, reduced: stressed)
                }
            case "c": consonant("eiy".contains(at(i + 1) ?? " ") ? .s : .k)
            case "g": consonant(!first && "eiy".contains(at(i + 1) ?? " ") ? .jh : .g)
            case "s":
                let voiced = (isVowel(at(i - 1)) && isVowel(at(i + 1))) || (last && i > 0 && "bdglmnrv".contains(w[i - 1]))
                consonant(voiced ? .z : .s)
            case "x": if first { consonant(.z) } else { consonant(.k, .s) }
            case "h": consonant(.hh)
            case "j": consonant(.jh)
            case "q": consonant(.k)
            // The other consonants are their ARPAbet namesakes.
            default: if let symbol = P(rawValue: c.uppercased()) { consonant(symbol) }
            }
            i += 1
        }
        return out
    }
}

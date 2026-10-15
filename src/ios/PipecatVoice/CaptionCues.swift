import Foundation

/// A flavour cue read from a sentence. Cues only colour the faces' reactions; who holds the
/// floor drives the stage.
enum Cue: Hashable, Sendable, CaseIterable {
    case laugh
    case exclaim
    case question
    case scoff
    /// Angel lines only: praise and good habits.
    case virtue
    /// Devil lines only: an invitation to indulge.
    case temptation
    case wow
    case mentionsAngel
    case mentionsDevil
}

/// Classifies captions into cues with small English lexicons, case-insensitive on word
/// boundaries. The lexicons leave out very common words ("no", "fun", "later", "better").
enum CaptionCues {
    /// The cues in `text`, spoken by `speaker` (nil for the human).
    static func classify(_ text: String, speaker: DuoCharacter?) -> Set<Cue> {
        var cues = Set<Cue>()
        let range = NSRange(text.startIndex..., in: text)
        func matches(_ pattern: NSRegularExpression) -> Bool {
            pattern.firstMatch(in: text, range: range) != nil
        }
        if matches(laugh) || text.unicodeScalars.contains(where: laughEmoji.contains) {
            cues.insert(.laugh)
        }
        let ending = trailingPunctuation(text)
        if ending.hasSuffix("!") || ending.hasSuffix("!?") { cues.insert(.exclaim) }
        if ending.hasSuffix("?") || ending.hasSuffix("?!") { cues.insert(.question) }
        if matches(scoff) { cues.insert(.scoff) }
        if speaker == .angel, matches(virtue) { cues.insert(.virtue) }
        if speaker == .devil, matches(temptation) { cues.insert(.temptation) }
        if matches(wow) { cues.insert(.wow) }
        if matches(angel) { cues.insert(.mentionsAngel) }
        if matches(devil) { cues.insert(.mentionsDevil) }
        return cues
    }

    /// The run of `!` and `?` that ends the sentence, after trimming whitespace, quotes,
    /// closing brackets and emoji. A run ending in "!" or "!?" is an exclamation; one ending
    /// in "?" or "?!" is a question, so "?!" and "!?" are both. Emoji forms of the marks
    /// (‼ ⁉ ❗ ❕ ❓ ❔) count as the marks themselves, not as trimmable emoji.
    static func trailingPunctuation(_ text: String) -> Substring {
        let text = plainMarks(text)
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard isTrimmable(text[previous]) else { break }
            end = previous
        }
        var start = end
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard text[previous] == "!" || text[previous] == "?" else { break }
            start = previous
        }
        return text[start..<end]
    }

    /// `text` with the emoji exclamation and question marks spelled as `!` and `?`, and
    /// variation selectors dropped so a mark stays a character of its own.
    private static func plainMarks(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { emojiMarks[$0] != nil || $0.value == 0xFE0F }) else {
            return text
        }
        var plain = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar.value != 0xFE0F {
            if let mark = emojiMarks[scalar] { plain.append(contentsOf: mark.unicodeScalars) } else { plain.append(scalar) }
        }
        return String(plain)
    }

    private static let emojiMarks: [Unicode.Scalar: String] = [
        "\u{203C}": "!!", "\u{2049}": "!?", "\u{2757}": "!", "\u{2755}": "!", "\u{2753}": "?", "\u{2754}": "?",
    ]

    private static func isTrimmable(_ character: Character) -> Bool {
        if character.isWhitespace || trailingClosers.contains(character) { return true }
        return character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || scalar.value == 0xFE0F || scalar.value == 0x200D
                || (scalar.properties.isEmoji && scalar.value > 0x2000)
        }
    }

    private static let trailingClosers: Set<Character> = [
        "\"", "'", "\u{201D}", "\u{2019}", "\u{201C}", "\u{2018}", "\u{BB}", "\u{203A}", ")", "]", "}",
    ]
    private static let laughEmoji: Set<Unicode.Scalar> = ["\u{1F602}", "\u{1F923}", "\u{1F606}"]

    private static func pattern(_ source: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(
                pattern: source, options: [.caseInsensitive])
        } catch {
            preconditionFailure("Invalid cue pattern \(source): \(error)")
        }
    }

    /// "haha", "Ha!", "hehe", "lol", "lmao"; a lone "Ha." is not a laugh.
    private static let laugh = pattern(#"\b(?:ha){2,}\b|\bha!|\bhe(?:he)+\b|\blol\b|\blmao\b"#)
    private static let scoff = pattern(
        #"^\W*(?:oh,?\s+(?:please|come on|sure)|pfft+|ugh+|puh-?lease|yeah,?\s+right|as if|seriously)\b"#)
    private static let virtue = pattern(
        #"\b(?:proud|wonderful|you deserve|good for you|the right thing|healthy|kind(?!\s+of)|promise)\b"#)
    private static let temptation = pattern(
        #"\b(?:just this once|live a little|treat yourself|why not|skip (?:it|the|this)|nobody will know|who cares|go on)\b"#)
    private static let wow = pattern(#"^\W*(?:wow|whoa|no way)\b|\b(?:amazing|incredible)\b"#)
    private static let angel = pattern(#"\bangel\b"#)
    /// "devil-may-care" is not a mention.
    private static let devil = pattern(#"\bdevil\b(?!-)"#)
}

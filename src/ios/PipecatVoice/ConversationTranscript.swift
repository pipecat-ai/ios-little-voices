import Foundation

/// What the human has said this turn: speech recognition's final fragments, then its live
/// hypothesis for the words after them.
struct UserTranscript: Equatable {
    private(set) var final = ""
    /// The recognizer's current guess at the words after the final fragments.
    var partial = ""

    /// Everything said so far.
    var text: String {
        guard !partial.isEmpty else { return final }
        guard !final.isEmpty else { return partial }
        return final + (final.hasSuffix(" ") ? "" : " ") + partial
    }

    /// Whether every word so far is final.
    var isFinal: Bool { partial.isEmpty }

    /// Add a final fragment, which settles the live hypothesis.
    mutating func commit(_ fragment: String) {
        partial = ""
        guard !fragment.isEmpty else { return }
        final += (final.isEmpty || final.hasSuffix(" ") ? "" : " ") + fragment
    }
}

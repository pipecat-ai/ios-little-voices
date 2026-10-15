import Foundation

/// The angel and the devil. Raw values are Python's ids; each voice must match Python's `CAST`.
enum DuoCharacter: String, CaseIterable, Identifiable, Sendable {
    case angel
    case devil

    var id: Self { self }
    var title: String { self == .angel ? "Angel" : "Devil" }
    var voice: String { self == .angel ? "en_gb_Freya" : "en_gb_Reuben" }
}

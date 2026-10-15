import Foundation

/// The speech engine and its voices, one per character.
enum VoiceSettings {
    static let engineTitle = "Gradium Phonon"
    /// The voices Phonon loads, the angel's first.
    static var voices: [String] { DuoCharacter.allCases.map(\.voice) }
}

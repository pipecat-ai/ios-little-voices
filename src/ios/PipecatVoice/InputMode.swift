import Foundation

/// How the human takes their turns: holding the microphone while they talk, or hands-free, where
/// it listens throughout a conversation and a pause ends each turn.
enum InputMode: String, CaseIterable, Identifiable, Sendable {
    case hold
    case handsFree

    var id: Self { self }

    var title: String { self == .hold ? "Hold to talk" : "Hands-free" }

    private static let key = "input-mode"

    static func load(defaults: UserDefaults = .standard) -> InputMode {
        defaults.string(forKey: key).flatMap(InputMode.init(rawValue:)) ?? .hold
    }

    static func save(_ mode: InputMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}

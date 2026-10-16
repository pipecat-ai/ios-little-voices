import Foundation
import Observation

/// A conversation as it was heard: what the human said and each line the angel and the devil
/// spoke, kept on the device so it can be read again. No audio is kept.
struct SavedConversation: Codable, Identifiable, Equatable, Sendable {
    enum Speaker: String, Codable, Sendable {
        case human, angel, devil

        init(_ character: DuoCharacter) { self = character == .angel ? .angel : .devil }

        var character: DuoCharacter? {
            switch self {
            case .human: nil
            case .angel: .angel
            case .devil: .devil
            }
        }
    }

    struct Entry: Codable, Identifiable, Equatable, Sendable {
        let id: UUID
        let speaker: Speaker
        var text: String
        let time: Date
    }

    let id: UUID
    let started: Date
    var entries: [Entry]

    /// When it was last added to.
    var updated: Date { entries.last?.time ?? started }
    /// What the human first said, if they have.
    var opening: String? { entries.first { $0.speaker == .human }?.text }
}

/// Writes a conversation's transcript as it is heard: the human's words for each turn, updated as
/// they are recognized, and each line's sentences as they start playing, so a line cut off keeps
/// only what was said of it.
struct TranscriptRecorder: Sendable {
    private(set) var conversation: SavedConversation
    private var turn: String?
    /// The current turn's entry for the human's words, and for each of its lines.
    private var human: Int?
    private var lines: [Int: Int] = [:]

    init(id: UUID = UUID(), started: Date = .now) {
        conversation = SavedConversation(id: id, started: started, entries: [])
    }

    var isEmpty: Bool { conversation.entries.isEmpty }

    /// The human's words for `turn` so far.
    mutating func heard(human text: String, turn: String, at time: Date = .now) {
        enter(turn)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let human {
            conversation.entries[human].text = text
        } else {
            human = conversation.entries.count
            conversation.entries.append(.init(id: UUID(), speaker: .human, text: text, time: time))
        }
    }

    /// A sentence of line `line` of `turn` has started playing.
    mutating func heard(sentence: String, line: Int, speaker: DuoCharacter, turn: String, at time: Date = .now) {
        enter(turn)
        let sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return }
        if let index = lines[line] {
            conversation.entries[index].text += " " + sentence
        } else {
            lines[line] = conversation.entries.count
            conversation.entries.append(.init(id: UUID(), speaker: .init(speaker), text: sentence, time: time))
        }
    }

    private mutating func enter(_ turn: String) {
        guard turn != self.turn else { return }
        self.turn = turn
        human = nil
        lines = [:]
    }
}

/// The saved conversations, newest first. Each is a small JSON file in Application Support,
/// excluded from backups so it never leaves the device; files are read and written off the main
/// thread, in order.
@MainActor @Observable
final class ConversationArchive {
    private(set) var conversations: [SavedConversation] = []
    /// The files have been read.
    private(set) var isLoaded = false
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let queue = DispatchQueue(label: "ai.pipecat.littlevoices.history", qos: .utility)

    nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Conversations", directoryHint: .isDirectory)
    }

    init(directory: URL = ConversationArchive.defaultDirectory) {
        self.directory = directory
        queue.async { [weak self, directory] in
            let stored = Self.readAll(in: directory)
            Task { @MainActor in self?.finishLoading(stored) }
        }
    }

    func conversation(_ id: UUID) -> SavedConversation? { conversations.first { $0.id == id } }

    /// Keeps `conversation`, or its latest version; one with nothing said is not kept.
    func save(_ conversation: SavedConversation) {
        guard !conversation.entries.isEmpty else { return }
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            guard conversations[index] != conversation else { return }
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
            conversations.sort { $0.started > $1.started }
        }
        queue.async { [directory] in
            do {
                try Self.prepare(directory)
                let data = try JSONEncoder().encode(conversation)
                try data.write(to: Self.file(for: conversation.id, in: directory), options: .atomic)
            } catch {
                #if DEBUG
                print("HISTORY_FAILED: \(error.localizedDescription)")
                #endif
            }
        }
    }

    func delete(_ ids: some Sequence<UUID>) {
        let ids = Set(ids)
        conversations.removeAll { ids.contains($0.id) }
        queue.async { [directory] in
            for id in ids { try? FileManager.default.removeItem(at: Self.file(for: id, in: directory)) }
        }
    }

    func deleteAll() {
        conversations.removeAll()
        queue.async { [directory] in try? FileManager.default.removeItem(at: directory) }
    }

    /// Waits for the files written or deleted so far.
    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private func finishLoading(_ stored: [SavedConversation]) {
        // Anything saved meanwhile is newer than its file.
        let kept = Set(conversations.map(\.id))
        conversations = (conversations + stored.filter { !kept.contains($0.id) }).sorted { $0.started > $1.started }
        isLoaded = true
    }

    private nonisolated static func file(for id: UUID, in directory: URL) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    private nonisolated static func prepare(_ directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private nonisolated static func readAll(in directory: URL) -> [SavedConversation] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            (try? Data(contentsOf: file)).flatMap { try? decoder.decode(SavedConversation.self, from: $0) }
        }
    }
}

/// Whether conversations are saved, from Settings; they are unless turned off.
enum HistorySettings {
    private static let key = "saves-conversations"

    static func load(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func save(_ saves: Bool, defaults: UserDefaults = .standard) { defaults.set(saves, forKey: key) }
}

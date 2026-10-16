import Foundation

@main @MainActor
enum HistoryChecks {
    static func main() async throws {
        // The transcript as it is heard: the human's words update in place, each line gathers its
        // sentences, and a new turn starts new entries.
        var recorder = TranscriptRecorder()
        precondition(recorder.isEmpty)
        recorder.heard(human: "Should I", turn: "t1")
        recorder.heard(human: "Should I go out tonight?", turn: "t1")
        recorder.heard(sentence: "Go out!", line: 0, speaker: .angel, turn: "t1")
        recorder.heard(sentence: "You deserve it.", line: 0, speaker: .angel, turn: "t1")
        recorder.heard(sentence: "Stay in.", line: 1, speaker: .devil, turn: "t1")
        recorder.heard(sentence: "   ", line: 2, speaker: .angel, turn: "t1")
        recorder.heard(human: "Wait, devil,", turn: "t2")
        recorder.heard(sentence: "Yes?", line: 0, speaker: .devil, turn: "t2")
        let entries = recorder.conversation.entries
        precondition(entries.map(\.speaker) == [.human, .angel, .devil, .human, .devil], "\(entries.map(\.speaker))")
        precondition(entries.map(\.text) == ["Should I go out tonight?", "Go out! You deserve it.", "Stay in.",
                                             "Wait, devil,", "Yes?"], "\(entries.map(\.text))")
        precondition(recorder.conversation.opening == "Should I go out tonight?")

        // Saved, read back, replaced, and deleted, in a scratch directory.
        let directory = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ConversationArchive(directory: directory)
        archive.save(recorder.conversation)
        archive.save(TranscriptRecorder().conversation)
        var later = TranscriptRecorder(started: .now.addingTimeInterval(60))
        later.heard(human: "Hello!", turn: "t1")
        archive.save(later.conversation)
        await archive.flush()
        precondition(archive.conversations.map(\.id) == [later.conversation.id, recorder.conversation.id])

        let reread = ConversationArchive(directory: directory)
        await reread.flush()
        try await waitUntil { reread.isLoaded }
        precondition(reread.conversations == [later.conversation, recorder.conversation])
        let excluded = try URL(filePath: directory.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
        precondition(excluded.isExcludedFromBackup == true)

        later.heard(sentence: "Hi there.", line: 0, speaker: .devil, turn: "t1")
        reread.save(later.conversation)
        reread.delete([recorder.conversation.id])
        await reread.flush()
        let third = ConversationArchive(directory: directory)
        try await waitUntil { third.isLoaded }
        precondition(third.conversations == [later.conversation])

        third.deleteAll()
        await third.flush()
        precondition(!FileManager.default.fileExists(atPath: directory.path))
        print("HISTORY_CHECKS_PASSED: transcripts as heard, saved, read back, replaced and deleted")
    }

    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }
}

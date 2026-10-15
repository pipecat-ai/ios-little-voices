// Runs Apple's on-device model through the app's AppleLanguageModel, on a Mac with Apple
// Intelligence: FOUNDATION_MODELS_RUNTIME=1 uv run pytest tests/test_language_model.py
import Foundation
import FoundationModels

@main
struct LanguageModelRuntimeChecks {
    @MainActor
    static func main() async throws {
        if let reason = AppleLanguageModel.unavailableReason {
            print("SKIP Foundation Models runtime: \(reason)")
            return
        }
        let entries: [Transcript.Entry] = [
            .instructions(.init(segments: [.text(.init(content: "Reply briefly in English."))], toolDefinitions: [])),
            .prompt(.init(segments: [.text(.init(content: "Say hello."))]))
        ]
        let tokens = try await SystemLanguageModel.default.tokenCount(for: entries)
        guard tokens > 0, tokens < SystemLanguageModel.default.contextSize else {
            throw VoiceError(message: "Native token counting returned an invalid input budget")
        }
        print("PASS native transcript tokenCount=\(tokens), contextSize=\(SystemLanguageModel.default.contextSize)")
        let manager = AppleLanguageModel()
        let instructions = "Reply briefly in English. Follow the user's request."
        await manager.prepare(instructions: instructions, history: [])
        // Give the OS's loading hint a short lead without running inference.
        try await Task.sleep(for: .seconds(1))
        var first = ""
        try await manager.generate(prompt: "Say hello in one short sentence.", instructions: instructions, history: []) {
            first += $0
        }
        guard !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceError(message: "Native streaming returned no text")
        }
        print("PASS prepared native streaming, characters=\(first.count)")

        await manager.prepare(instructions: instructions, history: [])
        var receivedBeforeCancellation = false
        do {
            try await manager.generate(prompt: "Count from one to twenty, with a sentence for each number.",
                                       instructions: instructions, history: []) { _ in
                receivedBeforeCancellation = true
                manager.invalidate()
            }
            throw VoiceError(message: "Invalidated native generation completed instead of cancelling")
        } catch is CancellationError {
            guard receivedBeforeCancellation else { throw VoiceError(message: "Stream cancelled before the probe received text") }
        }
        print("PASS native invalidation fences subsequent streaming snapshots")

        await manager.prepare(instructions: instructions, history: [])
        var following = ""
        try await manager.generate(prompt: "Say goodbye in one short sentence.", instructions: instructions, history: []) {
            following += $0
        }
        guard !following.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceError(message: "A request after cancellation could not produce text")
        }
        print("PASS fresh native generation after cancellation, characters=\(following.count)")
    }
}

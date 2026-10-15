// Character probe for scripts/persona_eval.py: replays scenarios through the
// app's AppleLanguageModel on an Apple Intelligence Mac. Not a default unit test.
import Foundation

private struct Scenario: Decodable {
    let name: String
    let prompt: String
    let history: [HistoryMessage]
}

private struct Configuration: Decodable {
    let instructions: String
    let scenarios: [Scenario]
}

private struct Outcome: Encodable {
    let name: String
    let reply: String
    let error: String?
    let seconds: Double
}

@main
struct PersonaEval {
    @MainActor
    static func main() async throws {
        if let reason = AppleLanguageModel.unavailableReason {
            print("PERSONA_EVAL_SKIPPED: \(reason)")
            return
        }
        let configuration = try JSONDecoder().decode(Configuration.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let manager = AppleLanguageModel()
        let encoder = JSONEncoder()
        for scenario in configuration.scenarios {
            var reply = ""
            var failure: String?
            let started = ContinuousClock.now
            do {
                try await manager.generate(prompt: scenario.prompt, instructions: configuration.instructions,
                                           history: scenario.history) { reply += $0 }
            } catch {
                failure = error.localizedDescription
            }
            let elapsed = started.duration(to: .now).components
            let outcome = Outcome(name: scenario.name, reply: reply, error: failure,
                                  seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            print("PERSONA_EVAL_RESULT: " + String(decoding: try encoder.encode(outcome), as: UTF8.self))
        }
    }
}

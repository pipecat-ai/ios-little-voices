import Foundation

private struct CheckFailure: Error { let message: String }

private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(message: message) }
}

@main
struct TTSChecks {
    static func main() async throws {
        try settings()
        try await cancellation()
        print("Native TTS checks passed: Phonon settings, request cancellation")
    }

    static func settings() throws {
        try check(VoiceSettings.engineTitle == "Gradium Phonon", "Wrong speech engine title")
        try check(VoiceSettings.voices == ["en_gb_Freya", "en_gb_Reuben"], "Phonon must load the angel's voice, then the devil's")
    }

    static func cancellation() async throws {
        let first = SpeechSynthesis { output in
            output.yield([1])
            try await Task.sleep(for: .seconds(30))
            output.yield([2])
        }
        var iterator = first.samples.makeAsyncIterator()
        let initial = try await iterator.next()
        try check(initial == [1], "Producer never started")
        first.cancel()
        await first.waitForCompletion()
        do {
            _ = try await iterator.next()
            throw CheckFailure(message: "Cancelled synthesis completed successfully")
        } catch is CancellationError { }

        let next = SpeechSynthesis { output in
            try await Task.sleep(for: .milliseconds(10))
            output.yield([3])
        }
        first.cancel()
        var values: [Float] = []
        for try await chunk in next.samples { values += chunk }
        await next.waitForCompletion()
        try check(values == [3], "Delayed cancellation affected the next request")

        let pending = SpeechSynthesis { output in
            output.yield([4])
            try await Task.sleep(for: .seconds(30))
        }
        let consumer = Task { for try await _ in pending.samples { } }
        consumer.cancel()
        _ = await consumer.result
        await pending.waitForCompletion()
    }
}

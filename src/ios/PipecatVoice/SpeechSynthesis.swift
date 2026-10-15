import Foundation

struct VoiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A single request owns cancellation; delayed cancellation cannot stop another request.
final class SpeechSynthesis: Sendable {
    let samples: AsyncThrowingStream<[Float], Error>
    private let task: Task<Void, Never>

    init(produce: @escaping @Sendable (AsyncThrowingStream<[Float], Error>.Continuation) async throws -> Void) {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        samples = stream
        let task = Task {
            do {
                try Task.checkCancellation()
                try await produce(continuation)
                try Task.checkCancellation()
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        self.task = task
        continuation.onTermination = { reason in
            if case .cancelled = reason { task.cancel() }
        }
    }

    func cancel() { task.cancel() }
    func waitForCompletion() async { await task.value }
}

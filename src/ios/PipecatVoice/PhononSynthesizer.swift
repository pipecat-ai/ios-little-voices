import Foundation

private final class CancellationToken: @unchecked Sendable {
    let pointer = phonon_cancellation_new()!
    func cancel() { phonon_cancel(pointer) }
    deinit { phonon_cancellation_free(pointer) }
}

private final class PCMContext {
    let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    init(_ continuation: AsyncThrowingStream<[Float], Error>.Continuation) {
        self.continuation = continuation
    }
}

/// Streams 24 kHz mono PCM from the bundled Gradium Phonon model through its Rust runtime.
/// One model holds several voices; each request picks one.
final class PhononSynthesizer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "voice.phonon", qos: .userInitiated)
    // All model access is serialized on queue. The C cancellation flag is atomic.
    private var model: OpaquePointer?
    private var loadedVoices: [String] = []

    /// Load the model with `voices`; the first is the default.
    func prepare(voices: [String]) async throws {
        guard let root = Bundle.main.url(forResource: "phonon", withExtension: nil) else {
            throw VoiceError(message: "The Phonon voice model is missing from the app bundle.")
        }
        try Task.checkCancellation()
        try await load(root: root, voices: voices)
        try Task.checkCancellation()
    }

    /// Speak `text` in `voice`, one of those prepared (the first when nil).
    func synthesize(_ text: String, voice: String? = nil) async throws -> SpeechSynthesis {
        SpeechSynthesis { [self] continuation in
            let token = CancellationToken()
            try await withTaskCancellationHandler {
                try await speak(text, voice: voice, token: token, output: continuation)
            } onCancel: { token.cancel() }
        }
    }

    func unload() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let model { phonon_free(model); self.model = nil }
                loadedVoices = []
                continuation.resume()
            }
        }
    }

    private func load(root: URL, voices: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if model != nil && loadedVoices == voices {
                    continuation.resume()
                    return
                }
                if let model { phonon_free(model); self.model = nil }
                var error = [CChar](repeating: 0, count: 1024)
                model = phonon_load(root.path, voices.joined(separator: "\n"), &error, error.count)
                if model == nil {
                    continuation.resume(throwing: VoiceError(message: String(cString: error)))
                } else {
                    loadedVoices = voices
                    continuation.resume()
                }
            }
        }
    }

    private func speak(_ text: String, voice: String?, token: CancellationToken,
                       output: AsyncThrowingStream<[Float], Error>.Continuation) async throws {
        // Completion waits for the Rust call itself, including cancelled inference.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self, token] in
                guard let model else {
                    continuation.resume(throwing: VoiceError(message: "Phonon is not loaded."))
                    return
                }
                let index = voice.flatMap { loadedVoices.firstIndex(of: $0) } ?? (voice == nil ? 0 : nil)
                guard let index else {
                    continuation.resume(throwing: VoiceError(message: "Phonon has no voice named \(voice ?? "")."))
                    return
                }
                let context = Unmanaged.passRetained(PCMContext(output))
                defer { context.release() }
                var error = [CChar](repeating: 0, count: 1024)
                let status = phonon_speak(model, text, index, token.pointer, { samples, count, opaque in
                    guard let samples, let opaque else { return false }
                    let target = Unmanaged<PCMContext>.fromOpaque(opaque).takeUnretainedValue()
                    let chunk = Array(UnsafeBufferPointer(start: samples, count: count))
                    if case .terminated = target.continuation.yield(chunk) { return false }
                    return true
                }, context.toOpaque(), &error, error.count)
                switch status {
                case 0: continuation.resume()
                case 1: continuation.resume(throwing: CancellationError())
                default: continuation.resume(throwing: VoiceError(message: String(cString: error)))
                }
            }
        }
    }

    deinit { if let model { phonon_free(model) } }
}

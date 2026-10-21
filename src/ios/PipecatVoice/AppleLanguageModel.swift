import Foundation
import FoundationModels
import OSLog

@MainActor
final class AppleLanguageModel {
    private struct PreparedSession {
        let session: LanguageModelSession
        let history: [HistoryMessage]
    }

    private let logger = Logger(subsystem: "ai.pipecat.littlevoices", category: "FoundationModels")
    private var cache = PreparedLanguageModelCache<PreparedSession>()
    private var generating = false

    /// Why Apple's language model cannot be used on this device, and what to do about it; nil when it can.
    static var unavailableReason: String? {
        #if os(macOS)
        let settings = "System Settings › Apple Intelligence & Siri"
        #else
        let settings = "Settings › Apple Intelligence & Siri"
        #endif
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn’t support Apple Intelligence, which the angel and the devil need to talk."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in \(settings), then try again."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence isn’t ready on this device yet. In \(settings), check that it has "
                + "finished downloading. It needs free storage, and the device and Siri set to a supported language."
        @unknown default:
            return "Apple Intelligence is unavailable right now. Check \(settings), then try again."
        }
    }

    /// Discard unused sessions and fence work suspended in token counting or streaming.
    func invalidate() {
        cache.invalidate()
        generating = false
    }

    /// Prewarm a session for the next reply; a hint that never generates text.
    func prepare(instructions: String, history: [HistoryMessage]) async {
        guard !generating, Self.unavailableReason == nil, !Task.isCancelled else { return }
        let key = LanguageModelContextKey(instructions: instructions, history: history)
        guard let ticket = cache.beginPreparation(for: key) else { return }
        let started = ContinuousClock.now
        do {
            let selection = try await select(instructions: instructions, history: history, prompt: nil,
                                             reservedPromptTokens: LanguageModelContext.prewarmPromptTokens)
            try Task.checkCancellation()
            guard cache.isCurrent(ticket), !generating else { return }
            let prepared = makeSession(instructions: instructions, history: selection.history)
            prepared.session.prewarm()
            cache.store(prepared, for: key, ticket: ticket)
            logger.debug("LLM prewarm queued: input=\(selection.inputTokens), history=\(selection.history.count), prepare_ms=\(Self.milliseconds(since: started))")
        } catch is CancellationError {
            // The host cancelled this hint; a later request will prepare its own session.
        } catch {
            guard !Task.isCancelled, cache.isCurrent(ticket) else { return }
            let failure = NativeGenerationError.classify(error).atStage("prepare_context")
            logger.debug("LLM prewarm skipped: category=\(failure.code, privacy: .public), domain=\(failure.underlyingDomain, privacy: .public), native_code=\(failure.underlyingCode), stage=count_or_prepare, history=\(history.count)")
        }
    }

    func generate(prompt: String, instructions: String, history: [HistoryMessage],
                  onDelta: (String) -> Void) async throws {
        try Task.checkCancellation()
        if let reason = Self.unavailableReason {
            let failure = NativeGenerationError(code: "LLM_ASSETS", message: reason,
                underlyingDomain: "FoundationModels.Availability", underlyingCode: 1, stage: "availability")
            throw failure
        }
        let started = ContinuousClock.now
        let key = LanguageModelContextKey(instructions: instructions, history: history)
        let prepared = cache.take(for: key)
        // Invalidate suspended preparations and older generations before any await.
        cache.invalidate()
        let epoch = cache.epoch
        generating = true
        defer { if cache.epoch == epoch { generating = false } }

        var stage = "count_context"
        var reused = false
        var inputTokens = -1
        var selectedHistoryCount = history.count
        var emittedCharacters = 0
        do {
            let maximum = inputBudget
            var selected: PreparedSession
            if let prepared {
                let preparedTokens: Int?
                do {
                    preparedTokens = try await count(instructions: instructions, history: prepared.history,
                                                      prompt: prompt)
                } catch LanguageModelContext.BudgetError.tokenCountInputTooLarge {
                    preparedTokens = nil
                }
                try checkCurrent(epoch)
                if let preparedTokens, preparedTokens <= maximum {
                    inputTokens = preparedTokens
                    selected = prepared
                    reused = true
                } else {
                    let selection = try await select(instructions: instructions, history: history, prompt: prompt)
                    try checkCurrent(epoch)
                    inputTokens = selection.inputTokens
                    stage = "create_session"
                    selected = makeSession(instructions: instructions, history: selection.history)
                }
            } else {
                let selection = try await select(instructions: instructions, history: history, prompt: prompt)
                try checkCurrent(epoch)
                inputTokens = selection.inputTokens
                stage = "create_session"
                selected = makeSession(instructions: instructions, history: selection.history)
            }
            try checkCurrent(epoch)
            selectedHistoryCount = selected.history.count
            logger.debug("LLM request: prewarmed=\(reused), input=\(inputTokens), budget=\(maximum), setup_ms=\(Self.milliseconds(since: started))")
            stage = "stream_response"
            let stream = selected.session.streamResponse(to: prompt,
                options: GenerationOptions(maximumResponseTokens: LanguageModelContext.responseTokens))
            var previous = ""
            for try await snapshot in stream {
                try checkCurrent(epoch)
                // Foundation Models emits cumulative snapshots, not token deltas.
                guard snapshot.content.hasPrefix(previous) else {
                    throw NativeGenerationError(code: "LLM_STREAM",
                        message: "Apple’s language model changed a response that was already being spoken. Please try again.",
                        underlyingDomain: "ai.pipecat.littlevoices", underlyingCode: 1)
                }
                let delta = String(snapshot.content.dropFirst(previous.count))
                if previous.isEmpty, !delta.isEmpty {
                    logger.debug("LLM first text: prewarmed=\(reused), elapsed_ms=\(Self.milliseconds(since: started))")
                }
                previous = snapshot.content
                if !delta.isEmpty { emittedCharacters += delta.count; onDelta(delta) }
            }
            try checkCurrent(epoch)
            // Cached input tokens show how much of the prompt the prewarmed session reused.
            let usage = selected.session.usage
            logger.debug("LLM finished: elapsed_ms=\(Self.milliseconds(since: started)), input_tokens=\(usage.input.totalTokenCount), cached_input_tokens=\(usage.input.cachedTokenCount), output_tokens=\(usage.output.totalTokenCount)")
        } catch {
            if Task.isCancelled || cache.epoch != epoch { throw CancellationError() }
            let failure = NativeGenerationError.classify(error).atStage(stage)
            logger.error("LLM failed: category=\(failure.code, privacy: .public), domain=\(failure.underlyingDomain, privacy: .public), native_code=\(failure.underlyingCode), stage=\(stage, privacy: .public), input=\(inputTokens), history=\(selectedHistoryCount), prewarmed=\(reused), emitted_characters=\(emittedCharacters)")
            invalidate()
            throw failure
        }
    }

    private func checkCurrent(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard cache.epoch == epoch else { throw CancellationError() }
    }

    private var inputBudget: Int {
        SystemLanguageModel.default.contextSize - LanguageModelContext.responseTokens
            - LanguageModelContext.safetyTokens
    }

    private func select(instructions: String, history: [HistoryMessage], prompt: String?,
                        reservedPromptTokens: Int = 0) async throws -> LanguageModelContext.Selection {
        try await LanguageModelContext.select(history: history,
            maximumInputTokens: inputBudget - reservedPromptTokens) { candidate in
                try await self.count(instructions: instructions, history: candidate, prompt: prompt)
            }
    }

    private func count(instructions: String, history: [HistoryMessage], prompt: String?) async throws -> Int {
        var transcript = Self.entries(instructions: instructions, history: history)
        if let prompt { transcript.append(.prompt(.init(segments: [.text(.init(content: prompt))]))) }
        do {
            return try await SystemLanguageModel.default.tokenCount(for: transcript)
        } catch {
            if NativeGenerationError.isContextWindowError(error) {
                throw LanguageModelContext.BudgetError.tokenCountInputTooLarge
            }
            throw error
        }
    }

    private func makeSession(instructions: String, history: [HistoryMessage]) -> PreparedSession {
        let entries = Self.entries(instructions: instructions, history: history)
        return PreparedSession(session: LanguageModelSession(transcript: Transcript(entries: entries)),
                               history: history)
    }

    /// A request's transcript: instructions, then the human's lines as prompts and the
    /// characters' as responses.
    static func entries(instructions: String, history: [HistoryMessage]) -> [Transcript.Entry] {
        [.instructions(.init(segments: [.text(.init(content: instructions))], toolDefinitions: []))]
            + history.filter { !$0.content.isEmpty }.map { message in
                let segments: [Transcript.Segment] = [.text(.init(content: message.content))]
                return message.role == "user"
                    ? .prompt(.init(segments: segments))
                    : .response(.init(assetIDs: [], segments: segments))
            }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = start.duration(to: .now).components
        return elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
    }
}

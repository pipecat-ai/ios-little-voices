import Foundation

private struct CheckFailure: Error { let message: String }

private final class SessionFixture {
    var generated = ""
}

private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(message: message) }
}

@main
struct LanguageModelChecks {
    static func main() async throws {
        let history = (1...4).flatMap { number in
            [HistoryMessage(role: "user", content: "Question \(number)"),
             HistoryMessage(role: "assistant", content: "Played reply \(number)")]
        }
        // A fixture tokenizer charges 20 tokens per historical message and 50
        // for the system instructions plus current user prompt.
        let selection = try await LanguageModelContext.select(history: history, maximumInputTokens: 130) {
            50 + $0.count * 20
        }
        try check(selection.history == Array(history.suffix(4)), "Budget split or lost the most recent complete turns")
        try check(selection.inputTokens == 130, "An exact-fit token budget was rejected")

        let smaller = try await LanguageModelContext.select(history: history, maximumInputTokens: 129) {
            50 + $0.count * 20
        }
        try check(smaller.history == Array(history.suffix(2)), "Overflow kept an orphan assistant response")
        let empty = try await LanguageModelContext.select(history: history, maximumInputTokens: 50) {
            50 + $0.count * 20
        }
        try check(empty.history.isEmpty && empty.inputTokens == 50, "Empty history did not preserve input budget")
        do {
            _ = try await LanguageModelContext.select(history: history, maximumInputTokens: 49) { _ in 50 }
            throw CheckFailure(message: "Oversized instructions/current prompt were silently admitted")
        } catch LanguageModelContext.BudgetError.inputTooLarge { }

        let tokenizerOverflow = try await LanguageModelContext.select(history: history, maximumInputTokens: 130) {
            if $0.count >= 6 { throw LanguageModelContext.BudgetError.tokenCountInputTooLarge }
            return 50 + $0.count * 20
        }
        try check(tokenizerOverflow.history == Array(history.suffix(4)),
                  "An oversized native token-count request aborted whole-turn pruning")
        do {
            _ = try await LanguageModelContext.select(history: history, maximumInputTokens: 130) { _ in
                throw LanguageModelContext.BudgetError.tokenCountInputTooLarge
            }
            throw CheckFailure(message: "An oversized current prompt was admitted without a token count")
        } catch LanguageModelContext.BudgetError.inputTooLarge { }
        struct TokenizerUnavailable: Error { }
        do {
            _ = try await LanguageModelContext.select(history: history, maximumInputTokens: 130) { _ in
                throw TokenizerUnavailable()
            }
            throw CheckFailure(message: "A model/tokenizer failure was hidden by dropping history")
        } catch is TokenizerUnavailable { }

        let orphan = [HistoryMessage(role: "assistant", content: "Not attached to any user turn")]
        try check(LanguageModelContext.turns(in: orphan + history, maximumTurns: 2).flatMap { $0 }
                  == Array(history.suffix(4)), "History cap retained an orphan or too many turns")
        let interrupted = [HistoryMessage(role: "user", content: "A reply was interrupted before playback")]
        try check(LanguageModelContext.turns(in: interrupted) == [interrupted], "Unanswered user turn was lost")
        let segmented = Array(history.prefix(2)) + [HistoryMessage(role: "assistant", content: "Another played sentence")]
        try check(LanguageModelContext.turns(in: segmented).count == 1, "Played sentences became separate turns")
        try check(LanguageModelContext.turns(in: history, maximumCharacters: 1).isEmpty,
                  "A history cap truncated a message instead of dropping its whole turn")

        try check(LanguageModelContext.responseTokens + LanguageModelContext.safetyTokens == 288,
                  "Generation reserve no longer includes response and safety headroom")

        let cancelled = Task {
            try await LanguageModelContext.select(history: history, maximumInputTokens: 130) { messages in
                await Task.yield()
                return 50 + messages.count * 20
            }
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw CheckFailure(message: "Cancelled token selection completed successfully")
        } catch is CancellationError { }

        let key = LanguageModelContextKey(instructions: "Rules", history: history)
        var cache = PreparedLanguageModelCache<String>()
        var ticket = cache.beginPreparation()
        cache.store("unused session", for: key, ticket: ticket)
        try check(cache.take(for: key) == "unused session", "Matching committed context missed its cache")
        try check(cache.take(for: key) == nil, "A used session with potentially unplayed output was reused")

        ticket = cache.beginPreparation()
        cache.store("old instructions", for: key, ticket: ticket)
        let changedInstructions = LanguageModelContextKey(instructions: "New rules", history: history)
        try check(cache.take(for: changedInstructions) == nil, "Changed instructions reused an incompatible session")
        ticket = cache.beginPreparation()
        cache.store("old history", for: key, ticket: ticket)
        let changedHistory = LanguageModelContextKey(instructions: "Rules", history: Array(history.dropLast()))
        try check(cache.take(for: changedHistory) == nil, "Interrupted playback reused the uncommitted assistant text")

        ticket = cache.beginPreparation()
        let oldEpoch = cache.epoch
        cache.invalidate()
        cache.store("late cancelled preparation", for: key, ticket: ticket)
        try check(cache.epoch != oldEpoch && cache.take(for: key) == nil,
                  "Session reset allowed a suspended preparation to repopulate the cache")
        let oldTicket = cache.beginPreparation()
        let newTicket = cache.beginPreparation()
        cache.store("new preparation", for: key, ticket: newTicket)
        cache.store("late old preparation", for: key, ticket: oldTicket)
        try check(cache.take(for: key) == "new preparation", "Slow old preparation overwrote the current one")
        ticket = cache.beginPreparation()
        _ = cache.take(for: key)
        cache.store("preparation completed after generation began", for: key, ticket: ticket)
        try check(cache.take(for: key) == nil, "Generation did not fence an unfinished prewarm")

        var sessions = PreparedLanguageModelCache<SessionFixture>()
        let firstSession = SessionFixture()
        var sessionTicket = sessions.beginPreparation()
        sessions.store(firstSession, for: key, ticket: sessionTicket)
        let repeatedHint = sessions.beginPreparation(for: key)
        try check(repeatedHint == nil, "Identical user-start prewarm discarded a ready session")
        try check(sessions.isCurrent(sessionTicket), "An identical hint invalidated the prepared session ticket")
        let firstReply = sessions.take(for: key)
        try check(firstReply === firstSession, "Repeated prewarming replaced the ready native session")
        firstReply?.generated = "Text generated but never played"
        try check(sessions.take(for: key) == nil, "Identical next prompt reused interrupted native state")
        let secondSession = SessionFixture()
        sessionTicket = sessions.beginPreparation()
        sessions.store(secondSession, for: key, ticket: sessionTicket)
        let secondReply = sessions.take(for: key)
        try check(secondReply === secondSession && secondReply !== firstReply && secondReply?.generated == "",
                  "A newly prepared session inherited unplayed native output for identical input")

        sessionTicket = sessions.beginPreparation()
        sessions.store(SessionFixture(), for: key, ticket: sessionTicket)
        try check(sessions.beginPreparation(for: changedHistory) != nil,
                  "Changed played context incorrectly reused a prepared session")
        try check(sessions.take(for: key) == nil, "Preparing changed context retained the obsolete ready session")
        if CommandLine.arguments.count > 1 {
            struct ConfiguredPrompt: Decodable {
                let instructions: String
                let prompt: String
            }
            let configured = try JSONDecoder().decode([ConfiguredPrompt].self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let inputBudget = 4096 - LanguageModelContext.responseTokens - LanguageModelContext.safetyTokens
            let prior = (1...4).flatMap { index in
                [HistoryMessage(role: "user", content: "Earlier question \(index)"),
                 HistoryMessage(role: "assistant", content: String(repeating: "A previous spoken reply. ", count: 10))]
            }
            for configured in configured {
                let selected = try await LanguageModelContext.select(history: prior, maximumInputTokens: inputBudget) {
                    conservativeTokens(instructions: configured.instructions,
                        history: $0, prompt: configured.prompt)
                }
                try check(selected.inputTokens <= inputBudget,
                          "The configured profile and instructions cannot fit a conservative byte budget")
            }
        }
        print("Native language model checks passed")
    }
}

/// Overestimates Apple's tokenizer, which averages about four characters per
/// English token: two ASCII bytes per token, a token per non-ASCII byte (as in
/// byte-fallback tokenization of rare scripts), and per-entry overhead.
private func conservativeTokens(instructions: String, history: [HistoryMessage], prompt: String?) -> Int {
    func tokens(_ text: String) -> Int {
        let ascii = text.utf8.filter { $0 < 0x80 }.count
        return (ascii + 1) / 2 + (text.utf8.count - ascii) + 64
    }
    return tokens(instructions)
        + history.reduce(0) { $0 + tokens($1.content) }
        + (prompt.map(tokens) ?? 0)
}

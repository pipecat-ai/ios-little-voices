import Foundation

/// A message of the conversation Python sends with each request: the human's (`user`) or a
/// character's (`assistant`).
struct HistoryMessage: Decodable, Equatable, Sendable {
    let role: String
    let content: String
}

struct LanguageModelContextKey: Equatable {
    let instructions: String
    let history: [HistoryMessage]
}

/// Bounded conversation selection, independent of the Foundation Models runtime.
enum LanguageModelContext {
    static let responseTokens = 160
    static let safetyTokens = 128
    static let prewarmPromptTokens = 512

    struct Selection {
        let history: [HistoryMessage]
        let inputTokens: Int
    }

    enum BudgetError: LocalizedError {
        case inputTooLarge
        case tokenCountInputTooLarge

        var errorDescription: String? {
            "This message is too long for the on-device language model. Please try a shorter message."
        }
    }

    /// Keep a bounded suffix, with each user's messages and replies removed together.
    static func turns(in history: [HistoryMessage], maximumTurns: Int = 32,
                      maximumCharacters: Int = 32_000) -> [[HistoryMessage]] {
        var turns: [[HistoryMessage]] = []
        for message in history where !message.content.isEmpty {
            if message.role == "user" {
                turns.append([message])
            } else if message.role == "assistant", !turns.isEmpty {
                turns[turns.count - 1].append(message)
            }
        }
        var characters = 0
        var retained: [[HistoryMessage]] = []
        for turn in turns.reversed().prefix(maximumTurns) {
            let size = turn.reduce(0) { $0 + $1.content.count }
            guard characters + size <= maximumCharacters else { break }
            characters += size
            retained.append(turn)
        }
        return retained.reversed()
    }

    /// Choose the longest suffix that fits; count includes instructions and the new prompt.
    static func select(history: [HistoryMessage], maximumInputTokens: Int,
                       count: ([HistoryMessage]) async throws -> Int) async throws -> Selection {
        // The native tokenizer can reject an oversized transcript before returning
        // a count. Only that specific failure means this suffix is too large.
        func measure(_ candidate: [HistoryMessage]) async throws -> Int? {
            do {
                let tokens = try await count(candidate)
                try Task.checkCancellation()
                return tokens
            } catch BudgetError.tokenCountInputTooLarge {
                try Task.checkCancellation()
                return nil
            }
        }
        let turns = turns(in: history)
        let all = turns.flatMap { $0 }
        if let allCount = try await measure(all), allCount <= maximumInputTokens {
            return Selection(history: all, inputTokens: allCount)
        }
        guard let emptyCount = try await measure([]), emptyCount <= maximumInputTokens else {
            throw BudgetError.inputTooLarge
        }
        var selection = Selection(history: [], inputTokens: emptyCount)
        // Token usage grows with complete transcript entries. Binary search avoids
        // repeatedly tokenizing every suffix of a longer conversation.
        var lower = 1
        var upper = turns.count - 1
        while lower <= upper {
            let length = lower + (upper - lower) / 2
            let candidate = turns.suffix(length).flatMap { $0 }
            if let tokens = try await measure(candidate), tokens <= maximumInputTokens {
                selection = Selection(history: candidate, inputTokens: tokens)
                lower = length + 1
            } else {
                upper = length - 1
            }
        }
        return selection
    }
}

/// Only unused, authoritative-context sessions may be cached. A consumed session
/// is never returned: its transcript can contain output the user did not hear.
struct PreparedLanguageModelCache<Value> {
    struct Ticket: Equatable {
        let epoch: UInt64
        let preparation: UInt64
    }

    private(set) var epoch: UInt64 = 0
    private var preparation: UInt64 = 0
    private var entry: (key: LanguageModelContextKey, value: Value)?

    /// Repeated hints must preserve an already prepared exact-context session.
    mutating func beginPreparation(for key: LanguageModelContextKey) -> Ticket? {
        guard entry?.key != key else { return nil }
        return beginPreparation()
    }

    mutating func beginPreparation() -> Ticket {
        preparation &+= 1
        entry = nil
        return Ticket(epoch: epoch, preparation: preparation)
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        ticket.epoch == epoch && ticket.preparation == preparation
    }

    mutating func store(_ value: Value, for key: LanguageModelContextKey, ticket: Ticket) {
        guard isCurrent(ticket) else { return }
        entry = (key, value)
    }

    mutating func take(for key: LanguageModelContextKey) -> Value? {
        preparation &+= 1
        defer { entry = nil }
        guard entry?.key == key else { return nil }
        return entry?.value
    }

    mutating func invalidate() {
        epoch &+= 1
        preparation &+= 1
        entry = nil
    }
}

import Foundation
import FoundationModels

/// A language model failure: a stable code for logs, and a message that says what to do.
struct NativeGenerationError: LocalizedError, Sendable {
    let code: String
    let message: String
    let underlyingDomain: String
    let underlyingCode: Int
    let stage: String?

    init(code: String, message: String, underlyingDomain: String, underlyingCode: Int, stage: String? = nil) {
        self.code = code
        self.message = message
        self.underlyingDomain = underlyingDomain
        self.underlyingCode = underlyingCode
        self.stage = stage
    }

    func atStage(_ stage: String) -> NativeGenerationError {
        NativeGenerationError(code: code, message: message, underlyingDomain: underlyingDomain,
                              underlyingCode: underlyingCode, stage: stage)
    }

    var errorDescription: String? { "\(message) [\(code)]" }

    static func isContextWindowError(_ error: Error) -> Bool {
        if case LanguageModelError.contextSizeExceeded = error { return true }
        let native = error as NSError
        return native.domain == "FoundationModels.LanguageModelError" && native.code == 0
    }

    static func classify(_ error: Error) -> NativeGenerationError {
        if let classified = error as? NativeGenerationError { return classified }
        let native = error as NSError
        func failure(_ code: String, _ message: String) -> NativeGenerationError {
            NativeGenerationError(code: code, message: message,
                                  underlyingDomain: native.domain, underlyingCode: native.code)
        }
        if isContextWindowError(error) {
            return failure("LLM_CONTEXT", "Apple’s language model ran out of room for this reply. Please ask a shorter question.")
        }
        if let budget = error as? LanguageModelContext.BudgetError {
            switch budget {
            case .inputTooLarge, .tokenCountInputTooLarge:
                return failure("LLM_INPUT", "This question is too long for Apple’s language model. Please ask a shorter question.")
            }
        }
        // Apps built with Xcode 27 receive these iOS 27 types instead of the
        // deprecated LanguageModelSession.GenerationError.
        if let model = error as? LanguageModelError {
            switch model {
            case .guardrailViolation, .refusal:
                return failure("LLM_DECLINED", "Apple’s language model declined this request. Please try a different question.")
            case .unsupportedLanguageOrLocale:
                return failure("LLM_LANGUAGE", "Apple’s language model does not support this request’s language. Please ask in English.")
            case .rateLimited:
                return failure("LLM_BUSY", "Apple’s language model is busy. Wait a moment and try again.")
            case .timeout:
                return failure("LLM_TIMEOUT", "Apple’s language model took too long to reply. Please try again.")
            case .contextSizeExceeded, .unsupportedCapability, .unsupportedTranscriptContent,
                 .unsupportedGenerationGuide:
                break
            @unknown default:
                break
            }
        }
        if let system = error as? SystemLanguageModel.Error {
            switch system {
            case .assetsUnavailable:
                return failure("LLM_ASSETS", "Apple’s language model is unavailable. Check Apple Intelligence in Settings and try again.")
            @unknown default:
                break
            }
        }
        if let session = error as? LanguageModelSession.Error, session == .concurrentRequests {
            return failure("LLM_CONCURRENT", "Apple’s language model is still finishing another reply. Please try again.")
        }
        if error is GeneratedContent.ParsingError {
            return failure("LLM_DECODING", "Apple’s language model could not produce a valid response. Please try again.")
        }
        return failure("LLM_FAILED", "Apple’s language model could not complete this reply. Please try again.")
    }
}

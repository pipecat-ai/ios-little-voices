import Observation

/// A transient start request survives cold launch until Python and the foreground UI are ready.
@MainActor
@Observable
final class ConversationLaunchRequests {
    static let shared = ConversationLaunchRequests()
    private(set) var pendingStart = false

    /// Coalesce repeated shortcuts while the app is still becoming ready.
    func request() { pendingStart = true }

    /// The host passes its readiness and foreground checks together, then starts or unmutes once.
    @discardableResult
    func consume(whenReady: Bool) -> Bool {
        guard whenReady, pendingStart else { return false }
        pendingStart = false
        return true
    }

    /// Backgrounding or an explicit stop must not leave a delayed microphone start behind.
    func cancel() { pendingStart = false }
}

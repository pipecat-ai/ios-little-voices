import AppIntents

struct StartConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start conversation"
    static var description = IntentDescription("Open Little Voices and start a voice conversation.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        ConversationLaunchRequests.shared.request()
        return .result()
    }
}

struct PipecatShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartConversationIntent(), phrases: [
            "Start a conversation with \(.applicationName)",
            "Talk to \(.applicationName)"
        ], shortTitle: "Start conversation", systemImageName: "mic.fill")
    }
}

import Foundation

private struct CheckFailure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(message: message) }
}

@main
struct ConversationLaunchChecks {
    @MainActor
    static func main() throws {
        let requests = ConversationLaunchRequests()
        var starts = 0
        var foreground = false
        var pythonReady = false
        func drain() {
            if requests.consume(whenReady: foreground && pythonReady) { starts += 1 }
        }

        // A cold-launch intent can arrive before either the scene or Python is ready.
        requests.request()
        drain()
        try check(starts == 0 && requests.pendingStart, "Cold launch lost its pending request")
        foreground = true
        drain()
        try check(starts == 0 && requests.pendingStart, "The shortcut started before Python was ready")
        requests.request()
        requests.request()
        pythonReady = true
        drain()
        drain()
        try check(starts == 1 && !requests.pendingStart, "Duplicate cold-start requests started multiple conversations")

        // A warm foreground request is consumed once; a later explicit request is independent.
        requests.request()
        drain()
        try check(starts == 2, "A ready foreground app ignored its shortcut")
        requests.request()
        drain()
        try check(starts == 3, "A new shortcut could not start after the previous request completed")

        foreground = false
        requests.request()
        drain()
        try check(starts == 3 && requests.pendingStart, "Ready Python bypassed the foreground requirement")
        requests.cancel()
        foreground = true
        drain()
        try check(starts == 3 && !requests.pendingStart, "Background cancellation left a delayed microphone start")

        pythonReady = false
        requests.request()
        requests.cancel()
        pythonReady = true
        drain()
        try check(starts == 3, "An explicit stop was undone by delayed Python readiness")

        requests.request()
        let relaunched = ConversationLaunchRequests()
        try check(!relaunched.pendingStart, "A new process inherited a persisted microphone-start request")
        requests.cancel()
        print("Conversation launch checks passed")
    }
}

import Foundation

private struct CheckFailure: Error { let message: String }

private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(message: message) }
}

@main
struct TranscriptChecks {
    static func main() throws {
        var heard = UserTranscript()
        try check(heard.text.isEmpty && heard.isFinal, "A new turn started with words")

        heard.partial = "Let’s plan a weekend"
        try check(heard.text == "Let’s plan a weekend" && !heard.isFinal, "A live hypothesis was not shown as live")
        heard.partial = "Let’s plan a day"
        try check(heard.text == "Let’s plan a day", "A revised hypothesis kept the obsolete one")

        heard.commit("Let’s plan a day out.")
        try check(heard.text == "Let’s plan a day out." && heard.isFinal, "A final fragment kept the hypothesis it settled")

        heard.partial = "Somewhere nearby"
        try check(heard.text == "Let’s plan a day out. Somewhere nearby" && !heard.isFinal,
                  "Words after a final fragment were not joined to it")
        heard.commit("Somewhere nearby.")
        try check(heard.text == "Let’s plan a day out. Somewhere nearby.", "Final fragments were not joined in order")

        var spaced = UserTranscript()
        spaced.commit("Hello ")
        spaced.partial = "there"
        try check(spaced.text == "Hello there", "A fragment's trailing space was doubled")

        heard.partial = "um"
        heard.commit("")
        try check(heard.text == "Let’s plan a day out. Somewhere nearby." && heard.isFinal,
                  "An empty final fragment kept a stale hypothesis")
        print("Native transcript checks passed")
    }
}

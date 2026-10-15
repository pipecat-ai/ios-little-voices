import CoreML
import Foundation

// Runs AudienceModel (tokenizer, Core ML encoder and head) on the requests in tests/fixtures/audience/answers.json
// and compares its answers with the SpellSpeak reference runtime's on ONNX Runtime.
private struct Fixture: Decodable {
    struct Request: Decodable {
        let cards: [String]
        let line: String
        let current: Int
        let people: [[Float]]
        let features: [Float]
        let person: [Double]
        let unclear: Double
        let group: Double
    }

    let source: String
    let requests: [Request]
}

private func reading(person: [Double], unclear: Double, group: Double) -> String {
    if unclear >= 0.5 { return "unclear" }
    if group >= 0.5 { return "group" }
    return String(person.indices.max { person[$0] < person[$1] }!)
}

@main
enum AudienceModelChecks {
    static func main() throws {
        let arguments = CommandLine.arguments
        let model = try AudienceModel(directory: URL(fileURLWithPath: arguments[1]),
                                      computeUnits: arguments.count > 3 && arguments[3] == "all" ? .all : .cpuOnly)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        var worst = 0.0
        var times: [Double] = []
        for request in fixture.requests {
            let started = ProcessInfo.processInfo.systemUptime
            let answer = try model.answer(cards: request.cards, line: request.line, current: request.current,
                                          people: request.people, features: request.features)
            times.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            let differences = zip(answer.person, request.person).map { abs($0 - $1) }
                + [abs(answer.unclear - request.unclear), abs(answer.group - request.group)]
            worst = max(worst, differences.max()!)
            let got = reading(person: answer.person, unclear: answer.unclear, group: answer.group)
            let expected = reading(person: request.person, unclear: request.unclear, group: request.group)
            precondition(got == expected, "reading \(got) != \(expected) for \(request.line.debugDescription)")
        }
        precondition(worst < 1e-4, "probabilities differ from the reference by \(worst)")
        let warm = times.dropFirst(20).sorted()
        print("AUDIENCE_MODEL_CHECKS_PASSED: \(fixture.requests.count) answers match \(fixture.source); largest "
            + String(format: "difference %.1e, median %.1f ms per line", worst, warm[warm.count / 2]))
    }
}

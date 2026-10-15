import Foundation

// Compares AudienceTokenizer with the tokenizers library on the texts in tests/fixtures/audience/tokenization.json.
private struct Fixture: Decodable {
    struct Case: Decodable {
        let text: String
        let max_length: Int
        let ids: [Int32]
        let offsets: [[Int]]
    }

    let source: String
    let cases: [Case]
}

@main
enum AudienceTokenizerChecks {
    static func main() throws {
        let arguments = CommandLine.arguments
        let tokenizer = try AudienceTokenizer(contentsOf: URL(fileURLWithPath: arguments[1]))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        var failures = 0
        for item in fixture.cases {
            let got = tokenizer.encode(item.text, maxLength: item.max_length)
            let offsets = got.offsets.map { [$0.start, $0.end] }
            if got.ids != item.ids || offsets != item.offsets {
                failures += 1
                if failures <= 5 {
                    let firstDiff = zip(got.ids, item.ids).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                    FileHandle.standardError.write("""
                        mismatch for \(item.text.debugDescription.prefix(80)) (max \(item.max_length))
                          ids \(got.ids.count) vs \(item.ids.count), first id difference at \(firstDiff.map(String.init) ?? "none")
                          got      \(got.ids.prefix(24)) \(offsets.prefix(12))
                          expected \(item.ids.prefix(24)) \(item.offsets.prefix(12))

                        """.data(using: .utf8)!)
                }
            }
        }
        precondition(failures == 0, "\(failures) of \(fixture.cases.count) encodings differ from \(fixture.source)")
        let started = ProcessInfo.processInfo.systemUptime
        for item in fixture.cases { _ = tokenizer.encode(item.text, maxLength: item.max_length) }
        let perText = (ProcessInfo.processInfo.systemUptime - started) * 1000 / Double(fixture.cases.count)
        print("AUDIENCE_TOKENIZER_CHECKS_PASSED: \(fixture.cases.count) encodings match \(fixture.source); "
            + String(format: "%.3f ms per text", perText))
    }
}

import Foundation

// Compares the Swift FormantLipsyncAnalyzer with the pipecat-visemes Python reference
// (tests/fixtures/lipsync/make_fixture.py) on the same 16 kHz audio: with the reference's
// defaults, or with the dead band the fixture names.
private struct Expected: Decodable {
    let source: String
    let keyframes: [[Double]]
    let events: [[ExpectedValue]]
    let deadBand: Double?

    enum CodingKeys: String, CodingKey {
        case source, keyframes, events
        case deadBand = "dead_band"
    }
}

private enum ExpectedValue: Decodable {
    case number(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) { self = .number(value) } else { self = .text(try container.decode(String.self)) }
    }

    var number: Double { if case .number(let value) = self { return value }; return .nan }
    var text: String { if case .text(let value) = self { return value }; return "" }
}

private func readWAV(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    // Canonical 44-byte header written by the fixture script: 16 kHz mono 16-bit PCM.
    precondition(data.count > 44 && data[22] == 1 && data[24] == 0x80 && data[25] == 0x3E && data[34] == 16)
    return data[44...].withUnsafeBytes { raw in
        raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
    }
}

@main
enum LipsyncChecks {
    static func main() throws {
        let arguments = CommandLine.arguments
        let audio = try readWAV(URL(fileURLWithPath: arguments[1]))
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        // NumPy's BLAS and vDSP sum Float32 in different orders, so values agree only to a
        // tolerance; confidence, a diagnostic, drifts most.
        let tolerance = arguments.count > 3 ? Double(arguments[3])! : 5e-3
        let confidenceTolerance = 4 * tolerance

        // A different chunk size than the reference proves streaming is hop-exact.
        let analyzer = expected.deadBand.map { FormantLipsyncAnalyzer(deadBand: $0) } ?? FormantLipsyncAnalyzer()
        var keyframes: [LipsyncKeyframe] = []
        var events: [LipsyncEvent] = []
        var start = 0
        while start < audio.count {
            let result = analyzer.analyze(Array(audio[start..<min(start + 997, audio.count)]))
            keyframes += result.keyframes
            events += result.events
            start += 997
        }
        let tail = analyzer.flush()
        keyframes += tail.keyframes
        events += tail.events

        precondition(keyframes.count == expected.keyframes.count,
                     "keyframes \(keyframes.count) != reference \(expected.keyframes.count)")
        var worst = [Double](repeating: 0, count: 7)
        for (actual, reference) in zip(keyframes, expected.keyframes) {
            let values = [actual.offset, actual.openness, actual.width, actual.rounding, actual.energy, actual.pitch, actual.confidence]
            for i in 0..<7 { worst[i] = max(worst[i], abs(values[i] - reference[i])) }
        }
        FileHandle.standardError.write("max |swift - python|: offset \(worst[0]), openness \(worst[1]), width \(worst[2]), rounding \(worst[3]), energy \(worst[4]), pitch \(worst[5]), confidence \(worst[6])\n".data(using: .utf8)!)
        precondition(worst[0] < 1e-9, "keyframe offsets differ")
        precondition(worst[1...5].allSatisfy { $0 <= tolerance }, "keyframe values differ beyond \(tolerance)")
        precondition(worst[6] <= confidenceTolerance, "keyframe confidence differs beyond \(confidenceTolerance)")

        precondition(events.count == expected.events.count, "events \(events.count) != reference \(expected.events.count)")
        for (actual, reference) in zip(events, expected.events) {
            precondition(actual.kind.rawValue == reference[1].text, "event \(actual.kind) != \(reference[1].text)")
            precondition(abs(actual.offset - reference[0].number) < 1e-9, "event offset differs")
            precondition(abs(actual.duration - reference[2].number) < 1e-9, "event duration differs")
            precondition(abs(actual.confidence - reference[3].number) <= confidenceTolerance, "event confidence differs")
        }
        let settings = expected.deadBand.map { "dead band \($0)" } ?? "defaults"
        print("LIPSYNC_CHECKS_PASSED: \(keyframes.count) keyframes and \(events.count) events match \(expected.source) (\(settings))")
    }
}

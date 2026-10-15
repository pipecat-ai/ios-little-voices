import CoreML
import Foundation

@main
enum PerformanceChecks {
    static func near(_ actual: Double?, _ expected: Double, file: StaticString = #filePath, line: UInt = #line) {
        precondition(actual != nil && abs(actual! - expected) < 0.000_001,
                     "Expected \(expected), received \(String(describing: actual))", file: file, line: line)
    }

    static func main() {
        let expectedAssertions = CommandLine.arguments.contains("--expect-assertions")
        precondition(SpeechBenchmarkBuild.current.swiftAssertionsEnabled == expectedAssertions)

        // A slow first chunk is startup latency, not an underflow. Earlier queued
        // audio absorbs an arrival gap longer than a single 80ms frame.
        var buffered = SpeechStreamMetrics(started: 10)
        buffered.record(samples: 1920, at: 12)
        buffered.record(samples: 1920, at: 12.01)
        buffered.record(samples: 1920, at: 12.14)
        let bufferedReport = buffered.report(finished: 12.15)
        near(bufferedReport.firstChunkSeconds, 2)
        near(bufferedReport.audioSeconds, 0.24)
        near(bufferedReport.realTimeFactor, 2.15 / 0.24)
        near(bufferedReport.maxChunkGapSeconds, 0.13)
        precondition(bufferedReport.potentialUnderflowCount == 0)

        // Supplying 80ms of audio every 120ms leaves five 40ms holes, excluding
        // the initial wait and excluding any time after the producer finishes.
        var slow = SpeechStreamMetrics(started: 0)
        for index in 0..<6 { slow.record(samples: 1920, at: 1 + Double(index) * 0.12) }
        let slowReport = slow.report(finished: 2)
        precondition(slowReport.chunks == 6 && slowReport.samples == 11_520)
        precondition(slowReport.potentialUnderflowCount == 5)
        near(slowReport.potentialUnderflowSeconds, 0.2)
        near(slowReport.p95ChunkGapSeconds, 0.12)

        // Fast bursts and equal timestamps remain valid; stale/nonfinite/empty
        // observations cannot contaminate a report or produce invalid JSON.
        var burst = SpeechStreamMetrics(started: 3)
        precondition(!burst.record(samples: 1920, at: .nan))
        precondition(!burst.record(samples: 1920, at: .infinity))
        precondition(!burst.record(samples: 1920, at: 2))
        precondition(!burst.record(samples: 0, at: 3))
        precondition(!burst.record(samples: -1, at: 3))
        precondition(burst.record(samples: 1920, at: 3.1))
        precondition(burst.record(samples: 1920, at: 3.1))
        precondition(!burst.record(samples: 1920, at: 3.05))
        let burstReport = burst.report(finished: .nan)
        near(burstReport.generationSeconds, 0.1)
        precondition(burstReport.potentialUnderflowCount == 0)
        precondition((try? JSONEncoder().encode(burstReport)) != nil)
        let emptyReport = SpeechStreamMetrics(started: 5).report(finished: 4)
        precondition(emptyReport.realTimeFactor == nil && emptyReport.firstChunkSeconds == nil)
        near(emptyReport.generationSeconds, 0)

        print("Speech performance checks passed")
    }
}

#if DEBUG
import Foundation

/// Whether this build checks Swift assertions, which change its speed independently of optimization.
struct SpeechBenchmarkBuild: Codable, Sendable {
    let swiftAssertionsEnabled: Bool

    static var current: Self {
        var assertionsEnabled = false
        // The side effect only describes this build; it never controls app behavior.
        assert({ assertionsEnabled = true; return true }())
        return Self(swiftAssertionsEnabled: assertionsEnabled)
    }
}

/// Chunk delivery in monotonic seconds. Potential underflow simulates playback from the first
/// chunk with no prebuffer; it does not measure audible glitches.
struct SpeechStreamMetrics {
    struct Report: Codable, Sendable {
        let samples: Int
        let chunks: Int
        let audioSeconds: Double
        let generationSeconds: Double
        let realTimeFactor: Double?
        let firstChunkSeconds: Double?
        let maxChunkGapSeconds: Double
        let p95ChunkGapSeconds: Double
        let potentialUnderflowCount: Int
        let potentialUnderflowSeconds: Double
    }

    private let started: Double
    private let sampleRate: Double
    private var firstArrival: Double?
    private var lastArrival: Double?
    private var playbackDeadline: Double?
    private var gaps: [Double] = []
    private var sampleCount = 0
    private var chunkCount = 0
    private var underflows = 0
    private var underflowSeconds = 0.0

    init(started: Double, sampleRate: Double = 24_000) {
        precondition(started.isFinite && sampleRate.isFinite && sampleRate > 0)
        self.started = started
        self.sampleRate = sampleRate
    }

    /// Empty chunks and invalid/non-monotonic observations do not change the measurement.
    @discardableResult
    mutating func record(samples: Int, at time: Double) -> Bool {
        guard samples > 0, time.isFinite, time >= started,
              time >= (lastArrival ?? started) else { return false }
        if let lastArrival { gaps.append(time - lastArrival) }
        if let deadline = playbackDeadline, time - deadline > 0.000_001 {
            underflows += 1
            underflowSeconds += time - deadline
        }
        playbackDeadline = max(time, playbackDeadline ?? time) + Double(samples) / sampleRate
        firstArrival = firstArrival ?? time
        lastArrival = time
        sampleCount += samples
        chunkCount += 1
        return true
    }

    func report(finished: Double) -> Report {
        let end = finished.isFinite ? max(started, lastArrival ?? started, finished) : (lastArrival ?? started)
        let elapsed = end - started
        let audio = Double(sampleCount) / sampleRate
        let sorted = gaps.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        return Report(samples: sampleCount, chunks: chunkCount, audioSeconds: audio,
                      generationSeconds: elapsed, realTimeFactor: audio > 0 ? elapsed / audio : nil,
                      firstChunkSeconds: firstArrival.map { $0 - started },
                      maxChunkGapSeconds: sorted.last ?? 0, p95ChunkGapSeconds: p95,
                      potentialUnderflowCount: underflows, potentialUnderflowSeconds: underflowSeconds)
    }
}
#endif

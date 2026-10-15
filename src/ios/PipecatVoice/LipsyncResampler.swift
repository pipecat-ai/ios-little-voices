import Foundation

/// Streams Phonon's 24 kHz audio to the analyzer's 16 kHz with a windowed-sinc low-pass.
/// Output sample k is centered on input time 1.5k, so analysis offsets need no delay
/// correction to line up with playback.
struct LipsyncResampler {
    static let inputRate = 24_000.0
    /// Input samples either side of each output sample.
    private static let halfWidth = 24
    private static let cutoffHz = 7_000.0
    /// Kernels for output positions on an input sample and halfway between two.
    private static let kernels: [[Float]] = [0.0, 0.5].map { fraction in
        let cutoff = cutoffHz / inputRate
        let edge = Double(halfWidth + 1)
        let taps = (-halfWidth...(halfWidth + 1)).map { index -> Double in
            let t = Double(index) - fraction
            let x = 2 * cutoff * t
            let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            let blackman = 0.42 + 0.5 * cos(Double.pi * t / edge) + 0.08 * cos(2 * Double.pi * t / edge)
            return sinc * max(blackman, 0)
        }
        let sum = taps.reduce(0, +)
        return taps.map { Float($0 / sum) }
    }

    /// Input not yet consumed; index 0 is absolute input sample `base`.
    private var input = [Float](repeating: 0, count: halfWidth)
    private var base = -halfWidth
    private var received = 0
    private var produced = 0

    mutating func reset() { self = LipsyncResampler() }

    /// Resample the next input chunk; a few output samples wait for the kernel's look-ahead.
    mutating func process(_ samples: [Float]) -> [Float] {
        input += samples
        received += samples.count
        return drain(limit: received - Self.halfWidth - 1)
    }

    /// Emit the remaining output for everything received, treating later input as silence.
    mutating func flush() -> [Float] {
        input += [Float](repeating: 0, count: Self.halfWidth + 2)
        return drain(limit: received - 1)
    }

    /// Produce outputs whose center lies at or before input index `limit`.
    private mutating func drain(limit: Int) -> [Float] {
        var output: [Float] = []
        while true {
            let numerator = 3 * produced  // center = 1.5 * produced input samples
            let center = numerator / 2
            guard center <= limit, center + Self.halfWidth + 1 - base < input.count else { break }
            let kernel = Self.kernels[numerator % 2]
            let first = center - Self.halfWidth - base
            var sum: Float = 0
            for j in 0..<kernel.count { sum += input[first + j] * kernel[j] }
            output.append(sum)
            produced += 1
        }
        // Keep the left context the next output needs.
        let keepFrom = (3 * produced) / 2 - Self.halfWidth
        if keepFrom > base {
            input.removeFirst(keepFrom - base)
            base = keepFrom
        }
        return output
    }
}

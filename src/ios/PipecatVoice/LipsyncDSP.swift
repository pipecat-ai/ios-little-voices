// Ported from pipecat-visemes (server/lipsync/dsp.py), BSD 2-Clause, Copyright (c) 2026 Daily.
// Each routine mirrors the NumPy original, including which steps run in single
// precision, so the Swift analyzer reproduces the Python reference's output.
import Accelerate
import Foundation

/// DSP primitives for formant-based lipsync at a fixed 16 kHz analysis rate.
enum LipsyncDSP {
    static let sampleRate = 16_000
    /// 25 ms analysis frame and 20 ms hop.
    static let frameSize = 400
    static let hopSize = 320
    /// The LPC frame shares the 25 ms frame; the NCC pitch frame is 40 ms, centered on the same hop.
    static let lpcFrameSize = 400
    static let pitchFrameSize = 640
    static let preEmphasis: Float = 0.97
    static let lpcOrder = 16

    static let formantMinHz: Float = 200
    static let formantMaxHz: Float = 3500
    static let formantMaxBandwidthHz: Float = 500
    static let f1Band: (Double, Double) = (200, 1000)
    static let f2Band: (Double, Double) = (650, 2600)
    static let f3Band: (Double, Double) = (1800, 3500)
    static let slotNominalHz: [Double] = [550, 1500, 2500]
    static let slotPriorWeights: [Double] = [0, 1, 1]
    static let f2MinAboveF1Hz: Double = 150
    static let f3MinAboveF2Hz: Double = 200
    static let f1BroadMaxBandwidthHz: Double = 800
    static let f2BroadMaxBandwidthHz: Double = 1000
    static let f2LowRootMinHz: Double = 500

    static let pitchMinHz = 60
    static let pitchMaxHz = 400
    static let nccVoicedThreshold = 0.6
    static let nccOctaveGuard = 0.85
    static let epsilon = 1e-9
    static let pitchLagMin = sampleRate / pitchMaxHz
    static let pitchLagMax = sampleRate / pitchMinHz
    static let autocorrRegularization: Float = 1.0 + 1e-6

    static let spectralFFTSize = 512
    static let lowBandBins = Int(500.0 / (Double(sampleRate) / Double(spectralFFTSize)))

    struct FormantEstimate {
        var f1 = 0.0, f2 = 0.0, f3 = 0.0
        var f2Bandwidth = 0.0
        var f1Broad = 0.0
        var f2Broad = 0.0
        var f2Low = 0.0
    }

    struct PitchEstimate {
        let frequency: Double
        let voiced: Bool
        let clarity: Double
    }

    /// NumPy's `np.hamming(n).astype(np.float32)`.
    static func hamming(_ count: Int) -> [Float] {
        guard count > 1 else { return [1] }
        return (0..<count).map { Float(0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(count - 1))) }
    }

    static func dot(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ count: Int) -> Float {
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(count))
        return result
    }

    /// Levinson-Durbin recursion with the float32 coefficient updates of the original.
    static func levinsonDurbin(_ autocorr: [Float], order: Int) -> (coefficients: [Float], error: Double) {
        var a = [Float](repeating: 0, count: order + 1)
        a[0] = 1
        var err = Double(autocorr[0])
        if err <= 0 { return (a, 0) }
        for i in 1...order {
            var acc = Double(autocorr[i])
            if i > 1 {
                var sum: Float = 0
                for j in 1..<i { sum += a[j] * autocorr[i - j] }
                acc += Double(sum)
            }
            let k = -acc / err
            let k32 = Float(k)
            let previous = a
            for j in 1..<i { a[j] += k32 * previous[i - j] }
            a[i] = k32
            err *= 1 - k * k
            if err <= 0 { return (a, 0) }
        }
        return (a, err)
    }

    /// Autocorrelation LPC with lag-zero regularization; returns coefficients and prediction gain.
    static func lpcCoefficients(_ frame: [Float], order: Int = lpcOrder) -> (coefficients: [Float], predictionGain: Double) {
        let n = frame.count
        var r = [Float](repeating: 0, count: order + 1)
        frame.withUnsafeBufferPointer { x in
            let base = x.baseAddress!
            r[0] = dot(base, base, n) * autocorrRegularization + Float(epsilon)
            for lag in 1...order { r[lag] = dot(base, base + lag, n - lag) }
        }
        let (a, err) = levinsonDurbin(r, order: order)
        return (a, err > 0 ? Double(r[0] / Float(err)) : 0)
    }

    /// `np.roots`: eigenvalues of the companion matrix, solved in double precision and
    /// returned in single precision like NumPy does for float32 coefficients.
    static func polynomialRoots(_ coefficients: [Float]) -> [(real: Float, imag: Float)] {
        var p = coefficients
        while let first = p.first, first == 0 { p.removeFirst() }
        var trailingZeros = 0
        while let last = p.last, last == 0 { p.removeLast(); trailingZeros += 1 }
        let zeros = [(real: Float, imag: Float)](repeating: (0, 0), count: trailingZeros)
        let degree = p.count - 1
        guard degree >= 1 else { return zeros }
        // Column-major companion matrix: first row -p[1:]/p[0], ones on the subdiagonal.
        var matrix = [Double](repeating: 0, count: degree * degree)
        for column in 0..<degree { matrix[column * degree] = Double(-p[column + 1] / p[0]) }
        for row in 1..<degree { matrix[(row - 1) * degree + row] = 1 }
        var n = __LAPACK_int(degree), lda = __LAPACK_int(degree), one = __LAPACK_int(1)
        var wr = [Double](repeating: 0, count: degree), wi = [Double](repeating: 0, count: degree)
        var vl = [Double](repeating: 0, count: 1), vr = [Double](repeating: 0, count: 1)
        var lwork = __LAPACK_int(8 * degree), info = __LAPACK_int(0)
        var work = [Double](repeating: 0, count: Int(lwork))
        "N".withCString { jobvl in
            "N".withCString { jobvr in
                dgeev_(jobvl, jobvr, &n, &matrix, &lda, &wr, &wi, &vl, &one, &vr, &one, &work, &lwork, &info)
            }
        }
        guard info == 0 else { return zeros }
        return (0..<degree).map { (Float(wr[$0]), Float(wi[$0])) } + zeros
    }

    /// Assign candidate (frequency, bandwidth) roots to F1/F2/F3 by band, maximizing filled
    /// slots and then minimizing deviation from the targets plus the nominal-center prior.
    static func assignSlots(_ candidates: [(Double, Double)], targets: [Double]) -> (f: [Double], f2Bandwidth: Double) {
        let bands = [f1Band, f2Band, f3Band]
        let eligible: [[Int?]] = bands.map { band in
            candidates.indices.filter { index in
                let (f, bw) = candidates[index]
                return band.0 <= f && f <= band.1 && bw <= Double(formantMaxBandwidthHz)
            }.map { Optional($0) } + [nil]
        }
        var bestFilled = -1
        var bestDeviation = Double.infinity
        var best = [0.0, 0.0, 0.0]
        var bestBandwidth = 0.0
        for i1 in eligible[0] {
            let f1 = i1.map { candidates[$0].0 } ?? 0
            for i2 in eligible[1] {
                if let i2, i2 == i1 { continue }
                let f2 = i2.map { candidates[$0].0 } ?? 0
                if f1 != 0, f2 != 0, f2 <= f1 + f2MinAboveF1Hz { continue }
                for i3 in eligible[2] {
                    if let i3, i3 == i1 || i3 == i2 { continue }
                    let f3 = i3.map { candidates[$0].0 } ?? 0
                    if f2 != 0, f3 != 0, f3 <= f2 + f3MinAboveF2Hz { continue }
                    let values = [f1, f2, f3]
                    let filled = values.filter { $0 > 0 }.count
                    var deviation = 0.0
                    for slot in 0..<3 where values[slot] > 0 {
                        deviation += abs(values[slot] - targets[slot]) / targets[slot]
                            + slotPriorWeights[slot] * abs(values[slot] - slotNominalHz[slot]) / slotNominalHz[slot]
                    }
                    if filled > bestFilled || (filled == bestFilled && deviation < bestDeviation) {
                        bestFilled = filled
                        bestDeviation = deviation
                        best = values
                        bestBandwidth = i2.map { candidates[$0].1 } ?? 0
                    }
                }
            }
        }
        return (best, bestBandwidth)
    }

    /// F1/F2/F3 from one pre-emphasized, windowed frame's LPC polynomial.
    static func lpcFormants(_ a: [Float], previous: FormantEstimate?) -> FormantEstimate {
        guard a.dropFirst().contains(where: { $0 != 0 }) else { return FormantEstimate() }
        let maxBandwidth = Float(max(f1BroadMaxBandwidthHz, f2BroadMaxBandwidthHz))
        var candidates: [(Double, Double)] = []
        for root in polynomialRoots(a) {
            guard root.imag > 0 else { continue }
            let magnitude = hypotf(root.real, root.imag)
            guard Double(magnitude) > epsilon else { continue }
            let bandwidth = Float(-(Double(sampleRate) / Double.pi)) * logf(magnitude)
            guard bandwidth > 0, bandwidth <= maxBandwidth else { continue }
            let frequency = atan2f(root.imag, root.real) * Float(sampleRate) / Float(2 * Double.pi)
            if formantMinHz <= frequency, frequency <= formantMaxHz {
                candidates.append((Double(frequency), Double(bandwidth)))
            }
        }
        let previousValues: [Double] = previous.map { [$0.f1, $0.f2, $0.f3] } ?? [0, 0, 0]
        let targets: [Double] = (0..<3).map { previousValues[$0] > 0 ? previousValues[$0] : slotNominalHz[$0] }
        let (slots, f2Bandwidth) = assignSlots(candidates, targets: targets)
        let (f1, f2, f3) = (slots[0], slots[1], slots[2])

        var f1Broad = 0.0
        if f1 == 0 {
            let broad = candidates.filter {
                f1Band.0 <= $0.0 && $0.0 <= f1Band.1
                    && Double(formantMaxBandwidthHz) < $0.1 && $0.1 <= f1BroadMaxBandwidthHz
            }.map(\.0)
            if let nearest = broad.min(by: { abs($0 - targets[0]) < abs($1 - targets[0]) }) { f1Broad = nearest }
        }
        let above = (f1 > 0 ? f1 : f1Broad) + f2MinAboveF1Hz
        var f2Broad = 0.0
        if f2 == 0 {
            f2Broad = candidates.filter {
                f2Band.0 <= $0.0 && $0.0 <= f2Band.1 && $0.0 > above
                    && Double(formantMaxBandwidthHz) < $0.1 && $0.1 <= f2BroadMaxBandwidthHz
            }.map(\.0).min() ?? 0
        }
        let f2Low = candidates.filter {
            $0.0 >= f2LowRootMinHz && $0.0 > above && $0.1 <= f2BroadMaxBandwidthHz
        }.map(\.0).min() ?? 0
        return FormantEstimate(f1: f1, f2: f2, f3: f3,
                               f2Bandwidth: f2Bandwidth, f1Broad: f1Broad, f2Broad: f2Broad, f2Low: f2Low)
    }

    /// Pitch by normalized cross-correlation of the raw (unwindowed) frame.
    static func nccPitch(_ frame: [Float]) -> PitchEstimate {
        let n = frame.count
        var mean: Float = 0
        vDSP_meanv(frame, 1, &mean, vDSP_Length(n))
        let x = frame.map { $0 - mean }
        let lagMax = min(pitchLagMax, n - 2 * pitchLagMin)
        let segment = n - lagMax
        var energy = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { energy[i + 1] = energy[i] + Double(x[i] * x[i]) }
        let lagCount = lagMax - pitchLagMin + 1
        var ncc = [Double](repeating: 0, count: lagCount)
        x.withUnsafeBufferPointer { samples in
            let base = samples.baseAddress!
            for j in 0..<lagCount {
                let lag = pitchLagMin + j
                let cross = dot(base + lag, base, segment)
                let lagEnergy = energy[lag + segment] - energy[lag]
                ncc[j] = Double(cross) / (energy[segment] * lagEnergy + epsilon).squareRoot()
            }
        }
        let peak = ncc.max() ?? 0
        if peak <= nccVoicedThreshold { return PitchEstimate(frequency: 0, voiced: false, clarity: max(peak, 0)) }
        // Octave guard: the local maximum inside the first run reaching the guard fraction.
        let first = ncc.firstIndex { $0 >= nccOctaveGuard * peak } ?? 0
        let end = ncc[first...].firstIndex { $0 < nccOctaveGuard * peak } ?? lagCount
        var best = first
        for index in first..<end where ncc[index] > ncc[best] { best = index }
        let clarity = ncc[best]
        var shift = 0.0
        if best > 0, best < lagCount - 1 {
            let (left, right) = (ncc[best - 1], ncc[best + 1])
            let curvature = left - 2 * clarity + right
            if curvature < 0 { shift = 0.5 * (left - right) / curvature }
        }
        let frequency = Double(sampleRate) / (Double(pitchLagMin + best) + shift)
        return PitchEstimate(frequency: frequency, voiced: clarity > nccVoicedThreshold, clarity: clarity)
    }

    /// RMS of the raw frame, in single precision like the original.
    static func rmsEnergy(_ frame: ArraySlice<Float>) -> Double {
        let sum = frame.withUnsafeBufferPointer { dot($0.baseAddress!, $0.baseAddress!, frame.count) }
        return Double((sum / Float(frame.count) + Float(epsilon)).squareRoot())
    }

    /// Power in bins 0...256 of a frame zero-padded to 512 points. vDSP's real FFT doubles
    /// amplitudes, so each bin holds four times the power.
    final class PowerSpectrum {
        private let fft = vDSP.FFT(log2n: 9, radix: .radix2, ofType: DSPSplitComplex.self)!
        private var real = [Float](repeating: 0, count: spectralFFTSize / 2)
        private var imaginary = [Float](repeating: 0, count: spectralFFTSize / 2)
        private var output = [Float](repeating: 0, count: spectralFFTSize / 2)
        private var outputImaginary = [Float](repeating: 0, count: spectralFFTSize / 2)

        func callAsFunction(_ frame: [Float]) -> [Double] {
            var padded = [Float](repeating: 0, count: spectralFFTSize)
            padded.replaceSubrange(0..<frame.count, with: frame)
            let half = spectralFFTSize / 2
            var power = [Double](repeating: 0, count: half + 1)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    // Even samples to the real part, odd to the imaginary part (vDSP's packed real FFT).
                    for i in 0..<half {
                        realPointer[i] = padded[2 * i]
                        imaginaryPointer[i] = padded[2 * i + 1]
                    }
                    output.withUnsafeMutableBufferPointer { outPointer in
                        outputImaginary.withUnsafeMutableBufferPointer { outImaginaryPointer in
                            let input = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                            var out = DSPSplitComplex(realp: outPointer.baseAddress!, imagp: outImaginaryPointer.baseAddress!)
                            fft.forward(input: input, output: &out)
                            // DC and Nyquist are packed into bin 0.
                            power[0] = Double(out.realp[0]) * Double(out.realp[0])
                            power[half] = Double(out.imagp[0]) * Double(out.imagp[0])
                            for k in 1..<half {
                                power[k] = Double(out.realp[k]) * Double(out.realp[k]) + Double(out.imagp[k]) * Double(out.imagp[k])
                            }
                        }
                    }
                }
            }
            return power
        }
    }

    /// Spectral centroid and the fraction of power below 500 Hz of the windowed frame.
    final class NasalSpectrum {
        private let spectrum = PowerSpectrum()

        func features(_ frame: [Float]) -> (centroid: Double, lowRatio: Double) {
            let power = spectrum(frame)
            let binHz = Double(sampleRate) / Double(spectralFFTSize)
            let total = power.reduce(0, +) * 0.25 + epsilon
            var centroid = 0.0
            for k in 0...(spectralFFTSize / 2) { centroid += power[k] * 0.25 * Double(k) * binHz }
            let low = power[0..<lowBandBins].reduce(0, +) * 0.25
            return (centroid / total, low / total)
        }
    }

    /// Streaming P² quantile estimator (Jain & Chlamtac, 1985).
    struct P2Quantile {
        private let quantile: Double
        private var initial: [Double] = []
        private var q: [Double] = []
        private var positions: [Double] = []
        private var desired: [Double] = []
        private let increments: [Double]

        init(_ quantile: Double) {
            self.quantile = quantile
            increments = [0, quantile / 2, quantile, (1 + quantile) / 2, 1]
        }

        var count: Int { q.isEmpty ? initial.count : Int(positions[4]) }

        var value: Double {
            if !q.isEmpty { return q[2] }
            guard !initial.isEmpty else { return 0 }
            let ordered = initial.sorted()
            // Python's round() is round-half-to-even.
            let index = Int((quantile * Double(ordered.count - 1)).rounded(.toNearestOrEven))
            return ordered[index]
        }

        mutating func add(_ value: Double) {
            if initial.count < 5 {
                initial.append(value)
                if initial.count == 5 {
                    q = initial.sorted()
                    positions = [1, 2, 3, 4, 5]
                    let p = quantile
                    desired = [1, 1 + 2 * p, 1 + 4 * p, 3 + 2 * p, 5]
                }
                return
            }
            var k: Int
            if value < q[0] {
                q[0] = value
                k = 0
            } else if value >= q[4] {
                q[4] = value
                k = 3
            } else {
                k = 0
                while value >= q[k + 1] { k += 1 }
            }
            for i in (k + 1)..<5 { positions[i] += 1 }
            for i in 0..<5 { desired[i] += increments[i] }
            for i in 1..<4 {
                var d = desired[i] - positions[i]
                if (d >= 1 && positions[i + 1] - positions[i] > 1) || (d <= -1 && positions[i - 1] - positions[i] < -1) {
                    d = d >= 0 ? 1 : -1
                    var candidate = q[i] + d / (positions[i + 1] - positions[i - 1]) * (
                        (positions[i] - positions[i - 1] + d) * (q[i + 1] - q[i]) / (positions[i + 1] - positions[i])
                            + (positions[i + 1] - positions[i] - d) * (q[i] - q[i - 1]) / (positions[i] - positions[i - 1]))
                    if !(q[i - 1] < candidate && candidate < q[i + 1]) {
                        let j = i + Int(d)
                        candidate = q[i] + d * (q[j] - q[i]) / (positions[j] - positions[i])
                    }
                    q[i] = candidate
                    positions[i] += d
                }
            }
        }
    }

    /// NumPy's `np.median` of a small list.
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

import Foundation

/// Aligns a sentence's phones to its audio as the audio streams in. A hidden semi-Markov model
/// walks the phones in order (silence, each word, an optional pause after it, silence), with a
/// Gaussian over each 20 ms hop's features and a log-normal duration per phone
/// (`LipsyncAlignerModel`). Viterbi decoding of the hops so far leaves the last phone in
/// progress, so later audio can still move boundaries not yet heard. Five decoders cover
/// speaking rates from 0.8 to 1.75 times the model's durations, leaning toward the voice's last.
/// When the aligned phones explain the audio much worse than the best-fitting phones would,
/// the alignment is lost and the timeline falls back to formant analysis.
final class LipsyncAligner {
    /// A phone of a word, or a pause, over hops `start..<end` of the analyzer's grid.
    struct Segment: Equatable, Sendable {
        /// Nil for silence and pauses.
        var phone: LipsyncPhone?
        /// The word it belongs to; a pause belongs to the word before it (-1 before the first).
        var word: Int
        var start: Int
        var end: Int
    }

    /// What a voice carries from one sentence to the next.
    struct Voice: Sendable {
        var cepstralMean = LipsyncAlignerModel.cepstralMean
        var cepstralVariance = LipsyncAlignerModel.cepstralDeviation.map { $0 * $0 }
        var rate: Double?
    }

    /// Emission log-likelihoods are weighed this much against durations.
    private static let emissionWeight = 0.15
    private static let rates: [Double] = [0.8, 1.0, 1.2, 1.45, 1.75]
    /// Log-likelihood cost of a rate 1.2 times away from the voice's last.
    private static let ratePreference = 3.0
    /// Mean per-hop log-likelihood shortfall, over a second of speech, below which the alignment is lost.
    private static let confidenceFloor = -0.65
    private static let confidenceHops = 50
    /// The newest hops are still provisional, so confidence looks behind them.
    private static let provisionalHops = 10
    /// Sentences of more states (phones and pauses), or audio of more hops (20 s), are left to
    /// formant analysis.
    private static let maxStates = 300
    private static let maxHops = 1000

    let words: [LipsyncWord]
    private(set) var voice: Voice
    /// Whether the alignment explains the audio; once lost, it stays lost.
    private(set) var confident = true
    private(set) var finished = false
    var hops: Int { trellises[0].time }

    fileprivate struct State {
        var model: Int
        var phone: LipsyncPhone?
        var word: Int
        var skippable: Bool
        var maxDuration: Int
        /// Log-probabilities of entering and of skipping a skippable state.
        var enter: Double
        var skip: Double
        /// Hops at rate 1; infinite for the silence around the sentence, which costs nothing.
        var meanDuration = Double.infinity
        var sigma = 0.0
    }

    private let states: [State]
    private let features = LipsyncAlignerFeatures()
    /// Each state's emission log-likelihood summed over hops `0..<t`, in row `t % Trellis.ring`.
    private var cumulative: [Double]
    /// Each hop's best emission of any phone, and whether it is speech.
    private var bestEmission: [Double] = []
    private var speech: [Bool] = []
    private var trellises: [Trellis]
    private var rate = 1.0
    /// The newest hop's features, waiting for the next hop's level, and the level before it.
    private var pending: [Double]?
    private var levelBefore: Double?
    private let modelMeans = LipsyncAlignerModel.means
    private let modelInverseVariances = LipsyncAlignerModel.variances.map { $0.map { 1 / $0 } }
    private let modelNorms = LipsyncAlignerModel.variances.map { v in -0.5 * v.reduce(0) { $0 + log(2 * Double.pi * $1) } }

    /// Nil when there is nothing to align, or too much.
    init?(words: [LipsyncWord], voice: Voice) {
        let names = LipsyncAlignerModel.names
        let index = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        var states: [State] = []
        func add(_ name: String, phone: LipsyncPhone?, word: Int, pause: LipsyncWord.Pause = .none) {
            // How likely a skippable state is entered rather than skipped; its duration's key.
            var key = name, enter = 1.0, skip = 0.0
            switch (name, pause) {
            case ("SIL", _): (enter, skip) = (0.5, 0.5)
            case ("SP", .comma): (key, enter, skip) = ("SP,", 0.75, 0.25)
            case ("SP", .stop): (key, enter, skip) = ("SP.", 0.9, 0.1)
            case ("SP", .none): (enter, skip) = (0.12, 0.88)
            default: break
            }
            var state = State(model: index[name] ?? 0, phone: phone, word: word, skippable: skip > 0,
                              maxDuration: name == "SIL" ? 150 : (name == "SP" ? 50 : 30), enter: log(enter),
                              skip: log(skip))
            if name != "SIL" {
                let (mean, sigma) = LipsyncAlignerModel.durations[key] ?? (4, 0.5)
                // Unstressed full vowels are shorter; AX, AXR and IX are trained short.
                let reduced = phone.map { $0.isVowel && $0.stress == 0 && !["AX", "AXR", "IX"].contains(name) } ?? false
                state.meanDuration = reduced ? mean * 0.75 : mean
                state.sigma = sigma
            }
            states.append(state)
        }
        add("SIL", phone: nil, word: -1)
        for (w, word) in words.enumerated() {
            for phone in word.phones { add(Self.modelName(phone), phone: phone, word: w) }
            if w < words.count - 1 { add("SP", phone: nil, word: w, pause: word.pause) }
        }
        add("SIL", phone: nil, word: words.count)
        guard states.contains(where: { $0.phone != nil }), states.count <= Self.maxStates else { return nil }
        self.states = states
        self.words = words
        self.voice = voice
        cumulative = [Double](repeating: 0, count: Trellis.ring * states.count)
        trellises = Self.rates.map { Trellis(states: states, rate: $0) }
    }

    /// Unstressed AH, ER and IH have their own models.
    private static func modelName(_ phone: LipsyncPhone) -> String {
        guard phone.stress == 0 else { return phone.symbol.rawValue }
        switch phone.symbol {
        case .ah: return "AX"
        case .er: return "AXR"
        case .ih: return "IX"
        default: return phone.symbol.rawValue
        }
    }

    /// Feed 16 kHz samples of the sentence (ignored once the alignment is lost).
    func process(_ samples: [Float]) {
        guard !finished, confident else { return }
        for hop in features.process(samples) { push(hop) }
    }

    /// The audio is complete: decode to the end of the sentence, and keep the voice's rate if it held.
    func finish() {
        guard !finished else { return }
        if confident {
            for hop in features.flush() { push(hop) }
            if var last = pending {
                pending = nil
                last[last.count - 1] = 0
                step(last)
            }
        }
        finished = true
        _ = segments()
        if confident { voice.rate = rate }
    }

    /// Normalize a hop's cepstra (learning from loud hops), then step the hop before it, whose
    /// level slope (half the change across it) needed this hop's level.
    private func push(_ hop: LipsyncAlignerFeatures.Hop) {
        if hop.level > 0.5 {
            let alpha = 1.0 / 500
            for i in 0..<12 {
                let diff = hop.cepstra[i] - voice.cepstralMean[i]
                voice.cepstralMean[i] += alpha * diff
                voice.cepstralVariance[i] += alpha * (diff * diff - voice.cepstralVariance[i])
            }
        }
        let cepstra = (0..<12).map { (hop.cepstra[$0] - voice.cepstralMean[$0]) / voice.cepstralVariance[$0].squareRoot() }
        if var previous = pending {
            previous[previous.count - 1] = levelBefore.map { (hop.level - $0) / 2 } ?? 0
            levelBefore = previous[0]
            step(previous)
        }
        pending = [hop.level, hop.zeroCrossings * 4] + cepstra + [0]
    }

    private func step(_ feature: [Double]) {
        guard hops < Self.maxHops else {
            confident = false
            return
        }
        let perModel = modelMeans.indices.map { m in
            let mean = modelMeans[m], inverse = modelInverseVariances[m]
            var sum = 0.0
            for i in feature.indices {
                let d = feature[i] - mean[i]
                sum += d * d * inverse[i]
            }
            return Self.emissionWeight * (modelNorms[m] - 0.5 * sum)
        }
        bestEmission.append(perModel.max() ?? 0)
        speech.append(feature[0] > 0.5)
        let S = states.count, t = hops + 1
        let previous = ((t - 1) % Trellis.ring) * S, now = (t % Trellis.ring) * S
        for s in 0..<S { cumulative[now + s] = cumulative[previous + s] + perModel[states[s].model] }
        for index in trellises.indices { trellises[index].step(cumulative: cumulative) }
    }

    /// The likeliest alignment of the hops so far (once finished, of the whole sentence), and with
    /// `predicting`, that many hops beyond them: the phone in progress for the rest of its mean
    /// duration, then the next phones at theirs, pausing only where punctuation makes it likely.
    /// The prediction keeps the mouth up with audio that arrives just in time.
    func segments(predicting extra: Int = 0) -> [Segment] {
        guard hops > 0 else { return [] }
        var best: (score: Double, path: [(state: Int, start: Int, end: Int)], rate: Double)?
        for (k, trellis) in trellises.enumerated() {
            guard let decoded = trellis.decode(cumulative: cumulative, final: finished) else { continue }
            var score = decoded.score
            if let previous = voice.rate { score -= Self.ratePreference * abs(log(Self.rates[k] / previous)) / log(1.2) }
            if best == nil || score > best!.score { best = (score, decoded.path, Self.rates[k]) }
        }
        guard let best else { return [] }
        rate = best.rate
        updateConfidence(best.path)
        var path = best.path
        if extra > 0 && !finished, let last = path.last {
            let horizon = hops + extra
            let mean = states[last.state].meanDuration
            var t = min(max(mean.isFinite ? last.start + Int((mean * rate).rounded(.up)) : horizon, hops + 1), horizon)
            path[path.count - 1].end = t
            for s in (last.state + 1)..<states.count where t < horizon && !(states[s].skippable && states[s].enter < log(0.5)) {
                let length = states[s].meanDuration.isFinite ? max(Int((states[s].meanDuration * rate).rounded()), 1) : extra
                path.append((s, t, min(t + length, horizon)))
                t = min(t + length, horizon)
            }
        }
        return path.map { Segment(phone: states[$0.state].phone, word: states[$0.state].word, start: $0.start, end: $0.end) }
    }

    /// Mean shortfall of each speech hop's aligned emission against its best, over the last
    /// `confidenceHops` speech hops behind the provisional ones.
    private func updateConfidence(_ path: [(state: Int, start: Int, end: Int)]) {
        let S = states.count, ring = Trellis.ring
        let newest = finished ? hops : hops - Self.provisionalHops
        let oldest = max(hops - ring + 1, 0)
        var shortfall: [Double] = []
        for segment in path.reversed() where segment.start < newest && shortfall.count < Self.confidenceHops {
            for t in stride(from: min(segment.end, newest) - 1, through: max(segment.start, oldest), by: -1)
            where speech[t] && shortfall.count < Self.confidenceHops {
                let emission = cumulative[((t + 1) % ring) * S + segment.state] - cumulative[(t % ring) * S + segment.state]
                shortfall.append(emission - bestEmission[t])
            }
        }
        if shortfall.count == Self.confidenceHops, shortfall.reduce(0, +) / Double(shortfall.count) < Self.confidenceFloor {
            confident = false
        }
    }
}

/// One speaking rate's semi-Markov Viterbi trellis. Scores are kept for the last `ring` hops
/// (longer than any state lasts), the choices behind them for every hop.
private struct Trellis {
    static let ring = 160

    private let states: [LipsyncAligner.State]
    private let S: Int
    /// log P(duration = d) and log P(duration ≥ d), at index d.
    private let logDurations: [[Double]]
    private let survivals: [[Double]]
    /// The best score of each state ending at the current hop.
    private var delta: [Double]
    /// Row `t % ring`: the best score of a path ready to start each state at hop t.
    private var entry: [Double]
    /// Row t: each state's best duration ending at hop t, and the state before each starting at hop t.
    private var durations: [UInt8]
    private var source: [Int16]
    private(set) var time = 0

    fileprivate init(states: [LipsyncAligner.State], rate: Double) {
        self.states = states
        S = states.count
        logDurations = states.map { state in
            guard state.meanDuration.isFinite else { return [Double](repeating: 0, count: state.maxDuration + 1) }
            // A log-normal with this mean, normalized over 1...maxDuration.
            let mean = state.meanDuration * rate, sigma = state.sigma
            let mu = log(mean) - sigma * sigma / 2
            let values = [-Double.infinity] + (1...state.maxDuration).map { d in
                -log(Double(d) * sigma * (2 * Double.pi).squareRoot()) - pow(log(Double(d)) - mu, 2) / (2 * sigma * sigma)
            }
            let peak = values.max() ?? 0
            let total = log(values.dropFirst().reduce(0) { $0 + exp($1 - peak) }) + peak
            return values.map { $0 - total }
        }
        survivals = zip(states, logDurations).map { state, logDuration in
            guard state.meanDuration.isFinite else { return logDuration }
            var tail = [Double](repeating: -Double.infinity, count: logDuration.count + 1)
            for d in stride(from: logDuration.count - 1, through: 1, by: -1) {
                let high = max(tail[d + 1], logDuration[d])
                tail[d] = high == -Double.infinity ? high : high + log(exp(tail[d + 1] - high) + exp(logDuration[d] - high))
            }
            return Array(tail.prefix(logDuration.count))
        }
        delta = [Double](repeating: -Double.infinity, count: S)
        durations = [UInt8](repeating: 0, count: S)
        // The start: the first state, or later ones when the first are skipped.
        entry = [Double](repeating: -Double.infinity, count: Self.ring * S)
        var accumulated = 0.0
        for s in 0..<S {
            entry[s] = accumulated + states[s].enter
            if !states[s].skippable { break }
            accumulated += states[s].skip
        }
        source = [Int16](repeating: -2, count: S)
    }

    mutating func step(cumulative: [Double]) {
        time += 1
        let t = time, R = Self.ring
        let now = (t % R) * S
        var best = [Double](repeating: -Double.infinity, count: S)
        var chosen = [UInt8](repeating: 0, count: S)
        for s in 0..<S {
            let logDuration = logDurations[s]
            let end = cumulative[now + s]
            var top = -Double.infinity, duration = 0
            for d in 1...min(t, states[s].maxDuration) {
                let start = ((t - d) % R) * S + s
                let score = entry[start] + logDuration[d] + (end - cumulative[start])
                if score > top {
                    top = score
                    duration = d
                }
            }
            best[s] = top
            chosen[s] = UInt8(duration)
        }
        delta = best
        durations += chosen
        // Entries at hop t: from the previous state ending here, or across skipped states.
        var sources = [Int16](repeating: -1, count: S)
        entry[now] = -Double.infinity
        for s in 1..<S {
            var top = best[s - 1], from = s - 1
            var j = s - 1, accumulated = 0.0
            while j >= 1 && states[j].skippable {
                accumulated += states[j].skip
                if best[j - 1] + accumulated > top {
                    top = best[j - 1] + accumulated
                    from = j - 1
                }
                j -= 1
            }
            entry[now + s] = top + states[s].enter
            sources[s] = Int16(from)
        }
        source += sources
    }

    /// The best path to the current hop and its score: ending the sentence when `final`,
    /// otherwise with its last state possibly still in progress.
    func decode(cumulative: [Double], final: Bool) -> (score: Double, path: [(state: Int, start: Int, end: Int)])? {
        let T = time, R = Self.ring
        guard T > 0 else { return nil }
        var top = -Double.infinity, state = -1, duration = 0
        if final {
            var accumulated = 0.0
            for s in stride(from: S - 1, through: 0, by: -1) {
                if delta[s] + accumulated > top {
                    top = delta[s] + accumulated
                    state = s
                }
                if !states[s].skippable { break }
                accumulated += states[s].skip
            }
        } else {
            let end = (T % R) * S
            for s in 0..<S {
                for d in 1...min(T, states[s].maxDuration) {
                    let start = ((T - d) % R) * S + s
                    let score = entry[start] + survivals[s][d] + (cumulative[end + s] - cumulative[start])
                    if score > top {
                        top = score
                        state = s
                        duration = d
                    }
                }
            }
        }
        guard state >= 0, top > -Double.infinity else { return nil }
        if final { return (top, trace(state: state, end: T)) }
        let start = T - duration
        let previous = Int(source[start * S + state])
        return (top, (previous >= 0 ? trace(state: previous, end: start) : []) + [(state, start, T)])
    }

    /// The path back from `state` ending at hop `end`.
    private func trace(state: Int, end: Int) -> [(state: Int, start: Int, end: Int)] {
        var path: [(state: Int, start: Int, end: Int)] = []
        var s = state, t = end
        while t > 0 && s >= 0 {
            let d = Int(durations[t * S + s])
            guard d > 0 else { break }
            path.append((s, t - d, t))
            let from = Int(source[(t - d) * S + s])
            if from == -2 { break }
            s = from
            t -= d
        }
        return path.reversed()
    }
}

/// Each hop's alignment features from the 16 kHz stream, on the analyzer's hop grid: loudness
/// against a decaying peak, zero-crossing rate, and mel cepstra c1…c12 of the pre-emphasized,
/// Hamming-windowed frame.
final class LipsyncAlignerFeatures {
    struct Hop {
        var level: Double
        var zeroCrossings: Double
        var cepstra: [Double]
    }

    /// The loudness peak starts at a typical speech peak (−14 dBFS) and decays 0.2 dB a second.
    private static let referenceStart = pow(10, -14.0 / 20)
    private static let referenceDecay = 0.9995
    private static let melBands = 20
    private static let window = LipsyncDSP.hamming(LipsyncDSP.frameSize)
    /// Triangular mel filters from 100 Hz to 7 kHz over the spectrum's bins.
    private static let filterbank: [[Double]] = {
        func mel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
        func hz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }
        let low = mel(100), high = mel(7000)
        let binHz = Double(LipsyncDSP.sampleRate) / Double(LipsyncDSP.spectralFFTSize)
        let edges = (0...(melBands + 1)).map { hz(low + (high - low) * Double($0) / Double(melBands + 1)) / binHz }
        return (0..<melBands).map { m in
            (0...(LipsyncDSP.spectralFFTSize / 2)).map { k in
                max(0, min((Double(k) - edges[m]) / (edges[m + 1] - edges[m]),
                           (edges[m + 2] - Double(k)) / (edges[m + 2] - edges[m + 1])))
            }
        }
    }()
    private static let dct: [[Double]] = (1...12).map { i in
        (0..<melBands).map { j in cos(Double.pi * Double(i) * (Double(j) + 0.5) / Double(melBands)) }
    }

    private let spectrum = LipsyncDSP.PowerSpectrum()
    private var buffer: [Float] = []
    private var previousSample: Float = 0
    private var reference = referenceStart

    func process(_ samples: [Float]) -> [Hop] {
        buffer += samples
        return drain()
    }

    /// The last frames, completed with silence as the analyzer completes them.
    func flush() -> [Hop] {
        buffer += [Float](repeating: 0, count: (LipsyncDSP.pitchFrameSize - LipsyncDSP.frameSize) / 2)
        return drain()
    }

    private func drain() -> [Hop] {
        var hops: [Hop] = []
        var start = 0
        while buffer.count - start >= LipsyncDSP.frameSize {
            let frame = Array(buffer[start..<(start + LipsyncDSP.frameSize)])
            hops.append(measure(frame, previous: start > 0 ? buffer[start - 1] : previousSample))
            start += LipsyncDSP.hopSize
        }
        if start > 0 {
            previousSample = buffer[start - 1]
            buffer.removeFirst(start)
        }
        return hops
    }

    private func measure(_ frame: [Float], previous: Float) -> Hop {
        let rms = LipsyncDSP.rmsEnergy(frame[...])
        reference = max(reference * Self.referenceDecay, rms)
        let signs = frame.map { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }
        let crossings = (1..<frame.count).filter { signs[$0] != signs[$0 - 1] }
        let windowed = frame.indices.map { i in
            (frame[i] - LipsyncDSP.preEmphasis * (i > 0 ? frame[i - 1] : previous)) * Self.window[i]
        }
        let power = spectrum(windowed)
        let logMel = Self.filterbank.map { band in
            log(band.indices.reduce(0) { band[$1] > 0 ? $0 + band[$1] * (0.25 * power[$1]) : $0 } + 1e-10)
        }
        return Hop(level: min(max(1 + 20 * log10(rms / reference + 1e-9) / 60, 0), 1),
                   zeroCrossings: Double(crossings.count) / Double(frame.count - 1),
                   cepstra: Self.dct.map { row in zip(row, logMel).reduce(0) { $0 + $1.0 * $1.1 } })
    }
}

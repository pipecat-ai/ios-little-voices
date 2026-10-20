// Pose sampling after pipecat-visemes (client/src/lipsync/feed.ts), BSD 2-Clause,
// Copyright (c) 2026 Daily.
import Foundation
import Observation

/// Analyzes Phonon's audio as it is scheduled for playback and serves the mouth pose at the
/// playback position, on the player's own clock. With the sentence's text (`expect(text:)`) the
/// pose comes from its phones, aligned as the audio streams in; without text, or once the
/// alignment is lost, from the formant analyzer. Either way the hop's loudness gates the opening.
/// Sampling follows pipecat-visemes' web client: interpolate between keyframes, blend in from
/// rest, then hold and ease back to rest after the last keyframe.
@MainActor @Observable
final class LipsyncTimeline {
    struct Pose: Equatable, Sendable {
        var openness: Double
        var width: Double
        var rounding: Double

        func blended(to other: Pose, by t: Double) -> Pose {
            Pose(openness: openness + (other.openness - openness) * t,
                 width: width + (other.width - width) * t,
                 rounding: rounding + (other.rounding - rounding) * t)
        }
    }

    /// The analyzer's silence rest: lips nearly closed.
    nonisolated static let rest = Pose(openness: 0.15, width: 0.35, rounding: 0.1)
    /// A pose gives way to rest as its hop's energy (the analyzer's, against the voice's running
    /// peak) falls from `voicedEnergy` (about −10 dB) to `quietEnergy` (about −21 dB).
    nonisolated static let quietEnergy = 0.25
    nonisolated static let voicedEnergy = 0.6
    /// A text pose, whose sounds are known, holds down to quieter hops (about −16 to −31 dB), such as
    /// the words a sentence trails off on.
    nonisolated static let shapeQuietEnergy = 0.1
    nonisolated static let shapeVoicedEnergy = 0.4
    /// Keyframes and closures lead their audio: lips shape a sound just before it is heard.
    static let leadSeconds = 0.02
    /// The lips start to part this long before an utterance's first keyframe.
    static let prerollSeconds = 0.05
    /// An utterance's first sound is its first 10 ms block (at 24 kHz) reaching −40 dBFS: above
    /// Phonon's leading near-silence and its click, below any speech.
    private static let onsetLevel: Float = 0.01
    private static let onsetBlock = 240
    private static let holdSeconds = 0.25
    private static let easeSeconds = 0.3
    /// Closures ease the lips shut over this long at each edge.
    private static let closureRampSeconds = 0.03
    private static let closedOpenness = 0.02
    /// The widest closed lips: spread lips part the mouth (`LipSyncMapping.spreadOpening`).
    private static let closedWidth = 0.55
    /// Aligned M, B and P lead their audio by less than keyframes, so a short vowel before one shows.
    private static let closureLeadSeconds = 0.01

    /// Whether the mouth may still move; the view pauses its animation otherwise.
    private(set) var isAnimating = false

    /// The current or last utterance's alignment.
    @ObservationIgnored private(set) var alignment: LipsyncAnalysis.Alignment?

    @ObservationIgnored private let analysis: LipsyncAnalysis
    /// Identifies the current utterance, so results for a stopped one are dropped.
    @ObservationIgnored private var generation = 0
    /// Where each scheduled chunk starts in utterance audio and on the player's clock (seconds).
    @ObservationIgnored private var segments: [(audio: Double, player: Double)] = []
    @ObservationIgnored private var scheduledAudio = 0.0
    /// Where the utterance's first sound starts in its audio, once scheduled.
    @ObservationIgnored private var onset: Double?
    /// The formant track.
    @ObservationIgnored private var keyframes: [(time: Double, pose: Pose)] = []
    @ObservationIgnored private var closures: [(start: Double, end: Double)] = []
    @ObservationIgnored private var cursor = 0
    /// The text track: a keyframe for every hop, and the bilabials' closures.
    @ObservationIgnored private var textKeyframes: [(time: Double, pose: Pose)] = []
    @ObservationIgnored private var textClosures: [(start: Double, end: Double)] = []
    @ObservationIgnored private var textCursor = 0
    @ObservationIgnored private var usesText = false
    @ObservationIgnored private var expectedText: String?
    @ObservationIgnored private var inUtterance = false
    @ObservationIgnored private var restTask: Task<Void, Never>?
    #if DEBUG
    /// The character, for `--lipsync-trace`; naming the timeline starts its audio file afresh.
    @ObservationIgnored var traceLabel = "" {
        didSet {
            if Self.tracing, traceLabel != oldValue { try? FileManager.default.removeItem(at: traceAudioURL) }
        }
    }
    /// The player time of the last pose sampled, for `--lipsync-trace`.
    @ObservationIgnored private(set) var lastSampleTime: Double?
    static let tracing = ProcessInfo.processInfo.arguments.contains("--lipsync-trace")
    /// `--lipsync-formant-only`: still align the text, for the trace, but draw formants.
    static let formantOnly = ProcessInfo.processInfo.arguments.contains("--lipsync-formant-only")
    #endif

    /// `lexicon` is loaded off the main actor before the first sentence needs it.
    init(lexicon: @escaping @Sendable () -> LipsyncLexicon? = { LipsyncLexicon.bundled }) {
        analysis = LipsyncAnalysis(lexicon: lexicon)
    }

    /// The sentence the next utterance speaks, before its first chunk is scheduled.
    func expect(text: String?) {
        expectedText = text
    }

    /// Analyze `samples` (24 kHz mono) that will start playing at `playerTime` seconds.
    func schedule(_ samples: [Float], at playerTime: Double) {
        guard !samples.isEmpty else { return }
        if !inUtterance {
            generation += 1
            clearTrack()
            inUtterance = true
            restTask?.cancel()
            isAnimating = true
            usesText = expectedText != nil
            analysis.begin(text: expectedText)
            #if DEBUG
            if Self.formantOnly { usesText = false }
            if Self.tracing, let text = expectedText {
                print(String(format: "LIPSYNC_TEXT: %@ %.6f %@", traceLabel, playerTime, text))
            }
            #endif
            expectedText = nil
        }
        segments.append((scheduledAudio, playerTime))
        #if DEBUG
        if Self.tracing { traceChunk(samples, at: playerTime) }
        #endif
        if onset == nil, let index = Self.firstSound(in: samples) {
            onset = scheduledAudio + Double(index) / LipsyncResampler.inputRate
        }
        scheduledAudio += Double(samples.count) / LipsyncResampler.inputRate
        analysis.analyze(samples, deliver: recorder())
    }

    /// Playback drained: analyze the tail, then let the mouth settle before pausing.
    func finish() {
        guard inUtterance else { return }
        analysis.analyze(nil, deliver: recorder())
        inUtterance = false
        let settle = Self.holdSeconds + 5 * Self.easeSeconds
        restTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(settle))
            guard !Task.isCancelled, let self, !self.inUtterance else { return }
            self.isAnimating = false
        }
    }

    /// Playback was interrupted: drop the utterance and rest at once.
    func cancel() {
        generation += 1
        analysis.reset()
        inUtterance = false
        expectedText = nil
        restTask?.cancel()
        clearTrack()
        isAnimating = false
    }

    /// Returns once everything scheduled so far has been analyzed and recorded.
    func analyzed() async {
        await analysis.drained()
    }

    /// The pose at `playerTime` seconds on the player's clock, or rest without playback.
    func pose(at playerTime: Double?) -> Pose {
        #if DEBUG
        lastSampleTime = playerTime
        #endif
        guard isAnimating, let time = playerTime else { return Self.rest }
        if usesText, let onset {
            // Like formant keyframes, text keyframes start at the first sound.
            let first = max(Int(((onset - Self.hopOffset(0)) / FormantLipsyncAnalyzer.hopSeconds).rounded(.up)), 0)
            if first < textKeyframes.count {
                return Self.sample(textKeyframes[first...], closures: textClosures, cursor: &textCursor, at: time)
            }
        }
        return Self.sample(keyframes[...], closures: closures, cursor: &cursor, at: time)
    }

    private static func sample(_ keyframes: ArraySlice<(time: Double, pose: Pose)>,
                               closures: [(start: Double, end: Double)], cursor: inout Int, at time: Double) -> Pose {
        guard let first = keyframes.first else { return rest }
        var pose: Pose
        if time < first.time {
            let until = first.time - time
            if until > prerollSeconds { return rest }
            pose = rest.blended(to: first.pose, by: 1 - until / prerollSeconds)
        } else {
            let start = keyframes.startIndex, end = keyframes.endIndex
            cursor = min(max(cursor, start), end - 1)
            while cursor + 1 < end && keyframes[cursor + 1].time <= time { cursor += 1 }
            while cursor > start && keyframes[cursor].time > time { cursor -= 1 }
            let current = keyframes[cursor]
            if cursor + 1 < end {
                let next = keyframes[cursor + 1]
                let span = next.time - current.time
                pose = current.pose.blended(to: next.pose, by: span > 0 ? min(1, (time - current.time) / span) : 1)
            } else {
                let over = time - current.time
                pose = over <= holdSeconds ? current.pose
                    : current.pose.blended(to: rest, by: 1 - exp(-(over - holdSeconds) / easeSeconds))
            }
        }
        for closure in closures where closure.start - closureRampSeconds < time && time < closure.end + closureRampSeconds {
            let entering = (time - (closure.start - closureRampSeconds)) / closureRampSeconds
            let leaving = (closure.end + closureRampSeconds - time) / closureRampSeconds
            let amount = min(1, entering, leaving)
            pose.openness += (min(pose.openness, closedOpenness) - pose.openness) * amount
            pose.width += (min(pose.width, closedWidth) - pose.width) * amount
        }
        return pose
    }

    private func recorder() -> @MainActor @Sendable (LipsyncAnalysis.Output) -> Void {
        let generation = generation
        return { [weak self] output in
            guard let self, self.generation == generation else { return }
            record(output.result)
            if let text = output.text { record(text) }
        }
    }

    /// Place analyzer output from the utterance's first sound on the player's clock. Results only
    /// cover audio already scheduled, so the onset is known by the time they arrive.
    func record(_ result: FormantLipsyncAnalyzer.Result) {
        #if DEBUG
        if Self.tracing { traceResult(result) }
        #endif
        guard let onset else { return }
        for keyframe in result.keyframes where keyframe.offset >= onset {
            keyframes.append((playerTime(forAudio: keyframe.offset) - Self.leadSeconds, Self.pose(keyframe)))
        }
        for event in result.events where event.kind == .closure && event.offset >= onset {
            let start = playerTime(forAudio: event.offset) - Self.leadSeconds
            closures.append((start, start + event.duration))
        }
    }

    /// Replace the text track from the update's first hop on, or drop it once the alignment is lost.
    private func record(_ update: LipsyncAnalysis.TextUpdate) {
        alignment = update.alignment
        #if DEBUG
        if Self.tracing, update.alignment.finished { traceAlignment(update.alignment) }
        #endif
        guard usesText else { return }
        guard update.alignment.confident else {
            usesText = false
            textKeyframes = []
            textClosures = []
            return
        }
        textKeyframes.removeLast(textKeyframes.count - min(update.firstHop, textKeyframes.count))
        for (index, pose) in update.poses.enumerated() {
            textKeyframes.append((playerTime(forAudio: Self.hopOffset(update.firstHop + index)) - Self.leadSeconds, pose))
        }
        textClosures = update.closures.map { closure in
            (playerTime(forAudio: Self.hopBoundary(closure.start)) - Self.closureLeadSeconds,
             playerTime(forAudio: Self.hopBoundary(closure.end)) - Self.closureLeadSeconds)
        }
    }

    /// The centre of hop `hop` in utterance audio, as the analyzer gives keyframe offsets.
    nonisolated static func hopOffset(_ hop: Int) -> Double {
        (Double(hop * LipsyncDSP.hopSize) + Double(LipsyncDSP.frameSize) / 2) / Double(LipsyncDSP.sampleRate)
    }

    /// Where hop `hop` begins (fractional hops allowed): halfway between its centre and the previous one's.
    nonisolated static func hopBoundary(_ hop: Double) -> Double {
        hop * FormantLipsyncAnalyzer.hopSeconds
            + (Double(LipsyncDSP.frameSize) / 2 - Double(LipsyncDSP.hopSize) / 2) / Double(LipsyncDSP.sampleRate)
    }

    nonisolated static func pose(_ keyframe: LipsyncKeyframe) -> Pose {
        gated(Pose(openness: keyframe.openness, width: keyframe.width, rounding: keyframe.rounding),
              energy: keyframe.energy)
    }

    nonisolated static func gated(_ pose: Pose, energy: Double) -> Pose {
        rest.blended(to: pose, by: smoothstep(energy, quietEnergy, voicedEnergy))
    }

    /// A text pose: its opening, width and rounding give way to rest only below a text pose's quieter
    /// gate.
    nonisolated static func gatedText(_ pose: Pose, energy: Double) -> Pose {
        rest.blended(to: pose, by: smoothstep(energy, shapeQuietEnergy, shapeVoicedEnergy))
    }

    nonisolated private static func smoothstep(_ x: Double, _ low: Double, _ high: Double) -> Double {
        let t = min(max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The start of the first 10 ms block of `samples` whose RMS reaches `onsetLevel`.
    private static func firstSound(in samples: [Float]) -> Int? {
        var start = 0
        while start < samples.count {
            let end = min(start + onsetBlock, samples.count)
            var energy: Float = 0
            for i in start..<end { energy += samples[i] * samples[i] }
            if energy >= onsetLevel * onsetLevel * Float(end - start) { return start }
            start = end
        }
        return nil
    }

    /// Map seconds of utterance audio to the player's clock, across any gaps between chunks.
    func playerTime(forAudio seconds: Double) -> Double {
        guard let segment = segments.last(where: { $0.audio <= seconds }) ?? segments.first else { return seconds }
        return segment.player + (seconds - segment.audio)
    }

    private func clearTrack() {
        segments = []
        scheduledAudio = 0
        onset = nil
        keyframes = []
        closures = []
        cursor = 0
        textKeyframes = []
        textClosures = []
        textCursor = 0
        usesText = false
        alignment = nil
    }
}

#if DEBUG
/// `--lipsync-trace`: each chunk (its samples appended to tmp/lipsync-<label>.f32 as 24 kHz
/// Float32, with the player time last drawn), the analyzer's keyframes and events, and each
/// sentence's text and final alignment, all on the player clock.
extension LipsyncTimeline {
    private var traceAudioURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lipsync-\(traceLabel).f32")
    }

    private func traceChunk(_ samples: [Float], at playerTime: Double) {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        if let handle = try? FileHandle(forWritingTo: traceAudioURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: traceAudioURL)
        }
        print(String(format: "LIPSYNC_CHUNK: %@ %.6f %.6f %d %.6f", traceLabel, playerTime, scheduledAudio, samples.count,
                     lastSampleTime ?? -1))
    }

    private func traceResult(_ result: FormantLipsyncAnalyzer.Result) {
        for k in result.keyframes {
            print(String(format: "LIPSYNC_KEY: %@ %.6f %.6f %.4f %.4f %.4f %.4f", traceLabel,
                         playerTime(forAudio: k.offset), k.offset, k.openness, k.width, k.rounding, k.energy))
        }
        for e in result.events {
            print(String(format: "LIPSYNC_EVENT: %@ %.6f %@ %.4f %.3f", traceLabel, playerTime(forAudio: e.offset),
                         e.kind.rawValue, e.duration, e.confidence))
        }
    }

    /// Whether the alignment held, then each phone or pause as heard, with its word.
    private func traceAlignment(_ alignment: LipsyncAnalysis.Alignment) {
        print("LIPSYNC_ALIGNMENT: \(traceLabel) \(alignment.confident ? "held" : "lost")")
        for segment in alignment.segments {
            let word = segment.phone == nil || !alignment.words.indices.contains(segment.word)
                ? "-" : alignment.words[segment.word].spelling
            print(String(format: "LIPSYNC_PHONE: %@ %.6f %.6f %@ %@", traceLabel,
                         playerTime(forAudio: Self.hopBoundary(Double(segment.start))),
                         playerTime(forAudio: Self.hopBoundary(Double(segment.end))),
                         segment.phone?.description ?? "_", word))
        }
    }
}
#endif

/// Owns the resampler, analyzer and aligner on a serial queue, so work runs in scheduling order.
final class LipsyncAnalysis: @unchecked Sendable {
    struct Alignment: Sendable {
        var words: [LipsyncWord]
        var segments: [LipsyncAligner.Segment]
        var confident: Bool
        /// The audio is complete and the alignment final.
        var finished: Bool
    }

    /// The text track from hop `firstHop` on (earlier hops are unchanged), with every closure.
    struct TextUpdate: Sendable {
        var alignment: Alignment
        var firstHop: Int
        var poses: [LipsyncTimeline.Pose]
        /// Bilabial closures in hops.
        var closures: [(start: Double, end: Double)]
    }

    struct Output: Sendable {
        var result: FormantLipsyncAnalyzer.Result
        var text: TextUpdate?
    }

    /// How far the text track runs past the analyzed audio, on the alignment's prediction.
    static let predictedHops = 2

    private let queue = DispatchQueue(label: "ai.pipecat.littlevoices.lipsync", qos: .userInitiated)
    // Touched only on `queue`. A dead band of 0 makes every hop that moves a keyframe, so the
    // timeline has each hop's energy.
    private let analyzer = FormantLipsyncAnalyzer(deadBand: 0)
    private var resampler = LipsyncResampler()
    private let loadLexicon: @Sendable () -> LipsyncLexicon?
    private lazy var lexicon = loadLexicon()
    /// The voice's normalization and speaking rate, carried from sentence to sentence.
    private var voice = LipsyncAligner.Voice()
    private var aligner: LipsyncAligner?
    /// Each hop's energy from the analyzer's keyframes (nil until it arrives), and the poses last sent.
    private var energies: [Double?] = []
    private var sentPoses: [LipsyncTimeline.Pose] = []

    init(lexicon: @escaping @Sendable () -> LipsyncLexicon?) {
        loadLexicon = lexicon
        queue.async { [self] in _ = self.lexicon }
    }

    /// Start an utterance, aligning `text` if there is any.
    func begin(text: String?) {
        queue.async { [self] in
            aligner = text.flatMap { text in lexicon.flatMap { LipsyncAligner(words: $0.words(text), voice: voice) } }
            energies = []
            sentPoses = []
        }
    }

    /// Discard the current utterance's state.
    func reset() {
        queue.async { [self] in
            analyzer.resetUtterance()
            resampler.reset()
            aligner = nil
        }
    }

    /// Analyze 24 kHz `samples`, or with nil flush the utterance's tail, then deliver the result on
    /// the main actor, whose FIFO queue keeps results in order.
    func analyze(_ samples: [Float]?, deliver: @escaping @MainActor @Sendable (Output) -> Void) {
        queue.async { [self] in
            var result: FormantLipsyncAnalyzer.Result
            if let samples {
                let resampled = resampler.process(samples)
                result = analyzer.analyze(resampled)
                aligner?.process(resampled)
            } else {
                let resampled = resampler.flush()
                result = analyzer.analyze(resampled)
                let tail = analyzer.flush()
                result.keyframes += tail.keyframes
                result.events += tail.events
                resampler.reset()
                aligner?.process(resampled)
                aligner?.finish()
            }
            let text = aligner.map { textUpdate($0, keyframes: result.keyframes) }
            if let aligner, aligner.finished {
                voice = aligner.voice
                self.aligner = nil
            }
            let output = Output(result: result, text: text)
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(output) } }
        }
    }

    /// The alignment as each hop's pose, gated by the hop's energy, from the first hop that changed.
    private func textUpdate(_ aligner: LipsyncAligner, keyframes: [LipsyncKeyframe]) -> TextUpdate {
        for keyframe in keyframes {
            let hop = Int(((keyframe.offset - LipsyncTimeline.hopOffset(0)) / FormantLipsyncAnalyzer.hopSeconds).rounded())
            guard hop >= 0 else { continue }
            if hop >= energies.count { energies += [Double?](repeating: nil, count: hop - energies.count + 1) }
            energies[hop] = keyframe.energy
        }
        guard aligner.confident else {
            let alignment = Alignment(words: aligner.words, segments: [], confident: false, finished: aligner.finished)
            return TextUpdate(alignment: alignment, firstHop: 0, poses: [], closures: [])
        }
        // Decoding may lose the alignment.
        let segments = aligner.segments(predicting: Self.predictedHops)
        let alignment = Alignment(words: aligner.words,
                                  segments: aligner.finished ? segments : segments.filter { $0.start < aligner.hops },
                                  confident: aligner.confident, finished: aligner.finished)
        // Hops with an alignment and an energy (a hop without a keyframe keeps the last energy),
        // then predicted hops at their phone's usual loudness, but little louder than the last
        // measured hop, so speech that has stopped stays stopped.
        let count = aligner.finished ? energies.count : min(aligner.hops, energies.count)
        let total = aligner.finished ? count : aligner.hops + Self.predictedHops
        let targets = LipsyncVisemes.poses(segments, hops: 0..<total)
        var poses: [LipsyncTimeline.Pose] = []
        poses.reserveCapacity(total)
        var energy = 0.0, measured = 0.0
        var index = 0
        for hop in 0..<total {
            if hop < count {
                energy = energies[hop] ?? energy
                measured = energy
            } else {
                while index + 1 < segments.count && segments[index].end <= hop { index += 1 }
                energy = min(segments.isEmpty ? 0 : Self.usualEnergy(segments[index].phone), measured + 0.2)
            }
            let target = targets[hop]
            poses.append(LipsyncTimeline.gatedText(LipsyncTimeline.Pose(openness: target.openness, width: target.width,
                                                                        rounding: target.rounding), energy: energy))
        }
        var first = 0
        while first < min(poses.count, sentPoses.count) && poses[first] == sentPoses[first] { first += 1 }
        sentPoses = poses
        return TextUpdate(alignment: alignment, firstHop: first, poses: Array(poses[first...]),
                          closures: LipsyncVisemes.closures(segments))
    }

    /// A phone's usual analyzer energy: vowels loud, sonorants nearly so, voiced obstruents
    /// softer, voiceless ones quiet, pauses silent.
    static func usualEnergy(_ phone: LipsyncPhone?) -> Double {
        guard let phone else { return 0 }
        if phone.isVowel { return 0.8 }
        switch phone.symbol {
        case .m, .n, .ng, .l, .r, .w, .y: return 0.65
        case .b, .d, .g, .v, .dh, .z, .zh, .jh: return 0.45
        default: return 0.3
        }
    }

    /// Returns once the work queued so far has run and its results have been delivered.
    func drained() async {
        await withCheckedContinuation { continuation in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }
}

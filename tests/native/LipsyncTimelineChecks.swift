import Foundation

private func near(_ a: Double, _ b: Double, _ message: String) {
    precondition(abs(a - b) <= 1e-9, "\(message): \(a) != \(b)")
}

@main
enum LipsyncTimelineChecks {
    @MainActor
    static func main() async throws {
        resampler()
        try await timeline()
        print("LIPSYNC_TIMELINE_CHECKS_PASSED: zero-delay resampling, aliasing, chunking, clock mapping, background analysis, stale results, rest through leading silence, closures between syllables, rest after speech, steady vowels, quiet hops rest, pose sampling, closures, rest")
    }

    /// Near-silence at 24 kHz, like Phonon's pauses (about -80 dBFS).
    static func silence(seconds: Double) -> [Float] {
        (0..<Int(seconds * 24_000)).map { Float(1e-4 * sin(Double($0) * 2.399)) }
    }

    /// A sustained vowel at 24 kHz: 120 Hz harmonics shaped by formant resonances.
    static func vowel(f1: Double, f2: Double, seconds: Double = 1) -> [Float] {
        (0..<Int(seconds * 24_000)).map { i in
            let t = Double(i) / 24_000
            var sum = 0.0
            for harmonic in 1...60 {
                let f = 120 * Double(harmonic)
                let gain = 1 / (1 + pow((f - f1) / 90, 2)) + 0.6 / (1 + pow((f - f2) / 110, 2))
                    + 0.2 / (1 + pow((f - 2600) / 150, 2))
                sum += gain * sin(2 * Double.pi * f * t)
            }
            return Float(0.08 * sum)
        }
    }

    static func resample(_ input: [Float], chunk: Int) -> [Float] {
        var resampler = LipsyncResampler()
        var output: [Float] = []
        var start = 0
        while start < input.count {
            output += resampler.process(Array(input[start..<min(start + chunk, input.count)]))
            start += chunk
        }
        return output + resampler.flush()
    }

    static func resampler() {
        let tone = (0..<4800).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / 24_000)) }
        let output = resample(tone, chunk: 731)
        precondition(output.count == 3200, "24 kHz to 16 kHz must keep duration: \(output.count)")
        precondition(output == resample(tone, chunk: 4800), "Chunk boundaries changed the output")
        // Output sample k is centered on input time 1.5k: no delay to correct.
        var worst: Float = 0
        for k in 40..<3160 {
            let exact = Float(0.5 * sin(2 * Double.pi * 1000 * 1.5 * Double(k) / 24_000))
            worst = max(worst, abs(output[k] - exact))
        }
        precondition(worst < 2e-3, "Passband tone distorted or delayed: \(worst)")
        // Content above the 8 kHz output Nyquist must not alias into the analysis band.
        let high = (0..<4800).map { Float(0.5 * sin(2 * Double.pi * 10_000 * Double($0) / 24_000)) }
        let aliased = resample(high, chunk: 500)[40..<3160]
        let rms = (aliased.reduce(0) { $0 + $1 * $1 } / Float(aliased.count)).squareRoot()
        precondition(rms < 0.005, "10 kHz content aliased: rms \(rms)")
    }

    @MainActor
    static func timeline() async throws {
        let mouth = LipsyncTimeline()
        precondition(mouth.pose(at: 1) == LipsyncTimeline.rest && !mouth.isAnimating)

        // One second of audio from player time 0, then half a second after a 0.25 s gap.
        mouth.schedule([Float](repeating: 0, count: 24_000), at: 0)
        mouth.schedule([Float](repeating: 0, count: 12_000), at: 1.25)
        precondition(mouth.isAnimating)
        near(mouth.playerTime(forAudio: 0.5), 0.5, "Audio before the gap moved")
        near(mouth.playerTime(forAudio: 1.2), 1.45, "Audio after the gap must follow the player clock")
        mouth.cancel()
        precondition(!mouth.isAnimating && mouth.pose(at: 0.5) == LipsyncTimeline.rest)

        // Real analysis runs off the main actor and lands on the player clock in order.
        let open = vowel(f1: 750, f2: 1200)
        mouth.schedule(Array(open[..<12_000]), at: 2)
        mouth.schedule(Array(open[12_000...]), at: 2.5)
        mouth.finish()
        await mouth.analyzed()
        precondition(mouth.pose(at: 2.5).openness > 0.6, "/a/ must open the mouth: \(mouth.pose(at: 2.5))")
        precondition(mouth.pose(at: 1.5) == LipsyncTimeline.rest, "Analysis must follow the player clock")
        let spread = vowel(f1: 280, f2: 2300)
        mouth.schedule(spread, at: 0)
        mouth.finish()
        await mouth.analyzed()
        precondition(mouth.pose(at: 0.5).width > 0.7, "/i/ must spread the lips: \(mouth.pose(at: 0.5))")
        // A stopped utterance's late results must not reach the next one.
        mouth.schedule(open, at: 0)
        mouth.cancel()
        mouth.schedule([Float](repeating: 0, count: 24_000), at: 0)
        mouth.finish()
        await mouth.analyzed()
        precondition(mouth.pose(at: 0.5).openness < 0.3, "A cancelled utterance leaked: \(mouth.pose(at: 0.5))")
        mouth.cancel()

        // Like a Phonon sentence: 0.15 s of near-silence with a click in its first 40 ms, then
        // /a/. The analyzer starts each utterance from a half-open neutral pose; the mouth must
        // still rest until the lips part for the first sound.
        var sentence = (0..<3600).map { i in
            Float(1e-4 * sin(Double(i) * 2.399)) + (i < 120 ? Float(0.003 * sin(2 * Double.pi * Double(i) / 24)) : 0)
        }
        sentence += vowel(f1: 750, f2: 1200, seconds: 0.6)
        for start in stride(from: 0, to: sentence.count, by: 1920) {
            mouth.schedule(Array(sentence[start..<min(start + 1920, sentence.count)]), at: Double(start) / 24_000)
        }
        mouth.finish()
        await mouth.analyzed()
        for step in 0..<50 {
            let time = Double(step) / 1000
            precondition(mouth.pose(at: time) == LipsyncTimeline.rest,
                         "The mouth opened in the silence before the first sound: \(time) s, \(mouth.pose(at: time))")
        }
        precondition(mouth.pose(at: 0.4).openness > 0.6, "/a/ after silence must open the mouth: \(mouth.pose(at: 0.4))")
        mouth.cancel()

        // Speech-like: /a/, an 80 ms closure (a B or P), /a/ again, then a pause. The analyzer's
        // formant pose holds through the closure; its energy shuts the lips there, and they rest
        // once the voice stops.
        let first = vowel(f1: 750, f2: 1200, seconds: 0.4), second = vowel(f1: 700, f2: 1300, seconds: 0.4)
        let speech = silence(seconds: 0.15) + first + silence(seconds: 0.08) + second + silence(seconds: 0.4)
        for start in stride(from: 0, to: speech.count, by: 1920) {
            mouth.schedule(Array(speech[start..<min(start + 1920, speech.count)]), at: Double(start) / 24_000)
        }
        mouth.finish()
        await mouth.analyzed()
        let closure = 0.15 + 0.4 + 0.04, stopped = closure + 0.04 + 0.4
        precondition(mouth.pose(at: closure).openness <= LipsyncTimeline.rest.openness + 1e-9,
                     "The lips must meet in a closure between syllables: \(mouth.pose(at: closure))")
        for step in 0...20 {
            let time = stopped + 0.06 + Double(step) / 60
            precondition(abs(mouth.pose(at: time).openness - LipsyncTimeline.rest.openness) < 0.01,
                         "The mouth must rest once the voice stops: \(time) s, \(mouth.pose(at: time))")
        }
        // A steady vowel holds its pose: open, with no frame far from the one before.
        var previous: Double?
        for step in 0..<16 {
            let openness = mouth.pose(at: 0.2 + Double(step) / 60).openness
            precondition(openness > 0.6, "A steady /a/ must hold the mouth open: \(openness)")
            if let previous { precondition(abs(openness - previous) < 0.05, "A steady /a/ must not flicker") }
            previous = openness
        }
        mouth.cancel()

        // Each hop's pose gives way to rest as the hop grows quiet.
        mouth.schedule(vowel(f1: 750, f2: 1200, seconds: 0.01), at: 0)
        let wide = LipsyncTimeline.Pose(openness: 0.9, width: 0.8, rounding: 0.6)
        var quiet = FormantLipsyncAnalyzer.Result()
        quiet.keyframes = [0.1, 0.4, 0.42, 0.7].enumerated().map { index, energy in
            LipsyncKeyframe(offset: 0.2 + 0.5 * Double(index), openness: wide.openness, width: wide.width,
                            rounding: wide.rounding, energy: energy, pitch: 0, confidence: 0)
        }
        mouth.record(quiet)
        let lead = LipsyncTimeline.leadSeconds
        precondition(mouth.pose(at: 0.2 - lead) == LipsyncTimeline.rest, "A quiet hop must rest")
        let middle = mouth.pose(at: 0.7 - lead)
        precondition(middle.openness > LipsyncTimeline.rest.openness && middle.openness < wide.openness
                         && middle.width > LipsyncTimeline.rest.width && middle.width < wide.width,
                     "A softer hop must sit between rest and its pose: \(middle)")
        precondition(mouth.pose(at: 1.2 - lead).openness > middle.openness, "A louder hop must open further")
        precondition(mouth.pose(at: 1.7 - lead) == wide, "A voiced hop must take its pose")
        mouth.cancel()

        // Hand-placed keyframes: open /a/ at 0.5 s, spread /i/ at 1.0 s, a closure at 0.7 s,
        // in an utterance whose first sound starts at once. Each lands `lead` ahead of its audio.
        mouth.schedule(vowel(f1: 750, f2: 1200, seconds: 0.01), at: 0)
        let preroll = LipsyncTimeline.prerollSeconds
        let openPose = LipsyncTimeline.Pose(openness: 0.8, width: 0.3, rounding: 0)
        let spreadPose = LipsyncTimeline.Pose(openness: 0.3, width: 0.9, rounding: 0)
        var result = FormantLipsyncAnalyzer.Result()
        result.keyframes = [
            LipsyncKeyframe(offset: 0.5, openness: openPose.openness, width: openPose.width, rounding: openPose.rounding, energy: 1, pitch: 0, confidence: 0),
            LipsyncKeyframe(offset: 1.0, openness: spreadPose.openness, width: spreadPose.width, rounding: spreadPose.rounding, energy: 1, pitch: 0, confidence: 0),
        ]
        result.events = [LipsyncEvent(offset: 0.7, kind: .closure, duration: 0.1, confidence: 1),
                         LipsyncEvent(offset: 0.9, kind: .nasal, duration: 0, confidence: 1)]
        mouth.record(result)
        precondition(mouth.pose(at: nil) == LipsyncTimeline.rest, "No playback must rest")
        precondition(mouth.pose(at: 0.5 - lead - preroll - 0.01) == LipsyncTimeline.rest, "Too early to blend in")
        near(mouth.pose(at: 0.5 - lead - preroll / 2).openness, 0.15 + (0.8 - 0.15) * 0.5, "Pre-roll blends from rest")
        near(mouth.pose(at: 0.6 - lead).width, 0.3 + (0.9 - 0.3) * 0.2, "Keyframes interpolate")
        precondition(mouth.pose(at: 0.75 - lead).openness <= 0.02 + 1e-9, "A closure must shut the lips")
        let entering = mouth.pose(at: 0.685 - lead).openness
        precondition(entering > 0.02 && entering < mouth.pose(at: 0.66 - lead).openness, "Closures ease in")
        near(mouth.pose(at: 0.95 - lead).openness, 0.8 + (0.3 - 0.8) * 0.9, "Lips reopen after the closure")
        precondition(mouth.pose(at: 1.2 - lead) == spreadPose, "The last keyframe holds briefly")
        let resting = mouth.pose(at: 3)
        precondition(abs(resting.openness - LipsyncTimeline.rest.openness) < 0.01, "The mouth eases back to rest")
        // Queries may go backwards in time (the playhead restarts after a stop).
        near(mouth.pose(at: 0.6 - lead).width, 0.3 + (0.9 - 0.3) * 0.2, "Cursor must rewind")

        mouth.finish()
        precondition(mouth.isAnimating, "The mouth settles before animation pauses")
        try await Task.sleep(for: .seconds(2.2))
        precondition(!mouth.isAnimating && mouth.pose(at: 1) == LipsyncTimeline.rest, "Animation never paused")
    }
}

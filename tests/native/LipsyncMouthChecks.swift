import Foundation

// The drawn mouth, end to end: synthetic speech through each character's LipsyncTimeline
// (resampler, analyzer, timeline), sampled once per 60 Hz frame a frame ahead of the audio as
// DuoStageView samples it, and drawn by the stage's FaceRig and LipSyncMapping.

/// The frame's sampled mouths, the same for each of its substeps.
private struct FrameMouths: MouthSource {
    var drives = PerCharacter<MouthDrive?>(angel: nil, devil: nil)
    func drive(_ character: DuoCharacter, at simTime: Double) -> MouthDrive? { drives[character] }
}

/// Near-silence at 24 kHz, like Phonon's pauses (about -80 dBFS).
private func silence(seconds: Double) -> [Float] {
    (0..<Int(seconds * 24_000)).map { Float(1e-4 * sin(Double($0) * 2.399)) }
}

/// A sustained vowel at 24 kHz: 120 Hz harmonics shaped by formant resonances.
private func vowel(f1: Double, f2: Double, seconds: Double) -> [Float] {
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

@main
enum LipsyncMouthChecks {
    /// Where each part of the utterance plays on the player's clock (seconds).
    static let start = 1.0
    static let open = (from: 1.3, to: 1.8)
    static let closure = (from: 1.8, to: 1.88)
    static let voiceStops = 2.18
    static let spread = (from: 2.68, to: 3.08)

    @MainActor
    static func main() async throws {
        for c in DuoCharacter.allCases { try await speak(c) }
        knee()
        print("LIPSYNC_MOUTH_CHECKS_PASSED: rest before speech, steady vowels, bilabial closures, rest after speech, spread vowels, soft full opening")
    }

    /// The jaw's opening rises smoothly with openness and eases level into the full opening at
    /// ô = 1, so a loud open vowel short of it still moves.
    static func knee() {
        func opening(_ o: Double) -> Double {
            LipSyncMapping.opening(MouthDrive(openness: o, width: 0.5, rounding: 0.1))
        }
        let full = MouthDrive(talkOpen: 1).openness
        var previous = 0.0
        for k in 0...200 {
            let x = opening(Double(k) / 200)
            precondition(x >= previous - 1e-12 && x - previous < 0.03, "The opening must rise smoothly: \(x) after \(previous)")
            previous = x
        }
        precondition(abs(opening(full) - 1) < 1e-9 && opening(1) == 1, "ô = 1 must open fully")
        precondition(opening(0.76) < 0.97, "A loud vowel short of ô = 1 must not sit at the full opening: \(opening(0.76))")
        precondition(opening(full) - opening(full - 0.01) < 0.002, "The opening must ease level into the full opening")
    }

    /// One character, holding the floor, says /a/, a B (an 80 ms closure), /a/, a pause, then
    /// /i/, after 0.3 s of silence; each frame's drawn mouth is checked at the time it shows.
    @MainActor
    static func speak(_ c: DuoCharacter) async throws {
        let audio = silence(seconds: 0.3) + vowel(f1: 750, f2: 1200, seconds: 0.5) + silence(seconds: 0.08)
            + vowel(f1: 700, f2: 1300, seconds: 0.3) + silence(seconds: 0.5) + vowel(f1: 280, f2: 2300, seconds: 0.4)
            + silence(seconds: 0.6)
        let mouth = LipsyncTimeline()
        for offset in stride(from: 0, to: audio.count, by: 1920) {
            mouth.schedule(Array(audio[offset..<min(offset + 1920, audio.count)]), at: start + Double(offset) / 24_000)
        }
        mouth.finish()
        await mouth.analyzed()

        // The character holds the floor from the start; sim time is the player's clock.
        var sim = StageSimulation(seed: 3, metrics: .iPhone18Pro)
        var inputs = StageInputs()
        inputs.active = true
        inputs.floor = c
        sim.receive(inputs, at: 0)
        var frames: [(time: Double, mouth: MouthParams)] = []
        for k in 1...(5 * 60) {
            let now = Double(k) / 60
            let talking: Set<DuoCharacter> = now >= start - 0.2 && mouth.isAnimating ? [c] : []
            if talking != inputs.talking {
                inputs.talking = talking
                sim.receive(inputs, at: now)
            }
            var source = FrameMouths()
            if !talking.isEmpty {
                let pose = mouth.pose(at: now + 1 / 60)
                source.drives[c] = MouthDrive(openness: pose.openness, width: pose.width, rounding: pose.rounding)
            }
            sim.advance(to: now, mouths: source)
            frames.append((now + 1 / 60, sim.faces[c].mouth))
        }
        func during(_ from: Double, _ to: Double) -> [MouthParams] {
            frames.filter { $0.time >= from && $0.time < to }.map(\.mouth)
        }
        let closedWidth = c == .angel ? AngelGeometry.mouthClosedWidth : DevilGeometry.mouthClosedWidth

        // Silence before the first sound rests: the closed smile.
        for m in during(start + 0.05, open.from - 0.1) {
            precondition(m.open <= 1.5, "\(c): the mouth must rest before speech: \(m.open)")
        }
        // A steady /a/ holds the mouth wide open, with no frame far from the one before.
        let held = during(open.from + 0.1, open.to - 0.08)
        precondition(held.allSatisfy { $0.open >= 20 }, "\(c): a steady /a/ must open the mouth: \(held.map(\.open))")
        for (a, b) in zip(held, held.dropFirst()) {
            precondition(abs(a.open - b.open) < 2, "\(c): a steady /a/ must not flicker: \(a.open) then \(b.open)")
        }
        // The lips meet in a bilabial's closure.
        let shut = during(closure.from - 0.02, closure.to + 0.02).map(\.open).min() ?? .infinity
        precondition(shut <= 1, "\(c): the lips must meet in a bilabial closure: \(shut)")
        // Once the voice stops the mouth closes within 0.12 s and rests.
        for m in during(voiceStops + 0.12, spread.from - 0.1) {
            precondition(m.open <= 2, "\(c): the mouth must rest once the voice stops: \(m.open)")
        }
        // An /i/ spreads the lips wide and parts them a little, though its jaw barely opens.
        for m in during(spread.from + 0.1, spread.to - 0.08) {
            precondition(m.open >= 5 && m.open <= 20 && m.width >= closedWidth + 8,
                         "\(c): an /i/ must spread a small opening: depth \(m.open), width \(m.width)")
        }
    }
}

import Foundation

// Lip sync that knows the words: pronunciations (the dictionary, contractions, numbers as Phonon
// reads them, letter-to-sound for the rest) and the visemes through each character's mouth; with
// the fixtures, the alignment of two Phonon sentences against landmarks placed by hand from their
// level and high-band energy, and the timeline's text track and fallback to formant analysis.
//
// usage: lipsync-text-checks <cmudict.lzma> [<fixtures dir>]
// Fixtures: who-knew.wav, Phonon's en_gb_Freya saying "Who knew? You too, Sue?", and
// maybe-my-mommy.wav, en_gb_Reuben saying "Maybe my mommy may buy a puppy.", at 24 kHz. Phonon's
// voices cannot be in the repository; scripts/lipsync/make_fixtures.py writes the clips from the
// local checkpoint.

private func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    precondition(condition, message())
}

@main
enum LipsyncTextChecks {
    static let whoKnew = "Who knew? You too, Sue?"
    static let maybe = "Maybe my mommy may buy a puppy."

    @MainActor
    static func main() async throws {
        let arguments = CommandLine.arguments
        let lexicon = try LipsyncLexicon(compressed: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        guard let lexicon else { fatalError("The pronunciations did not load") }
        pronunciations(lexicon)
        visemes()
        print("LIPSYNC_TEXT_CHECKS_PASSED: dictionary, contractions, initialisms, drawn-out words, letter-to-sound, "
              + "numbers, amounts, years, times, pauses, visemes, coarticulation, closures")
        guard arguments.count > 2 else { return }
        let fixtures = URL(fileURLWithPath: arguments[2])
        let freya = try wav(fixtures.appendingPathComponent("who-knew.wav"))
        let reuben = try wav(fixtures.appendingPathComponent("maybe-my-mommy.wav"))
        alignment(lexicon, freya: freya, reuben: reuben)
        try await timeline(lexicon, freya: freya, reuben: reuben)
        print("LIPSYNC_ALIGNMENT_CHECKS_PASSED: landmarks, chunking, confidence, text track, rest before speech, "
              + "fallback")
    }

    /// 16-bit mono WAV samples as floats.
    static func wav(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(data[offset + 4]) | Int(data[offset + 5]) << 8 | Int(data[offset + 6]) << 16 | Int(data[offset + 7]) << 24
            if id == "data" {
                return stride(from: offset + 8, to: offset + 8 + size - 1, by: 2).map { i in
                    Float(Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8)) / 32768
                }
            }
            offset += 8 + size + size % 2
        }
        fatalError("No data chunk in \(url.lastPathComponent)")
    }

    // MARK: - Pronunciations

    static func phones(_ lexicon: LipsyncLexicon, _ text: String) -> String {
        lexicon.words(text).map { $0.phones.map(\.description).joined(separator: " ") }.joined(separator: " | ")
    }

    static func spoken(_ text: String) -> String { LipsyncText.tokens(text).map(\.text).joined(separator: " ") }

    static func pronunciations(_ lexicon: LipsyncLexicon) {
        expect(lexicon.count > 120_000, "The dictionary must hold CMUdict's words: \(lexicon.count)")
        expect(phones(lexicon, "hello") == "HH AH0 L OW1", "Dictionary word: \(phones(lexicon, "hello"))")
        expect(phones(lexicon, "You") == "Y UW1", "Case must not matter: \(phones(lexicon, "You"))")
        expect(phones(lexicon, "don't") == "D OW1 N T", "Contraction: \(phones(lexicon, "don't"))")
        expect(phones(lexicon, "It\u{2019}s") == "IH1 T S", "Typographic apostrophe: \(phones(lexicon, "It\u{2019}s"))")
        expect(phones(lexicon, "AI") == "EY1 | AY1", "An initialism is spelled: \(phones(lexicon, "AI"))")
        expect(phones(lexicon, "Sooo") == phones(lexicon, "so"), "A drawn-out word is the word: \(phones(lexicon, "Sooo"))")
        expect(phones(lexicon, "Mmm") == "M", "A hum is not the letter's name: \(phones(lexicon, "Mmm"))")
        expect(lexicon.words("Thorwick's").first?.phones.last?.symbol == .s,
               "A possessive takes the S: \(phones(lexicon, "Thorwick's"))")
        // Letter-to-sound for words the dictionary lacks.
        for (word, first, last) in [("Thorwick", "TH", "K"), ("blorps", "B", "S"), ("Zandrel", "Z", "L")] {
            let guess = lexicon.words(word)
            expect(guess.count == 1 && guess[0].phones == LipsyncLetterToSound.phones(word), "\(word) must come from the rules")
            expect(guess[0].phones.first?.description == first && guess[0].phones.last?.description == last
                       && guess[0].phones.contains(where: { $0.isVowel && $0.stress == 1 }),
                   "\(word) guessed as \(phones(lexicon, word))")
        }
        // Numbers, amounts, years and times as Phonon's normalization has them read.
        let cases = [("1,250", "one thousand two hundred and fifty"), ("2024", "twenty twenty four"),
                     ("1999", "nineteen ninety nine"), ("2005", "two thousand five"), ("42", "forty two"),
                     ("$4.59", "four dollars and fifty nine cents"), ("£20", "twenty pounds"), ("3rd", "third"),
                     ("21st", "twenty first"), ("15%", "fifteen percent"), ("3:45pm", "three forty five PM"),
                     ("7:00", "seven"), ("9:05", "nine oh five"), ("-2", "minus two"), ("2.5", "two point five"),
                     ("twenty-five", "twenty five"), ("rock & roll", "rock and roll")]
        for (text, words) in cases {
            expect(spoken(text) == words, "\"\(text)\" must read \"\(words)\", not \"\(spoken(text))\"")
        }
        expect(lexicon.words("1,250").allSatisfy { lexicon.lookup($0.spelling) == $0.phones },
               "Number words come from the dictionary")
        // Punctuation becomes pauses; quotes and dashes fold as Phonon folds them.
        let words = lexicon.words("Wait, what? Are you \u{201C}sure\u{201D} \u{2014} really\u{2026}")
        expect(words.map(\.spelling) == ["Wait", "what", "Are", "you", "sure", "really"],
               "Words: \(words.map(\.spelling))")
        expect(words.map(\.pause) == [.comma, .stop, .none, .none, .comma, .stop], "Pauses: \(words.map(\.pause))")
    }

    // MARK: - Alignment

    /// The sentence's 24 kHz audio through the app's resampler into an aligner, `chunk` samples at
    /// a time, decoding after each chunk as the timeline does.
    static func align(_ lexicon: LipsyncLexicon, _ samples: [Float], _ text: String, chunk: Int = 1920)
        -> LipsyncAligner {
        guard let aligner = LipsyncAligner(words: lexicon.words(text), voice: LipsyncAligner.Voice()) else {
            fatalError("No aligner for \(text)")
        }
        var resampler = LipsyncResampler()
        var start = 0
        while start < samples.count {
            aligner.process(resampler.process(Array(samples[start..<min(start + chunk, samples.count)])))
            _ = aligner.segments(predicting: 2)
            start += chunk
        }
        aligner.process(resampler.flush())
        aligner.finish()
        return aligner
    }

    /// Where a word's phone starts and ends, in seconds.
    static func span(_ segments: [LipsyncAligner.Segment], word: Int, _ phone: String, nth: Int = 0) -> (Double, Double) {
        let matches = segments.filter { $0.word == word && $0.phone?.description == phone }
        guard nth < matches.count else { fatalError("No \(phone) in word \(word): \(segments)") }
        return (LipsyncTimeline.hopBoundary(Double(matches[nth].start)), LipsyncTimeline.hopBoundary(Double(matches[nth].end)))
    }

    static func near(_ value: Double, _ landmark: Double, _ tolerance: Double, _ what: String) {
        expect(abs(value - landmark) <= tolerance, "\(what) at \(value) s, landmark \(landmark) s")
    }

    static func alignment(_ lexicon: LipsyncLexicon, freya: [Float], reuben: [Float]) {
        // "Who knew? You too, Sue?": silence from 0.78 to 1.26 s; the vowels after H, T and S.
        let who = align(lexicon, freya, whoKnew)
        expect(who.confident, "The right text must hold")
        let segments = who.segments()
        guard let pause = segments.first(where: { $0.phone == nil && $0.word == 1 }) else {
            fatalError("No pause after \"knew?\": \(segments)")
        }
        near(LipsyncTimeline.hopBoundary(Double(pause.start)), 0.78, 0.04, "The pause after \"knew?\"")
        near(LipsyncTimeline.hopBoundary(Double(pause.end)), 1.26, 0.04, "\"You\"")
        near(span(segments, word: 0, "UW1").0, 0.2, 0.04, "The OO of \"Who\"")
        near(span(segments, word: 3, "UW1").0, 1.57, 0.03, "The OO of \"too\"")
        near(span(segments, word: 4, "S").0, 1.75, 0.03, "The S of \"Sue\"")
        near(span(segments, word: 4, "UW1").0, 1.89, 0.03, "The OO of \"Sue\"")

        // "Maybe my mommy may buy a puppy.": the closures of B and P, and the vowels after them.
        let mommy = align(lexicon, reuben, maybe)
        expect(mommy.confident, "The right text must hold")
        let lips = mommy.segments()
        near(span(lips, word: 3, "EY1").0, 1.06, 0.04, "The EY of \"may\"")
        near(span(lips, word: 4, "AY1").0, 1.26, 0.03, "The AY of \"buy\"")
        near(span(lips, word: 6, "AH1").0, 1.54, 0.04, "The AH of \"puppy\"")
        near(span(lips, word: 6, "IY0").0, 1.69, 0.04, "The final Y of \"puppy\"")
        // Each B or P ends at its release (the burst after the closure's silence).
        for (word, nth, release) in [(4, 0, 1.25), (6, 0, 1.51), (6, 1, 1.68)] {
            let (start, end) = span(lips, word: word, word == 4 ? "B" : "P", nth: nth)
            expect(start <= release && abs(end - release) <= 0.04,
                   "The B or P released at \(release) s is aligned at \(start)-\(end)")
        }

        // Chunking never changes the alignment.
        let rechunked = align(lexicon, freya, whoKnew, chunk: 731)
        expect(rechunked.segments() == segments, "Chunk boundaries moved the alignment")

        // The wrong text loses confidence.
        let wrong = align(lexicon, freya, maybe)
        expect(!wrong.confident, "A mismatched text must lose the alignment")
    }

    // MARK: - Visemes

    static func drive(_ phone: LipsyncPhone) -> MouthDrive {
        let target = LipsyncVisemes.targets(phone)[0]
        return MouthDrive(openness: target.openness, width: target.width, rounding: target.rounding)
    }

    static func visemes() {
        let uw = LipsyncPhone(.uw, stress: 1), iy = LipsyncPhone(.iy, stress: 1), aa = LipsyncPhone(.aa, stress: 1)
        let ow = LipsyncPhone(.ow, stress: 1), f = LipsyncPhone(.f)
        for character in DuoCharacter.allCases {
            let talking = ExpressionLibrary.targets(.talking, for: character).mouth
            func draw(_ phone: LipsyncPhone) -> MouthParams {
                LipSyncMapping.map(talking, drive: drive(phone), talk: 1, character: character)
            }
            let open = draw(aa), rounded = draw(uw), spread = draw(iy)
            // A: deep; U and O: narrower and rounded; E: wide and shallow.
            expect(open.open >= 0.75 * LipSyncMapping.maxOpen(character), "\(character) AA must open: \(open.open)")
            expect(rounded.width < 0.8 * open.width && rounded.round > 0.25,
                   "\(character) OO must round: width \(rounded.width) round \(rounded.round)")
            expect(draw(ow).round > 0.8 && draw(ow).width < 0.7 * open.width, "\(character) OW must start an O")
            expect(spread.width > open.width && spread.open < open.open, "\(character) EE must spread: \(spread)")
            expect(LipSyncMapping.parting(drive(f)) < 0.35, "\(character) F must stay narrow")
        }
        func segments(_ symbols: [LipsyncPhone.Symbol], lengths: [Int]) -> [LipsyncAligner.Segment] {
            var start = 0
            return zip(symbols, lengths).map { symbol, length in
                defer { start += length }
                return LipsyncAligner.Segment(phone: LipsyncPhone(symbol, stress: 1), word: 0, start: start, end: start + length)
            }
        }
        // Coarticulation: the lips round through the S of "soon" before its OO, not that of "seen".
        let soon = LipsyncVisemes.poses(segments([.s, .uw, .n], lengths: [5, 8, 4]), hops: 0..<17)
        let seen = LipsyncVisemes.poses(segments([.s, .iy, .n], lengths: [5, 8, 4]), hops: 0..<17)
        expect(soon[4].rounding > 0.4 && seen[4].rounding < 0.15,
               "The S must anticipate its vowel: soon \(soon[4].rounding), seen \(seen[4].rounding)")
        expect(soon[9].rounding > 0.9 && seen[9].width > 0.95, "Each vowel must reach its target")
        // A T leaves the lips to the vowels around it.
        let toot = LipsyncVisemes.poses(segments([.uw, .t, .uw], lengths: [6, 2, 6]), hops: 0..<14)
        expect(toot[6].rounding > 0.7, "The T of \"oo-too\" must stay rounded: \(toot[6].rounding)")
        // M, B and P close the lips: an M throughout, a B or P from a hop early until its release;
        // closures that touch merge.
        let closures = LipsyncVisemes.closures(segments([.m, .aa, .p, .b, .aa], lengths: [4, 6, 3, 2, 5]))
        expect(closures.count == 2 && closures[0] == (0, 4) && closures[1] == (9, 14.5),
               "Closures: \(closures)")
    }

    // MARK: - Timeline

    /// Play `samples` into `mouth` from player time 0 in Phonon's 80 ms chunks, with `text` if any.
    @MainActor
    static func play(_ mouth: LipsyncTimeline, _ samples: [Float], text: String?) async {
        mouth.cancel()
        mouth.expect(text: text)
        var start = 0
        while start < samples.count {
            mouth.schedule(Array(samples[start..<min(start + 1920, samples.count)]), at: Double(start) / 24_000)
            start += 1920
        }
        mouth.finish()
        await mouth.analyzed()
    }

    @MainActor
    static func timeline(_ lexicon: LipsyncLexicon, freya: [Float], reuben: [Float]) async throws {
        let mouth = LipsyncTimeline(lexicon: { lexicon })
        let formant = LipsyncTimeline(lexicon: { lexicon })
        let lead = LipsyncTimeline.leadSeconds

        // With its text the mouth rounds for the OO of "too", where formants alone read a spread E.
        await play(mouth, freya, text: whoKnew)
        await play(formant, freya, text: nil)
        expect(mouth.alignment?.confident == true && mouth.alignment?.finished == true, "The alignment must hold")
        expect(formant.alignment == nil, "No text, no alignment")
        let too = 1.66 - lead
        expect(mouth.pose(at: too).rounding > 0.6 && mouth.pose(at: too).rounding > formant.pose(at: too).rounding + 0.3,
               "\"too\" must round: \(mouth.pose(at: too)) against \(formant.pose(at: too))")
        // The mouth rests until the first sound, and through the pause after "knew?".
        for time in stride(from: 0.0, to: 0.06, by: 0.01) {
            expect(mouth.pose(at: time) == LipsyncTimeline.rest, "The mouth opened before the first sound: \(time) s")
        }
        expect(abs(mouth.pose(at: 1.0).openness - LipsyncTimeline.rest.openness) < 0.01, "The pause must rest")

        // The B of "buy" and the P's of "puppy" shut the lips.
        await play(mouth, reuben, text: maybe)
        for closure in [1.23, 1.48, 1.65] {
            expect(mouth.pose(at: closure - 0.01).openness <= 0.05, "Lips must close at \(closure) s: \(mouth.pose(at: closure))")
        }

        // Falling back: the wrong text, and pronunciations that cannot load, draw the formant mouth.
        // Each timeline hears the same audio first (the analyzer learns the voice as it goes).
        let reference = LipsyncTimeline(lexicon: { lexicon })
        let wrong = LipsyncTimeline(lexicon: { lexicon })
        let missing = LipsyncTimeline(lexicon: { nil })
        let cancelled = LipsyncTimeline(lexicon: { lexicon })
        await play(reference, freya, text: nil)
        await play(wrong, freya, text: maybe)
        await play(missing, freya, text: whoKnew)
        // A stopped utterance's text does not carry over to the next.
        cancelled.expect(text: whoKnew)
        cancelled.cancel()
        await play(cancelled, freya, text: nil)
        expect(wrong.alignment?.confident == false, "A mismatched text must lose the alignment")
        expect(cancelled.alignment == nil, "Text leaked past a cancel")
        for time in stride(from: 0.1, to: 2.3, by: 0.05) {
            let expected = reference.pose(at: time)
            expect(wrong.pose(at: time) == expected, "A lost alignment must draw the formant mouth at \(time) s")
            expect(missing.pose(at: time) == expected, "Without pronunciations the mouth must follow formants at \(time) s")
            expect(cancelled.pose(at: time) == expected, "Text leaked past a cancel at \(time) s")
        }
    }
}

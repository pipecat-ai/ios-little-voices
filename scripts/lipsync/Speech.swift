import Foundation

// Phonon speech for the lip-sync scripts, through the app's phonon-ffi and its own lip-sync code
// (speech.py builds it).
//   speech pcm <checkpoint> <voice> <text>
//     The sentence's 24 kHz mono Float32 samples, on stdout.
//   speech features <checkpoint> <cmudict.lzma> <voice> <sentence>...
//     JSON on stdout: for each sentence its words (phones and pause) and each hop's level, zero
//     crossings and cepstra c1…c12, measured as LipsyncAligner measures them.

/// One voice of a Phonon checkpoint.
final class Phonon {
    private let model: OpaquePointer

    init(checkpoint: String, voice: String) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard let model = phonon_load(checkpoint, voice, &error, error.count) else {
            throw SpeechError(String(cString: error))
        }
        self.model = model
    }

    deinit { phonon_free(model) }

    func speak(_ text: String) throws -> [Float] {
        final class Sink { var samples: [Float] = [] }
        let sink = Sink()
        let token = phonon_cancellation_new()
        defer { phonon_cancellation_free(token) }
        var error = [CChar](repeating: 0, count: 1024)
        let status = phonon_speak(model, text, 0, token, { pcm, count, context in
            guard let pcm, let context else { return false }
            Unmanaged<Sink>.fromOpaque(context).takeUnretainedValue().samples
                .append(contentsOf: UnsafeBufferPointer(start: pcm, count: count))
            return true
        }, Unmanaged.passUnretained(sink).toOpaque(), &error, error.count)
        guard status == 0 else { throw SpeechError("\(text): \(String(cString: error))") }
        return sink.samples
    }
}

struct SpeechError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
enum Speech {
    static func main() throws {
        let arguments = CommandLine.arguments
        switch arguments.count > 1 ? arguments[1] : "" {
        case "pcm" where arguments.count == 5:
            let samples = try Phonon(checkpoint: arguments[2], voice: arguments[3]).speak(arguments[4])
            FileHandle.standardOutput.write(samples.withUnsafeBufferPointer { Data(buffer: $0) })
        case "features" where arguments.count >= 6:
            guard let lexicon = LipsyncLexicon(compressed: try Data(contentsOf: URL(fileURLWithPath: arguments[3])))
            else { throw SpeechError("The pronunciations did not load") }
            let phonon = try Phonon(checkpoint: arguments[2], voice: arguments[4])
            let sentences = try arguments[5...].map { text -> [String: Any] in
                // As the app feeds the aligner: resampled to 16 kHz, then measured hop by hop.
                let samples = try phonon.speak(text)
                var resampler = LipsyncResampler()
                let audio = resampler.process(samples) + resampler.flush()
                let features = LipsyncAlignerFeatures()
                let hops = features.process(audio) + features.flush()
                let words = lexicon.words(text).map { word -> [String: Any] in
                    let pause = switch word.pause {
                    case .none: ""
                    case .comma: ","
                    case .stop: "."
                    }
                    return ["phones": word.phones.map(\.description), "pause": pause]
                }
                return ["text": text, "words": words, "hops": hops.map { [$0.level, $0.zeroCrossings] + $0.cepstra }]
            }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: sentences))
        default:
            throw SpeechError("usage: speech pcm <checkpoint> <voice> <text>\n"
                              + "       speech features <checkpoint> <cmudict.lzma> <voice> <sentence>...")
        }
    }
}

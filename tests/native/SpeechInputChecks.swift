import AVFoundation
import Foundation
import Speech

struct VoiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []
    private var levels = 0
    private var entered = false
    func fail(_ text: String) { lock.lock(); failures.append(text); lock.unlock() }
    func level() { lock.lock(); levels += 1; lock.unlock() }
    func enter() { lock.lock(); entered = true; lock.unlock() }
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return failures }
    var levelCount: Int { lock.lock(); defer { lock.unlock() }; return levels }
    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
}

@main
enum SpeechInputChecks {
    /// Microphone audio, and the 16-bit format SpeechAnalyzer requires for ASR input.
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                     channels: 1, interleaved: false)!
    static let asrFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                        channels: 1, interleaved: false)!

    static func buffer(_ index: Int, frames: AVAudioFrameCount = 320) -> AVAudioPCMBuffer {
        let value = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        value.frameLength = frames
        value.floatChannelData![0].initialize(repeating: Float(index + 1) / 200, count: Int(frames))
        return value
    }

    /// The first ASR sample, which identifies the microphone buffer it came from.
    /// Only fixtures inspect samples (via the deprecated `buffer`); the app reads
    /// AnalyzerInput's duration and format.
    static func firstSample(_ frame: AnalyzerInput) -> Float {
        let buffer = frame.buffer
        return withExtendedLifetime(buffer) { Float(buffer.int16ChannelData![0][0]) / 32_768 }
    }

    static func matches(_ frame: AnalyzerInput, _ index: Int) -> Bool {
        abs(firstSample(frame) - Float(index + 1) / 200) < 0.000_1
    }

    static func wait(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw VoiceError(message: "Timed out waiting for \(label)")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    static func main() async throws {
        // Freeze the classifier while the real converter and ASR input process
        // over two seconds of audio, including an endpoint rotation. The old
        // shared processing queue blocked here and exhausted its 12 tap slots.
        let observed = Observations()
        let releaseVAD = DispatchSemaphore(value: 0)
        let (first, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(192))
        let capture = try SpeechAudioInput(sourceFormat: format, format: asrFormat, input: input,
            onVAD: { _, _, _ in }, onLevel: { _ in observed.level() }, onError: { observed.fail($0) },
            vadAnalysis: { _, _ in
                if !observed.hasEntered { observed.enter(); releaseVAD.wait() }
            })
        defer { capture.cancel(); releaseVAD.signal() }
        capture.consume(buffer(0))
        try await wait("classifier start; errors=\(observed.errors)") { observed.hasEntered }
        for batch in 0..<5 {
            for offset in 0..<20 { capture.consume(buffer(1 + batch * 20 + offset)) }
            try await wait("capture drain") { capture.snapshot.pendingSeconds < 0.000_001 || !observed.errors.isEmpty }
            precondition(observed.errors.isEmpty, "Classifier stalled lossless ASR: \(observed.errors)")
            precondition(capture.snapshot.vad!.pendingSeconds <= 0.500_001)
        }
        precondition(capture.snapshot.asrBufferedAtLastYield == 101)
        precondition(capture.snapshot.peakASRBufferedBuffers == 101)
        precondition(capture.snapshot.asrBufferCapacity == 192)
        precondition(abs(capture.snapshot.asrFrameSeconds - 0.02) < 0.000_001)
        precondition(capture.snapshot.asrSampleRate == 16_000)
        try await capture.pauseASR()
        var received: [AnalyzerInput] = []
        for await frame in first { received.append(frame) }
        precondition(received.count == 101)
        for (index, frame) in received.enumerated() {
            precondition(abs(frame.bufferDuration.seconds - 0.02) < 0.000_001)
            precondition(frame.bufferFormat.commonFormat == .pcmFormatInt16)
            precondition(abs(frame.bufferStartTime!.seconds - Double(index) * 0.02) < 0.000_001)
            precondition(matches(frame, index))
        }
        precondition(capture.snapshot.vad!.discardedBuffers > 0)
        precondition(capture.snapshot.vad!.discardedSeconds > 1)

        // Capture arriving during ASR handoff is replayed into the replacement in
        // order, on the same timeline, while VAD is still blocked.
        for index in 101..<106 { capture.consume(buffer(index)) }
        try await wait("capture drain") { capture.snapshot.pendingSeconds < 0.000_001 }
        let (second, replacement) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(192))
        try await capture.resumeASR(replacement)
        for index in 106..<111 { capture.consume(buffer(index)) }
        try await capture.pauseASR()
        var retained: [AnalyzerInput] = []
        for await frame in second { retained.append(frame) }
        precondition(retained.count == 10)
        for (offset, frame) in retained.enumerated() {
            precondition(abs(frame.bufferStartTime!.seconds - Double(101 + offset) * 0.02) < 0.000_001)
            precondition(matches(frame, 101 + offset))
        }
        precondition(observed.errors.isEmpty)
        precondition(observed.levelCount <= 67)
        capture.cancel()
        precondition(capture.snapshot.vad!.pendingSeconds == 0)
        releaseVAD.signal()

        // A stale classification is ignored, never converted to a silence score.
        let classifier = SpeechVADQueue(analyze: { _, _ in })
        classifier.captured(through: 10)
        precondition(!classifier.acceptsResult(endingAt: 9.49))
        precondition(!classifier.acceptsResult(endingAt: .nan))
        precondition(classifier.acceptsResult(endingAt: 9.6))
        precondition(classifier.snapshot.staleResults == 2)
        classifier.cancel()
        precondition(!classifier.acceptsResult(endingAt: 10))

        // Persistent ASR consumer backpressure remains an explicit failure.
        let blockedASR = Observations()
        let (slowStream, slowInput) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(2))
        defer { withExtendedLifetime(slowStream) {} }
        let slowCapture = try SpeechAudioInput(sourceFormat: format, format: asrFormat, input: slowInput,
            onVAD: { _, _, _ in }, onLevel: { _ in }, onError: { blockedASR.fail($0) },
            vadAnalysis: { _, _ in }, asrBufferCapacity: 2)
        for index in 0..<5 { slowCapture.consume(buffer(index)) }
        try await wait("ASR overload") { !blockedASR.errors.isEmpty }
        precondition(blockedASR.errors.count == 1 && blockedASR.errors[0].contains("Speech recognition fell behind"))
        precondition(slowCapture.snapshot.asrBufferedAtLastYield == 2)
        precondition(slowCapture.snapshot.peakASRBufferedBuffers == 2)
        slowCapture.cancel()

        // Admission is measured in audio seconds, independent of tap chunk size.
        // Block conversion's callback to simulate a genuinely overloaded worker.
        let blockedCapture = Observations()
        let releaseCapture = DispatchSemaphore(value: 0)
        let (heldStream, heldInput) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(192))
        defer { withExtendedLifetime(heldStream) {} }
        let heldCapture = try SpeechAudioInput(sourceFormat: format, format: asrFormat, input: heldInput,
            onVAD: { _, _, _ in }, onLevel: { _ in
                if !blockedCapture.hasEntered { blockedCapture.enter(); releaseCapture.wait() }
            }, onError: { blockedCapture.fail($0) }, vadAnalysis: { _, _ in })
        defer { heldCapture.cancel(); releaseCapture.signal() }
        heldCapture.consume(buffer(0, frames: 160))
        try await wait("capture stall") { blockedCapture.hasEntered }
        for index in 1..<75 { heldCapture.consume(buffer(index, frames: 160)) }
        precondition(blockedCapture.errors.isEmpty)
        precondition(abs(heldCapture.snapshot.pendingSeconds - 0.75) < 0.000_001)
        heldCapture.consume(buffer(75, frames: 160))
        precondition(blockedCapture.errors.count == 1 && blockedCapture.errors[0].contains("Microphone processing fell behind"))
        heldCapture.cancel()
        releaseCapture.signal()

        // Holding to talk: closed ASR keeps only the pre-roll, for as long as it stays closed,
        // and a press replays it ahead of live audio on the same timeline, or skips it.
        let held = Observations()
        let pushToTalk = try SpeechAudioInput(sourceFormat: format, format: asrFormat, input: nil,
            onVAD: { _, _, _ in held.fail("speech was scored") }, onLevel: { _ in },
            onError: { held.fail($0) }, classifiesSpeech: false)
        defer { pushToTalk.cancel() }
        // Within the capture budget: a batch at a time, as a microphone delivers them.
        func speak(_ indices: Range<Int>) async throws {
            for batch in stride(from: indices.lowerBound, to: indices.upperBound, by: 20) {
                for index in batch..<min(batch + 20, indices.upperBound) { pushToTalk.consume(buffer(index)) }
                try await wait("capture drain; errors=\(held.errors)") {
                    pushToTalk.snapshot.pendingSeconds < 0.000_001 || !held.errors.isEmpty
                }
            }
        }
        try await speak(0..<60)
        let (pressed, pressedInput) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(192))
        try await pushToTalk.resumeASR(pressedInput)
        try await speak(60..<65)
        try await pushToTalk.closeASR()
        var spoken: [AnalyzerInput] = []
        for await frame in pressed { spoken.append(frame) }
        let preRoll = Int(SpeechAudioInput.preRollSeconds / 0.02)
        precondition(spoken.count == preRoll + 5, "\(spoken.count) frames after a press")
        for (offset, frame) in spoken.enumerated() {
            precondition(abs(frame.bufferStartTime!.seconds - Double(60 - preRoll + offset) * 0.02) < 0.000_001)
            precondition(matches(frame, 60 - preRoll + offset))
        }
        try await speak(65..<120)
        let (cut, cutInput) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(192))
        try await pushToTalk.resumeASR(cutInput, replaying: false)
        try await speak(120..<121)
        try await pushToTalk.pauseASR()
        var live: [AnalyzerInput] = []
        for await frame in cut { live.append(frame) }
        precondition(live.count == 1 && matches(live[0], 120))
        precondition(held.errors.isEmpty, "\(held.errors)")
        print("SPEECH_INPUT_CHECKS_PASSED: blocked classifier preserves ASR and handoff, VAD shedding/staleness bounded, capture and ASR overflow explicit, push-to-talk pre-roll")
    }
}

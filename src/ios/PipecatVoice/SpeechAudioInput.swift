import AVFoundation
import SoundAnalysis
import Speech

// AVAudioConverter calls its provider synchronously on the capture processing queue.
private final class ConverterInput {
    let buffer: AVAudioPCMBuffer
    var consumed = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

private final class SpeechConfidenceObserver: NSObject, SNResultsObserving {
    let onResult: (Double, Double) -> Void
    let onError: (String) -> Void

    init(onResult: @escaping (Double, Double) -> Void, onError: @escaping (String) -> Void) {
        self.onResult = onResult
        self.onError = onError
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let confidence = result.classification(forIdentifier: "speech")?.confidence ?? 0
        onResult(confidence, result.timeRange.end.seconds)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        onError(error.localizedDescription)
    }
}

/// SoundAnalysis may block for model backpressure. Keep that work away from ASR,
/// retaining only a recent half-second of waiting VAD audio when it falls behind.
/// Sample positions stay absolute; a gap never becomes fabricated silence.
final class SpeechVADQueue: @unchecked Sendable {
    struct Snapshot: Sendable {
        let pendingSeconds: Double
        let discardedBuffers: Int
        let discardedSeconds: Double
        let staleResults: Int
        let maximumAnalysisSeconds: Double
    }

    private struct Input {
        let buffer: AVAudioPCMBuffer
        let start: AVAudioFramePosition
        let duration: Double
    }

    private let queue = DispatchQueue(label: "voice.apple.vad", qos: .userInitiated)
    private let lock = NSLock()
    private let analyze: (AVAudioPCMBuffer, AVAudioFramePosition) -> Void
    private let removeRequests: () -> Void
    private var active = true
    private var running = false
    private var pending: [Input] = []
    private var pendingSeconds = 0.0
    private var latestCaptureTime = 0.0
    private var discardedBuffers = 0
    private var discardedSeconds = 0.0
    private var staleResults = 0
    private var maximumAnalysisSeconds = 0.0
    private let maximumPendingSeconds = 0.5

    init(analyze: @escaping (AVAudioPCMBuffer, AVAudioFramePosition) -> Void,
         removeRequests: @escaping () -> Void = {}) {
        self.analyze = analyze
        self.removeRequests = removeRequests
    }

    func captured(through time: Double) {
        lock.lock()
        latestCaptureTime = max(latestCaptureTime, time)
        lock.unlock()
    }

    func acceptsResult(endingAt time: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return false }
        guard time.isFinite, time >= 0,
              latestCaptureTime - time <= maximumPendingSeconds else {
            staleResults += 1
            return false
        }
        return true
    }

    func submit(_ buffer: AVAudioPCMBuffer, at start: AVAudioFramePosition) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        guard duration.isFinite, duration > 0 else { return }
        lock.lock()
        guard active else { lock.unlock(); return }
        pending.append(Input(buffer: buffer, start: start, duration: duration))
        pendingSeconds += duration
        while pendingSeconds > maximumPendingSeconds + 0.000_001, !pending.isEmpty {
            let discarded = pending.removeFirst()
            pendingSeconds -= discarded.duration
            discardedBuffers += 1
            discardedSeconds += discarded.duration
        }
        let shouldStart = !running && !pending.isEmpty
        if shouldStart { running = true }
        lock.unlock()
        if shouldStart { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard active, !pending.isEmpty else {
                running = false
                lock.unlock()
                return
            }
            let next = pending.removeFirst()
            pendingSeconds = max(0, pendingSeconds - next.duration)
            lock.unlock()
            let began = ProcessInfo.processInfo.systemUptime
            analyze(next.buffer, next.start)
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            lock.lock()
            maximumAnalysisSeconds = max(maximumAnalysisSeconds, elapsed)
            lock.unlock()
        }
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(pendingSeconds: pendingSeconds, discardedBuffers: discardedBuffers,
                        discardedSeconds: discardedSeconds, staleResults: staleResults,
                        maximumAnalysisSeconds: maximumAnalysisSeconds)
    }

    func cancel() {
        lock.lock()
        active = false
        pending.removeAll()
        pendingSeconds = 0
        lock.unlock()
        queue.async { [removeRequests] in removeRequests() }
    }
}

/// Conversion and lossless ASR delivery run independently of the bounded VAD
/// worker. The lock protects capture admission and callback snapshots only.
final class SpeechAudioInput: @unchecked Sendable {
    static let asrBufferCapacity = 192
    /// The audio kept while ASR is closed, between pushes to talk: a word begun with the press is
    /// heard from its start.
    static let preRollSeconds = 0.3

    struct Snapshot: Sendable {
        let capturedSeconds: Double
        let pendingSeconds: Double
        let peakPendingSeconds: Double
        let peakProcessingSeconds: Double
        // AsyncStream reports capacity at each yield; this is not a live count
        // after its consumer advances without another microphone buffer.
        let asrBufferedAtLastYield: Int
        let peakASRBufferedBuffers: Int
        let asrBufferCapacity: Int
        let asrFrameSeconds: Double
        let asrSampleRate: Double
        let vad: SpeechVADQueue.Snapshot?
    }

    private let queue = DispatchQueue(label: "voice.apple.audio", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true
    private var volume = 0.0
    private var pendingSeconds = 0.0
    private var capturedSeconds = 0.0
    private var maximumPendingSeconds = 0.0
    private var maximumProcessingSeconds = 0.0
    private var asrBufferedAtLastYield = 0
    private var peakASRBufferedBuffers = 0
    private var asrFrameSeconds = 0.0
    private let asrCapacity: Int
    private var lastLevelTime = -Double.infinity
    private let captureBudgetSeconds = 0.75
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private var vad: SpeechVADQueue!
    private var observer: SpeechConfidenceObserver!
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var retained: [AnalyzerInput] = []
    private var retainedFrames = 0
    /// ASR is closed (`closeASR`): only the pre-roll is retained.
    private var closed = false
    private var position: AVAudioFramePosition = 0
    private var energies: [(end: Double, duration: Double, energy: Double)] = []
    private let onVAD: @Sendable (Double, Double, Double) -> Void
    private let onLevel: @Sendable (Double) -> Void
    private let onError: @Sendable (String) -> Void

    /// `input` nil starts with ASR closed. Without `classifiesSpeech`, nothing scores speech and
    /// `onVAD` is never called, as when a push to talk marks the human's turns.
    init(sourceFormat: AVAudioFormat, format: AVAudioFormat,
         input: AsyncStream<AnalyzerInput>.Continuation?,
         onVAD: @escaping @Sendable (Double, Double, Double) -> Void,
         onLevel: @escaping @Sendable (Double) -> Void,
         onError: @escaping @Sendable (String) -> Void,
         classifiesSpeech: Bool = true,
         vadAnalysis: ((AVAudioPCMBuffer, AVAudioFramePosition) -> Void)? = nil,
         asrBufferCapacity: Int = SpeechAudioInput.asrBufferCapacity) throws {
        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw VoiceError(message: "The microphone cannot supply the speech recognition audio format.")
        }
        self.converter = converter
        self.format = format
        self.asrCapacity = asrBufferCapacity
        self.input = input
        closed = input == nil
        self.onVAD = onVAD
        self.onLevel = onLevel
        self.onError = onError
        // A supplied analysis kernel lets native fixtures exercise real capture
        // conversion and backpressure with a deterministic classifier stall.
        if let vadAnalysis {
            vad = SpeechVADQueue(analyze: vadAnalysis)
            return
        }
        guard classifiesSpeech else {
            vad = SpeechVADQueue(analyze: { _, _ in })
            return
        }
        let soundAnalyzer = SNAudioStreamAnalyzer(format: format)
        // SpeechAnalyzer's detector publishes no activity results, so SoundAnalysis's
        // classifier supplies the speech probabilities.
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 16_000)
        request.overlapFactor = 0.8
        observer = SpeechConfidenceObserver(onResult: { [weak self] confidence, time in
            guard let self else { return }
            self.lock.lock()
            let active = self.active
            let volume = self.volume
            self.lock.unlock()
            if active, self.vad.acceptsResult(endingAt: time) {
                self.onVAD(confidence, time, volume)
            }
        }, onError: { [weak self] message in self?.fail(message) })
        try soundAnalyzer.add(request, withObserver: observer)
        vad = SpeechVADQueue(analyze: { buffer, start in
            soundAnalyzer.analyze(buffer, atAudioFramePosition: start)
        }, removeRequests: { soundAnalyzer.removeAllRequests() })
    }

    private var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        guard duration.isFinite, duration > 0 else { return }
        lock.lock()
        guard active else { lock.unlock(); return }
        capturedSeconds += duration
        let capturedTime = capturedSeconds
        guard pendingSeconds + duration <= captureBudgetSeconds + 0.000_001 else {
            lock.unlock()
            fail("Microphone processing fell behind. Tap the microphone to start again.", stage: "capture")
            return
        }
        pendingSeconds += duration
        maximumPendingSeconds = max(maximumPendingSeconds, pendingSeconds)
        lock.unlock()
        vad.captured(through: capturedTime)
        // Tap buffers are owned by AVAudioEngine and may be reused after this call.
        guard let copied = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            release(duration: duration, processingSeconds: 0)
            fail("Could not allocate the microphone audio buffer.")
            return
        }
        copied.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        queue.async { [self] in
            let began = ProcessInfo.processInfo.systemUptime
            defer { release(duration: duration, processingSeconds: ProcessInfo.processInfo.systemUptime - began) }
            guard isActive else { return }
            do { try process(copied) }
            catch { fail(error.localizedDescription) }
        }
    }

    private func release(duration: Double, processingSeconds: Double) {
        lock.lock()
        pendingSeconds = max(0, pendingSeconds - duration)
        maximumProcessingSeconds = max(maximumProcessingSeconds, processingSeconds)
        lock.unlock()
    }

    private func process(_ buffer: AVAudioPCMBuffer) throws {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw VoiceError(message: "Could not allocate converted microphone audio.")
        }
        let source = ConverterInput(buffer)
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if source.consumed { status.pointee = .noDataNow; return nil }
            source.consumed = true
            status.pointee = .haveData
            return source.buffer
        }
        if let conversionError { throw conversionError }
        guard converted.frameLength > 0 else { return }
        let start = position
        position += AVAudioFramePosition(converted.frameLength)
        let time = Double(position) / format.sampleRate
        let duration = Double(converted.frameLength) / format.sampleRate
        let energy = Self.meanSquare(converted)
        energies.append((time, duration, energy))
        energies.removeAll { $0.end < time - 0.5 }
        let totalDuration = energies.reduce(0.0) { $0 + $1.duration }
        let meanEnergy = energies.reduce(0.0) { $0 + $1.energy * $1.duration } / max(totalDuration, 0.001)
        // An RMS approximation using Pipecat's [-110, -10] loudness normalization;
        // the classifier, rather than this level gate, decides whether this is speech.
        let loudness = meanEnergy > 1e-12 ? min(1, max(0, (10 * log10(meanEnergy) + 110) / 100)) : 0
        lock.lock()
        volume = loudness
        lock.unlock()
        // The UI does not need a MainActor task for every hardware callback.
        if time - lastLevelTime >= 1.0 / 30 {
            lastLevelTime = time
            onLevel(min(1, sqrt(energy) * 7))
        }
        let frame = AnalyzerInput(buffer: converted,
                                  bufferStartTime: CMTime(value: start, timescale: CMTimeScale(format.sampleRate)))
        if let input {
            try deliver(frame, to: input)
        } else {
            retained.append(frame)
            retainedFrames += Int(converted.frameLength)
            if closed { trimToPreRoll() }
            guard retainedFrames <= Int(format.sampleRate * 4) else {
                throw VoiceError(message: "Speech recognition took too long to finish your turn. Tap the microphone to start again.")
            }
        }
        vad.submit(converted, at: start)
    }

    private func deliver(_ frame: AnalyzerInput, to input: AsyncStream<AnalyzerInput>.Continuation) throws {
        let result = input.yield(frame)
        let buffered: Int
        switch result {
        case .enqueued(let remainingCapacity): buffered = max(0, asrCapacity - remainingCapacity)
        case .dropped: buffered = asrCapacity
        case .terminated: buffered = 0
        @unknown default: buffered = 0
        }
        lock.lock()
        asrBufferedAtLastYield = buffered
        peakASRBufferedBuffers = max(peakASRBufferedBuffers, buffered)
        asrFrameSeconds = frame.bufferDuration.seconds
        lock.unlock()
        if case .dropped = result {
            logMetrics(stage: "asr")
            throw VoiceError(message: "Speech recognition fell behind the microphone. Tap the microphone to start again.")
        }
    }

    /// End only the current ASR input. Capture and acoustic VAD keep running, and
    /// all subsequent audio is retained until the replacement transcriber is ready.
    func pauseASR() async throws {
        try await endASR(closing: false)
    }

    /// End the current ASR input between pushes to talk, retaining only the latest
    /// `preRollSeconds` of what follows.
    func closeASR() async throws {
        try await endASR(closing: true)
    }

    private func endASR(closing: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard isActive else { continuation.resume(throwing: CancellationError()); return }
                input?.finish()
                input = nil
                closed = closing
                if closing { trimToPreRoll() }
                continuation.resume()
            }
        }
    }

    /// Feed `continuation` the retained audio, unless `replaying` is false, then all that follows.
    func resumeASR(_ continuation: AsyncStream<AnalyzerInput>.Continuation, replaying: Bool = true) async throws {
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard isActive else {
                    continuation.finish()
                    completion.resume(throwing: CancellationError())
                    return
                }
                do {
                    if replaying { for frame in retained { try deliver(frame, to: continuation) } }
                    retained.removeAll(keepingCapacity: true)
                    retainedFrames = 0
                    input = continuation
                    closed = false
                    completion.resume()
                } catch { completion.resume(throwing: error) }
            }
        }
    }

    private func trimToPreRoll() {
        let limit = Int(format.sampleRate * Self.preRollSeconds)
        while let first = retained.first {
            let frames = Int((first.bufferDuration.seconds * format.sampleRate).rounded())
            guard retainedFrames - frames >= limit else { break }
            retained.removeFirst()
            retainedFrames -= frames
        }
    }

    func cancel() {
        lock.lock()
        active = false
        lock.unlock()
        vad.cancel()
        logMetrics(stage: "stopped")
        queue.async { [self] in
            input?.finish()
            input = nil
            retained.removeAll()
        }
    }

    private func fail(_ message: String, stage: String = "analysis") {
        lock.lock()
        let shouldReport = active
        active = false
        lock.unlock()
        if shouldReport {
            logMetrics(stage: stage)
            vad?.cancel()
            onError(message)
        }
    }

    var snapshot: Snapshot {
        lock.lock()
        let captured = capturedSeconds
        let pending = pendingSeconds
        let peakPending = maximumPendingSeconds
        let peakProcessing = maximumProcessingSeconds
        let asrBuffered = asrBufferedAtLastYield
        let peakASRBuffered = peakASRBufferedBuffers
        let frameSeconds = asrFrameSeconds
        lock.unlock()
        return Snapshot(capturedSeconds: captured, pendingSeconds: pending,
                        peakPendingSeconds: peakPending, peakProcessingSeconds: peakProcessing,
                        asrBufferedAtLastYield: asrBuffered, peakASRBufferedBuffers: peakASRBuffered,
                        asrBufferCapacity: asrCapacity, asrFrameSeconds: frameSeconds,
                        asrSampleRate: format.sampleRate, vad: vad?.snapshot)
    }

    func logMetrics(stage: String) {
        #if DEBUG
        let stats = snapshot
        print("SPEECH_INPUT: stage=\(stage), uptime_s=\(ProcessInfo.processInfo.systemUptime), captured_s=\(stats.capturedSeconds), pending_s=\(stats.pendingSeconds), peak_pending_s=\(stats.peakPendingSeconds), peak_processing_s=\(stats.peakProcessingSeconds), asr_buffered_at_last_yield=\(stats.asrBufferedAtLastYield), asr_peak_buffers=\(stats.peakASRBufferedBuffers), asr_capacity=\(stats.asrBufferCapacity), asr_frame_s=\(stats.asrFrameSeconds), asr_sample_rate=\(stats.asrSampleRate), vad_pending_s=\(stats.vad?.pendingSeconds ?? 0), vad_dropped_buffers=\(stats.vad?.discardedBuffers ?? 0), vad_dropped_s=\(stats.vad?.discardedSeconds ?? 0), vad_stale_results=\(stats.vad?.staleResults ?? 0), vad_peak_processing_s=\(stats.vad?.maximumAnalysisSeconds ?? 0)")
        #endif
    }

    private static func meanSquare(_ buffer: AVAudioPCMBuffer) -> Double {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        if let samples = buffer.floatChannelData?[0] {
            return UnsafeBufferPointer(start: samples, count: count).reduce(0.0) { $0 + Double($1 * $1) } / Double(count)
        }
        if let samples = buffer.int16ChannelData?[0] {
            return UnsafeBufferPointer(start: samples, count: count).reduce(0.0) {
                let value = Double($1) / 32768
                return $0 + value * value
            } / Double(count)
        }
        return 0
    }
}

import AVFoundation
import OSLog
import Speech

@MainActor
private final class RecognitionSession {
    let analyzer: SpeechAnalyzer
    let input: AsyncStream<AnalyzerInput>.Continuation
    let results: Task<Void, Error>

    init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, results: Task<Void, Error>) {
        self.analyzer = analyzer
        self.input = input
        self.results = results
    }

    func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        results.cancel()
    }
}

@MainActor
final class AppleSpeechRecognizer {
    private let audio: VoiceAudioEngine
    private var session: RecognitionSession?
    private var capture: SpeechAudioInput?
    private var format: AVAudioFormat?
    private var locale: Locale?
    private var finalizationTask: Task<Void, Error>?
    private var epoch = UUID()
    private let logger = Logger(subsystem: "ai.pipecat.voice", category: "Speech")
    var onTranscript: ((String, Bool, Double, Double) -> Void)?
    var onVAD: ((Double, Double, Double) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onError: ((String) -> Void)?

    init(audio: VoiceAudioEngine) { self.audio = audio }

    func logAudioMetrics(stage: String) { capture?.logMetrics(stage: stage) }

    /// Start recognizing on a fresh input generation: callbacks from an earlier one are dropped.
    func start() async throws {
        let generation = UUID()
        let previous = resetCapture(generation: generation)
        await previous?.cancel()
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw VoiceError(message: "Little Voices needs your microphone to hear you. Allow it in Settings › Apps › "
                + "Little Voices, then try again.")
        }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            #if targetEnvironment(simulator)
            throw VoiceError(message: "Apple’s on-device speech recognition doesn’t run in the Simulator. Run on an "
                + "iPhone to talk, or launch with --preview-duo to watch a scripted conversation.")
            #else
            throw VoiceError(message: "This device can’t recognize English speech on the device.")
            #endif
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            do { try await request.downloadAndInstall() }
            catch is CancellationError { throw CancellationError() }
            catch {
                logger.error("Speech assets failed to install: \(error.localizedDescription, privacy: .public)")
                throw VoiceError(message: "Apple’s English speech recognition couldn’t download. Check your "
                    + "connection and free storage, then try again.")
            }
        }
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        let hardware = try audio.microphoneFormat()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: hardware) else {
            throw VoiceError(message: "No audio format is available for speech recognition.")
        }
        self.format = format
        self.locale = locale
        let session = try await makeSession(transcriber: transcriber, format: format, generation: generation)
        guard epoch == generation, !Task.isCancelled else {
            await session.cancel()
            throw CancellationError()
        }
        self.session = session
        do {
            let capture = try SpeechAudioInput(sourceFormat: hardware, format: format, input: session.input,
                onVAD: { [weak self] confidence, time, volume in
                    Task { @MainActor in
                        guard let self, self.epoch == generation else { return }
                        self.onVAD?(confidence, time, volume)
                    }
                }, onLevel: { [weak self] level in
                    Task { @MainActor in
                        guard let self, self.epoch == generation else { return }
                        self.onLevel?(level)
                    }
                }, onError: { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.epoch == generation else { return }
                        self.onError?(message)
                    }
                })
            self.capture = capture
            try audio.startCapture { buffer, _ in capture.consume(buffer) }
        } catch {
            if epoch == generation { await stop() }
            throw error
        }
    }

    private func makeSession(transcriber: SpeechTranscriber, format: AVAudioFormat,
                             generation: UUID) async throws -> RecognitionSession {
        let analyzer = SpeechAnalyzer(modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(SpeechAudioInput.asrBufferCapacity))
        let results = Task(priority: .userInitiated) { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.epoch == generation else { return }
                    self.onTranscript?(String(result.text.characters), result.isFinal,
                                       result.range.start.seconds, result.range.end.seconds)
                }
            } catch is CancellationError { }
            catch {
                if let self, self.epoch == generation {
                    self.logger.error("Speech recognition failed: \(error.localizedDescription, privacy: .public)")
                    self.onError?("Speech recognition stopped. Tap the microphone to start again.")
                }
                throw error
            }
        }
        do { try await analyzer.start(inputSequence: stream) }
        catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw error
        }
        return RecognitionSession(analyzer: analyzer, input: continuation, results: results)
    }

    /// Finish an utterance without ending capture or VAD. Apple finalize(through:)
    /// publishes results but offers no consumer barrier. Rotating only the ASR
    /// session lets us await its result stream before acknowledging the endpoint.
    func finalize() async throws {
        let generation = epoch
        // An earlier endpoint may still be rotating ASR after resumed speech
        // cancelled its request. Its replacement contains newer audio; this
        // endpoint must finalize that audio too before acknowledging the turn.
        while let finalizationTask {
            try await finalizationTask.value
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard let capture, let previous = session, let format, let locale else {
            throw CancellationError()
        }
        // This unstructured task survives cancellation of the Python request that
        // asked for finalization, so resumed user speech cannot strand capture.
        let task = Task(priority: .userInitiated) { [weak self] in
            guard let self else { throw CancellationError() }
            // Clear ownership before awaiting callers resume. An older caller
            // must never clear a newer rotation's task after it has started.
            defer { if self.epoch == generation { self.finalizationTask = nil } }
            let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            let replacement = try await self.makeSession(transcriber: transcriber, format: format, generation: generation)
            do {
                guard self.epoch == generation, !Task.isCancelled else { throw CancellationError() }
                // Cut at the newest captured audio, including any trailing words
                // after the VAD window. Future input is buffered on the same clock.
                try await capture.pauseASR()
                try await previous.analyzer.finalizeAndFinishThroughEndOfInput()
                try await previous.results.value
                guard self.epoch == generation, !Task.isCancelled else { throw CancellationError() }
                self.session = replacement
                try await capture.resumeASR(replacement.input)
            } catch {
                await replacement.cancel()
                throw error
            }
        }
        finalizationTask = task
        try await task.value
    }

    func stop() async {
        let previous = resetCapture(generation: UUID())
        await previous?.cancel()
    }

    private func resetCapture(generation: UUID) -> RecognitionSession? {
        epoch = generation
        audio.stopCapture()
        capture?.cancel()
        capture = nil
        let previous = session
        session = nil
        format = nil
        locale = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        onLevel?(0)
        return previous
    }
}

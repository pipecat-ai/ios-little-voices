import AVFoundation

/// One engine for capture and playback, with echo cancellation verified before use.
@MainActor
final class VoiceAudioEngine {
    private enum EchoCancellation: String {
        case nativeInput = "native-input"
        case voiceProcessing = "voice-processing"
    }

    private let engine = AVAudioEngine()
    private var hasCaptureTap = false
    /// Reported when the engine starts, so construction stays non-throwing.
    private var connectionError: Error?
    private var captureFormat: AVAudioFormat?
    private var echoCancellation: EchoCancellation?

    var inputPickerSession: AVAudioSession? {
        echoCancellation == nil ? nil : AVAudioSession.sharedInstance()
    }

    /// Prefers echo-cancelled input, which keeps the default mode; falls back to voice processing.
    func configureSession(preservingInput selectedInput: AVAudioSessionPortDescription? = nil) throws {
        guard !engine.isRunning, !hasCaptureTap else {
            throw VoiceError(message: "Stop the conversation before configuring audio.")
        }
        echoCancellation = nil
        let session = AVAudioSession.sharedInstance()
        do {
            // VoiceProcessingIO implicitly enables a chat mode. Disable it before
            // selecting default mode, including when restarting after a fallback.
            if engine.inputNode.isVoiceProcessingEnabled {
                try engine.inputNode.setVoiceProcessingEnabled(false)
            }
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
            try restoreInput(selectedInput, in: session)
            if session.isEchoCancelledInputAvailable {
                do {
                    try session.setPrefersEchoCancelledInput(true)
                    try session.setActive(true)
                    // A preference is not a guarantee: route and active-session
                    // compatibility decide whether the system actually honors it.
                    if session.isEchoCancelledInputEnabled {
                        echoCancellation = .nativeInput
                        logConfiguration("configured")
                        return
                    }
                } catch {
                    #if DEBUG
                    print("AUDIO_SESSION: native input AEC unavailable: \(error.localizedDescription)")
                    #endif
                }
            }

            // Never capture speaker output without AEC if the native path fails.
            if session.prefersEchoCancelledInput {
                try session.setPrefersEchoCancelledInput(false)
            }
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
            try restoreInput(selectedInput, in: session)
            try session.setActive(true)
            try engine.inputNode.setVoiceProcessingEnabled(true)
            try restoreInput(selectedInput, in: session)
            guard engine.inputNode.isVoiceProcessingEnabled else {
                throw VoiceError(message: "Echo cancellation couldn’t start for this microphone. Try another microphone or headset.")
            }
            echoCancellation = .voiceProcessing
            logConfiguration("configured")
        } catch {
            stop()
            throw error
        }
    }

    private func restoreInput(_ selectedInput: AVAudioSessionPortDescription?, in session: AVAudioSession) throws {
        guard let selectedInput else { return }
        if session.preferredInput?.uid == selectedInput.uid,
           session.currentRoute.inputs.contains(where: { $0.uid == selectedInput.uid }) { return }
        guard let input = session.availableInputs?.first(where: { $0.uid == selectedInput.uid }) else {
            throw VoiceError(message: "The selected microphone is no longer available. Choose another microphone and try again.")
        }
        try session.setPreferredInput(input)
    }

    func attach(_ player: AVAudioPlayerNode, format: AVAudioFormat) {
        engine.attach(player)
        do { try engine.connectNode(player, to: engine.mainMixerNode, format: format) }
        catch { connectionError = error }
    }

    func microphoneFormat() throws -> AVAudioFormat {
        try validateConfiguration()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceError(message: "No microphone is available. Connect one, then try again.")
        }
        return format
    }

    func startCapture(_ handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws {
        stopCapture()
        let format = try microphoneFormat()
        // Consumers keep buffers beyond the callback, so each read-only tap buffer is copied.
        try engine.inputNode.installAudioTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            handler(AVAudioPCMBuffer(copying: buffer), time)
        }
        hasCaptureTap = true
        captureFormat = format
        do { try start() }
        catch { stopCapture(); throw error }
    }

    func start() throws {
        if let connectionError { throw connectionError }
        _ = try microphoneFormat()
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
                try validateConfiguration()
            } catch {
                engine.stop()
                throw error
            }
        }
    }

    /// Why capture can't continue on the new route as configured; nil when it can.
    func routeChangeError() -> String? {
        guard echoCancellation != nil else { return nil }
        logConfiguration("route changed")
        do {
            try validateConfiguration()
            if let captureFormat, !captureFormat.isEqual(engine.inputNode.outputFormat(forBus: 0)) {
                return "The microphone changed. Tap the microphone to start again."
            }
            return nil
        }
        catch { return error.localizedDescription }
    }

    private func validateConfiguration() throws {
        switch echoCancellation {
        case .nativeInput:
            let session = AVAudioSession.sharedInstance()
            guard session.isEchoCancelledInputEnabled, session.mode == .default,
                  !engine.inputNode.isVoiceProcessingEnabled else {
                throw VoiceError(message: "The new audio route changed echo cancellation. Tap the microphone to start again.")
            }
        case .voiceProcessing:
            guard engine.inputNode.isVoiceProcessingEnabled else {
                throw VoiceError(message: "Echo cancellation stopped. Tap the microphone to start again.")
            }
        case nil:
            throw VoiceError(message: "The conversation audio session is not configured.")
        }
    }

    private func logConfiguration(_ context: String) {
        #if DEBUG
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("AUDIO_SESSION: \(context), path=\(echoCancellation?.rawValue ?? "none"), mode=\(session.mode.rawValue), native_available=\(session.isEchoCancelledInputAvailable), native_enabled=\(session.isEchoCancelledInputEnabled), input=\(inputs), output=\(outputs), rate=\(session.sampleRate)")
        #endif
    }

    /// Stops capture; playback keeps running.
    func stopCapture() {
        if hasCaptureTap {
            engine.inputNode.removeTap(onBus: 0)
            hasCaptureTap = false
        }
        captureFormat = nil
    }

    /// Stops the engine but keeps the session active while the input picker is open.
    func suspendForRouteChange() {
        stopCapture()
        engine.stop()
    }

    func stop() {
        suspendForRouteChange()
        echoCancellation = nil
        let session = AVAudioSession.sharedInstance()
        if session.prefersEchoCancelledInput { try? session.setPrefersEchoCancelledInput(false) }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    #if DEBUG
    private var outputRecording: OutputRecording?

    /// Record everything the engine plays to `url`, for a demo's soundtrack. `started` is given the
    /// wall-clock time the first recorded sample was rendered.
    func recordOutput(to url: URL, started: @escaping @Sendable (Date) -> Void) throws {
        stopRecordingOutput()
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let recording = OutputRecording(file: try AVAudioFile(forWriting: url, settings: format.settings),
                                        started: started)
        try engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            recording.write(AVAudioPCMBuffer(copying: buffer), at: time)
        }
        outputRecording = recording
    }

    func stopRecordingOutput() {
        guard let outputRecording else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        outputRecording.close()
        self.outputRecording = nil
    }
    #endif
}

#if DEBUG
/// The engine's output, written to a file from its tap.
private final class OutputRecording: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var started: (@Sendable (Date) -> Void)?

    init(file: AVAudioFile, started: @escaping @Sendable (Date) -> Void) {
        self.file = file
        self.started = started
    }

    func write(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        if let started, time.isHostTimeValid {
            // The buffer's render time on the host clock, as a wall-clock time.
            let age = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                - AVAudioTime.seconds(forHostTime: time.hostTime)
            started(Date(timeIntervalSinceNow: -age))
            self.started = nil
        }
        try? file?.write(from: buffer)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        file?.close()
        file = nil
    }
}
#endif

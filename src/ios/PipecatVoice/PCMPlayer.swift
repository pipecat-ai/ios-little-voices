import AVFoundation

@MainActor
final class PCMPlayer {
    /// Phonon's audio, as the player schedules it: mono Float32 at 24 kHz.
    static let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    /// `samples`, copied into a buffer of `format`.
    static func buffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = buffer.floatChannelData?[0] else {
            throw VoiceError(message: "Could not allocate an audio buffer.")
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { output.update(from: base, count: source.count) }
        }
        return buffer
    }

    private let audio: VoiceAudioEngine
    private let player = AVAudioPlayerNode()
    private var pending = 0
    private var generation = 0
    private var drained: CheckedContinuation<Void, Error>?
    var onSpeakingChanged: ((Bool) -> Void)?
    /// Each scheduled chunk and the time it starts on the player's clock, in seconds.
    var onScheduled: (([Float], Double) -> Void)?
    /// Playback ended: `true` when stopped early, `false` when everything queued played.
    var onPlaybackEnded: ((Bool) -> Void)?
    private var speaking = false
    /// Player sample time at which the audio scheduled so far ends.
    private var scheduledEnd: AVAudioFramePosition = 0

    init(audio: VoiceAudioEngine) {
        self.audio = audio
        audio.attach(player, format: Self.format)
    }

    func enqueue(_ samples: [Float]) throws {
        try Task.checkCancellation()
        guard !samples.isEmpty else { return }
        try audio.start()
        let buffer = try Self.buffer(samples)
        // Offline audio checks have no output device to report dataPlayedBack.
        let callbackType: AVAudioPlayerNodeCompletionCallbackType = player.engine?.isInManualRenderingMode == true
            ? .dataRendered : .dataPlayedBack
        let epoch = generation
        // A stopped player restarts its clock at zero; a starved one plays new audio next render.
        let start = max(renderedSampleTime ?? 0, scheduledEnd)
        scheduledEnd = start + AVAudioFramePosition(samples.count)
        pending += 1
        player.scheduleBuffer(buffer, completionCallbackType: callbackType) { [weak self] _ in
            Task { @MainActor in
                guard let self, epoch == self.generation else { return }
                self.pending -= 1
                if self.pending == 0 {
                    self.drained?.resume()
                    self.drained = nil
                    self.setSpeaking(false)
                    self.onPlaybackEnded?(false)
                }
            }
        }
        if !player.isPlaying { try player.playAudio() }
        onScheduled?(samples, Double(start) / Self.format.sampleRate)
        setSpeaking(true)
    }

    /// The audible position on the player's clock, in seconds; nil while stopped.
    var playbackTime: Double? {
        guard let (nodeTime, sampleTime) = renderTime else { return nil }
        var seconds = Double(sampleTime) / Self.format.sampleRate
        // Render times only advance once per I/O cycle; follow the host clock in between
        // so the mouth moves at display rate. Offline rendering has no host time.
        if nodeTime.isHostTimeValid {
            let elapsed = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                - AVAudioTime.seconds(forHostTime: nodeTime.hostTime)
            seconds += min(max(elapsed, -0.1), 0.1)
        }
        #if os(iOS)
        seconds -= AVAudioSession.sharedInstance().outputLatency
        #endif
        return seconds
    }

    private var renderedSampleTime: AVAudioFramePosition? { renderTime?.sample }

    /// The last render cycle's node time and the player sample it rendered.
    private var renderTime: (node: AVAudioTime, sample: AVAudioFramePosition)? {
        // Before the first render cycle the node time is invalid, and converting it traps.
        guard player.isPlaying, let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let time = player.playerTime(forNodeTime: nodeTime), time.isSampleTimeValid else { return nil }
        return (nodeTime, time.sampleTime)
    }

    func finish() async throws {
        try Task.checkCancellation()
        if pending == 0 { return }
        let expectedGeneration = generation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { drained = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                self.stop()
            }
        }
    }

    func stop() {
        generation += 1
        player.stop()
        pending = 0
        scheduledEnd = 0
        drained?.resume(throwing: CancellationError())
        drained = nil
        setSpeaking(false)
        onPlaybackEnded?(true)
    }

    private func setSpeaking(_ speaking: Bool) {
        guard self.speaking != speaking else { return }
        self.speaking = speaking
        onSpeakingChanged?(speaking)
    }
}

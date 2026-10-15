import AVFoundation
import Foundation

struct VoiceError: Error { let message: String }

// Exercise the real PCMPlayer against an offline engine, without microphone
// permission, speakers, or the app's voice-processing audio session.
@MainActor final class VoiceAudioEngine {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    func attach(_ player: AVAudioPlayerNode, format: AVAudioFormat) {
        engine.attach(player)
        try! engine.connectNode(player, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        guard !engine.isRunning else { return }
        if !engine.isInManualRenderingMode {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
        }
        try engine.start()
    }

    func render(frames: Int) async throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        var output: [Float] = []
        while output.count < frames {
            let count = AVAudioFrameCount(min(480, frames - output.count))
            let status = try engine.renderOffline(count, to: buffer)
            precondition(status == .success, "Offline audio render failed")
            output.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            // Completion handlers dispatch onto the main actor, like in the app.
            try await Task.sleep(for: .milliseconds(1))
        }
        return output
    }
}

@main struct PlaybackChecks {
    @MainActor static func main() async throws {
        let audio = VoiceAudioEngine()
        let player = PCMPlayer(audio: audio)
        var speaking: [Bool] = []
        player.onSpeakingChanged = { speaking.append($0) }
        // Lip sync places each chunk on the player's clock and rests when playback ends.
        var starts: [Double] = []
        var ended: [Bool] = []
        player.onScheduled = { _, start in starts.append(start) }
        player.onPlaybackEnded = { ended.append($0) }

        func tone(_ gain: Float, frames: Int = 4_800) -> [Float] {
            (0..<frames).map { gain * sin(Float($0) * 2 * .pi * 200 / 24_000) }
        }

        // Consecutive synthesis chunks, including silence and an odd-length tail,
        // play back as one continuous PCM stream.
        let chunks = [tone(0.015), tone(0), tone(0.32), tone(0.015, frames: 1_083)]
        for chunk in chunks { try player.enqueue(chunk) }
        precondition(speaking == [true], "Queued audio must mark the bot as speaking once")
        let input = chunks.flatMap { $0 }
        let output = try await audio.render(frames: input.count + 1_920)
        try await player.finish()
        precondition(zip(input, output).allSatisfy { abs($0 - $1) < 0.00001 }, "Playback changed the PCM stream")
        precondition(output.dropFirst(input.count).allSatisfy { $0 == 0 }, "Audio continued after the last chunk")
        precondition(speaking == [true, false], "Playback did not report its end once")
        precondition(starts == [0, 0.2, 0.4, 0.6], "Queued chunks must start back to back: \(starts)")
        precondition(ended == [false], "Draining must end playback normally")

        // Old completion callbacks must not drain or end a replacement reply.
        try player.enqueue(tone(0.4, frames: 24_000))
        precondition(starts[4] >= Double(input.count) / 24_000, "A starved player must not schedule into the past")
        _ = try await audio.render(frames: 960)
        precondition(player.playbackTime.map { $0 > starts[4] } == true, "Playback time must advance")
        player.stop()
        precondition(ended == [false, true] && player.playbackTime == nil, "Stopping must end playback early")
        speaking.removeAll()
        try player.enqueue(tone(0.015))
        precondition(speaking == [true])
        precondition(starts[5] == 0, "A stopped player restarts its clock at zero")
        _ = try await audio.render(frames: 6_720)
        try await player.finish()
        precondition(speaking == [true, false], "A stopped reply's completion affected its replacement")

        try player.enqueue(tone(0.3, frames: 24_000))
        let finish = Task { try await player.finish() }
        await Task.yield()
        finish.cancel()
        do { try await finish.value; preconditionFailure("Cancelled finish succeeded") }
        catch is CancellationError { }
        precondition(speaking.last == false)
        audio.engine.stop()
        print("Native playback checks passed: PCM continuity, speaking state, interruption, restart, cancellation")
    }
}

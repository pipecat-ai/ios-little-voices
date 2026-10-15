#if DEBUG
import AVFoundation
import Foundation
import UIKit

private final class CaptureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var buffers: Int { lock.lock(); defer { lock.unlock() }; return count }
    func received() { lock.lock(); count += 1; lock.unlock() }
}

@MainActor
enum TTSDiagnostics {
    private static func report(_ message: String) {
        print(message)
        fflush(nil)
    }

    private struct BenchmarkRun: Codable {
        let pass: String
        let thermalBefore: String
        let thermalAfter: String
        let lowPowerMode: Bool
        let metrics: SpeechStreamMetrics.Report
    }

    private struct BenchmarkReport: Codable {
        let date: Date
        let platform: String
        let hardware: String
        let osVersion: String
        let build: SpeechBenchmarkBuild
        let model: String
        let voice: String
        let text: String
        let preparationSeconds: Double
        let runs: [BenchmarkRun]
        let notes: [String]
    }

    /// Inference-only Phonon profiling: no microphone permission or audio route is needed.
    static func benchmark() async {
        let text = "Hello there. Phonon is speaking on this device. You can interrupt me whenever you want."
        let synth = PhononSynthesizer()
        do {
            let build = SpeechBenchmarkBuild.current
            report("PHONON_BENCHMARK_BUILD: swiftAssertionsEnabled=\(build.swiftAssertionsEnabled); use SWIFT_OPTIMIZATION_LEVEL=-O for device comparisons")
            let prepareStart = ProcessInfo.processInfo.systemUptime
            try await synth.prepare(voices: VoiceSettings.voices)
            let preparationSeconds = ProcessInfo.processInfo.systemUptime - prepareStart
            report("PHONON_BENCHMARK_READY: voice=\(VoiceSettings.voices[0]), prepare=\(preparationSeconds)s")
            var runs: [BenchmarkRun] = []
            for pass in ["first", "warm-1", "warm-2", "warm-3"] {
                try Task.checkCancellation()
                let thermalBefore = thermalDescription()
                let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                var metrics = SpeechStreamMetrics(started: ProcessInfo.processInfo.systemUptime)
                let request = try await synth.synthesize(text)
                do {
                    for try await chunk in request.samples {
                        try Task.checkCancellation()
                        metrics.record(samples: chunk.count, at: ProcessInfo.processInfo.systemUptime)
                    }
                } catch {
                    request.cancel()
                    await request.waitForCompletion()
                    throw error
                }
                await request.waitForCompletion()
                let measurement = metrics.report(finished: ProcessInfo.processInfo.systemUptime)
                guard measurement.samples > 2400 else {
                    throw VoiceError(message: "The benchmark did not produce enough speech.")
                }
                let run = BenchmarkRun(pass: pass, thermalBefore: thermalBefore,
                                       thermalAfter: thermalDescription(), lowPowerMode: lowPowerMode,
                                       metrics: measurement)
                runs.append(run)
                let json = try JSONEncoder().encode(run)
                report("PHONON_BENCHMARK_RUN: \(String(decoding: json, as: UTF8.self))")
            }
            #if targetEnvironment(simulator)
            let platform = "simulator"
            let hardware = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown simulator"
            #else
            let platform = "device"
            var system = utsname()
            uname(&system)
            let machineSize = MemoryLayout.size(ofValue: system.machine)
            let hardware = withUnsafePointer(to: &system.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: machineSize) {
                    String(cString: $0)
                }
            }
            #endif
            let result = BenchmarkReport(
                date: Date(), platform: platform, hardware: hardware,
                osVersion: UIDevice.current.systemVersion, build: build, model: "gradium-phonon",
                voice: VoiceSettings.voices[0], text: text, preparationSeconds: preparationSeconds, runs: runs,
                notes: [
                    "Lower realTimeFactor is better; below 1 means generation finished faster than the audio duration.",
                    "Potential underflow simulates immediate playback with no startup buffer; it does not measure audible glitches.",
                    "First pass includes first-use inference costs after preparation; it is not a fresh-install cold-start measurement.",
                    "The Phonon runtime samples with a fixed seed (42) and ptts's default temperature (0.3), so each pass synthesizes the same audio.",
                    "DEBUG enables diagnostics independently of optimization. Build with SWIFT_OPTIMIZATION_LEVEL=-O for performance comparisons; swiftAssertionsEnabled records assertion behavior, not the exact compiler flag.",
                ])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let url = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
                .appendingPathComponent("phonon-benchmark.json")
            try encoder.encode(result).write(to: url, options: .atomic)
            report("PHONON_BENCHMARK_COMPLETE: \(url.path)")
        } catch { report("PHONON_BENCHMARK_FAILED: \(error.localizedDescription)") }
        await synth.unload()
    }

    private static func thermalDescription() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// Synthesize a fixed sentence to a WAV file, without audio-session setup or playback.
    static func verifySynthesis() async {
        let synth = PhononSynthesizer()
        let run = Task { @MainActor in
            var stage = "prepare"
            do {
                let started = ProcessInfo.processInfo.systemUptime
                try await synth.prepare(voices: VoiceSettings.voices)
                try Task.checkCancellation()
                report("PHONON_PREPARED: voices=\(VoiceSettings.voices.joined(separator: ",")), elapsed_s=\(ProcessInfo.processInfo.systemUptime - started)")

                let url = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("phonon-check.wav")
                var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: PCMPlayer.format.settings)
                stage = "synthesis"
                let generationStarted = ProcessInfo.processInfo.systemUptime
                let request = try await synth.synthesize("Hello there. This is a test of Gradium Phonon.")
                var count = 0
                var energy = 0.0
                do {
                    try await withTaskCancellationHandler {
                        for try await chunk in request.samples {
                            try Task.checkCancellation()
                            guard !chunk.isEmpty else { continue }
                            guard chunk.allSatisfy(\.isFinite), Double(count + chunk.count) <= PCMPlayer.format.sampleRate * 60 else {
                                throw VoiceError(message: "The diagnostic returned invalid or excessive audio.")
                            }
                            if count == 0 {
                                report("PHONON_FIRST_PCM: elapsed_s=\(ProcessInfo.processInfo.systemUptime - generationStarted), sample_rate=\(Int(PCMPlayer.format.sampleRate))")
                            }
                            count += chunk.count
                            energy += chunk.reduce(0.0) { $0 + Double($1 * $1) }
                            try file?.write(from: PCMPlayer.buffer(chunk))
                        }
                    } onCancel: { request.cancel() }
                    await request.waitForCompletion()
                } catch {
                    request.cancel()
                    await request.waitForCompletion()
                    throw error
                }
                file = nil // Close the WAV header before external inspection.
                guard count > 2400, energy.isFinite, energy > 0.001 else {
                    throw VoiceError(message: "The diagnostic did not produce audible speech.")
                }
                report("PHONON_SYNTHESIZED: samples=\(count), audio_s=\(Double(count) / PCMPlayer.format.sampleRate), elapsed_s=\(ProcessInfo.processInfo.systemUptime - generationStarted), file=phonon-check.wav")
                report("PHONON_PASS: microphone=off, playback=not_tested")
            } catch {
                let native = error as NSError
                report("PHONON_FAILED: stage=\(stage), domain=\(native.domain), code=\(native.code), cancelled=\(Task.isCancelled)")
            }
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            run.cancel()
        }
        await run.value
        timeout.cancel()
        await synth.unload()
    }

    /// Exercise playback, interruption, and restart through the shared audio engine.
    static func run() async {
        let audio = VoiceAudioEngine()
        let player = PCMPlayer(audio: audio)
        let synth = PhononSynthesizer()
        do {
            let start = Date()
            try await synth.prepare(voices: VoiceSettings.voices)
            report("PHONON_MODEL_LOADED: \(Date().timeIntervalSince(start))s")
            try audio.configureSession()
            let capture = CaptureProbe()
            try audio.startCapture { _, _ in capture.received() }
            let url = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true).appendingPathComponent("phonon-playback-check.wav")
            let file = try AVAudioFile(forWriting: url, settings: PCMPlayer.format.settings)
            let request = try await synth.synthesize("Hello there. Phonon is speaking on this device.")
            var count = 0
            var energy = 0.0
            let generationStart = Date()
            for try await chunk in request.samples where !chunk.isEmpty {
                if count == 0 { report("PHONON_FIRST_AUDIO: \(Date().timeIntervalSince(generationStart))s") }
                count += chunk.count
                energy += chunk.reduce(0.0) { $0 + Double($1 * $1) }
                try file.write(from: PCMPlayer.buffer(chunk))
                try player.enqueue(chunk)
            }
            await request.waitForCompletion()
            report("PHONON_SYNTHESIS_TIME: \(Date().timeIntervalSince(generationStart))s")
            try await player.finish()
            guard count > 2400, energy.isFinite, energy > 0.001 else {
                throw VoiceError(message: "Synthesis did not produce finite, non-silent speech.")
            }
            report("PHONON_PLAYED: \(count) samples, \(Double(count) / PCMPlayer.format.sampleRate)s audio")

            let cancelled = try await synth.synthesize("This is a longer sentence for the interruption test. It should stop when the first audio arrives.")
            for try await chunk in cancelled.samples {
                try player.enqueue(chunk)
                player.stop()
                cancelled.cancel()
                break
            }
            let cancellationStart = Date()
            await cancelled.waitForCompletion()
            report("PHONON_CANCELLED: inference drained in \(Date().timeIntervalSince(cancellationStart))s")
            let captureBeforeRestart = capture.buffers
            let resumed = try await synth.synthesize("The next reply works after an interruption.")
            cancelled.cancel() // A delayed cancellation must leave the new request intact.
            var resumedCount = 0
            for try await samples in resumed.samples {
                resumedCount += samples.count
                try player.enqueue(samples)
            }
            await resumed.waitForCompletion()
            try await player.finish()
            guard resumedCount > 2400, capture.buffers > captureBeforeRestart else {
                throw VoiceError(message: "Restart failed or capture stopped.")
            }
            report("PHONON_VERIFIED: load, playback, cancellation, restart and continuous capture")
        } catch { report("PHONON_FAILED: \(error.localizedDescription)") }
        await synth.unload()
        player.stop()
        audio.stop()
    }
}
#endif

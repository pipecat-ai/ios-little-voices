// Ported from pipecat-visemes (server/lipsync/formant_lipsync_analyzer.py), BSD 2-Clause,
// Copyright (c) 2026 Daily: the default DSP path, without the experimental text events.
// tests/native/LipsyncChecks.swift holds it to the Python reference's output.
import Foundation

/// A continuous articulation sample; all values are normalized to 0...1.
struct LipsyncKeyframe: Equatable, Sendable {
    /// Seconds from utterance start.
    var offset: Double
    var openness: Double
    var width: Double
    var rounding: Double
    var energy: Double
    var pitch: Double
    /// Per-hop evidence for diagnostics; it tracks loudness, so never scale the pose by it.
    var confidence: Double
}

struct LipsyncEvent: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// Bilabial closure (M/B/P): a brief energy dip inside speech.
        case closure
        /// Sustained nasal; the analyzer already caps openness while it lasts.
        case nasal
        /// Sustained silence; the mouth should rest.
        case silence
    }

    var offset: Double
    var kind: Kind
    /// Seconds; 0 means "until the next keyframe".
    var duration: Double
    var confidence: Double
}

/// Estimates mouth articulation from 16 kHz speech with LPC formant tracking: F1 maps to
/// openness, F2 to width and rounding, with closure, nasal and silence events. Adaptive
/// per-voice ranges persist across utterances; everything else resets with each one.
final class FormantLipsyncAnalyzer {
    struct Result: Sendable {
        var keyframes: [LipsyncKeyframe] = []
        var events: [LipsyncEvent] = []
    }

    static let hopSeconds = Double(LipsyncDSP.hopSize) / Double(LipsyncDSP.sampleRate)

    private static let neutral = 0.35
    private static let silenceRestOpenness = 0.15
    private static let unvoicedDecay = 0.8
    private static let f1Prior = (250.0, 900.0)
    private static let f2Prior = (800.0, 2500.0)
    private static let highPitchHz = 180.0
    private static let priorShift = 1.12
    private static let pitchProbeFrames = 10
    private static let convergenceFrames = 60.0
    private static let minLearnedSpanHz = 100.0
    private static let minEstimatorCount = 10
    private static let shiftRing = 100
    private static let shiftRecent = 25
    private static let shiftDeviation = 0.25
    private static let shiftDecayPerHop = hopSeconds / 2
    private static let shiftRetainedFrames = 30
    private static let noiseRing = 50
    private static let noiseFloorMin = 1e-5
    private static let noiseFloorPeakCap = 0.05
    private static let peakDecay = 0.98
    private static let energyMaxDecay = 0.998
    private static let logCompression = 9.0
    private static let silenceFloorMultiple = 2.5
    private static let silenceAbsolute = 1e-4
    private static let silenceEventHops = 10
    private static let closureFloorMultiple = 3.0
    private static let closurePeakFraction = 0.22
    private static let closureMinHops = 2
    private static let closureMaxSeconds = 0.25
    private static let speechWindowHops = 8
    private static let speechHistoryHops = speechWindowHops + Int(closureMaxSeconds / hopSeconds) + 2
    private static let nasalCentroidMaxHz = 1000.0
    private static let nasalLowRatioMin = 0.6
    private static let nasalF2MaxBandwidthHz = 300.0
    private static let nasalDarkRatio = 0.9
    private static let nasalSpuriousF2Hz = 1200.0
    private static let nasalVowelF2MaxHz = 1200.0
    private static let nasalHysteresisHops = 2
    private static let nasalF1MaxHz = 350.0
    private static let nasalOpennessMax = 0.15
    private static let roundedVowelMinOpenness = 0.1
    private static let roundingOpenGate = (0.75, 0.9)
    private static let nasalSoftCapOpenness = 0.2
    private static let nasalSoftCapCentroidHz = 800.0
    private static let nasalSoftCapRatio = 0.5
    private static let voicedMinPeakFraction = 0.05
    private static let medianTaps = 3
    private static let slewMaxPerHop = 0.4
    private static let holdMaxHops = 3
    private static let holdDecay = 0.1
    private static let f1HoldDrift = 0.0
    private static let adaptSpikeHz = 400.0
    private static let adaptMaxSkips = 2
    private static let formantDeltaHz = 300.0
    private static let lpcConfidenceFloor = 0.3
    private static let partialSlotConfidence = 0.5
    private static let snrFullDecibels = 20.0
    private static let fitLog10Full = 3.2

    private struct PendingHop {
        var offset: Double
        var energy: Double
        var pitch: Double
        var confidence: Double
        var eventFired: Bool
    }

    private struct PendingClosure {
        var offset: Double
        var duration: Double
        var depth: Double
        var deadlineHop: Int
    }

    private let deadBand: Double
    private let heartbeatSeconds: Double
    /// The pitch frame reaches this far either side of the 25 ms frame.
    private let pad = (LipsyncDSP.pitchFrameSize - LipsyncDSP.frameSize) / 2
    private let window = LipsyncDSP.hamming(LipsyncDSP.lpcFrameSize)
    private let spectrum = LipsyncDSP.NasalSpectrum()

    // Session state: survives utterances.
    private var f1Low = LipsyncDSP.P2Quantile(0.10), f1High = LipsyncDSP.P2Quantile(0.90)
    private var f2Low = LipsyncDSP.P2Quantile(0.10), f2High = LipsyncDSP.P2Quantile(0.90)
    private var pitchLow = LipsyncDSP.P2Quantile(0.05), pitchHigh = LipsyncDSP.P2Quantile(0.95)
    private var voicedFrames = 0
    private var f1PriorRange = FormantLipsyncAnalyzer.f1Prior
    private var f2PriorRange = FormantLipsyncAnalyzer.f2Prior
    private var pitchProbe: [Double] = []
    private var priorsShifted = false
    private var shiftHistory: [Double] = []
    private var priorDecay = 0.0
    private var noiseHistory: [Double] = []
    private var noiseFloor = FormantLipsyncAnalyzer.noiseFloorMin
    private var recentPeak = 0.0
    private var energyMax = FormantLipsyncAnalyzer.noiseFloorMin

    // Utterance state.
    private var buffer: [Float] = []
    private var previousSample: Float = 0
    private var hops = 0
    private var previousF1 = 0.0, previousF2 = 0.0, previousF3 = 0.0
    private var holdCounts = [0, 0]
    private var lastAdapt = [0.0, 0.0]
    private var adaptSkips = [0, 0]
    private var previousTargets = [neutral, neutral, neutral]
    private var medianHistory: [[Double]] = []
    private var pendingHop: PendingHop?
    private var conditionedPrevious: [Double]?
    private var lastEmitted: [Double]?
    private var lastEmitOffset = -1.0
    private var speechHistory: [Bool] = []
    private var lowRunHops = 0
    private var lowRunStartOffset = 0.0
    private var lowRunMinRMS = 0.0
    private var pendingClosures: [PendingClosure] = []
    private var silenceRunHops = 0
    private var silenceStartOffset = 0.0
    private var silenceEmitted = false
    private var nasalActive = false
    private var nasalEnterCount = 0
    private var nasalExitCount = 0

    init(deadBand: Double = 0.05, heartbeatMilliseconds: Int = 240) {
        self.deadBand = deadBand
        heartbeatSeconds = Double(heartbeatMilliseconds) / 1000
        resetUtterance()
    }

    /// Analyze 16 kHz mono samples of the current utterance.
    func analyze(_ samples: [Float]) -> Result {
        var result = Result()
        buffer += samples
        drain(&result)
        return result
    }

    /// Analyze the remaining complete frames, emit the last conditioned hop, and start a new
    /// utterance. Unconfirmed closures are dropped: no trailing speech will confirm them.
    func flush() -> Result {
        var result = Result()
        buffer += [Float](repeating: 0, count: pad)
        drain(&result)
        if let hop = pendingHop {
            pendingHop = nil
            let taps = Array(medianHistory.suffix(2)) + Array(medianHistory.suffix(1))
            conditionAndEmit(hop, taps: taps, into: &result)
        }
        resetUtterance()
        return result
    }

    /// Discard the current utterance (an interruption); the learned voice ranges remain.
    func resetUtterance() {
        // The buffer leads with the pitch frame's left context (zeros at utterance start).
        buffer = [Float](repeating: 0, count: pad)
        previousSample = 0
        hops = 0
        previousF1 = 0; previousF2 = 0; previousF3 = 0
        holdCounts = [0, 0]
        lastAdapt = [0, 0]
        adaptSkips = [0, 0]
        previousTargets = [Self.neutral, Self.neutral, Self.neutral]
        medianHistory = []
        pendingHop = nil
        conditionedPrevious = nil
        lastEmitted = nil
        lastEmitOffset = -1
        speechHistory = []
        lowRunHops = 0
        lowRunStartOffset = 0
        lowRunMinRMS = 0
        pendingClosures = []
        silenceRunHops = 0
        silenceStartOffset = 0
        silenceEmitted = false
        nasalActive = false
        nasalEnterCount = 0
        nasalExitCount = 0
    }

    private func drain(_ result: inout Result) {
        var start = 0
        let frame = LipsyncDSP.frameSize
        while buffer.count - start >= frame + 2 * pad {
            let lpcStart = start + pad
            let previous = lpcStart == 0 ? previousSample : buffer[lpcStart - 1]
            processHop(raw: Array(buffer[(start + pad)..<(start + pad + frame)]),
                       pitchFrame: Array(buffer[start..<(start + LipsyncDSP.pitchFrameSize)]),
                       previousSample: previous, into: &result)
            start += LipsyncDSP.hopSize
        }
        if start > 0 {
            previousSample = buffer[start - 1]
            buffer.removeFirst(start)
        }
    }

    private func processHop(raw: [Float], pitchFrame: [Float], previousSample: Float, into result: inout Result) {
        let offset = (Double(hops * LipsyncDSP.hopSize) + Double(LipsyncDSP.frameSize) / 2) / Double(LipsyncDSP.sampleRate)
        hops += 1

        let rms = LipsyncDSP.rmsEnergy(raw[...])
        noiseHistory.append(rms)
        if noiseHistory.count > Self.noiseRing { noiseHistory.removeFirst() }
        recentPeak = max(recentPeak * Self.peakDecay, rms)
        energyMax = max(energyMax * Self.energyMaxDecay, rms)
        noiseFloor = max(min(noiseHistory.min() ?? rms, Self.noiseFloorPeakCap * recentPeak), Self.noiseFloorMin)
        let silenceGate = max(Self.silenceFloorMultiple * noiseFloor, Self.silenceAbsolute)

        var voiced = false
        var pitchHz = 0.0
        var clarity = 0.0
        var centroid = 0.0
        var lowRatio = 0.0
        var f1Found = false, f2Found = false
        var f1 = previousF1, f2 = previousF2, f3 = previousF3
        var predictionGain = 0.0
        var f1Present = false, f2Present = false
        var f2Damped = false
        var vowelF2 = false
        if rms >= silenceGate {
            let windowed = preEmphasizedWindow(raw, previousSample: previousSample)
            let lpc = LipsyncDSP.lpcCoefficients(windowed)
            predictionGain = lpc.predictionGain
            let formants = LipsyncDSP.lpcFormants(
                lpc.coefficients,
                previous: LipsyncDSP.FormantEstimate(f1: previousF1, f2: previousF2, f3: previousF3))
            let pitch = LipsyncDSP.nccPitch(pitchFrame)
            let pitchVoiced = pitch.voiced && rms > Self.voicedMinPeakFraction * recentPeak
            // Nasal features read the pre-emphasized spectrum, where low harmonics no longer
            // dominate. The reference disables its 500–1500 Hz murmur limit, so that band is skipped.
            (centroid, lowRatio) = spectrum.features(windowed)
            voiced = pitchVoiced
            pitchHz = pitchVoiced ? pitch.frequency : 0
            clarity = pitch.clarity
            f1Found = formants.f1 > 0
            f2Found = formants.f2 > 0
            let f3Found = formants.f3 > 0
            f1Present = f1Found || formants.f1Broad > 0
            f1 = f1Found ? formants.f1 : (formants.f1Broad > 0 ? formants.f1Broad : previousF1)
            f2 = f2Found ? formants.f2 : (formants.f2Broad > 0 ? formants.f2Broad : previousF2)
            f2Present = f2Found || formants.f2Broad > 0
            f3 = f3Found ? formants.f3 : previousF3
            let dark = lowRatio > Self.nasalDarkRatio
            let f2MissingDamped = !f2Found
            vowelF2 = formants.f2Low > 0 && formants.f2Low <= Self.nasalVowelF2MaxHz
            f2Damped = !vowelF2 && (f2MissingDamped || formants.f2Bandwidth > Self.nasalF2MaxBandwidthHz
                                    || (dark && formants.f2 > Self.nasalSpuriousF2Hz))
        }

        f1 = boundHold(slot: 0, value: f1, found: f1Present, prior: f1PriorRange)
        f2 = boundHold(slot: 1, value: f2, found: f2Present, prior: f2PriorRange)
        if voiced { updateAdaptation(f1: f1, f2: f2, pitchHz: pitchHz, f1Found: f1Found, f2Found: f2Found) }
        if priorDecay > 0 { priorDecay = max(0, priorDecay - Self.shiftDecayPerHop) }
        let (f1Lo, f1Hi) = effectiveRange(f1Low, f1High, prior: f1PriorRange)
        let (f2Lo, f2Hi) = effectiveRange(f2Low, f2High, prior: f2PriorRange)

        var openness: Double, width: Double, rounding: Double
        if voiced && f1 > 0 {
            openness = clamp01((f1 - f1Lo) / (f1Hi - f1Lo + LipsyncDSP.epsilon))
            width = clamp01((f2 - f2Lo) / (f2Hi - f2Lo + LipsyncDSP.epsilon))
            let f2Mid = (f2Lo + f2Hi) / 2
            rounding = clamp01((f2Mid - f2) / (f2Mid - f2Lo + LipsyncDSP.epsilon))
                * (1 - smoothstep(openness, Self.roundingOpenGate.0, Self.roundingOpenGate.1))
            if vowelF2 { openness = max(openness, Self.roundedVowelMinOpenness) }
        } else {
            // Unvoiced speech decays toward neutral; true silence rests nearly closed.
            let rest = rms < silenceGate ? Self.silenceRestOpenness : Self.neutral
            openness = rest + (previousTargets[0] - rest) * Self.unvoicedDecay
            width = Self.neutral + (previousTargets[1] - Self.neutral) * Self.unvoicedDecay
            rounding = Self.neutral + (previousTargets[2] - Self.neutral) * Self.unvoicedDecay
        }

        let speech = rms > 2 * max(Self.closureFloorMultiple * noiseFloor, Self.closurePeakFraction * recentPeak)
        let murmurShape = f1 <= Self.nasalF1MaxHz || f1 == 0
        let eventFired = updateEvents(offset: offset, rms: rms, silenceGate: silenceGate, speech: speech,
                                      voiced: voiced, centroid: centroid, lowRatio: lowRatio,
                                      f2Damped: f2Damped && murmurShape, clarity: clarity, into: &result)
        if nasalActive {
            openness = min(openness, Self.nasalOpennessMax)
        } else if voiced && f2Damped && centroid < Self.nasalSoftCapCentroidHz && lowRatio > Self.nasalSoftCapRatio {
            // Close toward a nasal within one hop, before the event latches.
            openness = min(openness, Self.nasalSoftCapOpenness)
        }
        previousTargets = [openness, width, rounding]

        let energy = log1p(Self.logCompression * rms / (energyMax + LipsyncDSP.epsilon)) / log1p(Self.logCompression)
        var pitchNorm = 0.0
        if voiced {
            let (low, high) = (pitchLow.value, pitchHigh.value)
            pitchNorm = high - low >= 20 ? clamp01((pitchHz - low) / (high - low)) : 0.5
        }

        let slotConfidence = f1Found && f2Found ? 1 : (f1Found || f2Found ? Self.partialSlotConfidence : Self.lpcConfidenceFloor)
        let delta = max(abs(f1 - previousF1), abs(f2 - previousF2))
        let deltaTerm = clamp01(1 - delta / Self.formantDeltaHz)
        let lpcConfidence = slotConfidence * (Self.lpcConfidenceFloor + (1 - Self.lpcConfidenceFloor) * deltaTerm)
        let fitConfidence = clamp01(log10(max(predictionGain, 1)) / Self.fitLog10Full)
        let convergence = min(1, Double(voicedFrames) / Self.convergenceFrames)
        let snr = 20 * log10((rms + LipsyncDSP.epsilon) / (3 * noiseFloor + LipsyncDSP.epsilon))
        let snrConfidence = clamp01(snr / Self.snrFullDecibels)
        let confidence = lpcConfidence * fitConfidence * snrConfidence * convergence.squareRoot()

        previousF1 = f1; previousF2 = f2; previousF3 = f3

        // Conditioning: this hop completes the previous hop's centered median-3.
        medianHistory.append([openness, width, rounding])
        if medianHistory.count > Self.medianTaps { medianHistory.removeFirst() }
        let previous = pendingHop
        pendingHop = PendingHop(offset: offset, energy: energy, pitch: pitchNorm, confidence: confidence,
                                eventFired: eventFired)
        if let previous { conditionAndEmit(previous, taps: medianHistory, into: &result) }
    }

    private func preEmphasizedWindow(_ frame: [Float], previousSample: Float) -> [Float] {
        var windowed = frame
        for i in stride(from: frame.count - 1, through: 1, by: -1) {
            windowed[i] -= LipsyncDSP.preEmphasis * frame[i - 1]
        }
        windowed[0] -= Float(0.97 * Double(previousSample))
        for i in 0..<windowed.count { windowed[i] *= window[i] }
        return windowed
    }

    private func boundHold(slot: Int, value: Double, found: Bool, prior: (Double, Double)) -> Double {
        if found {
            holdCounts[slot] = 0
            return value
        }
        holdCounts[slot] += 1
        if holdCounts[slot] > Self.holdMaxHops && value > 0 {
            let drift = slot == 0 ? Self.f1HoldDrift : 0.5
            let target = prior.0 + (prior.1 - prior.0) * drift
            return value + (target - value) * Self.holdDecay
        }
        return value
    }

    private func updateAdaptation(f1: Double, f2: Double, pitchHz: Double, f1Found: Bool, f2Found: Bool) {
        voicedFrames += 1
        // High-pitched voices sit higher in formant space: shift the priors once.
        if !priorsShifted && pitchProbe.count < Self.pitchProbeFrames {
            pitchProbe.append(pitchHz)
            if pitchProbe.count == Self.pitchProbeFrames {
                priorsShifted = true
                if LipsyncDSP.median(pitchProbe) > Self.highPitchHz {
                    f1PriorRange = (Self.f1Prior.0 * Self.priorShift, Self.f1Prior.1 * Self.priorShift)
                    f2PriorRange = (Self.f2Prior.0 * Self.priorShift, Self.f2Prior.1 * Self.priorShift)
                }
            }
        }
        if f1Found && acceptAdaptation(slot: 0, value: f1) {
            f1Low.add(f1)
            f1High.add(f1)
            shiftHistory.append(f1)
            if shiftHistory.count > Self.shiftRing { shiftHistory.removeFirst() }
            // A distribution shift (such as a voice change) decays toward the priors.
            if shiftHistory.count == Self.shiftRing && priorDecay == 0 {
                let recent = LipsyncDSP.median(Array(shiftHistory.suffix(Self.shiftRecent)))
                let overall = LipsyncDSP.median(shiftHistory)
                if overall > 0 && abs(recent - overall) / overall > Self.shiftDeviation {
                    priorDecay = 1
                    voicedFrames = Self.shiftRetainedFrames
                }
            }
        }
        if f2Found && acceptAdaptation(slot: 1, value: f2) {
            f2Low.add(f2)
            f2High.add(f2)
        }
        if pitchHz > 0 {
            pitchLow.add(pitchHz)
            pitchHigh.add(pitchHz)
        }
    }

    /// Reject isolated large jumps from the learned ranges; accept real shifts.
    private func acceptAdaptation(slot: Int, value: Double) -> Bool {
        let last = lastAdapt[slot]
        if last > 0 && abs(value - last) > Self.adaptSpikeHz && adaptSkips[slot] < Self.adaptMaxSkips {
            adaptSkips[slot] += 1
            return false
        }
        adaptSkips[slot] = 0
        lastAdapt[slot] = value
        return true
    }

    private func effectiveRange(_ low: LipsyncDSP.P2Quantile, _ high: LipsyncDSP.P2Quantile,
                                prior: (Double, Double)) -> (Double, Double) {
        var (lo, hi) = prior
        if low.count >= Self.minEstimatorCount {
            let (learnedLo, learnedHi) = (low.value, high.value)
            if learnedHi - learnedLo >= Self.minLearnedSpanHz {
                let weight = min(1, Double(voicedFrames) / Self.convergenceFrames)
                lo = lerp(prior.0, learnedLo, weight)
                hi = lerp(prior.1, learnedHi, weight)
            }
        }
        if priorDecay > 0 {
            lo = lerp(lo, prior.0, priorDecay)
            hi = lerp(hi, prior.1, priorDecay)
        }
        return (lo, hi)
    }

    private func updateEvents(offset: Double, rms: Double, silenceGate: Double, speech: Bool, voiced: Bool,
                              centroid: Double, lowRatio: Double, f2Damped: Bool, clarity: Double,
                              into result: inout Result) -> Bool {
        var fired = false
        speechHistory.append(speech)
        if speechHistory.count > Self.speechHistoryHops { speechHistory.removeFirst() }

        // Silence: sustained sub-gate energy emits one event per stretch.
        if rms < silenceGate {
            if silenceRunHops == 0 { silenceStartOffset = offset }
            silenceRunHops += 1
            if silenceRunHops >= Self.silenceEventHops && !silenceEmitted {
                result.events.append(LipsyncEvent(offset: silenceStartOffset, kind: .silence, duration: 0, confidence: 0.9))
                silenceEmitted = true
                fired = true
            }
        } else {
            silenceRunHops = 0
            silenceEmitted = false
        }

        // Closure candidates: a bounded energy dip with speech right before it.
        let closureThreshold = max(Self.closureFloorMultiple * noiseFloor, Self.closurePeakFraction * recentPeak)
        if rms < closureThreshold {
            if lowRunHops == 0 {
                lowRunStartOffset = offset
                lowRunMinRMS = rms
            }
            lowRunHops += 1
            lowRunMinRMS = min(lowRunMinRMS, rms)
        } else {
            if lowRunHops > 0 {
                let duration = Double(lowRunHops) * Self.hopSeconds
                let end = speechHistory.count - (lowRunHops + 1)
                let speechBefore = end > 0 && speechHistory[max(0, end - Self.speechWindowHops)..<end].contains(true)
                if lowRunHops >= Self.closureMinHops && duration <= Self.closureMaxSeconds && speechBefore {
                    let depth = clamp01(1 - lowRunMinRMS / (closureThreshold + LipsyncDSP.epsilon))
                    pendingClosures.append(PendingClosure(offset: lowRunStartOffset, duration: duration, depth: depth,
                                                          deadlineHop: hops + Self.speechWindowHops))
                }
            }
            lowRunHops = 0
        }

        // Confirm pending closures on trailing speech; expire the rest.
        if !pendingClosures.isEmpty {
            var remaining: [PendingClosure] = []
            for pending in pendingClosures {
                if speech {
                    result.events.append(LipsyncEvent(offset: pending.offset, kind: .closure,
                                                      duration: pending.duration, confidence: pending.depth))
                    fired = true
                } else if hops <= pending.deadlineHop {
                    remaining.append(pending)
                }
            }
            pendingClosures = remaining
        }

        // Nasal: enter and exit with hysteresis.
        let nasalNow = voiced && centroid < Self.nasalCentroidMaxHz && lowRatio > Self.nasalLowRatioMin && f2Damped
        if nasalNow {
            nasalEnterCount += 1
            nasalExitCount = 0
            if !nasalActive && nasalEnterCount >= Self.nasalHysteresisHops {
                nasalActive = true
                result.events.append(LipsyncEvent(offset: offset, kind: .nasal, duration: 0,
                                                  confidence: min(lowRatio, max(clarity, 0))))
                fired = true
            }
        } else {
            nasalEnterCount = 0
            if nasalActive {
                nasalExitCount += 1
                if nasalExitCount >= Self.nasalHysteresisHops {
                    nasalActive = false
                    nasalExitCount = 0
                }
            }
        }
        return fired
    }

    /// Condition one hop (centered median, then slew limit) and emit it if it moved enough.
    private func conditionAndEmit(_ hop: PendingHop, taps: [[Double]], into result: inout Result) {
        var conditioned: [Double] = []
        for i in 0..<3 {
            var value = LipsyncDSP.median(taps.map { $0[i] })
            if let previous = conditionedPrevious?[i] {
                let delta = value - previous
                if delta > Self.slewMaxPerHop {
                    value = previous + Self.slewMaxPerHop
                } else if delta < -Self.slewMaxPerHop {
                    value = previous - Self.slewMaxPerHop
                }
            }
            conditioned.append(value)
        }
        conditionedPrevious = conditioned
        if !hop.eventFired, let last = lastEmitted {
            let moved = (0..<3).map { abs(conditioned[$0] - last[$0]) }.max() ?? 0
            // Heartbeats run only while speech is active; a silence stretch already rests the mouth.
            let silenceActive = silenceRunHops >= Self.silenceEventHops
            let heartbeatDue = !silenceActive && hop.offset - lastEmitOffset >= heartbeatSeconds
            if moved <= deadBand && !heartbeatDue { return }
        }
        lastEmitted = conditioned
        lastEmitOffset = hop.offset
        result.keyframes.append(LipsyncKeyframe(offset: hop.offset, openness: conditioned[0], width: conditioned[1],
                                                rounding: conditioned[2], energy: hop.energy, pitch: hop.pitch,
                                                confidence: hop.confidence))
    }

    private func clamp01(_ value: Double) -> Double { value < 0 ? 0 : (value > 1 ? 1 : value) }

    private func smoothstep(_ value: Double, _ edge0: Double, _ edge1: Double) -> Double {
        let t = clamp01((value - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

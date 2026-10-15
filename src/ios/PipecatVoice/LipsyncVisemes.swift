import Foundation

/// Mouth poses for aligned phones. Each phone has a target on the analyzer's scale (openness,
/// width, rounding, as `MouthDrive` reads them) and a dominance over each, so neighbours
/// coarticulate (Cohen and Massaro's dominance blending): lips round through the consonants
/// before an OO, while a T or a K, which leaves the lips free, takes its shape from the vowels
/// around it. Diphthongs glide between two targets.
enum LipsyncVisemes {
    struct Target: Sendable {
        var openness: Double
        var width: Double
        var rounding: Double
        /// How strongly the phone holds openness, width and rounding against its neighbours.
        var dominance: (openness: Double, width: Double, rounding: Double)
    }

    /// The analyzer's silence rest (`LipsyncTimeline.rest`), held firmly through pauses.
    static let rest = Target(openness: 0.15, width: 0.35, rounding: 0.1, dominance: (1, 1, 1))

    private static func vowel(_ openness: Double, _ width: Double, _ rounding: Double) -> Target {
        Target(openness: openness, width: width, rounding: rounding, dominance: (1, 1, 1))
    }

    private static func consonant(_ openness: Double, _ width: Double, _ rounding: Double,
                                  _ dominance: (Double, Double, Double)) -> Target {
        Target(openness: openness, width: width, rounding: rounding, dominance: dominance)
    }

    /// A phone's targets: one, or two for a diphthong (its start and its end).
    static func targets(_ phone: LipsyncPhone) -> [Target] {
        let unstressed = phone.isVowel && phone.stress == 0
        switch phone.symbol {
        // Open: an A.
        case .aa: return [vowel(0.8, 0.5, 0.05)]
        case .ae: return [vowel(0.75, 0.65, 0)]
        case .ah: return [unstressed ? vowel(0.45, 0.48, 0.05) : vowel(0.66, 0.5, 0.05)]
        case .aw: return [vowel(0.78, 0.5, 0.05), vowel(0.5, 0.15, 0.9)]
        case .ay: return [vowel(0.78, 0.52, 0.05), vowel(0.4, 0.92, 0)]
        // Spread: an E.
        case .eh: return [vowel(0.62, 0.78, 0)]
        case .ey: return [vowel(0.58, 0.85, 0), vowel(0.4, 1, 0)]
        case .ih: return [unstressed ? vowel(0.38, 0.75, 0) : vowel(0.42, 0.85, 0)]
        case .iy: return [vowel(0.34, 1, 0)]
        // Rounded: an O or a U.
        case .ao: return [vowel(0.74, 0.25, 0.95)]
        case .ow: return [vowel(0.72, 0.25, 0.95), vowel(0.5, 0.12, 0.95)]
        case .oy: return [vowel(0.72, 0.25, 0.95), vowel(0.4, 0.92, 0)]
        case .uh: return [vowel(0.5, 0.15, 0.9)]
        case .uw: return [vowel(0.48, 0.1, 0.95)]
        case .er: return [unstressed ? vowel(0.4, 0.32, 0.5) : vowel(0.48, 0.25, 0.7)]
        // Lips closed (the closure itself comes from `closures`); width and rounding from context.
        case .m, .b, .p: return [consonant(0.3, 0.45, 0.1, (0.2, 0.3, 0.3))]
        // Lower lip to the teeth: narrow and slightly open.
        case .f, .v: return [consonant(0.24, 0.5, 0.05, (0.9, 0.5, 0.5))]
        case .th, .dh: return [consonant(0.3, 0.55, 0.05, (0.6, 0.3, 0.3))]
        case .s, .z: return [consonant(0.26, 0.68, 0.05, (0.7, 0.3, 0.2))]
        case .sh, .zh, .ch, .jh: return [consonant(0.32, 0.22, 0.8, (0.6, 0.8, 0.9))]
        case .w: return [consonant(0.3, 0.08, 1, (0.7, 0.95, 1))]
        case .r: return [consonant(0.36, 0.3, 0.6, (0.4, 0.6, 0.7))]
        case .y: return [consonant(0.32, 0.9, 0, (0.4, 0.6, 0.6))]
        // The tongue's consonants leave the lips to the vowels around them.
        case .l: return [consonant(0.4, 0.5, 0.05, (0.3, 0.1, 0.1))]
        case .t, .d, .n: return [consonant(0.32, 0.5, 0.05, (0.4, 0.1, 0.1))]
        case .k, .g, .ng: return [consonant(0.38, 0.5, 0.05, (0.3, 0.1, 0.1))]
        // An H is the next vowel, breathed.
        case .hh: return [consonant(0.45, 0.5, 0.05, (0.05, 0.05, 0.05))]
        }
    }

    /// A target's reach beyond its plateau, in hops: how far it bends its neighbours.
    private static let spreadHops = 1.6
    /// The share of a phone's span over which it holds its own target fully.
    private static let plateau = 0.6
    /// How many segments either side can bend a hop's pose.
    private static let reach = 6

    /// One target placed in time (hops), with its plateau's half-width.
    private struct Placed {
        var target: Target
        var center: Double
        var halfWidth: Double
    }

    /// Each hop's coarticulated target for hops `range`, from `segments` (pauses rest).
    static func poses(_ segments: [LipsyncAligner.Segment], hops range: Range<Int>)
        -> [(openness: Double, width: Double, rounding: Double)] {
        var placed: [Placed] = []
        var owner: [Int] = []  // first placed index of each segment
        for segment in segments {
            owner.append(placed.count)
            let span = Double(segment.end - segment.start)
            let targets = segment.phone.map(Self.targets) ?? [rest]
            if targets.count == 1 {
                placed.append(Placed(target: targets[0], center: Double(segment.start) + span / 2,
                                     halfWidth: span * plateau / 2))
            } else {
                // A diphthong: its start over the first 45 %, its end over the rest.
                let split = Double(segment.start) + span * 0.45
                placed.append(Placed(target: targets[0], center: (Double(segment.start) + split) / 2,
                                     halfWidth: (split - Double(segment.start)) * plateau / 2))
                placed.append(Placed(target: targets[1], center: (split + Double(segment.end)) / 2,
                                     halfWidth: (Double(segment.end) - split) * plateau / 2))
            }
        }
        var poses: [(openness: Double, width: Double, rounding: Double)] = []
        poses.reserveCapacity(range.count)
        var index = 0
        for hop in range {
            while index + 1 < segments.count && segments[index].end <= hop { index += 1 }
            guard !segments.isEmpty else {
                poses.append((rest.openness, rest.width, rest.rounding))
                continue
            }
            let t = Double(hop) + 0.5
            let first = owner[max(index - reach, 0)]
            let last = index + reach + 1 < owner.count ? owner[index + reach + 1] : placed.count
            var sum = (0.0, 0.0, 0.0), weight = (0.0, 0.0, 0.0)
            for p in placed[first..<last] {
                let g = exp(-max(0, abs(t - p.center) - p.halfWidth) / spreadHops)
                let w = (p.target.dominance.openness * g, p.target.dominance.width * g, p.target.dominance.rounding * g)
                sum.0 += w.0 * p.target.openness
                sum.1 += w.1 * p.target.width
                sum.2 += w.2 * p.target.rounding
                weight.0 += w.0
                weight.1 += w.1
                weight.2 += w.2
            }
            poses.append((weight.0 > 0 ? sum.0 / weight.0 : rest.openness,
                          weight.1 > 0 ? sum.1 / weight.1 : rest.width,
                          weight.2 > 0 ? sum.2 / weight.2 : rest.rounding))
        }
        return poses
    }

    /// Where M, B and P close the lips, in hops: an M throughout; a B or P from a hop before its
    /// aligned start, since alignment gives a stop's first silent hop to the vowel before (which
    /// keeps at least a hop), until its release. Closures less than a hop apart merge: a P before
    /// a B is not released.
    static func closures(_ segments: [LipsyncAligner.Segment]) -> [(start: Double, end: Double)] {
        var closures: [(start: Double, end: Double)] = []
        for (index, segment) in segments.enumerated() {
            guard let symbol = segment.phone?.symbol, [.m, .b, .p].contains(symbol) else { continue }
            var start = Double(segment.start)
            if symbol != .m, index > 0 { start = max(start - 1, Double(segments[index - 1].start + 1)) }
            let end = Double(segment.end) - (symbol == .m ? 0 : 0.5)
            if let last = closures.last, last.end >= start - 1 {
                closures[closures.count - 1].end = max(last.end, end)
            } else {
                closures.append((start, end))
            }
        }
        return closures
    }
}

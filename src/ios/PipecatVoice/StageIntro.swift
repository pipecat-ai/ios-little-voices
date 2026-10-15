import Foundation

/// How far a face has popped in at the launch intro, drawn on top of the rig about its pivot:
/// its size (0 unseen, past 1 at the overshoot) and a factor on its squash, which the volume
/// rule turns into a stretch. Both are 1 once it has popped in.
struct FacePop: Equatable, Sendable {
    var size = 1.0
    var squash = 1.0

    static let unseen = FacePop(size: 0, squash: 1)

    /// A pop's length: by then both springs are within a millionth of rest, and it is exactly 1
    /// and 1.
    static let duration = 1.5
    /// The head's stretch as it pops in (sy/s).
    static let stretchKick = 5.5

    init(size: Double = 1, squash: Double = 1) {
        self.size = size
        self.squash = squash
    }

    /// The pop `elapsed` s after it began: the size springs from nothing past full size and back
    /// (`markPop`), while the head stretches tall as it grows and squashes wide at the overshoot,
    /// as its free squash does (`freeSquash`).
    init(after elapsed: Double) {
        if elapsed <= 0 {
            self.init(size: 0, squash: 1)
        } else if elapsed >= Self.duration {
            self.init()
        } else {
            let size = SpringSpec.markPop.transition(over: elapsed).apply(-1, 0)
            let squash = SpringSpec.freeSquash.transition(over: elapsed).apply(0, Self.stretchKick)
            self.init(size: 1 + size.y, squash: 1 + squash.y)
        }
    }

    /// `point` (stage) as drawn on a head popped about `anchor` and tilted `tilt`: the halo's
    /// place.
    func place(_ point: Vec2, about anchor: Vec2, tilt: Double) -> Vec2 {
        let local = (point - anchor).rotated(by: -tilt)
        let stretched = Vec2(local.x * size * pow(squash, FaceRig.volumeExponent), local.y * size * squash)
        return anchor + stretched.rotated(by: tilt)
    }
}

/// The launch intro: the characters pop in, shove each other back and forth along the seam, make
/// up, and settle to wait for the human. Its beats run at fixed times from its start. A
/// conversation starting hands over at once: the beats stop, anyone not yet there pops in, and
/// the shove lets go. Under Reduce Motion the faces fade in instead (`StageSimulation`).
struct StageIntro: Sendable {
    enum Beat: Equatable, Sendable {
        /// The face pops in, holding `expression` at the human for `length` s.
        case pop(DuoCharacter, FaceExpression, length: Double)
        /// The face holds `expression` at the other character for `length` s, as `gesture`.
        case look(DuoCharacter, StageGesture, FaceExpression, length: Double)
        /// The shover crouches, the seam pulling back toward them.
        case windUp(DuoCharacter)
        /// The shover pushes the seam's middle into the other's half and stretches into it.
        case shove(DuoCharacter)
        /// The shoved face takes it: squished for `length` s, its impact reaction, a jolt away
        /// from the seam and a ripple along it.
        case squish(DuoCharacter, length: Double)
        /// The shover lets go, and the seam springs back.
        case letGo
    }

    /// The choreography, in seconds from the start. The first pop waits out the system's
    /// cross-fade from the launch screen.
    static let beats: [(time: Double, beat: Beat)] = [
        // Pop! Pop! Each appears beaming at the human.
        (0.25, .pop(.angel, .happy, length: 0.7)),
        (0.45, .pop(.devil, .happy, length: 0.6)),
        // They notice each other: he smirks, she smiles back.
        (0.95, .look(.devil, .glance, .thinking, length: 0.45)),
        (1.05, .look(.angel, .glance, .listening, length: 0.5)),
        // He cackles and shoves her up...
        (1.3, .look(.devil, .laughAlong, .laughing, length: 0.55)),
        (1.3, .windUp(.devil)),
        (1.4, .shove(.devil)),
        (1.48, .squish(.angel, length: 0.45)),
        (1.78, .letGo),
        // ...she huffs and shoves him back down...
        (1.85, .look(.angel, .huff, .grumpy, length: 0.5)),
        (1.85, .windUp(.angel)),
        (1.95, .shove(.angel)),
        (2.03, .squish(.devil, length: 0.45)),
        (2.33, .letGo),
        // ...and they make up: a cheeky wink, a giggle.
        (2.5, .look(.devil, .cheekyWink, .wink, length: 0.75)),
        (2.6, .look(.angel, .laughAlong, .laughing, length: 0.7)),
    ]

    /// How far a shove bows the seam's middle into the other's half (band), and the kick it
    /// starts with (band/s).
    static let shove = (amount: 0.07, kick: 0.45)
    /// How far the wind-up pulls the seam back toward the shover (band).
    static let windUp = 0.012
    /// How far each face rides with the shove (of the seam's travel): pushed, or leaning in.
    static let ride = (pushed: 0.5, leaning: 0.25)

    /// When the intro started; nil while the faces wait unseen for it.
    private(set) var start: Double?
    /// When each face popped in; nil while it is unseen.
    private(set) var pops = PerCharacter<Double?>(angel: nil, devil: nil)
    /// The next beat to run.
    private(set) var next = 0
    /// Who shoves the seam: they come on top as its middle crosses into the other's half.
    var shover: DuoCharacter?

    /// Starts the beats at `time`.
    mutating func begin(at time: Double) {
        guard start == nil else { return }
        start = time
    }

    /// The next beat due at `t`, in order; nil once none is.
    mutating func beat(dueAt t: Double) -> Beat? {
        guard let start, next < Self.beats.count, start + Self.beats[next].time <= t + 1e-9 else { return nil }
        next += 1
        return Self.beats[next - 1].beat
    }

    /// `c` pops in at `t`, unless it already has.
    mutating func popIn(_ c: DuoCharacter, at t: Double) {
        if pops[c] == nil { pops[c] = t }
    }

    /// A conversation starts at `t`: no more beats, anyone unseen pops in, and the shove lets go.
    mutating func handOver(at t: Double) {
        start = start ?? t
        next = Self.beats.count
        for c in DuoCharacter.allCases { popIn(c, at: t) }
        shover = nil
    }

    /// `c`'s pop at `t`.
    func pop(_ c: DuoCharacter, at t: Double) -> FacePop {
        pops[c].map { FacePop(after: t - $0) } ?? .unseen
    }

    /// The next beat's time.
    var nextBeat: Double? {
        guard let start, next < Self.beats.count else { return nil }
        return start + Self.beats[next].time
    }

    /// Beats are still to come or a face is still popping in; false while it waits to start.
    func isRunning(at t: Double) -> Bool {
        guard start != nil else { return false }
        return next < Self.beats.count
            || DuoCharacter.allCases.contains { pops[$0].map { t - $0 < FacePop.duration } ?? false }
    }
}

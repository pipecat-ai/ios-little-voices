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

/// The launch intro: the characters pop in, shove each other in turn, each taking the floor as a
/// speaker does and squishing the other, make up, and settle to wait for the human. Its beats run
/// at fixed times from its start. A conversation starting hands over at once: the beats stop,
/// anyone not yet there pops in, and a shover's floor is let go. Under Reduce Motion the faces
/// fade in instead (`StageSimulation`).
struct StageIntro: Sendable {
    enum Beat: Equatable, Sendable {
        /// The face pops in, holding `expression` at the human for `length` s.
        case pop(DuoCharacter, FaceExpression, length: Double)
        /// The face holds `expression` at the other character for `length` s, as `gesture`.
        case look(DuoCharacter, StageGesture, FaceExpression, length: Double)
        /// The shover crouches, gathering.
        case windUp(DuoCharacter)
        /// The shover takes the floor as a speaker does, though nobody speaks: the seam hands
        /// over to them, and the other is squished against it.
        case shove(DuoCharacter)
        /// The shoved face looks squished for `length` s.
        case squish(DuoCharacter, length: Double)
        /// The shover lets the floor go, and the seam is released back to nobody's.
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
        // He sets his jaw and shoves her up, and cackles as she is squashed...
        (1.3, .look(.devil, .shove, .determined, length: 0.55)),
        (1.3, .windUp(.devil)),
        (1.45, .shove(.devil)),
        (1.75, .squish(.angel, length: 0.65)),
        (1.95, .look(.devil, .laughAlong, .laughing, length: 0.45)),
        (2.4, .letGo),
        // ...she glares down at him and shoves him back...
        (2.65, .look(.angel, .shove, .determined, length: 0.55)),
        (2.65, .windUp(.angel)),
        (2.8, .shove(.angel)),
        (3.1, .squish(.devil, length: 0.65)),
        (3.75, .letGo),
        // ...and they make up: a cheeky wink, a giggle.
        (4.0, .look(.devil, .cheekyWink, .wink, length: 0.75)),
        (4.1, .look(.angel, .laughAlong, .laughing, length: 0.7)),
    ]

    /// When the logo drops in over the laughing pair and when it leaves, in seconds from the
    /// start, and how long it takes to slide away.
    static let logo = (enter: 4.0, leave: 6.0, exit: 0.45)

    /// The intro's length: until its last look ends and the logo has left.
    static let length = max(beats.map { time, beat in
        switch beat {
        case .pop(_, _, let length), .look(_, _, _, let length), .squish(_, let length): time + length
        case .windUp, .shove, .letGo: time
        }
    }.max() ?? 0, logo.leave + logo.exit)

    /// When the intro started; nil while the faces wait unseen for it.
    private(set) var start: Double?
    /// When each face popped in; nil while it is unseen.
    private(set) var pops = PerCharacter<Double?>(angel: nil, devil: nil)
    /// The next beat to run.
    private(set) var next = 0
    /// A conversation has taken over: the intro ends once every face has popped in.
    private(set) var handedOver = false

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

    /// A conversation starts at `t`: no more beats, and anyone unseen pops in.
    mutating func handOver(at t: Double) {
        start = start ?? t
        next = Self.beats.count
        handedOver = true
        for c in DuoCharacter.allCases { popIn(c, at: t) }
    }

    /// Whether the logo shows at `t`: not once a conversation has taken over.
    func showsLogo(at t: Double) -> Bool {
        guard let start, !handedOver else { return false }
        return (Self.logo.enter..<Self.logo.leave).contains(t - start)
    }

    /// `c`'s pop at `t`.
    func pop(_ c: DuoCharacter, at t: Double) -> FacePop {
        pops[c].map { FacePop(after: t - $0) } ?? .unseen
    }

    /// Its beats or its logo have not finished, unless a conversation took over, or a face is
    /// still popping in; false while it waits to start.
    func isRunning(at t: Double) -> Bool {
        guard let start else { return false }
        return !handedOver && t - start < Self.length
            || DuoCharacter.allCases.contains { pops[$0].map { t - $0 < FacePop.duration } ?? false }
    }
}

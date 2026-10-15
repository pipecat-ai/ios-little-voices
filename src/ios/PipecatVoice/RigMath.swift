import Foundation

/// A 2-D vector in stage points or face units (fu); y points down.
struct Vec2: Equatable, Hashable, Sendable {
    var x: Double
    var y: Double

    static let zero = Vec2(0, 0)

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    var length: Double { (x * x + y * y).squareRoot() }

    /// This offset on the side `sigma` (−1 screen left, +1 screen right): x is multiplied by σ.
    func sided(_ sigma: Double) -> Vec2 { Vec2(sigma * x, y) }

    func dot(_ other: Vec2) -> Double { x * other.x + y * other.y }

    /// Rotated by `radians`; positive turns +x toward +y (clockwise on screen).
    func rotated(by radians: Double) -> Vec2 {
        let c = cos(radians), s = sin(radians)
        return Vec2(x * c - y * s, x * s + y * c)
    }

    static func lerp(_ a: Vec2, _ b: Vec2, _ t: Double) -> Vec2 { a + (b - a) * t }

    static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    static func * (a: Vec2, k: Double) -> Vec2 { Vec2(a.x * k, a.y * k) }
    static func * (k: Double, a: Vec2) -> Vec2 { Vec2(a.x * k, a.y * k) }
    static func / (a: Vec2, k: Double) -> Vec2 { Vec2(a.x / k, a.y / k) }
    static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }
    static func += (a: inout Vec2, b: Vec2) { a = a + b }
    static func -= (a: inout Vec2, b: Vec2) { a = a - b }
}

/// Scalar helpers shared by the rig, the layout solver and the renderer.
enum RigMath {
    static func clamp(_ x: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(x, lower), upper)
    }

    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// Hermite smoothstep: 0 at or below `edge0`, 1 at or above `edge1`.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    /// Quadratic ease-in on [0, 1].
    static func easeIn(_ t: Double) -> Double {
        let t = clamp(t, 0, 1)
        return t * t
    }

    /// Cubic ease-in-out on [0, 1].
    static func easeInOut(_ t: Double) -> Double {
        let t = clamp(t, 0, 1)
        if t < 0.5 { return 4 * t * t * t }
        let u = -2 * t + 2
        return 1 - u * u * u / 2
    }

    /// Ease-out-back on [0, 1] with back constant `c`: overshoots 1 and settles on it.
    static func easeOutBack(_ t: Double, c: Double) -> Double {
        let s = clamp(t, 0, 1) - 1
        return 1 + (c + 1) * s * s * s + c * s * s
    }

    /// The ease-out-back constant whose peak overshoot is `overshoot` (0.04 for 4%).
    /// The peak of `easeOutBack` is 1 + 4c³ / (27(c + 1)²), solved here by bisection.
    static func backConstant(overshoot: Double) -> Double {
        var lower = 0.0, upper = 10.0
        for _ in 0..<80 {
            let c = (lower + upper) / 2
            if 4 * c * c * c / (27 * (c + 1) * (c + 1)) < overshoot { lower = c } else { upper = c }
        }
        return (lower + upper) / 2
    }
}

// MARK: - Springs

/// The exact one-step map of a damped spring on (y = x − target, v).
struct SpringTransition: Equatable, Sendable {
    var yy: Double, yv: Double
    var vy: Double, vv: Double

    func apply(_ y: Double, _ v: Double) -> (y: Double, v: Double) {
        (yy * y + yv * v, vy * y + vv * v)
    }
}

/// A unit-mass spring given SwiftUI-style: `response` is the undamped period in seconds and
/// `dampingFraction` is ζ. ω = 2π/response, stiffness ω², damping 2ζω. The transition matrix
/// for one fixed substep is precomputed, so stepping is exact at any frame cadence.
struct SpringSpec: Equatable, Sendable {
    /// The fixed simulation substep, 1/240 s (the stepper's).
    static let step = FixedStepper.step

    let response: Double
    let dampingFraction: Double
    let omega: Double
    /// The transition over one substep.
    let transition: SpringTransition

    init(response: Double, dampingFraction: Double) {
        precondition(response > 0 && dampingFraction >= 0, "Invalid spring \(response) / \(dampingFraction)")
        self.response = response
        self.dampingFraction = dampingFraction
        omega = 2 * Double.pi / response
        transition = Self.transition(omega: omega, zeta: dampingFraction, over: Self.step)
    }

    var stiffness: Double { omega * omega }
    var damping: Double { 2 * dampingFraction * omega }

    /// The peak overshoot of a step response from rest, exp(−ζπ/√(1−ζ²)); 0 when ζ ≥ 1.
    var overshoot: Double {
        let zeta = dampingFraction
        return zeta < 1 ? exp(-zeta * Double.pi / (1 - zeta * zeta).squareRoot()) : 0
    }

    /// The exact transition over `t` seconds.
    func transition(over t: Double) -> SpringTransition {
        Self.transition(omega: omega, zeta: dampingFraction, over: t)
    }

    private static func transition(omega w: Double, zeta: Double, over t: Double) -> SpringTransition {
        if zeta < 1 {
            // y′ = e(yC + (v + ζωy)S/ωd), v′ = e(vC − (ω²y + ζωv)S/ωd)
            let wd = w * (1 - zeta * zeta).squareRoot()
            let e = exp(-zeta * w * t), c = cos(wd * t), s = sin(wd * t) / wd
            return SpringTransition(yy: e * (c + zeta * w * s), yv: e * s,
                                    vy: -e * w * w * s, vv: e * (c - zeta * w * s))
        }
        if zeta == 1 {
            // y′ = E(y + (v + ωy)t), v′ = E(v − ω(v + ωy)t)
            let e = exp(-w * t)
            return SpringTransition(yy: e * (1 + w * t), yv: e * t,
                                    vy: -e * w * w * t, vv: e * (1 - w * t))
        }
        // Overdamped: y = C₁e^(r₁t) + C₂e^(r₂t), with C₁ = (v − r₂y)/(r₁ − r₂), C₂ = y − C₁.
        let root = (zeta * zeta - 1).squareRoot()
        let r1 = -w * (zeta - root), r2 = -w * (zeta + root)
        let a = exp(r1 * t), b = exp(r2 * t), d = r1 - r2
        return SpringTransition(yy: (r1 * b - r2 * a) / d, yv: (a - b) / d,
                                vy: r1 * r2 * (b - a) / d, vv: (r1 * a - r2 * b) / d)
    }
}

extension SpringSpec {
    // Head
    static let headAnchor = SpringSpec(response: 0.42, dampingFraction: 0.62)
    static let headScale = SpringSpec(response: 0.50, dampingFraction: 0.60)
    static let freeSquash = SpringSpec(response: 0.24, dampingFraction: 0.32)
    static let contactSquash = SpringSpec(response: 0.12, dampingFraction: 0.45)
    /// The seam's press on a squished face, easing in with the contact and out as it is freed.
    static let press = SpringSpec(response: 0.12, dampingFraction: 1.0)
    static let tilt = SpringSpec(response: 0.55, dampingFraction: 0.45)
    static let parallax = SpringSpec(response: 0.30, dampingFraction: 0.80)
    // Eyes
    static let gaze = SpringSpec(response: 0.08, dampingFraction: 0.88)
    static let eyeOpen = SpringSpec(response: 0.10, dampingFraction: 0.85)
    static let eyeMorph = SpringSpec(response: 0.18, dampingFraction: 1.0)
    static let lids = SpringSpec(response: 0.14, dampingFraction: 0.80)
    static let glyph = SpringSpec(response: 0.10, dampingFraction: 1.0)
    // Brows
    static let brows = SpringSpec(response: 0.18, dampingFraction: 0.50)
    // Mouth
    static let mouthExpression = SpringSpec(response: 0.16, dampingFraction: 0.70)
    static let mouthFeature = SpringSpec(response: 0.12, dampingFraction: 1.0)
    static let talkWeight = SpringSpec(response: 0.08, dampingFraction: 1.0)
    // Accessories
    static let blush = SpringSpec(response: 0.30, dampingFraction: 1.0)
    static let cheekPuff = SpringSpec(response: 0.28, dampingFraction: 0.40)
    static let haloPosition = SpringSpec(response: 0.34, dampingFraction: 0.32)
    static let haloRotation = SpringSpec(response: 0.45, dampingFraction: 0.25)
    static let haloSquash = SpringSpec(response: 0.20, dampingFraction: 0.30)
    static let wingAngle = SpringSpec(response: 0.30, dampingFraction: 0.28)
    static let hornAngle = SpringSpec(response: 0.20, dampingFraction: 0.42)
    static let hornStretch = SpringSpec(response: 0.16, dampingFraction: 0.30)
    static let markPop = SpringSpec(response: 0.25, dampingFraction: 0.45)
    // Seam
    static let windupIn = SpringSpec(response: 0.14, dampingFraction: 1.0)
    static let windupOut = SpringSpec(response: 0.10, dampingFraction: 0.90)
    static let baseAngelPush = SpringSpec(response: 0.44, dampingFraction: 0.48)
    static let baseDevilPush = SpringSpec(response: 0.38, dampingFraction: 0.55)
    static let bulgeLaunch = SpringSpec(response: 0.38, dampingFraction: 0.34)
    static let collapse = SpringSpec(response: 0.24, dampingFraction: 0.50)
    static let waveAmplitude = SpringSpec(response: 0.50, dampingFraction: 0.60)
    static let releaseBase = SpringSpec(response: 0.60, dampingFraction: 0.75)
    static let releaseBulge = SpringSpec(response: 0.45, dampingFraction: 0.60)
    static let interruptBase = SpringSpec(response: 0.30, dampingFraction: 0.85)
    static let interruptBulge = SpringSpec(response: 0.25, dampingFraction: 0.85)
    static let lean = SpringSpec(response: 0.45, dampingFraction: 0.65)
    static let pulse = SpringSpec(response: 0.22, dampingFraction: 0.50)
    static let relax = SpringSpec(response: 0.60, dampingFraction: 0.80)
    /// The idle drift settling into its still S-curve and setting off again.
    static let driftSettle = SpringSpec(response: 2.0, dampingFraction: 1.0)
    /// Caption bubble slot changes (SwiftUI `.spring(response: 0.45, dampingFraction: 0.85)`).
    static let bubble = SpringSpec(response: 0.45, dampingFraction: 0.85)

    /// Every named preset, for the checks.
    static let presets: [(name: String, spec: SpringSpec)] = [
        ("headAnchor", headAnchor), ("headScale", headScale), ("freeSquash", freeSquash),
        ("contactSquash", contactSquash), ("press", press), ("tilt", tilt), ("parallax", parallax), ("gaze", gaze),
        ("eyeOpen", eyeOpen), ("eyeMorph", eyeMorph), ("lids", lids), ("glyph", glyph),
        ("brows", brows), ("mouthExpression", mouthExpression), ("mouthFeature", mouthFeature),
        ("talkWeight", talkWeight), ("blush", blush), ("cheekPuff", cheekPuff),
        ("haloPosition", haloPosition), ("haloRotation", haloRotation), ("haloSquash", haloSquash),
        ("wingAngle", wingAngle), ("hornAngle", hornAngle), ("hornStretch", hornStretch),
        ("markPop", markPop), ("windupIn", windupIn), ("windupOut", windupOut),
        ("baseAngelPush", baseAngelPush), ("baseDevilPush", baseDevilPush),
        ("bulgeLaunch", bulgeLaunch), ("collapse", collapse), ("waveAmplitude", waveAmplitude),
        ("releaseBase", releaseBase), ("releaseBulge", releaseBulge),
        ("interruptBase", interruptBase), ("interruptBulge", interruptBulge), ("lean", lean),
        ("pulse", pulse), ("relax", relax), ("driftSettle", driftSettle), ("bubble", bubble),
    ]
}

/// A scalar spring stepped exactly at the fixed substep, named apart from SwiftUI's `Spring`.
/// It keeps only its spec's one-substep transition, so the rig's ~160 springs stay small.
struct RigSpring: Sendable {
    /// The spec's transition over one substep.
    private(set) var transition: SpringTransition
    var value: Double
    var velocity: Double
    var target: Double
    /// The parameter's range; settling tolerances scale with it.
    var range: Double

    init(_ value: Double = 0, spec: SpringSpec, range: Double = 1) {
        transition = spec.transition
        self.value = value
        velocity = 0
        target = value
        self.range = range
    }

    /// Switches to `spec`, keeping position and velocity.
    mutating func use(_ spec: SpringSpec) { transition = spec.transition }

    /// Advances one substep (1/240 s).
    mutating func step() {
        let next = transition.apply(value - target, velocity)
        value = target + next.y
        velocity = next.v
    }

    /// Moves the rest point, keeping position and velocity.
    mutating func retarget(_ newTarget: Double) { target = newTarget }

    mutating func kick(_ deltaVelocity: Double) { velocity += deltaVelocity }

    /// Jumps to rest at the target.
    mutating func snap() {
        value = target
        velocity = 0
    }

    /// Within 1e-3 of the range of the target and slower than 1e-2 range per second.
    var isSettled: Bool {
        abs(value - target) < 1e-3 * range && abs(velocity) < 1e-2 * range
    }
}

/// A 2-D spring for positions: both axes share one transition and range.
struct RigSpring2: Sendable {
    /// The spec's transition over one substep.
    private(set) var transition: SpringTransition
    var value: Vec2
    var velocity: Vec2
    var target: Vec2
    /// The range of each axis; settling tolerances scale with it.
    var range: Double

    init(_ value: Vec2 = .zero, spec: SpringSpec, range: Double = 1) {
        transition = spec.transition
        self.value = value
        velocity = .zero
        target = value
        self.range = range
    }

    /// Switches to `spec`, keeping position and velocity.
    mutating func use(_ spec: SpringSpec) { transition = spec.transition }

    /// Advances one substep (1/240 s).
    mutating func step() {
        let x = transition.apply(value.x - target.x, velocity.x)
        let y = transition.apply(value.y - target.y, velocity.y)
        value = Vec2(target.x + x.y, target.y + y.y)
        velocity = Vec2(x.v, y.v)
    }

    /// Moves the rest point, keeping position and velocity.
    mutating func retarget(_ newTarget: Vec2) { target = newTarget }

    mutating func kick(_ deltaVelocity: Vec2) { velocity += deltaVelocity }

    /// Jumps to rest at the target.
    mutating func snap() {
        value = target
        velocity = .zero
    }

    /// Both axes within 1e-3 of the range of the target and slower than 1e-2 range per second.
    var isSettled: Bool {
        abs(value.x - target.x) < 1e-3 * range && abs(value.y - target.y) < 1e-3 * range
            && abs(velocity.x) < 1e-2 * range && abs(velocity.y) < 1e-2 * range
    }
}

// MARK: - Randomness

/// SplitMix64 (Steele, Lea and Flood): the rig's only source of randomness. Each character and
/// the stage draw from their own stream, so one stream's draws never shift another's.
struct SplitMix64: RandomNumberGenerator, Sendable {
    enum Stream: Sendable {
        case angel, devil, stage

        var salt: UInt64 {
            switch self {
            case .angel: 0x9E37_79B9_7F4A_7C15
            case .devil: 0xD1B5_4A32_D192_ED03
            case .stage: 0x94D0_49BB_1331_11EB
            }
        }
    }

    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    init(seed: UInt64, stream: Stream) {
        state = seed ^ stream.salt
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform draw in [0, 1) with 53 random bits.
    mutating func uniform() -> Double { Double(next() >> 11) * 0x1p-53 }

    mutating func uniform(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * uniform()
    }

    /// True with probability `p`.
    mutating func chance(_ p: Double) -> Bool { uniform() < p }

    /// −1 or +1 with equal probability.
    mutating func sign() -> Double { next() >> 63 == 0 ? -1 : 1 }
}

// MARK: - Envelopes and paths

/// A blink: close over 60 ms (ease-in), hold 40 ms, open over 120 ms with a 4% ease-out-back.
///
/// `closure` is the lid amount in 0…1 that enters the eye's openness
/// `open·(1 − max(blink, closed))`, and `reopenGain` (≥ 1, `FacePose.reopen`) multiplies the
/// result, so the reopening eye overshoots its rest by 4% instead of the overshoot being lost
/// in the `max`.
enum BlinkEnvelope {
    static let close = 0.06
    static let hold = 0.04
    static let open = 0.12
    static let overshoot = 0.04
    static let duration = close + hold + open
    private static let back = RigMath.backConstant(overshoot: overshoot)

    /// The signed closure `t` seconds after the blink starts: 1 when shut, dipping below 0
    /// (to −`overshoot`) while the eye reopens past rest; 0 outside the blink.
    private static func shape(at t: Double) -> Double {
        if t <= 0 || t >= duration { return 0 }
        if t < close { return RigMath.easeIn(t / close) }
        if t < close + hold { return 1 }
        return 1 - RigMath.easeOutBack((t - close - hold) / open, c: back)
    }

    /// The lid closure in 0…1, `t` seconds after the blink starts (0 outside the blink).
    static func closure(at t: Double) -> Double { max(0, shape(at: t)) }

    /// The openness multiplier of the reopening overshoot: 1 + the ease-out-back's excess, up
    /// to 1.04; 1 while closing, shut and outside the blink.
    static func reopenGain(at t: Double) -> Double { 1 + max(0, -shape(at: t)) }
}

/// A keyframed gaze path in [−1, 1]², for eye rolls and other scripted looks.
struct GazePath: Sendable {
    enum Easing: Sendable {
        case linear, easeInOut
    }

    struct Key: Sendable {
        var to: Vec2
        var duration: Double
        var easing: Easing
    }

    var start: Vec2
    var keys: [Key]

    var duration: Double { keys.reduce(0) { $0 + $1.duration } }

    /// The gaze `t` seconds into the path; holds the last key afterwards.
    func value(at t: Double) -> Vec2 {
        var from = start
        var elapsed = max(t, 0)
        for key in keys {
            if elapsed < key.duration {
                let p = elapsed / key.duration
                return Vec2.lerp(from, key.to, key.easing == .linear ? p : RigMath.easeInOut(p))
            }
            elapsed -= key.duration
            from = key.to
        }
        return from
    }

    /// The devil's eye roll from `home`: (−0.85·direction, −0.35), over the top through (0, −1),
    /// to (0.85·direction, −0.35), so it ends on side `direction` (±1). The legs take 0.16, 0.20
    /// and 0.20 s, then a 0.18-s hold and a 0.28-s return home.
    static func eyeRoll(from home: Vec2, direction: Double) -> GazePath {
        let side = direction < 0 ? -1.0 : 1.0
        return GazePath(start: home, keys: [
            Key(to: Vec2(-0.85 * side, -0.35), duration: 0.16, easing: .easeInOut),
            Key(to: Vec2(0, -1), duration: 0.20, easing: .easeInOut),
            Key(to: Vec2(0.85 * side, -0.35), duration: 0.20, easing: .easeInOut),
            Key(to: Vec2(0.85 * side, -0.35), duration: 0.18, easing: .linear),
            Key(to: home, duration: 0.28, easing: .easeInOut),
        ])
    }
}

/// Uniform Catmull-Rom curves through sample points, as cubic Béziers or scalar samples.
enum CatmullRom {
    /// Bézier controls of the segment p1 → p2: c₁ = p1 + (p2 − p0)/6, c₂ = p2 − (p3 − p1)/6.
    static func controls(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2) -> (Vec2, Vec2) {
        (p1 + (p2 - p0) / 6, p2 - (p3 - p1) / 6)
    }

    /// Calls `body(start, control1, control2, end)` for each segment through `points`; the end
    /// points act as their own outer neighbours. Allocates nothing.
    static func forEachSegment(_ points: [Vec2], _ body: (Vec2, Vec2, Vec2, Vec2) -> Void) {
        let n = points.count
        guard n >= 2 else { return }
        for i in 0..<(n - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i]
            let p2 = points[i + 1], p3 = points[min(i + 2, n - 1)]
            let (c1, c2) = controls(p0, p1, p2, p3)
            body(p1, c1, c2, p2)
        }
    }

    /// The scalar Catmull-Rom polynomial through y1 (t = 0) and y2 (t = 1).
    static func value(_ y0: Double, _ y1: Double, _ y2: Double, _ y3: Double, _ t: Double) -> Double {
        let t2 = t * t, t3 = t2 * t
        return 0.5 * (2 * y1 + (y2 - y0) * t + (2 * y0 - 5 * y1 + 4 * y2 - y3) * t2
            + (3 * y1 - y0 - 3 * y2 + y3) * t3)
    }

    /// Samples equally spaced `values` over u ∈ [0, 1] (free ends: the ghost nodes repeat
    /// their neighbours). Outside [0, 1] the edge value holds.
    static func sample(_ values: [Double], at u: Double) -> Double {
        let n = values.count
        guard n > 1 else { return values.first ?? 0 }
        let x = RigMath.clamp(u, 0, 1) * Double(n - 1)
        let i = min(Int(x), n - 2)
        let t = x - Double(i)
        return value(values[max(i - 1, 0)], values[i], values[i + 1], values[min(i + 2, n - 1)], t)
    }
}

// MARK: - Fixed stepping

/// Counts fixed 1/240-s substeps. Sim time is always an exact substep boundary, `index`/240,
/// so the same events land on the same substeps whatever the frame cadence.
struct FixedStepper: Sendable {
    static let rate = 240.0
    static let step = 1 / rate
    /// At most this many substeps per frame (0.1 s); a longer gap is a hitch.
    static let maxSteps = 24

    private(set) var index: Int64

    init(time: Double = 0) {
        index = Self.index(atOrBefore: time)
    }

    var time: Double { Double(index) / Self.rate }

    /// The first boundary at or after `t`.
    static func index(atOrAfter t: Double) -> Int64 { Int64((t * rate - 1e-7).rounded(.up)) }

    /// The last boundary at or before `t`.
    static func index(atOrBefore t: Double) -> Int64 { Int64((t * rate + 1e-7).rounded(.down)) }

    /// Moves to the last boundary at or before `t`: one substep on, or a settled fast-forward.
    mutating func skip(to t: Double) {
        index = max(index, Self.index(atOrBefore: t))
    }
}

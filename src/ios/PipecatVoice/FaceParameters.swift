import Foundation

/// One sample of a speaking mouth, from `LipsyncTimeline.Pose`: openness, width and rounding,
/// each in 0…1. The rig reads it at every substep; nothing smooths it on the way in.
struct MouthDrive: Equatable, Sendable {
    var openness: Double
    var width: Double
    var rounding: Double

    /// The analyzer's silence rest (`LipsyncTimeline.rest`): lips nearly closed.
    static let rest = MouthDrive(openness: 0.15, width: 0.35, rounding: 0.1)

    /// Openness normalised for the mouth, ô = clamp((o − 0.13)/0.72, 0, 1): the rest pose maps
    /// to 0.028 (a closed line) and a lip closure (0.02) to 0.
    var talkOpen: Double { RigMath.clamp((openness - 0.13) / 0.72, 0, 1) }

    /// The drive whose normalised openness is `talkOpen`, at mid width and no rounding.
    init(talkOpen: Double, width: Double = 0.5, rounding: Double = 0.1) {
        self.init(openness: 0.13 + 0.72 * talkOpen, width: width, rounding: rounding)
    }

    init(openness: Double, width: Double, rounding: Double) {
        self.openness = openness
        self.width = width
        self.rounding = rounding
    }
}

/// A value for the screen-left and the screen-right feature.
struct PerSide<Value: Sendable>: Sendable {
    var left: Value
    var right: Value

    init(left: Value, right: Value) {
        self.left = left
        self.right = right
    }

    init(_ both: Value) {
        self.init(left: both, right: both)
    }

    /// The feature on side σ (−1 screen left, +1 screen right).
    subscript(sigma: Double) -> Value {
        get { sigma < 0 ? left : right }
        set { if sigma < 0 { left = newValue } else { right = newValue } }
    }
}

extension PerSide: Equatable where Value: Equatable {}

// MARK: - Parameters

/// One eye. Openness is `open·(1 − max(blink, closed))`; the closed glyph's weights (`arcUp` ∩,
/// `arcDown` ∪, `chevron` toward the nose) sum to 1.
struct EyeParams: Equatable, Sendable {
    var open = 1.0
    var size = 1.0
    /// 0 is a glossy ink bead, 1 a sclera with an ink iris.
    var sclera = 0.0
    /// The iris radius as a fraction of rx (0.45…0.75).
    var iris = 0.6
    /// How far the iris sits toward the nose and up, 0…1 of `DevilGeometry.pupilInward`: the
    /// devil's mischievous look. It gives way as the gaze turns sideways.
    var inward = 0.0
    var highlight = 1.0
    var highlight2 = 0.0
    var sparkle = 0.0
    var starry = 0.0
    /// How far the top lid comes down (0…0.7 of the eye's height).
    var lidTop = 0.0
    /// Degrees; positive lowers the lid's inner end.
    var lidAngle = 0.0
    var lidInk = 0.0
    var lowerLid = 0.0
    var closed = 0.0
    var arcUp = 1.0
    var arcDown = 0.0
    var chevron = 0.0
}

/// One brow: offsets from the character's base brow.
struct BrowParams: Equatable, Sendable {
    /// fu; positive moves the brow down.
    var dy = 0.0
    /// Degrees added to the base angle; positive lowers the inner end.
    var angle = 0.0
    /// Multiplies the base arch.
    var arch = 1.0
    var alpha = 1.0
}

/// The mouth, in fu around the character's mouth anchor.
struct MouthParams: Equatable, Sendable {
    var width = 54.0
    /// The opening's depth.
    var open = 0.0
    /// Corner lift; positive is up.
    var corner = 0.0
    /// Positive raises the right corner.
    var skew = 0.0
    /// 0 is the D shape, 1 an O.
    var round = 0.0
    var tongue = 0.0
    /// The fang's size, 0…1 (the devil's).
    var fang = 0.0
    /// The fang's x as a fraction of the half width.
    var fangX = 0.0
    var shiftX = 0.0
    /// The closed mouth's thickness: the least depth of the ink shape.
    var line = 5.0
}

/// Everything around the features: blush, marks, the halo's glow, wing and horn rest angles and
/// the head's expression offsets.
struct AccessoryParams: Equatable, Sendable {
    var blush = 0.0
    /// Multiplies the blush ellipse.
    var blushSize = 1.0
    // Angel marks.
    var dashes = 0.0
    var sparkles = 0.0
    var puffs = 0.0
    // Devil marks: the motion dashes and the anger vein.
    var motion = 0.0
    var annoyed = 0.0
    var haloGlow = 1.0
    /// Degrees; positive swings the wing tips away from the face.
    var wingSpread = 0.0
    /// Degrees; positive turns the horn tips outward.
    var hornSplay = 0.0
    /// Multiplies the head's scale.
    var scaleBias = 1.0
    /// Head tilt in degrees; positive turns clockwise on screen.
    var tilt = 0.0
    /// Head offset in fu; positive is down.
    var headDy = 0.0
}

/// A whole face's parameters: the springs' targets and, read back, their current values.
struct FaceTargets: Equatable, Sendable {
    var eyes = PerSide(EyeParams())
    var brows = PerSide(BrowParams())
    var mouth = MouthParams()
    var accessories = AccessoryParams()
    /// Where the eyes look, in [−1, 1]² (+y down).
    var gaze = Vec2.zero

    /// One sprung scalar: its key path, spring and range (for settling).
    struct Channel {
        let path: WritableKeyPath<FaceTargets, Double>
        let spec: SpringSpec
        let range: Double
    }

    /// Every sprung parameter with its spring. Head tilt, scale bias and head offset are read
    /// straight from the targets by the head springs.
    static let channels: [Channel] = {
        var channels: [Channel] = []
        func add(_ path: WritableKeyPath<FaceTargets, Double>, _ spec: SpringSpec, _ range: Double) {
            channels.append(Channel(path: path, spec: spec, range: range))
        }
        for side in [\FaceTargets.eyes.left, \FaceTargets.eyes.right] {
            add(side.appending(path: \.open), .eyeOpen, 1)
            add(side.appending(path: \.size), .eyeOpen, 1)
            add(side.appending(path: \.sclera), .eyeMorph, 1)
            add(side.appending(path: \.iris), .eyeMorph, 1)
            add(side.appending(path: \.inward), .eyeMorph, 1)
            add(side.appending(path: \.highlight), .eyeMorph, 1)
            add(side.appending(path: \.highlight2), .eyeMorph, 1)
            add(side.appending(path: \.sparkle), .eyeMorph, 1)
            add(side.appending(path: \.starry), .eyeMorph, 1)
            add(side.appending(path: \.lidTop), .lids, 1)
            add(side.appending(path: \.lidAngle), .lids, 30)
            add(side.appending(path: \.lidInk), .lids, 1)
            add(side.appending(path: \.lowerLid), .lids, 1)
            add(side.appending(path: \.closed), .glyph, 1)
            add(side.appending(path: \.arcUp), .glyph, 1)
            add(side.appending(path: \.arcDown), .glyph, 1)
            add(side.appending(path: \.chevron), .glyph, 1)
        }
        for side in [\FaceTargets.brows.left, \FaceTargets.brows.right] {
            add(side.appending(path: \.dy), .brows, 20)
            add(side.appending(path: \.angle), .brows, 30)
            add(side.appending(path: \.arch), .brows, 2)
            add(side.appending(path: \.alpha), .brows, 1)
        }
        add(\.mouth.width, .mouthExpression, 60)
        add(\.mouth.open, .mouthExpression, 30)
        add(\.mouth.corner, .mouthExpression, 10)
        add(\.mouth.skew, .mouthExpression, 10)
        add(\.mouth.round, .mouthExpression, 1)
        add(\.mouth.fangX, .mouthExpression, 1)
        add(\.mouth.shiftX, .mouthExpression, 10)
        add(\.mouth.line, .mouthExpression, 5)
        add(\.mouth.tongue, .mouthFeature, 1)
        add(\.mouth.fang, .mouthFeature, 1)
        add(\.accessories.blush, .blush, 1)
        add(\.accessories.blushSize, .blush, 1)
        add(\.accessories.haloGlow, .blush, 1)
        add(\.accessories.dashes, .markPop, 1)
        add(\.accessories.sparkles, .markPop, 1)
        add(\.accessories.puffs, .markPop, 1)
        add(\.accessories.motion, .markPop, 1)
        add(\.accessories.annoyed, .markPop, 1)
        add(\.accessories.wingSpread, .blush, 30)
        add(\.accessories.hornSplay, .blush, 30)
        add(\.gaze.x, .gaze, 1)
        add(\.gaze.y, .gaze, 1)
        return channels
    }()

    /// Every channel's value, in `channels` order.
    func value(_ channel: Int) -> Double { self[keyPath: Self.channels[channel].path] }
}

// MARK: - Lip sync

/// Maps a lip-sync pose onto the expression's mouth: pure, with no smoothing, so the mouth
/// follows the voice exactly. `talk` (τ) blends from the expression to speech.
enum LipSyncMapping {
    /// The deepest speaking opening (fu).
    static func maxOpen(_ c: DuoCharacter) -> Double {
        c == .angel ? AngelGeometry.mouthTalkDepth : DevilGeometry.mouthTalkDepth
    }
    /// The least opening of a laughing speaker's syllables.
    static func laughOpen(_ c: DuoCharacter) -> Double { c == .angel ? 28 : 30 }
    /// Fully spread lips part at least this fraction of the full opening, as in an E.
    static let spreadOpening = 0.35

    static func map(_ e: MouthParams, drive: MouthDrive?, talk tau: Double, character c: DuoCharacter,
                    laughing: Bool = false) -> MouthParams {
        c == .angel ? angel(e, drive: drive ?? .rest, talk: tau, laughing: laughing)
            : devil(e, drive: drive ?? .rest, talk: tau, laughing: laughing)
    }

    /// How far the jaw opens: 0 at rest and at closures, 1 wide open. Eased, so small openings
    /// still read; above `kneeOpenness` it eases level into the full opening at ô = 1 (openness
    /// 0.85), so the loudest open vowels still move instead of sitting at the maximum.
    static func opening(_ d: MouthDrive) -> Double {
        let o = d.openness
        guard o > kneeOpenness else { return eased(o) }
        // A cubic from the curve's value and slope at the knee to 1, level, at ô = 1.
        let t = min((o - kneeOpenness) / (fullOpenness - kneeOpenness), 1)
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * kneeOpening + (t3 - 2 * t2 + t) * kneeSlope + (3 * t2 - 2 * t3)
    }

    private static func eased(_ openness: Double) -> Double {
        pow(RigMath.clamp((openness - 0.14) / 0.62, 0, 1), 0.85)
    }
    private static let kneeOpenness = 0.6
    private static let fullOpenness = MouthDrive(talkOpen: 1).openness
    private static let kneeOpening = eased(kneeOpenness)
    /// The eased curve's slope at the knee, per unit of the knee's span.
    private static let kneeSlope = 0.85 * kneeOpening / (kneeOpenness - 0.14) * (fullOpenness - kneeOpenness)

    /// How spread the lips are, 0…1, from a high F2 (an E or a fronted U). Such vowels have a
    /// low F1, so the jaw reads nearly shut: spread lips part the mouth by `spreadOpening`
    /// and widen it at any opening.
    static func spread(_ d: MouthDrive) -> Double { RigMath.smoothstep(0.55, 0.9, d.width) }

    /// How far the lips part: the jaw's opening, or the spread lips' parting.
    static func parting(_ d: MouthDrive) -> Double { max(opening(d), spreadOpening * spread(d)) }

    /// A laughing speaker's syllables open to at least `laughOpen`; between them the lips meet.
    /// The floor fades over the lips' whole closing, so a pause never snaps the mouth shut.
    private static func laughFloor(_ c: DuoCharacter, parting x: Double) -> Double {
        laughOpen(c) * RigMath.smoothstep(0, 0.45, x)
    }

    /// How far the width moves from the closed mouth's to the spoken one: with the opening, and
    /// at once for spread lips.
    private static func widthBlend(_ d: MouthDrive, parting x: Double) -> Double {
        max(RigMath.smoothstep(0, 0.35, x), spread(d))
    }

    /// The angel's speaking mouth: the closed smile at rest and at closures, a flat pill as the
    /// lips part, the wide D of an A or E, and the narrow oval of an O or U when the lips round.
    /// Width and depth keep their proportions, so the shape changes without the mouth jumping in size.
    private static func angel(_ e: MouthParams, drive d: MouthDrive, talk tau: Double, laughing: Bool) -> MouthParams {
        let x = parting(d)
        // Rounded lips narrow the mouth: a little for a U, more once it opens into an O.
        let rounded = RigMath.smoothstep(0.3, 0.75, d.rounding) * RigMath.smoothstep(0.1, 0.3, x)
        let narrow = 1 - rounded * (0.25 + 0.3 * RigMath.smoothstep(0.4, 0.75, x))
        let spoken = (48 + 16 * d.width) * narrow
        var m = e
        m.open = RigMath.mix(e.open, maxOpen(.angel) * x, tau)
        if laughing { m.open = max(m.open, laughFloor(.angel, parting: x)) }
        m.width = RigMath.mix(e.width, RigMath.mix(AngelGeometry.mouthClosedWidth, spoken, widthBlend(d, parting: x)), tau)
        m.round = RigMath.mix(e.round, rounded * RigMath.smoothstep(0.45, 0.7, x), tau)
        m.corner = e.corner * (1 - 0.3 * x * tau)
        m.tongue = RigMath.mix(e.tongue, 1, tau)
        return m
    }

    /// The devil's speaking mouth: the closed smile with the fang hanging under it at rest and at
    /// closures, a D with the fang as the lips part, the wide shallow D of an E, the slim rounded
    /// slot of a U and the small round O, both showing coral. The expression's skew, fang and
    /// shift carry through; width and depth keep their proportions, so the shape changes without
    /// the mouth jumping in size.
    private static func devil(_ e: MouthParams, drive d: MouthDrive, talk tau: Double, laughing: Bool) -> MouthParams {
        let x = parting(d)
        let rounded = RigMath.smoothstep(0.3, 0.75, d.rounding) * RigMath.smoothstep(0.1, 0.3, x)
        // Rounded lips make a slim slot (a U) that opens into a circle (an O).
        let circle = RigMath.smoothstep(0.55, 0.8, x)
        // Spread lips make a wide, shallow D (an E).
        let shallow = RigMath.smoothstep(0.6, 1, d.width) * (1 - rounded)
        let spoken = (58 + 22 * d.width) * (1 - rounded * (0.3 + 0.3 * circle))
        let depth = maxOpen(.devil) * x * (1 - 0.35 * shallow) * (1 - rounded * (0.45 - 0.2 * circle))
        var m = e
        m.open = RigMath.mix(e.open, depth, tau)
        if laughing { m.open = max(m.open, laughFloor(.devil, parting: x)) }
        m.width = RigMath.mix(e.width, RigMath.mix(DevilGeometry.mouthClosedWidth, spoken, widthBlend(d, parting: x)), tau)
        m.round = RigMath.mix(e.round, rounded * RigMath.smoothstep(0.3, 0.6, x), tau)
        m.corner = e.corner * (1 - 0.3 * x * tau)
        m.tongue = RigMath.mix(e.tongue, 1, tau)
        return m
    }
}

// MARK: - Paths

/// A path in face units: built by the shape builders, drawn by the renderer through the head
/// transform, and measured by the checks.
struct CurvePath: Equatable, Sendable {
    enum Element: Equatable, Sendable {
        case move(Vec2)
        case line(Vec2)
        case quad(Vec2, Vec2)
        case cubic(Vec2, Vec2, Vec2)
        case close
    }

    var elements: [Element] = []

    mutating func move(to p: Vec2) { elements.append(.move(p)) }
    mutating func line(to p: Vec2) { elements.append(.line(p)) }
    mutating func quad(to p: Vec2, control c: Vec2) { elements.append(.quad(c, p)) }
    mutating func cubic(to p: Vec2, _ c1: Vec2, _ c2: Vec2) { elements.append(.cubic(c1, c2, p)) }
    mutating func close() { elements.append(.close) }

    mutating func append(_ other: CurvePath) { elements += other.elements }

    /// Every point mapped through `transform`.
    func map(_ transform: (Vec2) -> Vec2) -> CurvePath {
        CurvePath(elements: elements.map {
            switch $0 {
            case .move(let p): .move(transform(p))
            case .line(let p): .line(transform(p))
            case .quad(let c, let p): .quad(transform(c), transform(p))
            case .cubic(let a, let b, let p): .cubic(transform(a), transform(b), transform(p))
            case .close: .close
            }
        })
    }

    /// Every end and control point.
    var points: [Vec2] {
        elements.flatMap { element -> [Vec2] in
            switch element {
            case .move(let p), .line(let p): [p]
            case .quad(let c, let p): [c, p]
            case .cubic(let a, let b, let p): [a, b, p]
            case .close: []
            }
        }
    }

    /// The control-point bounds (a superset of the curve's).
    var bounds: (min: Vec2, max: Vec2) {
        let pts = points
        guard let first = pts.first else { return (.zero, .zero) }
        var lo = first, hi = first
        for p in pts {
            lo = Vec2(Swift.min(lo.x, p.x), Swift.min(lo.y, p.y))
            hi = Vec2(Swift.max(hi.x, p.x), Swift.max(hi.y, p.y))
        }
        return (lo, hi)
    }

    /// An ellipse of radii (rx, ry) as four cubics, clockwise from the right.
    static func ellipse(center c: Vec2, rx: Double, ry: Double) -> CurvePath {
        let k = 0.552_284_749_8
        var path = CurvePath()
        path.move(to: c + Vec2(rx, 0))
        path.cubic(to: c + Vec2(0, ry), c + Vec2(rx, k * ry), c + Vec2(k * rx, ry))
        path.cubic(to: c + Vec2(-rx, 0), c + Vec2(-k * rx, ry), c + Vec2(-rx, k * ry))
        path.cubic(to: c + Vec2(0, -ry), c + Vec2(-rx, -k * ry), c + Vec2(-k * rx, -ry))
        path.cubic(to: c + Vec2(rx, 0), c + Vec2(k * rx, -ry), c + Vec2(rx, -k * ry))
        path.close()
        return path
    }

    /// A smooth open curve through `points` (Catmull-Rom as cubics).
    static func smooth(through points: [Vec2]) -> CurvePath {
        var path = CurvePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        CatmullRom.forEachSegment(points) { _, c1, c2, end in path.cubic(to: end, c1, c2) }
        return path
    }

    /// Straight segments through `points`.
    static func polyline(_ points: [Vec2], closed: Bool = false) -> CurvePath {
        var path = CurvePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.line(to: p) }
        if closed { path.close() }
        return path
    }
}

/// Bézier evaluation helpers.
enum Bezier {
    static func quad(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ t: Double) -> Vec2 {
        let u = 1 - t
        return p0 * (u * u) + p1 * (2 * u * t) + p2 * (t * t)
    }

    static func cubic(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2, _ t: Double) -> Vec2 {
        let u = 1 - t
        return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
    }
}

// MARK: - Shape builders

/// Eye sizes, closed glyphs and the devil's upper-lid line.
enum EyeShape {
    /// The base radii (rx, ry) at size 1.
    static func radii(_ c: DuoCharacter) -> Vec2 {
        (c == .angel ? AngelGeometry.eyeSize : DevilGeometry.eyeSize) / 2
    }

    /// The closed glyph's stroke width (fu).
    static func glyphStroke(_ c: DuoCharacter) -> Double { c == .angel ? 6.5 : 7 }

    /// The closed glyph around the eye centre: a quadratic through the ∩ and ∪ control points
    /// blended by weight, sampled at 9 points. When the chevron outweighs the arcs, the
    /// quadratic runs through the chevron's controls instead (vertex toward the nose), and each
    /// sample is pulled toward the chevron's polyline by its weight: a part-chevron is a rounded
    /// one, a full chevron is sharp.
    static func glyphPoints(rx: Double, ry: Double, sigma: Double, arcUp: Double, arcDown: Double,
                            chevron: Double) -> [Vec2] {
        let total = max(arcUp + arcDown + chevron, 1e-9)
        let wu = arcUp / total, wd = arcDown / total
        let up = [Vec2(-0.9 * rx, 0.15 * ry), Vec2(0, -0.75 * ry), Vec2(0.9 * rx, 0.15 * ry)]
        let down = [Vec2(-0.9 * rx, -0.1 * ry), Vec2(0, 0.7 * ry), Vec2(0.9 * rx, -0.1 * ry)]
        let chev = [Vec2(sigma * 0.7 * rx, -0.5 * ry), Vec2(-sigma * 0.6 * rx, 0), Vec2(sigma * 0.7 * rx, 0.5 * ry)]
        let chevronLed = chevron / total >= 0.5
        let wc = chevronLed ? RigMath.mix(0.3, 1, (chevron / total - 0.5) * 2) : 0
        let arcs = max(wu + wd, 1e-9)
        let p = chevronLed ? chev : (0..<3).map { up[$0] * (wu / arcs) + down[$0] * (wd / arcs) }
        return (0..<9).map { i in
            let t = Double(i) / 8
            let curve = Bezier.quad(p[0], p[1], p[2], t)
            let poly = t < 0.5 ? Vec2.lerp(p[0], p[1], 2 * t) : Vec2.lerp(p[1], p[2], 2 * t - 1)
            return Vec2.lerp(curve, poly, wc)
        }
    }

    static func glyph(rx: Double, ry: Double, sigma: Double, arcUp: Double, arcDown: Double,
                      chevron: Double) -> CurvePath {
        let points = glyphPoints(rx: rx, ry: ry, sigma: sigma, arcUp: arcUp, arcDown: arcDown, chevron: chevron)
        guard chevron > 0.5 else { return .smooth(through: points) }
        return .polyline(points)
    }

    /// The devil's heavy upper-lid line around an eye of radii (rx, ry) at the origin, whose top
    /// lid comes down `lidTop` (0…0.95 of its height) along a chord turned by `rotation`: a band
    /// along the visible eye's top, `weight` thick on the lid's chord (or, with no lid, at the
    /// top) and tapering down both sides to `outline`, the sclera outline's weight, so it melts
    /// into that outline.
    static func upperLid(rx: Double, ry: Double, lidTop: Double, rotation: Double, weight: Double,
                         outline: Double) -> CurvePath {
        let lidY = -ry + 2 * ry * RigMath.clamp(lidTop, 0, 0.95)
        let count = 40, spread = 0.5
        var points: [Vec2] = [], cut: [Bool] = []
        for k in 0...count {
            let t = Double.pi - spread + (Double.pi + 2 * spread) * Double(k) / Double(count)
            // In the lid's frame, anything above the lid line lies on it.
            var q = Vec2(rx * cos(t), ry * sin(t)).rotated(by: -rotation)
            cut.append(q.y < lidY)
            q.y = max(q.y, lidY)
            points.append(q.rotated(by: rotation))
        }
        let top = points.indices.min { points[$0].y < points[$1].y } ?? count / 2
        let first = cut.firstIndex(of: true) ?? top, last = cut.lastIndex(of: true) ?? top
        var above: [Vec2] = [], below: [Vec2] = []
        for k in 0...count {
            let heavy = k < first ? RigMath.smoothstep(0, Double(first), Double(k))
                : k > last ? RigMath.smoothstep(Double(count), Double(last), Double(k)) : 1
            let half = RigMath.mix(outline, weight, heavy) / 2
            let d = points[min(k + 1, count)] - points[max(k - 1, 0)]
            let n = Vec2(d.y, -d.x) / max(d.length, 1e-9)
            above.append(points[k] + n * half)
            below.append(points[k] - n * half)
        }
        return .polyline(above + below.reversed(), closed: true)
    }
}

/// A four-point star (sparkles, starry eyes, sparkle marks).
enum StarShape {
    static func star(center c: Vec2, radius r: Double, waist: Double = 0.28, rotation: Double = 0) -> CurvePath {
        var path = CurvePath()
        let tips = (0..<4).map { c + Vec2(0, -r).rotated(by: rotation + Double($0) * Double.pi / 2) }
        let waists = (0..<4).map {
            c + Vec2(0, -r * waist).rotated(by: rotation + Double.pi / 4 + Double($0) * Double.pi / 2)
        }
        path.move(to: tips[0])
        for i in 0..<4 {
            path.quad(to: tips[(i + 1) % 4], control: Vec2.lerp(c, waists[i], 0.9))
        }
        path.close()
        return path
    }
}

/// Brows: the angel's arc stroke and the devil's filled taper, on side σ.
enum BrowShape {
    /// The chord's ends after the brow's angle (about the chord's midpoint) and offset.
    static func chord(_ c: DuoCharacter, sigma: Double, params b: BrowParams) -> (outer: Vec2, inner: Vec2) {
        let outer = (c == .angel ? AngelGeometry.browOuter : DevilGeometry.browOuter).sided(sigma)
        let inner = (c == .angel ? AngelGeometry.browInner : DevilGeometry.browInner).sided(sigma)
        let mid = Vec2.lerp(outer, inner, 0.5)
        // A positive angle lowers the inner end: clockwise on screen for the left brow.
        let theta = -sigma * b.angle * Double.pi / 180
        let o = mid + (outer - mid).rotated(by: theta) + Vec2(0, b.dy)
        let i = mid + (inner - mid).rotated(by: theta) + Vec2(0, b.dy)
        return (o, i)
    }

    /// The upward normal of the chord from `a` to `b`.
    private static func up(_ a: Vec2, _ b: Vec2) -> Vec2 {
        let d = b - a
        let n = Vec2(d.y, -d.x) / max(d.length, 1e-9)
        return n.y <= 0 ? n : -n
    }

    /// The angel's brow: a quadratic arc along the chord, convex up (to be stroked 6 fu).
    static func angel(sigma: Double, params b: BrowParams) -> CurvePath {
        let (o, i) = chord(.angel, sigma: sigma, params: b)
        let sag = AngelGeometry.browSagitta * b.arch
        var path = CurvePath()
        path.move(to: o)
        path.quad(to: i, control: Vec2.lerp(o, i, 0.5) + up(o, i) * (2 * sag))
        return path
    }

    /// The devil's brow: a thick filled taper from a round 9.5-fu outer end to a round 4.5-fu
    /// inner end, arched convex up.
    static func devil(sigma: Double, params b: BrowParams) -> CurvePath {
        let (o, i) = chord(.devil, sigma: sigma, params: b)
        let n = up(o, i)
        let control = Vec2.lerp(o, i, 0.5) + n * (2 * DevilGeometry.browArch * b.arch)
        let count = 16
        var top: [Vec2] = [], bottom: [Vec2] = []
        for k in 0...count {
            let t = Double(k) / Double(count)
            let p = Bezier.quad(o, control, i, t)
            let tangent = (o - control) * (2 * (1 - t)) * -1 + (i - control) * (2 * t)
            var normal = Vec2(tangent.y, -tangent.x) / max(tangent.length, 1e-9)
            if normal.y > 0 { normal = -normal }
            let half = RigMath.mix(DevilGeometry.browOuterThickness, DevilGeometry.browInnerThickness,
                                   pow(t, 1.3)) / 2
            top.append(p + normal * half)
            bottom.append(p - normal * half)
        }
        let away = (o - i) / max((o - i).length, 1e-9)
        var path = CurvePath()
        path.move(to: top[0])
        for p in top.dropFirst() { path.line(to: p) }
        // The round caps, inner then outer.
        let ri = DevilGeometry.browInnerThickness / 2, ro = DevilGeometry.browOuterThickness / 2
        path.cubic(to: bottom[count], top[count] - away * (ri * 1.33), bottom[count] - away * (ri * 1.33))
        for p in bottom.reversed().dropFirst() { path.line(to: p) }
        path.cubic(to: top[0], bottom[0] + away * (ro * 1.33), top[0] + away * (ro * 1.33))
        path.close()
        return path
    }
}

/// The ink mouth both characters draw: one closed outline, so nothing cross-fades. It is a top
/// edge and a bottom edge of two quarter arcs, blended between three forms:
/// - **thin**: the bottom edge follows the top, an even-weight curve: a closed smile, a smirk
///   (with `skew`), the flat pill of an M or B, or (with a negative `corner`) a frown;
/// - **bowl**: a round bottom under the top edge: the open D of an A, E or a laugh;
/// - **oval** (`round` 1): the oval of an O.
/// The top edge passes through the anchor at its centre: `corner` lifts both corners above it
/// and `skew` raises the right one and lowers the left.
enum InkMouth {
    /// The left corner, top controls, right corner, controls to the bottom's centre, the bottom's
    /// centre, and controls back to the left corner, for a shape `d` deep showing `bowl` of the
    /// bowl form.
    static func points(_ m: MouthParams, depth d: Double, bowl g: Double) -> [Vec2] {
        let w = m.width, lift = m.corner, s = m.skew
        let k = 0.5523  // a quarter ellipse's control length
        let left = Vec2(-w / 2, -lift + s), right = Vec2(w / 2, -lift - s)
        // The top edge passes through the anchor.
        let top = [left, Vec2(-w / 6, lift / 3 + s / 3), Vec2(w / 6, lift / 3 - s / 3), right]
        // Thin: the top edge lowered by `d` at its centre, split at the bottom's centre.
        let q1 = Vec2(w / 6, lift / 3 - s / 3 + 4 * d / 3), q2 = Vec2(-w / 6, lift / 3 + s / 3 + 4 * d / 3)
        let thin = top + [(right + q1) / 2, (right + q1 * 2 + q2) / 4, Vec2(0, d),
                          (q1 + q2 * 2 + left) / 4, (q2 + left) / 2]
        // Bowl: quarter arcs from the corners down to the bottom's centre.
        let rounded = top + [Vec2(w / 2, right.y + k * (d - right.y)), Vec2(k * w / 2, d), Vec2(0, d),
                             Vec2(-k * w / 2, d), Vec2(-w / 2, left.y + k * (d - left.y))]
        // Oval: from the lifted corners' height down to `d`.
        let up = max(lift, 0), cy = (d - up) / 2, ry = (d + up) / 2
        let oval = [Vec2(-w / 2, cy), Vec2(-w / 2, cy - 4 * ry / 3), Vec2(w / 2, cy - 4 * ry / 3), Vec2(w / 2, cy),
                    Vec2(w / 2, cy + k * ry), Vec2(k * w / 2, cy + ry), Vec2(0, cy + ry),
                    Vec2(-k * w / 2, cy + ry), Vec2(-w / 2, cy + k * ry)]
        return (0..<9).map { Vec2.lerp(Vec2.lerp(thin[$0], rounded[$0], g), oval[$0], m.round) + Vec2(m.shiftX, 0) }
    }

    static func outline(_ p: [Vec2]) -> CurvePath {
        var path = CurvePath()
        path.move(to: p[0])
        path.cubic(to: p[3], p[1], p[2])
        path.cubic(to: p[6], p[4], p[5])
        path.cubic(to: p[0], p[7], p[8])
        path.close()
        return path
    }

    /// The top edge's y at x (clamped to the corners).
    static func topY(_ p: [Vec2], at x: Double) -> Double { y(p[0], p[1], p[2], p[3], at: x) }

    /// The bottom edge's y at x (clamped to the corners).
    static func bottomY(_ p: [Vec2], at x: Double) -> Double {
        x >= p[6].x ? y(p[3], p[4], p[5], p[6], at: x) : y(p[6], p[7], p[8], p[0], at: x)
    }

    /// The y of a cubic whose x runs one way, at x.
    private static func y(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2, at x: Double) -> Double {
        var lo = 0.0, hi = 1.0
        let increasing = p3.x >= p0.x
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if (Bezier.cubic(p0, p1, p2, p3, mid).x < x) == increasing { lo = mid } else { hi = mid }
        }
        return Bezier.cubic(p0, p1, p2, p3, (lo + hi) / 2).y
    }
}

/// The angel's mouth: an `InkMouth` with a coral tongue resting on its bottom.
enum AngelMouthShape {
    /// How far the shape reaches below the anchor: never less than the closed line's thickness.
    static func depth(_ m: MouthParams) -> Double { max(m.open, m.line) }

    /// How much of the bowl shows: none while the mouth is a thin curve or frowns.
    static func bowl(_ m: MouthParams) -> Double {
        RigMath.smoothstep(4, 12, depth(m)) * RigMath.smoothstep(-2, 2, m.corner)
    }

    /// The outline's points (`InkMouth.points`).
    static func points(_ m: MouthParams) -> [Vec2] { InkMouth.points(m, depth: depth(m), bowl: bowl(m)) }

    static func outline(_ m: MouthParams) -> CurvePath { InkMouth.outline(points(m)) }

    /// How much of the tongue shows: none in a closed or barely parted mouth, growing in with the
    /// opening rather than fading.
    static func tongueScale(_ m: MouthParams) -> Double {
        m.tongue * RigMath.smoothstep(AngelGeometry.tongueGrowth.from, AngelGeometry.tongueGrowth.to, depth(m))
    }

    /// The tongue: a dome centred on the bottom, drawn clipped to the mouth so only its upper half
    /// shows. About half a wide mouth's width; in a small mouth, as for a U, it fills most of it.
    /// Nil when none shows.
    static func tongue(_ m: MouthParams) -> CurvePath? {
        let s = tongueScale(m)
        guard s > 0.01 else { return nil }
        let d = depth(m), small = 1 - RigMath.smoothstep(16, 30, d)
        return .ellipse(center: Vec2(m.shiftX, d), rx: m.width * (0.27 + 0.1 * small + 0.07 * m.round) * s,
                        ry: min(AngelGeometry.tongueMaxHeight, (0.42 + 0.23 * small) * d) * s)
    }
}

/// The devil's mouth: an `InkMouth` with a coral tongue resting on its bottom and one white
/// fang near the right corner. The fang hangs from the top edge of an open mouth and from under
/// the line of a closed one or a smirk, so it never crosses the ink; it keeps its size in every
/// mouth and only draws up into the lip as the lips round into a U or O.
enum DevilMouthShape {
    /// How far the shape reaches below the anchor: never less than the closed line's thickness.
    static func depth(_ m: MouthParams) -> Double { max(m.open, m.line) }

    /// How much of the bowl shows: none while the mouth is a line, a smirk or a frown.
    static func bowl(_ m: MouthParams) -> Double {
        RigMath.smoothstep(DevilGeometry.bowlGrowth.from, DevilGeometry.bowlGrowth.to, depth(m))
            * RigMath.smoothstep(-2, 2, m.corner)
    }

    /// The outline's points (`InkMouth.points`).
    static func points(_ m: MouthParams) -> [Vec2] { InkMouth.points(m, depth: depth(m), bowl: bowl(m)) }

    static func outline(_ m: MouthParams) -> CurvePath { InkMouth.outline(points(m)) }

    /// How much of the tongue shows: none in a closed or barely parted mouth, growing in with the
    /// opening. Rounded lips count as deeper, so the slim U and the small O show their coral.
    static func tongueScale(_ m: MouthParams) -> Double {
        m.tongue * RigMath.smoothstep(DevilGeometry.tongueGrowth.from, DevilGeometry.tongueGrowth.to,
                                      depth(m) + 8 * m.round)
    }

    /// The tongue: a dome centred on the bottom, drawn clipped to the mouth so only its upper half
    /// shows. Nil when none shows.
    static func tongue(_ m: MouthParams) -> CurvePath? {
        let s = tongueScale(m)
        guard s > 0.01 else { return nil }
        let d = depth(m), small = 1 - RigMath.smoothstep(16, 30, d)
        return .ellipse(center: Vec2(m.shiftX, d), rx: m.width * (0.26 + 0.1 * small + 0.08 * m.round) * s,
                        ry: min(DevilGeometry.tongueMaxHeight, (0.4 + 0.25 * small) * d) * s)
    }

    /// Everything below the top edge (carried on level past the corners): the fang's bold
    /// outline is clipped to it, so in an open mouth it never pokes above the lip.
    static func belowTopEdge(_ m: MouthParams) -> CurvePath {
        let p = points(m)
        var path = CurvePath()
        path.move(to: p[0] - Vec2(40, 0))
        path.line(to: p[0])
        path.cubic(to: p[3], p[1], p[2])
        path.line(to: p[3] + Vec2(40, 0))
        path.line(to: p[3] + Vec2(40, 120))
        path.line(to: p[0] + Vec2(-40, 120))
        path.close()
        return path
    }

    /// The fang's size: `fang`, drawn up into the lip as the lips round.
    static func fangScale(_ m: MouthParams) -> Double {
        RigMath.clamp(m.fang, 0, 1) * (1 - RigMath.smoothstep(0.25, 0.75, m.round))
    }

    /// The fang at `fangX` of the half width: a white triangle leaning a little toward the corner,
    /// `DevilGeometry.fangBaseFactor` of the grin wide. In an open mouth it hangs from just under
    /// the top edge, up to `fangHeight` long; under a closed line it hangs `fangBelowLine` below
    /// the line's bottom edge. Nil when it has no size.
    static func fang(_ m: MouthParams) -> CurvePath? {
        guard let f = fangPoints(m) else { return nil }
        var path = CurvePath()
        path.move(to: f.left)
        path.line(to: f.right)
        path.quad(to: f.tip, control: f.rightControl)
        path.quad(to: f.left, control: f.leftControl)
        path.close()
        return path
    }

    /// The path the fang's bold outline is stroked along: the fang with its sides carried
    /// `fangOutline` + 1.4 fu on up past its root, so the outline's top corners sit up in the
    /// mouth's ink (or above the lip, where `belowTopEdge` clips them) and its sides run smoothly
    /// into the line. Nil when the fang has no size.
    static func fangOutline(_ m: MouthParams) -> CurvePath? {
        guard let f = fangPoints(m) else { return nil }
        func unit(_ v: Vec2) -> Vec2 { v / max(v.length, 1e-12) }
        let reach = DevilGeometry.fangOutline + 1.4
        var path = CurvePath()
        path.move(to: f.left + unit(f.left - f.leftControl) * reach)
        path.line(to: f.right + unit(f.right - f.rightControl) * reach)
        path.line(to: f.right)
        path.quad(to: f.tip, control: f.rightControl)
        path.quad(to: f.left, control: f.leftControl)
        path.close()
        return path
    }

    /// The fang's root corners, tip and the controls of its curved sides (see `fang`).
    private static func fangPoints(_ m: MouthParams)
        -> (left: Vec2, right: Vec2, tip: Vec2, rightControl: Vec2, leftControl: Vec2)? {
        let s = fangScale(m)
        guard s > 0.02 else { return nil }
        let p = points(m)
        let x = m.fangX * m.width / 2 + m.shiftX
        let half = DevilGeometry.fangBaseFactor * DevilGeometry.mouthWidth / 2 * s
        func band(_ x: Double) -> Double { max(0, InkMouth.bottomY(p, at: x) - InkMouth.topY(p, at: x)) }
        // 0 while the ink at the fang is a line, 1 once it is an opening.
        let open = RigMath.smoothstep(m.line, m.line + 8, band(x))
        func root(_ x: Double) -> Double {
            InkMouth.topY(p, at: x) + RigMath.mix(band(x) + 0.4 * DevilGeometry.mouthEdge, DevilGeometry.fangInset, open)
        }
        let height = RigMath.mix(DevilGeometry.fangBelowLine, min(DevilGeometry.fangHeight, 0.6 * band(x)), open) * s
        let left = Vec2(x - half, root(x - half)), right = Vec2(x + half, root(x + half))
        let top = (left.y + right.y) / 2
        return (left, right, Vec2(x + 0.15 * half, top + height), Vec2(x + 0.6 * half, top + 0.6 * height),
                Vec2(x - 0.5 * half, top + 0.5 * height))
    }
}

/// The devil's left horn (screen left; the right mirrors): one smooth closed outline with no
/// sharp corner. From the outer base the convex back sweeps out to its widest point
/// (`DevilGeometry.hornBulge`), where it runs straight up, and over to the tip, nearly level
/// there; at the tip it turns over in a small round cap into the concave inner edge, which
/// curves down to the inner base; the straight base runs back to the start. The base's corners
/// are rounded (`hornCornerRadius`) and every join is smooth.
enum HornShape {
    private static func unit(_ v: Vec2) -> Vec2 { v / max(v.length, 1e-12) }

    /// The way the back leaves the outer base: up and out.
    static let backDirection = unit(Vec2(-0.54, -0.84))
    /// Where the tip's round cap gives way to the inner edge, and the way it runs there: down.
    static let capEnd = DevilGeometry.hornTip + Vec2(2.8, 5.5)
    static let capDirection = unit(Vec2(-0.1, 1))
    /// The way the inner edge reaches the inner base: down and in.
    static let innerDirection = unit(Vec2(0.63, 0.78))

    /// The back as two cubics (start, controls, end), from just past the outer base's rounded
    /// corner out to the widest point and over to the tip.
    static func back() -> [(Vec2, Vec2, Vec2, Vec2)] {
        let start = DevilGeometry.hornOuterBase + backDirection * DevilGeometry.hornCornerRadius
        let bulge = DevilGeometry.hornBulge, tip = DevilGeometry.hornTip
        return [(start, start + backDirection * 12, bulge + Vec2(0, 13), bulge),
                (bulge, bulge + Vec2(0, -18), tip + Vec2(-15, 3), tip)]
    }

    static func outline() -> CurvePath {
        let tip = DevilGeometry.hornTip, outer = DevilGeometry.hornOuterBase, inner = DevilGeometry.hornInnerBase
        let r = DevilGeometry.hornCornerRadius
        // Along the base, from the inner corner to the outer.
        let along = unit(outer - inner)
        let edge = back()
        var path = CurvePath()
        path.move(to: edge[0].0)
        for (_, c1, c2, end) in edge { path.cubic(to: end, c1, c2) }
        path.cubic(to: capEnd, tip + Vec2(2, -0.4), capEnd - capDirection * 2.5)
        let innerEnd = inner - innerDirection * r
        path.cubic(to: innerEnd, capEnd + capDirection * 20, innerEnd - innerDirection * 15)
        path.quad(to: inner + along * r, control: inner)
        path.line(to: outer - along * r)
        path.quad(to: edge[0].0, control: outer)
        path.close()
        return path
    }

    /// Points along the back from the outer base to the tip with their arc length, finely
    /// sampled.
    private static let backSamples: [(point: Vec2, length: Double)] = {
        var samples: [(Vec2, Double)] = []
        var length = 0.0
        for (p0, c1, c2, p3) in back() {
            for k in 0...64 where !(k == 0 && !samples.isEmpty) {
                let p = Bezier.cubic(p0, c1, c2, p3, Double(k) / 64)
                if let last = samples.last { length += (p - last.0).length }
                samples.append((p, length))
            }
        }
        return samples
    }()

    /// The point `u` (0…1) of the way along the back by length, and the unit normal into the
    /// horn there.
    static func backPoint(at u: Double) -> (point: Vec2, inward: Vec2) {
        let samples = backSamples
        let target = RigMath.clamp(u, 0, 1) * (samples.last?.length ?? 0)
        let i = min(max(samples.firstIndex { $0.length >= target } ?? samples.count - 1, 1), samples.count - 1)
        let (a, b) = (samples[i - 1], samples[i])
        let t = (target - a.length) / max(b.length - a.length, 1e-12)
        let d = b.point - a.point
        // Inward is to the right of the way from the base to the tip.
        return (Vec2.lerp(a.point, b.point, RigMath.clamp(t, 0, 1)), unit(Vec2(-d.y, d.x)))
    }

    /// How strong the shine is `v` (0…1) of the way along its span: nothing at the ends, most a
    /// little past the middle.
    static func shineStrength(_ v: Double) -> Double { pow(sin(Double.pi * pow(RigMath.clamp(v, 0, 1), 0.85)), 0.8) }

    /// The glossy shine (`DevilGeometry.hornShineSpan`, `hornShineBand`, `hornShineFalloff`) as
    /// `layers` nested bands, from the faintest and widest to the strongest and narrowest: band
    /// k covers where the shine reaches k / `layers` of its peak. Filled one over another at a low
    /// opacity they build a soft highlight with no hard edge: an even band inside a dark rim
    /// along the edge, eased out toward the edge and, more slowly, toward the inside, and fading
    /// toward both ends of the span.
    static func shine(layers: Int) -> [CurvePath] {
        let span = DevilGeometry.hornShineSpan, band = DevilGeometry.hornShineBand
        let falloff = DevilGeometry.hornShineFalloff
        let middle = (band.lowerBound + band.upperBound) / 2, halfBand = (band.upperBound - band.lowerBound) / 2
        let count = 40
        let along = (0...count).map { k -> (v: Double, point: Vec2, inward: Vec2) in
            let v = Double(k) / Double(count)
            let (p, n) = backPoint(at: RigMath.mix(span.lowerBound, span.upperBound, v))
            return (v, p, n)
        }
        return (0..<layers).map { k in
            let level = Double(k) / Double(layers)
            var outerSide: [Vec2] = [], innerSide: [Vec2] = []
            // The band runs where the shine is above this level, pointed at both ends.
            let present = along.map { shineStrength($0.v) > level }
            for (i, (v, p, n)) in along.enumerated()
            where present[i] || (i > 0 && present[i - 1]) || (i < along.count - 1 && present[i + 1]) {
                let strength = shineStrength(v)
                // The band narrows toward the span's ends. Across, the strength eases from the
                // band's edge to nothing as (1 + cos πt) / 2 over the falloff, so this level
                // reaches t of the way out.
                let taper = pow(sin(Double.pi * v), 0.6)
                var outer = middle, inner = middle
                if present[i] {
                    let t = acos(RigMath.clamp(2 * level / strength - 1, -1, 1)) / Double.pi
                    outer = middle - (halfBand + falloff.outer * t) * taper
                    inner = middle + (halfBand + falloff.inner * t) * taper
                }
                outerSide.append(p + n * outer)
                innerSide.append(p + n * inner)
            }
            return .polyline(outerSide + innerSide.reversed(), closed: true)
        }
    }

    /// The horn's fill runs from warm maroon at the inner base corner (its centre, just below
    /// it) to dark brown at `shadeRadius`, beyond the tip, as if lit from below.
    static let shadeCenter = DevilGeometry.hornInnerBase + Vec2(-4, 8)
    static let shadeRadius = 58.0
}

/// A character's blush, mirrored on both sides: its centre on side σ, its radii in face units
/// and its strength, after the squeeze q (the volume a squash leaves over) and, for the devil,
/// his cheeks' puff, which widens and deepens it.
enum BlushShape {
    /// The blush's strength (0…1 of its colour's alpha).
    static func strength(_ pose: FacePose) -> Double {
        let amount = pose.features.accessories.blush
        guard pose.character == .devil else { return amount }
        return min(1, amount * (1 + DevilGeometry.blushPuffStrength * max(0, pose.puff)))
    }

    static func center(_ pose: FacePose, sigma: Double) -> Vec2 {
        let geometry = pose.character == .angel ? AngelGeometry.blush : DevilGeometry.blush
        return geometry.center.sided(sigma) + Vec2(3 * pose.turn.x, 2 * pose.turn.y + 4 * pose.squeeze)
    }

    static func radii(_ pose: FacePose) -> Vec2 {
        let geometry = pose.character == .angel ? AngelGeometry.blush : DevilGeometry.blush
        let size = geometry.size * (pose.features.accessories.blushSize * (1 + 0.25 * pose.squeeze))
        guard pose.character == .devil else { return size / 2 }
        let puff = DevilGeometry.blushPuff * max(0, pose.puff)
        return Vec2(size.x * (1 + puff.x), size.y * (1 + puff.y)) / 2
    }
}

/// The angel's left wing (screen left; the right mirrors): a long convex leading edge from the
/// rounded tip down past the hinge, and three lobes stacked along the trailing edge, largest at
/// the tip, with a sharp notch between neighbours.
enum WingShape {
    /// The outline as cubics (start, controls, end), clockwise from the tip: down the leading
    /// edge, round the bottom lobe, then up the middle lobe and the top lobe.
    static let segments: [(Vec2, Vec2, Vec2, Vec2)] = {
        let tip = Vec2(-167.5, -18), shoulder = Vec2(-137, 6), inner = Vec2(-122, 48), bottom = Vec2(-145, 72)
        let lowLobe = Vec2(-164.5, 59.5), lowNotch = Vec2(-158, 50)
        let midLobe = Vec2(-178, 28.5), highNotch = Vec2(-165.5, 19), topLobe = Vec2(-177.5, -5.5)
        return [(tip, Vec2(-156.5, -18), Vec2(-143, -3), shoulder),
                (shoulder, Vec2(-129, 18), Vec2(-122, 33.5), inner),
                (inner, Vec2(-122, 62), Vec2(-131, 72), bottom),
                (bottom, Vec2(-152.5, 72), Vec2(-164.5, 68.5), lowLobe),
                (lowLobe, Vec2(-164.5, 53.5), Vec2(-160.5, 53), lowNotch),
                (lowNotch, Vec2(-167, 47), Vec2(-178, 39), midLobe),
                (midLobe, Vec2(-178, 18.5), Vec2(-168.5, 20.5), highNotch),
                (highNotch, Vec2(-171.5, 12.5), Vec2(-177.5, 3.5), topLobe),
                (topLobe, Vec2(-177.5, -12), Vec2(-174.5, -18), tip)]
    }()

    static func outline() -> CurvePath {
        var path = CurvePath()
        path.move(to: segments[0].0)
        for (_, c1, c2, end) in segments { path.cubic(to: end, c1, c2) }
        path.close()
        return path
    }

    /// Points around the outline, `perSegment` along each cubic.
    static func rim(perSegment: Int = 4) -> [Vec2] {
        segments.flatMap { s in
            (0..<perSegment).map { Bezier.cubic(s.0, s.1, s.2, s.3, Double($0) / Double(perSegment)) }
        }
    }
}

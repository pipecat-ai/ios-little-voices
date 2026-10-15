import Foundation

/// A rectangle in stage points (origin at the window's top-left, y down).
struct StageRect: Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    var isFinite: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite }

    func intersects(_ other: StageRect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    /// The gap between the two rectangles; 0 when they touch or overlap.
    func distance(to other: StageRect) -> Double {
        let dx = max(0, max(other.minX - maxX, minX - other.maxX))
        let dy = max(0, max(other.minY - maxY, minY - other.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// The stage's geometry: the window, the band between the header and the footer, the face scale
/// and the seam's centred window.
struct StageMetrics: Equatable, Sendable {
    var width: Double
    var height: Double
    var bandTop: Double
    var bandBottom: Double

    init(width: Double, height: Double, bandTop: Double, bandBottom: Double) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.bandTop = bandTop.isFinite ? bandTop : 0
        self.bandBottom = max(bandBottom.isFinite ? bandBottom : self.height - 120, self.bandTop + 1)
    }

    /// The band from the stage's size and the header's and footer's edges (global coordinates):
    /// 8 pt inside each. Before the footer is measured the band ends 120 pt above the bottom.
    init(size: Vec2, globalMinY: Double, headerBottom: Double, footerTop: Double) {
        let top = headerBottom - globalMinY + 8
        let bottom = footerTop.isFinite ? footerTop - globalMinY - 8 : size.y - 120
        self.init(width: size.x, height: size.y, bandTop: top, bandBottom: bottom)
    }

    var bandHeight: Double { bandBottom - bandTop }
    /// Points per face unit for a face at its neutral size: min(W/400, bandH/600, 1.6).
    var scale: Double { min(width / 400, bandHeight / 600, 1.6) }
    /// The smallest face scale the solver uses (0.62·s_n).
    var minimumScale: Double { 0.62 * scale }
    /// The seam spans a centred window at most 720 pt wide.
    var windowWidth: Double { min(width, 720) }
    var windowMinX: Double { (width - windowWidth) / 2 }

    /// A band fraction as a stage y.
    func y(_ v: Double) -> Double { bandTop + v * bandHeight }
    /// A stage y as a band fraction.
    func v(_ y: Double) -> Double { (y - bandTop) / bandHeight }
    /// A seam abscissa as a stage x.
    func x(_ u: Double) -> Double { windowMinX + u * windowWidth }
    /// A stage x as a seam abscissa (unclamped).
    func u(_ x: Double) -> Double { (x - windowMinX) / windowWidth }

    /// For the checks: W = 400 and the band is [0, 600], so s_n = 1 and a face unit is a point.
    static let fidelity = StageMetrics(width: 400, height: 600, bandTop: 0, bandBottom: 600)
    static let iPhoneSE = StageMetrics(width: 375, height: 667, bandTop: 86, bandBottom: 541)
    static let iPhone18Pro = StageMetrics(width: 402, height: 874, bandTop: 128, bandBottom: 714)
    static let iPhoneProMax = StageMetrics(width: 440, height: 956, bandTop: 128, bandBottom: 796)
    static let iPadPortrait = StageMetrics(width: 820, height: 1180, bandTop: 90, bandBottom: 1030)
    static let iPadLandscape = StageMetrics(width: 1180, height: 820, bandTop: 90, bandBottom: 670)
}

/// The stage's settled arrangements.
enum StagePreset: String, CaseIterable, Sendable {
    case neutral
    /// The human addressed the angel and nobody holds the floor.
    case leanAngel
    case leanDevil
    /// The angel holds the floor.
    case angelFloor
    /// The devil holds the floor.
    case devilFloor

    /// The seam's targets before the room clamps.
    var shape: SeamShape {
        switch self {
        case .neutral: .neutral
        // The leans drift as the neutral seam does.
        case .leanAngel: SeamShape(base: 0.535, bulge: 0.02, wave: 0, drift: SeamShape.idleDrift)
        case .leanDevil: SeamShape(base: 0.465, bulge: 0, wave: 0.006, drift: SeamShape.idleDrift)
        case .angelFloor: SeamShape(base: KeyPoses.angelFloorBase, bulge: KeyPoses.angelFloorBulge, wave: 0)
        case .devilFloor: SeamShape(base: KeyPoses.devilFloorMean, bulge: 0, wave: KeyPoses.devilFloorAmplitude)
        }
    }

    /// Who holds the floor in this preset.
    var speaker: DuoCharacter? {
        switch self {
        case .angelFloor: .angel
        case .devilFloor: .devil
        default: nil
        }
    }

    /// Who is squished in this preset.
    var listener: DuoCharacter? { speaker.map { $0 == .angel ? .devil : .angel } }

    /// The preset for a floor holder, or for who the human addressed when nobody holds it.
    static func resolve(floor: DuoCharacter?, addressed: Set<DuoCharacter>) -> StagePreset {
        switch floor {
        case .angel: return .angelFloor
        case .devil: return .devilFloor
        case nil:
            if addressed == [.angel] { return .leanAngel }
            if addressed == [.devil] { return .leanDevil }
            return .neutral
        }
    }
}

/// What a caption bubble shows.
enum BubbleKind: Equatable, Hashable, Sendable {
    case caption
    case dots
}

/// Everything the layout depends on except measured heights. It changes only on events.
struct StageLayoutKey: Equatable, Hashable, Sendable {
    var preset = StagePreset.neutral
    /// The visible bubbles.
    var bubbles: [DuoCharacter: BubbleKind] = [:]
    /// Squished writers shown as a typing capsule.
    var capsules: Set<DuoCharacter> = []
    /// The human's words are shown.
    var pill = false
    /// Who spoke last: their neutral caption stays when two cannot fit.
    var lead = DuoCharacter.angel
}

/// Feature boxes in face units at rest, around each face's origin (the eye midpoint). Each is
/// computed once.
enum FaceBoxes {
    struct Box: Equatable, Sendable {
        var min: Vec2
        var max: Vec2
    }

    private static let angelLayout = Box(min: AngelGeometry.layoutBoxMin, max: AngelGeometry.layoutBoxMax)
    private static let devilLayout = Box(min: DevilGeometry.layoutBoxMin, max: DevilGeometry.layoutBoxMax)
    private static let angelEyes = makeEyes(.angel), devilEyes = makeEyes(.devil)
    private static let angelBrows = makeBrows(.angel), devilBrows = makeBrows(.devil)
    private static let angelMouth = makeMouth(.angel), devilMouth = makeMouth(.devil)
    private static let angelFeatures = makeFeatures(.angel), devilFeatures = makeFeatures(.devil)

    /// The face's extent including accessories (halo glow, wings, horns, marks).
    static func layout(_ c: DuoCharacter) -> Box { c == .angel ? angelLayout : devilLayout }

    /// Both eyes, screen left first.
    static func eyes(_ c: DuoCharacter) -> [Box] { c == .angel ? angelEyes : devilEyes }

    /// Both brows with their stroke, screen left first.
    static func brows(_ c: DuoCharacter) -> [Box] { c == .angel ? angelBrows : devilBrows }

    /// The mouth at rest with its outline.
    static func mouth(_ c: DuoCharacter) -> Box { c == .angel ? angelMouth : devilMouth }

    /// The union of eyes, brows and mouth.
    static func features(_ c: DuoCharacter) -> Box { c == .angel ? angelFeatures : devilFeatures }

    /// The devil's horns, screen left first, with 8 fu to spare and room for the squished
    /// splay and press; none for the angel.
    static func horns(_ c: DuoCharacter) -> [Box] { c == .angel ? [] : devilHorns }

    private static let devilHorns: [Box] = {
        let xs = [DevilGeometry.hornTip.x, DevilGeometry.hornOuterBase.x, DevilGeometry.hornInnerBase.x]
        let ys = [DevilGeometry.hornTip.y, DevilGeometry.hornOuterBase.y, DevilGeometry.hornInnerBase.y]
        let pad = 8.0, splay = 14.0
        let left = Box(min: Vec2(xs.min()! - pad - splay, ys.min()! - pad),
                       max: Vec2(xs.max()! + pad, ys.max()! + pad + DevilGeometry.hornPress))
        return [left, Box(min: Vec2(-left.max.x, left.min.y), max: Vec2(-left.min.x, left.max.y))]
    }()

    private static func makeEyes(_ c: DuoCharacter) -> [Box] {
        let center = c == .angel ? AngelGeometry.eyeCenter : DevilGeometry.eyeCenter
        let half = (c == .angel ? AngelGeometry.eyeSize : DevilGeometry.eyeSize) / 2
        return [-1.0, 1].map { sigma in
            let p = center.sided(sigma)
            return Box(min: p - half, max: p + half)
        }
    }

    private static func makeBrows(_ c: DuoCharacter) -> [Box] {
        let right: Box
        if c == .angel {
            let pad = AngelGeometry.browStroke / 2
            let inner = AngelGeometry.browInner, outer = AngelGeometry.browOuter
            right = Box(min: Vec2(inner.x - pad, min(inner.y, outer.y) - AngelGeometry.browSagitta - pad),
                        max: Vec2(outer.x + pad, max(inner.y, outer.y) + pad))
        } else {
            let inner = DevilGeometry.browInner, outer = DevilGeometry.browOuter
            let cap = DevilGeometry.browOuterThickness / 2
            right = Box(min: Vec2(inner.x, outer.y - cap - DevilGeometry.browArch),
                        max: Vec2(outer.x + cap, inner.y + DevilGeometry.browInnerThickness / 2))
        }
        return [Box(min: Vec2(-right.max.x, right.min.y), max: Vec2(-right.min.x, right.max.y)), right]
    }

    private static func makeMouth(_ c: DuoCharacter) -> Box {
        let pad = 2.25
        if c == .angel {
            let a = AngelGeometry.mouthAnchor, w = AngelGeometry.mouthWidth
            return Box(min: Vec2(a.x - w / 2 - pad, a.y - pad),
                       max: Vec2(a.x + w / 2 + pad, a.y + AngelGeometry.mouthDepth + pad))
        }
        let l = DevilGeometry.mouthLeftCorner, r = DevilGeometry.mouthRightCorner
        return Box(min: Vec2(l.x - pad, min(l.y, r.y) - pad),
                   max: Vec2(r.x + pad, DevilGeometry.mouthAnchor.y + DevilGeometry.mouthDepth + pad))
    }

    private static func makeFeatures(_ c: DuoCharacter) -> Box {
        let all = makeEyes(c) + makeBrows(c) + [makeMouth(c)]
        return Box(min: Vec2(all.map(\.min.x).min()!, all.map(\.min.y).min()!),
                   max: Vec2(all.map(\.max.x).max()!, all.map(\.max.y).max()!))
    }
}

/// A face's settled placement: the head transform without tilt.
struct FacePlacement: Equatable, Sendable {
    /// The stage point the pivot sits on.
    var anchor: Vec2
    /// The pivot in face units: the eye midpoint for a free face, the floor contact or the halo
    /// top for a squished one.
    var pivot: Vec2
    /// Points per face unit, role scale included.
    var scale: Double
    /// The scale the face would have with room to spare.
    var designScale: Double
    /// The settled vertical squash sy.
    var squash: Double
    /// The floor or ceiling a squished face is pinned to (stage y).
    var pin: FacePin?
    /// How far past its normal clearance the face had to be pushed toward its bubble (pt);
    /// 0 when it fits.
    var squeeze: Double
    /// How far the face box reaches into its bubble (pt).
    var overlap: Double

    /// sx = sy^(−0.4): the face keeps its volume.
    var stretch: Double { pow(squash, -0.4) }

    /// A face-unit point in stage points.
    func point(_ p: Vec2) -> Vec2 {
        anchor + Vec2((p.x - pivot.x) * scale * stretch, (p.y - pivot.y) * scale * squash)
    }

    func rect(_ box: FaceBoxes.Box) -> StageRect {
        let a = point(box.min), b = point(box.max)
        return StageRect(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
    }

    /// The eye midpoint's y.
    var eyeLine: Double { point(.zero).y }
}

/// The floor or the ceiling a squished face is pinned to.
enum FacePin: Equatable, Sendable {
    case floor(Double)
    case ceiling(Double)

    var y: Double {
        switch self {
        case .floor(let y), .ceiling(let y): y
        }
    }
}

/// A caption bubble's slot.
struct BubbleSlot: Equatable, Sendable {
    enum Tail: Equatable, Sendable {
        case top
        case bottom
    }

    var kind: BubbleKind
    var rect: StageRect
    /// Where the 12 × 9 tail points from (stage x), 30 pt inside the corners.
    var tailX: Double
    var tail: Tail
    /// The floor holder's bubble.
    var isSpeaker: Bool
}

/// A squished writer's typing capsule.
struct CapsuleSlot: Equatable, Sendable {
    var rect: StageRect
    /// The face the tail points to.
    var tailToward: Vec2
    /// False when no candidate cleared everything and the capsule overlaps decoration.
    var clear: Bool
}

/// The pure layout solver: seam targets with the room clamps, face anchors, scales and pivots,
/// the floor and ceiling, and the slots for bubbles, capsules, the pill and the accessibility
/// regions. The simulation takes its targets from it and the caption layer its rects; both get
/// the same answer for the same key, metrics and heights.
struct StageLayout: Equatable, Sendable {
    static let bubbleGap = 19.0
    /// The speaking angel's gap above her bubble: 8 pt more, for the open jaw and riding the
    /// blob, so her chin never meets the tail mid-sentence.
    static let speakerBubbleGap = bubbleGap + 8
    static let speakerSeamClearance = 16.0
    static let pushBack = 0.008
    static let capsuleSize = Vec2(52, 30)

    /// A caption bubble's width with nobody on the floor: a capsule two thirds of the screen
    /// wide, at most 380 pt.
    static func neutralBubbleWidth(_ width: Double) -> Double { min(380, (0.66 * width).rounded()) }

    /// The floor holder's bubble, wider for the sentence being said: at most 340 pt, 32 pt from
    /// each edge.
    static func speakerBubbleWidth(_ width: Double) -> Double { min(340, width - 64) }

    var key: StageLayoutKey
    var metrics: StageMetrics
    /// The seam's settled targets after the room clamps and any push for room.
    var seam: SeamShape
    /// The preset's seam after the room clamps, before pushes: the accessibility regions use it.
    var presetSeam: SeamShape
    /// The squished listener's walls on the live seam.
    var limits: SeamRig.Limits
    var faces: PerCharacter<FacePlacement>
    var bubbles: [DuoCharacter: BubbleSlot] = [:]
    /// A neutral caption hidden because both could not fit within the rules; VoiceOver still
    /// reads it.
    var hidden: Set<DuoCharacter> = []
    var capsules: [DuoCharacter: CapsuleSlot] = [:]
    var pill: StageRect?
    /// Each character's settled half, for the accessibility elements.
    var regions: PerCharacter<StageRect>

    // MARK: Solving

    static func solve(key: StageLayoutKey, metrics m: StageMetrics,
                      bubbleHeights: [DuoCharacter: Double] = [:], pillHeight: Double = 0) -> StageLayout {
        let (presetSeam, limits) = clamped(key.preset, metrics: m)
        var visible = key.bubbles
        if let speaker = key.preset.speaker {
            // While someone holds the floor only the speaker's caption shows.
            visible = visible.filter { $0.key == speaker }
            if visible[speaker] == .dots { visible[speaker] = nil }
        }
        var hidden: Set<DuoCharacter> = []
        var best = search(key: key, metrics: m, seam: presetSeam, bubbles: visible,
                          heights: bubbleHeights, pillHeight: pillHeight)
        // With nobody on the floor both last sentences show, unless even the last fit step (faces
        // at 0.62·s_n, overlapped by their bubbles by 30%) cannot hold them, as with two large
        // captions on a small phone: then only the last speaker's shows. VoiceOver reads both.
        if key.preset.speaker == nil, visible.count == 2, !best.withinRules {
            let earlier: DuoCharacter = key.lead == .angel ? .devil : .angel
            hidden.insert(earlier)
            visible[earlier] = nil
            best = search(key: key, metrics: m, seam: presetSeam, bubbles: visible,
                          heights: bubbleHeights, pillHeight: pillHeight)
        }
        let centreY = m.y(presetSeam.value(at: 0.5))
        var layout = StageLayout(
            key: key, metrics: m, seam: best.seam, presetSeam: presetSeam, limits: limits,
            faces: best.faces, bubbles: best.bubbles, hidden: hidden, pill: best.pill,
            regions: PerCharacter(angel: StageRect(minX: 0, minY: m.bandTop, maxX: m.width, maxY: centreY),
                                  devil: StageRect(minX: 0, minY: centreY, maxX: m.width, maxY: m.bandBottom)))
        for c in DuoCharacter.allCases where key.capsules.contains(c) && key.preset.listener == c {
            layout.capsules[c] = layout.placeCapsule(for: c)
        }
        return layout
    }

    /// The preset's seam with the listener's minimum room, and the listener's walls. The clamp
    /// reduces the bulge first, then moves the base. The devil's wave is not a bulge, so a short
    /// band moves his base and keeps the wave.
    static func clamped(_ preset: StagePreset, metrics m: StageMetrics) -> (SeamShape, SeamRig.Limits) {
        var shape = preset.shape
        let room = roomLimits(metrics: m)
        switch preset {
        case .angelFloor:
            let excess = shape.centre - room.maxLowest
            if excess > 0 {
                let cut = min(excess, shape.bulge)
                shape.bulge -= cut
                shape.base -= excess - cut
            }
        case .devilFloor:
            let deficit = room.minHighest - (shape.base - abs(shape.wave))
            if deficit > 0 { shape.base += deficit }
        case .neutral, .leanAngel, .leanDevil:
            break
        }
        return (shape, walls(preset, metrics: m))
    }

    /// Where a settled seam may go with both characters keeping their minimum room: the centre no
    /// lower than the devil's room above the floor, the highest point no higher than the angel's
    /// room below the ceiling.
    static func roomLimits(metrics m: StageMetrics) -> SeamRig.Limits {
        SeamRig.Limits(maxLowest: floorV - minimumRoom(for: .devil, metrics: m) / m.bandHeight,
                       minHighest: ceilingV + minimumRoom(for: .angel, metrics: m) / m.bandHeight)
    }

    /// The squished listener's walls on the live seam: the room where its contact squash reaches
    /// its deepest, need·sMin·s, over its face span (±100 fu). The settled seam keeps the minimum
    /// room above that (at least 8 pt more), which leaves the speaker's handover overshoot room
    /// to deepen the squash before it bounces.
    static func walls(_ preset: StagePreset, metrics m: StageMetrics) -> SeamRig.Limits {
        guard let listener = preset.listener else { return .none }
        let half = 100 * m.scale
        var limits = SeamRig.Limits(span: m.u(m.width / 2 - half)...m.u(m.width / 2 + half))
        let room = deepestRoom(for: listener, metrics: m) / m.bandHeight
        if listener == .devil { limits.maxLowest = floorV - room } else { limits.minHighest = ceilingV + room }
        return limits
    }

    /// The squished devil's pivot sits on this band fraction.
    static let floorV = KeyPoses.angelFloorFloor
    /// The squished angel's halo top sits on this band fraction.
    static let ceilingV = KeyPoses.devilFloorHaloTop

    /// The room a squished listener keeps between its pinned edge and the seam (pt):
    /// the devil max(112, (130·0.70)·s + 8), the angel max(150, (201·0.86)·s + 8).
    static func minimumRoom(for listener: DuoCharacter, metrics m: StageMetrics) -> Double {
        max(listener == .angel ? 150 : 112, deepestRoom(for: listener, metrics: m) + 8)
    }

    /// The room that squashes a listener to its deepest (pt): need·sMin·s.
    static func deepestRoom(for listener: DuoCharacter, metrics m: StageMetrics) -> Double {
        let contact = Contact.of(listener)
        return contact.need * contact.minimum * m.scale
    }

    /// The contact squash of a squished listener.
    struct Contact: Equatable, Sendable {
        /// The squash it settles at with room to spare.
        var pressure: Double
        /// The deepest squash.
        var minimum: Double
        /// The height that squashes (fu): pivot to brow top, or halo top to chin.
        var need: Double

        static let devil = Contact(pressure: 0.78, minimum: 0.70, need: 130)
        static let angel = Contact(pressure: 0.92, minimum: 0.86, need: 201)

        static func of(_ c: DuoCharacter) -> Contact { c == .angel ? angel : devil }

        /// sy = clamp(min(pressure, room/need), minimum, 1), with `need` scaled to points.
        func squash(room: Double, scale: Double) -> Double {
            RigMath.clamp(min(pressure, room / (need * scale)), minimum, 1)
        }
    }

    // MARK: Arrangement

    private struct Arrangement {
        var seam: SeamShape
        var faces: PerCharacter<FacePlacement>
        var bubbles: [DuoCharacter: BubbleSlot]
        var pill: StageRect?
        /// The smallest scale ratio of a fitted face.
        var ratio: Double
        /// The largest overlap as a fraction of the face's height.
        var overlapFraction: Double
        var squeezed: Bool
        var feasible: Bool

        var atDesign: Bool { ratio >= 1 - 1e-12 && !squeezed && feasible }
        var withinRules: Bool { feasible && overlapFraction <= 0.3 + 1e-9 }
    }

    /// The idle drift needs room on both sides of the seam. Faces may shrink a little to keep
    /// it, but when they would be squeezed into their bubbles or break the fit rules, the drift
    /// gives way: the seam is also tried still, and kept still only when that fits strictly
    /// better.
    private static func search(key: StageLayoutKey, metrics m: StageMetrics, seam: SeamShape,
                               bubbles: [DuoCharacter: BubbleKind],
                               heights: [DuoCharacter: Double], pillHeight: Double) -> Arrangement {
        let drifting = searchPushes(key: key, metrics: m, seam: seam, bubbles: bubbles, heights: heights,
                                    pillHeight: pillHeight)
        guard seam.drift > 0, drifting.squeezed || !drifting.withinRules else { return drifting }
        var still = seam
        still.drift = 0
        let held = searchPushes(key: key, metrics: m, seam: still, bubbles: bubbles, heights: heights,
                                pillHeight: pillHeight)
        return better(held, 0, than: drifting, 0) ? held : drifting
    }

    /// Tries the seam at the preset's position, then pushed within the listener's minimum room
    /// (with nobody on the floor, within both characters' rooms), and keeps the best: faces at
    /// design size with the smallest push; otherwise one within the rules, preferring no squeeze,
    /// then the least overlap, the largest faces and the smallest push. The search is coarse
    /// (0.01 band), then fine (0.0025 band) around the coarse winner.
    private static func searchPushes(key: StageLayoutKey, metrics m: StageMetrics, seam: SeamShape,
                                     bubbles: [DuoCharacter: BubbleKind],
                                     heights: [DuoCharacter: Double], pillHeight: Double) -> Arrangement {
        func arrange(_ delta: Double) -> Arrangement {
            var shape = seam
            shape.base += delta
            return arrangement(key: key, metrics: m, seam: shape, bubbles: bubbles, heights: heights,
                               pillHeight: pillHeight)
        }
        let start = arrange(0)
        if start.atDesign { return start }
        let lower: Double, upper: Double
        let room = roomLimits(metrics: m)
        switch key.preset {
        case .angelFloor:
            (lower, upper) = (0, max(0, room.maxLowest - seam.centre))
        case .devilFloor:
            (lower, upper) = (min(0, room.minHighest - (seam.base - abs(seam.wave))), 0)
        case .neutral, .leanAngel, .leanDevil:
            guard !bubbles.isEmpty || key.pill else { return start }
            lower = min(0, room.minHighest - (seam.base - abs(seam.wave) - abs(seam.drift)))
            upper = max(0, room.maxLowest - (seam.centre + abs(seam.drift)))
        }
        guard upper > lower else { return start }
        var best = start, bestDelta = 0.0
        func scan(from a: Double, to b: Double, step: Double) {
            var delta = a
            while true {
                let d = min(delta, b)
                if d != 0 {
                    let candidate = arrange(d)
                    if better(candidate, d, than: best, bestDelta) {
                        best = candidate
                        bestDelta = d
                    }
                }
                if d >= b { break }
                delta += step
            }
        }
        scan(from: lower, to: upper, step: 0.01)
        let centre = bestDelta
        scan(from: max(lower, centre - 0.01), to: min(upper, centre + 0.01), step: 0.0025)
        return best
    }

    private static func better(_ a: Arrangement, _ da: Double, than b: Arrangement, _ db: Double) -> Bool {
        if a.atDesign != b.atDesign { return a.atDesign }
        if a.atDesign { return abs(da) < abs(db) - 1e-12 }
        if a.withinRules != b.withinRules { return a.withinRules }
        let aClean = !a.squeezed, bClean = !b.squeezed
        if aClean != bClean { return aClean }
        if abs(a.overlapFraction - b.overlapFraction) > 1e-9 { return a.overlapFraction < b.overlapFraction }
        if abs(a.ratio - b.ratio) > 1e-9 { return a.ratio > b.ratio }
        return abs(da) < abs(db) - 1e-12
    }

    /// One constraint on a face's anchor y: `y − reach·s ≥ limit` (lower) or
    /// `y + reach·s ≤ limit` (upper). A soft one is a bubble's clearance, which may give way.
    private struct Bound {
        var limit: Double
        var reach: Double
        /// The clearance between the limit and the bubble, for soft bounds.
        var gap: Double?
    }

    private struct Fit {
        var scale: Double
        var y: Double
        var squeeze: Double
        var overlap: Double
        var height: Double
        var feasible: Bool
        /// The scale as a fraction of the design scale.
        var ratio = 1.0
    }

    /// Fits a face: at its design anchor if it fits, else moved within its room, else shrunk down
    /// to 0.62·s_n, else squeezed into its bubble's clearance and then the bubble. The design
    /// anchor is `design + designPerScale·s`.
    private static func fit(design: Double, designPerScale: Double = 0, designScale: Double,
                            minimumScale: Double, top: Double, bottom: Double,
                            lower: [Bound], upper: [Bound]) -> Fit {
        func bounds(_ s: Double, give: Double) -> (lo: Double, hi: Double) {
            var lo = -Double.infinity, hi = Double.infinity
            for b in lower { lo = max(lo, b.limit + b.reach * s - (b.gap == nil ? 0 : give)) }
            for b in upper { hi = min(hi, b.limit - b.reach * s + (b.gap == nil ? 0 : give)) }
            return (lo, hi)
        }
        var largest = designScale
        for l in lower {
            for u in upper where l.reach + u.reach > 0 {
                largest = min(largest, (u.limit - l.limit) / (l.reach + u.reach))
            }
        }
        if largest >= minimumScale {
            let s = largest
            let (lo, hi) = bounds(s, give: 0)
            let y = min(max(design + designPerScale * s, lo), max(lo, hi))
            return Fit(scale: s, y: y, squeeze: 0, overlap: 0, height: (top + bottom) * s, feasible: true)
        }
        let s = minimumScale
        let (lo, hi) = bounds(s, give: 0)
        let give = max(0, lo - hi)
        let relaxed = bounds(s, give: give)
        let feasible = relaxed.lo <= relaxed.hi + 1e-9
        let y = feasible ? min(max(design + designPerScale * s, relaxed.lo), relaxed.hi) : relaxed.hi
        let gap = (lower + upper).compactMap(\.gap).min() ?? 0
        return Fit(scale: s, y: y, squeeze: give, overlap: max(0, give - gap),
                   height: (top + bottom) * s, feasible: feasible)
    }

    private static func arrangement(key: StageLayoutKey, metrics m: StageMetrics, seam: SeamShape,
                                    bubbles: [DuoCharacter: BubbleKind], heights: [DuoCharacter: Double],
                                    pillHeight: Double) -> Arrangement {
        let relaxed = seam.relaxed()
        let w = m.width, sN = m.scale
        func span(_ halfWidth: Double) -> (Double, Double) { (m.u(w / 2 - halfWidth), m.u(w / 2 + halfWidth)) }
        /// The highest the settled seam gets over a span (active and relaxed).
        func highest(_ halfWidth: Double, pushBack: Bool = false) -> Double {
            let (u0, u1) = span(halfWidth)
            return m.y(min(seam.highest(from: u0, to: u1), relaxed.highest(from: u0, to: u1))
                - (pushBack ? Self.pushBack : 0))
        }
        func lowest(_ halfWidth: Double) -> Double {
            let (u0, u1) = span(halfWidth)
            return m.y(max(seam.lowest(from: u0, to: u1), relaxed.lowest(from: u0, to: u1)))
        }
        func height(_ c: DuoCharacter) -> Double { max(0, heights[c] ?? 0) }

        var pill: StageRect?
        if key.pill {
            let h = max(0, pillHeight), pw = min(380, w - 32)
            let lo = m.bandTop + h / 2 + 8, hi = m.bandBottom - h / 2 - 8
            let cy = min(max(m.y(seam.value(at: 0.5)), lo), max(lo, hi))
            pill = StageRect(x: (w - pw) / 2, y: cy - h / 2, width: pw, height: h)
        }
        let angelBox = FaceBoxes.layout(.angel), devilBox = FaceBoxes.layout(.devil)
        let devilFeatures = FaceBoxes.features(.devil)
        var faces = PerCharacter(angel: pinned(.angel, seam: seam, metrics: m),
                                 devil: pinned(.devil, seam: seam, metrics: m))
        var slots: [DuoCharacter: BubbleSlot] = [:]
        var fits: [Fit] = []

        func place(_ c: DuoCharacter, _ fit: Fit, designScale: Double) {
            faces[c] = FacePlacement(anchor: Vec2(w / 2, fit.y), pivot: .zero, scale: fit.scale,
                                     designScale: designScale, squash: 1, pin: nil,
                                     squeeze: fit.squeeze, overlap: fit.overlap)
            var fit = fit
            fit.ratio = fit.scale / designScale
            fits.append(fit)
        }

        switch key.preset {
        case .neutral, .leanAngel, .leanDevil:
            let gap = key.pill ? max(30, max(0, pillHeight) / 2 + 8) : 30
            let bw = neutralBubbleWidth(w)
            for c in DuoCharacter.allCases {
                guard let kind = bubbles[c] else { continue }
                let h = height(c)
                let y = c == .angel ? highest(bw / 2) - gap - h : lowest(bw / 2) + gap
                slots[c] = BubbleSlot(kind: kind, rect: StageRect(x: (w - bw) / 2, y: y, width: bw, height: h),
                                      tailX: w / 2, tail: c == .angel ? .top : .bottom, isSpeaker: false)
            }
            for c in DuoCharacter.allCases {
                let lean: StagePreset = c == .angel ? .leanAngel : .leanDevil
                let design = sN * (key.preset == lean ? 1.05 : 1)
                let box = c == .angel ? angelBox : devilBox
                let half = max(abs(box.min.x), box.max.x) * design
                if c == .angel {
                    var upper = [Bound(limit: highest(half) - 8, reach: box.max.y)]
                    if let slot = slots[.angel] {
                        upper.append(Bound(limit: slot.rect.minY - bubbleGap, reach: box.max.y, gap: bubbleGap))
                    }
                    // The pill clears the wings too: their rest spread and the listening tilt
                    // lower a wing tip up to 18 fu below the rest box.
                    if let pill { upper.append(Bound(limit: pill.minY - 8, reach: box.max.y + 18)) }
                    place(.angel, fit(design: m.y(KeyPoses.neutralAngel.eyeLine), designScale: design,
                                      minimumScale: m.minimumScale, top: -box.min.y, bottom: box.max.y,
                                      lower: [Bound(limit: m.bandTop + 4, reach: -box.min.y)], upper: upper),
                          designScale: design)
                } else {
                    var lower = [Bound(limit: lowest(half) + 8, reach: -box.min.y)]
                    if let slot = slots[.devil] {
                        lower.append(Bound(limit: slot.rect.maxY + bubbleGap, reach: -box.min.y, gap: bubbleGap))
                    }
                    // The pill clears the horn tips too, not just the features.
                    if let pill { lower.append(Bound(limit: pill.maxY + 8, reach: -box.min.y)) }
                    place(.devil, fit(design: m.y(KeyPoses.neutralDevil.eyeLine), designScale: design,
                                      minimumScale: m.minimumScale, top: -box.min.y, bottom: box.max.y,
                                      lower: lower, upper: [Bound(limit: m.bandBottom - 4, reach: box.max.y)]),
                          designScale: design)
                }
            }

        case .angelFloor:
            let design = sN * KeyPoses.angelFloorAngel.scale.x
            let half = max(abs(angelBox.min.x), angelBox.max.x) * design
            var upper = [Bound(limit: highest(half) - 8, reach: angelBox.max.y)]
            if let kind = bubbles[.angel] {
                let bw = speakerBubbleWidth(w), h = height(.angel)
                let bottom = highest(bw / 2, pushBack: true) - Self.speakerSeamClearance
                let rect = StageRect(x: (w - bw) / 2, y: bottom - h, width: bw, height: h)
                slots[.angel] = BubbleSlot(kind: kind, rect: rect, tailX: w / 2, tail: .top, isSpeaker: true)
                upper.append(Bound(limit: rect.minY - speakerBubbleGap, reach: angelBox.max.y, gap: speakerBubbleGap))
            }
            place(.angel, fit(design: m.y(KeyPoses.angelFloorAngel.eyeLine), designScale: design,
                              minimumScale: m.minimumScale, top: -angelBox.min.y, bottom: angelBox.max.y,
                              lower: [Bound(limit: m.bandTop + 4, reach: -angelBox.min.y)], upper: upper),
                  designScale: design)

        case .devilFloor:
            let design = sN * KeyPoses.devilFloorDevil.scale.x
            let hornHalf = abs(DevilGeometry.hornTip.x) * design
            let clearance = lowest(hornHalf)
            let tip = -DevilGeometry.hornTip.y
            var upper = [Bound(limit: m.bandBottom - 4, reach: devilBox.max.y)]
            if let kind = bubbles[.devil] {
                let bw = speakerBubbleWidth(w), h = height(.devil)
                let rect = StageRect(x: (w - bw) / 2, y: m.bandBottom - 4 - h, width: bw, height: h)
                let tailX = w / 2 + DevilGeometry.neutralShiftX * design
                slots[.devil] = BubbleSlot(kind: kind, rect: rect, tailX: tailX, tail: .top, isSpeaker: true)
                upper.append(Bound(limit: rect.minY - 15, reach: devilFeatures.max.y, gap: 15))
            }
            place(.devil, fit(design: clearance + 0.03 * m.bandHeight, designPerScale: tip, designScale: design,
                              minimumScale: m.minimumScale, top: -devilBox.min.y, bottom: devilBox.max.y,
                              lower: [Bound(limit: clearance, reach: tip)], upper: upper),
                  designScale: design)
        }

        for (c, slot) in slots {
            let mouthX = faces[c].point(c == .angel ? AngelGeometry.mouthAnchor
                : DevilGeometry.mouthAnchor + Vec2(DevilGeometry.neutralShiftX, 0)).x
            var slot = slot
            let target = slot.isSpeaker ? mouthX : faces[c].anchor.x
            slot.tailX = min(max(target, slot.rect.minX + 30), max(slot.rect.minX + 30, slot.rect.maxX - 30))
            slots[c] = slot
        }
        return Arrangement(seam: seam, faces: faces, bubbles: slots, pill: pill,
                           ratio: fits.map(\.ratio).min() ?? 1,
                           overlapFraction: fits.map { $0.overlap / max($0.height, 1e-9) }.max() ?? 0,
                           squeezed: fits.contains { $0.squeeze > 1e-9 },
                           feasible: fits.allSatisfy(\.feasible))
    }

    /// A squished listener pinned to the floor (devil) or the ceiling (angel), squashed by the
    /// settled seam; a placeholder for faces that are fitted instead.
    private static func pinned(_ c: DuoCharacter, seam: SeamShape, metrics m: StageMetrics) -> FacePlacement {
        let s = m.scale
        let contact = Contact.of(c)
        let half = 100 * s
        let u0 = m.u(m.width / 2 - half), u1 = m.u(m.width / 2 + half)
        if c == .devil {
            let floor = m.y(floorV)
            let room = floor - m.y(seam.lowest(from: u0, to: u1))
            return FacePlacement(anchor: Vec2(m.width / 2, floor), pivot: DevilGeometry.squishPivot, scale: s,
                                 designScale: s, squash: contact.squash(room: room, scale: s),
                                 pin: .floor(floor), squeeze: 0, overlap: 0)
        }
        let ceiling = m.y(ceilingV)
        let room = m.y(seam.highest(from: u0, to: u1)) - ceiling
        return FacePlacement(anchor: Vec2(m.width / 2, ceiling), pivot: AngelGeometry.squishPivot, scale: s,
                             designScale: s, squash: contact.squash(room: room, scale: s),
                             pin: .ceiling(ceiling), squeeze: 0, overlap: 0)
    }

    // MARK: Capsules

    /// The squished writer's capsule: the first candidate that clears the faces' eyes, mouths and
    /// brows, the speaker's bubble and the live seam envelope + 6 pt. The angel's first float
    /// beside her head at brow level, over a wing and under the halo's dashes, clear of the
    /// header's buttons in the top corners.
    private func placeCapsule(for c: DuoCharacter) -> CapsuleSlot {
        let m = metrics, size = Self.capsuleSize
        let face = faces[c]
        let toward = face.point(.zero)
        func edgeY(_ x0: Double) -> Double {
            let envelope = liveEnvelope(fromX: x0, toX: x0 + size.x)
            return c == .angel ? m.bandTop + 4 : m.y(envelope.lowest) + 8
        }
        let eyeOuter = (c == .angel ? AngelGeometry.eyeCenter.x + AngelGeometry.eyeSize.x / 2
            : DevilGeometry.eyeCenter.x + DevilGeometry.eyeSize.x / 2) + 16
        let eyeY = toward.y - size.y / 2
        let besideLeft = face.point(Vec2(-eyeOuter, 0)).x - size.x
        let besideRight = face.point(Vec2(eyeOuter, 0)).x
        var candidates = [
            StageRect(x: 16, y: edgeY(16), width: size.x, height: size.y),
            StageRect(x: m.width - 16 - size.x, y: edgeY(m.width - 16 - size.x), width: size.x, height: size.y),
            StageRect(x: besideLeft, y: eyeY, width: size.x, height: size.y),
            StageRect(x: besideRight, y: eyeY, width: size.x, height: size.y),
        ]
        if c == .angel {
            let y = face.point(Vec2(0, (AngelGeometry.browOuter.y + AngelGeometry.browInner.y) / 2)).y - size.y / 2
            let wing = (AngelGeometry.wingBoxMin.x + AngelGeometry.wingBoxMax.x) / 2
            let besideHead = [wing, -wing].map { x in
                StageRect(x: RigMath.clamp(face.point(Vec2(x, 0)).x - size.x / 2, 16, m.width - 16 - size.x), y: y,
                          width: size.x, height: size.y)
            }
            candidates.insert(contentsOf: besideHead, at: 0)
        }
        // The squished devil's horns fill his outer corners under the seam, so his capsule
        // tries just below a horn first.
        if let horn = FaceBoxes.horns(c).first.map({ face.rect($0) }) {
            let y = max(horn.maxY + 2, edgeY(16))
            candidates.insert(contentsOf: [
                StageRect(x: 16, y: y, width: size.x, height: size.y),
                StageRect(x: m.width - 16 - size.x, y: y, width: size.x, height: size.y),
            ], at: 0)
        }
        if let clear = candidates.first(where: { capsuleClears($0, for: c, strict: true) }) {
            return CapsuleSlot(rect: clear, tailToward: toward, clear: true)
        }
        let fallback = candidates.first { capsuleClears($0, for: c, strict: false) } ?? candidates[0]
        return CapsuleSlot(rect: fallback, tailToward: toward, clear: false)
    }

    /// Whether a capsule for listener `c` stays in the band and on screen, on its side of the
    /// live envelope + 6 pt, and clear of the eyes and mouths (and, when strict, the brows, the
    /// horns and the speaker's bubble).
    func capsuleClears(_ rect: StageRect, for c: DuoCharacter, strict: Bool) -> Bool {
        let m = metrics
        guard rect.minX >= 0, rect.maxX <= m.width, rect.minY >= m.bandTop, rect.maxY <= m.bandBottom else {
            return false
        }
        let envelope = liveEnvelope(fromX: rect.minX, toX: rect.maxX)
        if c == .angel ? rect.maxY > m.y(envelope.highest) - 6 : rect.minY < m.y(envelope.lowest) + 6 {
            return false
        }
        for face in DuoCharacter.allCases {
            var boxes = FaceBoxes.eyes(face) + [FaceBoxes.mouth(face)]
            if strict { boxes += FaceBoxes.brows(face) + FaceBoxes.horns(face) }
            if boxes.contains(where: { faces[face].rect($0).intersects(rect) }) { return false }
        }
        if strict, let speaker = key.preset.speaker, let bubble = bubbles[speaker], bubble.rect.intersects(rect) {
            return false
        }
        return true
    }

    // MARK: Reading

    subscript(_ c: DuoCharacter) -> FacePlacement { faces[c] }

    /// How far the live seam can reach over [x0, x1] once settled (band fractions): the active
    /// and relaxed profiles at any wave phase, the push-back envelope, the pulse limit and the
    /// speaking angel's energy swelling her bulge by up to 6%. A handover's overshoot and ripple
    /// pass before the capsule's slot clears.
    func liveEnvelope(fromX x0: Double, toX x1: Double) -> (highest: Double, lowest: Double) {
        let u0 = metrics.u(x0), u1 = metrics.u(x1), relaxed = seam.relaxed()
        let highest = min(seam.highest(from: u0, to: u1), relaxed.highest(from: u0, to: u1)) - Self.pushBack
        let lowest = max(seam.lowest(from: u0, to: u1), relaxed.lowest(from: u0, to: u1)) + 0.06 * max(0, seam.bulge)
        return (highest - SeamRig.pulseLimit, lowest + SeamRig.pulseLimit)
    }

    /// The face's extent at rest, accessories included.
    func faceBox(_ c: DuoCharacter) -> StageRect { faces[c].rect(FaceBoxes.layout(c)) }

    /// The union of the face's eyes, brows and mouth.
    func featureBox(_ c: DuoCharacter) -> StageRect { faces[c].rect(FaceBoxes.features(c)) }

    /// Every text rect: bubbles, capsules and the pill.
    var textRects: [StageRect] {
        bubbles.values.map(\.rect) + capsules.values.map(\.rect) + (pill.map { [$0] } ?? [])
    }

    /// A measured bubble height as the layout uses it: rounded to 4 pt, and changed only when the
    /// rounded value moves by more than 6 pt or the content kind changes, so faces do not pump
    /// between sentences.
    static func layoutHeight(measured: Double, previous: Double?, kindChanged: Bool = false) -> Double {
        let rounded = (max(0, measured) / 4).rounded() * 4
        guard let previous, !kindChanged else { return rounded }
        return abs(rounded - previous) > 6 ? rounded : previous
    }
}

import Foundation

/// An axis-aligned ellipse given by its centre and full size.
struct FaceEllipse: Equatable, Sendable {
    var center: Vec2
    var size: Vec2
}

/// A circle by centre and radius.
struct FaceCircle: Equatable, Sendable {
    var center: Vec2
    var radius: Double
}

/// A capsule mark: `length` × `thickness`, its axis `angle` degrees below horizontal, pointing
/// inward (toward x = 0). Centres are for the screen-right mark; `center.sided(σ)` places either.
struct FaceCapsule: Equatable, Sendable {
    var center: Vec2
    var length: Double
    var thickness: Double
    var angle: Double
}

// The faces are measured in face units (fu). Each face's origin is the midpoint between its eye
// centres; +x is screen right and +y down. "Inner" means toward x = 0, and σ is −1 for the
// screen-left feature and +1 for the right. Paired features use one of three conventions,
// noted on each constant:
//
// - Screen-right (eyes, brows, blush, dashes, marks): a positive x describes the right feature,
//   and `p.sided(σ)` places it on side σ.
// - Screen-left (wings and horns): the constants describe the left feature (negative x), so
//   `p.sided(−σ)` places it on side σ.
// - Inner or outer (the angel's highlight, secondary highlight and sparkle): offsets from an eye
//   centre whose x counts toward the inner or outer side, so on side σ the screen offset is
//   `(−σ·x, y)` for inner and `(σ·x, y)` for outer.

/// The angel's face.
enum AngelGeometry {
    // Eyes: glossy ink beads.
    static let eyeCenter = Vec2(65, 0)
    static let eyeSize = Vec2(48, 60)
    /// The highlight ellipse, offset (inner, y).
    static let highlightSize = Vec2(14, 19)
    static let highlightInnerOffset = Vec2(7.5, -12)
    /// The secondary highlight dot, offset (outer, y).
    static let highlight2Diameter = 6.0
    static let highlight2OuterOffset = Vec2(6, 8)
    /// The 4-point star sparkle, offset (outer, y).
    static let sparkleTipRadius = 7.5
    static let sparkleWaist = 0.28
    static let sparkleOuterOffset = Vec2(8, 13)

    // Brows: an arc stroke along the chord, convex up.
    static let browStroke = 6.0
    static let browOuter = Vec2(89, -42)
    static let browInner = Vec2(61, -58)
    static let browSagitta = 5.0
    /// The chord's angle (degrees; negative is inner end up).
    static let browBaseAngle = -30.0

    // Mouth (the open D); the anchor is the top line's centre.
    static let mouthAnchor = Vec2(0, 25)
    static let mouthWidth = 54.0
    static let mouthDepth = 35.0

    // Every mouth is one ink shape about the open smile's size, with a coral tongue resting on
    // its bottom.
    /// The closed smile's width and thickness.
    static let mouthClosedWidth = 42.0
    static let mouthLine = 2.5
    /// The ink edge that rounds the shape's corners, centred on its outline.
    static let mouthEdge = 2.6
    /// The deepest speaking opening: an A.
    static let mouthTalkDepth = 34.0
    /// The tongue's tallest dome, and when it grows in (by the opening's depth).
    static let tongueMaxHeight = 15.0
    static let tongueGrowth = (from: 12.0, to: 18.0)

    static let blush = FaceEllipse(center: Vec2(86.5, 46), size: Vec2(39.5, 24))

    // Halo, centred on the midline: `haloOuterSize` is the ring's outer edge.
    static let haloCenter = Vec2(0, -115.2)
    static let haloOuterSize = Vec2(187, 51)
    /// The ring's hole. The ring is the band between its outer edge and this ellipse: thicker at
    /// the sides than at the top and bottom, with nothing filling the middle.
    static let haloHoleSize = Vec2(151, 27)

    /// The ring: its outer edge and its hole, centred on the origin, to fill even-odd.
    static func haloRing() -> (outer: Vec2, hole: Vec2) { (haloOuterSize, haloHoleSize) }
    static var haloTop: Double { haloCenter.y - haloOuterSize.y / 2 }

    // Marks: two light dashes above each eye, pointing inward.
    static let upperDash = FaceCapsule(center: Vec2(124, -119.5), length: 24, thickness: 8, angle: 46)
    static let lowerDash = FaceCapsule(center: Vec2(132, -88.5), length: 25, thickness: 8, angle: 22)
    /// Sparkle marks: stars of tip radius 9 and 5 (screen right).
    static let sparkleMarks = [FaceCircle(center: Vec2(118, -95), radius: 9),
                               FaceCircle(center: Vec2(140, -60), radius: 5)]

    // Wings (screen left): the box the wing fills at rest. The outline is `WingShape`'s.
    static let wingBoxMin = Vec2(-178, -18)
    static let wingBoxMax = Vec2(-124, 72)
    /// The hinge (root) the wing swings about.
    static let wingHinge = Vec2(-127, 52)
    static let wingTopLobe = FaceCircle(center: Vec2(-160, 2), radius: 18)

    /// The face's extent at rest, including the halo glow.
    static let layoutBoxMin = Vec2(-178, -150)
    static let layoutBoxMax = Vec2(178, 72)

    /// The squished angel's pivot: the halo top, pinned at the ceiling.
    static let squishPivot = Vec2(0, -141)
}

/// The devil's face.
enum DevilGeometry {
    // Eyes: cream sclera, a big dark pupil with a small white dot, under a heavy upper-lid line.
    static let eyeCenter = Vec2(69.5, 0)
    static let eyeSize = Vec2(50, 54)
    /// The cream highlight, at the same offset in both eyes: the light comes from screen right.
    static let highlightSize = Vec2(14, 20)
    static let highlightOffset = Vec2(10, -6)
    /// The highlight dot on a pupil, as a fraction of the pupil's radius.
    static let highlightDot = 0.42
    /// How far `EyeParams.inward` moves a pupil toward the nose and up, as fractions of its
    /// travel: his scheming look.
    static let pupilInward = Vec2(0.8, 0.6)
    /// The heavy upper-lid line along the visible eye's top, at full `lidInk`, and the sclera's
    /// outline it thickens.
    static let lidLine = 7.0
    static let scleraOutline = 4.5

    // Brows: a thick filled taper with round caps, angled down to the nose.
    static let browOuter = Vec2(97.7, -34)
    static let browOuterThickness = 9.5
    static let browInner = Vec2(41.8, -13.9)
    static let browInnerThickness = 4.5
    /// The chord's angle with the inner end down (degrees).
    static let browBaseAngle = 20.0
    static let browArch = 2.0

    // Mouth (the grin): the anchor sits on the midline at the corner line's height; the neutral
    // grin is shifted `neutralShiftX` right, so its corners land at (−34, +40) and (+40, +25)
    // and its bottom at +62.5.
    static let mouthAnchor = Vec2(0, 32.5)
    static let neutralShiftX = 3.0
    static let mouthWidth = 74.0
    static let mouthSkew = 7.5
    static let mouthDepth = 30.0
    static let mouthLeftCorner = Vec2(-34, 40)
    static let mouthRightCorner = Vec2(40, 25)

    // Every mouth is one ink shape about the open grin's size, with a coral tongue resting on its
    // bottom and a white fang.
    /// The closed smile's width and thickness.
    static let mouthClosedWidth = 52.0
    static let mouthLine = 4.0
    /// The ink edge that rounds the shape's corners, centred on its outline.
    static let mouthEdge = 3.2
    /// The deepest speaking opening.
    static let mouthTalkDepth = 34.0
    /// When the bowl grows in (by the opening's depth).
    static let bowlGrowth = (from: 5.0, to: 13.0)
    /// The tongue's tallest dome, and when it grows in (by the opening's depth; rounded lips
    /// count as deeper, so a U shows its coral).
    static let tongueMaxHeight = 14.0
    static let tongueGrowth = (from: 12.0, to: 20.0)

    // Fang: a white triangle hanging from the top edge near the right corner, the same size in
    // every mouth.
    static let fangBaseFactor = 0.127
    static let fangHeight = 13.0
    static let fangX = 0.62
    /// Under a closed or smirking line the fang hangs this far below it.
    static let fangBelowLine = 9.0
    /// In an open mouth the fang starts this far below the top edge, under the lip's ink.
    static let fangInset = 1.0
    /// The fang's bold ink outline: about as heavy as the closed line (`mouthLine`), half of
    /// `fangEdge` of it inside the white and the rest outside, where it joins the mouth's ink.
    /// In an open mouth only the inner part shows.
    static let fangOutline = 3.6
    static let fangEdge = 1.4

    // Horns (screen left), a smooth crescent: the convex back sweeps out past the outer base to
    // its widest point, `hornBulge`, and up to a rounded tip, the concave inner edge curves back
    // down to the inner base, and the straight base, with rounded corners, rises toward the face
    // about 37°. Hinged at the base midpoint, (−118.75, −59.5).
    static let hornTip = Vec2(-116, -117)
    static let hornOuterBase = Vec2(-135.5, -47.1)
    static let hornInnerBase = Vec2(-102, -71.9)
    static var hornHinge: Vec2 { Vec2.lerp(hornOuterBase, hornInnerBase, 0.5) }
    /// The back's widest point, where it runs straight up: 12 fu outside the outer base, a
    /// little below half height.
    static let hornBulge = Vec2(-147.5, -80)
    /// The radius the base's corners are rounded to.
    static let hornCornerRadius = 1.6
    /// How far the squished devil's horns are pressed down at full squeeze (fu), so they poke
    /// out beside the seam rather than under it.
    static let hornPress = 26.0
    /// The glossy shine along the back: over `hornShineSpan` of its length (from the base), an
    /// even band `hornShineBand` inside the edge, leaving a dark rim along it, whose light eases
    /// out over `hornShineFalloff` on either side and which narrows and fades toward both ends
    /// of the span.
    static let hornShineSpan = 0.32...0.9
    static let hornShineBand = 3.2...7.0
    static let hornShineFalloff = (outer: 1.3, inner: 2.6)

    // Blush: soft red-orange ovals under the eyes, just redder than his skin.
    static let blush = FaceEllipse(center: Vec2(88, 42), size: Vec2(38, 24))

    /// The yellow motion dashes beside his head.
    static let motionMarks = [FaceCapsule(center: Vec2(147, -33), length: 30, thickness: 9.5, angle: 40),
                              FaceCapsule(center: Vec2(157, -4), length: 30, thickness: 9.5, angle: 6)]
    /// The anger vein (💢) at the screen-right temple: four thick bent strokes, each corner
    /// turned toward its centre, `radius` from it.
    static let angerVein = FaceCircle(center: Vec2(152, 2), radius: 13)
    static let angerVeinStroke = 5.0
    /// Seconds per throb of the anger vein.
    static let angerVeinPeriod = 1.6

    /// How much wider (x) and taller (y) his blush grows with his cheeks fully puffed, and how
    /// much stronger it gets: squished, the volume the squash leaves over goes into his cheeks.
    static let blushPuff = Vec2(0.4, 0.12)
    static let blushPuffStrength = 0.6

    /// The face's extent at rest, including the motion marks.
    static let layoutBoxMin = Vec2(-172, -120)
    static let layoutBoxMax = Vec2(172, 66)

    /// The squished devil's pivot: the floor contact under his chin.
    static let squishPivot = Vec2(0, 90)
}

/// The stage's three key poses in band fractions (0 at the band's top, 1 at its bottom): at
/// rest, the angel speaking (her floor bulges down into the devil's half) and the devil speaking
/// (a wave travels along the seam). The presets and the layout are built from them, and the
/// fidelity checks hold the settled rig to them.
enum KeyPoses {
    /// Where `angelFloorSeam` is sampled: u across the centred stage window.
    static let seamU = [0, 0.094, 0.219, 0.344, 0.5, 0.656, 0.781, 0.906, 1]

    /// A face in a key pose.
    struct Face: Sendable {
        /// The eye line's band fraction.
        var eyeLine: Double
        /// The face's size relative to its neutral size, across (x) and down (y).
        var scale: Vec2
        /// The settled vertical squash `sy`: 1 for a free face, the contact pressure for a
        /// squished listener. It can differ from `scale.y`.
        var squashTarget: Double
    }

    // At rest: a level seam.
    static let neutralSeam = 0.507
    static let neutralAngel = Face(eyeLine: 0.330, scale: Vec2(1, 1), squashTarget: 1)
    static let neutralDevil = Face(eyeLine: 0.747, scale: Vec2(1, 1), squashTarget: 1)

    // The angel speaks: the seam bulges down, symmetric about the middle.
    static let angelFloorSeam = [0.625, 0.660, 0.692, 0.712, 0.722, 0.712, 0.692, 0.660, 0.625]
    static let angelFloorAngel = Face(eyeLine: 0.426, scale: Vec2(1.16, 1.16), squashTarget: 1)
    /// The squished devil keeps his width and is squashed to 0.78.
    static let angelFloorDevil = Face(eyeLine: 0.778, scale: Vec2(1.0, 0.78), squashTarget: 0.78)
    /// The floor the squished devil is pinned to.
    static let angelFloorFloor = 0.895
    /// The bulge fitted to `angelFloorSeam`: base + bulge·(4u(1−u))^exponent.
    static let angelFloorBase = 0.625
    static let angelFloorBulge = 0.097
    static let bulgeExponent = 0.95

    // The devil speaks: a travelling wave.
    static let devilFloorMean = 0.387
    static let devilFloorAmplitude = 0.0225
    static let waveLength = 0.66
    /// The wave's resting phase φ: its highest point (smallest y) falls at u = 0.25.
    static let restPhase = 0.6288
    static let devilFloorHighest = (u: 0.25, v: 0.365)
    static let devilFloorLowest = (u: 0.6, v: 0.41)
    /// The squished angel: 0.95 of her size overall, her squash settled at 0.92.
    static let devilFloorAngel = Face(eyeLine: 0.257, scale: Vec2(0.95, 0.95), squashTarget: 0.92)
    /// The ceiling the squished angel's halo top is pinned to.
    static let devilFloorHaloTop = 0.031
    static let devilFloorDevil = Face(eyeLine: 0.661, scale: Vec2(1.10, 1.10), squashTarget: 1)
    /// Where the speaking devil's horn tips reach.
    static let devilFloorHornTips = 0.43...0.45

    /// The bulge profile P(u) = (4u(1−u))^0.95, nearly a parabola.
    static func bulge(_ u: Double) -> Double {
        pow(max(0, 4 * u * (1 - u)), bulgeExponent)
    }

    /// The unit wave sin(2π(u/λ − φ)); negative values raise the seam.
    static func wave(_ u: Double, phase: Double = restPhase) -> Double {
        sin(2 * Double.pi * (u / waveLength - phase))
    }
}

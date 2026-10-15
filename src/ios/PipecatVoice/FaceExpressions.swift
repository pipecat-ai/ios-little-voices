import Foundation

/// The held expressions. Each is a set of overrides of the character's neutral face.
enum FaceExpression: String, CaseIterable, Sendable {
    case neutral
    case resting
    case listening
    case attentive
    case thinking
    case talking
    case laughing
    case squished
    case squishedAddressed
    case happy
    case content
    case wink
    case starry
    case sideEye
    case grumpy
    case determined
    case surprised
    case sleepy
}

/// A speaker's flavour on top of `talking`, held for the sentence.
enum TalkingMood: String, CaseIterable, Sendable {
    case none
    /// A `!` cue.
    case excited
    /// A `?` cue.
    case asking
    /// A laugh cue: `laughing` replaces `talking`, and lip sync keeps the mouth's floor.
    case laughing
    /// A pause of 0.6 s or more while holding the floor.
    case waiting
}

/// The physical reactions a face plays: kicks to its springs, and for some a short override of
/// its features. The director's gestures are `StageGesture`.
enum FaceReaction: String, CaseIterable, Sendable {
    /// The squished devil hit by the seam: chevron eyes for 140 ms, puff and horn kicks.
    case oof
    /// The squished angel hit by the seam: wide eyes and an "o" for 0.35 s, halo and wing kicks.
    case eep
    case startle
    case popUp
    /// Popping in at the launch intro: the halo bobs up and the wings flutter, or the horns
    /// stretch and splay; the marks pulse.
    case popIn
    case nod
    case shocked
    case huff
    case laughAlong
    case eyeRoll
}

/// The expression table: every expression's targets for each character.
enum ExpressionLibrary {
    /// The character's neutral face.
    static func neutral(_ c: DuoCharacter) -> FaceTargets {
        var f = FaceTargets()
        if c == .angel {
            f.eyes = PerSide(EyeParams(open: 1, size: 1, sclera: 0, highlight: 1, sparkle: 1))
            f.mouth = MouthParams(width: AngelGeometry.mouthWidth, open: AngelGeometry.mouthDepth, corner: 2, tongue: 1,
                                  line: AngelGeometry.mouthLine)
            f.accessories = AccessoryParams(blush: 1, dashes: 1, haloGlow: 1, wingSpread: 14)
        } else {
            // His mischievous default: cream eyes under heavy lids with the pupils toward the upper
            // inner side, brows angled down to the nose, the open grin with its fang and tongue,
            // coral-pink blush and the yellow motion dashes.
            f.eyes = PerSide(EyeParams(sclera: 1, iris: 0.62, inward: 0.6, highlight: 1, lidTop: 0.10, lidAngle: 20,
                                       lidInk: 1))
            f.mouth = DevilMouths.openLarge
            f.accessories = AccessoryParams(blush: 1, motion: 1, haloGlow: 0)
        }
        return f
    }

    /// An expression's targets; `mood` applies on top of `talking`.
    static func targets(_ expression: FaceExpression, for c: DuoCharacter, mood: TalkingMood = .none) -> FaceTargets {
        if expression == .talking, mood == .laughing { return targets(.laughing, for: c) }
        var f = neutral(c)
        if c == .angel { angel(expression, &f) } else { devil(expression, &f) }
        if expression == .talking { apply(mood, for: c, to: &f) }
        return f
    }

    /// The gaze an expression fixes, overriding the director's gaze home; nil keeps the home.
    static func gaze(_ expression: FaceExpression, for c: DuoCharacter) -> Vec2? {
        switch (c, expression) {
        case (.angel, .sideEye): Vec2(0.85, 0.1)
        case (.devil, .sideEye): Vec2(0.85, 0.15)
        case (.devil, .content): Vec2(0.6, 0.1)
        case (.devil, .sleepy): Vec2(0.5, 0.5)
        // Fixed on the other, across the seam: the angel down, the devil up.
        case (.angel, .determined): Vec2(0.05, 0.9)
        case (.devil, .determined): Vec2(0.1, -0.9)
        default: nil
        }
    }

    /// Whether the eyes are closed in this expression, so blinks are suppressed.
    static func eyesClosed(_ expression: FaceExpression, for c: DuoCharacter) -> Bool {
        switch expression {
        case .laughing, .sleepy, .happy: true
        case .content: c == .angel
        default: false
        }
    }

    // MARK: Angel

    private static func angel(_ e: FaceExpression, _ f: inout FaceTargets) {
        switch e {
        case .neutral:
            break
        case .resting:
            f.eyes.left.sparkle = 0; f.eyes.right.sparkle = 0
            f.eyes.left.highlight2 = 1; f.eyes.right.highlight2 = 1
            f.mouth = MouthParams(width: AngelGeometry.mouthClosedWidth, open: 0, corner: 7, line: AngelGeometry.mouthLine)
            f.accessories.dashes = 0.35
            f.accessories.blush = 0.85
        case .listening:
            eyes(&f) { $0.open = 1.06; $0.size = 1.04; $0.sparkle = 1 }
            brows(&f) { $0.dy = -3 }
            f.mouth = MouthParams(width: 46, open: 0, corner: 8, line: AngelGeometry.mouthLine)
            f.accessories.tilt = 4
        case .attentive, .starry:
            eyes(&f) { $0.starry = 1; $0.open = 1.08; $0.size = 1.05; $0.highlight = 0; $0.sparkle = 0 }
            brows(&f) { $0.dy = -8 }
            f.mouth = e == .attentive ? MouthParams(width: 20, open: 26, round: 1, tongue: 1, line: AngelGeometry.mouthLine)
                : MouthParams(width: 16, open: 20, round: 1, tongue: 1, line: AngelGeometry.mouthLine)
            f.accessories.dashes = 0
            f.accessories.sparkles = 1
            if e == .attentive { f.accessories.scaleBias = 1.05 }
        case .thinking:
            eyes(&f) { $0.sclera = 1; $0.iris = 0.6; $0.open = 1.05 }
            f.brows.right.dy = -6
            f.mouth = MouthParams(width: 14, open: 14, round: 1, tongue: 1, shiftX: 4, line: AngelGeometry.mouthLine)
            f.accessories.tilt = 5
            f.accessories.dashes = 0.4
        case .talking:
            eyes(&f) { $0.open = 1.08; $0.sparkle = 1 }
            brows(&f) { $0.dy = -4; $0.arch = 1.2 }
            // Lip sync opens the mouth with her voice; before it, between words and while she
            // waits, it rests on the closed smile it starts from, the corner keeping it smiling.
            f.mouth = MouthParams(width: AngelGeometry.mouthClosedWidth, open: 0, corner: 5, tongue: 1,
                                  line: AngelGeometry.mouthLine)
            f.accessories.blush = 1
            f.accessories.dashes = 1
            // At speaker scale the wings fold in a little, so they stay on screen.
            f.accessories.wingSpread = -4
        case .laughing:
            eyes(&f) { $0.closed = 1; $0.arcUp = 1 }
            brows(&f) { $0.dy = -8 }
            f.mouth = MouthParams(width: 60, open: 34, corner: 6, tongue: 1, line: AngelGeometry.mouthLine)
            f.accessories.dashes = 0
            f.accessories.sparkles = 1
        case .squished, .squishedAddressed:
            eyes(&f) { $0.sclera = 1; $0.iris = 0.55; $0.open = 1.12 }
            f.brows.right.angle = 8; f.brows.right.arch = 0.2; f.brows.right.dy = 2
            f.mouth = MouthParams(width: 16, open: 20, round: 1, tongue: 1, line: AngelGeometry.mouthLine)
            f.accessories.blush = 0.8
            f.accessories.dashes = 0.8
            if e == .squishedAddressed { brows(&f) { $0.dy -= 4 } }
        case .happy:
            eyes(&f) { $0.closed = 1; $0.arcUp = 1 }
            brows(&f) { $0.dy = -6 }
            f.mouth = MouthParams(width: 50, open: 28, corner: 6, tongue: 1, line: AngelGeometry.mouthLine)
            f.accessories.dashes = 0
            f.accessories.sparkles = 1
        case .content:
            eyes(&f) { $0.closed = 1; $0.arcUp = 1 }
            f.mouth = MouthParams(width: 44, open: 0, corner: 9, line: AngelGeometry.mouthLine)
            f.accessories.dashes = 0
            f.accessories.puffs = 0.7
            f.accessories.blush = 0.9
        case .wink:
            // A soft arc, mostly: the sharp chevron is the devil's wink.
            f.eyes.right.closed = 1; f.eyes.right.chevron = 0.25; f.eyes.right.arcUp = 0.75
            f.eyes.left.open = 1.05
            f.brows.right.dy = 3
            f.mouth = MouthParams(width: 46, open: 22, corner: 6, tongue: 1, line: AngelGeometry.mouthLine)
            f.accessories.tilt = 6
        case .sideEye:
            eyes(&f) { $0.sclera = 1 }
            brows(&f) { $0.angle = -8 }
            f.mouth = MouthParams(width: 44, open: 10, corner: -11, line: AngelGeometry.mouthLine)
        case .grumpy:
            brows(&f) { $0.angle = -10; $0.dy = 2 }
            f.mouth = MouthParams(width: 38, open: 0, corner: -8, line: AngelGeometry.mouthLine)
            f.accessories.blush = 1
            f.accessories.blushSize = 1.15
        case .determined:
            // Pushing: white eyes narrowed under brows hard down to the nose, a firm, effortful
            // mouth, flushed cheeks and the head leaning into it. Her eyes have no lids, so they
            // narrow by their height.
            eyes(&f) { $0.sclera = 1; $0.iris = 0.6; $0.open = 0.82; $0.sparkle = 0 }
            // Her resting brows rise toward the middle, so it takes a steep turn to bring their
            // inner ends down.
            brows(&f) { $0.angle = 38; $0.dy = 5; $0.arch = 0.3 }
            f.mouth = MouthParams(width: 34, open: 8, corner: -4, line: AngelGeometry.mouthLine)
            f.accessories.blush = 1
            f.accessories.blushSize = 1.2
            f.accessories.dashes = 0
            f.accessories.headDy = 6
        case .surprised:
            eyes(&f) { $0.sclera = 1; $0.iris = 0.5; $0.open = 1.2; $0.size = 1.08 }
            brows(&f) { $0.dy = -8 }
            f.mouth = MouthParams(width: 25, open: 40, round: 1, tongue: 1, line: AngelGeometry.mouthLine)
        case .sleepy:
            eyes(&f) { $0.closed = 1; $0.arcUp = 0; $0.arcDown = 1 }
            brows(&f) { $0.dy = 3; $0.angle = 6 }
            f.mouth = MouthParams(width: 36, open: 0, corner: 6, line: AngelGeometry.mouthLine)
            f.accessories.dashes = 0
            f.accessories.puffs = 0.6
            f.accessories.haloGlow = 0.6
            f.accessories.wingSpread = 4
        }
    }

    // MARK: Devil

    /// The devil's expressions: every open eye is cream with a big dark pupil under a heavy
    /// upper-lid line (`lidInk` 1, from `neutral`), and every mouth is one of `DevilMouths`.
    private static func devil(_ e: FaceExpression, _ f: inout FaceTargets) {
        switch e {
        case .neutral:
            break
        case .resting:
            // Neutral eyes: slightly lidded, pupils forward; the closed smile.
            eyes(&f) { $0.inward = 0; $0.lidTop = 0.24; $0.lidAngle = 8 }
            brows(&f) { $0.dy = 3; $0.angle = -6 }
            f.mouth = DevilMouths.closed
            f.accessories.blush = 0.8
            f.accessories.motion = 0
        case .listening:
            eyes(&f) { $0.inward = 0.3; $0.lidTop = 0.2; $0.lidAngle = 12 }
            f.brows.right.dy = -8; f.brows.right.angle = -6
            f.mouth = DevilMouths.openSmall
            f.accessories.motion = 0
        case .attentive, .starry:
            // Excited: wide eyes, a second highlight in each pupil, brows up.
            let big = e == .starry
            eyes(&f) {
                $0.open = big ? 1.12 : 1.08; $0.size = big ? 1.06 : 1.04; $0.inward = 0.2; $0.lidTop = 0.02
                $0.lidAngle = 0; $0.highlight2 = 1
            }
            brows(&f) { $0.dy = big ? -8 : -6; $0.angle = big ? -10 : -8 }
            f.mouth = big ? DevilMouths.openLarge : DevilMouths.openMedium
            f.accessories.motion = big ? 1.2 : 0.6
            f.accessories.hornSplay = -5
            if !big { f.accessories.scaleBias = 1.05 }
        case .thinking:
            // Curious: one eye bigger under a raised brow, the other narrowed; a sideways smirk.
            eyes(&f) { $0.inward = 0 }
            f.eyes.right.size = 1.12; f.eyes.right.open = 1.06; f.eyes.right.lidTop = 0.04; f.eyes.right.lidAngle = 0
            f.eyes.left.lidTop = 0.36; f.eyes.left.lidAngle = 10
            f.brows.right.dy = -9; f.brows.right.angle = -12
            f.brows.left.dy = 3; f.brows.left.angle = 6
            f.mouth = DevilMouths.smirkLeft
            f.accessories.motion = 0.3
        case .talking:
            // The lids cut the eye tops and the brows sit on them: cheeky, scheming.
            eyes(&f) { $0.inward = 0.45; $0.lidTop = 0.24; $0.lidAngle = 20 }
            brows(&f) { $0.dy = 7 }
            f.mouth = DevilMouths.talking
        case .laughing:
            // Happy eyes (closed ∩ arcs) over his biggest grin.
            eyes(&f) { $0.closed = 1; $0.arcUp = 1 }
            brows(&f) { $0.dy = -4; $0.angle = -6 }
            f.mouth = DevilMouths.laughing
        case .squished:
            // Annoyed, pressed under the angel: lowered lids, one brow cocked, a frown.
            eyes(&f) { $0.open = 1.1; $0.inward = 0; $0.lidTop = 0.3; $0.lidAngle = -6; $0.lowerLid = 0.04 }
            f.brows.left.angle = -14; f.brows.left.dy = -4; f.brows.left.arch = 2.5
            f.brows.right.angle = 2; f.brows.right.dy = 0
            // The cocked right brow's lid follows it, so no eye white shows above the brow.
            f.eyes.right.lidAngle = 28; f.eyes.right.lidTop = 0.32
            f.mouth = DevilMouths.sad(width: 38, corner: -6)
            f.accessories.annoyed = 0.8
            f.accessories.blush = 0.6
            f.accessories.motion = 0
        case .squishedAddressed:
            // Angry: brows hard down to the nose, narrowed eyes, a grimace.
            eyes(&f) { $0.iris = 0.55; $0.inward = 0.5; $0.lidTop = 0.3; $0.lidAngle = 26; $0.lowerLid = 0.1 }
            brows(&f) { $0.angle = 14; $0.dy = 4 }
            f.mouth = DevilMouths.grimace
            f.accessories.annoyed = 1
            f.accessories.blush = 0.6
            f.accessories.motion = 0
        case .happy:
            eyes(&f) { $0.closed = 1; $0.arcUp = 1 }
            brows(&f) { $0.dy = -4; $0.angle = -4 }
            f.mouth = DevilMouths.grin(width: 76, depth: 30, tongue: 1, skew: 4, corner: 4)
        case .content:
            // Smug: flat half-lids looking aside, a smirk.
            eyes(&f) { $0.inward = 0; $0.lidTop = 0.45; $0.lidAngle = 3 }
            brows(&f) { $0.dy = 3; $0.angle = -4 }
            f.mouth = DevilMouths.smirkRight
            f.accessories.blush = 0.9
            f.accessories.motion = 0
            f.accessories.headDy = -3
        case .wink:
            // Wink right: a closed ∩ arc over a smirk rising to that side.
            f.eyes.right.closed = 1; f.eyes.right.arcUp = 1
            f.eyes.left.inward = 0.3
            f.brows.left.dy = -6; f.brows.left.angle = -5
            f.brows.right.dy = 3
            f.mouth = DevilMouths.smirkRight
            f.accessories.tilt = -5
        case .sideEye:
            // Looking aside under heavy, flat lids.
            eyes(&f) { $0.iris = 0.58; $0.inward = 0; $0.lidTop = 0.42; $0.lidAngle = 0 }
            brows(&f) { $0.dy = 3; $0.angle = -6 }
            f.mouth = DevilMouths.smirkLeft
            f.accessories.motion = 0
        case .determined:
            // Pushing: narrowed eyes under brows hard down to the nose, a gritted line with the
            // fang, the motion dashes flaring and the head leaning into it.
            eyes(&f) { $0.iris = 0.55; $0.inward = 0.2; $0.lidTop = 0.3; $0.lidAngle = 24; $0.lowerLid = 0.08 }
            brows(&f) { $0.angle = 15; $0.dy = 4 }
            f.mouth = DevilMouths.grimace
            f.accessories.motion = 1.3
            f.accessories.headDy = -6
        case .grumpy:
            // Angry, with the anger vein: brows hard down to the nose, narrowed eyes, a frown.
            eyes(&f) { $0.iris = 0.55; $0.inward = 0.5; $0.lidTop = 0.32; $0.lidAngle = 28; $0.lowerLid = 0.12 }
            brows(&f) { $0.angle = 16; $0.dy = 3 }
            f.mouth = DevilMouths.sad(width: 40, corner: -7)
            f.accessories.annoyed = 1
            f.accessories.motion = 0
        case .surprised:
            // Round wide eyes with small pupils, brows up, the small round O.
            eyes(&f) { $0.iris = 0.42; $0.open = 1.15; $0.size = 1.06; $0.inward = 0; $0.lidTop = 0; $0.lidAngle = 0 }
            brows(&f) { $0.angle = -12; $0.dy = -8 }
            f.mouth = DevilMouths.o
            f.accessories.motion = 0
        case .sleepy:
            // Closed curves, a small smile with the fang.
            eyes(&f) { $0.closed = 1; $0.arcUp = 0; $0.arcDown = 1 }
            brows(&f) { $0.dy = 4; $0.angle = -6 }
            f.mouth = DevilMouths.line(width: 30, corner: 3, skew: 3, fang: 0.8)
            f.accessories.blush = 0.7
            f.accessories.motion = 0
        }
    }

    // MARK: Moods

    private static func apply(_ mood: TalkingMood, for c: DuoCharacter, to f: inout FaceTargets) {
        switch mood {
        case .none, .laughing:
            break
        case .excited:
            if c == .angel {
                eyes(&f) { $0.starry = 0.6; $0.size = 1.12 }
                brows(&f) { $0.dy = -7 }
                f.accessories.dashes = 1.35
            } else {
                eyes(&f) { $0.open += 0.06; $0.highlight2 = 1 }
                brows(&f) { $0.angle += 6 }
                f.accessories.motion = 1.3
            }
        case .asking:
            f.accessories.tilt = c == .angel ? -8 : 8
            f.brows.right.dy = -8
            eyes(&f) { $0.open = 1.1 }
        case .waiting:
            brows(&f) { $0.dy -= 2 }
        }
    }

    private static func eyes(_ f: inout FaceTargets, _ change: (inout EyeParams) -> Void) {
        change(&f.eyes.left)
        change(&f.eyes.right)
    }

    private static func brows(_ f: inout FaceTargets, _ change: (inout BrowParams) -> Void) {
        change(&f.brows.left)
        change(&f.brows.right)
    }
}

/// One face in a still: an expression with the overrides a gallery cell needs.
struct FaceStill: Equatable, Sendable {
    var expression: FaceExpression
    var mood = TalkingMood.none
    /// Speaking at this normalised openness.
    var talkOpen: Double?
    var gaze: Vec2?
    /// A mouth depth that replaces the expression's.
    var mouthOpen: Double?

    /// The targets with the overrides applied.
    func targets(for c: DuoCharacter) -> FaceTargets {
        var f = ExpressionLibrary.targets(expression, for: c, mood: mood)
        if let mouthOpen { f.mouth.open = mouthOpen }
        return f
    }
}

/// A cell of the 4 × 3 expression gallery (`--expression-gallery`), named `rNcM`.
struct GalleryCell: Equatable, Sendable {
    var row: Int
    var column: Int
    var angel: FaceStill
    var devil: FaceStill

    subscript(_ c: DuoCharacter) -> FaceStill { c == .angel ? angel : devil }

    var name: String { "r\(row)c\(column)" }

    static let all: [GalleryCell] = [
        GalleryCell(row: 1, column: 1, angel: FaceStill(expression: .talking, talkOpen: 0.75),
                    devil: FaceStill(expression: .neutral)),
        GalleryCell(row: 1, column: 2, angel: FaceStill(expression: .happy), devil: FaceStill(expression: .sideEye)),
        GalleryCell(row: 1, column: 3, angel: FaceStill(expression: .starry), devil: FaceStill(expression: .thinking)),
        GalleryCell(row: 1, column: 4, angel: FaceStill(expression: .wink), devil: FaceStill(expression: .wink)),
        GalleryCell(row: 2, column: 1, angel: FaceStill(expression: .content), devil: FaceStill(expression: .grumpy)),
        GalleryCell(row: 2, column: 2, angel: FaceStill(expression: .thinking, gaze: Vec2(0.5, -0.5)),
                    devil: FaceStill(expression: .listening)),
        GalleryCell(row: 2, column: 3, angel: FaceStill(expression: .laughing, mouthOpen: 22),
                    devil: FaceStill(expression: .laughing)),
        GalleryCell(row: 2, column: 4, angel: FaceStill(expression: .resting), devil: FaceStill(expression: .resting)),
        GalleryCell(row: 3, column: 1, angel: FaceStill(expression: .sleepy), devil: FaceStill(expression: .sleepy)),
        GalleryCell(row: 3, column: 2, angel: FaceStill(expression: .wink, mouthOpen: 22),
                    devil: FaceStill(expression: .surprised)),
        GalleryCell(row: 3, column: 3, angel: FaceStill(expression: .starry), devil: FaceStill(expression: .happy)),
        GalleryCell(row: 3, column: 4, angel: FaceStill(expression: .happy), devil: FaceStill(expression: .content)),
    ]

    /// The cell named `rNcM`.
    static func named(_ name: String) -> GalleryCell? { all.first { $0.name == name.lowercased() } }
}

/// The devil's mouth states, all about the open grin's size: ink with the white fang near the
/// right side of the top edge and, once open, a coral tongue.
enum DevilMouths {
    /// A closed mouth: a line `width` wide, its corners lifted by `corner` and the right one
    /// raised by `skew`, with the fang hanging under the raised end.
    static func line(width: Double, corner: Double, skew: Double = 0, fang: Double = 1) -> MouthParams {
        MouthParams(width: width, open: 0, corner: corner, skew: skew, fang: fang, fangX: skew < 0 ? -0.55 : 0.55,
                    line: DevilGeometry.mouthLine)
    }

    /// An open D `depth` deep with the fang near its right corner.
    static func grin(width: Double, depth: Double, tongue: Double, skew: Double, corner: Double,
                     fangX: Double = 0.6) -> MouthParams {
        MouthParams(width: width, open: depth, corner: corner, skew: skew, tongue: tongue, fang: 1, fangX: fangX,
                    line: DevilGeometry.mouthLine)
    }

    /// A frown arc, no fang.
    static func sad(width: Double, corner: Double) -> MouthParams {
        MouthParams(width: width, open: 0, corner: corner, line: DevilGeometry.mouthLine)
    }

    static let closed = line(width: DevilGeometry.mouthClosedWidth, corner: 6, skew: 1)
    static let smirkLeft = line(width: 46, corner: 2, skew: -7)
    static let smirkRight = line(width: 46, corner: 2, skew: 7)
    static let openSmall = grin(width: 50, depth: 14, tongue: 0, skew: 3, corner: 2)
    static let openMedium = grin(width: 62, depth: 22, tongue: 0.6, skew: 4, corner: 2)
    /// The neutral grin: corners at (−34, +40) and (+40, +25), bottom at +62.5.
    static let openLarge = MouthParams(width: DevilGeometry.mouthWidth, open: DevilGeometry.mouthDepth,
                                       skew: DevilGeometry.mouthSkew, tongue: 1, fang: 1, fangX: DevilGeometry.fangX,
                                       shiftX: DevilGeometry.neutralShiftX, line: DevilGeometry.mouthLine)
    /// The talking mouth at rest: the closed smile, its right end raised over the fang, that lip
    /// sync opens per viseme. It shows before his voice, between words and while he waits.
    static let talking = MouthParams(width: DevilGeometry.mouthClosedWidth, open: 0, corner: 3, skew: 4, tongue: 1,
                                     fang: 1, fangX: 0.55, line: DevilGeometry.mouthLine)
    static let laughing = grin(width: 80, depth: 38, tongue: 1, skew: 2, corner: 4, fangX: 0.5)
    /// A long slanted line with the fang.
    static let grimace = line(width: 64, corner: -2, skew: 8)
    /// The small round O with a coral inside.
    static let o = MouthParams(width: 28, open: 28, round: 1, tongue: 1, line: DevilGeometry.mouthLine)
}

/// One state on a mouth sheet.
struct MouthSheetState: Sendable {
    let name: String
    let mouth: MouthParams
}

/// The angel's mouth states for `--mouth-sheet`: as her expressions hold the mouth, and as lip
/// sync shapes it for each viseme.
enum AngelMouthSheet {
    typealias State = MouthSheetState

    /// Representative lip-sync poses, one per viseme.
    static let visemes: [(name: String, drive: MouthDrive)] = [
        ("Talking A", MouthDrive(openness: 0.82, width: 0.55, rounding: 0.1)),
        ("Talking E", MouthDrive(openness: 0.62, width: 1, rounding: 0)),
        ("Talking O", MouthDrive(openness: 0.8, width: 0.25, rounding: 1)),
        ("Talking U", MouthDrive(openness: 0.46, width: 0.1, rounding: 0.95)),
        ("Talking M/B", MouthDrive(openness: 0.3, width: 0.45, rounding: 0.1)),
    ]

    static var states: [State] {
        func held(_ name: String, _ e: FaceExpression) -> State {
            State(name: name, mouth: ExpressionLibrary.targets(e, for: .angel).mouth)
        }
        let talking = ExpressionLibrary.targets(.talking, for: .angel).mouth
        let spoken = visemes.map {
            State(name: $0.name, mouth: LipSyncMapping.map(talking, drive: $0.drive, talk: 1, character: .angel))
        }
        return [held("Closed", .resting), held("Smile (small)", .listening), held("Smile (open)", .neutral)]
            + spoken + [held("Laughing", .laughing), held("Surprised", .surprised), held("Concerned", .sideEye),
                        held("Sad", .grumpy)]
    }
}

/// The devil's mouth states for `--mouth-sheet`: as his expressions hold the mouth, and as lip
/// sync shapes it for each viseme.
enum DevilMouthSheet {
    typealias State = MouthSheetState

    /// Representative lip-sync poses, one per viseme.
    static let visemes: [(name: String, drive: MouthDrive)] = [
        ("Talking A", MouthDrive(openness: 0.6, width: 0.55, rounding: 0.1)),
        ("Talking E", MouthDrive(openness: 0.62, width: 1, rounding: 0)),
        ("Talking O", MouthDrive(openness: 0.8, width: 0.25, rounding: 1)),
        ("Talking U", MouthDrive(openness: 0.46, width: 0.1, rounding: 0.95)),
        ("Talking", MouthDrive(openness: 0.72, width: 0.5, rounding: 0.1)),
    ]

    static var states: [State] {
        func held(_ name: String, _ e: FaceExpression) -> State {
            State(name: name, mouth: ExpressionLibrary.targets(e, for: .devil).mouth)
        }
        let talking = ExpressionLibrary.targets(.talking, for: .devil).mouth
        let spoken = visemes.map {
            State(name: $0.name, mouth: LipSyncMapping.map(talking, drive: $0.drive, talk: 1, character: .devil))
        }
        return [held("Closed (Neutral)", .resting), held("Smirk (Left)", .sideEye), held("Smirk (Right)", .content),
                held("Open (Small)", .listening), held("Open (Medium)", .attentive), held("Open (Large)", .neutral)]
            + spoken + [held("Laughing", .laughing), held("Grimace", .squishedAddressed), held("Sad", .grumpy)]
    }
}

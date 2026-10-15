import Foundation

/// The halo as drawn: a follower in stage space.
struct HaloPose: Equatable, Sendable {
    /// The ring's centre (stage points).
    var center = Vec2.zero
    /// Radians; positive turns clockwise on screen.
    var rotation = 0.0
    /// Multiplies the ring's vertical radius.
    var squash = 1.0
    /// The glow's strength (1 at rest).
    var glow = 1.0
}

/// How a face is drawn this frame. The head transform is
/// T = translate(anchor)·rotate(tilt)·scale(s·sx, s·sy)·translate(−pivot).
struct FacePose: Equatable, Sendable {
    /// The stage point the pivot sits on.
    var anchor: Vec2
    /// The pivot in face units.
    var pivot: Vec2
    /// Points per face unit.
    var scale: Double
    var sx: Double
    var sy: Double
    /// Radians; positive turns clockwise on screen.
    var tilt: Double
    /// The floor or ceiling a squished face is clipped to.
    var pin: FacePin?
    /// The eyes' blink closure, 0…1.
    var blink: Double
    /// A reopening blink's overshoot: the eyes open up to 4% past rest (1 otherwise).
    var reopen = 1.0
    /// A dozing face's peek: how far one eye opens, 0…0.6.
    var peek: Double
    /// The mouth's normalised openness ô (0 when silent).
    var talkOpen: Double
    var character = DuoCharacter.angel
    /// Every feature's current value; the mouth is the lip-synced one.
    var features = FaceTargets()
    /// The parallax turn (τ, ν) = (0.5·gaze.x, 0.4·gaze.y), sprung.
    var turn = Vec2.zero
    var halo = HaloPose()
    /// Wing angles about their hinges (radians; positive swings the tips away from the face).
    var wings = PerSide(0.0)
    /// Horn angles about their hinges (radians; positive turns the tips outward).
    var horns = PerSide(0.0)
    /// The horns' stretch along their axis (0 at rest).
    var hornStretch = 0.0
    /// The marks' beat pulse: their scale is 1 + pulse.
    var markPulse = 0.0
    /// The anger vein's slow throb, −1…1 (0 under Reduce Motion).
    var veinThrob = 0.0
    /// How far the devil's cheeks puff out, 0…1: squished, the volume his squash leaves over
    /// widens his blush (`BlushShape`); the seam's oof and a huff kick it.
    var puff = 0.0
    /// How hard the face is squeezed, q in 0…1.
    var squeeze = 0.0
    /// How far the seam presses a squished face, 0…1: it eases in with the contact and out as
    /// the face is freed. The devil's horns press down and his lower lids rise with it.
    var press = 0.0
    /// Ambient and laughing motion drawn on top of the rig: a vertical squash offset, a head
    /// bob (fu, + down) and an extra tilt (radians).
    var breath = 0.0
    var bob = 0.0
    var shake = 0.0
    /// The face's own clock: the seconds it has moved, for the starry eyes' turn and twinkle. It
    /// stands still while the stage sleeps, so nothing jumps when it wakes.
    var clock = 0.0
    /// The launch intro's pop, drawn on top of the rig about the pivot.
    var pop = FacePop()

    /// A face-unit point in stage points.
    func point(_ p: Vec2) -> Vec2 {
        anchor + Vec2((p.x - pivot.x) * scale * sx, (p.y - pivot.y) * scale * sy).rotated(by: tilt)
    }

    /// The eye midpoint's y.
    var eyeLine: Double { point(.zero).y }

    /// The pose as drawn: breath, bob, shake and the pop folded into the head transform, the
    /// squash kept within its limits, and the halo popped with the head.
    var drawn: FacePose {
        var p = self
        p.sy = FaceRig.limitSquash(sy * (1 + breath) * pop.squash, character)
        p.sx = pow(p.sy, FaceRig.volumeExponent)
        p.scale = scale * pop.size
        p.anchor = anchor + Vec2(0, bob * p.scale).rotated(by: tilt)
        p.tilt = tilt + shake
        if pop != FacePop() { p.halo.center = pop.place(halo.center, about: anchor, tilt: tilt) }
        return p
    }

    /// The net vertical scale of a part with counter-scale `k`: sy^(1−k).
    func netVertical(_ part: FacePart) -> Double { pow(sy, 1 - part.counterScale(character)) }

    /// Calls `body` with every number that affects the drawing, in a fixed order.
    func forEachValue(_ body: (Double) -> Void) {
        for v in [anchor.x, anchor.y, pivot.x, pivot.y, scale, sx, sy, tilt, blink, reopen, peek, talkOpen, turn.x,
                  turn.y, halo.center.x, halo.center.y, halo.rotation, halo.squash, halo.glow, wings.left, wings.right,
                  horns.left, horns.right, hornStretch, markPulse, veinThrob, puff, squeeze, press, breath, bob, shake,
                  clock, pop.size, pop.squash] {
            body(v)
        }
        for i in FaceTargets.channels.indices { body(features.value(i)) }
        body(features.accessories.scaleBias)
        body(features.accessories.tilt)
        body(features.accessories.headDy)
        switch pin {
        case nil: body(0)
        case .floor(let y): body(1); body(y)
        case .ceiling(let y): body(2); body(y)
        }
        body(character == .angel ? 1 : 2)
    }
}

/// The parts that counter-scale against the head's squash: the eyes, brows and mouth
/// vertically, inside the head's transform; the horns and wings, drawn about their own hinges,
/// on both axes. The halo keeps its own squash.
enum FacePart: Sendable {
    case eyes, brows, mouth, horns, wings

    /// k: the part's local vertical factor is sy^(−k), so its net vertical scale is sy^(1−k); the
    /// horns and wings also keep sx^(1−k) of the head's stretch.
    func counterScale(_ c: DuoCharacter) -> Double {
        switch self {
        case .eyes: c == .angel ? 1 : 0.5
        case .brows: 0.4
        case .mouth: 0.3
        case .horns: 0.7
        case .wings: 0.5
        }
    }
}

/// What the director asks of a face this substep.
struct FaceDirective: Equatable, Sendable {
    var expression = FaceExpression.neutral
    var mood = TalkingMood.none
    /// Where the eyes rest when the expression does not fix them.
    var gaze = Vec2.zero
    /// Lip sync blends in: this character holds the floor and its mouth animates.
    var talking = false
    /// The weight of ambient motion (breath, float, the slow flap), 0…1.
    var ambient = 0.0
    /// The halo bonks off this stage y (band.top − 6).
    var ceiling = -Double.infinity
    /// The stage's left and right edges (stage x): the wings swing out no further than just
    /// inside them.
    var edges = -Double.infinity...Double.infinity
    var reduceMotion = false
    /// A still's fixed face (the gallery), replacing the expression.
    var still: FaceStill?
    /// The director's gesture offsets: brows (fu, + down; degrees), the top lids' and the
    /// sclera's minimums, eye openness, head tilt (degrees) and head offset (fu).
    var browDy = 0.0
    var browAngle = 0.0
    var lidMin = 0.0
    var scleraMin = 0.0
    var eyeOpen = 0.0
    var tilt = 0.0
    var headDy = 0.0

    var effectiveExpression: FaceExpression {
        if let still { return still.expression }
        return expression == .talking && mood == .laughing ? .laughing : expression
    }
}

/// A face's rig: head springs with squash and the volume rule, contact squash, every feature
/// parameter on its own spring, lip sync with no lag, beats, short reactions, and the
/// accessories as lagging followers (halo, wings, horns, marks, cheeks).
struct FaceRig: Sendable {
    /// Volume rule: sx = sy^(−0.4).
    static let volumeExponent = -0.4
    /// Energy is an EMA of ô with a 0.35-s time constant.
    private static let energyGain = 1 - exp(-SpringSpec.step / 0.35)
    /// The lips open with the voice at once but ease shut, and change shape, over 30 ms: quick
    /// enough to meet in a bilabial's 50–100 ms closure, slow enough not to snap within a frame.
    private static let lipGain = 1 - exp(-SpringSpec.step / 0.03)
    private static let degrees = Double.pi / 180
    /// A drive opener than this means the voice has started: a little past the silence rest,
    /// early in the lip-sync timeline's lead-in to the first sound.
    private static let voiceOnset = MouthDrive.rest.openness + 0.02
    /// The gaze's channels are the last two.
    private static let gazeChannels = FaceTargets.channels.count - 2

    let character: DuoCharacter
    private(set) var anchor: RigSpring2
    private(set) var scale: RigSpring
    private(set) var squash: RigSpring
    private(set) var tilt: RigSpring
    private(set) var placement: FacePlacement
    private(set) var pivot: Vec2
    /// Set while a squished listener is pressed by the seam.
    private(set) var contact: StageLayout.Contact?
    /// A free squash target that overrides 1 (a crouch or a launch stretch).
    private(set) var hold: Double?
    /// EMA of ô while speaking.
    private(set) var energy = 0.0
    private(set) var talkOpen = 0.0
    /// How far the anchor's target rides with the live seam (stage points, y).
    var ride = 0.0
    private var beatArmed = false
    private var lastBeat = -Double.infinity
    private var delayedTiltKick: (time: Double, velocity: Double)?

    /// The face's neutral scale s_n: an addressed lean already enlarges the face, so the
    /// expression's scale bias only adds what the lean does not.
    private var neutralScale: Double
    private(set) var directive = FaceDirective()
    /// The feature springs, in `FaceTargets.channels` order.
    private var bank: ContiguousArray<RigSpring>
    private(set) var targets: FaceTargets
    /// The springs' current values.
    private(set) var current: FaceTargets
    /// The lip-synced mouth.
    private(set) var mouth: MouthParams
    /// The drive the mouth shows: the substep's drive, eased (`ease`).
    private var lips: MouthDrive?
    /// The last lips shown: when the voice stops at once (an interruption), the mouth hands back
    /// to the expression from this shape, through τ, rather than snapping to rest first.
    private var lastLips: MouthDrive?
    /// τ: lip sync's weight.
    private(set) var talk: RigSpring
    /// The voice has started since this face began talking: lip sync takes the mouth from then
    /// on. Until then the mouth eases to the talking face's own closed rest on its springs, so
    /// taking the floor never shows an open mouth before the voice.
    private(set) var voiced = false
    private var turn: RigSpring2
    private var haloCenter: RigSpring2
    private var haloRotation: RigSpring
    private var haloSquash: RigSpring
    private var wings: PerSide<RigSpring>
    private var horns: PerSide<RigSpring>
    private var hornStretch: RigSpring
    private var puff: RigSpring
    private var markPulse: RigSpring
    private var browKick: RigSpring
    private var glowPulse: RigSpring
    /// How far the seam presses the face: 1 in contact, 0 once freed.
    private var press: RigSpring
    /// The laugh's bounce (the angel's laugh, the devil's happy chuckle), its shake (the devil's
    /// laugh) and the slow ambient flap fade in and out on these, each on its own, so changing
    /// from one to another never jumps.
    private var laughBounce: RigSpring
    private var laughShake: RigSpring
    private var ambientFlap: RigSpring
    /// How much of a laughing speaker's wide-open floor the mouth shows (`LipSyncMapping`'s
    /// `laughing`), so a laugh opens and closes the mouth rather than snapping it.
    private var laughMouth: RigSpring
    private var flapPhase = 0.0
    private var bonks = 0
    /// The seconds this face has stepped: the clock of its rhythms (breath, float, flap, laugh,
    /// throb, twinkle). It stands still while the stage sleeps, so they resume where they were.
    private var clock = 0.0
    /// A gesture's head shake this substep (radians), drawn on top of the tilt.
    var gestureShake = 0.0
    private var reaction: (gesture: FaceReaction, start: Double, until: Double)?

    init(_ character: DuoCharacter, placement: FacePlacement) {
        self.character = character
        self.placement = placement
        pivot = placement.pivot
        neutralScale = placement.designScale
        anchor = RigSpring2(placement.anchor, spec: .headAnchor, range: 100)
        scale = RigSpring(placement.scale, spec: .headScale, range: 1)
        squash = RigSpring(placement.squash, spec: .freeSquash, range: 0.5)
        tilt = RigSpring(0, spec: .tilt, range: 0.5)
        let neutral = ExpressionLibrary.neutral(character)
        targets = neutral
        current = neutral
        mouth = neutral.mouth
        bank = ContiguousArray(FaceTargets.channels.map { RigSpring(neutral[keyPath: $0.path], spec: $0.spec, range: $0.range) })
        talk = RigSpring(0, spec: .talkWeight)
        turn = RigSpring2(.zero, spec: .parallax)
        haloCenter = RigSpring2(.zero, spec: .haloPosition, range: 100)
        haloRotation = RigSpring(0, spec: .haloRotation)
        haloSquash = RigSpring(1, spec: .haloSquash)
        wings = PerSide(RigSpring(0, spec: .wingAngle))
        horns = PerSide(RigSpring(0, spec: .hornAngle))
        hornStretch = RigSpring(0, spec: .hornStretch)
        puff = RigSpring(0, spec: .cheekPuff)
        markPulse = RigSpring(0, spec: .markPop)
        browKick = RigSpring(0, spec: .brows, range: 20)
        glowPulse = RigSpring(0, spec: .pulse)
        press = RigSpring(0, spec: .press)
        laughBounce = RigSpring(0, spec: .blush)
        laughShake = RigSpring(0, spec: .blush)
        ambientFlap = RigSpring(0, spec: .relax)
        laughMouth = RigSpring(0, spec: .mouthFeature)
        haloCenter.retarget(haloTarget())
        haloCenter.snap()
    }

    // MARK: Commands

    /// Retargets to a new placement. A new pivot moves the anchor to where that pivot is drawn
    /// now (breath, bob and shake included), so the face as drawn does not jump.
    mutating func place(_ placement: FacePlacement, neutralScale: Double? = nil) {
        if let neutralScale { self.neutralScale = neutralScale }
        if placement.pivot != pivot {
            let posed = headPose(), drawn = posed.drawn
            anchor.value = drawn.point(placement.pivot) - (drawn.anchor - posed.anchor)
            pivot = placement.pivot
        }
        self.placement = placement
        anchor.retarget(anchorTarget)
        scale.retarget(scaleTarget)
        if contact == nil { squash.retarget(hold ?? 1) }
    }

    /// Sets what the face shows; the feature springs retarget on the next substep.
    mutating func direct(_ directive: FaceDirective) {
        guard directive != self.directive else { return }
        let wasStill = self.directive.still != nil
        self.directive = directive
        retargetFeatures()
        if wasStill != (directive.still != nil) { scale.retarget(scaleTarget) }
    }

    /// Holds the free squash at `sy` (nil returns to 1).
    mutating func setHold(_ sy: Double?) {
        hold = sy
        if contact == nil {
            squash.use(.freeSquash)
            squash.retarget(sy ?? 1)
        }
    }

    /// The seam starts pressing: the contact spring tracks room/need from now on.
    mutating func beginContact(kick: Double) {
        contact = StageLayout.Contact.of(character)
        hold = nil
        squash.use(.contactSquash)
        squash.kick(kick)
    }

    /// The seam lets go; the free squash returns to 1.
    mutating func endContact(kick: Double) {
        contact = nil
        hold = nil
        squash.use(.freeSquash)
        squash.retarget(1)
        squash.kick(kick)
    }

    mutating func kickSquash(_ velocity: Double) { squash.kick(velocity) }
    mutating func kickAnchor(_ velocity: Vec2) { anchor.kick(velocity) }
    mutating func kickScale(_ velocity: Double) { scale.kick(velocity) }

    /// Kicks the tilt now, or at `time`.
    mutating func kickTilt(_ velocity: Double, at time: Double? = nil) {
        if let time { delayedTiltKick = (time, velocity) } else { tilt.kick(velocity) }
    }

    /// A beat on this face: brows pop, the halo glows, horns stretch, marks pulse.
    mutating func beat(strength: Double) {
        browKick.kick(-40 * strength)
        glowPulse.kick(6 * strength)
        hornStretch.kick(0.6 * strength)
        markPulse.kick(2.5 * strength)
    }

    /// A short reaction: the seam's impact (oof, eep), an interruption (startle) or a gesture.
    mutating func react(_ gesture: FaceReaction, at t: Double, strength: Double = 1) {
        guard !directive.reduceMotion else { return }
        let s = scale.value
        switch gesture {
        case .oof:
            reaction = (gesture, t, t + 0.14)
            puff.kick(2 * strength)
            horns.left.kick(6 * strength)
            horns.right.kick(6 * strength)
            hornStretch.kick(0.6 * strength)
            markPulse.kick(3)
        case .eep:
            reaction = (gesture, t, t + 0.35)
            haloCenter.kick(Vec2(0, -220 * s * strength))
            haloRotation.kick((bonks % 2 == 0 ? 4 : -4) * strength)
            wings.left.kick(20 * Self.degrees * 8)
            wings.right.kick(20 * Self.degrees * 8)
        case .startle:
            reaction = (gesture, t, t + 0.35)
            haloCenter.kick(Vec2(0, -120 * s))
            hornStretch.kick(0.6)
        case .popUp:
            puff.kick(-1.5)
            markPulse.kick(2)
        case .popIn:
            if character == .angel {
                haloCenter.kick(Vec2(0, -150 * s))
                wings.left.kick(20 * Self.degrees * 10)
                wings.right.kick(20 * Self.degrees * 10)
            } else {
                hornStretch.kick(4)
                horns.left.kick(5)
                horns.right.kick(5)
            }
            markPulse.kick(2.5)
        case .nod:
            anchor.kick(Vec2(0, 60 * s))
        case .shocked:
            haloCenter.kick(Vec2(0, -60 * s))
            wings.left.kick(20 * Self.degrees * 8)
            wings.right.kick(20 * Self.degrees * 8)
            markPulse.kick(2)
        case .huff:
            squash.kick(-1.0)
            puff.kick(0.3 * 8)
            horns.left.kick(3)
            horns.right.kick(-3)
            markPulse.kick(2.5)
        case .laughAlong:
            squash.kick(0.6)
            markPulse.kick(2)
        case .eyeRoll:
            tilt.kick(-0.15)
        }
        retargetFeatures()
    }

    /// One substep of the lips toward `target`: opening at once, closing eased. Silence hands the
    /// mouth straight back to the expression (through τ).
    private static func ease(_ lips: MouthDrive?, toward target: MouthDrive?) -> MouthDrive? {
        guard let target, let lips else { return target }
        func follow(_ value: Double, _ goal: Double) -> Double { value + (goal - value) * lipGain }
        let openness = target.openness >= lips.openness ? target.openness : follow(lips.openness, target.openness)
        return MouthDrive(openness: openness, width: follow(lips.width, target.width),
                          rounding: follow(lips.rounding, target.rounding))
    }

    /// Sets the mouth's drive outside stepping (stills).
    mutating func hold(drive: MouthDrive?) {
        lips = drive
        talkOpen = drive?.talkOpen ?? 0
        energy = talkOpen
        mapMouth()
    }

    // MARK: Stepping

    /// One substep from `t`. `drive` is this substep's mouth (nil when silent) and `room` the
    /// live room in points while in contact. Returns a beat's strength when one fires.
    mutating func step(at t: Double, drive: MouthDrive?, speaking: Bool, room: Double?, beats: Bool) -> Double? {
        clock += SpringSpec.step
        talkOpen = drive?.talkOpen ?? 0
        lips = Self.ease(lips, toward: drive)
        energy += (talkOpen - energy) * Self.energyGain
        var beat: Double?
        if speaking, beats, let o = drive?.openness {
            if o < 0.22 {
                beatArmed = true
            } else if beatArmed, o > 0.42, t - lastBeat >= 0.110 {
                beatArmed = false
                lastBeat = t
                beat = RigMath.clamp((o - 0.42) / 0.4 + 0.5, 0.5, 1)
                if directive.mood == .excited { beat = min(1.5, beat! * 1.5) }
            }
        } else {
            beatArmed = false
        }
        if let ending = reaction, t >= ending.until {
            reaction = nil
            retargetFeatures()
        }

        // Features.
        for i in bank.indices { bank[i].step() }
        if !directive.talking {
            voiced = false
        } else if let drive, drive.openness > Self.voiceOnset {
            voiced = true
        }
        talk.retarget(directive.talking && (speaking || directive.still != nil)
            && (voiced || directive.still != nil) ? 1 : 0)
        talk.step()
        laughMouth.retarget(laughMouthTarget)
        laughMouth.step()
        readBack()
        mapMouth()

        // Head.
        if let contact, let room { squash.retarget(contact.squash(room: room, scale: scale.value)) }
        if let kick = delayedTiltKick, t >= kick.time {
            tilt.kick(kick.velocity)
            delayedTiltKick = nil
        }
        anchor.retarget(anchorTarget)
        scale.retarget(scaleTarget)
        tilt.retarget(targets.accessories.tilt * Self.degrees)
        anchor.step()
        scale.step()
        squash.step()
        tilt.step()

        // Accessories.
        stepFollowers(dt: SpringSpec.step)
        return beat
    }

    /// Snaps every spring to its target.
    mutating func settle() {
        retargetFeatures()
        for i in bank.indices { bank[i].snap() }
        // Settled, a talking face is voiced.
        voiced = directive.talking
        talk.retarget(directive.talking ? 1 : 0)
        talk.snap()
        laughMouth.retarget(laughMouthTarget)
        laughMouth.snap()
        readBack()
        anchor.retarget(anchorTarget)
        scale.retarget(scaleTarget)
        tilt.retarget(targets.accessories.tilt * Self.degrees)
        anchor.snap()
        scale.snap()
        squash.snap()
        tilt.snap()
        if let kick = delayedTiltKick {
            tilt.kick(kick.velocity)
            tilt.snap()
            delayedTiltKick = nil
        }
        reaction = nil
        if talkOpen == 0 { energy = 0 }
        retargetFeatures()
        for i in bank.indices { bank[i].snap() }
        readBack()
        mapMouth()
        retargetFollowers()
        turn.snap()
        haloCenter.snap(); haloRotation.snap(); haloSquash.snap()
        wings.left.snap(); wings.right.snap()
        horns.left.snap(); horns.right.snap()
        hornStretch.snap(); puff.snap(); markPulse.snap(); browKick.snap(); glowPulse.snap()
        press.snap(); laughBounce.snap(); laughShake.snap(); ambientFlap.snap()
    }

    // MARK: Features

    /// The targets for the directive and any running reaction.
    private mutating func retargetFeatures() {
        let d = directive
        var f = d.still?.targets(for: character) ?? ExpressionLibrary.targets(d.expression, for: character, mood: d.mood)
        let expression = d.effectiveExpression
        f.gaze = d.still?.gaze ?? ExpressionLibrary.gaze(expression, for: character) ?? d.gaze
        if let reaction {
            switch reaction.gesture {
            case .oof:
                for sigma in [-1.0, 1] {
                    f.eyes[sigma].closed = 1
                    f.eyes[sigma].chevron = 1
                    f.eyes[sigma].arcUp = 0
                    f.eyes[sigma].arcDown = 0
                }
            case .eep:
                for sigma in [-1.0, 1] {
                    f.eyes[sigma].sclera = 1
                    f.eyes[sigma].open = 1.25
                    f.eyes[sigma].closed = 0
                }
                f.mouth = MouthParams(width: 22, open: 30, round: 1, tongue: 1, line: AngelGeometry.mouthLine)
            case .startle:
                for sigma in [-1.0, 1] {
                    f.eyes[sigma].open = 1.25
                    f.eyes[sigma].sclera = min(1, f.eyes[sigma].sclera + 0.4)
                    f.eyes[sigma].closed = 0
                    f.brows[sigma].dy -= 10
                }
            default:
                break
            }
        }
        if d.still == nil {
            for sigma in [-1.0, 1] {
                f.brows[sigma].dy += d.browDy
                f.brows[sigma].angle += d.browAngle
                f.eyes[sigma].lidTop = max(f.eyes[sigma].lidTop, d.lidMin)
                if d.lidMin > 0 { f.eyes[sigma].lidInk = max(f.eyes[sigma].lidInk, 1) }
                f.eyes[sigma].sclera = max(f.eyes[sigma].sclera, d.scleraMin)
                f.eyes[sigma].open += d.eyeOpen
            }
            f.accessories.tilt += d.tilt
            f.accessories.headDy += d.headDy
        }
        if d.reduceMotion {
            // Under Reduce Motion the head holds its placement: no expression tilt, lift or perk.
            f.accessories.tilt = 0
            f.accessories.headDy = 0
            f.accessories.scaleBias = 1
        }
        targets = f
        for i in bank.indices { bank[i].retarget(f[keyPath: FaceTargets.channels[i].path]) }
        // The angel bounces as she laughs; the devil bounces with a happy chuckle and shakes his
        // head as he laughs.
        let bounce = character == .angel ? expression == .laughing : expression == .happy
        let shake = character == .devil && expression == .laughing
        laughBounce.retarget(!d.reduceMotion && bounce ? 1 : 0)
        laughShake.retarget(!d.reduceMotion && shake ? 1 : 0)
    }

    private mutating func readBack() {
        var f = targets
        for i in bank.indices { f[keyPath: FaceTargets.channels[i].path] = bank[i].value }
        current = f
    }

    /// Maps the lips onto the expression's mouth, under Reduce Motion too.
    private mutating func mapMouth() {
        if let lips { lastLips = lips }
        let shown = lips ?? lastLips
        let spoken = LipSyncMapping.map(current.mouth, drive: shown, talk: talk.value, character: character)
        let weight = laughMouth.value
        guard weight > 1e-6 else {
            mouth = spoken
            return
        }
        let laughed = LipSyncMapping.map(current.mouth, drive: shown, talk: talk.value, character: character,
                                         laughing: true)
        mouth = Self.mix(spoken, laughed, weight)
    }

    /// A laughing speaker's mouth keeps its wide-open floor as lip sync takes it over.
    private var laughMouthTarget: Double {
        directive.talking && directive.effectiveExpression == .laughing ? 1 : 0
    }

    /// Every number of `a` moved `t` of the way to `b`'s.
    private static func mix(_ a: MouthParams, _ b: MouthParams, _ t: Double) -> MouthParams {
        MouthParams(width: RigMath.mix(a.width, b.width, t), open: RigMath.mix(a.open, b.open, t),
                    corner: RigMath.mix(a.corner, b.corner, t), skew: RigMath.mix(a.skew, b.skew, t),
                    round: RigMath.mix(a.round, b.round, t), tongue: RigMath.mix(a.tongue, b.tongue, t),
                    fang: RigMath.mix(a.fang, b.fang, t), fangX: RigMath.mix(a.fangX, b.fangX, t),
                    shiftX: RigMath.mix(a.shiftX, b.shiftX, t), line: RigMath.mix(a.line, b.line, t))
    }

    // MARK: Head targets

    private var anchorTarget: Vec2 {
        placement.anchor + Vec2(0, ride + targets.accessories.headDy * placement.scale)
    }

    private var scaleTarget: Double {
        let lean = placement.designScale / max(neutralScale, 1e-9)
        let bias = max(targets.accessories.scaleBias, lean) / max(lean, 1e-9)
        return placement.scale * bias
    }

    // MARK: Accessories

    /// q: how far the head is squashed, toward where the leftover volume goes.
    var squeeze: Double {
        let sy = squash.value
        return RigMath.clamp((1 - sy) / (character == .devil ? 0.30 : 0.12), 0, 1)
    }

    private func haloTarget() -> Vec2 {
        headPose().point(AngelGeometry.haloCenter + Vec2(-3 * turn.value.x, -2 * turn.value.y))
    }

    private mutating func retargetFollowers() {
        let s = max(scale.value, 1e-6)
        let q = squeeze
        let gaze = current.gaze
        turn.retarget(Vec2(0.5 * gaze.x, 0.4 * gaze.y))
        haloCenter.retarget(haloTarget())
        let vx = haloCenter.velocity.x / s
        haloRotation.retarget(tilt.value + RigMath.clamp(0.0025 * vx, -0.35, 0.35))
        haloSquash.retarget((1 - 0.3 * (1 - squash.value)) * (1 - 0.25 * q))
        let head = anchor.velocity / s
        let drag = RigMath.clamp(-0.0016 * head.y, -0.45, 0.45)
        let spread = current.accessories.wingSpread * Self.degrees
        let tuck = 25 * Self.degrees * q
        var flap = 0.0
        let expression = directive.effectiveExpression
        if !directive.reduceMotion {
            if expression == .laughing {
                flap = 14 * Self.degrees * sin(flapPhase)
            } else if directive.talking {
                // Tempered at speaker scale, so the beating wings stay on screen.
                flap = 0.6 * (5 + 9 * energy) * Self.degrees * sin(flapPhase)
            }
        }
        wings.left.retarget(spread + drag - tuck + flap)
        wings.right.retarget(spread + drag - tuck + flap)
        let splay = current.accessories.hornSplay * Self.degrees + (contact != nil ? (16 + 18 * q) * Self.degrees : 0)
        let hornDrag = RigMath.clamp(-0.001 * head.x, -0.25, 0.25)
        horns.left.retarget(splay - hornDrag)
        horns.right.retarget(splay + hornDrag)
        hornStretch.retarget(0)
        puff.retarget(contact != nil && character == .devil ? min(1, 1.35 * q) : 0)
        markPulse.retarget(0)
        browKick.retarget(0)
        glowPulse.retarget(0)
        press.retarget(contact != nil ? 1 : 0)
        let talkingFlap = !directive.reduceMotion && (expression == .laughing || directive.talking)
        ambientFlap.retarget(talkingFlap ? 0 : directive.ambient)
    }

    private mutating func stepFollowers(dt: Double) {
        let expression = directive.effectiveExpression
        let frequency = expression == .laughing ? 3 : 0.6 + 1.8 * energy
        flapPhase += 2 * Double.pi * frequency * dt
        if flapPhase > 2 * Double.pi { flapPhase -= 2 * Double.pi }
        retargetFollowers()
        turn.step()
        haloCenter.step()
        haloRotation.step()
        haloSquash.step()
        wings.left.step(); wings.right.step()
        horns.left.step(); horns.right.step()
        hornStretch.step(); puff.step(); markPulse.step(); browKick.step(); glowPulse.step()
        press.step(); laughBounce.step(); laughShake.step(); ambientFlap.step()
        // The halo bonks off the top of the band.
        if character == .angel, directive.ceiling.isFinite {
            let half = AngelGeometry.haloOuterSize.y / 2 * scale.value * haloSquash.value
            if haloCenter.value.y - half < directive.ceiling {
                haloCenter.value.y = directive.ceiling + half
                if haloCenter.velocity.y < 0 {
                    haloCenter.velocity.y *= -0.35
                    bonks += 1
                    let golden = Double(bonks) * 0.618_033_988_7
                    let spin = 0.4 + 0.8 * (golden - golden.rounded(.down))
                    haloRotation.kick(bonks % 2 == 0 ? spin : -spin)
                }
            }
        }
    }

    // MARK: Reading

    var isSettled: Bool { isSettled(ignoringGaze: false) }

    /// Settled, apart from the gaze and what follows it (the parallax turn and the halo) when
    /// `ignoringGaze`, so the gaze's drift keeps an ambient stage ambient.
    func isSettled(ignoringGaze: Bool) -> Bool {
        guard anchor.isSettled, scale.isSettled, squash.isSettled, tilt.isSettled, delayedTiltKick == nil,
              energy < 1e-3, talkOpen == 0, reaction == nil, talk.isSettled else { return false }
        for (i, spring) in bank.enumerated() where !spring.isSettled {
            if ignoringGaze, i >= Self.gazeChannels { continue }
            return false
        }
        if !ignoringGaze, !turn.isSettled { return false }
        // Only the angel draws a halo and wings, and only the devil horns.
        let accessories = character == .angel
            ? (ignoringGaze || haloCenter.isSettled) && haloRotation.isSettled && haloSquash.isSettled
                && wings.left.isSettled && wings.right.isSettled
            : horns.left.isSettled && horns.right.isSettled
        return accessories && hornStretch.isSettled && puff.isSettled && markPulse.isSettled && browKick.isSettled
            && glowPulse.isSettled && press.isSettled && laughMouth.isSettled && laughBounce.isSettled
            && laughBounce.target == 0 && laughShake.isSettled && laughShake.target == 0 && ambientFlap.isSettled
    }

    /// The largest spring speed (each in its own units), for the Reduce Motion checks.
    var maxSpringSpeed: Double {
        var fastest = max(abs(anchor.velocity.x), abs(anchor.velocity.y), abs(scale.velocity), abs(squash.velocity),
                          abs(tilt.velocity), abs(talk.velocity), abs(laughMouth.velocity))
        for spring in bank { fastest = max(fastest, abs(spring.velocity)) }
        for spring in [haloRotation, haloSquash, wings.left, wings.right, horns.left, horns.right, hornStretch, puff,
                       markPulse, browKick, glowPulse, press, laughBounce, laughShake, ambientFlap] {
            fastest = max(fastest, abs(spring.velocity))
        }
        return max(fastest, abs(turn.velocity.x), abs(turn.velocity.y), abs(haloCenter.velocity.x),
                   abs(haloCenter.velocity.y))
    }

    /// The squash's limits: the devil 0.70…1.18, the angel 0.86…1.12.
    static func squashLimits(_ c: DuoCharacter) -> ClosedRange<Double> { c == .devil ? 0.70...1.18 : 0.86...1.12 }

    /// Overshoot past a knee near each limit is compressed smoothly (tanh) so the drawn squash
    /// never passes the limit; settled values inside the knees are unchanged.
    static func limitSquash(_ x: Double, _ c: DuoCharacter) -> Double {
        let limits = squashLimits(c)
        let lowKnee = limits.lowerBound + (c == .devil ? 0.06 : 0.03)
        let highKnee = limits.upperBound - 0.06
        if x < lowKnee {
            let room = lowKnee - limits.lowerBound
            return lowKnee - room * tanh((lowKnee - x) / room)
        }
        if x > highKnee {
            let room = limits.upperBound - highKnee
            return highKnee + room * tanh((x - highKnee) / room)
        }
        return x
    }

    /// `box` (face units) as drawn now: the stage rect around its corners.
    func drawnRect(_ box: FaceBoxes.Box) -> StageRect {
        let drawn = headPose().drawn
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for corner in [box.min, Vec2(box.max.x, box.min.y), Vec2(box.min.x, box.max.y), box.max] {
            let p = drawn.point(corner)
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return StageRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// The head's transform and the rhythms drawn on top of it (breath, the laugh's bob and
    /// shake, a gesture's shake): enough to place a point on the face, without its features.
    private func headPose() -> FacePose {
        let jaw = directive.reduceMotion ? 0 : 0.03 * talkOpen * talk.value
        let sy = Self.limitSquash(squash.value + jaw, character)
        var pose = FacePose(anchor: anchor.value, pivot: pivot, scale: scale.value, sx: pow(sy, Self.volumeExponent),
                            sy: sy, tilt: tilt.value, pin: placement.pin, blink: 0, peek: 0, talkOpen: talkOpen)
        pose.character = character
        let t = clock
        let ambient = directive.reduceMotion ? 0 : directive.ambient
        let rate = character == .angel ? 0.29 : 0.34
        var breath = 0.012 * sin(2 * Double.pi * rate * t) * ambient
        var bob = 0.0, shake = 0.0
        if laughBounce.value > 0 {
            let (rate, amplitude) = character == .angel ? (3.2, 4.0) : (2.5, 3.0)
            let phase = 2 * Double.pi * rate * t
            bob = -amplitude * abs(sin(phase)) * laughBounce.value
            breath += 0.04 * sin(2 * phase) * laughBounce.value
        }
        if laughShake.value > 0 { shake = 5 * Self.degrees * sin(2 * Double.pi * 4 * t) * laughShake.value }
        pose.breath = breath
        pose.bob = bob
        pose.shake = shake + (directive.reduceMotion ? 0 : gestureShake)
        pose.clock = t
        return pose
    }

    func pose(blink: Double = 0, reopen: Double = 1, peek: Double = 0, pop: FacePop = FacePop()) -> FacePose {
        var pose = headPose()
        pose.blink = blink
        pose.reopen = reopen
        pose.peek = peek
        pose.pop = pop
        var features = current
        features.mouth = mouth
        features.brows.left.dy += browKick.value
        features.brows.right.dy += browKick.value
        pose.features = features
        pose.turn = turn.value
        let t = clock
        let ambient = directive.reduceMotion ? 0 : directive.ambient
        let floatOffset = character == .angel ? -2.5 * scale.value * sin(2 * Double.pi * 0.35 * t) * ambient : 0
        pose.halo = HaloPose(center: haloCenter.value + Vec2(0, floatOffset), rotation: haloRotation.value,
                             squash: haloSquash.value,
                             glow: current.accessories.haloGlow * (1 + 0.15 * RigMath.clamp(glowPulse.value, 0, 1)))
        let slowFlap = 5 * Self.degrees * sin(2 * Double.pi * 0.6 * t) * ambientFlap.value
        pose.wings = PerSide(left: wings.left.value + slowFlap, right: wings.right.value + slowFlap)
        pose.horns = PerSide(left: horns.left.value, right: horns.right.value)
        pose.hornStretch = hornStretch.value
        pose.markPulse = markPulse.value * 0.25
        pose.puff = max(0, puff.value)
        pose.squeeze = squeeze
        pose.press = RigMath.clamp(press.value, 0, 1)
        pose.veinThrob = directive.reduceMotion ? 0 : sin(2 * Double.pi * t / DevilGeometry.angerVeinPeriod)
        if character == .angel { keepWingsOnStage(&pose) }
        return pose
    }

    // MARK: Wings at the edges

    /// Points around the left wing's outline (fu): its top lobe and feather tips, the parts that
    /// reach out as it swings.
    private static let wingRim: [Vec2] = {
        let lobe = AngelGeometry.wingTopLobe
        var circles = [FaceCircle(center: lobe.center + Vec2(-1, -1), radius: lobe.radius * 1.05)]
        circles += WingShape.featherTips
        return circles.flatMap { circle in
            (0..<12).map { k in
                let angle = Double(k) * Double.pi / 6
                return circle.center + Vec2(cos(angle), sin(angle)) * circle.radius
            }
        }
    }()

    /// How far inside the stage's edge a wing stops, in face units.
    private static let wingMargin = 3.0
    /// The wing angles the edge is looked for between: folded right in, to swung far out.
    private static let wingSearch = (from: -60 * degrees, to: 90 * degrees, step: 5 * degrees)

    /// How far the angel's wing on side σ reaches past `edges` (stage points; negative while
    /// inside), swung to `angle`, on the drawn head `drawn`, as the renderer draws it.
    static func wingOverhang(_ drawn: FacePose, sigma: Double, angle a: Double, edges: ClosedRange<Double>) -> Double {
        let hingeFu = AngelGeometry.wingHinge
        let k = 1 - 0.15 * drawn.squeeze
        let net = 1 - FacePart.wings.counterScale(.angel)
        let wsx = pow(drawn.sx, net) * k * drawn.scale, wsy = pow(drawn.sy, net) * k * drawn.scale
        let hinge = drawn.point(Vec2(-sigma * hingeFu.x, hingeFu.y))
        let angle = drawn.tilt + sigma * a
        let c = cos(angle), s = sin(angle)
        var reach = -Double.infinity
        for p in wingRim {
            let lx = (p.x - hingeFu.x) * -sigma * wsx, ly = (p.y - hingeFu.y) * wsy
            let x = hinge.x + lx * c - ly * s
            reach = max(reach, sigma < 0 ? edges.lowerBound - x : x - edges.upperBound)
        }
        return reach
    }

    /// Swinging out, a wing eases to a stop just inside the stage's edge, as drawn (breath, bob
    /// and shake included): from 8° short of the angle where, swinging out from folded, it would
    /// first cross the edge, the swing is compressed smoothly (tanh) toward that angle, so a
    /// flap or a jolt never pushes the wing off screen.
    private func keepWingsOnStage(_ pose: inout FacePose) {
        let edges = directive.edges
        guard edges.lowerBound.isFinite, edges.upperBound.isFinite else { return }
        let drawn = pose.drawn
        let margin = Self.wingMargin * drawn.scale
        guard edges.upperBound - edges.lowerBound > 2 * margin else { return }
        let inner = (edges.lowerBound + margin)...(edges.upperBound - margin)
        let knee = 8 * Self.degrees
        for sigma in [-1.0, 1] {
            func overhang(_ a: Double) -> Double { Self.wingOverhang(drawn, sigma: sigma, angle: a, edges: inner) }
            let angle = pose.wings[sigma]
            // The first angle, swinging out from folded, at which the wing meets the edge.
            var inside = Self.wingSearch.from
            guard angle > inside + 1e-9, overhang(inside) < 0 else { continue }
            var outside: Double?
            var a = inside
            while a < min(angle + knee, Self.wingSearch.to) {
                let next = min(a + Self.wingSearch.step, angle + knee)
                if overhang(next) >= 0 {
                    outside = next
                    break
                }
                inside = next
                a = next
            }
            guard var over = outside else { continue }
            for _ in 0..<20 {
                let middle = (inside + over) / 2
                if overhang(middle) < 0 { inside = middle } else { over = middle }
            }
            let start = inside - knee
            if angle > start { pose.wings[sigma] = start + knee * tanh((angle - start) / knee) }
        }
    }
}

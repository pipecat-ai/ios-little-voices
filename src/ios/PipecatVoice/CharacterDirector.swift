import Foundation

/// What a character is doing on stage. Each role holds an expression.
enum CharacterRole: Equatable, Hashable, Sendable {
    /// Nobody has been in a conversation for 30 s.
    case dozing
    case speaking
    /// Pressed by the other's line; `addressed` when that line is for this character.
    case squished(addressed: Bool)
    case thinking
    /// Just addressed with nobody on the floor (1.2 s), then listening.
    case attentive
    case listening
    /// Within 0.6 s of an interruption.
    case startled
    /// Within 2.5 s of an exchange ending; `lastSpeaker` for the one who spoke last.
    case afterglow(lastSpeaker: Bool)
    case neutral
    /// Neutral for 6 s.
    case resting
}

/// The gestures the director starts, recorded as `StageEvent.gesture`.
enum StageGesture: String, Sendable {
    case blink
    case peek
    case drift
    case glance
    case eyeRoll
    case sigh
    case nod
    case laughAlong
    case shocked
    case huff
    case headShake
    case starry
    case content
    case browRaise
    case glare
    case curious
    case wink
    case cheekyWink
    /// The launch intro's: popping in, shoving the other off the floor, and being squished.
    case popIn
    case shove
    case squish
}

/// What role resolution and the agenda read.
struct RoleContext: Sendable {
    var inputs: StageInputs
    /// The stage's (debounced) floor.
    var floor: DuoCharacter?
    var time: Double
    var lastInputChange: Double
    var interruptedAt: Double?
    var exchangeEndedAt: Double?
    var lastSpeaker: DuoCharacter?
    /// When each character was last addressed.
    var addressedAt: PerCharacter<Double?>
    /// When the floor holder fell silent (a pause of 0.6 s or more), while it lasts.
    var pausedSince: Double?
    /// The human's microphone level while their words show.
    var userLevel: Double?
}

/// How a face looks this substep, on top of its held expression: the gaze and the gestures'
/// offsets.
struct FaceLook: Equatable, Sendable {
    /// A gesture's expression in place of the held one.
    var expression: FaceExpression?
    var gaze = Vec2.zero
    /// fu; positive moves the brows down.
    var browDy = 0.0
    /// Degrees added to both brows.
    var browAngle = 0.0
    /// The top lids come down at least this far (an eye roll's or a sigh's lids).
    var lidMin = 0.0
    var scleraMin = 0.0
    /// Added to both eyes' openness.
    var eyeOpen = 0.0
    /// Degrees added to the head's tilt.
    var tilt = 0.0
    /// fu added to the head's offset (positive is down).
    var headDy = 0.0
}

/// One character's director: its role, agenda, reactions and gestures, on its own seeded
/// stream. Draws happen only when an item is scheduled, and are stored as absolute sim times.
/// Gestures arbitrate by layer: a gesture starts only when none of equal or higher layer runs
/// (agenda items then wait 0.3 s and reactions are dropped), and a higher layer cancels a lower
/// glance or drift.
struct CharacterDirector: Sendable {
    static let dozeAfter = 30.0
    static let attentiveFor = 1.2
    static let startleFor = 0.6
    static let afterglowFor = 2.5
    static let restingAfter = 6.0
    static let peekDuration = 0.6
    static let deferral = 0.3
    static let flashDuration = 0.25
    static let rollDuration = 1.02
    static let sighDuration = 0.7

    /// A timed overlay: an expression, a held offset or a rhythmic motion.
    struct Overlay: Equatable, Sendable {
        var gesture: StageGesture
        var start: Double
        var until: Double
        var expression: FaceExpression?
        var gaze: Vec2?
        var browDy = 0.0
        var eyeOpen = 0.0
        var tilt = 0.0
        /// A head shake: amplitude (degrees) and frequency (Hz).
        var shake: (amplitude: Double, frequency: Double)?

        static func == (a: Overlay, b: Overlay) -> Bool {
            a.gesture == b.gesture && a.start == b.start && a.until == b.until && a.expression == b.expression
                && a.gaze == b.gaze && a.browDy == b.browDy && a.eyeOpen == b.eyeOpen && a.tilt == b.tilt
                && a.shake?.amplitude == b.shake?.amplitude && a.shake?.frequency == b.shake?.frequency
        }
    }

    /// A glance away from the gaze home and back (layer 2).
    private struct Glance: Equatable, Sendable {
        var target: Vec2
        var until: Double
        /// "Look about and stay": the target becomes the new resting look.
        var stay: Bool
    }

    let character: DuoCharacter
    private(set) var random: SplitMix64
    private(set) var role = CharacterRole.neutral
    private var neutralSince: Double?
    private(set) var nextBlink: Double?
    private(set) var doubleBlink: Double?
    private(set) var blinkStart: Double?
    private(set) var peekStart: Double?
    private(set) var nextDrift: Double?
    private var drift = Vec2.zero
    private(set) var nextGlance: Double?
    private var glance: Glance?
    /// Where a resting face settled after looking about.
    private var lookAbout = Vec2.zero
    private var flashUntil: Double?
    private(set) var nextRoll: Double?
    private(set) var rollStart: Double?
    private var rollPath: GazePath?
    private(set) var nextSigh: Double?
    private(set) var sighStart: Double?
    private(set) var overlay: Overlay?
    /// A reaction waiting out its hearing delay.
    private(set) var pending: Overlay?
    /// The thinking gaze's side and when it next swaps.
    private var searchSide: Double
    /// A squished writer's gaze is searching (rather than watching the speaker).
    private var searchAway = false
    private var nextSwap: Double?
    /// The speaker's tilt for the current sentence, alternating per sentence (degrees).
    private var sentenceTilt = 0.0
    private var tiltSign: Double
    /// The speaker's sentence has a laugh cue: it laughs with closed eyes, so it never blinks.
    private var laughingLine = false
    private var nodArmed = true
    private var lastNod = -Double.infinity
    /// Gestures started by the last `runAgenda` or `hear` call, for the stage's events and kicks.
    private(set) var started: [StageGesture] = []

    init(_ character: DuoCharacter, seed: UInt64, at time: Double) {
        self.character = character
        random = SplitMix64(seed: seed, stream: character == .angel ? .angel : .devil)
        neutralSince = time
        searchSide = character == .angel ? 1 : -1
        tiltSign = character == .angel ? 1 : -1
        started.reserveCapacity(4)
        scheduleFirstBlink(at: time)
    }

    private var other: DuoCharacter { character == .angel ? .devil : .angel }

    // MARK: Roles

    /// Resolves the role at `context.time` (first match wins); true when it changed.
    mutating func resolve(_ context: RoleContext) -> Bool {
        let t = context.time, inputs = context.inputs
        let next: CharacterRole
        if !inputs.active, !inputs.preparing, t - context.lastInputChange >= Self.dozeAfter {
            next = .dozing
        } else if context.floor == character {
            next = .speaking
        } else if context.floor == other {
            next = .squished(addressed: inputs.addressed.contains(character))
        } else if inputs.thinking.contains(character) {
            next = .thinking
        } else if context.floor == nil, inputs.addressed.contains(character) {
            let since = context.addressedAt[character] ?? t
            next = t - since < Self.attentiveFor ? .attentive : .listening
        } else if inputs.userText != nil {
            next = .listening
        } else if let interrupted = context.interruptedAt, t - interrupted < Self.startleFor {
            next = .startled
        } else if let ended = context.exchangeEndedAt, t - ended < Self.afterglowFor {
            next = .afterglow(lastSpeaker: context.lastSpeaker == character)
        } else {
            if role != .neutral, role != .resting { neutralSince = t }
            next = t - (neutralSince ?? t) >= Self.restingAfter ? .resting : .neutral
        }
        guard next != role else { return false }
        let wasSpeaking = role == .speaking
        role = next
        if wasSpeaking {
            sentenceTilt = 0
            laughingLine = false
        }
        // Taking the floor ends a listener's reactions: the speaker's own face takes over.
        if next == .speaking { endGestures(at: t) }
        // A new role draws its own glance timing.
        nextGlance = nil
        glance = nil
        return true
    }

    /// Ends the gestures running at `t`. Reaction faces, rolls, sighs, the brow flash and drift
    /// give way at once, their springs easing the face back; a head shake fades out over 0.15 s
    /// rather than stopping dead.
    private mutating func endGestures(at t: Double) {
        if var shaking = overlay, shaking.shake != nil, t < shaking.until {
            shaking.expression = nil
            shaking.gaze = nil
            shaking.browDy = 0
            shaking.eyeOpen = 0
            shaking.tilt = 0
            shaking.until = min(shaking.until, t + 0.15)
            overlay = shaking
        } else {
            overlay = nil
        }
        pending = nil
        rollStart = nil
        rollPath = nil
        sighStart = nil
        flashUntil = nil
        drift = .zero
    }

    /// The next time the role may change without new input.
    func roleDeadline(_ context: RoleContext) -> Double? {
        let t = context.time, inputs = context.inputs
        var earliest = Double.infinity
        func consider(_ time: Double?) {
            if let time, time > t, time < earliest { earliest = time }
        }
        if !inputs.active, !inputs.preparing { consider(context.lastInputChange + Self.dozeAfter) }
        consider(context.addressedAt[character].map { $0 + Self.attentiveFor })
        consider(context.interruptedAt.map { $0 + Self.startleFor })
        consider(context.exchangeEndedAt.map { $0 + Self.afterglowFor })
        if role == .neutral { consider(neutralSince.map { $0 + Self.restingAfter }) }
        if role == .speaking, let paused = context.pausedSince, inputs.active || inputs.preparing {
            consider(paused + 0.6)
            consider(paused + 1.2)
        }
        return earliest.isFinite ? earliest : nil
    }

    /// The expression a role holds.
    static func expression(for role: CharacterRole) -> FaceExpression {
        switch role {
        case .dozing: .sleepy
        case .speaking: .talking
        case .squished(let addressed): addressed ? .squishedAddressed : .squished
        case .thinking: .thinking
        case .attentive: .attentive
        case .listening: .listening
        case .startled: .surprised
        case .afterglow(let lastSpeaker): lastSpeaker ? .happy : .content
        case .neutral: .neutral
        case .resting: .resting
        }
    }

    /// The expression this character holds now.
    var expression: FaceExpression { Self.expression(for: role) }

    private var isSquished: Bool { if case .squished = role { true } else { false } }
    private var isSquishedUnaddressed: Bool { role == .squished(addressed: false) }

    // MARK: Gaze

    /// Where the eyes rest: the player, the other character, or searching while writing.
    /// `still` (Reduce Motion) holds the gaze at the role's home, without the waiting glances.
    func home(_ context: RoleContext, still: Bool = false) -> Vec2 {
        let t = context.time
        switch role {
        case .speaking:
            if !still, let paused = context.pausedSince, context.inputs.active || context.inputs.preparing {
                // Waiting: a glance at the other, then the player, then a pondering look up.
                let held = t - paused
                if held < 0.6 { return lookAtOther }
                if held >= 1.2 { return Vec2(0.55 * searchSide, -0.6) }
                return .zero
            }
            return context.inputs.addressed.contains(other) ? speakerLookAtOther : .zero
        case .squished:
            if context.inputs.thinking.contains(character), searchAway {
                return Vec2(0.8 * searchSide, -0.75)
            }
            return lookAtOther
        case .thinking:
            return Vec2(0.8 * searchSide, -0.75)
        case .neutral, .resting:
            return lookAbout
        default:
            return .zero
        }
    }

    /// The look-at vector to the other character while watching them.
    private var lookAtOther: Vec2 { character == .angel ? Vec2(0.1, 0.8) : Vec2(0.15, -0.85) }

    /// A speaker addressing the other character looks down (angel) or up (devil) at them.
    private var speakerLookAtOther: Vec2 { character == .angel ? Vec2(0.1, 0.85) : Vec2(-0.2, -0.8) }

    /// The face's look at `context.time`: gaze home with drift, glances, rolls, sighs and the
    /// reaction overlay; the eye roll's path, the brow flash and the overlay's offsets.
    func look(_ context: RoleContext) -> FaceLook {
        let t = context.time
        var look = FaceLook()
        look.gaze = home(context) + drift
        if let glance { look.gaze = glance.target }
        if let flashUntil, t < flashUntil { look.browDy -= 3 }
        if let start = rollStart, let path = rollPath {
            look.gaze = path.value(at: t - start)
            look.lidMin = 0.38
            look.scleraMin = 0.7
            look.browDy -= 4
            look.tilt -= 3
        }
        if sighStart != nil {
            look.gaze = Vec2(0, -0.9)
            look.lidMin = 0.2
            look.browAngle -= 8
            look.headDy += 2
        }
        if let overlay {
            look.expression = overlay.expression
            if let gaze = overlay.gaze { look.gaze = gaze }
            look.browDy += overlay.browDy
            look.eyeOpen += overlay.eyeOpen
            look.tilt += overlay.tilt
        }
        if role == .speaking { look.tilt += sentenceTilt }
        return look
    }

    /// The overlay's head shake at `t` (radians).
    func shake(at t: Double) -> Double {
        guard let overlay, let shake = overlay.shake, t >= overlay.start, t < overlay.until else { return 0 }
        let fade = min(1, (overlay.until - t) / 0.15)
        return shake.amplitude * Double.pi / 180 * sin(2 * Double.pi * shake.frequency * (t - overlay.start)) * fade
    }

    // MARK: Agenda

    /// Runs the agenda at boundary `t`: blinks (with doubles), drift, glances, the devil's eye
    /// rolls and the angel's sighs while squished, the thinking gaze's swaps, nods while the
    /// human speaks and reactions whose hearing delay has passed. `allowed` is false under Reduce
    /// Motion, where nothing runs. Started gestures are in `started`.
    mutating func runAgenda(_ context: RoleContext, allowed: Bool) {
        let t = context.time
        started.removeAll(keepingCapacity: true)
        expire(at: t)
        guard allowed, role != .dozing else {
            clearAgenda(keepPeek: allowed)
            return
        }
        let inputs = context.inputs
        let inConversation = inputs.active || inputs.preparing
        // Drift belongs to an ambient stage: a conversation with input in the last minute.
        let conversation = inConversation && t - context.lastInputChange < StageSimulation.ambientTimeout

        // Blinks.
        if nextBlink == nil { scheduleFirstBlink(at: t) }
        if let pending = doubleBlink, t >= pending, blinkStart == nil {
            doubleBlink = nil
            startBlink(at: t)
        }
        if let next = nextBlink, t >= next {
            if blinkStart != nil || !blinkAllowed {
                nextBlink = t + Self.deferral
            } else {
                startBlink(at: t)
                nextBlink = t + random.uniform(in: 2...5.5) / (isSquished ? 1.3 : 1)
                if random.chance(0.15) { doubleBlink = t + random.uniform(in: 0.2...0.3) }
            }
        }

        // Drift.
        if conversation {
            let busy = inputs.floor != nil || !inputs.thinking.isEmpty || inputs.userText != nil
            if nextDrift == nil { nextDrift = t + driftDelay(busy) }
            if let next = nextDrift, t >= next {
                if activeLayer(at: t) >= 0 {
                    nextDrift = t + Self.deferral
                } else {
                    drift = Vec2(random.uniform(in: -0.12...0.12), random.uniform(in: -0.08...0.08))
                    nextDrift = t + driftDelay(busy)
                    started.append(.drift)
                }
            }
        } else if nextDrift != nil {
            nextDrift = nil
            drift = .zero
        }

        // Glances.
        if inConversation || !isSquished, let delay = glanceDelay(context) {
            if nextGlance == nil { nextGlance = t + random.uniform(in: delay) }
            if let next = nextGlance, t >= next {
                if activeLayer(at: t) >= 2 {
                    nextGlance = t + Self.deferral
                } else {
                    startGlance(context)
                    nextGlance = t + random.uniform(in: delay)
                }
            }
        } else {
            nextGlance = nil
        }

        // The devil's eye rolls and the angel's sighs while squished and not addressed.
        if character == .devil, isSquishedUnaddressed, inConversation {
            if nextRoll == nil { nextRoll = t + random.uniform(in: 1.2...5.5) }
            if let next = nextRoll, t >= next {
                if activeLayer(at: t) >= 3 {
                    nextRoll = t + Self.deferral
                } else {
                    startRoll(context)
                    nextRoll = t + Self.rollDuration + random.uniform(in: 2.5...5.5)
                }
            }
        } else {
            nextRoll = nil
        }
        if character == .angel, isSquishedUnaddressed, inConversation {
            if nextSigh == nil { nextSigh = t + random.uniform(in: 6...11) }
            if let next = nextSigh, t >= next {
                if activeLayer(at: t) >= 3 {
                    nextSigh = t + Self.deferral
                } else {
                    cancelLower(than: 3)
                    sighStart = t
                    nextSigh = t + Self.sighDuration + random.uniform(in: 6...11)
                    started.append(.sigh)
                }
            }
        } else {
            nextSigh = nil
        }

        // The thinking gaze alternates sides.
        let searching = role == .thinking || (isSquished && inputs.thinking.contains(character))
        if searching {
            if nextSwap == nil { nextSwap = t + random.uniform(in: 0.7...1.4) }
            if let next = nextSwap, t >= next {
                if role == .thinking {
                    searchSide = -searchSide
                } else {
                    searchAway.toggle()
                    if searchAway { searchSide = -searchSide }
                }
                nextSwap = t + random.uniform(in: 0.7...1.4)
            }
        } else {
            nextSwap = nil
            searchAway = false
        }

        // Nods while the human speaks.
        if inputs.userText != nil, let level = context.userLevel {
            if level < 0.3 {
                nodArmed = true
            } else if nodArmed, level > 0.5 {
                nodArmed = false
                if t - lastNod >= 0.8, activeLayer(at: t) < 4,
                   random.chance(inputs.addressed.contains(character) ? 0.35 : 0.15) {
                    lastNod = t
                    started.append(.nod)
                }
            }
        }

        // A reaction whose hearing delay has passed: dropped when a reaction already runs.
        if let reaction = pending, t >= reaction.start {
            pending = nil
            if activeLayer(at: t) < 4 { begin(reaction, at: t) }
        }
    }

    /// Ends gestures whose time is up.
    private mutating func expire(at t: Double) {
        if let start = blinkStart, t - start >= BlinkEnvelope.duration { blinkStart = nil }
        if let start = peekStart, t - start >= Self.peekDuration { peekStart = nil }
        if let current = glance, t >= current.until {
            if current.stay { lookAbout = current.target }
            glance = nil
        }
        if let until = flashUntil, t >= until { flashUntil = nil }
        if let start = rollStart, t - start >= Self.rollDuration {
            rollStart = nil
            rollPath = nil
        }
        if let start = sighStart, t - start >= Self.sighDuration { sighStart = nil }
        if let current = overlay, t >= current.until { overlay = nil }
    }

    private mutating func clearAgenda(keepPeek: Bool) {
        nextBlink = nil
        doubleBlink = nil
        blinkStart = nil
        if !keepPeek { peekStart = nil }
        nextDrift = nil
        drift = .zero
        nextGlance = nil
        glance = nil
        // A dozing face keeps looking where it was; under Reduce Motion the gaze holds at home.
        if !keepPeek { lookAbout = .zero }
        flashUntil = nil
        nextRoll = nil
        rollStart = nil
        rollPath = nil
        nextSigh = nil
        sighStart = nil
        overlay = nil
        pending = nil
        nextSwap = nil
    }

    /// Blinks never overlap closed eyes, a roll or a wink.
    private var blinkAllowed: Bool {
        if rollStart != nil || (role == .speaking && laughingLine) { return false }
        if let overlay, overlay.gesture == .wink || overlay.gesture == .cheekyWink
            || overlay.expression.map({ ExpressionLibrary.eyesClosed($0, for: character) }) == true {
            return false
        }
        return !ExpressionLibrary.eyesClosed(expression, for: character)
    }

    private mutating func startBlink(at t: Double) {
        guard blinkAllowed else { return }
        blinkStart = t
        started.append(.blink)
    }

    private mutating func driftDelay(_ busy: Bool) -> Double {
        busy ? random.uniform(in: 0.6...1.6) : random.uniform(in: 2...4)
    }

    /// The range of delays to the next glance in this role; nil when it does not glance.
    private func glanceDelay(_ context: RoleContext) -> ClosedRange<Double>? {
        switch role {
        case .speaking: context.pausedSince == nil ? 3...6 : nil
        case .squished: context.inputs.thinking.contains(character) ? nil : 2.5...5
        case .listening: 3.5...7
        // Outside a conversation the face looks about less often, so the idle stage sleeps.
        case .neutral, .resting: context.inputs.active || context.inputs.preparing ? 2...5 : 8...14
        default: nil
        }
    }

    private mutating func startGlance(_ context: RoleContext) {
        let from = home(context) + drift
        var target: Vec2, hold: Double, stay = false, flash = false
        switch role {
        case .speaking where context.inputs.addressed.contains(other):
            target = .zero
            hold = random.uniform(in: 0.7...1.3)
            flash = true
        case .speaking:
            target = character == .angel ? Vec2(0.05, 0.75) : Vec2(-0.1, -0.75)
            hold = random.uniform(in: 0.5...1.0)
        case .squished:
            target = .zero
            hold = random.uniform(in: 0.7...1.3)
            flash = true
        default:
            if !(context.inputs.active || context.inputs.preparing) {
                // Idle: look about and stay, or look back at the player; one saccade each.
                cancelLower(than: 2)
                lookAbout = lookAbout == .zero
                    ? Vec2(random.uniform(in: 0.35...0.7) * random.sign(), random.uniform(in: -0.35...0.15)) : .zero
                started.append(.glance)
                return
            }
            if random.chance(0.5) {
                target = Vec2(random.uniform(in: 0.4...0.75) * random.sign(), random.uniform(in: -0.4...0.2))
                hold = random.uniform(in: 0.7...1.4)
                stay = role == .resting && random.chance(0.5)
            } else {
                target = lookAtOther
                hold = random.uniform(in: 0.5...1.0)
            }
            if stay { lookAbout = .zero }
        }
        let t = context.time
        cancelLower(than: 2)
        glance = Glance(target: target, until: t + hold, stay: stay)
        if flash { flashUntil = t + Self.flashDuration }
        started.append(.glance)
        // A large gaze shift carries a blink 60% of the time.
        if (target - from).length > 0.6, blinkStart == nil, random.chance(0.6) { startBlink(at: t) }
    }

    private mutating func startRoll(_ context: RoleContext) {
        cancelLower(than: 3)
        let from = home(context)
        rollPath = GazePath.eyeRoll(from: from, direction: random.sign())
        rollStart = context.time
        started.append(.eyeRoll)
    }

    /// A higher layer cancels a lower glance or drift.
    private mutating func cancelLower(than layer: Int) {
        if layer > 0 { drift = .zero }
        if layer > 2 {
            glance = nil
            flashUntil = nil
        }
    }

    /// The highest layer running at `t` (−1 when none): blinks 1, glances 2, rolls and sighs 3,
    /// reactions 4.
    func activeLayer(at t: Double) -> Int {
        if overlay != nil { return 4 }
        if rollStart != nil || sighStart != nil { return 3 }
        if glance != nil { return 2 }
        if let start = blinkStart, t - start < BlinkEnvelope.duration { return 1 }
        return -1
    }

    private mutating func begin(_ reaction: Overlay, at t: Double) {
        var reaction = reaction
        let length = reaction.until - reaction.start
        reaction.start = t
        reaction.until = t + length
        if reaction.gesture == .eyeRoll {
            // A delayed eye roll (virtue, exclaim) is a roll, not an overlay.
            guard rollStart == nil else { return }
            cancelLower(than: 3)
            rollPath = GazePath.eyeRoll(from: lookAtOther, direction: random.sign())
            rollStart = t
            started.append(.eyeRoll)
            return
        }
        cancelLower(than: 4)
        rollStart = nil
        rollPath = nil
        sighStart = nil
        overlay = reaction
        if reaction.gesture == .browRaise || reaction.gesture == .glance {
            glance = Glance(target: lookAtOther, until: reaction.until, stay: false)
        }
        started.append(reaction.gesture)
    }

    mutating func startPeek(at t: Double) { peekStart = t }

    /// Starts one of the launch intro's looks at `t`: `expression` for `length` s on the reaction
    /// layer, at the other character or, unless `atOther`, the human. `gesture` names it.
    mutating func perform(_ gesture: StageGesture, _ expression: FaceExpression, at t: Double, for length: Double,
                          atOther: Bool) {
        started.removeAll(keepingCapacity: true)
        begin(Overlay(gesture: gesture, start: t, until: t + length, expression: expression,
                      gaze: atOther ? lookAtOther : .zero), at: t)
    }

    // MARK: Hearing

    /// The stage noticed `event` at `t`: reactions to the other's caption after a seeded 0.25–0.6-s
    /// hearing delay, the speaker's own sentence tilt and scoff, the verdict at an exchange's
    /// end, and the human's final words. `allowed` is false under Reduce Motion.
    mutating func hear(_ event: StageEvent, at t: Double, context: RoleContext, lineToPlayer: Bool, allowed: Bool) {
        started.removeAll(keepingCapacity: true)
        guard allowed, role != .dozing else { return }
        switch event {
        case .captionStarted(let speaker, _, let cues) where speaker == character:
            // The speaker leans into each sentence with a tilt that alternates sides.
            // A question's own tilt (the asking mood) replaces it.
            tiltSign = -tiltSign
            sentenceTilt = tiltSign * random.uniform(in: 3...6)
            if cues.contains(.question) { sentenceTilt = 0 }
            laughingLine = cues.contains(.laugh)
            if character == .devil, cues.contains(.scoff), rollStart == nil {
                cancelLower(than: 3)
                rollPath = GazePath.eyeRoll(from: home(context), direction: random.sign())
                rollStart = t
                started.append(.eyeRoll)
            }
        case .captionStarted(let speaker, _, let cues) where speaker == other:
            pending = reaction(to: cues, at: t, addressed: context.inputs.addressed.contains(character))
        case .exchangeEnded:
            verdict(at: t, lastSpeaker: context.lastSpeaker, toPlayer: lineToPlayer)
        case .interrupted:
            endGestures(at: t)
            glance = nil
            sentenceTilt = 0
        case .floorChanged:
            pending = nil
        case .userFinal(let text, let cues):
            if cues.contains(.laugh), random.chance(0.5) {
                begin(Overlay(gesture: .laughAlong, start: t, until: t + 1.2, expression: .laughing), at: t)
            } else if text.range(of: "thank", options: .caseInsensitive) != nil {
                begin(Overlay(gesture: .content, start: t, until: t + 1.2, expression: .content), at: t)
            } else if cues.contains(.question) {
                begin(Overlay(gesture: .curious, start: t, until: t + 0.6, eyeOpen: 0.06,
                              tilt: character == .angel ? 6 : -6), at: t)
            }
        default:
            break
        }
    }

    /// The listener's reaction to a caption's cues, waiting out its hearing delay; nil when the
    /// dice say no.
    private mutating func reaction(to cues: Set<Cue>, at t: Double, addressed: Bool) -> Overlay? {
        let delay = random.uniform(in: 0.25...0.6)
        let start = t + delay
        func overlay(_ gesture: StageGesture, _ length: Double, expression: FaceExpression? = nil,
                     browDy: Double = 0, eyeOpen: Double = 0, tilt: Double = 0,
                     shake: (Double, Double)? = nil) -> Overlay {
            Overlay(gesture: gesture, start: start, until: start + length, expression: expression, browDy: browDy,
                    eyeOpen: eyeOpen, tilt: tilt, shake: shake.map { (amplitude: $0.0, frequency: $0.1) })
        }
        let angel = character == .angel
        if cues.contains(.laugh) {
            if angel {
                return random.chance(0.4)
                    ? overlay(.laughAlong, random.uniform(in: 1.4...2.2), expression: .laughing) : nil
            }
            return random.chance(0.25) ? overlay(.laughAlong, 0.7, expression: .laughing)
                : overlay(.content, 1.2, expression: .content)
        }
        if cues.contains(angel ? .mentionsAngel : .mentionsDevil) {
            if angel { return random.chance(0.8) ? overlay(.browRaise, 1.0, browDy: -6) : nil }
            return overlay(.glare, 2.5, expression: .squishedAddressed)
        }
        if cues.contains(.question), addressed {
            return overlay(.curious, 1.5, browDy: -5, eyeOpen: 0.1, tilt: angel ? 6 : -6)
        }
        if !angel, cues.contains(.virtue) {
            // The eye roll comes 0.6 s into the line.
            guard random.chance(0.7) else { return nil }
            return Overlay(gesture: .eyeRoll, start: t + 0.6, until: t + 0.6 + Self.rollDuration)
        }
        if angel, cues.contains(.temptation) {
            return random.chance(0.6) ? overlay(.headShake, 0.8, shake: (4, 2)) : nil
        }
        if cues.contains(.exclaim) {
            if angel { return random.chance(0.5) ? overlay(.shocked, 0.6, expression: .surprised) : nil }
            let roll = random.uniform()
            if roll < 0.3 { return overlay(.huff, 0.5, expression: .grumpy) }
            if roll < 0.7 { return Overlay(gesture: .eyeRoll, start: start, until: start + Self.rollDuration) }
            return nil
        }
        if cues.contains(.wow) {
            return angel ? overlay(.starry, 1.2, expression: .starry) : overlay(.content, 1.2, expression: .content)
        }
        return nil
    }

    /// The verdict as an exchange ends: the afterglow role holds happy or content, and
    /// sometimes a wink lands first.
    private mutating func verdict(at t: Double, lastSpeaker: DuoCharacter?, toPlayer: Bool) {
        // The faces hold through the release hold; the verdict lands with the release.
        let start = t + StageSimulation.releaseHold
        if lastSpeaker == character {
            let chance = character == .angel ? 0.35 : 0.5
            guard toPlayer, random.chance(chance) else { return }
        } else {
            guard character == .devil, lastSpeaker == .angel, random.chance(0.4) else { return }
        }
        let length = character == .angel ? 0.45 : 0.7
        // The head stays level: the release's pop already moves it.
        let level = -ExpressionLibrary.targets(.wink, for: character).accessories.tilt
        pending = Overlay(gesture: character == .angel ? .wink : .cheekyWink, start: start, until: start + length,
                          expression: .wink, tilt: level)
    }

    // MARK: Skipping

    /// Time skipped from `from` to `to` without stepping: anything that fell due in between is
    /// rescheduled from `to` with the time it had left (other items at least 0.5 s on), and
    /// running gestures end, so nothing bursts on the next frame. True when the next blink moved.
    @discardableResult
    mutating func reschedule(from: Double, to: Double) -> Bool {
        var moved = false
        if let next = nextBlink, next < to {
            nextBlink = to + max(0, next - from)
            moved = true
        }
        func move(_ time: inout Double?, _ offset: Double) {
            if let next = time, next < to { time = to + max(0.5, next - from) + offset }
        }
        move(&nextDrift, 0)
        move(&nextGlance, 0.3)
        move(&nextRoll, 0.6)
        move(&nextSigh, 0.6)
        move(&nextSwap, 0.9)
        doubleBlink = nil
        blinkStart = nil
        peekStart = nil
        glance = nil
        flashUntil = nil
        rollStart = nil
        rollPath = nil
        sighStart = nil
        overlay = nil
        pending = nil
        return moved
    }

    /// Moves the next blink to `time` at the earliest.
    mutating func postponeBlink(until time: Double) {
        if let next = nextBlink, next < time { nextBlink = time }
    }

    private mutating func scheduleFirstBlink(at t: Double) {
        nextBlink = t + random.uniform(in: 1.5...4.5)
    }

    // MARK: Reading

    /// The blink closure at `t`.
    func blink(at t: Double) -> Double {
        guard let start = blinkStart else { return 0 }
        return BlinkEnvelope.closure(at: t - start)
    }

    /// How far past rest the eyes open as a blink ends, as a multiplier (1 outside a blink).
    func reopen(at t: Double) -> Double {
        guard let start = blinkStart else { return 1 }
        return BlinkEnvelope.reopenGain(at: t - start)
    }

    /// The peeking eye's openness at `t`: up to 0.6 and back over 0.6 s.
    func peek(at t: Double) -> Double {
        guard let start = peekStart else { return 0 }
        let p = (t - start) / Self.peekDuration
        return p >= 0 && p < 1 ? 0.6 * sin(Double.pi * p) : 0
    }

    /// A gesture that moves every frame runs at `t`: a blink, a peek, an eye roll or a head
    /// shake. Holds (glances, sighs, held reaction faces) need no frames once their springs
    /// settle; their ends are agenda items.
    func isGesturing(at t: Double) -> Bool {
        if let start = blinkStart, t - start < BlinkEnvelope.duration { return true }
        if let start = peekStart, t - start < Self.peekDuration { return true }
        if let start = rollStart, t - start < Self.rollDuration { return true }
        if let overlay, overlay.shake != nil, t < overlay.until { return true }
        return false
    }

    /// The next agenda item: a gesture's start or end, or a timer.
    var nextAgendaItem: Double? {
        var earliest = Double.infinity
        func consider(_ time: Double?) { if let time, time < earliest { earliest = time } }
        consider(nextBlink)
        consider(doubleBlink)
        consider(nextDrift)
        consider(nextGlance)
        consider(glance?.until)
        consider(flashUntil)
        consider(nextRoll)
        consider(nextSigh)
        consider(sighStart.map { $0 + Self.sighDuration })
        consider(overlay?.until)
        consider(pending?.start)
        consider(nextSwap)
        return earliest.isFinite ? earliest : nil
    }
}

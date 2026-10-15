import Foundation

/// What the stage reads from the conversation. It changes only on events.
struct StageInputs: Equatable, Sendable {
    var active = false
    var preparing = false
    /// The character whose line is being heard.
    var floor: DuoCharacter?
    /// Who that line, or the human's question, is for.
    var addressed: Set<DuoCharacter> = []
    /// Characters writing a line while someone else holds the floor.
    var thinking: Set<DuoCharacter> = []
    /// Each character's current or last sentence.
    var captions: [DuoCharacter: String] = [:]
    /// The human's words, shown until a character answers.
    var userText: String?
    var userFinal = false
    /// Characters whose mouths are animating.
    var talking: Set<DuoCharacter> = []
    /// Lines stopped early while a character held the floor.
    var interruptions = 0
}

/// How the stage is shown, apart from the conversation.
struct StageMode: Equatable, Sendable {
    var reduceMotion = false
    /// "Prefer Cross-Fade Transitions" without Reduce Motion: handovers and releases cross-fade.
    var crossFadeOnly = false
    var sceneActive = true
}

/// Something the stage noticed: input diffs and internal events.
enum StageEvent: Equatable, Sendable {
    case interrupted
    case exchangeEnded
    case floorChanged(from: DuoCharacter?, to: DuoCharacter?)
    case captionStarted(DuoCharacter, String, Set<Cue>)
    case thinkingStarted(DuoCharacter)
    case thinkingStopped(DuoCharacter)
    case addressedChanged(Set<DuoCharacter>)
    case userStarted
    case userUpdated
    case userFinal(String, Set<Cue>)
    case userEnded
    case activeChanged(Bool)
    case talkingStarted(DuoCharacter)
    case talkingStopped(DuoCharacter)
    case beat(DuoCharacter, Double)
    case pause(DuoCharacter)
    case resume(DuoCharacter)
    /// The seam hit the listener, with strength 0.4…1.
    case impact(DuoCharacter, Double)
    /// The incoming speaker's bubble, or the writing listener's capsule, may show.
    case slotClear(DuoCharacter)
    /// The draw order flipped; this character is now on top.
    case flipped(DuoCharacter)
    case gesture(DuoCharacter, StageGesture)
    /// Everything has settled.
    case settled
}

/// A pending slot's wait: since when, and the earliest it may show.
struct SlotHold: Equatable, Sendable {
    var since: Double
    var earliest: Double
}

struct StageEventRecord: Equatable, Sendable {
    var time: Double
    var event: StageEvent
}

/// Where the mouths come from: the app samples each frame's lip-sync poses; checks and demos
/// use analytic or scripted sources. Only characters in `StageInputs.talking` are asked.
protocol MouthSource {
    func drive(_ character: DuoCharacter, at simTime: Double) -> MouthDrive?
}

/// No mouth moves.
struct SilentMouths: MouthSource {
    func drive(_ character: DuoCharacter, at simTime: Double) -> MouthDrive? { nil }
}

/// The frame-rate tier the stage needs.
enum StageActivity: String, Sendable {
    /// A handover, impact or release: the display's full rate.
    case transition
    /// Speech, a gesture or a travelling wave: 60 Hz.
    case speech
    /// Only breath remains: 30 Hz.
    case ambient
    /// Everything settled: paused until `nextWake`.
    case asleep
    /// Outside a conversation for 30 s: paused, waking at least 10 s apart.
    case dozing
    /// The scene is inactive and sim time is frozen.
    case paused

    var isRunning: Bool { self == .transition || self == .speech || self == .ambient }

    /// The minimum frame interval, nil for the display's rate.
    func frameInterval() -> Double? {
        switch self {
        case .transition: nil
        case .speech: 1.0 / 60
        default: 1.0 / 30
        }
    }
}

/// What the renderer draws: the seam and both faces.
struct StagePicture: Equatable, Sendable {
    /// The live seam at u_k = k/48 (band fractions).
    var seam: [Double]
    var dominant: DuoCharacter
    /// The contact shadow's strength, clamp(|centre − resting centre|/0.12, 0, 1): none at rest.
    var shadow: Double

    /// The seam's soft edge at rest (1 − shadow): full with nobody on the floor, gone once the
    /// seam has moved into a floor holder's place, where the rim and contact shadow take over.
    var restEdge: Double { 1 - shadow }
    var faces: PerCharacter<FacePose>
}

extension StagePicture {
    /// The same seam, draw order and head placements, and the faces as far popped in; the
    /// features may differ (a mouth closing as speech ends is not a change of held layout).
    func sameLayout(as other: StagePicture) -> Bool {
        guard seam == other.seam, dominant == other.dominant, shadow == other.shadow else { return false }
        for c in DuoCharacter.allCases {
            let a = faces[c], b = other.faces[c]
            guard a.anchor == b.anchor, a.pivot == b.pivot, a.scale == b.scale, a.sx == b.sx, a.sy == b.sy,
                  a.tilt == b.tilt, a.pin == b.pin, a.pop == b.pop else { return false }
        }
        return true
    }
}

/// A Reduce Motion cross-fade from the previous settled picture.
struct StageCrossFade: Equatable, Sendable {
    var from: StagePicture
    /// 0…1, linear over 0.25 s.
    var progress: Double
}

/// One immutable frame of the stage.
struct StageFrame: Equatable, Sendable {
    var time: Double
    var picture: StagePicture
    var crossFade: StageCrossFade?

    /// The seam as drawn, in stage points, for a canvas `width` wide, as cubic segments
    /// `body(start, control1, control2, end)`: a level run from 20 pt beyond the left edge,
    /// Catmull-Rom cubics through the samples spread across the centred window and one spacing
    /// past each end (at the end value, so the curve eases into the runs without a kink), then a
    /// level run to 20 pt beyond the right edge. Across the window it is the graph of
    /// `seam(at:)`. Allocates nothing.
    static func forEachSeamSegment(of samples: [Double], metrics: StageMetrics, width: Double,
                                   _ body: (Vec2, Vec2, Vec2, Vec2) -> Void) {
        let count = samples.count
        let right = max(metrics.width, width) + 20
        func line(_ a: Vec2, _ b: Vec2) { body(a, a + (b - a) / 3, b - (b - a) / 3, b) }
        guard count > 1 else {
            let y = metrics.y(samples.first ?? 0.5)
            line(Vec2(-20, y), Vec2(right, y))
            return
        }
        // Point i sits at u = i/(n − 1) for any i, holding the end values beyond the samples.
        func point(_ i: Int) -> Vec2 {
            Vec2(metrics.x(Double(i) / Double(count - 1)), metrics.y(samples[min(max(i, 0), count - 1)]))
        }
        line(Vec2(-20, point(-1).y), point(-1))
        for i in -1..<count {
            let (c1, c2) = CatmullRom.controls(point(i - 1), point(i), point(i + 1), point(i + 2))
            body(point(i), c1, c2, point(i + 1))
        }
        line(point(count), Vec2(right, point(count).y))
    }

    /// The live seam at `u` (band fraction), as drawn: Catmull-Rom through the samples.
    func seam(at u: Double) -> Double { CatmullRom.sample(picture.seam, at: u) }

    /// A stable FNV-1a hash over the bit patterns of everything drawn, for the determinism checks.
    func digest() -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(bits: UInt64) {
            for shift in stride(from: 0, to: 64, by: 8) {
                hash ^= (bits >> UInt64(shift)) & 0xFF
                hash &*= 0x0000_0100_0000_01B3
            }
        }
        func mix(_ value: Double) { mix(bits: value.bitPattern) }
        func mix(_ picture: StagePicture) {
            mix(bits: UInt64(picture.seam.count))
            for v in picture.seam { mix(v) }
            mix(bits: picture.dominant == .angel ? 1 : 2)
            mix(picture.shadow)
            for c in DuoCharacter.allCases {
                picture.faces[c].forEachValue { mix($0) }
            }
        }
        mix(time)
        mix(picture)
        if let fade = crossFade {
            mix(bits: 3)
            mix(fade.progress)
            mix(fade.from)
        }
        return hash
    }
}

/// The stage's simulation: Foundation only, fixed 240-Hz substeps, seeded. It turns timestamped
/// inputs and per-substep mouth drives into `StageFrame`s, decides the layout key, and reports
/// the frame-rate tier and when it next needs to wake.
struct StageSimulation: Sendable {
    static let debounce = 0.2
    static let releaseHold = 0.25
    static let crossFadeDuration = 0.25
    static let ambientTimeout = 60.0
    static let pauseAfter = 0.6
    /// The idle drift flows this long after the last input or the app's return, then settles
    /// into its still S-curve so the stage can sleep.
    static let driftTimeout = 180.0

    /// Whether the idle drift may flow at `t`: within its timeout, and never under Reduce Motion.
    private func driftFlows(at t: Double) -> Bool {
        !mode.reduceMotion && t - max(lastInputChange, activatedAt) < Self.driftTimeout
    }

    private enum Queued: Sendable {
        case inputs(StageInputs)
        case mode(StageMode)
    }

    let seed: UInt64
    let options: SeamRig.Options
    private(set) var metrics: StageMetrics
    private(set) var mode: StageMode
    private(set) var inputs = StageInputs()
    private(set) var stepper: FixedStepper
    private(set) var seam: SeamRig
    private(set) var faces: PerCharacter<FaceRig>
    private(set) var directors: PerCharacter<CharacterDirector>
    private var stageRandom: SplitMix64
    private(set) var layout: StageLayout
    private var bubbleHeights: [DuoCharacter: Double] = [:]
    private var pillHeight = 0.0
    /// The heights `layout` was solved with.
    private var solvedHeights: [DuoCharacter: Double] = [:]
    private var solvedPillHeight = 0.0
    private var queue: [(time: Double, item: Queued)] = []

    /// Who holds the floor after the debounce.
    private(set) var stageFloor: DuoCharacter?
    private(set) var preset = StagePreset.neutral
    private var debounce: (from: DuoCharacter, deadline: Double)?
    private var releaseAt: Double?
    private var releaseFrom: DuoCharacter?
    private var awaitingLaunch = false
    /// The angel holds her launch stretch (sy 1.08).
    private var stretching = false
    /// Who waits for their slot to clear before their bubble or capsule shows: after a handover
    /// the speaker's bubble and the writing listener's capsule; a bubble appearing where its
    /// character's face still is; and a caption whose slot moves across its face. A bubble never
    /// shows over a face or sweeps across it.
    private(set) var pendingSlots: Set<DuoCharacter> = []
    /// Each pending slot's wait.
    private var holds: [DuoCharacter: SlotHold] = [:]
    private(set) var impactAt: Double?
    private var motionStart: Double?
    private var interruptedAt: Double?
    private var exchangeEndedAt: Double?
    private var lastSpeaker: DuoCharacter?
    private var addressedAt = PerCharacter<Double?>(angel: nil, devil: nil)
    private var lastInputChange: Double
    /// When the scene last became active: the idle drift flows again from then.
    private var activatedAt = 0.0
    private var quietSince: Double?
    private(set) var paused = false
    /// When the current pause began (0.6 s after the speaker fell silent).
    private var pausedAt: Double?
    /// Who the floor holder's line was for, kept after the floor ends for the verdict.
    private var lineAddressed: Set<DuoCharacter> = []
    /// Events the directors have yet to hear.
    private var unheard: [StageEventRecord] = []
    /// `skip(to:)` is moving sim time.
    private var skipping = false
    private var pushBacks = 0
    private var lastPushBack = -Double.infinity
    private var nextPeek: Double?
    private var crossFade: (from: StagePicture, start: Double)?
    private var drives = PerCharacter<MouthDrive?>(angel: nil, devil: nil)
    /// Each speaker's flavour for the current sentence, from its caption's cues.
    private(set) var moods = PerCharacter<TalkingMood>(angel: .none, devil: .none)
    /// The launch intro, while it plays or the faces wait unseen for it.
    private(set) var intro: StageIntro?
    /// The intro has begun: it plays once.
    private var introduced = false
    /// Fixed faces for stills (the expression gallery); nil follows the director.
    var stills = PerCharacter<FaceStill?>(angel: nil, devil: nil)
    private var events: [StageEventRecord] = []
    /// The last drained events' buffer, reused by the next drain once the caller lets go.
    private var drainedEvents: [StageEventRecord] = []
    private var wasQuiet = true
    private var lastRequest = -Double.infinity
    /// The human's microphone level this frame, while their words show.
    private(set) var userLevel: Double?
    private(set) var frame: StageFrame
    /// The seam samples of the frame before last, reused for the next frame so that a caller
    /// holding only the latest frame lets the stage draw without allocating.
    private var spareSeam: [Double] = []

    init(seed: UInt64, metrics: StageMetrics, mode: StageMode = StageMode(), options: SeamRig.Options = .standard,
         at time: Double = 0) {
        self.seed = seed
        self.options = options
        self.metrics = metrics
        self.mode = mode
        stepper = FixedStepper(time: time)
        let start = stepper.time
        lastInputChange = start
        stageRandom = SplitMix64(seed: seed, stream: .stage)
        layout = StageLayout.solve(key: StageLayoutKey(), metrics: metrics)
        seam = SeamRig(shape: layout.seam, options: options, at: start)
        faces = PerCharacter(angel: FaceRig(.angel, placement: layout.faces.angel),
                             devil: FaceRig(.devil, placement: layout.faces.devil))
        directors = PerCharacter(angel: CharacterDirector(.angel, seed: seed, at: start),
                                 devil: CharacterDirector(.devil, seed: seed, at: start))
        frame = StageFrame(time: start, picture: StagePicture(seam: [], dominant: .angel, shadow: 0,
                                                               faces: PerCharacter(angel: faces.angel.pose(),
                                                                                   devil: faces.devil.pose())))
        events.reserveCapacity(64)
        drainedEvents.reserveCapacity(64)
        unheard.reserveCapacity(16)
        refreshFrame()
    }

    var time: Double { stepper.time }
    var roles: PerCharacter<CharacterRole> { PerCharacter(angel: directors.angel.role, devil: directors.devil.role) }
    /// Preset changes (handovers, releases, interruptions, leans) snap and cross-fade: under
    /// Reduce Motion and with "Prefer Cross-Fade Transitions". Only Reduce Motion also snaps
    /// every other change and stills beats, lean-ins, blinks and ambient motion.
    private var crossFades: Bool { mode.reduceMotion || mode.crossFadeOnly }

    // MARK: Inputs

    /// Queues `inputs` for the first substep boundary at or after `time`.
    mutating func receive(_ inputs: StageInputs, at time: Double) { enqueue(.inputs(inputs), at: time) }

    /// Queues a mode change for the first substep boundary at or after `time`.
    mutating func receive(_ mode: StageMode, at time: Double) { enqueue(.mode(mode), at: time) }

    private mutating func enqueue(_ item: Queued, at time: Double) {
        let index = queue.firstIndex { $0.time > time } ?? queue.count
        queue.insert((time, item), at: index)
    }

    /// New geometry or measured heights: the layout is solved again and springs retarget.
    mutating func update(metrics: StageMetrics, bubbleHeights: [DuoCharacter: Double], pillHeight: Double) {
        guard metrics != self.metrics || bubbleHeights != self.bubbleHeights || pillHeight != self.pillHeight else {
            return
        }
        self.metrics = metrics
        self.bubbleHeights = bubbleHeights
        self.pillHeight = pillHeight
        let before = mode.reduceMotion ? currentPicture() : nil
        resolveLayout()
        applyLayout()
        if let before { snapIfNeeded(from: before) }
        refreshFrame()
    }

    /// Events since the last call, oldest first. Draining allocates nothing when there are no
    /// events, nor when the caller has let go of the previous drain's array.
    mutating func drainEvents() -> [StageEventRecord] {
        guard !events.isEmpty else { return [] }
        var drained = drainedEvents
        drainedEvents = []
        drained.removeAll(keepingCapacity: true)
        swap(&drained, &events)
        drainedEvents = drained
        return drained
    }

    // MARK: Advancing

    /// Advances to the last substep boundary at or before `time`, at most 24 substeps (0.1 s)
    /// of motion; settled stretches are skipped exactly. A time at or before the last request
    /// returns the cached frame. While the scene is inactive, sim time stands still and queued
    /// items still apply.
    @discardableResult
    mutating func advance<M: MouthSource>(to time: Double, mouths: M, userLevel: Double? = nil) -> StageFrame {
        guard time > lastRequest else { return frame }
        lastRequest = time
        self.userLevel = userLevel
        let target = FixedStepper.index(atOrBefore: time)
        applyDue()
        var steps = 0
        while stepper.index < target, steps < FixedStepper.maxSteps, mode.sceneActive {
            if isQuiet {
                var wake = nextWake ?? .infinity
                if let queued = queue.first?.time { wake = min(wake, queued) }
                let stop = wake.isFinite ? min(target, FixedStepper.index(atOrAfter: wake)) : target
                if stop > stepper.index {
                    stepper.skip(to: Double(stop) / FixedStepper.rate)
                    seam.skip(to: stepper.time)
                    applyDue()
                    continue
                }
            }
            substep(mouths: mouths)
            steps += 1
            applyDue()
        }
        // While the scene is inactive the driver's clock offset grows instead, so later
        // requests continue from the frozen sim time.
        if !mode.sceneActive { lastRequest = stepper.time }
        refreshFrame()
        return frame
    }

    /// Moves sim time to `time` without integrating, for a settled stage (`needsFrames` false).
    /// The stage's own deadlines on the way (the floor debounce, the release hold, role changes,
    /// slots, fades and queued items) are met at their substep boundaries, and the skip stops
    /// at one that sets the stage moving. Agenda items that fall due on the way are rescheduled
    /// with the time they had left, so waking never bursts. A stage that is not settled
    /// advances instead.
    mutating func skip(to time: Double) {
        guard mode.sceneActive else { return }
        guard !needsFrames else {
            advance(to: time, mouths: SilentMouths(), userLevel: userLevel)
            return
        }
        let end = FixedStepper.index(atOrBefore: time)
        skipping = true
        defer { skipping = false }
        while stepper.index < end {
            var deadline = wake(after: stepper.time + 1e-9, agenda: false) ?? .infinity
            if let queued = queue.first?.time { deadline = min(deadline, queued) }
            let stop = deadline.isFinite ? min(end, FixedStepper.index(atOrAfter: deadline)) : end
            let from = stepper.time
            stepper.skip(to: Double(stop) / FixedStepper.rate)
            seam.skip(to: stepper.time)
            rescheduleAgenda(from: from)
            guard stop < end || deadline <= time else { break }
            applyDue()
            if needsFrames { break }
        }
        lastRequest = max(lastRequest, stepper.time)
        refreshFrame()
    }

    /// Agenda items that fell due while sim time moved from `from` without stepping start from
    /// now with the time they had left.
    private mutating func rescheduleAgenda(from: Double) {
        let now = stepper.time
        guard now > from else { return }
        let movedAngel = directors.angel.reschedule(from: from, to: now)
        let movedDevil = directors.devil.reschedule(from: from, to: now)
        // At most one gesture on the first frame after a skip: when a rescheduled blink lands
        // within 0.25 s of the other character's, the later one waits.
        if movedAngel || movedDevil, let a = directors.angel.nextBlink, let d = directors.devil.nextBlink,
           abs(a - d) < Self.skipSpacing {
            if a <= d {
                directors.devil.postponeBlink(until: a + Self.skipSpacing)
            } else {
                directors.angel.postponeBlink(until: d + Self.skipSpacing)
            }
        }
        if let peek = nextPeek, peek < now { nextPeek = now + max(0, peek - from) }
    }

    /// The least time between the two characters' first gestures after a skip.
    static let skipSpacing = 0.25

    /// Applies queued items and timers due at the current boundary.
    private mutating func applyDue() {
        while let first = queue.first, FixedStepper.index(atOrAfter: first.time) <= stepper.index {
            queue.removeFirst()
            switch first.item {
            case .inputs(let inputs): apply(inputs)
            case .mode(let mode): apply(mode)
            }
        }
        runTimers()
    }

    private mutating func substep<M: MouthSource>(mouths: M) {
        let t = stepper.time, next = t + SpringSpec.step
        let reduceMotion = mode.reduceMotion
        for c in DuoCharacter.allCases {
            drives[c] = inputs.talking.contains(c) ? mouths.drive(c, at: next) : nil
        }
        detectPause(at: t)

        var drive = SeamRig.Drive()
        drive.energyAngel = reduceMotion ? 0 : faces.angel.energy
        drive.energyDevil = reduceMotion ? 0 : faces.devil.energy
        drive.devilSpeaking = stageFloor == .devil
        drive.devilPaused = paused
        drive.breathing = inputs.active && t - lastInputChange < Self.ambientTimeout
        drive.drifting = driftFlows(at: t)
        drive.reduceMotion = reduceMotion
        let seamEvents = seam.step(from: t, drive: drive)
        if seamEvents.launched { launch() }
        if let c = seamEvents.flipped { record(.flipped(c), at: seam.time) }
        if let strength = seamEvents.impact { impact(strength: strength, at: seam.time) }

        if stretching, !seam.isStretching {
            stretching = false
            faces.angel.setHold(nil)
        }
        for c in DuoCharacter.allCases {
            let speaking = stageFloor == c
            // The release hold keeps the faces as they were; the afterglow follows the release.
            if releaseAt == nil {
                faces[c].direct(directive(for: c))
                faces[c].ride = speaking && !awaitingLaunch
                    ? 0.35 * (seam.value(at: 0.5) - layout.seam.value(at: 0.5)) * metrics.bandHeight : 0
            }
            let room = faces[c].contact == nil ? nil : liveRoom(for: c)
            let beat = faces[c].step(at: t, drive: drives[c], speaking: speaking, room: room,
                                     beats: !reduceMotion && options.pulses)
            if let strength = beat, !reduceMotion { self.beat(c, strength: strength, at: next) }
            faces[c].gestureShake = directors[c].shake(at: next)
        }
        stepper.skip(to: next)
        if reduceMotion { settleSprings() }
        let quiet = isQuiet
        if quiet {
            settleSprings()
            if !wasQuiet { record(.settled, at: next) }
        }
        wasQuiet = quiet
    }

    // MARK: Input handling

    private mutating func apply(_ new: StageInputs) {
        let old = inputs
        guard new != old else { return }
        let t = stepper.time
        let before = crossFades ? currentPicture() : nil
        let rolesBefore = roles, presetBefore = preset
        inputs = new
        lastInputChange = t
        seam.setDriftFlowing(driftFlows(at: t))
        // A conversation starting hands the intro over to it, letting a shover's floor go before
        // the conversation's own floor and leans apply.
        if intro != nil, new != StageInputs() { handOverIntro(at: t) }
        if new.floor != nil { lineAddressed = new.addressed }
        if new.userText != nil, old.userText == nil, !mode.reduceMotion {
            // The human starts speaking: a dozing face wakes with a start.
            for c in DuoCharacter.allCases where directors[c].role == .dozing { faces[c].react(.startle, at: t) }
        }

        let interrupted = new.interruptions != old.interruptions
        if interrupted {
            interruptedAt = t
            record(.interrupted, at: t)
        }
        if new.active != old.active { record(.activeChanged(new.active), at: t) }
        for c in DuoCharacter.allCases {
            if new.addressed.contains(c), !old.addressed.contains(c) { addressedAt[c] = t }
            if !new.addressed.contains(c) { addressedAt[c] = nil }
        }
        if new.addressed != old.addressed { record(.addressedChanged(new.addressed), at: t) }

        var handedOver = false
        if new.floor != old.floor || (interrupted && new.floor == nil) {
            handedOver = floorChanged(to: new.floor, interrupted: interrupted, at: t)
        }
        for c in DuoCharacter.allCases {
            if let text = new.captions[c], !text.isEmpty, text != old.captions[c] {
                let cues = CaptionCues.classify(text, speaker: c)
                record(.captionStarted(c, text, cues), at: t)
                if c == stageFloor { moods[c] = Self.mood(for: cues) }
                if c == stageFloor, !handedOver, !mode.reduceMotion {
                    // The same speaker's next sentence: a lean-in, never a new handover.
                    faces[c].kickScale(0.4)
                    seam.kickPulse(0.01)
                }
            }
            if new.thinking.contains(c), !old.thinking.contains(c) { record(.thinkingStarted(c), at: t) }
            if !new.thinking.contains(c), old.thinking.contains(c) { record(.thinkingStopped(c), at: t) }
            if new.talking.contains(c), !old.talking.contains(c) { record(.talkingStarted(c), at: t) }
            if !new.talking.contains(c), old.talking.contains(c) { record(.talkingStopped(c), at: t) }
        }
        switch (old.userText, new.userText) {
        case (nil, .some): record(.userStarted, at: t)
        case (.some(let a), .some(let b)) where a != b: record(.userUpdated, at: t)
        case (.some, nil): record(.userEnded, at: t)
        default: break
        }
        if new.userFinal, !old.userFinal, let text = new.userText {
            record(.userFinal(text, CaptionCues.classify(text, speaker: nil)), at: t)
        }

        if stageFloor == nil, debounce == nil, releaseAt == nil {
            let lean = StagePreset.resolve(floor: nil, addressed: new.addressed)
            if lean != preset { beginLean(lean, at: t) }
        }
        if resolveLayout() { applyLayout() }
        resolveRoles(at: t)
        dispatchHeard()
        if let before {
            if mode.reduceMotion {
                snapIfNeeded(from: before, rolesChanged: roles != rolesBefore)
            } else if preset != presetBefore {
                // Prefer Cross-Fade Transitions: the new preset was snapped; fade to it.
                startFade(from: before)
            }
        }
    }

    /// Turning Reduce Motion on snaps to the held pose (the wave at its resting phase, the seam
    /// unrelaxed, the intro over) with one cross-fade. Other mode changes leave the motion alone.
    private mutating func apply(_ new: StageMode) {
        guard new != mode else { return }
        let before = new.reduceMotion && !mode.reduceMotion ? currentPicture() : nil
        if new.sceneActive, !mode.sceneActive { activatedAt = stepper.time }
        mode = new
        seam.setDriftFlowing(driftFlows(at: stepper.time))
        if let before {
            finishIntro()
            settleAll()
            startFade(from: before)
        }
    }

    /// Handles a floor change; true when a handover started.
    private mutating func floorChanged(to floor: DuoCharacter?, interrupted: Bool, at t: Double) -> Bool {
        if let floor {
            debounce = nil
            releaseAt = nil
            let previous = stageFloor
            if floor == previous {
                // The speaker took the floor back within the debounce: a line starts.
                resetPause()
                return false
            }
            stageFloor = floor
            record(.floorChanged(from: previous, to: floor), at: t)
            if preset.speaker == floor {
                // The same speaker took the floor back during the release hold, before the seam
                // moved: a line starts, so the seam stops relaxing.
                resetPause()
                return false
            }
            handover(to: floor, from: preset.speaker, at: t)
            return true
        }
        if interrupted {
            let from = stageFloor ?? debounce?.from
            debounce = nil
            releaseAt = nil
            stageFloor = nil
            if let from { record(.floorChanged(from: from, to: nil), at: t) }
            lastSpeaker = from ?? lastSpeaker
            interrupt(at: t)
        } else if let from = stageFloor {
            debounce = (from, t + Self.debounce)
        }
        return false
    }

    // MARK: Choreography

    /// The floor goes to `speaker`; the idle drift gives way on `driftSpec`.
    private mutating func handover(to speaker: DuoCharacter, from previous: DuoCharacter?, at t: Double,
                                   driftSpec: SpringSpec = .collapse) {
        moods = PerCharacter(angel: .none, devil: .none)
        motionStart = t
        impactAt = nil
        pendingSlots = Set(DuoCharacter.allCases)
        // The handover's slots wait at least 0.3 s, for the seam's launch; a character whose
        // bubble was showing waits until the caption layer has let it go, so their new bubble
        // shows afresh in its slot rather than gliding there from the old one.
        for c in DuoCharacter.allCases {
            let wait = layout.bubbles[c] != nil ? max(0.30, Self.captionFadeOut) : 0.30
            holds[c] = SlotHold(since: t, earliest: t + wait)
        }
        resetPause()
        pushBacks = 0
        preset = speaker == .angel ? .angelFloor : .devilFloor
        resolveLayout()
        seam.limits = layout.limits
        let listener: DuoCharacter = speaker == .angel ? .devil : .angel
        if crossFades {
            seam.jump(to: layout.seam, dominant: speaker)
            awaitingLaunch = false
            faces[speaker].endContact(kick: 0)
            faces[listener].beginContact(kick: 0)
            placeFaces()
            settleAll()
            return
        }
        seam.beginHandover(to: speaker, from: previous, shape: layout.seam, at: t, driftSpec: driftSpec)
        awaitingLaunch = true
        endStretch()
        if faces[speaker].contact != nil { faces[speaker].endContact(kick: 0) }
        faces[speaker].setHold(speaker == .angel ? 0.92 : 0.74)
    }

    /// The handover launches: the faces head for their new places.
    private mutating func launch() {
        guard let speaker = stageFloor ?? preset.speaker else { return }
        awaitingLaunch = false
        placeFaces()
        if speaker == .angel {
            faces.angel.setHold(1.08)
            stretching = true
        } else {
            faces.devil.setHold(nil)
            faces.devil.kickSquash(3.0)
            faces.devil.kickAnchor(Vec2(0, -60 * faces.devil.scale.value))
        }
    }

    private mutating func impact(strength: Double, at t: Double) {
        guard let speaker = preset.speaker, let listener = preset.listener else { return }
        impactAt = t
        faces[listener].beginContact(kick: (listener == .devil ? -2.5 : -1.2) * strength)
        faces[listener].react(listener == .devil ? .oof : .eep, at: t, strength: strength)
        seam.impulse(at: seam.strikePoint(for: speaker), velocity: (speaker == .angel ? 0.35 : -0.35) * strength)
        record(.impact(listener, strength), at: t)
    }

    private mutating func beat(_ c: DuoCharacter, strength: Double, at t: Double) {
        record(.beat(c, strength), at: t)
        faces[c].kickAnchor(Vec2(0, -22 * strength * faces[c].scale.value))
        faces[c].kickSquash(0.6)
        faces[c].beat(strength: strength)
        guard stageFloor == c else { return }
        seam.kickPulse(0.10 * strength)
        seam.impulse(at: seam.strikePoint(for: c), velocity: (c == .angel ? 0.02 : -0.02) * strength)
    }

    /// The floor went to nil and stayed there through the debounce.
    private mutating func endFloor(from speaker: DuoCharacter, at t: Double) {
        stageFloor = nil
        resetPause(relax: false)
        record(.floorChanged(from: speaker, to: nil), at: t)
        lastSpeaker = speaker
        exchangeEndedAt = t
        record(.exchangeEnded, at: t)
        releaseAt = t + Self.releaseHold
        releaseFrom = speaker
        if resolveLayout() { applyLayout() }
    }

    private mutating func release(at t: Double) {
        let former = releaseFrom ?? preset.speaker ?? .angel
        let freed: DuoCharacter = former == .angel ? .devil : .angel
        preset = StagePreset.resolve(floor: nil, addressed: inputs.addressed)
        pendingSlots = []
        holds = [:]
        resolveLayout()
        seam.limits = layout.limits
        if crossFades {
            seam.jump(to: layout.seam, dominant: seam.dominant)
            faces[freed].endContact(kick: 0)
            placeFaces()
            settleAll()
            return
        }
        motionStart = t
        seam.beginRelease(to: layout.seam, at: t)
        stretching = false
        faces[freed].endContact(kick: 2.2)
        faces[freed].react(.popUp, at: t)
        faces[freed].kickTilt(0.5)
        faces[freed].kickTilt(-0.5, at: t + 0.18)
        faces[former].setHold(nil)
        faces[former].kickSquash(-0.4)
        placeFaces()
    }

    private mutating func interrupt(at t: Double) {
        preset = StagePreset.resolve(floor: nil, addressed: inputs.addressed)
        pendingSlots = []
        holds = [:]
        awaitingLaunch = false
        resetPause()
        resolveLayout()
        seam.limits = layout.limits
        for c in DuoCharacter.allCases where faces[c].contact != nil { faces[c].endContact(kick: 0) }
        if crossFades {
            seam.jump(to: layout.seam, dominant: seam.dominant)
            placeFaces()
            settleAll()
            return
        }
        motionStart = t
        seam.beginInterrupt(to: layout.seam, at: t)
        stretching = false
        for c in DuoCharacter.allCases {
            faces[c].setHold(nil)
            faces[c].kickSquash(1.2)
            faces[c].react(.startle, at: t)
        }
        placeFaces()
    }

    private mutating func beginLean(_ lean: StagePreset, at t: Double) {
        preset = lean
        resolveLayout()
        seam.limits = layout.limits
        if crossFades {
            seam.jump(to: layout.seam, dominant: seam.dominant)
            placeFaces()
            settleAll()
            return
        }
        seam.beginLean(to: layout.seam, at: t)
        placeFaces()
        if let addressed = lean == .leanAngel ? DuoCharacter.angel : lean == .leanDevil ? .devil : nil {
            faces[addressed].kickSquash(1.2)
        }
    }

    // MARK: Intro

    /// Holds the faces unseen until the intro begins.
    mutating func awaitIntro() {
        guard !introduced, intro == nil, inputs == StageInputs() else { return }
        intro = StageIntro()
        refreshFrame()
    }

    /// Plays the launch intro from `time`, once (`StageIntro`); a conversation already under way
    /// gets none. Under Reduce Motion the faces fade in instead, as every change of picture does.
    mutating func beginIntro(at time: Double) {
        guard !introduced else { return }
        introduced = true
        guard inputs == StageInputs() else {
            handOverIntro(at: stepper.time)
            return
        }
        let start = max(time, stepper.time)
        if mode.reduceMotion {
            var before = currentPicture()
            for c in DuoCharacter.allCases { before.faces[c].pop = .unseen }
            intro = nil
            crossFade = (before, start)
            refreshFrame()
            return
        }
        var intro = self.intro ?? StageIntro()
        intro.begin(at: start)
        self.intro = intro
        refreshFrame()
    }

    /// Runs the intro's beats due at `t`, and lets it go once it has played.
    private mutating func runIntro(at t: Double) {
        guard var intro else { return }
        while let beat = intro.beat(dueAt: t) {
            switch beat {
            case .pop(let c, let expression, let length):
                intro.popIn(c, at: t)
                directors[c].perform(.popIn, expression, at: t, for: length, atOther: false)
                startGestures(of: c, at: t)
                appear(c, at: t)
            case .look(let c, let gesture, let expression, let length):
                directors[c].perform(gesture, expression, at: t, for: length, atOther: true)
                startGestures(of: c, at: t)
            case .windUp(let c):
                faces[c].kickSquash(-1.2)
            case .shove(let c):
                // The shover takes the floor as a speaker does: the handover's windup, launch
                // and impact, the other squished against the seam, though nobody speaks. The
                // idle drift eases out rather than collapsing with the windup.
                let before = crossFades ? currentPicture() : nil
                handover(to: c, from: preset.speaker, at: t, driftSpec: .relax)
                if let before { startFade(from: before) }
                record(.gesture(c, .shove), at: t)
            case .squish(let c, let length):
                directors[c].perform(.squish, .squished, at: t, for: length, atOther: true)
                startGestures(of: c, at: t)
            case .letGo:
                let before = crossFades ? currentPicture() : nil
                releaseFrom = nil
                release(at: t)
                if let before { startFade(from: before) }
            }
        }
        self.intro = intro.start == nil || intro.isRunning(at: t) ? intro : nil
    }

    /// `c` pops in at `t`: unseen until now, the face takes its look at once.
    private mutating func appear(_ c: DuoCharacter, at t: Double) {
        faces[c].direct(directive(for: c))
        faces[c].settle()
        faces[c].react(.popIn, at: t)
    }

    /// A conversation starts during the intro: no more beats, a shover's floor is let go, and
    /// anyone not yet there pops in (under Reduce Motion, the snap's cross-fade shows them).
    private mutating func handOverIntro(at t: Double) {
        guard var intro else { return }
        introduced = true
        guard !mode.reduceMotion else {
            self.intro = nil
            return
        }
        let unseen = DuoCharacter.allCases.filter { intro.pops[$0] == nil }
        intro.handOver(at: t)
        self.intro = intro
        dropIntroFloor(at: t)
        for c in unseen {
            appear(c, at: t)
            record(.gesture(c, .popIn), at: t)
        }
    }

    /// Ends the intro at once, every face there: as Reduce Motion turns on, and for stills.
    private mutating func finishIntro() {
        guard intro != nil else { return }
        introduced = true
        intro = nil
        dropIntroFloor(at: stepper.time)
    }

    /// Springs back to nobody's floor if a shove holds one and no conversation does.
    private mutating func dropIntroFloor(at t: Double) {
        guard stageFloor == nil, preset.speaker != nil else { return }
        interrupt(at: t)
    }

    // MARK: Waiting

    /// The speaker's o < 0.2 for 0.6 s while holding the floor is a pause; speech resumes it.
    private mutating func detectPause(at t: Double) {
        guard let speaker = stageFloor else { return }
        let o = drives[speaker]?.openness ?? MouthDrive.rest.openness
        if o < 0.2 {
            let since = quietSince ?? t
            quietSince = since
            if !paused, t - since >= Self.pauseAfter - 1e-9 {
                paused = true
                pausedAt = t
                record(.pause(speaker), at: t)
                if !mode.reduceMotion { seam.setRelaxed(true) }
                let listener: DuoCharacter = speaker == .angel ? .devil : .angel
                if !mode.reduceMotion, inputs.thinking.contains(listener), pushBacks < 3, t - lastPushBack >= 2.5 {
                    // The listener writing next pushes back toward the speaker.
                    pushBacks += 1
                    lastPushBack = t
                    seam.kickPulse(-0.12)
                }
            }
        } else {
            quietSince = nil
            if paused {
                paused = false
                record(.resume(speaker), at: t)
                seam.setRelaxed(false)
            }
        }
    }

    /// A new handover ends the angel's launch stretch from the last one.
    private mutating func endStretch() {
        guard stretching else { return }
        stretching = false
        if faces.angel.contact == nil { faces.angel.setHold(nil) }
    }

    private mutating func resetPause(relax: Bool = true) {
        quietSince = nil
        paused = false
        if relax { seam.setRelaxed(false) }
    }

    // MARK: Timers

    private mutating func runTimers() {
        let t = stepper.time
        if let pending = debounce, t >= pending.deadline - 1e-9 {
            debounce = nil
            endFloor(from: pending.from, at: t)
        }
        if let at = releaseAt, t >= at - 1e-9 {
            releaseAt = nil
            let before = crossFades ? currentPicture() : nil
            release(at: t)
            if let before {
                if mode.reduceMotion { snapIfNeeded(from: before) } else { startFade(from: before) }
            }
        }
        for c in DuoCharacter.allCases {
            guard pendingSlots.contains(c), let hold = holds[c], t >= hold.earliest - 1e-9,
                  slotOpens(c, after: t - hold.since) else { continue }
            pendingSlots.remove(c)
            holds[c] = nil
            if c == preset.speaker || layout.bubbles[c] != nil || layout.capsules[c] != nil {
                record(.slotClear(c), at: t)
            }
        }
        if let fade = crossFade, t - fade.start >= Self.crossFadeDuration - 1e-9 { crossFade = nil }
        var resolved = directors
        let context = roleContext(at: t)
        var rolesChanged = false
        for c in DuoCharacter.allCases where resolved[c].resolve(context) { rolesChanged = true }
        if rolesChanged {
            let before = mode.reduceMotion ? currentPicture() : nil
            directors = resolved
            if let before { snapIfNeeded(from: before, rolesChanged: true) }
        }

        dispatchHeard()
        let allowed = !mode.reduceMotion
        for c in DuoCharacter.allCases {
            directors[c].runAgenda(context, allowed: allowed)
            startGestures(of: c, at: t)
        }
        if directors.angel.role == .dozing, directors.devil.role == .dozing, !mode.reduceMotion {
            if let peek = nextPeek {
                if t >= peek {
                    let c: DuoCharacter = stageRandom.sign() < 0 ? .angel : .devil
                    directors[c].startPeek(at: t)
                    record(.gesture(c, .peek), at: t)
                    nextPeek = t + stageRandom.uniform(in: 10...20)
                }
            } else {
                nextPeek = t + stageRandom.uniform(in: 10...20)
            }
        } else {
            nextPeek = nil
        }
        runIntro(at: t)
        // Directives follow role and agenda changes at once, so a sleeping stage wakes for them.
        // A skip leaves them for the next frame, as it does every other change of face, and the
        // afterglow's faces follow the release rather than starting in its hold.
        if !skipping, releaseAt == nil {
            for c in DuoCharacter.allCases { faces[c].direct(directive(for: c)) }
        }
    }

    /// Lets the directors hear the events recorded since they last did.
    private mutating func dispatchHeard() {
        guard !unheard.isEmpty else { return }
        let allowed = !mode.reduceMotion
        var index = 0
        while index < unheard.count {
            let record = unheard[index]
            index += 1
            let context = roleContext(at: record.time)
            let toPlayer = !lineAddressed.contains(context.lastSpeaker == .angel ? .devil : .angel)
            for c in DuoCharacter.allCases {
                directors[c].hear(record.event, at: record.time, context: context, lineToPlayer: toPlayer,
                                  allowed: allowed)
                startGestures(of: c, at: record.time)
            }
        }
        unheard.removeAll(keepingCapacity: true)
    }

    /// Records the gestures a director just started and gives the face their kicks.
    private mutating func startGestures(of c: DuoCharacter, at t: Double) {
        for gesture in directors[c].started {
            record(.gesture(c, gesture), at: t)
            switch gesture {
            case .nod: faces[c].react(.nod, at: t)
            case .shocked: faces[c].react(.shocked, at: t)
            case .huff: faces[c].react(.huff, at: t)
            case .laughAlong: faces[c].react(.laughAlong, at: t)
            case .eyeRoll: faces[c].react(.eyeRoll, at: t)
            default: break
            }
        }
    }

    private mutating func resolveRoles(at t: Double) {
        let context = roleContext(at: t)
        for c in DuoCharacter.allCases { _ = directors[c].resolve(context) }
    }

    private func roleContext(at t: Double) -> RoleContext {
        RoleContext(inputs: inputs, floor: stageFloor, time: t, lastInputChange: lastInputChange,
                    interruptedAt: interruptedAt, exchangeEndedAt: exchangeEndedAt, lastSpeaker: lastSpeaker,
                    addressedAt: addressedAt, pausedSince: paused ? pausedAt : nil,
                    userLevel: inputs.userText != nil ? userLevel : nil)
    }

    /// Whether a waiting slot may show `elapsed` s after it began waiting: once it is clear. A
    /// capsule shows by 0.6 s; a bubble by 0.6 s once its character's face is clear of it,
    /// whatever the seam, and by 1 s regardless.
    private func slotOpens(_ c: DuoCharacter, after elapsed: Double) -> Bool {
        if let capsule = layout.capsules[c]?.rect {
            // Past the overshoot's apex (the seam no longer heading for the listener), ≥ 6 pt
            // from the seam.
            let approaching = c == .devil ? seam.centreVelocity > 0 : seam.centreVelocity < 0
            return elapsed >= 0.60 - 1e-9 || !approaching && liveSeamDistance(to: capsule) >= 6
        }
        guard let rect = layout.bubbles[c]?.rect else { return true }
        if elapsed >= 1.0 - 1e-9 { return true }
        return faceIsClear(c, of: rect) && (elapsed >= 0.60 - 1e-9 || liveSeamDistance(to: rect) >= 8)
    }

    /// Whether `c`'s eyes, brows and mouth, as drawn now, are 6 pt from `rect`, or as clear of it
    /// as they are at rest where the layout had to bring them closer.
    private func faceIsClear(_ c: DuoCharacter, of rect: StageRect) -> Bool {
        let settled = layout.featureBox(c).distance(to: rect)
        return faces[c].drawnRect(FaceBoxes.features(c)).distance(to: rect) >= min(6, settled - 1)
    }

    /// Holds a bubble that appears where its character's face still is (a speaker's next line
    /// after the last caption expired, typing dots), or a caption whose slot moves to the other
    /// side of its face (the devil's, from above the dock to under the seam, as an exchange
    /// ends), until the face and the seam have cleared it. A moved caption also waits out
    /// `captionFadeOut`, so it shows afresh in its new slot instead of gliding there across the
    /// face; one that moves on its own side glides there with the face.
    private mutating func holdCaptionsInTheWay(from old: StageLayout) {
        let t = stepper.time
        for c in DuoCharacter.allCases where !pendingSlots.contains(c) {
            guard let to = layout.bubbles[c]?.rect else { continue }
            if let from = old.bubbles[c]?.rect {
                guard (from.midY < old.featureBox(c).midY) != (to.midY < layout.featureBox(c).midY) else { continue }
                holds[c] = SlotHold(since: t, earliest: t + Self.captionFadeOut)
            } else {
                guard !faceIsClear(c, of: to) else { continue }
                holds[c] = SlotHold(since: t, earliest: t)
            }
            pendingSlots.insert(c)
        }
    }

    /// How long the caption layer takes to let go of a bubble whose slot is taken away: its
    /// removal springs out over about 0.4 s, plus a frame. A bubble given back sooner glides on
    /// from where it was.
    static let captionFadeOut = 0.45

    /// The smallest vertical distance from the live seam to `rect` over its span (pt);
    /// negative when the seam crosses it.
    func liveSeamDistance(to rect: StageRect) -> Double {
        var distance = Double.infinity
        let steps = 24
        for i in 0...steps {
            let x = rect.minX + rect.width * Double(i) / Double(steps)
            let y = metrics.y(seam.value(at: metrics.u(x)))
            let gap = y >= rect.midY ? y - rect.maxY : rect.minY - y
            distance = min(distance, gap)
        }
        return distance
    }

    /// A squished listener's live room: floor minus the lowest seam over its face (devil), or
    /// the highest seam minus the ceiling (angel), over x ∈ ±100 fu.
    private func liveRoom(for c: DuoCharacter) -> Double? {
        let face = faces[c]
        guard let pin = face.placement.pin else { return nil }
        let half = 100 * face.scale.value
        var extreme = c == .devil ? -Double.infinity : Double.infinity
        for i in 0...8 {
            let x = metrics.width / 2 - half + 2 * half * Double(i) / 8
            let y = metrics.y(seam.value(at: metrics.u(x)))
            extreme = c == .devil ? max(extreme, y) : min(extreme, y)
        }
        return c == .devil ? pin.y - extreme : extreme - pin.y
    }

    // MARK: Layout

    private func makeKey() -> StageLayoutKey {
        var key = StageLayoutKey(preset: preset, lead: lastSpeaker ?? seam.dominant)
        key.pill = inputs.userText != nil
        if let speaker = preset.speaker {
            if let text = inputs.captions[speaker], !text.isEmpty { key.bubbles[speaker] = .caption }
            let listener: DuoCharacter = speaker == .angel ? .devil : .angel
            if inputs.thinking.contains(listener) { key.capsules = [listener] }
        } else {
            for c in DuoCharacter.allCases {
                if inputs.thinking.contains(c) {
                    key.bubbles[c] = .dots
                } else if let text = inputs.captions[c], !text.isEmpty {
                    key.bubbles[c] = .caption
                }
            }
        }
        return key
    }

    /// Solves the layout for the current key; true when it changed. The solver is pure, so an
    /// unchanged key, metrics and heights (say, the human's next word) keep the layout unsolved.
    @discardableResult
    private mutating func resolveLayout() -> Bool {
        let key = makeKey()
        if key == layout.key, metrics == layout.metrics, bubbleHeights == solvedHeights,
           pillHeight == solvedPillHeight {
            return false
        }
        let solved = StageLayout.solve(key: key, metrics: metrics, bubbleHeights: bubbleHeights,
                                       pillHeight: pillHeight)
        solvedHeights = bubbleHeights
        solvedPillHeight = pillHeight
        guard solved != layout else { return false }
        let old = layout
        layout = solved
        holdCaptionsInTheWay(from: old)
        return true
    }

    /// Retargets the seam and faces to the current layout without changing the preset.
    private mutating func applyLayout() {
        seam.limits = layout.limits
        if mode.reduceMotion {
            seam.jump(to: layout.seam, dominant: seam.dominant)
        } else {
            seam.retarget(layout.seam)
        }
        if !awaitingLaunch { placeFaces() }
        if mode.reduceMotion { settleAll() }
    }

    // MARK: Faces

    /// What each face shows this substep: the role's held expression, the speaker's mood, the
    /// gaze home and the ambient motion's weight.
    private func directive(for c: DuoCharacter) -> FaceDirective {
        let other: DuoCharacter = c == .angel ? .devil : .angel
        let role = directors[c].role
        var d = FaceDirective()
        let look = directors[c].look(roleContext(at: stepper.time))
        d.expression = look.expression ?? CharacterDirector.expression(for: role)
        if stageFloor == c { d.mood = paused && !mode.reduceMotion ? .waiting : moods[c] }
        d.gaze = mode.reduceMotion ? directors[c].home(roleContext(at: stepper.time), still: true) : look.gaze
        if !mode.reduceMotion {
            d.browDy = look.browDy
            d.browAngle = look.browAngle
            d.lidMin = look.lidMin
            d.scleraMin = look.scleraMin
            d.eyeOpen = look.eyeOpen
            d.tilt = look.tilt
            d.headDy = look.headDy
            if stageFloor == other, paused, inputs.thinking.contains(c) {
                // Ready: the listener writing next leans in while the speaker waits.
                d.eyeOpen += 0.08
                d.browDy -= 4
            }
        }
        d.talking = stageFloor == c && inputs.talking.contains(c)
        d.ambient = mode.reduceMotion ? 0 : seam.breath.value
        d.ceiling = metrics.bandTop - 6
        d.edges = 0...metrics.width
        d.reduceMotion = mode.reduceMotion
        if let still = stills[c] {
            d.still = still
            d.talking = still.talkOpen != nil
        }
        return d
    }

    /// The speaker's mood for a caption's cues: laugh, then excited, then asking.
    static func mood(for cues: Set<Cue>) -> TalkingMood {
        if cues.contains(.laugh) { return .laughing }
        if cues.contains(.exclaim) { return .excited }
        if cues.contains(.question) { return .asking }
        return .none
    }

    /// Holds a speaking mouth open for a still: the face shows `drive` as if it were sampled.
    mutating func holdMouth(_ drive: MouthDrive?, for c: DuoCharacter) {
        faces[c].hold(drive: drive)
        refreshFrame()
    }

    private mutating func placeFaces() {
        for c in DuoCharacter.allCases { faces[c].place(layout.faces[c], neutralScale: metrics.scale) }
    }

    // MARK: Settling

    /// Everything at rest: seam and faces settled, no gesture, fade, speech, intro or pending
    /// timer that needs frames.
    private var isQuiet: Bool {
        let t = stepper.time
        guard crossFade == nil, intro?.isRunning(at: t) != true, inputs.talking.isEmpty, !awaitingLaunch,
              stageFloor == nil || paused, seam.isSettled, faces.angel.isSettled, faces.devil.isSettled else {
            return false
        }
        return !directors.angel.isGesturing(at: t) && !directors.devil.isGesturing(at: t)
    }

    private mutating func settleSprings() {
        seam.settle()
        for c in DuoCharacter.allCases { faces[c].settle() }
    }

    /// Completes any choreography and snaps everything to its settled pose. Under Reduce Motion
    /// that is the held pose: unrelaxed, with the wave at its resting phase.
    mutating func settleAll() {
        if awaitingLaunch {
            awaitingLaunch = false
            placeFaces()
        }
        if mode.reduceMotion { seam.holdPose() }
        seam.settle()
        if let listener = preset.listener, faces[listener].contact == nil { faces[listener].beginContact(kick: 0) }
        for c in DuoCharacter.allCases { faces[c].direct(directive(for: c)) }
        stretching = false
        for c in DuoCharacter.allCases {
            faces[c].setHold(nil)
            faces[c].ride = 0
        }
        for _ in 0..<2 {
            for c in DuoCharacter.allCases {
                if faces[c].contact != nil {
                    _ = faces[c].step(at: stepper.time, drive: nil, speaking: false, room: liveRoom(for: c), beats: false)
                }
                faces[c].settle()
            }
        }
        refreshFrame()
    }

    /// A settled still: choreography and intro complete, the idle drift resting and every bubble
    /// shown.
    mutating func settleForStill() {
        finishIntro()
        seam.holdStill()
        settleAll()
        pendingSlots = []
        holds = [:]
        _ = drainEvents()
    }

    /// Reduce Motion: everything snaps, and a changed picture or held expression cross-fades
    /// from the previous one.
    private mutating func snapIfNeeded(from before: StagePicture, rolesChanged: Bool = false) {
        guard mode.reduceMotion else { return }
        settleAll()
        if !currentPicture().sameLayout(as: before) || rolesChanged { crossFade = (before, stepper.time) }
        refreshFrame()
    }

    /// Starts a cross-fade from `before` when the picture changed.
    private mutating func startFade(from before: StagePicture) {
        if !currentPicture().sameLayout(as: before) { crossFade = (before, stepper.time) }
        refreshFrame()
    }

    // MARK: Frames

    /// The picture now, in a fresh sample array (for event-time comparisons).
    private func currentPicture() -> StagePicture {
        var samples: [Double] = []
        seam.fill(&samples)
        return picture(seam: samples)
    }

    private func picture(seam samples: [Double]) -> StagePicture {
        let t = stepper.time
        // The idle drift and the breath move level about the resting centre: they cast no shadow.
        let centre = seam.value(at: 0.5) - seam.ambientValue(at: 0.5)
        return StagePicture(
            seam: samples, dominant: seam.dominant,
            shadow: RigMath.clamp(abs(centre - SeamShape.neutral.value(at: 0.5)) / 0.12, 0, 1),
            faces: PerCharacter(angel: faces.angel.pose(blink: directors.angel.blink(at: t),
                                                        reopen: directors.angel.reopen(at: t),
                                                        peek: directors.angel.peek(at: t),
                                                        pop: intro?.pop(.angel, at: t) ?? FacePop()),
                                devil: faces.devil.pose(blink: directors.devil.blink(at: t),
                                                        reopen: directors.devil.reopen(at: t),
                                                        peek: directors.devil.peek(at: t),
                                                        pop: intro?.pop(.devil, at: t) ?? FacePop())))
    }

    /// Rebuilds `frame`, filling the spare sample array in place: no per-frame allocation once
    /// the caller lets go of the frame before last.
    private mutating func refreshFrame() {
        var samples = spareSeam
        spareSeam = []
        seam.fill(&samples)
        let t = stepper.time
        let fade = crossFade.map {
            StageCrossFade(from: $0.from, progress: RigMath.clamp((t - $0.start) / Self.crossFadeDuration, 0, 1))
        }
        let next = StageFrame(time: t, picture: picture(seam: samples), crossFade: fade)
        spareSeam = frame.picture.seam
        frame = next
    }

    private mutating func record(_ event: StageEvent, at time: Double) {
        if events.count >= 512 { events.removeFirst(events.count - 511) }
        events.append(StageEventRecord(time: time, event: event))
        switch event {
        case .captionStarted, .exchangeEnded, .interrupted, .floorChanged, .userFinal:
            unheard.append(StageEventRecord(time: time, event: event))
        default:
            break
        }
    }

    // MARK: Pacing

    /// The stage needs frames: something moves or a gesture runs.
    var needsFrames: Bool { mode.sceneActive && !isQuiet }

    var activity: StageActivity {
        guard mode.sceneActive else { return .paused }
        let t = stepper.time
        if isQuiet {
            return directors.angel.role == .dozing && directors.devil.role == .dozing ? .dozing : .asleep
        }
        if !mode.reduceMotion {
            if intro?.isRunning(at: t) == true { return .transition }
            let moving = motionStart.map { t - $0 <= 1.6 } ?? false
            if (moving && !seam.isMotionSettled) || impactAt.map({ t - $0 < 0.8 }) == true
                || abs(seam.centreVelocity) > 0.05 {
                return .transition
            }
            let gesturing = directors.angel.isGesturing(at: t) || directors.devil.isGesturing(at: t)
            if inputs.talking.isEmpty, !gesturing, crossFade == nil, !awaitingLaunch, seam.isAmbientOnly,
               faces.angel.isSettled(ignoringGaze: true), faces.devil.isSettled(ignoringGaze: true) {
                return .ambient
            }
        }
        return .speech
    }

    /// The earliest sim time something is scheduled: agenda items, role changes, the floor
    /// debounce, the release hold, a pending slot, a pending pause, the intro's next beat and the
    /// end of ambient breath.
    var nextWake: Double? { wake(after: stepper.time - 1e-9, agenda: true) }

    /// The earliest scheduled time after `after`; agenda items (blinks, doze peeks) only when
    /// asked for.
    private func wake(after: Double, agenda: Bool) -> Double? {
        let context = roleContext(at: stepper.time)
        var earliest = Double.infinity
        func consider(_ time: Double?) {
            if let time, time > after, time < earliest { earliest = time }
        }
        for c in DuoCharacter.allCases {
            if agenda { consider(directors[c].nextAgendaItem) }
            consider(directors[c].roleDeadline(context))
        }
        if agenda { consider(nextPeek) }
        consider(debounce?.deadline)
        for c in pendingSlots {
            guard let hold = holds[c] else { continue }
            consider(hold.earliest)
            consider(hold.since + 0.60)
            consider(hold.since + 1.0)
        }
        consider(releaseAt)
        consider(intro?.nextBeat)
        if stageFloor != nil, !paused, let since = quietSince { consider(since + Self.pauseAfter) }
        consider(crossFade.map { $0.start + Self.crossFadeDuration })
        if inputs.active { consider(lastInputChange + Self.ambientTimeout) }
        return earliest.isFinite ? earliest : nil
    }

    /// The largest spring speed in the seam and faces (each in its own units).
    var maxSpringSpeed: Double { max(seam.maxSpringSpeed, faces.angel.maxSpringSpeed, faces.devil.maxSpringSpeed) }
}

// MARK: - Stills

/// The stage's settled poses (`KeyPoses` and the leans), for stills and the fidelity checks.
enum StagePose: String, CaseIterable, Sendable {
    case neutral
    case leanAngel
    case leanDevil
    case angelTalking
    case devilTalking

    /// The inputs that hold this pose; captions only when asked for.
    func inputs(captions: Bool = false) -> StageInputs {
        var inputs = StageInputs(active: true)
        switch self {
        case .neutral:
            // The exchange has ended: both last sentences stay up.
            if captions { inputs.captions = [.angel: "Deal?", .devil: "The sofa is so much comfier."] }
        case .leanAngel: inputs.addressed = [.angel]
        case .leanDevil: inputs.addressed = [.devil]
        case .angelTalking:
            inputs.floor = .angel
            if captions { inputs.captions[.angel] = "Go to the gym tonight." }
        case .devilTalking:
            inputs.floor = .devil
            inputs.addressed = [.angel]
            if captions { inputs.captions[.devil] = "Oh, please, Angel! The sofa is so much comfier." }
        }
        return inputs
    }
}

extension StageSimulation {
    /// `pose` settled, with no captions unless asked for.
    static func snapshot(pose: StagePose, metrics: StageMetrics, seed: UInt64 = 1, options: SeamRig.Options = .standard,
                         mode: StageMode = StageMode(), captions: Bool = false,
                         bubbleHeights: [DuoCharacter: Double] = [:]) -> StageSimulation {
        var sim = StageSimulation(seed: seed, metrics: metrics, mode: mode, options: options)
        sim.update(metrics: metrics, bubbleHeights: bubbleHeights, pillHeight: 0)
        sim.receive(pose.inputs(captions: captions), at: 0)
        sim.advance(to: 1e-6, mouths: SilentMouths())
        sim.settleForStill()
        return sim
    }

    /// `pose` settled with the speaker's mouth held open at `talkOpen` (ô).
    static func snapshot(pose: StagePose, metrics: StageMetrics, talkOpen: Double, seed: UInt64 = 1,
                         mode: StageMode = StageMode(), captions: Bool = false,
                         bubbleHeights: [DuoCharacter: Double] = [:]) -> StageSimulation {
        var sim = StageSimulation(seed: seed, metrics: metrics, mode: mode)
        sim.update(metrics: metrics, bubbleHeights: bubbleHeights, pillHeight: 0)
        var inputs = pose.inputs(captions: captions)
        if let speaker = inputs.floor { inputs.talking = [speaker] }
        sim.receive(inputs, at: 0)
        sim.advance(to: 1e-6, mouths: SilentMouths())
        sim.settleForStill()
        if let speaker = inputs.floor { sim.holdMouth(MouthDrive(talkOpen: talkOpen), for: speaker) }
        return sim
    }

    /// A gallery cell: both faces in the neutral layout with the cell's expressions, settled.
    static func snapshot(cell: GalleryCell, metrics: StageMetrics, seed: UInt64 = 1) -> StageSimulation {
        var sim = StageSimulation(seed: seed, metrics: metrics)
        sim.stills = PerCharacter(angel: cell.angel, devil: cell.devil)
        sim.receive(StagePose.neutral.inputs(), at: 0)
        sim.advance(to: 1e-6, mouths: SilentMouths())
        sim.settleForStill()
        for c in DuoCharacter.allCases {
            if let open = cell[c].talkOpen { sim.holdMouth(MouthDrive(talkOpen: open), for: c) }
        }
        return sim
    }
}

import SwiftUI
import UIKit

extension StageInputs {
    /// What the stage reads from the conversation. Reading the mouths' `isAnimating` registers
    /// observation, so audio starting changes the inputs and wakes the stage.
    @MainActor init(model: ConversationModel) {
        self.init()
        active = model.active
        preparing = model.preparing
        floor = model.floor
        addressed = model.addressed
        thinking = Set(DuoCharacter.allCases.filter(model.isThinking))
        captions = model.captions
        userText = model.userLine?.text
        userFinal = model.userLine?.isFinal ?? false
        talking = Set(DuoCharacter.allCases.filter { model.mouths[$0]?.isAnimating == true })
        interruptions = model.interruptions
    }
}

/// The talking characters' mouths, sampled once for a frame at its presentation time. Each
/// voice drives only its own character's mouth.
struct FrameMouths: MouthSource {
    private var drives = PerCharacter<MouthDrive?>(angel: nil, devil: nil)
    #if DEBUG
    /// Each drive's player time, for `--lipsync-trace`.
    private(set) var times = PerCharacter<Double?>(angel: nil, devil: nil)
    #endif

    @MainActor init(model: ConversationModel, talking: Set<DuoCharacter>, ahead: Double) {
        for c in talking {
            let pose = model.mouthPose(for: c, ahead: ahead)
            drives[c] = MouthDrive(openness: pose.openness, width: pose.width, rounding: pose.rounding)
            #if DEBUG
            times[c] = model.mouths[c]?.lastSampleTime
            #endif
        }
    }

    #if DEBUG
    /// A scripted conversation's synthetic mouths `time` seconds into it (`--stage-script`).
    init(script: StageScript, at time: Double, talking: Set<DuoCharacter>) {
        for c in talking { drives[c] = script.drive(c, at: time) ?? .rest }
    }
    #endif

    func drive(_ character: DuoCharacter, at simTime: Double) -> MouthDrive? { drives[character] }
}

/// Runs the stage's simulation on the display's clock: timestamped inputs, the frame tiers
/// (display rate during handovers, 60 Hz for speech, 30 Hz ambient), sleeping until the next
/// scheduled wake when everything has settled, and a frozen clock while the scene is inactive.
/// The TimelineView's closure calls `frame(at:mouths:userLevel:)`, which touches only unobserved
/// storage; the observed properties change on events, from a deferred task.
@MainActor @Observable
final class StageDriver {
    /// Frames are wanted; false while asleep, dozing or paused.
    private(set) var running = true
    /// The frame tier's minimum interval; nil for the display's rate.
    private(set) var frameInterval: Double?
    /// The settled layout the captions and accessibility elements are placed from.
    private(set) var layout: StageLayout
    /// Characters whose bubble or capsule waits for the seam to clear its slot.
    private(set) var pendingSlots: Set<DuoCharacter> = []
    /// Each character's held expression, for VoiceOver's More Content.
    private(set) var held = PerCharacter(angel: FaceExpression.neutral, devil: .neutral)
    /// Changes whenever the stage goes to sleep with a new wake time.
    private(set) var wakeToken = 0
    /// The launch intro is playing, or about to on the first frame: the microphone waits for it.
    private(set) var introPlaying = true
    /// The intro's logo shows (`StageIntro.logo`).
    private(set) var logoShown = false

    @ObservationIgnored private var sim: StageSimulation
    @ObservationIgnored private let seed: UInt64
    /// Sim time is uptime − offset; the offset grows while the scene is inactive and by each
    /// hitch's excess over 0.1 s.
    @ObservationIgnored private var offset: Double
    /// The last frame's uptime while frames run continuously; nil after sleeping.
    @ObservationIgnored private var lastFrameUptime: Double?
    @ObservationIgnored private var suspendedAt: Double?
    @ObservationIgnored private var wakeUptime: Double?
    @ObservationIgnored private var publishScheduled = false
    @ObservationIgnored private var metrics: StageMetrics?
    @ObservationIgnored private var bubbleHeights: [DuoCharacter: Double] = [:]
    @ObservationIgnored private var bubbleKinds: [DuoCharacter: BubbleKind] = [:]
    @ObservationIgnored private var pillHeight = 0.0
    @ObservationIgnored private var still: (pose: StagePose, captions: Bool)?
    /// The Reduce Motion and cross-fade preference last asked for. Suspending and resuming
    /// change only its `sceneActive`, so a preference changed in Settings while the app was in
    /// the background holds when it comes back.
    @ObservationIgnored private var requestedMode = StageMode()
    /// Whether the conversation has given the stage anything to show yet; until then, and while
    /// the header and footer are unmeasured, new geometry snaps instead of springing.
    @ObservationIgnored private var engaged = false
    /// The header and footer have been measured once: later geometry springs while the intro plays.
    @ObservationIgnored private var measured = false
    /// The stage has drawn its first frame, where the intro begins.
    @ObservationIgnored private var appeared = false
    /// The launch intro has begun on a stage: it plays once per launch.
    private static var introduced = false
    /// The frame interval the next publish applies, and since when a slower tier has been asked
    /// for: the stage only slows after asking for 0.3 s, so the tier never flickers.
    @ObservationIgnored private var tierInterval: Double?
    @ObservationIgnored private var slowerSince: Double?
    /// The stage slept since the tier was last chosen, so the next one applies at once.
    @ObservationIgnored private var tierAsleep = true
    #if DEBUG
    @ObservationIgnored private let trace: Bool
    @ObservationIgnored private var traceWindow = (start: 0.0, frames: 0)
    #endif

    init(seed: UInt64, trace: Bool = false) {
        self.seed = seed
        #if DEBUG
        self.trace = trace
        #endif
        offset = Self.uptime
        let placeholder = StageMetrics.iPhone18Pro
        sim = StageSimulation(seed: seed, metrics: placeholder)
        layout = sim.layout
    }

    static var uptime: Double { ProcessInfo.processInfo.systemUptime }

    /// The stage seconds a frame is presented after it is built: the frame interval.
    var presentationLead: Double { frameInterval ?? 1.0 / 120 }

    private var simNow: Double { (suspendedAt ?? Self.uptime) - offset }

    /// Holds a settled pose (`--stage-pose`) with the speaker's mouth open, instead of running.
    func hold(_ pose: StagePose, captions: Bool) {
        still = (pose, captions)
        running = false
        introPlaying = false
        rebuildStill()
    }

    // MARK: Inputs

    /// New inputs at `uptime`: queued for their sim time, and the stage wakes.
    func receive(_ inputs: StageInputs, at uptime: Double) {
        guard still == nil else { return }
        if inputs.active || inputs.preparing || inputs.floor != nil || inputs.userText != nil
            || !inputs.captions.isEmpty || !inputs.thinking.isEmpty {
            engaged = true
            if introPlaying { introPlaying = false }
            if logoShown { logoShown = false }
        }
        sim.receive(inputs, at: (suspendedAt ?? uptime) - offset)
        wake()
    }

    /// Reduce Motion and Prefer Cross-Fade Transitions.
    func update(mode: StageMode) {
        guard still == nil else { return }
        requestedMode = mode
        sim.receive(sceneMode(active: suspendedAt == nil), at: simNow)
        wake()
    }

    private func sceneMode(active: Bool) -> StageMode {
        var mode = requestedMode
        mode.sceneActive = active
        return mode
    }

    /// New geometry: the layout is solved again. Geometry that arrives while the screen is
    /// still being measured (`provisional`), or before the conversation shows anything, snaps
    /// into place; later changes, such as the error banner, spring, as do changes after the
    /// measurement while the intro plays, so it never jumps.
    func update(metrics: StageMetrics, provisional: Bool) {
        guard metrics != self.metrics else { return }
        self.metrics = metrics
        resolve(snap: provisional || (!engaged && !(measured && sim.intro != nil)))
        if !provisional { measured = true }
    }

    /// A caption bubble's measured height: rounded to 4 pt, and kept unless it moves by more
    /// than 6 pt or the content kind changes, so the faces do not pump between sentences.
    func measured(bubble height: Double, for c: DuoCharacter, kind: BubbleKind) {
        let kindChanged = bubbleKinds[c] != kind
        bubbleKinds[c] = kind
        let next = StageLayout.layoutHeight(measured: height, previous: bubbleHeights[c], kindChanged: kindChanged)
        guard next != bubbleHeights[c] else { return }
        bubbleHeights[c] = next
        resolve()
    }

    /// The human's pill's measured height.
    func measured(pill height: Double) {
        let next = (max(0, height) / 4).rounded() * 4
        guard next != pillHeight else { return }
        pillHeight = next
        resolve()
    }

    private func resolve(snap: Bool = false) {
        guard let metrics else { return }
        if still != nil {
            rebuildStill()
            return
        }
        sim.update(metrics: metrics, bubbleHeights: bubbleHeights, pillHeight: pillHeight)
        if snap { sim.settleAll() }
        wake()
        schedulePublish()
    }

    private func rebuildStill() {
        guard let still, let metrics else { return }
        sim = if still.pose.inputs().floor != nil {
            StageSimulation.snapshot(pose: still.pose, metrics: metrics, talkOpen: 0.8, seed: seed,
                                     captions: still.captions, bubbleHeights: bubbleHeights)
        } else {
            StageSimulation.snapshot(pose: still.pose, metrics: metrics, seed: seed, captions: still.captions,
                                     bubbleHeights: bubbleHeights)
        }
        if layout != sim.layout { layout = sim.layout }
        if !pendingSlots.isEmpty { pendingSlots = [] }
        let expressions = sim.roles.map { CharacterDirector.expression(for: $1) }
        if held != expressions { held = expressions }
    }

    // MARK: Scene

    /// The scene became inactive (sim time freezes) or active again (it resumes where it froze).
    func scene(active: Bool, at uptime: Double) {
        if active {
            guard let suspended = suspendedAt else { return }
            offset += uptime - suspended
            suspendedAt = nil
            lastFrameUptime = nil
            if still == nil { sim.receive(sceneMode(active: true), at: simNow) }
            wake()
        } else if suspendedAt == nil {
            suspendedAt = uptime
            if still == nil { sim.receive(sceneMode(active: false), at: uptime - offset) }
        }
    }

    // MARK: Intro

    /// The first frame introduces the characters, once per launch. In DEBUG a `--stage-pose`
    /// shows no intro, and a `--stage-script` holds the faces unseen for its own cue
    /// (`StageScript.intro`), or shows none.
    private func introduce(at uptime: Double) {
        guard still == nil, !Self.introduced else { return }
        #if DEBUG
        if StageDebug.stagePose != nil { return }
        if let request = StageDebug.stageScript {
            if request.script.intro != nil { sim.awaitIntro() }
            return
        }
        #endif
        Self.introduced = true
        sim.beginIntro(at: (suspendedAt ?? uptime) - offset)
    }

    #if DEBUG
    /// Plays the intro from `uptime`, on a `--stage-script`'s cue.
    func beginIntro(at uptime: Double) {
        guard still == nil else { return }
        Self.introduced = true
        sim.beginIntro(at: (suspendedAt ?? uptime) - offset)
        wake()
    }
    #endif

    // MARK: Frames

    /// The frame for `uptime`: the simulation advanced in fixed substeps with this frame's
    /// mouths. A hitch longer than 0.1 s slows the stage rather than jumping it. The first
    /// frame adopts `metrics` at once, so nothing is ever drawn at placeholder positions, and
    /// begins the intro.
    func frame(at uptime: Double, metrics: StageMetrics, mouths: FrameMouths, userLevel: Double?) -> StageFrame {
        if self.metrics == nil {
            self.metrics = metrics
            if still != nil {
                Task { @MainActor [weak self] in self?.rebuildStill() }
            } else {
                sim.update(metrics: metrics, bubbleHeights: bubbleHeights, pillHeight: pillHeight)
                sim.settleAll()
                schedulePublish()
            }
        }
        if !appeared {
            appeared = true
            introduce(at: uptime)
        }
        guard still == nil, suspendedAt == nil else { return sim.frame }
        if let last = lastFrameUptime, uptime - last > 0.1 { offset += uptime - last - 0.1 }
        let frame = sim.advance(to: uptime - offset, mouths: mouths, userLevel: userLevel)
        lastFrameUptime = sim.needsFrames ? uptime : nil
        let events = sim.drainEvents()
        #if DEBUG
        if trace { log(events, at: uptime) }
        if LipsyncTimeline.tracing { traceMouths(mouths, at: uptime) }
        #endif
        updateTier(at: uptime)
        if needsPublish { schedulePublish() }
        return frame
    }

    /// Speeds up to a faster tier at once; slows down only once the slower tier has been asked
    /// for 0.3 s.
    private func updateTier(at uptime: Double) {
        let activity = sim.activity
        guard activity.isRunning else {
            slowerSince = nil
            tierAsleep = true
            return
        }
        let wanted = activity.frameInterval()
        func rank(_ interval: Double?) -> Double { interval ?? 0 }
        if tierAsleep || rank(wanted) <= rank(tierInterval) {
            tierAsleep = false
            tierInterval = wanted
            slowerSince = nil
        } else if let since = slowerSince {
            if uptime - since >= 0.3 {
                tierInterval = wanted
                slowerSince = nil
            }
        } else {
            slowerSince = uptime
        }
    }

    private var needsPublish: Bool {
        let activity = sim.activity
        return running != activity.isRunning || (activity.isRunning && frameInterval != tierInterval)
            || layout != sim.layout || pendingSlots != sim.pendingSlots
            || held != sim.roles.map { CharacterDirector.expression(for: $1) }
            || introPlaying != simIntroPlaying || logoShown != (sim.showsLogo && !engaged)
    }

    /// The simulation's intro is playing and no conversation has taken over the stage.
    private var simIntroPlaying: Bool { sim.intro != nil && !engaged }

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { @MainActor [weak self] in self?.publish() }
    }

    /// Copies the simulation's event-driven state into the observed properties.
    private func publish() {
        publishScheduled = false
        guard still == nil else { return }
        let activity = sim.activity
        if layout != sim.layout { layout = sim.layout }
        if pendingSlots != sim.pendingSlots { pendingSlots = sim.pendingSlots }
        let expressions = sim.roles.map { CharacterDirector.expression(for: $1) }
        if held != expressions { held = expressions }
        if introPlaying != simIntroPlaying { introPlaying = simIntroPlaying }
        if logoShown != (sim.showsLogo && !engaged) { logoShown = sim.showsLogo && !engaged }
        if activity.isRunning {
            if frameInterval != tierInterval { frameInterval = tierInterval }
            if !running { running = true }
        } else if running, suspendedAt == nil {
            running = false
            lastFrameUptime = nil
            wakeUptime = sim.nextWake.map { $0 + offset }
            wakeToken &+= 1
            #if DEBUG
            if trace {
                print(String(format: "STAGE_LINK: paused next_wake=%.2f", (wakeUptime ?? .infinity) - Self.uptime))
            }
            #endif
        }
    }

    private func wake() {
        if !running, still == nil { running = true }
    }

    /// Sleeps until the stage's next scheduled wake, then wakes it; cancelled by a newer one.
    func sleepUntilWake() async {
        guard !running, let wake = wakeUptime else { return }
        let delay = wake - Self.uptime
        if delay > 0 {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
        guard suspendedAt == nil else { return }
        self.wake()
    }

    // MARK: Trace

    #if DEBUG
    /// `--lipsync-trace`: each talking face's drive and drawn mouth, with the drive's player time.
    private func traceMouths(_ mouths: FrameMouths, at uptime: Double) {
        for c in DuoCharacter.allCases {
            let face = sim.faces[c]
            guard let time = mouths.times[c] else { continue }
            let drive = mouths.drive(c, at: 0)
            print(String(format: "LIPSYNC_FRAME: %@ %.6f %.6f %.4f %.4f %.4f %.3f %.3f %.3f %d", c.rawValue, uptime, time,
                         drive?.openness ?? -1, drive?.width ?? -1, drive?.rounding ?? -1, face.talk.value,
                         face.mouth.open, face.mouth.width, face.directive.talking ? 1 : 0))
        }
    }

    /// `--rig-trace`: the stage's events, and each second its tier and frame count.
    private func log(_ events: [StageEventRecord], at uptime: Double) {
        for record in events { print(String(format: "STAGE_EVENT: %.3f %@", record.time, "\(record.event)")) }
        traceWindow.frames += 1
        if uptime - traceWindow.start >= 1 {
            print("STAGE_LINK: tier=\(sim.activity.rawValue) frames=\(traceWindow.frames)")
            print("STAGE_DRAWS: \(traceWindow.frames)/s")
            traceWindow = (uptime, 0)
        }
    }
    #endif
}

/// The angel and the devil on one stage: a full-screen Canvas drawing both halves, the seam and
/// both faces from the simulation, the captions as SwiftUI views at settled slots, and two
/// accessibility elements, one per half.
struct DuoStageView: View {
    let model: ConversationModel
    /// Where the header ends and the footer starts, in window coordinates.
    let headerBottom: CGFloat
    let footerTop: CGFloat
    /// Whether the launch intro is playing (`StageDriver.introPlaying`).
    @Binding var introPlaying: Bool
    /// Whether the intro's logo shows (`StageDriver.logoShown`).
    @Binding var logoShown: Bool
    #if DEBUG
    /// A settled pose shown instead of the conversation (`--stage-pose`).
    var pose: StagePoseRequest?
    /// A scripted conversation played instead of the model's (`--stage-script`).
    private let script = StageDebug.stageScript
    /// The script's inputs so far, and the uptime it started at.
    @State private var scripted = StageInputs()
    @State private var scriptStart: Double?
    @State private var reportedPose = false
    #endif

    @State private var holder = StageDriverHolder()
    @State private var prefersCrossFade = UIAccessibility.prefersCrossFadeTransitions
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    private var reduceMotion: Bool {
        #if DEBUG
        systemReduceMotion || ProcessInfo.processInfo.arguments.contains("--reduce-motion")
        #else
        systemReduceMotion
        #endif
    }

    private var inputs: StageInputs {
        #if DEBUG
        if let pose {
            var inputs = pose.pose.inputs(captions: pose.captions)
            if let speaker = inputs.floor { inputs.talking = [speaker] }
            return inputs
        }
        if script != nil { return scripted }
        #endif
        return StageInputs(model: model)
    }

    private var driver: StageDriver { holder.driver }

    private var mode: StageMode {
        StageMode(reduceMotion: reduceMotion, crossFadeOnly: !reduceMotion && prefersCrossFade)
    }

    var body: some View {
        let inputs = inputs
        let palette = StagePalette(contrast: contrast, reduceTransparency: reduceTransparency)
        GeometryReader { proxy in
            let metrics = StageMetrics(size: Vec2(proxy.size.width, proxy.size.height),
                                       globalMinY: proxy.frame(in: .global).minY, headerBottom: headerBottom,
                                       footerTop: footerTop)
            ZStack(alignment: .topLeading) {
                canvas(metrics: metrics, palette: palette, talking: inputs.talking,
                       listening: inputs.userText != nil)
                StageCaptionLayer(driver: driver, inputs: inputs, metrics: metrics, palette: palette,
                                  reduceMotion: reduceMotion)
                StageAccessibilityLayer(driver: driver, inputs: inputs)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onChange(of: metrics, initial: true) { _, metrics in
                driver.update(metrics: metrics, provisional: headerBottom <= 0 || !footerTop.isFinite)
                #if DEBUG
                reportPose()
                #endif
            }
        }
        .ignoresSafeArea()
        .onChange(of: inputs, initial: true) { _, inputs in
            #if DEBUG
            // A script delivers its inputs at their own times.
            if script != nil { return }
            #endif
            driver.receive(inputs, at: StageDriver.uptime)
        }
        .onChange(of: mode, initial: true) { _, mode in driver.update(mode: mode) }
        .onChange(of: driver.introPlaying, initial: true) { _, playing in introPlaying = playing }
        .onChange(of: driver.logoShown, initial: true) { _, shown in logoShown = shown }
        .onChange(of: scenePhase, initial: true) { _, phase in
            driver.scene(active: phase == .active, at: StageDriver.uptime)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIAccessibility.prefersCrossFadeTransitionsStatusDidChange)) { _ in
            prefersCrossFade = UIAccessibility.prefersCrossFadeTransitions
        }
        .task(id: driver.wakeToken) { await driver.sleepUntilWake() }
        #if DEBUG
        .onAppear {
            if let pose { driver.hold(pose.pose, captions: pose.captions) }
            for c in DuoCharacter.allCases { model.mouths[c]?.traceLabel = c.rawValue }
        }
        .task {
            if let script { await play(script) }
        }
        #endif
    }

    private func canvas(metrics: StageMetrics, palette: StagePalette, talking: Set<DuoCharacter>,
                        listening: Bool) -> some View {
        let glow = GlowSpriteCache.shared.image(for: palette, pxPerFu: metrics.scale * displayScale)
        return TimelineView(.animation(minimumInterval: driver.frameInterval,
                                       paused: !driver.running || scenePhase != .active)) { _ in
            let uptime = StageDriver.uptime
            let (mouths, level) = frameInputs(at: uptime, talking: talking, listening: listening)
            let frame = driver.frame(at: uptime, metrics: metrics, mouths: mouths, userLevel: level)
            Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
                StageRenderer.draw(frame, metrics: metrics, palette: palette, glow: glow, in: &context, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    /// A frame's mouths and, while the human's words show, their microphone level.
    private func frameInputs(at uptime: Double, talking: Set<DuoCharacter>,
                             listening: Bool) -> (FrameMouths, Double?) {
        #if DEBUG
        if let script, let start = scriptStart {
            return (FrameMouths(script: script.script, at: uptime + driver.presentationLead - start, talking: talking),
                    listening ? script.script.userLevel(at: uptime - start) : nil)
        }
        #endif
        // The level is sampled without observing it, so microphone buffers never redraw the
        // stage between the frame tier's own frames.
        return (FrameMouths(model: model, talking: talking, ahead: driver.presentationLead),
                listening ? model.unobservedUserLevel : nil)
    }

    #if DEBUG
    /// Plays `--stage-script`: each step reaches the stage at its own time, as the model's
    /// changes would, and the captions follow.
    private func play(_ request: StageScriptRequest) async {
        try? await Task.sleep(for: .seconds(1.5))
        let start = StageDriver.uptime
        scriptStart = start
        let script = request.script
        StageDebug.log(String(format: "STAGE_SCRIPT_START: %@ seed %llu, %.1f s", request.name, StageDebug.seed,
                              script.duration))
        if let intro = script.intro { driver.beginIntro(at: start + intro) }
        var marks = script.marks[...]
        for step in script.steps {
            let due = start + step.time
            let delay = due - StageDriver.uptime
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            while let mark = marks.first, mark.time <= step.time {
                StageDebug.log(String(format: "STAGE_SCRIPT: %.3f %@", mark.time, mark.label))
                marks = marks.dropFirst()
            }
            scripted = step.inputs
            driver.receive(step.inputs, at: due)
            StageDebug.log(String(format: "STAGE_SCRIPT: %.3f step floor=%@ talking=%@ captions=%d", step.time,
                                  step.inputs.floor?.rawValue ?? "-",
                                  step.inputs.talking.map(\.rawValue).sorted().joined(separator: "+"),
                                  step.inputs.captions.count))
        }
        for mark in marks {
            let delay = start + mark.time - StageDriver.uptime
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            StageDebug.log(String(format: "STAGE_SCRIPT: %.3f %@", mark.time, mark.label))
        }
        let rest = start + script.duration - StageDriver.uptime
        if rest > 0 { try? await Task.sleep(for: .seconds(rest)) }
        StageDebug.log("STAGE_SCRIPT_DONE: \(request.name)")
    }

    /// `--stage-pose` reports once the header and footer are measured.
    private func reportPose() {
        guard let pose, !reportedPose, footerTop.isFinite, headerBottom > 0 else { return }
        reportedPose = true
        StageDebug.log("STAGE_POSE_READY: \(pose.name)@settled")
    }
    #endif
}

/// Creates the stage's driver on first use. SwiftUI keeps the holder in `@State`, so rebuilding
/// `DuoStageView` (which happens whenever its parent's body runs) never builds a new driver.
@MainActor
private final class StageDriverHolder {
    lazy var driver = StageDriver(seed: StageDriver.launchSeed, trace: StageDriver.traceRequested)
}

extension StageDriver {
    /// The rig's seed: `--rig-seed N` in DEBUG builds, otherwise a new one each launch.
    static var launchSeed: UInt64 {
        #if DEBUG
        if StageDebug.stagePose != nil || StageDebug.stageScript != nil { return StageDebug.seed }
        if let seed = StageDebug.value(after: "--rig-seed").flatMap(UInt64.init) { return seed }
        #endif
        return UInt64.random(in: 1...UInt64.max)
    }

    /// `--rig-trace` (DEBUG) prints the stage's events and frame counts.
    static var traceRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rig-trace")
        #else
        false
        #endif
    }
}

/// Two invisible elements over each character's settled half: the name, and the sentence being
/// said or "Thinking". They move only when the preset changes, so focus never chases the seam.
/// It reads the driver's layout and held expressions itself, so their changes re-run only this
/// layer.
private struct StageAccessibilityLayer: View {
    let driver: StageDriver
    let inputs: StageInputs

    var body: some View {
        let layout = driver.layout, held = driver.held
        ForEach(DuoCharacter.allCases) { c in
            let rect = layout.regions[c]
            Color.clear
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .accessibilityElement()
                .accessibilityLabel(c.title)
                .accessibilityValue(inputs.thinking.contains(c) ? "Thinking" : inputs.captions[c] ?? "")
                .accessibilityCustomContent("Expression", Text(held[c].spokenName))
                .accessibilitySortPriority(c == .angel ? 3 : 2)
                .placed(at: rect)
        }
    }
}

extension FaceExpression {
    /// The expression's name as VoiceOver reads it.
    var spokenName: String {
        switch self {
        case .squishedAddressed: "glaring"
        case .sideEye: "side-eye"
        case .starry: "starry-eyed"
        default: rawValue
        }
    }
}

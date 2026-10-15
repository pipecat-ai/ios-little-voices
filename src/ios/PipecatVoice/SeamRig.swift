import Foundation

/// The seam's settled shape in band fractions (0 at the band's top, 1 at its bottom):
/// y(u) = base + bulge·P(u) + wave·sin(2π(u/λ − φ)), with P(u) = (4u(1−u))^0.95 and λ = 0.66.
/// With nobody on the floor the idle drift (`SeamRig.driftProfile`) flows on top of it. Outside
/// u ∈ [0, 1] the seam holds its edge value.
struct SeamShape: Equatable, Sendable {
    var base: Double
    var bulge: Double
    var wave: Double
    /// The idle drift's amplitude: with nobody on the floor the seam is one smooth S across the
    /// window that rolls and swells slowly (`SeamRig.driftProfile`). It gives way as someone
    /// takes the floor, and rests as a still S under Reduce Motion and after a long idle.
    var drift: Double

    init(base: Double, bulge: Double, wave: Double, drift: Double = 0) {
        self.base = base
        self.bulge = bulge
        self.wave = wave
        self.drift = drift
    }

    /// The resting seam: level across the middle of the band, drifting slowly.
    static let neutral = SeamShape(base: 0.5, bulge: 0, wave: 0, drift: idleDrift)

    /// The idle drift's amplitude, which the neutral seam and the leans share: 0.026 band, about
    /// 15 pt on an iPhone 18 Pro and 24 pt on an iPad in portrait.
    static let idleDrift = 0.026

    /// The waiting profile, `relax` of the way there: the base moves 15% toward neutral, the
    /// bulge loses 15% and the wave 40%. Only the floor presets relax, and they do not drift.
    func relaxed(_ relax: Double = 1) -> SeamShape {
        SeamShape(base: base + (0.5 - base) * 0.15 * relax,
                  bulge: bulge * (1 - 0.15 * relax),
                  wave: wave * (1 - 0.4 * relax), drift: drift)
    }

    /// The baseline at the centre, where P(0.5) = 1.
    var centre: Double { base + bulge }

    /// The shape at `u` with the wave at `phase`, without the drift, which averages out level.
    func value(at u: Double, phase: Double = KeyPoses.restPhase) -> Double {
        let u = RigMath.clamp(u, 0, 1)
        return base + bulge * KeyPoses.bulge(u) + wave * KeyPoses.wave(u, phase: phase)
    }

    /// The highest point (smallest y) over [u0, u1] at any wave and drift phase. P is largest at
    /// 0.5 and falls toward both edges, so its smallest value over an interval is at an end.
    func highest(from u0: Double, to u1: Double) -> Double {
        let a = RigMath.clamp(min(u0, u1), 0, 1), b = RigMath.clamp(max(u0, u1), 0, 1)
        return base + bulge * min(KeyPoses.bulge(a), KeyPoses.bulge(b)) - abs(wave) - abs(drift)
    }

    /// The lowest point (largest y) over [u0, u1] at any wave and drift phase.
    func lowest(from u0: Double, to u1: Double) -> Double {
        let a = RigMath.clamp(min(u0, u1), 0, 1), b = RigMath.clamp(max(u0, u1), 0, 1)
        return base + bulge * KeyPoses.bulge(RigMath.clamp(0.5, a, b)) + abs(wave) + abs(drift)
    }
}

/// One handover's choreography: the windup, the launch and the base's start, with their kicks
/// and springs. Times are seconds after the floor change; kicks are band/s.
struct HandoverScript: Equatable, Sendable {
    /// The windup target, held until the launch (negative raises the seam).
    var windup: Double
    var launch: Double
    var baseStart: Double
    var bulgeKick: Double
    var baseKick: Double
    var baseSpec: SpringSpec
    var bulgeSpec: SpringSpec
    var waveSpec: SpringSpec

    /// The handover from `previous` (nil when nobody held the floor) to `speaker`.
    static func script(from previous: DuoCharacter?, to speaker: DuoCharacter) -> HandoverScript {
        switch (previous, speaker) {
        case (.devil, .angel):
            HandoverScript(windup: -0.020, launch: 0.11, baseStart: 0.15,
                           bulgeKick: 0.70, baseKick: 0.27, baseSpec: .baseAngelPush,
                           bulgeSpec: .bulgeLaunch, waveSpec: .collapse)
        case (_, .angel):
            HandoverScript(windup: -0.023, launch: 0.11, baseStart: 0.15,
                           bulgeKick: 0.65, baseKick: 0.15, baseSpec: .baseAngelPush,
                           bulgeSpec: .bulgeLaunch, waveSpec: .collapse)
        case (.angel, .devil):
            HandoverScript(windup: 0.017, launch: 0.09, baseStart: 0.09,
                           bulgeKick: 0, baseKick: -0.33, baseSpec: .baseDevilPush,
                           bulgeSpec: .collapse, waveSpec: .waveAmplitude)
        case (_, .devil):
            HandoverScript(windup: 0.020, launch: 0.09, baseStart: 0.09,
                           bulgeKick: 0, baseKick: -0.50, baseSpec: .baseDevilPush,
                           bulgeSpec: .collapse, waveSpec: .waveAmplitude)
        }
    }
}

/// The moving seam between the two halves: base, bulge, wave, windup, pulse and relax springs,
/// the ripple chain, the wave's phase, the idle drift, the handover choreography with its impact
/// and draw-order flip, and the walls. Values are band fractions; it
/// knows nothing of presets, which `StageSimulation` turns into shapes through `StageLayout`.
struct SeamRig: Sendable {
    /// Which secondary motions run.
    struct Options: Equatable, Sendable {
        var ripple = true
        /// Beat pulses, push-backs and lean-in pulses.
        var pulses = true
        var waveTravel = true
        /// The idle drift flows; without it the drift rests as its still S-curve.
        var drift = true

        static let standard = Options()
        /// The handover springs alone, for the choreography checks: no ripple, pulses, wave
        /// travel or flowing drift. Walls and breath still run.
        static let isolated = Options(ripple: false, pulses: false, waveTravel: false, drift: false)
    }

    /// The listener's walls on the live seam (band fractions): where the squished listener is
    /// pressed to its deepest squash. They act on the seam's extreme over the listener's face
    /// span.
    struct Limits: Equatable, Sendable {
        /// The lowest the seam may reach (the squished devil's floor side).
        var maxLowest = Double.infinity
        /// The highest the seam may reach (the squished angel's ceiling side).
        var minHighest = -Double.infinity
        /// The listener's face span in u (±100 fu about the centre).
        var span = 0.5...0.5

        static let none = Limits()
    }

    /// What the faces and the stage feed the seam each substep.
    struct Drive: Equatable, Sendable {
        var energyAngel = 0.0
        var energyDevil = 0.0
        /// The devil holds the floor and talks (the wave travels).
        var devilSpeaking = false
        /// The devil holds the floor but is waiting.
        var devilPaused = false
        /// Ambient breath runs.
        var breathing = false
        /// The idle drift flows (where the shape has one); otherwise it rests as its S-curve.
        var drifting = false
        var reduceMotion = false
    }

    /// What happened during one substep.
    struct StepEvents: Equatable, Sendable {
        var launched = false
        /// The impact's strength, 0.4…1.
        var impact: Double?
        /// The draw order flipped to this character.
        var flipped: DuoCharacter?
    }

    enum Motion: Equatable, Sendable {
        case idle
        case handover(Handover)
        case release(start: Double)
        case interrupt(start: Double)
        case lean(start: Double)
    }

    struct Handover: Equatable, Sendable {
        var speaker: DuoCharacter
        var script: HandoverScript
        var start: Double
        /// The centre baseline (base + bulge + windup) when the handover started.
        var startBaseline: Double
        var launched = false
        var baseStarted = false
        var impact: Double?
        var peakBaseSpeed = 0.0
        /// The speaker's launch stretch has ended (the base slowed below half its peak speed).
        var stretchEnded = false
    }

    static let rippleCount = 13
    static let sampleCount = 49
    static let pulseLimit = 0.010
    static let rippleLimit = 0.025
    static let breathAmplitude = 0.0026
    static let breathRate = 0.29
    /// The idle drift: one wavelength across the window, a smooth S, rolling right a wavelength
    /// every 11 s and swelling from `driftSwell` of the amplitude to all of it every 7.3 s. A
    /// whole wavelength keeps the seam level on average at every moment, the roll keeps every
    /// point level on average over time, and the periods' ratio keeps the motion from repeating.
    static let driftPeriods = (roll: 11.0, swell: 7.3)
    static let driftSwell = 0.7
    /// The drift at rest: the S through the middle of the band at this share of the amplitude,
    /// the same for both halves.
    static let driftStillShare = 0.6
    /// Ripple impulses are Gaussian in u with this σ.
    static let rippleSigma = 0.09

    let options: Options
    private(set) var base: RigSpring
    private(set) var bulge: RigSpring
    private(set) var wave: RigSpring
    private(set) var windup: RigSpring
    private(set) var pulse: RigSpring
    private(set) var relax: RigSpring
    private(set) var breath: RigSpring
    /// The idle drift's amplitude (band), sprung apart from the base and bulge so it never
    /// changes the handovers' choreography.
    private(set) var drift: RigSpring
    /// How far the drift has settled into its still S: 0 flowing, 1 still.
    private(set) var driftStill: RigSpring
    /// The drift's roll and swell phases in cycles.
    private(set) var driftPhases = (0.0, 0.0)
    /// The wave's phase φ in cycles.
    private(set) var phase = KeyPoses.restPhase
    /// The current φ̇ in cycles/s.
    private(set) var phaseRate = 0.0
    private(set) var ripple: [Double]
    private(set) var rippleVelocity: [Double]
    /// The settled targets.
    private(set) var shape: SeamShape
    var limits = Limits.none
    /// The character drawn on top: the last to hold the floor (the angel at launch).
    private(set) var dominant: DuoCharacter
    private(set) var motion = Motion.idle
    /// Sim time of the last substep's end.
    private(set) var time: Double
    private var energyAngel = 0.0

    init(shape: SeamShape = .neutral, options: Options = .standard, dominant: DuoCharacter = .angel, at time: Double = 0) {
        self.options = options
        self.shape = shape
        self.dominant = dominant
        self.time = time
        let range = 0.25
        base = RigSpring(shape.base, spec: .lean, range: range)
        bulge = RigSpring(shape.bulge, spec: .lean, range: range)
        wave = RigSpring(shape.wave, spec: .lean, range: range)
        windup = RigSpring(0, spec: .windupOut, range: range)
        pulse = RigSpring(0, spec: .pulse, range: range)
        relax = RigSpring(0, spec: .relax)
        breath = RigSpring(0, spec: .relax)
        drift = RigSpring(shape.drift, spec: .relax, range: range)
        driftStill = RigSpring(1, spec: .driftSettle)
        ripple = Array(repeating: 0, count: Self.rippleCount)
        rippleVelocity = Array(repeating: 0, count: Self.rippleCount)
    }

    // MARK: Commands

    /// Starts a handover to `speaker` from `previous` (nil when nobody held the floor); the idle
    /// drift gives way on `driftSpec`.
    mutating func beginHandover(to speaker: DuoCharacter, from previous: DuoCharacter?, shape: SeamShape, at t: Double,
                                driftSpec: SpringSpec = .collapse) {
        let script = HandoverScript.script(from: previous, to: speaker)
        self.shape = shape
        motion = .handover(Handover(speaker: speaker, script: script, start: t, startBaseline: baseline))
        windup.use(.windupIn)
        windup.retarget(script.windup)
        relax.retarget(0)
        // The idle drift gives way as the speaker gathers.
        drift.use(driftSpec)
        drift.retarget(driftTarget)
    }

    /// Releases to `shape` after an exchange ends (the hold is the caller's).
    mutating func beginRelease(to shape: SeamShape, at t: Double) {
        self.shape = shape
        motion = .release(start: t)
        use(base: .releaseBase, bulge: .releaseBulge)
        retargetAll()
        windup.use(.windupOut)
        windup.retarget(0)
        relax.retarget(0)
        impulse(at: 0.5, velocity: -sigma * 0.04)
    }

    /// Springs straight to `shape` when a line is cut off: no hold, no ripple.
    mutating func beginInterrupt(to shape: SeamShape, at t: Double) {
        self.shape = shape
        motion = .interrupt(start: t)
        use(base: .interruptBase, bulge: .interruptBulge)
        retargetAll()
        windup.use(.windupOut)
        windup.retarget(0)
        relax.retarget(0)
    }

    /// Eases to `shape` on the lean spring (a lean preset, or back to neutral).
    mutating func beginLean(to shape: SeamShape, at t: Double) {
        self.shape = shape
        motion = .lean(start: t)
        use(base: .lean, bulge: .lean)
        retargetAll()
    }

    /// New settled targets for the same preset (a re-solved layout). Springs a handover has
    /// not launched yet keep their targets until it does.
    mutating func retarget(_ shape: SeamShape) {
        guard shape != self.shape else { return }
        self.shape = shape
        switch motion {
        case .handover(let handover):
            drift.retarget(driftTarget)
            if handover.baseStarted { base.retarget(shape.base) }
            if handover.launched {
                bulge.retarget(shape.bulge)
                wave.retarget(shape.wave)
            }
        case .idle:
            use(base: .lean, bulge: .lean)
            retargetAll()
        case .release, .interrupt, .lean:
            retargetAll()
        }
    }

    /// Moves straight to `shape` with everything at rest (Reduce Motion's held poses).
    mutating func jump(to shape: SeamShape, dominant: DuoCharacter) {
        self.shape = shape
        self.dominant = dominant
        motion = .idle
        retargetAll()
        windup.retarget(0)
        relax.retarget(0)
        pulse.retarget(0)
        restPhase()
        settle()
    }

    /// Moves time on without stepping, for a settled seam.
    mutating func skip(to t: Double) { time = t }

    /// Stops the wave at its resting phase.
    mutating func restPhase() {
        phase = KeyPoses.restPhase
        phaseRate = 0
    }

    /// Reduce Motion's held pose: unrelaxed, without breath, the drift resting as its
    /// still S-curve and the wave static at its resting phase. `settle()` then snaps the springs
    /// to it.
    mutating func holdPose() {
        relax.retarget(0)
        breath.retarget(0)
        holdStill()
        restPhase()
    }

    /// Rests the idle drift as its still S-curve until the drive lets it flow again (stills,
    /// Reduce Motion). `settle()` then snaps it.
    mutating func holdStill() {
        driftStill.retarget(1)
    }

    /// Sets the idle drift flowing or settling at once, so a resting stage wakes for it.
    mutating func setDriftFlowing(_ flowing: Bool) {
        driftStill.retarget(options.drift && flowing ? 0 : 1)
    }

    /// Waiting while holding the floor: the seam relaxes toward neutral.
    mutating func setRelaxed(_ relaxed: Bool) { relax.retarget(relaxed ? 1 : 0) }

    /// Kicks the pulse (band/s; positive moves the seam toward the listener).
    mutating func kickPulse(_ velocity: Double) {
        guard options.pulses else { return }
        pulse.kick(velocity)
    }

    /// Adds a Gaussian ripple impulse (band/s) centred on `u`.
    mutating func impulse(at u: Double, velocity: Double) {
        guard options.ripple else { return }
        for i in 0..<Self.rippleCount {
            let d = Double(i) / Double(Self.rippleCount - 1) - u
            rippleVelocity[i] += velocity * exp(-d * d / (2 * Self.rippleSigma * Self.rippleSigma))
        }
    }

    /// Where impacts and beats strike: the centre under the angel, the wave crest nearest the
    /// centre under the devil.
    func strikePoint(for speaker: DuoCharacter) -> Double {
        guard speaker == .devil else { return 0.5 }
        // The crest (sin = −1) is at u/λ − φ = −1/4 + k.
        let lambda = KeyPoses.waveLength
        let k = (0.5 / lambda - phase + 0.25).rounded()
        return RigMath.clamp(lambda * (phase - 0.25 + k), 0, 1)
    }

    /// Snaps every spring to rest at its target and stills the ripple. Exact for a settled seam,
    /// so stepping a snapped seam and skipping time give the same state.
    mutating func settle() {
        if case .handover(var handover) = motion {
            if !handover.launched || !handover.baseStarted {
                retargetAll()
                windup.retarget(0)
            }
            handover.launched = true
            handover.baseStarted = true
            handover.stretchEnded = true
            handover.impact = handover.impact ?? time
            motion = .handover(handover)
            dominant = handover.speaker
        }
        base.snap(); bulge.snap(); wave.snap(); windup.snap(); pulse.snap(); relax.snap(); breath.snap(); drift.snap()
        driftStill.snap()
        for i in 0..<Self.rippleCount {
            ripple[i] = 0
            rippleVelocity[i] = 0
        }
    }

    // MARK: Stepping

    /// Advances one substep from `t` (the substep's start). Choreography triggers due at `t`
    /// fire first, as the floor change happens on a substep boundary.
    mutating func step(from t: Double, drive: Drive) -> StepEvents {
        var events = StepEvents()
        energyAngel = drive.energyAngel
        if case .handover(var handover) = motion {
            let elapsed = t - handover.start
            if !handover.launched, elapsed >= handover.script.launch - 1e-9 {
                handover.launched = true
                events.launched = true
                windup.use(.windupOut)
                windup.retarget(0)
                bulge.use(handover.script.bulgeSpec)
                bulge.retarget(shape.bulge)
                bulge.kick(handover.script.bulgeKick)
                wave.use(handover.script.waveSpec)
                wave.retarget(shape.wave)
            }
            if !handover.baseStarted, elapsed >= handover.script.baseStart - 1e-9 {
                handover.baseStarted = true
                base.use(handover.script.baseSpec)
                base.retarget(shape.base)
                base.kick(handover.script.baseKick)
            }
            motion = .handover(handover)
        }

        // The wave travels while the devil holds the floor, ramping in from 0.6 s after his
        // handover.
        var rate = 0.0
        if options.waveTravel, !drive.reduceMotion, drive.devilSpeaking {
            rate = drive.devilPaused ? 0.12 : 0.30 + 0.60 * drive.energyDevil
            if case .handover(let handover) = motion, handover.speaker == .devil {
                rate *= RigMath.smoothstep(0.6, 1.0, t - handover.start)
            }
        }
        phaseRate = rate
        phase += rate * SpringSpec.step
        phase -= phase.rounded(.down)

        breath.retarget(drive.breathing && !drive.reduceMotion ? 1 : 0)
        // The idle drift flows while the drive lets it and settles into its still S-curve
        // otherwise; its S rolls and swells while any of the flow shows.
        driftStill.retarget(options.drift && drive.drifting && !drive.reduceMotion ? 0 : 1)
        drift.retarget(driftTarget)
        if driftTravels {
            driftPhases.0 += SpringSpec.step / Self.driftPeriods.roll
            driftPhases.1 += SpringSpec.step / Self.driftPeriods.swell
            driftPhases.0 -= driftPhases.0.rounded(.down)
            driftPhases.1 -= driftPhases.1.rounded(.down)
        }
        base.step(); bulge.step(); wave.step(); windup.step(); pulse.step(); relax.step(); breath.step(); drift.step()
        driftStill.step()
        if abs(pulse.value) > Self.pulseLimit {
            pulse.value = RigMath.clamp(pulse.value, -Self.pulseLimit, Self.pulseLimit)
            if pulse.value * pulse.velocity > 0 { pulse.velocity = 0 }
        }
        if options.ripple { stepRipple() }
        if wave.target == 0, abs(wave.value) < 1e-6, abs(wave.velocity) < 1e-5 {
            phase = KeyPoses.restPhase
        }
        time = t + SpringSpec.step
        applyWalls()

        if case .handover(var handover) = motion {
            let now = baseline
            if handover.baseStarted {
                let speed = abs(base.velocity)
                handover.peakBaseSpeed = max(handover.peakBaseSpeed, speed)
                if speed < 0.5 * handover.peakBaseSpeed { handover.stretchEnded = true }
            }
            let travel = shape.centre - handover.startBaseline
            if handover.launched, handover.impact == nil, abs(travel) > 0.02,
               abs(now - handover.startBaseline) >= 0.85 * abs(travel) {
                handover.impact = time
                events.impact = RigMath.clamp(abs(centreVelocity) / 1.5, 0.4, 1)
            }
            if dominant != handover.speaker, handover.speaker == .devil ? now < 0.5 : now > 0.5 {
                dominant = handover.speaker
                events.flipped = handover.speaker
            }
            motion = .handover(handover)
        }
        return events
    }

    /// Semi-implicit Euler on r″ = −900r − 18r′ + 1400(r₋ + r₊ − 2r), free ends.
    private mutating func stepRipple() {
        let n = Self.rippleCount, dt = SpringSpec.step
        var previous = ripple[0]
        for i in 0..<n {
            let left = previous, right = ripple[min(i + 1, n - 1)]
            let r = ripple[i]
            previous = r
            let acceleration = -900 * r - 18 * rippleVelocity[i] + 1400 * (left + right - 2 * r)
            rippleVelocity[i] += acceleration * dt
        }
        for i in 0..<n {
            ripple[i] += rippleVelocity[i] * dt
            if abs(ripple[i]) > Self.rippleLimit {
                ripple[i] = RigMath.clamp(ripple[i], -Self.rippleLimit, Self.rippleLimit)
                if ripple[i] * rippleVelocity[i] > 0 { rippleVelocity[i] = 0 }
            }
        }
    }

    /// The listener's walls: when the live seam's extreme over the listener's face span passes
    /// its wall, the base moves it back onto the wall and that point's velocity is reflected
    /// × −0.35. The drawn base is base·k + 0.075·relax, so the base moves 1/k as far.
    private mutating func applyWalls() {
        let k = 1 - 0.15 * relax.value
        guard k > 0.1, limits.maxLowest.isFinite || limits.minHighest.isFinite else { return }
        // A cheap bound on every term first: the seam is usually far from its walls.
        let s = effectiveShape
        let centre = s.base + windup.value
        let bulgeTerm = s.bulge * (1 + 0.06 * energyAngel)
        var reach = abs(s.wave) + abs(s.drift) + abs(pulse.value)
            + abs(breath.value) * Self.breathAmplitude
        if options.ripple { reach += 1.25 * rippleMagnitude }
        if limits.maxLowest.isFinite, centre + max(0, bulgeTerm) + reach > limits.maxLowest {
            let lowest = extreme(lowest: true)
            if lowest.value > limits.maxLowest + Self.wallTolerance {
                base.value -= (lowest.value - limits.maxLowest) / k
                let v = velocity(at: lowest.u)
                if v > 0 { base.velocity -= 1.35 * v / k }
            }
        }
        if limits.minHighest.isFinite, centre + min(0, bulgeTerm) - reach < limits.minHighest {
            let highest = extreme(lowest: false)
            if highest.value < limits.minHighest - Self.wallTolerance {
                base.value += (limits.minHighest - highest.value) / k
                let v = velocity(at: highest.u)
                if v < 0 { base.velocity -= 1.35 * v / k }
            }
        }
    }

    /// The live seam's lowest (largest) or highest (smallest) value over the walls' span, at
    /// nine points.
    private func extreme(lowest: Bool) -> (u: Double, value: Double) {
        let span = limits.span
        var best = (u: span.lowerBound, value: lowest ? -Double.infinity : Double.infinity)
        for i in 0...8 {
            let u = span.lowerBound + (span.upperBound - span.lowerBound) * Double(i) / 8
            let y = value(at: u)
            if lowest ? y > best.value : y < best.value { best = (u, y) }
        }
        return best
    }

    /// Rounding slack before a wall acts, so a seam settled exactly on its wall stays put.
    private static let wallTolerance = 1e-12

    // MARK: Reading

    /// σ_d: +1 while the angel is dominant, −1 while the devil is.
    var sigma: Double { dominant == .angel ? 1 : -1 }

    /// The centre's baseline, base + bulge + windup.
    var baseline: Double { base.value + bulge.value + windup.value }

    /// The baseline's velocity in band/s.
    var centreVelocity: Double { base.velocity + bulge.velocity + windup.velocity }

    /// The relaxed values that are drawn.
    var effectiveShape: SeamShape {
        SeamShape(base: base.value, bulge: bulge.value, wave: wave.value, drift: drift.value).relaxed(relax.value)
    }

    /// The live seam at `u` (band fraction), every term included.
    func value(at u: Double) -> Double {
        let u = RigMath.clamp(u, 0, 1)
        let s = effectiveShape
        return s.base + windup.value
            + s.bulge * (1 + 0.06 * energyAngel) * KeyPoses.bulge(u)
            + s.wave * KeyPoses.wave(u, phase: phase)
            + s.drift * Self.driftProfile(u, phases: driftPhases, still: driftStill.value)
            + pulse.value * sigma * 4 * u * (1 - u)
            + (options.ripple ? CatmullRom.sample(ripple, at: u) : 0)
            + breath.value * Self.breathAmplitude * sin(2 * Double.pi * Self.breathRate * time)
    }

    /// How fast the live seam at `u` moves (band/s): every term's rate but the breath's and
    /// the energy's, which are slow.
    func velocity(at u: Double) -> Double {
        let u = RigMath.clamp(u, 0, 1)
        let r = relax.value, rv = relax.velocity
        let baseRate = base.velocity * (1 - 0.15 * r) + (0.5 - base.value) * 0.15 * rv
        let bulgeRate = (bulge.velocity * (1 - 0.15 * r) - bulge.value * 0.15 * rv) * (1 + 0.06 * energyAngel)
        let waveRate = wave.velocity * (1 - 0.4 * r) - wave.value * 0.4 * rv
        let angle = 2 * Double.pi * (u / KeyPoses.waveLength - phase)
        return baseRate + windup.velocity + bulgeRate * KeyPoses.bulge(u) + waveRate * sin(angle)
            - wave.value * (1 - 0.4 * r) * cos(angle) * 2 * Double.pi * phaseRate
            + driftVelocity(at: u)
            + pulse.velocity * sigma * 4 * u * (1 - u)
            + (options.ripple ? CatmullRom.sample(rippleVelocity, at: u) : 0)
    }

    /// The live seam at the 49 samples u_k = k/48, written into `samples`.
    func fill(_ samples: inout [Double]) {
        if samples.count != Self.sampleCount {
            samples = Array(repeating: 0, count: Self.sampleCount)
        }
        for k in 0..<Self.sampleCount {
            samples[k] = value(at: Double(k) / Double(Self.sampleCount - 1))
        }
    }

    /// The largest |ripple| node.
    var rippleMagnitude: Double { ripple.reduce(0) { max($0, abs($1)) } }

    /// The handover's speaker stretches while the base still moves at half its peak speed.
    var isStretching: Bool {
        if case .handover(let handover) = motion { return handover.launched && !handover.stretchEnded }
        return false
    }

    /// Every spring but the breath settled, the ripple still, the wave not travelling and no
    /// choreography pending (the drift may flow at its settled amplitude).
    var isMotionSettled: Bool {
        guard base.isSettled, bulge.isSettled, wave.isSettled, windup.isSettled, pulse.isSettled,
              relax.isSettled, drift.isSettled, driftStill.isSettled, phaseRate == 0 else {
            return false
        }
        if case .handover(let handover) = motion, !handover.launched || !handover.baseStarted { return false }
        for i in 0..<Self.rippleCount where abs(ripple[i]) > 1e-5 || abs(rippleVelocity[i]) > 1e-4 {
            return false
        }
        return true
    }

    /// Everything at rest: no breath, and the drift still.
    var isSettled: Bool { isMotionSettled && breath.isSettled && breath.target == 0 && !driftTravels }

    /// Breath and the idle drift's flow are the only motion left.
    var isAmbientOnly: Bool { (breath.target > 0 || driftTravels) && isMotionSettled }

    /// The largest spring speed, for the Reduce Motion checks.
    var maxSpringSpeed: Double {
        [base, bulge, wave, windup, pulse, relax, breath, drift, driftStill].reduce(0) {
            max($0, abs($1.velocity))
        }
    }

    private mutating func use(base baseSpec: SpringSpec, bulge bulgeSpec: SpringSpec) {
        base.use(baseSpec)
        bulge.use(bulgeSpec)
        wave.use(bulgeSpec)
        drift.use(.relax)
    }

    private mutating func retargetAll() {
        base.retarget(shape.base)
        bulge.retarget(shape.bulge)
        wave.retarget(shape.wave)
        drift.retarget(driftTarget)
    }

    /// The drift's amplitude target: the shape's.
    private var driftTarget: Double { shape.drift }

    /// The drift rolls and swells while any of its flow shows.
    var driftTravels: Bool {
        (abs(drift.value) > 1e-6 || abs(drift.velocity) > 1e-5) && (driftStill.value < 1 - 1e-6 || driftStill.target < 1)
    }

    /// The drift's shape at `u` per unit of amplitude: the rolling, swelling S, mixed `still` of
    /// the way into the still S. Either way, and between, it is one wavelength of a sine.
    /// |profile| ≤ 1, and its mean over the window is 0.
    static func driftProfile(_ u: Double, phases: (Double, Double), still: Double) -> Double {
        let flowing = driftSwelling(phases.1) * sin(2 * Double.pi * (u - phases.0))
        let resting = driftStillShare * sin(2 * Double.pi * u)
        return flowing + (resting - flowing) * still
    }

    /// The S's share of the amplitude at swell phase `phase`: all of it at phase 0.
    private static func driftSwelling(_ phase: Double) -> Double {
        1 - (1 - driftSwell) * 0.5 * (1 - cos(2 * Double.pi * phase))
    }

    /// The ambient motion's part of the live seam at `u` (band): the idle drift and the breath,
    /// both level on average.
    func ambientValue(at u: Double) -> Double {
        effectiveShape.drift * Self.driftProfile(RigMath.clamp(u, 0, 1), phases: driftPhases, still: driftStill.value)
            + breath.value * Self.breathAmplitude * sin(2 * Double.pi * Self.breathRate * time)
    }

    /// The drift term's rate at `u` (band/s): the amplitude's, the settling's and the S's roll
    /// and swell.
    private func driftVelocity(at u: Double) -> Double {
        let twoPi = 2 * Double.pi
        let angle = twoPi * (u - driftPhases.0)
        let swelling = Self.driftSwelling(driftPhases.1)
        let flowing = swelling * sin(angle)
        let resting = Self.driftStillShare * sin(twoPi * u)
        let m = driftStill.value
        var travel = 0.0
        if driftTravels {
            let swellRate = -(1 - Self.driftSwell) * 0.5 * sin(twoPi * driftPhases.1) * twoPi / Self.driftPeriods.swell
            travel = swellRate * sin(angle) - swelling * cos(angle) * twoPi / Self.driftPeriods.roll
        }
        let profile = flowing + (resting - flowing) * m
        return drift.velocity * profile + drift.value * ((resting - flowing) * driftStill.velocity + (1 - m) * travel)
    }
}

import Foundation

/// A precondition whose message survives `-O`: a failed check prints it and exits non-zero.
private func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition {
        FileHandle.standardError.write(Data("STAGE_RIG_CHECK_FAILED: \(message())\n".utf8))
        exit(1)
    }
}

private func near(_ actual: Double, _ expected: Double, _ tolerance: Double, _ message: @autoclosure () -> String) {
    check(actual.isFinite && abs(actual - expected) <= tolerance,
          "\(message()): \(actual) is not within \(tolerance) of \(expected)")
}

private func near(_ actual: Vec2, _ expected: Vec2, _ tolerance: Double, _ message: @autoclosure () -> String) {
    near(actual.x, expected.x, tolerance, "\(message()) x")
    near(actual.y, expected.y, tolerance, "\(message()) y")
}

/// Foundation-only checks of the stage rig, compiled with the rig sources and `-O`.
@main
enum StageRigChecks {
    static func main() {
        var sections: [String] = []
        springs(); sections.append("springs")
        support(); sections.append("randomness, envelopes, curves and stepping")
        cadence(); sections.append("cadence and determinism")
        geometry(); sections.append("face geometry and key poses")
        fidelity(); sections.append("seam and anchor fidelity")
        choreography(); sections.append("choreography")
        layoutMatrix(); sections.append("layout matrix")
        captionCues(); sections.append("caption cues")
        activity(); sections.append("activity and idle")
        idleDrift(); sections.append("idle drift")
        reduceMotion(); sections.append("Reduce Motion")
        palette(); sections.append("palette")
        faceFidelity(); sections.append("face fidelity")
        squashAndVolume(); sections.append("squash and volume")
        lipSync(); sections.append("lip sync")
        behaviour(); sections.append("behaviour")
        stress(); sections.append("seeded stress")
        smoothness(); sections.append("smoothness")
        intro(); sections.append("intro")
        timing()
        print("STAGE_RIG_CHECKS_PASSED: \(sections.joined(separator: ", "))")
    }

    // MARK: Springs

    /// The textbook solution of y″ + 2ζωy′ + ω²y = 0 from (y0, v0), written independently of
    /// `SpringSpec`'s transition matrices.
    static func closedForm(_ spec: SpringSpec, y0: Double, v0: Double, t: Double) -> (y: Double, v: Double) {
        let w = 2 * Double.pi / spec.response, z = spec.dampingFraction
        if z < 1 {
            let wd = w * (1 - z * z).squareRoot()
            let a = y0, b = (v0 + z * w * y0) / wd
            let e = exp(-z * w * t), c = cos(wd * t), s = sin(wd * t)
            let y = e * (a * c + b * s)
            let v = -z * w * y + e * (-a * wd * s + b * wd * c)
            return (y, v)
        }
        if z == 1 {
            let a = y0, b = v0 + w * y0
            let e = exp(-w * t)
            return (e * (a + b * t), e * (b - w * (a + b * t)))
        }
        let q = (z * z - 1).squareRoot()
        let r1 = -w * (z - q), r2 = -w * (z + q)
        let c2 = (v0 - r1 * y0) / (r2 - r1), c1 = y0 - c2
        return (c1 * exp(r1 * t) + c2 * exp(r2 * t), c1 * r1 * exp(r1 * t) + c2 * r2 * exp(r2 * t))
    }

    /// Classic RK4 on the spring ODE with a 10 µs step.
    static func integrated(_ spec: SpringSpec, y0: Double, v0: Double, t: Double) -> (y: Double, v: Double) {
        let w = 2 * Double.pi / spec.response, z = spec.dampingFraction
        func acceleration(_ y: Double, _ v: Double) -> Double { -w * w * y - 2 * z * w * v }
        let steps = Int((t / 1e-5).rounded()), h = t / Double(steps)
        var y = y0, v = v0
        for _ in 0..<steps {
            let k1y = v, k1v = acceleration(y, v)
            let k2y = v + h / 2 * k1v, k2v = acceleration(y + h / 2 * k1y, v + h / 2 * k1v)
            let k3y = v + h / 2 * k2v, k3v = acceleration(y + h / 2 * k2y, v + h / 2 * k2v)
            let k4y = v + h * k3v, k4v = acceleration(y + h * k3y, v + h * k3v)
            y += h / 6 * (k1y + 2 * k2y + 2 * k3y + k4y)
            v += h / 6 * (k1v + 2 * k2v + 2 * k3v + k4v)
        }
        return (y, v)
    }

    static func springs() {
        let overdamped = SpringSpec(response: 0.3, dampingFraction: 1.6)
        let specs = SpringSpec.presets + [("overdamped", overdamped)]
        // Each preset's response / ζ, in the presets' order.
        let table: [(String, Double, Double)] = [
            ("headAnchor", 0.42, 0.62), ("headScale", 0.50, 0.60), ("freeSquash", 0.24, 0.32),
            ("contactSquash", 0.12, 0.45), ("press", 0.12, 1.0), ("tilt", 0.55, 0.45), ("parallax", 0.30, 0.80),
            ("gaze", 0.08, 0.88), ("eyeOpen", 0.10, 0.85), ("eyeMorph", 0.18, 1.0), ("lids", 0.14, 0.80),
            ("glyph", 0.10, 1.0), ("brows", 0.18, 0.50), ("mouthExpression", 0.16, 0.70),
            ("mouthFeature", 0.12, 1.0), ("talkWeight", 0.08, 1.0), ("blush", 0.30, 1.0),
            ("cheekPuff", 0.28, 0.40), ("haloPosition", 0.34, 0.32), ("haloRotation", 0.45, 0.25),
            ("haloSquash", 0.20, 0.30), ("wingAngle", 0.30, 0.28), ("hornAngle", 0.20, 0.42),
            ("hornStretch", 0.16, 0.30), ("markPop", 0.25, 0.45), ("windupIn", 0.14, 1.0),
            ("windupOut", 0.10, 0.90), ("baseAngelPush", 0.44, 0.48), ("baseDevilPush", 0.38, 0.55),
            ("bulgeLaunch", 0.38, 0.34), ("collapse", 0.24, 0.50), ("waveAmplitude", 0.50, 0.60),
            ("releaseBase", 0.60, 0.75), ("releaseBulge", 0.45, 0.60), ("interruptBase", 0.30, 0.85),
            ("interruptBulge", 0.25, 0.85), ("lean", 0.45, 0.65), ("pulse", 0.22, 0.50),
            ("relax", 0.60, 0.80), ("driftSettle", 2.0, 1.0), ("bubble", 0.45, 0.85),
        ]
        check(SpringSpec.presets.count == table.count, "Every spring is a named preset")
        for (preset, row) in zip(SpringSpec.presets, table) {
            check(preset.name == row.0, "Preset \(preset.name) is in the table's order (expected \(row.0))")
            check(preset.spec.response == row.1 && preset.spec.dampingFraction == row.2,
                  "\(row.0) is \(preset.spec.response) / \(preset.spec.dampingFraction), the table says \(row.1) / \(row.2)")
        }
        near(SpringSpec.step, 1.0 / 240, 0, "the spring substep")
        check(SpringSpec.step == FixedStepper.step, "Springs and the stepper share the substep")
        check(specs.contains { $0.spec.dampingFraction < 1 } && specs.contains { $0.spec.dampingFraction == 1 }
                  && specs.contains { $0.spec.dampingFraction > 1 }, "All three damping regimes are covered")
        near(SpringSpec.bubble.response, 0.45, 0, "bubble response")
        near(SpringSpec.bubble.dampingFraction, 0.85, 0, "bubble damping")

        for (name, spec) in specs {
            near(spec.stiffness, pow(2 * Double.pi / spec.response, 2), 1e-9, "\(name) stiffness")
            near(spec.damping, 2 * spec.dampingFraction * 2 * Double.pi / spec.response, 1e-9, "\(name) damping")

            // 240 exact substeps equal the closed form at t = 1 s.
            var spring = RigSpring(1.5, spec: spec)
            spring.retarget(0.25)
            spring.kick(-3)
            for _ in 0..<240 { spring.step() }
            let exact = closedForm(spec, y0: 1.25, v0: -3, t: 1)
            near(spring.value - spring.target, exact.y, 1e-9, "\(name): 240 substeps vs closed form, position")
            near(spring.velocity, exact.v, 1e-9 * max(1, abs(exact.v)) + 1e-9, "\(name): 240 substeps vs closed form, velocity")
            // Arbitrary-interval transitions agree too, and with direct integration.
            let some = spec.transition(over: 0.37).apply(1.25, -3)
            let reference = closedForm(spec, y0: 1.25, v0: -3, t: 0.37)
            near(some.y, reference.y, 1e-9, "\(name): transition(over:) position")
            near(some.v, reference.v, 1e-8, "\(name): transition(over:) velocity")
            let solved = integrated(spec, y0: 1.25, v0: -3, t: 0.37)
            near(some.y, solved.y, 1e-8, "\(name): transition vs RK4 position")
            near(some.v, solved.v, 1e-6, "\(name): transition vs RK4 velocity")

            // Step response from rest: 0 → 1.
            var step = RigSpring(0, spec: spec)
            step.retarget(1)
            var peak = 0.0, peakIndex = 0
            var lastUnsettled = 0
            var states: [(x: Double, v: Double)] = [(0, 0)]
            let total = Int((12 * spec.response + 1) * 240)
            for i in 1...total {
                step.step()
                states.append((step.value, step.velocity))
                if step.value > peak { peak = step.value; peakIndex = i }
                if !step.isSettled { lastUnsettled = i }
            }
            let settleTime = Double(lastUnsettled + 1) / 240
            check(settleTime <= 6 * spec.response,
                  "\(name) settles in \(settleTime) s, more than 6·response (\(6 * spec.response) s)")
            check(step.isSettled, "\(name) stays settled")

            if spec.dampingFraction < 1 {
                // Refine the peak between the neighbouring substeps.
                let start = states[max(peakIndex - 1, 0)]
                let fine = SpringSpec.step / 2000
                let transition = spec.transition(over: fine)
                var y = start.x - 1, v = start.v
                for _ in 0..<4000 {
                    (y, v) = transition.apply(y, v)
                    peak = max(peak, 1 + y)
                }
                let expected = exp(-spec.dampingFraction * Double.pi / (1 - pow(spec.dampingFraction, 2)).squareRoot())
                near(peak - 1, expected, 0.005 * expected, "\(name) step-response overshoot")
                near(spec.overshoot, peak - 1, 0.005 * expected, "\(name) reported overshoot vs the stepped peak")
            } else {
                check(peak <= 1 + 1e-12, "\(name) (ζ ≥ 1) overshoots to \(peak)")
                check(spec.overshoot == 0, "\(name) reports an overshoot")
            }
        }

        // Operations keep state.
        var spring = RigSpring(2, spec: .tilt, range: 10)
        spring.retarget(5)
        spring.kick(4)
        check(spring.value == 2 && spring.velocity == 4 && spring.target == 5, "retarget and kick keep x and v")
        spring.step()
        let moved = (spring.value, spring.velocity)
        spring.use(.collapse)
        check(spring.value == moved.0 && spring.velocity == moved.1 && spring.transition == SpringSpec.collapse.transition,
              "Swapping the spec keeps state")
        check(!spring.isSettled, "A moving spring is not settled")
        spring.snap()
        check(spring.value == 5 && spring.velocity == 0 && spring.isSettled, "snap rests at the target")
        // Settling scales with the range: 0.005 off is settled for range 10, not for range 1.
        var wide = RigSpring(5.005, spec: .tilt, range: 10)
        wide.retarget(5)
        var narrow = RigSpring(5.005, spec: .tilt, range: 1)
        narrow.retarget(5)
        check(wide.isSettled && !narrow.isSettled, "Settling tolerance scales with the range")

        var pair = RigSpring2(Vec2(1, 2), spec: .headAnchor)
        pair.retarget(Vec2(-1, 4))
        pair.kick(Vec2(3, -3))
        pair.use(.haloPosition)
        check(pair.transition == SpringSpec.haloPosition.transition, "RigSpring2 switches spec")
        var singles = [RigSpring(1, spec: .haloPosition), RigSpring(2, spec: .haloPosition)]
        singles[0].retarget(-1)
        singles[0].kick(3)
        singles[1].retarget(4)
        singles[1].kick(-3)
        for _ in 0..<5 {
            pair.step()
            singles[0].step()
            singles[1].step()
        }
        check(pair.value == Vec2(singles[0].value, singles[1].value)
                  && pair.velocity == Vec2(singles[0].velocity, singles[1].velocity),
              "RigSpring2 steps like two springs")
        pair.snap()
        check(pair.value == Vec2(-1, 4) && pair.velocity == .zero && pair.isSettled, "RigSpring2 snaps to rest")
        // The rig holds about 160 springs, so each stays small.
        check(MemoryLayout<RigSpring>.stride <= 64, "RigSpring is \(MemoryLayout<RigSpring>.stride) bytes")
        check(MemoryLayout<RigSpring2>.stride <= 88, "RigSpring2 is \(MemoryLayout<RigSpring2>.stride) bytes")
    }

    // MARK: Randomness, envelopes, curves and stepping

    static func support() {
        // SplitMix64 reference outputs (Vigna's splitmix64.c).
        var zero = SplitMix64(seed: 0)
        check(zero.next() == 0xE220_A839_7B1D_CDAF && zero.next() == 0x6E78_9E6A_A1B9_65F4, "SplitMix64 seed 0")
        var reference = SplitMix64(seed: 1_234_567)
        let expected: [UInt64] = [6_457_827_717_110_365_317, 3_203_168_211_198_807_973, 9_817_491_932_198_370_423,
                                  4_593_380_528_125_082_431, 16_408_922_859_458_223_821]
        check((0..<5).map { _ in reference.next() } == expected, "SplitMix64 seed 1234567")
        // Each stream has its own salt, and the streams are independent.
        check(SplitMix64(seed: 7, stream: .angel).state == 7 ^ 0x9E37_79B9_7F4A_7C15, "angel salt")
        check(SplitMix64(seed: 7, stream: .devil).state == 7 ^ 0xD1B5_4A32_D192_ED03, "devil salt")
        check(SplitMix64(seed: 7, stream: .stage).state == 7 ^ 0x94D0_49BB_1331_11EB, "stage salt")
        var angel = SplitMix64(seed: 7, stream: .angel), devil = SplitMix64(seed: 7, stream: .devil)
        check(angel.next() != devil.next(), "Streams differ")
        var again = SplitMix64(seed: 7, stream: .angel), once = SplitMix64(seed: 7, stream: .angel)
        check((0..<100).map { _ in again.next() } == (0..<100).map { _ in once.next() }, "Same seed, same draws")
        var uniform = SplitMix64(seed: 42)
        var sum = 0.0, low = 1.0, high = 0.0, heads = 0
        for _ in 0..<100_000 {
            let u = uniform.uniform()
            sum += u; low = min(low, u); high = max(high, u)
            let r = uniform.uniform(in: 0.7...1.4)
            check(r >= 0.7 && r <= 1.4, "uniform(in:) stays in range")
            if uniform.sign() > 0 { heads += 1 }
        }
        check(low >= 0 && high < 1, "uniform() is in [0, 1)")
        near(sum / 100_000, 0.5, 0.005, "uniform mean")
        near(Double(heads) / 100_000, 0.5, 0.01, "sign balance")

        // Easing.
        near(RigMath.smoothstep(1, 4, 1), 0, 0, "smoothstep low edge")
        near(RigMath.smoothstep(1, 4, 4), 1, 0, "smoothstep high edge")
        near(RigMath.smoothstep(1, 4, 2.5), 0.5, 1e-12, "smoothstep midpoint")
        near(RigMath.easeInOut(0.5), 0.5, 1e-12, "easeInOut midpoint")
        var previous = -1.0
        for i in 0...100 {
            let value = RigMath.easeInOut(Double(i) / 100)
            check(value >= previous, "easeInOut is monotonic")
            previous = value
        }
        let back = RigMath.backConstant(overshoot: 0.04)
        let backPeak = (0...10_000).map { RigMath.easeOutBack(Double($0) / 10_000, c: back) }.max()!
        near(backPeak, 1.04, 1e-6, "ease-out-back peak overshoot")
        near(RigMath.easeOutBack(1, c: back), 1, 1e-12, "ease-out-back ends at 1")

        // Blink: close 60 ms (ease-in), hold 40 ms, open 120 ms with a 4% overshoot.
        near(BlinkEnvelope.duration, 0.22, 1e-12, "blink duration")
        near(BlinkEnvelope.closure(at: 0.03), 0.25, 1e-12, "blink eases in")
        for t in stride(from: 0.06, through: 0.1, by: 0.01) { near(BlinkEnvelope.closure(at: t), 1, 1e-12, "blink hold at \(t)") }
        let reopening = stride(from: 0.1, through: 0.22, by: 0.0001)
        check(reopening.allSatisfy { (0...1).contains(BlinkEnvelope.closure(at: $0)) }, "closure stays in 0…1")
        near(reopening.map { BlinkEnvelope.reopenGain(at: $0) }.max()!, 1.04, 1e-4, "blink reopens 4% past rest")
        // The eye's openness, as the renderer draws it (`open·(1 − max(blink, closed))·reopen`),
        // keeps the overshoot: a fully open eye peaks at 1.04, a half-closed one at 0.52, and a
        // shut eye stays shut.
        func openness(at t: Double, open: Double, closed: Double) -> Double {
            open * (1 - max(BlinkEnvelope.closure(at: t), closed)) * BlinkEnvelope.reopenGain(at: t)
        }
        let peaks = [(1.0, 0.0), (1.0, 0.5), (1.2, 1.0)].map { open, closed in
            reopening.map { openness(at: $0, open: open, closed: closed) }.max()!
        }
        near(peaks[0], 1.04, 1e-4, "open eye overshoot")
        near(peaks[1], 0.52, 1e-4, "half-closed eye overshoot")
        near(peaks[2], 0, 0, "a closed eye stays closed through a blink")
        near(openness(at: 0.08, open: 1, closed: 0), 0, 0, "shut at the hold")
        near(openness(at: 0.03, open: 1, closed: 0.5), 0.5, 1e-12, "closed wins over a light blink")
        for t in stride(from: 0.0, through: 0.1, by: 0.005) {
            near(BlinkEnvelope.reopenGain(at: t), 1, 0, "no gain before the reopening at \(t)")
        }
        near(BlinkEnvelope.closure(at: 0.22), 0, 0, "blink ends open")
        near(BlinkEnvelope.reopenGain(at: 0.22), 1, 0, "no gain after the blink")
        near(BlinkEnvelope.closure(at: -0.01), 0, 0, "no blink before it starts")

        // The eye roll path.
        let home = Vec2(0.1, 0.2)
        let roll = GazePath.eyeRoll(from: home, direction: -1)
        near(roll.duration, 1.02, 1e-12, "eye roll duration")
        near(roll.value(at: 0), home, 1e-12, "roll starts at home")
        near(roll.value(at: 0.16), Vec2(0.85, -0.35), 1e-12, "roll first key")
        near(roll.value(at: 0.36), Vec2(0, -1), 1e-12, "roll top")
        near(roll.value(at: 0.56), Vec2(-0.85, -0.35), 1e-12, "roll far side")
        near(roll.value(at: 0.74), Vec2(-0.85, -0.35), 1e-12, "roll hold")
        near(roll.value(at: 1.02), home, 1e-12, "roll returns home")
        var last = roll.value(at: 0)
        for i in 1...1020 {
            let point = roll.value(at: Double(i) / 1000)
            check((point - last).length < 0.02, "The roll path is continuous at \(i) ms")
            last = point
        }

        // Catmull-Rom: the Bézier form equals the Catmull-Rom polynomial.
        let points = [Vec2(0, 0), Vec2(10, 4), Vec2(25, -3), Vec2(31, 8), Vec2(50, 2)]
        var segments: [(Vec2, Vec2, Vec2, Vec2)] = []
        CatmullRom.forEachSegment(points) { segments.append(($0, $1, $2, $3)) }
        check(segments.count == points.count - 1, "One segment per gap")
        for (i, segment) in segments.enumerated() {
            near(segment.0, points[i], 0, "segment start")
            near(segment.3, points[i + 1], 0, "segment end")
            let p0 = points[max(i - 1, 0)], p3 = points[min(i + 2, points.count - 1)]
            for k in 0...10 {
                let t = Double(k) / 10, s = 1 - t
                let bezier = segment.0 * (s * s * s) + segment.1 * (3 * s * s * t) + segment.2 * (3 * s * t * t)
                    + segment.3 * (t * t * t)
                let x = CatmullRom.value(p0.x, points[i].x, points[i + 1].x, p3.x, t)
                let y = CatmullRom.value(p0.y, points[i].y, points[i + 1].y, p3.y, t)
                near(bezier, Vec2(x, y), 1e-9, "Bézier vs Catmull-Rom, segment \(i) t \(t)")
            }
        }
        let nodes = [0.0, 0.01, -0.02, 0.015, 0.0]
        for (i, node) in nodes.enumerated() {
            near(CatmullRom.sample(nodes, at: Double(i) / 4), node, 1e-12, "sample passes through node \(i)")
        }
        near(CatmullRom.sample(nodes, at: -1), 0, 0, "edge value holds outside")

        // Fixed stepping: substeps land on k/240 whatever the frame cadence.
        near(Double(FixedStepper.index(atOrAfter: 0.25)), 60, 0, "0.25 s is boundary 60")
        near(Double(FixedStepper.index(atOrAfter: 0.2501)), 61, 0, "just after 0.25 s rounds up")
        near(Double(FixedStepper.index(atOrBefore: 0.2501)), 60, 0, "just after 0.25 s rounds down")
        let quarters = (1...12).map { Double($0) / 4 }
        /// Steps `stepper` toward `frame` as the simulation does: one boundary at a time, at most
        /// `maxSteps` per frame. Returns each substep's time.
        func advance(_ stepper: inout FixedStepper, to frame: Double) -> [Double] {
            let target = FixedStepper.index(atOrBefore: frame)
            var times: [Double] = []
            while stepper.index < target, times.count < FixedStepper.maxSteps {
                stepper.skip(to: stepper.time + FixedStepper.step)
                times.append(stepper.time)
            }
            return times
        }
        func ticks(frames: [Double]) -> (all: [Double], atQuarters: [Double]) {
            var stepper = FixedStepper()
            var all: [Double] = [], reached: [Double] = []
            for frame in frames {
                all += advance(&stepper, to: frame)
                if quarters.contains(frame) { reached.append(stepper.time) }
            }
            return (all, reached)
        }
        /// Frame times at `hz`, with every quarter second also a frame time.
        func cadence(_ hz: Double) -> [Double] {
            Array(Set((1...Int(3 * hz)).map { Double($0) / hz } + quarters)).sorted()
        }
        // 8–17 ms seeded jitter with one 90-ms hitch.
        var jitter = SplitMix64(seed: 3)
        var jittered: [Double] = []
        var clock = 0.0, hitched = false
        while clock < 3 {
            var dt = jitter.uniform(in: 0.008...0.017)
            if !hitched && clock > 1.3 { dt = 0.09; hitched = true }
            let next = min(clock + dt, 3)
            jittered += quarters.filter { $0 > clock && $0 < next }
            jittered.append(next)
            clock = next
        }
        let runs = [cadence(30), cadence(60), cadence(120), jittered].map(ticks)
        for run in runs.dropFirst() {
            check(run.all == runs[0].all, "Substep times are independent of the frame cadence")
            check(run.atQuarters == runs[0].atQuarters, "Every quarter second is reached exactly")
        }
        check(runs[0].atQuarters == quarters, "Quarter-second frames land on their own boundaries")
        check(runs[0].all.count == 720 && runs[0].all.last == 3, "3 s is 720 substeps")
        var capped = FixedStepper()
        check(advance(&capped, to: 0.5).count == FixedStepper.maxSteps, "At most 24 substeps per frame")
        near(capped.time, 0.1, 1e-15, "A hitch advances 0.1 s")
        capped.skip(to: 3600.001)
        near(capped.time, 3600, 1e-12, "skip lands on the boundary at or before")
        check(advance(&capped, to: 3600.001).isEmpty, "Nothing to step after a skip")
    }

    // MARK: Face geometry and key poses

    static func geometry() {
        // The angel's brow: a 32-fu chord at its base angle.
        let chord = AngelGeometry.browInner - AngelGeometry.browOuter
        near(chord.length, 32, 0.5, "angel brow chord length")
        near(atan2(chord.y, abs(chord.x)) * 180 / Double.pi, AngelGeometry.browBaseAngle, 1, "angel brow base angle")
        // The halo sits on the face's midline, its top 140.8 fu above the eyes.
        check(AngelGeometry.haloCenter.x == 0, "the halo is centred on the midline")
        near(AngelGeometry.haloTop, -140.8, 0.2, "angel halo top")
        // The wing's top lobe and feather tips fill its box, around the hinge.
        let lobes = [AngelGeometry.wingTopLobe] + WingShape.featherTips
        near(lobes.map { $0.center.x - $0.radius }.min()!, AngelGeometry.wingBoxMin.x, 3, "wing outer extent")
        near(lobes.map { $0.center.y - $0.radius }.min()!, AngelGeometry.wingBoxMin.y, 3, "wing top")
        near(lobes.map { $0.center.y + $0.radius }.max()!, AngelGeometry.wingBoxMax.y, 3, "wing bottom")
        for lobe in lobes {
            check(lobe.center.x + lobe.radius <= AngelGeometry.wingBoxMax.x + 3, "wing lobe inside the box")
        }
        let hinge = AngelGeometry.wingHinge
        check(hinge.x <= AngelGeometry.wingBoxMax.x && hinge.x >= AngelGeometry.wingBoxMin.x
                  && hinge.y <= AngelGeometry.wingBoxMax.y && hinge.y >= AngelGeometry.wingBoxMin.y, "wing hinge in the box")
        // Everything at rest lies in the layout box.
        let angelExtents = [AngelGeometry.wingBoxMin, AngelGeometry.wingBoxMax,
                            AngelGeometry.haloCenter - AngelGeometry.haloOuterSize / 2,
                            AngelGeometry.haloCenter + AngelGeometry.haloOuterSize / 2,
                            Vec2(0, AngelGeometry.mouthAnchor.y + AngelGeometry.mouthDepth),
                            AngelGeometry.blush.center + AngelGeometry.blush.size / 2,
                            AngelGeometry.upperDash.center, AngelGeometry.lowerDash.center]
        for point in angelExtents {
            check(abs(point.x) <= AngelGeometry.layoutBoxMax.x && point.y >= AngelGeometry.layoutBoxMin.y
                      && point.y <= AngelGeometry.layoutBoxMax.y, "angel feature \(point) outside the layout box")
        }

        // The devil's brow drops at its base angle; his grin's corners and bottom follow from its
        // width, skew and shift.
        let devilChord = DevilGeometry.browInner - DevilGeometry.browOuter
        near(atan2(devilChord.y, abs(devilChord.x)) * 180 / Double.pi, DevilGeometry.browBaseAngle, 0.5, "devil brow angle")
        let anchor = DevilGeometry.mouthAnchor, w = DevilGeometry.mouthWidth
        let left = Vec2(anchor.x + DevilGeometry.neutralShiftX - w / 2, anchor.y + DevilGeometry.mouthSkew)
        let right = Vec2(anchor.x + DevilGeometry.neutralShiftX + w / 2, anchor.y - DevilGeometry.mouthSkew)
        near(left, DevilGeometry.mouthLeftCorner, 1e-9, "devil left corner")
        near(right, DevilGeometry.mouthRightCorner, 1e-9, "devil right corner")
        near(anchor.y + DevilGeometry.mouthDepth, 62.5, 1e-9, "devil mouth bottom")
        // The horn's crescent: the back bulges well past the outer base, a little below half
        // height, and the base rises steeply toward the face. The hinge is the base's midpoint.
        let outerBase = DevilGeometry.hornOuterBase, bulge = DevilGeometry.hornBulge
        check(outerBase.x - bulge.x >= 8 && outerBase.x - bulge.x <= 16,
              "the horn's back bulges \(outerBase.x - bulge.x) fu past the outer base, not 8–16")
        let bulgeHeight = (outerBase.y - bulge.y) / (outerBase.y - DevilGeometry.hornTip.y)
        check((0.35...0.6).contains(bulgeHeight), "the horn's widest point at \(bulgeHeight) of its height, not 0.35–0.6")
        let hornBase = DevilGeometry.hornInnerBase - outerBase
        let hornBaseAngle = atan2(-hornBase.y, hornBase.x) * 180 / Double.pi
        check((34...45).contains(hornBaseAngle), "the horn's base rises \(hornBaseAngle)° toward the face, not 34–45°")
        near(DevilGeometry.hornHinge, Vec2(-118.7, -59.5), 0.1, "horn hinge")
        let devilExtents = [DevilGeometry.hornTip, DevilGeometry.hornOuterBase, DevilGeometry.hornBulge,
                            DevilGeometry.mouthLeftCorner, DevilGeometry.mouthRightCorner,
                            Vec2(0, anchor.y + DevilGeometry.mouthDepth),
                            DevilGeometry.blush.center + DevilGeometry.blush.size / 2,
                            DevilGeometry.browOuter.sided(-1)]
            + DevilGeometry.motionMarks.map { $0.center + Vec2(cos($0.angle * .pi / 180), 0) * ($0.length / 2) }
        for point in devilExtents {
            check(abs(point.x) <= DevilGeometry.layoutBoxMax.x + 0.5 && point.y >= DevilGeometry.layoutBoxMin.y
                      && point.y <= DevilGeometry.layoutBoxMax.y, "devil feature \(point) outside the layout box")
        }

        // The angel speaking: the fitted bulge reproduces her seam.
        check(KeyPoses.angelFloorSeam.count == KeyPoses.seamU.count, "one sample per u")
        for (u, v) in zip(KeyPoses.seamU, KeyPoses.angelFloorSeam) {
            let fit = KeyPoses.angelFloorBase + KeyPoses.angelFloorBulge * KeyPoses.bulge(u)
            near(fit, v, 0.003, "the angel-speaking seam's fit at u \(u)")
        }
        // The squished devil's pivot is pinned to the floor: eye line 70 fu above it at sy 0.78.
        let floorGap = (KeyPoses.angelFloorFloor - KeyPoses.angelFloorDevil.eyeLine) * 600
        near(floorGap, DevilGeometry.squishPivot.y * KeyPoses.angelFloorDevil.scale.y, 1, "devil floor pivot")
        // The devil speaking: the wave's highest point at u 0.25 and lowest near 0.6; φ puts the
        // crest there.
        near(KeyPoses.restPhase, 0.25 / KeyPoses.waveLength + 0.25, 1e-4, "rest phase")
        let wave = { (u: Double) in KeyPoses.devilFloorMean + KeyPoses.devilFloorAmplitude * KeyPoses.wave(u) }
        near(wave(KeyPoses.devilFloorHighest.u), KeyPoses.devilFloorHighest.v, 0.002,
             "the devil-speaking wave's highest point")
        near(wave(KeyPoses.devilFloorLowest.u), KeyPoses.devilFloorLowest.v, 0.002,
             "the devil-speaking wave's lowest point")
        let crest = stride(from: 0.0, through: 0.5, by: 0.001).min { wave($0) < wave($1) }!
        near(crest, 0.25, 0.002, "the crest is at u 0.25")
        // The squished angel hangs from her halo top at the ceiling.
        let ceilingGap = (KeyPoses.devilFloorAngel.eyeLine - KeyPoses.devilFloorHaloTop) * 600
        near(ceilingGap, -AngelGeometry.squishPivot.y * KeyPoses.devilFloorAngel.scale.y, 2.5,
             "angel ceiling pivot")
        near(AngelGeometry.squishPivot.y, AngelGeometry.haloTop, 0.5, "the angel's pivot is her halo top")
        // The speaking devil's horn tips (untilted), from his eye line and scale:
        // 0.661 − 117·1.10/600 = 0.4465.
        let hornTips = KeyPoses.devilFloorDevil.eyeLine
            + DevilGeometry.hornTip.y * KeyPoses.devilFloorDevil.scale.y / 600
        check((0.43...0.46).contains(hornTips), "the speaking devil's horn tips at \(hornTips), outside 0.43–0.46")
        near(hornTips, KeyPoses.devilFloorHornTips.upperBound, 0.005, "the speaking devil's horn tips")
        // The squash targets the fidelity checks hold the rig to: the squished listeners' contact
        // pressures (devil 0.78, angel 0.92) and free faces at 1.
        let faces = [KeyPoses.neutralAngel, KeyPoses.neutralDevil, KeyPoses.angelFloorAngel,
                     KeyPoses.angelFloorDevil, KeyPoses.devilFloorAngel, KeyPoses.devilFloorDevil]
        check(faces.map(\.squashTarget) == [1, 1, 1, 0.78, 0.92, 1], "the key poses' squash targets")
        check(KeyPoses.devilFloorAngel.scale == Vec2(0.95, 0.95), "the squished angel at 0.95")
        check(KeyPoses.angelFloorDevil.scale == Vec2(1.0, 0.78), "the squished devil at 1.0 × 0.78")
    }

    // MARK: Caption cues

    static func captionCues() {
        typealias Case = (text: String, speaker: DuoCharacter?, cues: Set<Cue>)
        let cases: [Case] = [
            ("Go to the gym tonight.", .angel, []),
            ("You will feel wonderful.", .angel, [.virtue]),
            ("Oh, please, Angel!", .devil, [.scoff, .exclaim, .mentionsAngel]),
            ("The sofa is so much comfier.", .devil, []),
            ("…your favourite treat.", .devil, []),
            ("Deal?", .devil, [.question]),
            ("Ha! Fine.", .devil, [.laugh]),
            ("Ha.", .devil, []),
            ("Haha, nice try!", .devil, [.laugh, .exclaim]),
            ("I have a hat.", .angel, []),
            ("That shall do.", .angel, []),
            ("Chalk it up.", .devil, []),
            ("Aha, I see.", .angel, []),
            ("He said hello.", .angel, []),
            ("Hehe, gotcha.", .devil, [.laugh]),
            ("lol okay", nil, [.laugh]),
            ("HAHA", nil, [.laugh]),
            ("😂 okay", nil, [.laugh]),
            ("Live a little!", .devil, [.temptation, .exclaim]),
            ("Live a little!", .angel, [.exclaim]),
            ("Why not order pizza?", .devil, [.temptation, .question]),
            ("What do you think, Devil?", .angel, [.question, .mentionsDevil]),
            ("That's a devil-may-care attitude.", .angel, []),
            ("Wow, really?", .angel, [.wow, .question]),
            ("No, don't skip leg day.", .angel, []),
            ("You can have fun later.", .devil, []),
            ("Seriously? Again?", .devil, [.scoff, .question]),
            ("I'm kind of tired.", .angel, []),
            ("Be kind to yourself.", .angel, [.virtue]),
            ("Who cares about steps?", .devil, [.temptation, .question]),
            ("Ugh, fine.", .devil, [.scoff]),
            ("Pfft. Boring.", .devil, [.scoff]),
            ("Treat yourself!", .devil, [.temptation, .exclaim]),
            // Trimming, both-punctuation endings and speaker gating.
            ("\"Are you sure?\"", .angel, [.question]),
            ("(Fine!)", .devil, [.exclaim]),
            ("Let's go! 🎉", .devil, [.exclaim]),
            ("Wait, what?!", nil, [.question, .exclaim]),
            ("Really!? 😂", nil, [.laugh, .question, .exclaim]),
            ("No way!", .angel, [.wow, .exclaim]),
            ("That is amazing.", .devil, [.wow]),
            ("Whoa.", nil, [.wow]),
            ("Is that healthy?", .devil, [.question]),
            ("I'm so proud of you.", .angel, [.virtue]),
            ("I promise.", .devil, []),
            ("Just this once, okay?", .devil, [.temptation, .question]),
            ("Nobody will know.", .devil, [.temptation]),
            ("Skip the salad.", .devil, [.temptation]),
            ("Skip it.", .angel, []),
            ("Ha ha.", .devil, []),
            ("Lollipops are sweet.", .devil, []),
            ("Oh sure, Angel.", .devil, [.scoff, .mentionsAngel]),
            ("Yeah, right.", .devil, [.scoff]),
            ("As if!", .devil, [.scoff, .exclaim]),
            ("Puh-lease.", .devil, [.scoff]),
            ("The Angel's right, Devil.", nil, [.mentionsAngel, .mentionsDevil]),
            ("She's an angelic sort.", .devil, []),
            ("Hahaha, oh no.", .angel, [.laugh]),
            ("I'm not seriously worried.", .angel, []),
            ("Go on, live a little!!!", .devil, [.temptation, .exclaim]),
            // Emoji forms of the marks are the marks, not trimmable emoji.
            ("No way\u{203C}", .angel, [.wow, .exclaim]),
            ("Really\u{2049}", nil, [.exclaim, .question]),
            ("Stop\u{2757}\u{FE0F}", nil, [.exclaim]),
            ("Why\u{2753} \u{1F602}", nil, [.question, .laugh]),
            ("Sure\u{2754}\u{2755}", nil, [.question, .exclaim]),
            ("Love it \u{2764}\u{FE0F}", nil, []),
        ]
        check(cases.count >= 30, "At least 30 sentences")
        for item in cases {
            let cues = CaptionCues.classify(item.text, speaker: item.speaker)
            check(cues == item.cues,
                  "\(item.text.debugDescription) (\(item.speaker?.rawValue ?? "human")): \(cues) != \(item.cues)")
        }
        check(CaptionCues.trailingPunctuation("Go on, live a little!!!") == "!!!", "three !")
        check(CaptionCues.trailingPunctuation("Why?!") == "?!", "?! ends a question and an exclamation")
        check(CaptionCues.trailingPunctuation("Fine.").isEmpty, "no exclamation")
        check(CaptionCues.trailingPunctuation("Yes!! 😂\"") == "!!", "trailing emoji and quotes are trimmed")
        check(CaptionCues.trailingPunctuation("No way\u{203C}") == "!!", "‼ is two !")
        check(CaptionCues.trailingPunctuation("Really\u{2049}\u{FE0F}") == "!?", "⁉ is !?")
    }

    // MARK: Palette

    /// Every colour inside `value`, found by reflection so new tokens are covered automatically.
    static func colors(in value: Any, path: String = "colors") -> [(String, RGBA)] {
        if let color = value as? RGBA { return [(path, color)] }
        return Mirror(reflecting: value).children.enumerated().flatMap { index, child in
            colors(in: child.value, path: "\(path).\(child.label ?? String(index))")
        }
    }

    static func palette() {
        let sampled = stride(from: 0.0, through: 0.45, by: 0.01)
        for (name, colors, minimum) in [("light", StageColors.light, 4.5), ("dusk", StageColors.dusk, 3.0)] {
            for character in DuoCharacter.allCases {
                let half = character == .angel ? colors.angelHalf : colors.devilHalf
                for position in sampled {
                    let ratio = StageColors.contrast(colors.ink[character], StageColors.sample(half, at: position))
                    check(ratio >= minimum,
                          "\(name) \(character) ink contrast \(ratio) < \(minimum) at radial position \(position)")
                }
                let variants = [colors, colors.increasingContrast(), colors.reducingTransparency(dark: name == "dusk")]
                // Typing dots against the character's bubble, at its grade's densest and
                // thinnest edges, over any part of the half (solid under Reduce Transparency).
                for variant in variants {
                    for edge in [0.0, 1.0] {
                        let tint = variant.captionGrade.tint(variant.bubbleTint[character], at: edge)
                        for position in stride(from: 0.0, through: 1.0, by: 0.05) {
                            let bubble = StageColors.composite(tint, over: StageColors.sample(half, at: position))
                            let ratio = StageColors.contrast(colors.dots[character], bubble)
                            check(ratio >= 3, "\(name) \(character) dots contrast \(ratio) at \(position), edge \(edge)")
                            // Caption text is body size, so it needs 4.5:1 on its bubble.
                            let text = StageColors.contrast(colors.bubbleText[character], bubble)
                            check(text >= 4.5, "\(name) \(character) caption contrast \(text) at \(position), edge \(edge)")
                        }
                    }
                }
                // The chrome's glyphs (3:1, as icons) on its glass at either edge of its grade,
                // over any part of its half: the header's buttons over the angel's, the dock and
                // its side buttons over the devil's.
                for chrome in variants {
                    for edge in [0.0, 1.0] {
                        for position in stride(from: 0.0, through: 1.0, by: 0.05) {
                            let tint = chrome.chromeGrade.tint(chrome.chromeGlass[character], at: edge)
                            var glass = StageColors.composite(tint, over: StageColors.sample(half, at: position))
                            if character == .devil {
                                glass = StageColors.composite(chrome.chromeGrade.tint(chrome.dockButton, at: edge), over: glass)
                            }
                            let ratio = StageColors.contrast(chrome.chromeGlyph[character], glass)
                            check(ratio >= 3, "\(name) \(character) chrome glyph contrast \(ratio) at \(position), edge \(edge)")
                        }
                    }
                }
                // The human's words, final or still being recognized (body size, 4.5:1), on the
                // pill over any part of either half, and the error banner's text (4.5:1) and
                // glyph (3:1) over the devil's half, where the dock sits.
                for variant in variants {
                    for edge in [0.0, 1.0] {
                        for position in stride(from: 0.0, through: 1.0, by: 0.05) {
                            let behind = StageColors.sample(half, at: position)
                            let pill = StageColors.composite(variant.captionGrade.tint(variant.pillTint, at: edge), over: behind)
                            for (ink, kind) in [(variant.pillText, "final"), (variant.pillPendingText, "pending")] {
                                let ratio = StageColors.contrast(ink, pill)
                                check(ratio >= 4.5, "\(name) pill \(kind) text contrast \(ratio) over \(character) at \(position)")
                            }
                            guard character == .devil else { continue }
                            let banner = StageColors.composite(variant.captionGrade.tint(variant.bannerTint, at: edge), over: behind)
                            let text = StageColors.contrast(variant.bannerText, banner)
                            check(text >= 4.5, "\(name) banner text contrast \(text) at \(position), edge \(edge)")
                            let glyph = StageColors.contrast(variant.bannerGlyph, banner)
                            check(glyph >= 3, "\(name) banner glyph contrast \(glyph) at \(position), edge \(edge)")
                        }
                    }
                }
            }
            // White on the microphone, muted or not, from its middle down, where the glyph's
            // body sits (a 3:1 icon; the lighter top edge is 2.5:1).
            for fill in [colors.micFill, colors.micMutedFill] {
                for position in stride(from: 0.5, through: 1, by: 0.1) {
                    let ratio = StageColors.contrast(RGBA(0xFFFFFF), StageColors.sample(fill, at: position))
                    check(ratio >= 3, "\(name) microphone glyph contrast \(ratio) at \(position)")
                }
            }
        }
        // The microphone: teal-green, deepening toward the bottom.
        let mic = StageColors.light.micFill.map(\.color)
        check(mic == [RGBA(0x36C7A0), RGBA(0x19A383), RGBA(0x0B7A62)], "the teal microphone")
        check(mic[2].luminance < mic[0].luminance * 0.5, "the microphone darkens toward the bottom")
        // Reduce Transparency: every colour is opaque, and the glow sprite is gone.
        for dark in [false, true] {
            for increaseContrast in [false, true] {
                let reduced = StageColors.resolve(dark: dark, reduceTransparency: true, increaseContrast: increaseContrast)
                let all = Self.colors(in: reduced)
                check(all.count >= 40, "Reflection found the palette's colours (\(all.count))")
                for (path, color) in all {
                    check(color.a == 1, "\(path) is translucent (\(color.a)) under Reduce Transparency")
                }
                check(reduced.haloGlow == nil && reduced.haloOutline != nil && reduced.contactLine != nil
                          && reduced.opaque, "Reduce Transparency swaps the glow and the shadow")
                check(reduced.bubbleShadow == nil && reduced.glassEdgeLight == nil && reduced.chromeGrade == .flat
                          && reduced.captionGrade == .flat, "Reduce Transparency fills the glass evenly, unlit")
            }
        }

        // The seam's soft edge at rest: six feathering strokes a side in each scheme, the angel's
        // warm glow stronger than the devil's faint shade.
        for colors in [StageColors.light, StageColors.dusk] {
            for c in DuoCharacter.allCases {
                check(colors.seamGlow[c].count == 6 && colors.seamGlow[c].allSatisfy { $0.a > 0 && $0.a <= 0.1 },
                      "\(c)'s side of the seam's soft edge")
            }
            check(colors.seamGlow.angel[0].a > colors.seamGlow.devil[0].a, "the glow outshines the shade")
        }

        // Spot values.
        check(StageColors.light.ink.angel == RGBA(0x2A1206) && StageColors.dusk.ink.devil == RGBA(0x120502), "ink")
        check(StageColors.light.devilHalf.map(\.location) == [0, 0.15, 0.31, 0.48, 0.66, 0.85, 1], "devil half stops")
        // The halves' grading: lighter behind the faces than at the edges, the angel's gold
        // toward the seam and the devil's deep red toward the bottom.
        for half in [StageColors.light.angelHalf, StageColors.light.devilHalf] {
            check(half.last!.color.luminance < 0.75 * half.first!.color.luminance, "a half deepens toward its edges")
        }
        check(StageColors.resolve(dark: false, reduceTransparency: true, increaseContrast: false).wingFill[0].color
                  == RGBA(0xFFF7E1), "opaque light wing")
        check(StageColors.resolve(dark: true, reduceTransparency: true, increaseContrast: false).wingFill[0].color
                  == RGBA(0xE8DCB8), "opaque dark wing")
        check(StageColors.resolve(dark: false, reduceTransparency: false, increaseContrast: false) == .light, "light")
        check(StageColors.resolve(dark: true, reduceTransparency: false, increaseContrast: false) == .dusk, "dusk")
        let contrast = StageColors.resolve(dark: true, reduceTransparency: false, increaseContrast: true)
        near(contrast.inkStrokeScale, 1.2, 0, "Increase Contrast ink")
        near(contrast.seamLine!.a, 0.4, 0, "Increase Contrast seam line")
        check(contrast.bubbleTint.angel.a >= 0.9 && contrast.bubbleTint.devil.a >= 0.9 && contrast.pillTint.a >= 0.9
                  && contrast.bannerTint.a >= 0.9, "Increase Contrast bubble tints")
        check(contrast.chromeGrade == .flat && contrast.captionGrade == .flat && contrast.bubbleStrokeAlpha > 0,
              "Increase Contrast fills the glass evenly, outlined")
        // The glass grades gently: denser at the top, thinner toward the bottom, the captions'
        // less than the chrome's.
        for colors in [StageColors.light, StageColors.dusk] {
            check(colors.chromeGrade.top > 1 && colors.chromeGrade.bottom < 1, "the chrome's glass grades")
            check(colors.captionGrade.top > 1 && colors.captionGrade.bottom < 1
                      && colors.captionGrade.top - colors.captionGrade.bottom
                      < colors.chromeGrade.top - colors.chromeGrade.bottom, "the captions' glass grades gently")
        }
        near(StageColors.dusk.contactShadowAlphaScale, 1.4, 0, "dusk shadow alpha")
        // Rims: stroke alphas live in the palette; dusk's are its strongest stroke's.
        check(StageColors.light.rim.angel == [RGBA(0xFDC54F, alpha: 0.35), RGBA(0xFDC54F, alpha: 0.5)]
                  && StageColors.light.rim.devil == [RGBA(0xFF9A3C, alpha: 0.5)], "light rims")
        check(StageColors.dusk.rim.angel.map(\.a).max() == 0.6 && StageColors.dusk.rim.devil.map(\.a) == [0.5], "dusk rims")
        // Under Reduce Transparency each opaque band equals the translucent stack over the half.
        let opaqueRim = StageColors.resolve(dark: false, reduceTransparency: true, increaseContrast: false).rim.angel
        let seamAngel = StageColors.sample(StageColors.light.angelHalf, at: 0.55)
        let outerBand = StageColors.composite(StageColors.light.rim.angel[0], over: seamAngel)
        let innerBand = StageColors.composite(StageColors.light.rim.angel[1], over: outerBand)
        check(opaqueRim == [outerBand, innerBand], "Reduce Transparency rims match the translucent stack")

        // WCAG arithmetic: black on white is 21:1; compositing is source-over.
        near(StageColors.contrast(RGBA(0x000000), RGBA(0xFFFFFF)), 21, 1e-9, "black on white")
        near(StageColors.contrast(RGBA(0x777777), RGBA(0xFFFFFF)), 4.48, 0.01, "#777 on white")
        let half = StageColors.composite(RGBA(0xFFFFFF, alpha: 0.5), over: RGBA(0x000000))
        near(half.r, 0.5, 1e-12, "white at 50% over black")
        near(half.a, 1, 0, "composite over opaque is opaque")
        near(StageColors.sample(StageColors.light.angelHalf, at: 0.1).g,
             (RGBA(0xFEEFA2).g + RGBA(0xFDEA96).g) / 2, 1e-12, "gradient sampling interpolates")
    }
}

// MARK: - Simulation checks

/// Every talking mouth holds one openness: no beats (it never dips below 0.22) and no pauses.
private struct ConstantMouths: MouthSource {
    var openness = 0.3

    func drive(_ character: DuoCharacter, at simTime: Double) -> MouthDrive? {
        MouthDrive(openness: openness, width: 0.5, rounding: 0.1)
    }
}

/// Frame times at `hz` up to `end`, with every quarter second also a frame time.
private func frameTimes(_ hz: Double, until end: Double, quarters: [Double]) -> [Double] {
    Array(Set((1...Int((end * hz).rounded())).map { Double($0) / hz } + quarters)).sorted()
}

/// One sample per substep of a seam run.
private struct SeamSample {
    var time: Double
    var baseline: Double
    /// The baseline's velocity (band/s).
    var velocity: Double
    var ripple: Double
    var events: [StageEvent]
}

extension StageRigChecks {
    // MARK: Cadence and determinism

    /// Feeds `script` to a simulation with the given frame times, delivering each step just
    /// before the first frame at or after it, as the app's `onChange` does.
    private static func play(_ script: StageScript, frames: [Double], seed: UInt64, record: Set<Double>,
                             metrics: StageMetrics = .iPhone18Pro)
        -> (digests: [UInt64], roles: [PerCharacter<CharacterRole>], events: [StageEventRecord]) {
        var sim = StageSimulation(seed: seed, metrics: metrics)
        sim.update(metrics: metrics, bubbleHeights: [.angel: 64, .devil: 84], pillHeight: 46)
        var next = 0
        var digests: [UInt64] = [], roles: [PerCharacter<CharacterRole>] = [], events: [StageEventRecord] = []
        for time in frames {
            while next < script.steps.count, script.steps[next].time <= time {
                sim.receive(script.steps[next].inputs, at: script.steps[next].time)
                next += 1
            }
            let frame = sim.advance(to: time, mouths: script)
            check(frame.picture.seam.allSatisfy(\.isFinite) && frame.picture.seam.count == SeamRig.sampleCount,
                  "frame at \(time) has a finite 49-sample seam")
            if record.contains(time) {
                digests.append(frame.digest())
                roles.append(sim.roles)
            }
            events += sim.drainEvents()
        }
        return (digests, roles, events)
    }

    static func cadence() {
        let script = StageScript.previewDuo(seed: 1)
        let quarters = (1...120).map { Double($0) / 4 }
        let record = Set(quarters)
        var jitter = SplitMix64(seed: 11)
        var jittered: [Double] = []
        var clock = 0.0, hitched = false
        while clock < 30 {
            var dt = jitter.uniform(in: 0.008...0.017)
            if !hitched, clock > 9.5 {
                dt = 0.09
                hitched = true
            }
            let next = min(clock + dt, 30)
            jittered += quarters.filter { $0 > clock && $0 < next }
            jittered.append(next)
            clock = next
        }
        let cadences = [("30 Hz", frameTimes(30, until: 30, quarters: quarters)),
                        ("60 Hz", frameTimes(60, until: 30, quarters: quarters)),
                        ("120 Hz", frameTimes(120, until: 30, quarters: quarters)), ("jittered", jittered)]
        let runs = cadences.map { play(script, frames: $0.1, seed: 7, record: record) }
        let reference = runs[0]
        check(reference.digests.count == 120, "a digest every 0.25 s")
        check(Set(reference.digests).count > 60, "the digests change as the stage moves")
        for (run, cadence) in zip(runs, cadences).dropFirst() {
            for (i, (a, b)) in zip(reference.digests, run.digests).enumerated() where a != b {
                check(false, "\(cadence.0): the digest at \(quarters[i]) s differs from 30 Hz")
            }
            check(run.events == reference.events, "\(cadence.0): events and their times match 30 Hz")
        }

        // The preview's exchange: three handovers (the angel, the devil, the angel) and one
        // exchange end.
        let events = reference.events.map(\.event)
        func count(_ match: (StageEvent) -> Bool) -> Int { events.filter(match).count }
        check(count { if case .impact = $0 { true } else { false } } == 3, "three impacts")
        check(count { if case .impact(.devil, _) = $0 { true } else { false } } == 2,
              "the devil is hit each time the angel takes the floor")
        check(count { $0 == .flipped(.devil) } == 1 && count { $0 == .flipped(.angel) } == 1,
              "the draw order flips once each way")
        check(count { $0 == .exchangeEnded } == 1 && count { $0 == .interrupted } == 0, "one exchange end")
        // Bubbles appearing where a face still is wait for it too: the angel's typing dots before
        // her first line, and the devil's earlier caption as the exchange ends and the stage
        // relaxes around it.
        check(count { $0 == .slotClear(.angel) } == 4 && count { $0 == .slotClear(.devil) } == 3,
              "three speakers' slots clear, the capsules of the two listeners writing next, the angel's dots and "
                  + "the devil's last caption")
        check(count { if case .captionStarted = $0 { true } else { false } } == 7, "seven captions")
        check(count { if case .beat = $0 { true } else { false } } > 20, "speech beats")
        check(count { $0 == .gesture(.angel, .blink) } > 3 && count { $0 == .gesture(.devil, .blink) } > 3, "blinks")
        check(count { if case .userFinal(_, let cues) = $0 { cues == [.question, .mentionsAngel] } else { false } } == 1,
              "the human's question is classified")
        let floors = events.compactMap { event -> DuoCharacter?? in
            if case .floorChanged(_, let to) = event { return to } else { return nil }
        }
        check(floors == [.angel, .devil, .angel, nil], "floors \(floors)")

        // The same seed replays exactly; another seed moves the blinks but not the roles.
        let frames = frameTimes(60, until: 30, quarters: quarters)
        let again = play(script, frames: frames, seed: 7, record: record)
        check(again.digests == runs[1].digests && again.events == runs[1].events, "seed 7 replays exactly")
        let other = play(script, frames: frames, seed: 8, record: record)
        func blinks(_ events: [StageEventRecord]) -> [Double] {
            events.filter { if case .gesture(_, .blink) = $0.event { true } else { false } }.map(\.time)
        }
        check(blinks(other.events) != blinks(again.events), "seed 8 blinks at other times")
        check(other.roles == again.roles, "seed 8 plays the same roles")
        check(other.digests != again.digests, "seed 8 draws different frames")
        let roleSet = Set(again.roles.flatMap { [$0.angel, $0.devil] })
        for role in [CharacterRole.speaking, .squished(addressed: false), .squished(addressed: true), .thinking,
                     .listening, .afterglow(lastSpeaker: true), .afterglow(lastSpeaker: false), .neutral] {
            check(roleSet.contains(role), "the preview plays \(role)")
        }
    }

    // MARK: Seam and anchor fidelity

    static func fidelity() {
        let m = StageMetrics.fidelity
        check(m.scale == 1 && m.bandHeight == 600 && m.windowWidth == 400, "the fidelity stage maps 1 fu to 1 pt")
        func v(_ y: Double) -> Double { m.v(y) }

        // At rest. The resting seam lies across the band's middle, leaning neither
        // half into the other; a still shows the idle drift's still S-curve, level on average
        // and point-symmetric about the middle.
        let neutral = StageSimulation.snapshot(pose: .neutral, metrics: m).frame
        check(SeamShape.neutral.centre == 0.5 && SeamShape.neutral.drift == SeamShape.idleDrift,
              "the resting baseline is the band's middle, with the idle drift")
        near(neutral.picture.seam.reduce(0, +) / Double(neutral.picture.seam.count), 0.5, 1e-9,
             "the still neutral seam is level on average")
        let still = neutral.picture.seam
        for k in still.indices {
            let u = Double(k) / 48
            near(still[k], 0.5 + SeamShape.idleDrift * SeamRig.driftProfile(u, phases: (0, 0), still: 1), 1e-12,
                 "the still neutral seam is the drift's S-curve at u \(u)")
            near(still[k] - 0.5, 0.5 - still[48 - k], 1e-12, "the still S-curve favours neither half at u \(u)")
            near(still[k], KeyPoses.neutralSeam, 0.03, "the neutral seam near the resting pose's at u \(u)")
        }
        check(neutral.picture.restEdge == 1, "a still neutral seam shows its soft edge")
        let floorHeld = StageSimulation.snapshot(pose: .angelTalking, metrics: m).frame
        check(floorHeld.picture.restEdge == 0, "the soft edge gives way to the rim while someone holds the floor")
        let angel = neutral.picture.faces.angel, devil = neutral.picture.faces.devil
        near(v(angel.eyeLine), KeyPoses.neutralAngel.eyeLine, 0.02, "neutral angel eye line")
        near(v(devil.eyeLine), KeyPoses.neutralDevil.eyeLine, 0.02, "neutral devil eye line")
        for face in [angel, devil] {
            near(face.scale, 1, 1e-9, "neutral face scale")
            near(face.sy, 1, 1e-9, "neutral face squash")
            near(face.point(.zero).x, 200, 1e-9, "faces are centred")
            check(face.pin == nil && face.pivot == .zero, "free faces pivot at the eyes")
        }
        check(neutral.picture.dominant == .angel, "the angel is on top at launch")
        near(neutral.picture.shadow, 0, 1e-12, "no contact shadow in neutral")

        // The angel speaks.
        let angelFloor = StageSimulation.snapshot(pose: .angelTalking, metrics: m)
        let af = angelFloor.frame
        for (u, expected) in zip(KeyPoses.seamU, KeyPoses.angelFloorSeam) {
            near(af.seam(at: u), expected, 0.02, "angel floor seam at u \(u)")
        }
        let speaker = af.picture.faces.angel, squished = af.picture.faces.devil
        near(v(speaker.eyeLine), KeyPoses.angelFloorAngel.eyeLine, 0.03, "angel floor: angel eye line")
        near(speaker.scale, KeyPoses.angelFloorAngel.scale.x, 0.04, "angel floor: angel scale")
        near(v(squished.eyeLine), KeyPoses.angelFloorDevil.eyeLine, 0.03, "angel floor: devil eye line")
        check(squished.pin == .floor(m.y(KeyPoses.angelFloorFloor)), "the devil is pinned to the floor")
        near(v(squished.point(DevilGeometry.squishPivot).y), KeyPoses.angelFloorFloor, 1e-9, "devil pivot on the floor")
        near(squished.sy, KeyPoses.angelFloorDevil.squashTarget, 0.02, "angel floor: devil sy")
        check(squished.sx <= pow(squished.sy, -0.5) && squished.sx > 1, "devil sx \(squished.sx) within sy^(−0.5)")
        near(squished.sx, pow(squished.sy, -0.4), 1e-12, "volume rule")
        near(af.picture.shadow, 1, 1e-9, "full contact shadow on the floor")
        // The contact squash: sy = clamp(min(pressure, room/need), sMin, 1), need in fu × s.
        let devilContact = StageLayout.Contact.devil, angelContact = StageLayout.Contact.angel
        near(devilContact.squash(room: 500, scale: 1), 0.78, 0, "devil pressure")
        near(devilContact.squash(room: 0.74 * 130, scale: 1), 0.74, 1e-12, "devil room/need")
        near(devilContact.squash(room: 0.75 * 130 * 1.2, scale: 1.2), 0.75, 1e-12, "devil need scales with s")
        near(devilContact.squash(room: 10, scale: 1), 0.70, 0, "devil sMin")
        near(angelContact.squash(room: 500, scale: 1), 0.92, 0, "angel pressure")
        near(angelContact.squash(room: 0.88 * 201, scale: 1), 0.88, 1e-12, "angel room/need")
        near(angelContact.squash(room: 10, scale: 1), 0.86, 0, "angel sMin")

        // The devil speaks.
        let devilFloor = StageSimulation.snapshot(pose: .devilTalking, metrics: m)
        let df = devilFloor.frame
        let dense = (0...400).map { Double($0) / 400 }
        let values = dense.map { df.seam(at: $0) }
        near(values.reduce(0, +) / Double(values.count), KeyPoses.devilFloorMean, 0.01, "devil floor seam mean")
        near((values.max()! - values.min()!) / 2, KeyPoses.devilFloorAmplitude,
             0.1 * KeyPoses.devilFloorAmplitude, "devil floor wave amplitude")
        let highest = dense[values.firstIndex(of: values.min()!)!]
        near(highest, KeyPoses.devilFloorHighest.u, 0.05, "devil floor highest point")
        let top = df.picture.faces.angel, talker = df.picture.faces.devil
        near(v(top.eyeLine), KeyPoses.devilFloorAngel.eyeLine, 0.03, "devil floor: angel eye line")
        near(top.sy, KeyPoses.devilFloorAngel.squashTarget, 0.01, "devil floor: angel sy")
        check(top.pin == .ceiling(m.y(KeyPoses.devilFloorHaloTop)), "the angel is pinned to the ceiling")
        near(v(top.point(Vec2(0, AngelGeometry.haloTop)).y), KeyPoses.devilFloorHaloTop, 0.002,
             "devil floor: halo top at the ceiling")
        near(v(talker.eyeLine), KeyPoses.devilFloorDevil.eyeLine, 0.03, "devil floor: devil eye line")
        near(talker.scale, KeyPoses.devilFloorDevil.scale.x, 0.04, "devil floor: devil scale")
        for sigma in [-1.0, 1] {
            let tip = v(talker.point(DevilGeometry.hornTip.sided(-sigma)).y)
            check(tip >= 0.43 && tip <= 0.46, "devil floor: horn tip at v \(tip), not within 0.43–0.46")
        }
        check(df.picture.dominant == .devil, "the devil is on top when he talks")

        // The drawn seam: level runs at the edge values from 20 pt beyond each canvas edge, and
        // cubics one sample spacing long through the 49 samples across the centred window (at
        // most 720 pt wide). Every cubic heads rightward and meets the next without a kink, so
        // where an iPad's window ends the seam neither steps nor loops, and across the window it
        // is the graph of `seam(at:)`.
        for metrics in [StageMetrics.iPhone18Pro, .iPadPortrait, .iPadLandscape] {
            for pose in [StagePose.devilTalking, .angelTalking] {
                let frame = StageSimulation.snapshot(pose: pose, metrics: metrics).frame
                let samples = frame.picture.seam
                let label = "\(pose) on a \(metrics.width)-pt stage"
                var segments: [(Vec2, Vec2, Vec2, Vec2)] = []
                StageFrame.forEachSeamSegment(of: samples, metrics: metrics, width: metrics.width + 30) {
                    segments.append(($0, $1, $2, $3))
                }
                check(segments.count == SeamRig.sampleCount + 3, "\(label): \(segments.count) seam segments")
                check(segments.first!.0 == Vec2(-20, metrics.y(samples.first!))
                          && segments.last!.3 == Vec2(metrics.width + 50, metrics.y(samples.last!)),
                      "\(label): the seam runs level from 20 pt beyond each canvas edge")
                let window = min(metrics.width, 720), left = (metrics.width - window) / 2
                for (k, v) in samples.enumerated() {
                    near(segments[k + 1].3, Vec2(left + window * Double(k) / 48, metrics.y(v)), 1e-9,
                         "\(label): seam sample \(k)")
                }
                var worst = 0.0
                for (i, s) in segments.enumerated() {
                    check(s.0.x <= s.1.x && s.1.x <= s.2.x && s.2.x <= s.3.x,
                          "\(label): the seam turns back at x \(s.0.x)")
                    if i > 0 {
                        let p = segments[i - 1], a = p.3 - p.2, b = s.1 - s.0
                        check(p.3 == s.0 && abs(a.x * b.y - a.y * b.x) <= 1e-9 * max(1, a.length * b.length),
                              "\(label): the seam kinks at x \(s.0.x)")
                    }
                    for t in [0.25, 0.5, 0.75] {
                        let r = 1 - t
                        let point = s.0 * (r * r * r) + s.1 * (3 * r * r * t) + s.2 * (3 * r * t * t) + s.3 * (t * t * t)
                        let u = metrics.u(point.x)
                        if u >= 0, u <= 1 { worst = max(worst, abs(point.y - metrics.y(frame.seam(at: u)))) }
                    }
                }
                check(worst < 1e-6, "\(label): across the window the drawn seam leaves seam(at:) by \(worst) pt")
            }
        }

        // The leans hold their presets.
        let lean = StageSimulation.snapshot(pose: .leanAngel, metrics: m).frame
        near(lean.seam(at: 0.5), 0.535 + 0.02, 1e-9, "lean toward the angel")
        near(lean.seam(at: 0.5) - lean.seam(at: 0), 0.02, 1e-9, "the angel's lean bulges gently toward the devil")
        near(lean.picture.faces.angel.scale, 1.05, 1e-9, "the addressed angel is 5% larger")
        let leanDevil = StageSimulation.snapshot(pose: .leanDevil, metrics: m).frame
        near(leanDevil.seam(at: 0.5), 0.465 + 0.006 * KeyPoses.wave(0.5), 1e-9, "lean toward the devil")
        check(StagePreset.leanAngel.shape.drift == SeamShape.idleDrift
                  && StagePreset.leanDevil.shape.drift == SeamShape.idleDrift, "the leans drift as the neutral seam does")
        near(leanDevil.picture.faces.devil.scale, 1.05, 1e-9, "the addressed devil is 5% larger")
    }

    // MARK: Choreography

    /// Runs one handover (or release or interruption) from the settled pose `from`, recording
    /// every substep for `duration` seconds after the change at t0.
    private static func seamRun(from: StagePose, change: (inout StageInputs) -> Void, options: SeamRig.Options,
                                metrics: StageMetrics = .iPhone18Pro, duration: Double = 3)
        -> (t0: Double, start: Double, target: Double, samples: [SeamSample], sim: StageSimulation) {
        var sim = StageSimulation.snapshot(pose: from, metrics: metrics, options: options)
        _ = sim.drainEvents()
        let t0 = sim.time + FixedStepper.step
        var inputs = sim.inputs
        change(&inputs)
        sim.receive(inputs, at: t0)
        let start = sim.seam.baseline
        var samples: [SeamSample] = []
        let mouths = ConstantMouths()
        sim.advance(to: t0, mouths: mouths)
        let target = sim.layout.seam.centre
        samples.append(SeamSample(time: 0, baseline: sim.seam.baseline, velocity: sim.seam.centreVelocity,
                                  ripple: sim.seam.rippleMagnitude, events: sim.drainEvents().map(\.event)))
        for k in 1...Int(duration * 240) {
            sim.advance(to: t0 + Double(k) / 240, mouths: mouths)
            samples.append(SeamSample(time: Double(k) / 240, baseline: sim.seam.baseline,
                                      velocity: sim.seam.centreVelocity, ripple: sim.seam.rippleMagnitude,
                                      events: sim.drainEvents().map(\.event)))
        }
        return (t0, start, target, samples, sim)
    }

    static func choreography() {
        let m = StageMetrics.iPhone18Pro
        let band = m.bandHeight
        near(band, 586, 0, "the 18 Pro band")
        typealias Row = (name: String, from: StagePose, to: DuoCharacter, anticipation: Double, impact: Double,
                         apex: Double, overshoot: Double, settled: Double)
        // The rows hold the handover springs' motion toward an unclamped angel floor (0.722). On
        // the 18 Pro the room clamp holds the devil's 112 pt (centre 0.704), and his wall, where
        // he is squashed to sMin (88.9 pt above the floor), leaves the rest → angel overshoot of
        // 19 pt room but meets the devil → angel one: its seam runs 22 pt (12%) past its target,
        // touches the wall at 0.33 s and bounces, where unwalled it would reach 29 pt (16%) at
        // 0.37 s. That row is the walled motion's.
        let table: [Row] = [
            ("rest → angel", .neutral, .angel, 13.0, 0.24, 0.34, 0.17, 0.75),
            ("angel → devil", .angelTalking, .devil, 9.1, 0.20, 0.29, 0.10, 0.75),
            ("devil → angel", .devilTalking, .angel, 11.3, 0.26, 0.33, 0.12, 0.85),
            ("rest → devil", .neutral, .devil, 10.7, 0.20, 0.30, 0.13, 0.65),
        ]
        for row in table {
            let run = seamRun(from: row.from, change: {
                $0.floor = row.to
                $0.talking = [row.to]
                $0.captions = [:]
            }, options: .isolated)
            let travel = run.target - run.start
            let sign = travel > 0 ? 1.0 : -1.0
            check(abs(travel) > 0.1, "\(row.name): the seam travels")
            let script = HandoverScript.script(from: row.from == .neutral ? nil : row.from == .angelTalking ? .angel : .devil,
                                               to: row.to)
            let anticipation = run.samples.filter { $0.time <= script.launch + 0.02 }
                .map { -sign * ($0.baseline - run.start) }.max()! * band
            near(anticipation, row.anticipation, 2.5, "\(row.name) anticipation (pt)")
            let impacts = run.samples.filter { $0.events.contains { if case .impact = $0 { true } else { false } } }
            check(impacts.count == 1, "\(row.name): exactly one impact (\(impacts.count))")
            let listener: DuoCharacter = row.to == .angel ? .devil : .angel
            check(impacts.first!.events.contains { if case .impact(listener, _) = $0 { true } else { false } },
                  "\(row.name): the impact hits the listener")
            near(impacts.first!.time, row.impact, 0.03, "\(row.name) impact time")
            let apex = run.samples.max { sign * $0.baseline < sign * $1.baseline }!
            near(apex.time, row.apex, 0.03, "\(row.name) apex time")
            near(sign * (apex.baseline - run.target) / abs(travel), row.overshoot, 0.04, "\(row.name) overshoot")
            let late = run.samples.last { abs($0.baseline - run.target) * band > 1 }!
            check(late.time + FixedStepper.step <= row.settled,
                  "\(row.name) is within 1 pt only after \(late.time + FixedStepper.step) s (expected ≤ \(row.settled))")
            let flipIndices = run.samples.indices.filter {
                run.samples[$0].events.contains { if case .flipped = $0 { true } else { false } }
            }
            let flips = flipIndices.map { run.samples[$0] }
            if row.from != .neutral {
                check(flips.count == 1, "\(row.name): exactly one draw-order flip (\(flips.count))")
                // The flip lands on the substep whose baseline crosses 0.5. The seam crosses at
                // about 2.4–2.8 band/s, 0.010–0.012 band per substep, so the flip is as close to
                // 0.5 as one substep's travel.
                let before = run.samples[flipIndices[0] - 1].baseline, after = flips[0].baseline
                check(sign * (before - 0.5) <= 0 && sign * (after - 0.5) > 0,
                      "\(row.name) flips on the crossing substep (\(before) → \(after))")
                check(abs(after - 0.5) <= abs(after - before) + 1e-12, "\(row.name) flips at baseline \(after)")
                check(flips[0].events.contains(.flipped(row.to)), "\(row.name) flips to the new speaker")
            } else {
                check(flips.count == (row.to == .devil ? 1 : 0), "\(row.name): \(flips.count) flips")
            }
            check(run.samples.allSatisfy { $0.ripple == 0 }, "\(row.name): the isolated run has no ripple")
            let slot = run.samples.first { $0.events.contains(.slotClear(row.to)) }
            check(slot.map { $0.time >= 0.30 - 1e-9 && $0.time <= 0.60 + 1e-9 } == true,
                  "\(row.name): the slot clears between 0.30 and 0.60 s")

            // With everything enabled: walls, ripple, wave travel and breath.
            let full = seamRun(from: row.from, change: {
                $0.floor = row.to
                $0.talking = [row.to]
                $0.captions = [:]
            }, options: .standard)
            for sample in full.samples {
                check(sample.ripple <= SeamRig.rippleLimit + 1e-12, "\(row.name): ripple \(sample.ripple) past the limit")
                if sample.time >= 1.3 {
                    check(abs(sample.baseline - full.target) * band <= 2,
                          "\(row.name) with everything on is \(abs(sample.baseline - full.target) * band) pt off at \(sample.time) s")
                }
            }
            check(full.samples.contains { $0.ripple > 0.002 }, "\(row.name): the impact sets off a ripple")
            check(full.samples.filter { $0.events.contains { if case .impact = $0 { true } else { false } } }.count == 1,
                  "\(row.name) with everything on: one impact")
        }

        // Walls sit where the listener is squashed to sMin. On the 18 Pro the settled seam keeps
        // 23 pt above the devil's, and the rest → angel overshoot uses that room to squash him
        // deeper than his settled pressure.
        let proWall = StageLayout.walls(.angelFloor, metrics: m)
        let settledRoom = m.y(StageLayout.floorV) - m.y(StageLayout.clamped(.angelFloor, metrics: m).0.centre)
        near(m.y(StageLayout.floorV) - m.y(proWall.maxLowest), 130 * 0.70 * m.scale, 1e-9, "the devil's wall is need·sMin·s")
        check(settledRoom - (130 * 0.70 * m.scale) >= 8, "the settled seam keeps room above the wall")
        near(StageLayout.walls(.devilFloor, metrics: m).minHighest - StageLayout.ceilingV, 201 * 0.86 * m.scale / band,
             1e-12, "the angel's wall is need·sMin·s below the ceiling")
        check(StageLayout.walls(.neutral, metrics: m) == .none, "no walls with nobody squished")
        var deepened = StageSimulation.snapshot(pose: .neutral, metrics: m, options: .isolated)
        var takeFloor = deepened.inputs
        takeFloor.floor = .angel
        takeFloor.talking = [.angel]
        deepened.receive(takeFloor, at: deepened.time + FixedStepper.step)
        var deepest = 1.0, deepestTarget = 1.0, reachedWall = false
        for k in 1...480 {
            deepened.advance(to: Double(k) / 240, mouths: ConstantMouths())
            deepest = min(deepest, deepened.faces.devil.squash.value)
            if deepened.faces.devil.contact != nil { deepestTarget = min(deepestTarget, deepened.faces.devil.squash.target) }
            reachedWall = reachedWall || deepened.seam.value(at: 0.5) >= deepened.layout.limits.maxLowest - 1e-9
        }
        check(!reachedWall, "the rest → angel overshoot fits above the devil's wall on the 18 Pro")
        check(deepestTarget < StageLayout.Contact.devil.pressure - 0.04,
              "the overshoot deepens the devil's squash (target \(deepestTarget))")
        check(deepest < deepestTarget + 0.01, "the devil follows it down (sy \(deepest))")

        // On the Pro Max the preset is unclamped and only 16 pt above the wall: the rest → angel
        // overshoot reaches the wall, which holds the live seam over the devil's face and bounces
        // it.
        let wide = StageMetrics.iPhoneProMax
        var walled = StageSimulation.snapshot(pose: .neutral, metrics: wide, options: .isolated)
        var walledInputs = walled.inputs
        walledInputs.floor = .angel
        walledInputs.talking = [.angel]
        let walledStart = walled.time + FixedStepper.step
        walled.receive(walledInputs, at: walledStart)
        var walledLowest: [Double] = [], speed: [Double] = []
        for k in 0...480 {
            walled.advance(to: walledStart + Double(k) / 240, mouths: ConstantMouths())
            let limits = walled.layout.limits
            var extreme = -Double.infinity
            for i in 0...32 {
                let u = limits.span.lowerBound + (limits.span.upperBound - limits.span.lowerBound) * Double(i) / 32
                extreme = max(extreme, walled.seam.value(at: u))
            }
            walledLowest.append(extreme)
            speed.append(walled.seam.velocity(at: 0.5))
        }
        let wall = walled.layout.limits.maxLowest
        check(wall.isFinite && wall == StageLayout.walls(.angelFloor, metrics: wide).maxLowest, "the Pro Max's devil wall")
        check(walledLowest.allSatisfy { $0 <= wall + 1e-6 }, "the live seam never passes the devil's wall (\(walledLowest.max()!))")
        let contactIndex = walledLowest.firstIndex { $0 >= wall - 1e-9 }
        check(contactIndex != nil, "the rest → angel overshoot reaches the Pro Max's wall")
        let incoming = speed[contactIndex! - 1]
        check(incoming > 0.3, "the seam hits the wall at speed (\(incoming) band/s)")
        near(speed[contactIndex!], -0.35 * incoming, 0.1 * incoming, "the wall reflects the seam × −0.35")
        check(walledLowest[contactIndex! + 1] < wall - 1e-4, "the seam bounces off, not along, the wall")

        // The ripple chain: a jelly wave that runs to the free ends, wobbles about three
        // times and dies away, symmetric about a central impulse.
        var rig = SeamRig(shape: .neutral, options: .standard)
        rig.impulse(at: 0.5, velocity: 0.35)
        var centre: [Double] = [], edge: [Double] = []
        for k in 0..<480 {
            _ = rig.step(from: Double(k) / 240, drive: SeamRig.Drive())
            centre.append(rig.ripple[6])
            edge.append(rig.ripple[0])
            for i in 0..<SeamRig.rippleCount {
                near(rig.ripple[i], rig.ripple[SeamRig.rippleCount - 1 - i], 1e-12, "the ripple is symmetric")
            }
        }
        let peak = centre.map(abs).max()!
        check(peak > 0.003 && peak < SeamRig.rippleLimit, "the ripple's peak \(peak)")
        check(edge.map(abs).max()! > 0.05 * peak, "the ripple travels to the edges")
        var wobbles = 0
        for i in 1..<(centre.count - 1) where abs(centre[i]) > 0.05 * peak && abs(centre[i]) > abs(centre[i - 1])
            && abs(centre[i]) >= abs(centre[i + 1]) { wobbles += 1 }
        check((3...5).contains(wobbles), "about three visible wobbles (\(wobbles))")
        check(centre[240...].map(abs).max()! < 0.02 * peak, "the ripple dies within a second")

        // Release: the exchange ends after the 0.2-s debounce, then the seam holds 0.25 s.
        let release = seamRun(from: .angelTalking, change: { $0.floor = nil; $0.talking = [] }, options: .isolated)
        let ended = release.samples.first { $0.events.contains(.exchangeEnded) }!
        near(ended.time, 0.2, 1e-9, "the exchange ends after the 0.2-s debounce")
        let holdEnd = ended.time + 0.25
        let held = release.samples.filter { $0.time <= holdEnd + 1e-9 }
        check(held.allSatisfy { $0.baseline == release.start }, "no seam motion through the debounce and the hold")
        check(release.samples.first { $0.time > holdEnd + 1e-9 }!.baseline < release.start,
              "the release starts as the 0.25-s hold ends")
        let releaseTarget = release.sim.layout.seam.centre
        near(releaseTarget, 0.5, 1e-12, "release returns to neutral")
        check(release.sim.layout.seam.drift == SeamShape.idleDrift, "release brings back the idle drift")
        let overshoot = (releaseTarget - release.samples.map(\.baseline).min()!) / abs(release.start - releaseTarget)
        check(overshoot <= 0.04, "release overshoot \(overshoot)")
        let releaseLate = release.samples.last { abs($0.baseline - releaseTarget) * band > 1 }!
        check(releaseLate.time - holdEnd <= 0.7, "release is within 1 pt \(releaseLate.time - holdEnd) s after the hold")
        check(!release.samples.contains { $0.events.contains { if case .flipped = $0 { true } else { false } } },
              "no flip on release")
        check(!release.samples.contains { $0.events.contains { if case .impact = $0 { true } else { false } } },
              "no impact on release")

        // Interruption: no hold, a stiff spring straight to neutral.
        let cut = seamRun(from: .angelTalking, change: {
            $0.floor = nil
            $0.talking = []
            $0.interruptions += 1
        }, options: .isolated)
        check(cut.samples[0].events.contains(.interrupted) && !cut.samples.contains { $0.events.contains(.exchangeEnded) },
              "an interruption is not an exchange end")
        check(cut.samples[1].baseline < cut.start, "the interruption moves at once")
        let cutDeepest = cut.samples.map(\.baseline).min()!
        check((0.5 - cutDeepest) / abs(cut.start - 0.5) <= 0.02, "interruption overshoot")
        let cutLate = cut.samples.last { abs($0.baseline - 0.5) * band > 1 }!
        check(cutLate.time + FixedStepper.step <= 0.3, "interruption within 1 pt by \(cutLate.time) s")
        check(!cut.samples.contains { $0.events.contains { if case .flipped = $0 { true } else { false } } },
              "no flip on interruption")
        check(cut.sim.seam.dominant == .angel, "the interrupted speaker stays on top")

        // Floor → nil is an interruption only when `interruptions` rises in the same update.
        // A short line that starts just after an interruption ends as an exchange.
        var quick = StageSimulation.snapshot(pose: .angelTalking, metrics: m, options: .isolated)
        _ = quick.drainEvents()
        var short = quick.inputs
        short.floor = nil
        short.talking = []
        short.interruptions += 1
        quick.receive(short, at: 0.1)
        short.floor = .devil
        short.talking = [.devil]
        quick.receive(short, at: 0.2)
        short.talking = []
        quick.receive(short, at: 0.4)
        short.floor = nil
        quick.receive(short, at: 0.5)
        var quickEvents: [StageEventRecord] = []
        for k in 1...480 {
            quick.advance(to: Double(k) / 240, mouths: ConstantMouths())
            quickEvents += quick.drainEvents()
        }
        check(quickEvents.filter { $0.event == .interrupted }.count == 1, "one interruption")
        check(quickEvents.contains { $0.event == .exchangeEnded && abs($0.time - 0.7) < 1e-9 },
              "the short line after it ends as an exchange, after the debounce")

        // A handover begun while the seam still rushes the other way: its slot clears once the
        // live seam is 8 pt away, between 0.30 and 0.60 s.
        var rushed = StageSimulation.snapshot(pose: .neutral, metrics: m)
        rushed.update(metrics: m, bubbleHeights: [.angel: 104, .devil: 104], pillHeight: 0)
        var rush = rushed.inputs
        rush.floor = .devil
        rush.talking = [.devil]
        rush.captions[.devil] = "Oh, please, Angel!"
        rushed.receive(rush, at: 1.0 / 240)
        rush.floor = .angel
        rush.talking = [.angel]
        rush.captions[.angel] = "Go to the gym tonight."
        let second = 0.2
        rushed.receive(rush, at: second)
        var cleared: Double?
        for k in 1...300 {
            rushed.advance(to: Double(k) / 240, mouths: ConstantMouths())
            guard rushed.drainEvents().contains(where: { $0.event == .slotClear(.angel) }) else { continue }
            cleared = Double(k) / 240 - second
            let distance = rushed.liveSeamDistance(to: rushed.layout.bubbles[.angel]!.rect)
            check(distance >= 8 || cleared! >= 0.6 - 1e-9, "the slot clears with the seam \(distance) pt away")
        }
        check(cleared.map { $0 >= 0.3 - 1e-9 && $0 <= 0.6 + 1e-9 } == true, "the rushed slot clears in time")

        // A floor that comes back within the debounce goes straight to the next handover.
        var direct = StageSimulation.snapshot(pose: .angelTalking, metrics: m, options: .isolated)
        _ = direct.drainEvents()
        var inputs = direct.inputs
        inputs.floor = nil
        direct.receive(inputs, at: 0.1)
        inputs.floor = .devil
        inputs.talking = [.devil]
        direct.receive(inputs, at: 0.25)
        var directEvents: [StageEvent] = []
        var lowest = Double.infinity
        for k in 1...480 {
            direct.advance(to: Double(k) / 240, mouths: ConstantMouths())
            directEvents += direct.drainEvents().map(\.event)
            if Double(k) / 240 < 0.25 { lowest = min(lowest, direct.seam.baseline) }
        }
        check(!directEvents.contains(.exchangeEnded), "a quick new floor is not an exchange end")
        check(directEvents.filter { if case .floorChanged = $0 { true } else { false } } == [.floorChanged(from: .angel, to: .devil)],
              "the stage floor goes straight from the angel to the devil")
        near(lowest, StageLayout.clamped(.angelFloor, metrics: m).0.centre, 1e-9, "no neutral targets during the debounce")
        check(directEvents.contains(.flipped(.devil)), "the direct handover goes from the angel to the devil")

        // Drain, then endExchange: the paused speaker's floor ends, and she takes it back during
        // the release hold. A line starts, so the seam stops relaxing.
        var retake = StageSimulation.snapshot(pose: .angelTalking, metrics: m)
        var line = retake.inputs
        line.talking = [.angel]
        retake.receive(line, at: 0.05)
        line.talking = []
        retake.receive(line, at: 0.1)
        line.floor = nil
        retake.receive(line, at: 1.0)
        line.floor = .angel
        line.talking = [.angel]
        retake.receive(line, at: 1.3)
        var retakeEvents: [StageEvent] = []
        for k in 1...480 {
            let time = Double(k) / 240
            retake.advance(to: time, mouths: ConstantMouths(openness: time < 1.3 ? 0.1 : 0.5))
            retakeEvents += retake.drainEvents().map(\.event)
            if abs(time - 1.25) < 1e-9 {
                check(retake.seam.relax.target == 1 && !retake.paused && retake.stageFloor == nil,
                      "the floor ended while paused, the seam still relaxed through the hold")
            }
        }
        check(retakeEvents.contains(.pause(.angel)) && retakeEvents.contains(.exchangeEnded),
              "the speaker paused and the exchange ended")
        check(retake.stageFloor == .angel && retake.seam.relax.target == 0 && retake.seam.relax.value < 0.05,
              "taking the floor back stops the relax (target \(retake.seam.relax.target), value \(retake.seam.relax.value))")
    }
}

extension StageRigChecks {
    // MARK: Layout matrix

    /// The settled seam's extremes over [x0, x1] in stage y, at every wave phase, active and
    /// relaxed, widened by `margin` band. Computed here from `SeamShape.value`, independently of
    /// the solver's own envelope.
    private static func seamExtremes(_ layout: StageLayout, from x0: Double, to x1: Double,
                                     margin: Double = 0) -> (highest: Double, lowest: Double) {
        let m = layout.metrics
        var highest = Double.infinity, lowest = -Double.infinity
        for shape in [layout.seam, layout.seam.relaxed()] {
            for i in 0...32 {
                let x = x0 + (x1 - x0) * Double(i) / 32
                for p in 0..<40 {
                    // The idle drift reaches ±drift at every u over its phases.
                    let v = shape.value(at: m.u(x), phase: Double(p) / 40)
                    highest = min(highest, v - abs(shape.drift))
                    lowest = max(lowest, v + abs(shape.drift))
                }
            }
        }
        return (m.y(highest - margin), m.y(lowest + margin))
    }

    /// Checks one solved layout; true when a face overlaps its bubble below AX2 heights.
    @discardableResult
    private static func verify(_ layout: StageLayout, _ label: String, ax2: Bool, heights: [DuoCharacter: Double]) -> Bool {
        var crowded = false
        let m = layout.metrics, key = layout.key
        let speaker = key.preset.speaker, listener = key.preset.listener
        for c in DuoCharacter.allCases {
            let face = layout[c]
            check([face.anchor.x, face.anchor.y, face.scale, face.squash, face.squeeze, face.overlap].allSatisfy(\.isFinite),
                  "\(label): \(c) placement is finite")
            let box = layout.faceBox(c)
            check(box.minY >= m.bandTop - 1e-6 && box.maxY <= m.bandBottom + 1e-6,
                  "\(label): \(c) face box \(box) leaves the band \(m.bandTop)…\(m.bandBottom)")
            let wing = (AngelGeometry.wingBoxMax.x - AngelGeometry.wingBoxMin.x) * face.scale * face.stretch
            let allowance = c == .angel ? 0.3 * wing : 0
            check(box.minX >= -allowance - 1e-6 && box.maxX <= m.width + allowance + 1e-6,
                  "\(label): \(c) face box \(box) is too far off screen")
            if c == listener {
                near(face.scale, m.scale, 1e-12, "\(label): squished \(c) keeps its size")
                check(face.pin != nil, "\(label): the listener is pinned")
                continue
            }
            check(face.pin == nil && face.pivot == .zero, "\(label): \(c) is free")
            check(face.scale >= m.minimumScale - 1e-9, "\(label): \(c) scale \(face.scale) < 0.62·s_n")
            check(face.scale <= face.designScale + 1e-12, "\(label): \(c) is never enlarged")
            // A tight face may first give up its clearance to the bubble (the tail and a 10-pt
            // margin); then the bubble may overlap it, by at most 30% (the last fit step). Below
            // AX2 heights that happens only with nobody on the floor and both neutral bubbles
            // showing, when the band is shorter than both bubbles, their seam gaps and both faces
            // at 0.62·s_n (two 4-line captions on the SE).
            if face.overlap > 0 {
                if !ax2 {
                    check(speaker == nil && layout.bubbles.count == 2,
                          "\(label): \(c) overlaps its bubble (\(face.overlap) pt) below AX2 without two neutral bubbles")
                    let gap = key.pill ? max(30, layout.pill!.height / 2 + 8) : 30
                    let need = DuoCharacter.allCases.reduce(0.0) { total, f in
                        let box = FaceBoxes.layout(f)
                        return total + layout.bubbles[f]!.rect.height + gap + 4 + (box.max.y - box.min.y) * m.minimumScale
                    }
                    check(need > m.bandHeight, "\(label): \(c) overlaps its bubble (\(face.overlap) pt) though both fit")
                    crowded = true
                }
                check(face.overlap <= 0.3 * box.height + 1e-6, "\(label): \(c) overlaps its bubble by \(face.overlap) pt")
            }
            // Free faces stay on their side of the settled seam; the speaking devil's horns reach
            // up to it at most.
            let span = seamExtremes(layout, from: max(0, box.minX), to: min(m.width, box.maxX))
            if c == .angel {
                check(box.maxY <= span.highest + 1e-6, "\(label): the angel crosses the seam")
            } else if c == speaker {
                let half = abs(DevilGeometry.hornTip.x) * face.scale * face.stretch
                let horns = seamExtremes(layout, from: face.anchor.x - half, to: face.anchor.x + half)
                check(face.point(DevilGeometry.hornTip).y >= horns.lowest - 1e-6,
                      "\(label): the devil's horn tips cross the seam envelope")
            } else {
                check(box.minY >= span.lowest - 1e-6, "\(label): the devil crosses the seam")
            }
        }

        // Text rects lie in the band and on screen, and never overlap each other.
        let texts = layout.textRects
        for rect in texts {
            check(rect.isFinite && rect.minX >= -1e-6 && rect.maxX <= m.width + 1e-6 && rect.minY >= m.bandTop - 1e-6
                      && rect.maxY <= m.bandBottom + 1e-6, "\(label): text rect \(rect) leaves the band")
        }
        for (i, a) in texts.enumerated() {
            for b in texts[(i + 1)...] where a.height > 0 && b.height > 0 {
                check(!a.intersects(b), "\(label): text rects \(a) and \(b) overlap")
            }
        }

        // Bubbles: every bubble in the key, less the listener's while someone holds the floor,
        // and the earlier speaker's neutral caption only when both cannot fit within the rules:
        // the band is shorter than both bubbles, their seam gaps, the seam's own height over
        // the bubbles and both faces at 0.62·s_n overlapped by 30%, less the push search's
        // resolution (0.0025 band).
        var expected = key.bubbles
        if let speaker {
            expected = expected.filter { $0.key == speaker }
            if expected[speaker] == .dots { expected[speaker] = nil }
        }
        for c in layout.hidden {
            let gap = key.pill ? max(30, layout.pill!.height / 2 + 8) : 30
            let bw = StageLayout.neutralBubbleWidth(m.width)
            let seam = seamExtremes(layout, from: (m.width - bw) / 2, to: (m.width + bw) / 2)
            let need = DuoCharacter.allCases.reduce(seam.lowest - seam.highest) { total, f in
                let box = FaceBoxes.layout(f)
                return total + heights[f]! + gap + 4 + 0.7 * (box.max.y - box.min.y) * m.minimumScale
            }
            check(speaker == nil && key.bubbles.count == 2 && c != key.lead && need > m.bandHeight * (1 - 0.0025),
                  "\(label): \(c)'s neutral caption is hidden though both fit (need \(need) pt)")
            expected[c] = nil
        }
        check(Set(layout.bubbles.keys) == Set(expected.keys), "\(label): bubbles \(layout.bubbles.keys)")
        for (c, slot) in layout.bubbles {
            check(slot.kind == expected[c], "\(label): \(c) bubble kind")
            check(slot.tailX >= slot.rect.minX + 30 - 1e-9 && slot.tailX <= slot.rect.maxX - 30 + 1e-9,
                  "\(label): \(c) tail stays 30 pt inside the bubble")
            check(slot.isSpeaker == (c == speaker), "\(label): \(c) speaker flag")
            let span = seamExtremes(layout, from: slot.rect.minX, to: slot.rect.maxX)
            if c == speaker {
                let clearance = c == .angel ? span.highest - slot.rect.maxY : slot.rect.minY - span.lowest
                check(clearance >= 16 - 1e-6, "\(label): the speaker's bubble is \(clearance) pt from the seam")
                near(slot.rect.width, StageLayout.speakerBubbleWidth(m.width), 1e-9, "\(label): speaker bubble width")
            } else {
                let gap = key.pill ? max(30, layout.pill!.height / 2 + 8) : 30
                let clearance = c == .angel ? span.highest - slot.rect.maxY : slot.rect.minY - span.lowest
                check(clearance >= gap - 1e-6, "\(label): \(c)'s bubble is \(clearance) pt from the seam")
                near(slot.rect.width, StageLayout.neutralBubbleWidth(m.width), 1e-9, "\(label): neutral bubble width")
            }
            // A bubble never covers the other face's features, nor its own unless squeezed.
            for f in DuoCharacter.allCases where f != c || layout[f].squeeze == 0 {
                check(!layout.featureBox(f).intersects(slot.rect), "\(label): \(c)'s bubble covers \(f)'s features")
            }
            // Clearances: the angel's face in [band.top + 4, bubble.top − 19]; the speaking
            // devil's face bottom (mouth +62.5) ≥ 15 pt above his bubble; a neutral devil's face
            // ≥ 19 pt below his. A squeezed face gives up that clearance, and then overlaps the
            // bubble by no more than its overlap.
            let face = layout[c], box = layout.faceBox(c)
            let gap: Double, reach: Double
            switch c {
            case .angel:
                check(box.minY >= m.bandTop + 4 - 1e-6, "\(label): the angel's face is \(box.minY - m.bandTop) pt below the band top")
                (gap, reach) = (StageLayout.bubbleGap, box.maxY - slot.rect.minY)
            case .devil where slot.isSpeaker:
                let chin = face.point(Vec2(0, DevilGeometry.mouthAnchor.y + DevilGeometry.mouthDepth)).y
                (gap, reach) = (15, chin - slot.rect.minY)
            case .devil:
                (gap, reach) = (StageLayout.bubbleGap, slot.rect.maxY - box.minY)
            }
            if face.squeeze == 0 {
                check(reach <= -gap + 1e-6, "\(label): \(c)'s face is \(-reach) pt from its bubble, not \(gap)")
            } else {
                check(reach <= face.overlap + 1e-6, "\(label): \(c)'s face reaches \(reach) pt into its bubble "
                    + "(overlap \(face.overlap))")
            }
        }
        // With nobody on the floor, a push keeps both characters' minimum room.
        if speaker == nil {
            let room = StageLayout.roomLimits(metrics: m), seam = layout.seam, preset = layout.presetSeam
            func lowest(_ s: SeamShape) -> Double { s.centre + abs(s.drift) }
            func highest(_ s: SeamShape) -> Double { s.base - abs(s.wave) - abs(s.drift) }
            check(lowest(seam) <= max(room.maxLowest, lowest(preset)) + 1e-9
                      && highest(seam) >= min(room.minHighest, highest(preset)) - 1e-9,
                  "\(label): the neutral seam (centre \(seam.centre)) leaves the characters' rooms")
            // The idle drift gives way only to fit faces and captions.
            check(seam.drift == preset.drift || (!layout.bubbles.isEmpty || key.pill) && seam.drift == 0,
                  "\(label): the idle drift is \(seam.drift)")
        }

        if key.pill {
            let pill = layout.pill!
            for c in DuoCharacter.allCases {
                check(pill.distance(to: layout.featureBox(c)) >= 8 - 1e-6, "\(label): the pill is too close to \(c)")
            }
        } else {
            check(layout.pill == nil, "\(label): no pill")
        }

        check(Set(layout.capsules.keys) == (listener.map { key.capsules.contains($0) ? [$0] : [] } ?? []),
              "\(label): capsules \(layout.capsules.keys)")
        for (c, capsule) in layout.capsules {
            check(capsule.rect.width == 52 && capsule.rect.height == 30, "\(label): capsule size")
            check(capsule.clear, "\(label): no clear capsule spot")
            for f in DuoCharacter.allCases {
                for box in FaceBoxes.eyes(f) + FaceBoxes.brows(f) + [FaceBoxes.mouth(f)] {
                    check(!layout[f].rect(box).intersects(capsule.rect), "\(label): the capsule covers \(f)'s features")
                }
            }
            if let speaker, let bubble = layout.bubbles[speaker] {
                check(!bubble.rect.intersects(capsule.rect), "\(label): the capsule covers the bubble")
            }
            if c == .angel {
                // The squished angel's capsule floats beside her head, over a wing: well clear of
                // the header's buttons in the top corners (they end 8 pt above the band) and of
                // her wings.
                let head = layout[.angel].rect(FaceBoxes.layout(.angel))
                check(capsule.rect.minY >= m.bandTop + 40 && capsule.rect.midX >= head.minX
                          && capsule.rect.midX <= head.maxX,
                      "\(label): the angel's capsule \(capsule.rect) is not beside her head (\(head))")
                let wing = FaceBoxes.Box(min: AngelGeometry.wingBoxMin, max: AngelGeometry.wingBoxMax)
                let mirrored = FaceBoxes.Box(min: Vec2(-wing.max.x, wing.min.y), max: Vec2(-wing.min.x, wing.max.y))
                for box in [wing, mirrored] {
                    check(!layout[.angel].rect(box).intersects(capsule.rect), "\(label): the capsule covers a wing")
                }
            }
            // Beats pulse the seam toward the listener by up to the pulse limit, and the
            // speaking angel's energy swells her bulge by up to 6%.
            let live = seamExtremes(layout, from: capsule.rect.minX, to: capsule.rect.maxX, margin: SeamRig.pulseLimit)
            let swell = c == .devil ? 0.06 * max(0, layout.seam.bulge) * m.bandHeight : 0
            let clearance = c == .angel ? live.highest - capsule.rect.maxY : capsule.rect.minY - live.lowest - swell
            check(clearance >= 6 - 1e-6, "\(label): the capsule is \(clearance) pt from the live seam")
        }
        return crowded
    }

    static func layoutMatrix() {
        let devices: [(String, StageMetrics, (Double, Double, Double, Double))] = [
            ("iPhone SE", .iPhoneSE, (375, 667, 86, 541)), ("iPhone 18 Pro", .iPhone18Pro, (402, 874, 128, 714)),
            ("iPhone Pro Max", .iPhoneProMax, (440, 956, 128, 796)),
            ("iPad portrait", .iPadPortrait, (820, 1180, 90, 1030)),
            ("iPad landscape", .iPadLandscape, (1180, 820, 90, 670)),
        ]
        for (name, m, size) in devices {
            check(m.width == size.0 && m.height == size.1 && m.bandTop == size.2 && m.bandBottom == size.3,
                  "\(name) metrics")
        }
        near(StageMetrics.iPhone18Pro.scale, 0.977, 0.001, "18 Pro s_n")
        near(StageMetrics.iPhoneSE.scale, 0.758, 0.001, "SE s_n")
        near(StageMetrics.iPhoneProMax.scale, 1.10, 0.001, "Pro Max s_n")
        let header = StageMetrics(size: Vec2(402, 874), globalMinY: 0, headerBottom: 120, footerTop: .infinity)
        check(header.bandTop == 128 && header.bandBottom == 874 - 120, "the band before the footer is measured")

        var keys: [StageLayoutKey] = []
        let kinds: [BubbleKind?] = [nil, .caption, .dots]
        for preset in [StagePreset.neutral, .leanAngel, .leanDevil] {
            for a in kinds {
                for d in kinds {
                    for pill in [false, true] where !pill || (a != .caption && d != .caption) {
                        for lead in DuoCharacter.allCases {
                            var key = StageLayoutKey(preset: preset, pill: pill, lead: lead)
                            key.bubbles[.angel] = a
                            key.bubbles[.devil] = d
                            keys.append(key)
                        }
                    }
                }
            }
        }
        for preset in [StagePreset.angelFloor, .devilFloor] {
            let speaker = preset.speaker!, listener = preset.listener!
            for caption in [false, true] {
                for capsule in [false, true] {
                    var key = StageLayoutKey(preset: preset)
                    if caption { key.bubbles[speaker] = .caption }
                    // The listener's caption is in the key but hidden.
                    key.bubbles[listener] = .caption
                    if capsule { key.capsules = [listener] }
                    keys.append(key)
                }
            }
        }
        var solved = 0, squeezed = 0, overlapped = 0, pushed = 0, dropped = 0, stills = 0, stillPro = 0
        var crowdedDevices: Set<String> = [], crowded = 0
        for (name, m, _) in devices {
            var regions: [StageLayoutKey: PerCharacter<StageRect>] = [:]
            for key in keys {
                for h in [0.0, 44, 64, 84, 104, 168] {
                    // Typing dots never wrap: their bubble is at most 64 pt tall, even at AX2.
                    var heights: [DuoCharacter: Double] = [:]
                    for c in DuoCharacter.allCases { heights[c] = key.bubbles[c] == .dots ? min(h, 64) : h }
                    for p in [0.0, 46, 68] where key.pill || p == 0 {
                        let layout = StageLayout.solve(key: key, metrics: m, bubbleHeights: heights, pillHeight: p)
                        if verify(layout, "\(name) \(key.preset) \(key.bubbles) lead \(key.lead) pill \(key.pill ? p : 0) h \(h)",
                                  ax2: h == 168, heights: heights) {
                            crowded += 1
                            crowdedDevices.insert(name)
                        }
                        if let known = regions[key] {
                            check(known == layout.regions, "\(name): accessibility regions depend only on the key")
                        }
                        regions[key] = layout.regions
                        check(layout.regions.angel.maxY == layout.regions.devil.minY
                                  && layout.regions.angel.minY == m.bandTop && layout.regions.devil.maxY == m.bandBottom,
                              "\(name): the regions split the band at the seam")
                        solved += 1
                        if DuoCharacter.allCases.contains(where: { layout[$0].squeeze > 0 }) { squeezed += 1 }
                        if DuoCharacter.allCases.contains(where: { layout[$0].overlap > 0 }) { overlapped += 1 }
                        dropped += layout.hidden.count
                        if layout.seam != layout.presetSeam { pushed += 1 }
                        if layout.seam.drift < layout.presetSeam.drift {
                            stills += 1
                            if name == "iPhone 18 Pro" && h <= 84 { stillPro += 1 }
                        }
                    }
                }
            }
        }
        check(solved >= 4000, "the matrix covers \(solved) layouts")
        print("STAGE_RIG_LAYOUT: \(solved) layouts, \(pushed) pushed, \(squeezed) squeezed, \(overlapped) overlapped "
            + "(\(crowded) below AX2 with two neutral bubbles), \(dropped) neutral captions dropped, "
            + "\(stills) drifts held still")
        check(stillPro == 0, "the 18 Pro keeps the idle drift with captions up to 84 pt (\(stillPro) held still)")
        check(crowdedDevices.isSubset(of: ["iPhone SE"]), "overlaps below AX2 only on the SE: \(crowdedDevices)")
        check(pushed > 0 && squeezed > 0 && overlapped > 0, "the matrix exercises every fit step (push \(pushed), "
            + "squeeze \(squeezed), overlap \(overlapped))")

        // Bubble heights: rounded to 4 pt, with 6 pt of hysteresis unless the kind changes.
        check(StageLayout.layoutHeight(measured: 61.7, previous: nil) == 60, "heights round to 4 pt")
        check(StageLayout.layoutHeight(measured: 66.3, previous: 64) == 64, "a 4-pt change keeps the height")
        check(StageLayout.layoutHeight(measured: 70.3, previous: 64) == 72, "an 8-pt change takes")
        check(StageLayout.layoutHeight(measured: 66.3, previous: 64, kindChanged: true) == 68, "a new kind takes")

        // Room clamps: the squished listener keeps its minimum room.
        for (name, m, _) in devices {
            let floor = StageLayout.solve(key: StageLayoutKey(preset: .angelFloor), metrics: m)
            let room = m.y(StageLayout.floorV) - m.y(floor.seam.centre)
            check(room >= StageLayout.minimumRoom(for: .devil, metrics: m) - 1e-6, "\(name): the devil's room \(room)")
            let ceiling = StageLayout.solve(key: StageLayoutKey(preset: .devilFloor), metrics: m)
            let headroom = m.y(ceiling.seam.base - abs(ceiling.seam.wave)) - m.y(StageLayout.ceilingV)
            check(headroom >= StageLayout.minimumRoom(for: .angel, metrics: m) - 1e-6, "\(name): the angel's room \(headroom)")
        }
        let pro = StageMetrics.iPhone18Pro
        near(StageLayout.minimumRoom(for: .devil, metrics: pro), 112, 0, "the devil's room is at least 112 pt")
        near(StageLayout.minimumRoom(for: .angel, metrics: pro), 201 * 0.86 * pro.scale + 8, 1e-12, "the angel's room")
        let clamped = StageLayout.solve(key: StageLayoutKey(preset: .angelFloor), metrics: pro)
        check(clamped.seam.bulge < KeyPoses.angelFloorBulge && clamped.seam.base == KeyPoses.angelFloorBase,
              "the 18 Pro's angelFloor clamp cuts the bulge first (bulge \(clamped.seam.bulge))")
        near(pro.y(StageLayout.floorV) - pro.y(clamped.seam.centre), 112, 1e-9, "to exactly the devil's minimum room")
        let tight = StageMetrics(width: 402, height: 600, bandTop: 128, bandBottom: 428)
        let flattened = StageLayout.solve(key: StageLayoutKey(preset: .angelFloor), metrics: tight)
        check(flattened.seam.bulge == 0 && flattened.seam.base < KeyPoses.angelFloorBase,
              "a short band then moves the base")
        near(tight.y(StageLayout.floorV) - tight.y(flattened.seam.centre), StageLayout.minimumRoom(for: .devil, metrics: tight),
             1e-9, "to the devil's minimum room")
        let lowered = StageLayout.solve(key: StageLayoutKey(preset: .devilFloor), metrics: tight)
        check(lowered.seam.wave == KeyPoses.devilFloorAmplitude && lowered.seam.base > KeyPoses.devilFloorMean,
              "devilFloor has no bulge: a short band moves the base and keeps the wave")
        near(tight.y(lowered.seam.base - lowered.seam.wave) - tight.y(StageLayout.ceilingV),
             StageLayout.minimumRoom(for: .angel, metrics: tight), 1e-9, "to the angel's minimum room")

        // The live seam keeps 8 pt from the speaker's bubble, and 6 pt from the writing
        // listener's capsule, through a handover and 3 s of speech with beats, pulses, a pause
        // and a push-back.
        var tightestCapsule = Double.infinity
        for (name, m, _) in devices {
            for h in [44.0, 84, 104, 168] {
                for speaker in DuoCharacter.allCases {
                    let listener: DuoCharacter = speaker == .angel ? .devil : .angel
                    var script = StageScript(duration: 4)
                    script.at(0.1) { $0.active = true }
                    script.at(0.5) {
                        $0.floor = speaker
                        $0.captions[speaker] = "A sentence long enough to wrap."
                        $0.talking = [speaker]
                        $0.thinking = [listener]
                    }
                    script.speak(speaker, from: 0.5, to: 3.5, seed: 5, silences: [1.8...2.6])
                    script.at(3.5) { $0.talking = [] }
                    var sim = StageSimulation(seed: 3, metrics: m)
                    sim.update(metrics: m, bubbleHeights: [speaker: h], pillHeight: 0)
                    var next = 0, checked = 0
                    var pushedBack = false
                    var capsuleGap = Double.infinity
                    var events: [StageEvent] = []
                    var regions: [StageLayoutKey: PerCharacter<StageRect>] = [:]
                    for k in 1...480 {
                        let time = Double(k) / 120
                        while next < script.steps.count, script.steps[next].time <= time {
                            sim.receive(script.steps[next].inputs, at: script.steps[next].time)
                            next += 1
                        }
                        let frame = sim.advance(to: time, mouths: script)
                        events += sim.drainEvents().map(\.event)
                        if sim.seam.pulse.value < -1e-4 { pushedBack = true }
                        if let known = regions[sim.layout.key] {
                            check(known == sim.layout.regions, "\(name): regions are constant for a key")
                        }
                        regions[sim.layout.key] = sim.layout.regions
                        guard sim.stageFloor == speaker, !sim.pendingSlots.contains(speaker),
                              let bubble = sim.layout.bubbles[speaker]?.rect else { continue }
                        for i in 0...32 {
                            let x = bubble.minX + bubble.width * Double(i) / 32
                            let y = m.y(frame.seam(at: m.u(x)))
                            let gap = speaker == .angel ? y - bubble.maxY : bubble.minY - y
                            check(gap >= 8, "\(name) h \(h) \(speaker): the live seam is \(gap) pt from the bubble at \(time) s")
                        }
                        // The writing listener's capsule shows once the seam clears it, and then
                        // keeps 6 pt from the live seam.
                        guard !sim.pendingSlots.contains(listener) else { continue }
                        let capsule = sim.layout.capsules[listener]!.rect
                        for i in 0...8 {
                            let x = capsule.minX + capsule.width * Double(i) / 8
                            let y = m.y(frame.seam(at: m.u(x)))
                            let gap = listener == .angel ? y - capsule.maxY : capsule.minY - y
                            capsuleGap = min(capsuleGap, gap)
                            check(gap >= 6, "\(name) h \(h) \(listener): the live seam is \(gap) pt from the capsule at \(time) s")
                        }
                        checked += 1
                    }
                    check(checked > 300, "\(name): the bubble was checked over the line")
                    tightestCapsule = min(tightestCapsule, capsuleGap)
                    check(pushedBack, "\(name) \(speaker): the writing listener pushed back during the pause")
                    for event in [StageEvent.pause(speaker), .resume(speaker), .slotClear(speaker), .slotClear(listener)] {
                        check(events.contains(event), "\(name) \(speaker): \(event)")
                    }
                    check(events.contains { if case .beat(speaker, _) = $0 { true } else { false } }, "\(name): beats")
                }
            }
        }
        print(String(format: "STAGE_RIG_LIVE: the capsule kept at least %.1f pt from the live seam", tightestCapsule))
    }

    // MARK: Activity and idle

    /// Drives a simulation the way `StageDriver` does: frames at 60 Hz while it needs them,
    /// otherwise a skip to its next wake. Returns each frame's time and tier.
    private static func drive(_ sim: inout StageSimulation, script: StageScript, until end: Double)
        -> [(time: Double, activity: StageActivity, wake: Double?)] {
        var log: [(Double, StageActivity, Double?)] = []
        var next = 0
        var time = sim.time
        while time < end {
            let pending = next < script.steps.count ? script.steps[next].time : Double.infinity
            if sim.needsFrames || pending <= time + 1.0 / 60 {
                time += 1.0 / 60
            } else {
                // Asleep: skip to the next wake or input, whichever is first. The skip stops
                // early where a deadline on the way sets the stage moving.
                sim.skip(to: min(sim.nextWake ?? end, pending, end))
                time = sim.time + 1.0 / 240
            }
            while next < script.steps.count, script.steps[next].time <= time {
                sim.receive(script.steps[next].inputs, at: script.steps[next].time)
                next += 1
            }
            sim.advance(to: time, mouths: script)
            log.append((time, sim.activity, sim.nextWake))
        }
        return log
    }

    static func activity() {
        let m = StageMetrics.iPhone18Pro
        var script = StageScript(duration: 70)
        script.at(0.5) { $0.active = true }
        script.at(1.0) {
            $0.floor = .angel
            $0.captions[.angel] = "Go to the gym tonight."
            $0.talking = [.angel]
        }
        script.speak(.angel, from: 1.0, to: 3.0, seed: 2)
        script.at(3.0) { $0.talking = [] }
        script.at(3.4) { $0.floor = nil }
        // The idle drift rests here, so the stage sleeps once the breath has stopped.
        let resting = SeamRig.Options(drift: false)
        var sim = StageSimulation(seed: 4, metrics: m, options: resting)
        let log = drive(&sim, script: script, until: 70)
        var walk: [StageActivity] = []
        for entry in log where entry.time > 1.0 && walk.last != entry.activity { walk.append(entry.activity) }
        let order: [StageActivity] = [.transition, .speech, .ambient, .asleep]
        var index = 0
        for tier in walk where index < order.count && tier == order[index] { index += 1 }
        check(index == order.count, "tiers walk transition → speech → ambient → asleep: \(walk)")
        check(walk.first == .transition, "the handover runs at the display rate")
        let firstAsleep = log.first { $0.time > 3.4 && $0.activity == .asleep }!.time
        check(firstAsleep >= 3.4 + StageSimulation.ambientTimeout,
              "an active stage breathes until 60 s without input (asleep at \(firstAsleep))")
        check(firstAsleep <= 3.4 + StageSimulation.ambientTimeout + 2, "then sleeps (at \(firstAsleep))")
        check(log.contains { $0.activity == .ambient }, "ambient breathing")
        let interval = StageActivity.ambient.frameInterval()
        check(interval == 1.0 / 30 && StageActivity.speech.frameInterval() == 1.0 / 60
                  && StageActivity.transition.frameInterval() == nil, "tier intervals")

        // Not active: asleep within 2 s of settling, waking within 6 s.
        var ending = script
        ending.at(4.0) { $0.active = false }
        var idle = StageSimulation(seed: 4, metrics: m, options: resting)
        let idleLog = drive(&idle, script: ending, until: 20)
        let asleep = idleLog.first { $0.time > 4.0 && $0.activity == .asleep }!
        let lastTransition = idleLog.last { $0.time < asleep.time && $0.activity == .transition }!.time
        check(asleep.time - lastTransition <= 2, "asleep \(asleep.time - lastTransition) s after settling")
        check(asleep.wake.map { $0 - asleep.time <= 6 } == true, "the next wake is within 6 s")
        let sleeping = idleLog.filter { $0.time >= asleep.time }
        var running = 0.0
        for (a, b) in zip(sleeping, sleeping.dropFirst()) where a.activity.isRunning { running += b.time - a.time }
        let span = sleeping.last!.time - asleep.time
        check(running < 0.3 * span, "the idle stage runs \(running) s of \(span) s (blinks only)")
        check(sleeping.contains { $0.activity == .speech }, "blinks wake the idle stage")

        // Doze after 30 s without input, with wakes at least 10 s apart.
        var dozer = StageSimulation(seed: 9, metrics: m, options: resting)
        let dozeLog = drive(&dozer, script: StageScript(duration: 200), until: 200)
        let dozing = dozeLog.first { $0.activity == .dozing }!
        check(dozing.time >= CharacterDirector.dozeAfter && dozing.time <= CharacterDirector.dozeAfter + 1,
              "dozing from \(dozing.time) s")
        check(dozer.roles == PerCharacter(angel: .dozing, devil: .dozing), "both doze")
        var wakes: [Double] = []
        for (previous, entry) in zip(dozeLog, dozeLog.dropFirst())
            where entry.time > dozing.time && previous.activity == .dozing && entry.activity.isRunning {
            wakes.append(entry.time)
        }
        check(wakes.count >= 5, "doze peeks wake the stage (\(wakes.count))")
        for (a, b) in zip(wakes, wakes.dropFirst()) { check(b - a >= 10, "doze wakes \(b - a) s apart") }
        check(dozeLog.filter { $0.time > dozing.time }.allSatisfy { $0.activity != .asleep },
              "a dozing stage reports .dozing when it sleeps")

        // An inactive scene freezes sim time.
        var frozen = StageSimulation.snapshot(pose: .neutral, metrics: m)
        let before = frozen.advance(to: 1, mouths: SilentMouths())
        frozen.receive(StageMode(sceneActive: false), at: before.time)
        let still = frozen.advance(to: 6, mouths: SilentMouths())
        check(still.time == before.time && still.digest() == before.digest(), "sim time stands still while inactive")
        check(frozen.activity == .paused && !frozen.needsFrames, "an inactive scene is paused")
        // The driver's clock offset grew by the inactive time, so sim time resumes where it froze.
        frozen.receive(StageMode(), at: before.time)
        let resumed = frozen.advance(to: before.time + 0.05, mouths: SilentMouths())
        check(resumed.time > before.time && resumed.time <= before.time + 0.05, "it resumes without a jump")

        // A long skip wakes to at most one gesture on the next frame.
        for active in [false, true] {
            var skipper = StageSimulation(seed: 12, metrics: m, options: resting)
            var inputs = StageInputs()
            inputs.active = active
            skipper.receive(inputs, at: 0.1)
            var t = 0.0
            while skipper.needsFrames || t < 0.2 {
                t += 1.0 / 60
                skipper.advance(to: t, mouths: SilentMouths())
            }
            _ = skipper.drainEvents()
            check(!skipper.needsFrames, "settled before the skip")
            skipper.skip(to: t + 3600)
            near(skipper.time, t + 3600, 1.0 / 240, "skip moves sim time")
            skipper.advance(to: t + 3600 + 1.0 / 60, mouths: SilentMouths())
            let gestures = skipper.drainEvents().filter { if case .gesture = $0.event { true } else { false } }
            check(gestures.count <= 1, "at most one gesture after a long skip (\(gestures.count))")
        }
        // Both characters due together: the skip spaces them 0.25 s apart. (The skip stops
        // short of the doze at 30 s, which pauses blinks.)
        for seed in UInt64(0)..<200 {
            var pair = StageSimulation(seed: seed, metrics: m, options: resting)
            pair.advance(to: 0.05, mouths: SilentMouths())
            let a = pair.directors.angel.nextBlink!, d = pair.directors.devil.nextBlink!
            pair.skip(to: 25)
            near(pair.time, 25, 1e-9, "seed \(seed): the idle skip reaches its time")
            let a2 = pair.directors.angel.nextBlink!, d2 = pair.directors.devil.nextBlink!
            check(abs(a2 - d2) >= StageSimulation.skipSpacing - 1e-9, "seed \(seed): blinks \(a2), \(d2) after a skip")
            if abs(a - d) >= StageSimulation.skipSpacing {
                near(a2 - d2, a - d, 1e-9, "seed \(seed): spaced blinks keep their order and gap")
            }
        }

        // A skip meets the stage's deadlines on the way: from inside the floor's debounce or the
        // release hold, the exchange still ends 0.2 s after the floor does and the release starts
        // 0.25 s later, where the skip stops for frames.
        for (label, skipFrom) in [("debounce", 0.05), ("release hold", 0.3)] {
            var held = StageSimulation(seed: 2, metrics: m, options: resting)
            var line = StageInputs()
            line.floor = .angel
            line.talking = [.angel]
            line.captions[.angel] = "Go to the gym tonight."
            held.receive(line, at: 0.5)
            line.talking = []
            held.receive(line, at: 1.5)
            line.floor = nil
            let floorEnd = 4.0
            held.receive(line, at: floorEnd)
            var t = 0.0
            var heldEvents: [StageEventRecord] = []
            while t < floorEnd + skipFrom - 1e-9 || held.needsFrames {
                t += 1.0 / 240
                held.advance(to: t, mouths: ConstantMouths())
                heldEvents += held.drainEvents()
            }
            check(held.time < floorEnd + 0.45 - 1e-9 && (label == "debounce") == (held.time < floorEnd + 0.2 - 1e-9),
                  "\(label): the stage sleeps inside the \(label) (\(held.time) s)")
            held.skip(to: floorEnd + 5)
            heldEvents += held.drainEvents()
            check(heldEvents.contains { $0.event == .exchangeEnded && abs($0.time - (floorEnd + 0.2)) < 1e-9 },
                  "\(label): the exchange ends at its time")
            near(held.time, floorEnd + 0.45, 1e-9, "\(label): the skip stops where the release starts")
            check(held.seam.motion == .release(start: floorEnd + 0.45) && held.needsFrames,
                  "\(label): the release starts at its time (\(held.seam.motion))")
        }

        // A repeated time changes nothing.
        var repeated = StageSimulation(seed: 5, metrics: m)
        repeated.receive(StagePose.angelTalking.inputs(), at: 0.5)
        let first = repeated.advance(to: 0.7, mouths: ConstantMouths())
        let again = repeated.advance(to: 0.7, mouths: ConstantMouths())
        let earlier = repeated.advance(to: 0.6, mouths: ConstantMouths())
        check(first.digest() == again.digest() && again == earlier && repeated.time == first.time,
              "advance with a repeated or earlier time returns the cached frame")
    }

    // MARK: Idle drift

    /// With nobody on the floor the seam flows in two slow waves, on the start screen as in a
    /// conversation: level on average at every point and at every moment (no bowl or lean toward
    /// either half), within the drift's amplitude of the band's middle and calm from frame to
    /// frame, with its soft edge showing. Three minutes after the last input it settles into its
    /// still S-curve and the stage sleeps; an input or the app's return sets it flowing again
    /// without a jump. Under Reduce Motion it is the still S-curve.
    static func idleDrift() {
        let m = StageMetrics.iPhone18Pro
        let a = SeamShape.idleDrift
        func still(_ k: Int) -> Double {
            0.5 + a * SeamRig.driftProfile(Double(k) / 48, phases: (0, 0), still: 1)
        }
        // The seam's average height across the window (the trapezoid rule over its samples).
        func average(_ seam: [Double]) -> Double { (seam.reduce(0, +) - (seam[0] + seam[48]) / 2) / 48 }
        // The flow's fastest rate at any point (band/s).
        let calm = 2 * Double.pi * a * (SeamRig.driftWeights.0 / SeamRig.driftPeriods.0
            + SeamRig.driftWeights.1 / SeamRig.driftPeriods.1)
        check(SeamRig.driftPeriods.0 >= 7 && SeamRig.driftPeriods.1 >= 7, "the drift's periods are seconds long")
        check(StageSimulation.driftTimeout == 180, "the drift rests after three idle minutes")

        // The start screen: no conversation; a tap at 200 s.
        var sim = StageSimulation(seed: 3, metrics: m)
        sim.update(metrics: m, bubbleHeights: [:], pillHeight: 0)
        sim.settleAll()
        var sums = Array(repeating: 0.0, count: SeamRig.sampleCount), count = 0
        var reach = 0.0, middle = (low: Double.infinity, high: -Double.infinity), steepest = 0.0, unevenest = 0.0
        var previous: [Double]?, rested = 0, dozed = false, resumed = 0.0, resumeStep = 0.0, edge = 1.0
        var tapped = false
        for k in 1...(215 * 60) {
            let t = Double(k) / 60
            if !tapped, t >= 200 {
                var inputs = StageInputs()
                inputs.active = true
                sim.receive(inputs, at: 200)
                tapped = true
            }
            let frame = sim.advance(to: t, mouths: SilentMouths())
            let seam = frame.picture.seam
            edge = min(edge, frame.picture.restEdge)
            let step = previous.map { zip(seam, $0).map { abs($0 - $1) }.max()! } ?? 0
            if (5...165).contains(t) {
                for (i, v) in seam.enumerated() { sums[i] += v }
                count += 1
                reach = max(reach, seam.map { abs($0 - 0.5) }.max()!)
                middle = (min(middle.low, seam[24]), max(middle.high, seam[24]))
                unevenest = max(unevenest, abs(average(seam) - 0.5))
                steepest = max(steepest, step)
            }
            if (192...199).contains(t) {
                // Rested: the still S-curve, unmoving, and the stage asleep between peeks.
                let off = seam.indices.map { abs(seam[$0] - still($0)) }.max()!
                check(off <= 1e-4 && step <= 1e-9, "at \(t) s the long-idle seam rests as its S-curve (\(off), \(step))")
                rested += 1
                if sim.activity == .dozing { dozed = true }
            }
            if t > 200 {
                resumeStep = max(resumeStep, step)
                resumed = max(resumed, abs(seam[24] - still(24)))
            }
            previous = seam
        }
        let bias = sums.map { abs($0 / Double(count) - 0.5) }.max()!
        check(bias <= 0.001, "the idle seam is level on average all along (largest bias \(bias) band)")
        check(unevenest <= 1e-9, "the idle seam splits the band evenly at every moment (\(unevenest))")
        check(reach <= a + 1e-9 && reach >= 0.7 * a, "the idle drift reaches \(reach) band from the middle")
        check((middle.high - middle.low) * m.bandHeight >= 15, "the idle seam flows (\(middle.high - middle.low) band)")
        check(steepest <= calm / 60 + 1e-9, "the idle seam moves \(steepest * m.bandHeight) pt a frame at most")
        check(edge >= 1 - 1e-9, "the seam's soft edge shows at rest (\(edge))")
        check(rested > 60 * 6 && dozed, "after three idle minutes the seam rests (\(rested) frames) and the stage dozes (\(dozed))")
        // Setting off, the still S-curve eases into the flowing waves over a few seconds.
        check(resumeStep * m.bandHeight <= 1 && resumed * m.bandHeight >= 3,
              "a tap sets the seam flowing again smoothly (\(resumeStep * m.bandHeight) pt a frame at most)")

        // The app's return sets a resting seam flowing again.
        var away = StageSimulation(seed: 3, metrics: m)
        away.update(metrics: m, bubbleHeights: [:], pillHeight: 0)
        away.settleAll()
        var at = 0.0
        while at < 195 {
            at += 1.0 / 30
            away.advance(to: at, mouths: SilentMouths())
        }
        let resting = away.frame.picture.seam
        away.receive(StageMode(sceneActive: false), at: at)
        away.advance(to: at + 1.0 / 30, mouths: SilentMouths())
        away.receive(StageMode(), at: at)
        var back = 0.0
        for k in 1...300 {
            let frame = away.advance(to: at + Double(k) / 60, mouths: SilentMouths())
            back = max(back, zip(frame.picture.seam, resting).map { abs($0 - $1) }.max()!)
        }
        check(back * m.bandHeight >= 3, "the app's return sets the seam flowing again (\(back))")

        // In a conversation the breath rides on the drift: still level at every moment, but for it.
        var talk = StageSimulation(seed: 3, metrics: m)
        talk.update(metrics: m, bubbleHeights: [:], pillHeight: 0)
        talk.settleAll()
        var active = StageInputs()
        active.active = true
        talk.receive(active, at: 0.5)
        var uneven = 0.0
        for k in 1...(40 * 60) {
            let seam = talk.advance(to: Double(k) / 60, mouths: SilentMouths()).picture.seam
            if k > 5 * 60 { uneven = max(uneven, abs(average(seam) - 0.5)) }
        }
        check(uneven <= SeamRig.breathAmplitude + 1e-9, "in a conversation the seam splits the band evenly, but for the breath (\(uneven))")

        // Under Reduce Motion the idle seam is its still S-curve, unmoving.
        var held = StageSimulation(seed: 3, metrics: m, mode: StageMode(reduceMotion: true))
        held.update(metrics: m, bubbleHeights: [:], pillHeight: 0)
        held.settleAll()
        var heldOff = 0.0
        for k in 1...(20 * 60) {
            let seam = held.advance(to: Double(k) / 60, mouths: SilentMouths()).picture.seam
            heldOff = max(heldOff, seam.indices.map { abs(seam[$0] - still($0)) }.max()!)
        }
        check(heldOff <= 1e-9, "under Reduce Motion the idle seam is its still S-curve (\(heldOff))")
    }

    // MARK: Reduce Motion

    /// One cross-fade: the frames that showed it, with their progress.
    private struct FadeTrace {
        var times: [Double] = []
        var progress: [Double] = []
    }

    /// Runs `script` at 120 Hz, delivering `modes` at their times, and splits the frames'
    /// cross-fades into fades: a new fade starts when one appears or its progress restarts.
    /// With `fromSettled`, each fade must start from the previous frame's settled profile.
    private static func fadeRun(_ sim: inout StageSimulation, script: StageScript, until end: Double,
                                modes: [(time: Double, mode: StageMode)] = [], fromSettled: Bool = true,
                                each: (Double, StageFrame, inout StageSimulation, StageLayout) -> Void = { _, _, _, _ in })
        -> (fades: [FadeTrace], events: [StageEventRecord]) {
        var next = 0, nextMode = 0
        var fades: [FadeTrace] = []
        var events: [StageEventRecord] = []
        var previousLayout = sim.layout
        for k in 1...Int((end * 120).rounded()) {
            let time = Double(k) / 120
            while next < script.steps.count, script.steps[next].time <= time {
                sim.receive(script.steps[next].inputs, at: script.steps[next].time)
                next += 1
            }
            while nextMode < modes.count, modes[nextMode].time <= time {
                sim.receive(modes[nextMode].mode, at: modes[nextMode].time)
                nextMode += 1
            }
            let frame = sim.advance(to: time, mouths: script)
            events += sim.drainEvents()
            if let fade = frame.crossFade {
                if fades.isEmpty || fades[fades.count - 1].times.last! < time - 1.0 / 120 - 1e-9
                    || fade.progress < fades[fades.count - 1].progress.last! {
                    fades.append(FadeTrace())
                    for (i, v) in fade.from.seam.enumerated() where fromSettled {
                        near(v, heldProfile(previousLayout.seam, i), 1e-12, "the fade at \(time) s starts from the old profile")
                    }
                }
                fades[fades.count - 1].times.append(time)
                fades[fades.count - 1].progress.append(fade.progress)
            }
            each(time, frame, &sim, previousLayout)
            previousLayout = sim.layout
        }
        return (fades, events)
    }

    /// Each fade rises monotonically from about 0 and lasts 0.25 s, unless the next fade
    /// starts as it ends.
    private static func checkFades(_ fades: [FadeTrace], starts: [Double], _ label: String) {
        check(fades.count == starts.count, "\(label): \(fades.count) cross-fades at \(fades.map { $0.times[0] }), "
            + "expected \(starts.count)")
        for (fade, start) in zip(fades, starts) {
            near(fade.times[0], start, 1.0 / 120 + 1e-9, "\(label): a fade starts")
            check(fade.progress[0] < 0.1 && fade.progress.last! > 0.9, "\(label): the fade at \(start) s rises from 0 to 1")
            check(zip(fade.progress, fade.progress.dropFirst()).allSatisfy { $0 < $1 },
                  "\(label): the fade at \(start) s rises monotonically")
            near(fade.times.last! - fade.times[0], StageSimulation.crossFadeDuration, 1.0 / 60,
                 "\(label): the fade at \(start) s lasts 0.25 s")
        }
    }

    /// Seam sample `i` of `shape` held still: the design profile, with the idle drift as its
    /// still S-curve.
    private static func heldProfile(_ shape: SeamShape, _ i: Int) -> Double {
        let u = Double(i) / 48
        return shape.value(at: u) + shape.drift * SeamRig.driftProfile(u, phases: (0, 0), still: 1)
    }

    static func reduceMotion() {
        let m = StageMetrics.iPhone18Pro
        var sim = StageSimulation(seed: 6, metrics: m, mode: StageMode(reduceMotion: true))
        var script = StageScript(duration: 6)
        script.at(0.5) { $0.active = true }
        script.at(1.0) {
            $0.floor = .angel
            $0.talking = [.angel]
            $0.captions[.angel] = "Go to the gym tonight."
        }
        script.speak(.angel, from: 1.0, to: 2.0, seed: 3)
        script.at(2.0) { $0.talking = [] }
        script.at(3.5) { $0.floor = nil }
        var afterwards: [StageActivity] = []
        let run = fadeRun(&sim, script: script, until: 6) { time, frame, sim, _ in
            check(sim.maxSpringSpeed == 0, "every spring is at rest under Reduce Motion (\(time) s)")
            for c in DuoCharacter.allCases {
                let pose = frame.picture.faces[c], placement = sim.layout[c]
                check(pose.anchor == placement.anchor && pose.scale == placement.scale && pose.pivot == placement.pivot
                          && pose.tilt == 0, "\(c) holds its settled placement at \(time) s")
                near(pose.sy, placement.squash, 1e-9, "\(c) holds its settled squash at \(time) s")
            }
            for (i, v) in frame.picture.seam.enumerated() {
                near(v, heldProfile(sim.layout.seam, i), 1e-12, "the seam holds its settled profile at \(time) s")
            }
            if time > 3.0, time < 3.5 { afterwards.append(sim.activity) }
        }
        // The handover; then the exchange end's afterglow expressions, and the release 0.25 s
        // later: each change of held layout or expression is one fade.
        checkFades(run.fades, starts: [1.0, 3.7, 3.95], "Reduce Motion")
        let events = run.events.map(\.event)
        check(!events.contains { if case .gesture = $0 { true } else { false } }, "no blinks under Reduce Motion")
        check(!events.contains { if case .beat = $0 { true } else { false } }, "no beats under Reduce Motion")
        check(!events.contains { if case .impact = $0 { true } else { false } }, "no impact under Reduce Motion")
        check(events.contains(.slotClear(.angel)), "the bubble still appears")
        check(afterwards.allSatisfy { $0 == .asleep }, "the stage then sleeps: \(Set(afterwards))")
        check(sim.frame.picture.dominant == .angel, "the angel stays on top")

        // Reduce Motion turned on while the devil speaks (wave travelling) or waits (seam
        // relaxed): the seam snaps to the held pose, the wave static at φ 0.6288.
        for toggle in [1.8, 3.2] {
            var devil = StageSimulation(seed: 6, metrics: m)
            var line = StageScript(duration: 5)
            line.at(0.2) { $0.active = true }
            line.at(0.5) {
                $0.floor = .devil
                $0.talking = [.devil]
                $0.captions[.devil] = "Oh, please, Angel!"
            }
            line.speak(.devil, from: 0.5, to: 5, seed: 4, silences: [2.0...3.6])
            var travelled = false, relaxed = false
            let toggled = fadeRun(&devil, script: line, until: 5, modes: [(toggle, StageMode(reduceMotion: true))],
                                  fromSettled: false) {
                time, frame, sim, _ in
                if time < toggle - 1e-9 {
                    travelled = travelled || sim.seam.phase != KeyPoses.restPhase
                    relaxed = sim.seam.relax.value > 0.5
                    return
                }
                check(sim.seam.phase == KeyPoses.restPhase && sim.seam.phaseRate == 0,
                      "Reduce Motion from \(toggle) s freezes φ at 0.6288 (\(sim.seam.phase) at \(time) s)")
                check(sim.maxSpringSpeed == 0, "springs rest after Reduce Motion turns on (\(time) s)")
                for (i, v) in frame.picture.seam.enumerated() {
                    near(v, heldProfile(sim.layout.seam, i), 1e-12,
                         "Reduce Motion from \(toggle) s: the seam holds the design profile at \(time) s")
                }
            }
            check(travelled, "the wave travelled before \(toggle) s")
            check(relaxed == (toggle > 3), "the seam was \(relaxed ? "" : "not ")relaxed at \(toggle) s")
            checkFades(toggled.fades, starts: [toggle], "Reduce Motion from \(toggle) s")
        }

        // Prefer Cross-Fade Transitions alone: the handover and the release cross-fade; the
        // speaker's lean-ins, beats, blinks and the travelling seam remain.
        var lines = StageScript(duration: 8)
        lines.at(0.5) { $0.active = true }
        let sentences = [1.0, 2.02, 3.03, 4.04, 5.04]
        for (i, start) in sentences.enumerated() {
            lines.at(start) {
                $0.floor = .angel
                $0.talking = [.angel]
                $0.captions[.angel] = "Sentence \(i + 1) of the line."
            }
        }
        lines.speak(.angel, from: 1.0, to: 6.0, seed: 8)
        lines.at(6.0) { $0.talking = [] }
        lines.at(6.3) { $0.floor = nil }
        let crossFade = StageMode(crossFadeOnly: true)
        var fading = StageSimulation(seed: 6, metrics: m, mode: crossFade)
        var leanIns = 0, moving = 0
        var lastScaleSpeed = 0.0
        let faded = fadeRun(&fading, script: lines, until: 8, fromSettled: false) { _, _, sim, _ in
            let speed = sim.faces.angel.scale.velocity
            if speed > 0.2, lastScaleSpeed <= 0.2 { leanIns += 1 }
            lastScaleSpeed = speed
            if sim.seam.maxSpringSpeed > 0 { moving += 1 }
        }
        checkFades(faded.fades, starts: [1.0, 6.75], "Prefer Cross-Fade Transitions")
        let crossEvents = faded.events.map(\.event)
        check(leanIns >= sentences.count - 1, "each later sentence leans in (\(leanIns))")
        check(crossEvents.contains { if case .beat(.angel, _) = $0 { true } else { false } }, "beats with cross-fades")
        check(crossEvents.contains { if case .gesture(_, .blink) = $0 { true } else { false } }, "blinks with cross-fades")
        check(!crossEvents.contains { if case .impact = $0 { true } else { false } }, "the handover is a cross-fade")
        check(moving > 120, "the seam still moves with speech (\(moving) frames)")
    }

    // MARK: Timing (reported, not checked)

    static func timing() {
        // A line that never ends, so every substep integrates.
        var sim = StageSimulation(seed: 1, metrics: .iPhone18Pro)
        var inputs = StagePose.angelTalking.inputs()
        inputs.talking = [.angel]
        sim.receive(inputs, at: 0)
        let start = Date()
        var substeps = 0, t = 0.0
        while substeps < 100_000 {
            t += 1.0 / 120
            let before = sim.stepper.index
            sim.advance(to: t, mouths: ConstantMouths())
            substeps += Int(sim.stepper.index - before)
        }
        let ms = Date().timeIntervalSince(start) * 1000
        print(String(format: "STAGE_RIG_TIMING: %d substeps in %.1f ms", substeps, ms))
    }
}

// MARK: - Faces

/// A mouth source that answers only for some characters.
private struct OnlyMouths: MouthSource {
    var script: StageScript
    var characters: Set<DuoCharacter>

    func drive(_ character: DuoCharacter, at simTime: Double) -> MouthDrive? {
        characters.contains(character) ? script.drive(character, at: simTime) : nil
    }
}

extension StageRigChecks {
    // MARK: Path measures

    /// Each element's start and end directions (lines, quads and cubics; a close that draws a
    /// segment counts as a line).
    private static func segments(_ path: CurvePath) -> [(from: Vec2, start: Vec2, end: Vec2, to: Vec2)] {
        var result: [(Vec2, Vec2, Vec2, Vec2)] = []
        var current = Vec2.zero, first = Vec2.zero
        func direction(_ candidates: [Vec2]) -> Vec2 { candidates.first { $0.length > 1e-9 } ?? .zero }
        for element in path.elements {
            switch element {
            case .move(let p):
                current = p
                first = p
            case .line(let p):
                result.append((current, p - current, p - current, p))
                current = p
            case .quad(let c, let p):
                result.append((current, direction([c - current, p - current]), direction([p - c, p - current]), p))
                current = p
            case .cubic(let a, let b, let p):
                result.append((current, direction([a - current, b - current, p - current]),
                               direction([p - b, p - a, p - current]), p))
                current = p
            case .close:
                if (first - current).length > 1e-9 { result.append((current, first - current, first - current, first)) }
                current = first
            }
        }
        return result
    }

    /// The largest turn (degrees) where one element of a closed path meets the next.
    static func sharpestJoin(_ path: CurvePath) -> Double {
        let parts = segments(path)
        var sharpest = 0.0
        for (k, part) in parts.enumerated() {
            let next = parts[(k + 1) % parts.count]
            let a = part.end, b = next.start
            let cosine = RigMath.clamp(a.dot(b) / max(a.length * b.length, 1e-12), -1, 1)
            sharpest = max(sharpest, acos(cosine) * 180 / Double.pi)
        }
        return sharpest
    }

    /// Points along a path, each element sampled `steps` times.
    static func sampled(_ path: CurvePath, steps: Int = 32) -> [Vec2] {
        var points: [Vec2] = []
        var current = Vec2.zero
        for element in path.elements {
            switch element {
            case .move(let p): current = p; points.append(p)
            case .line(let p):
                points += (1...steps).map { Vec2.lerp(current, p, Double($0) / Double(steps)) }
                current = p
            case .quad(let c, let p):
                points += (1...steps).map { Bezier.quad(current, c, p, Double($0) / Double(steps)) }
                current = p
            case .cubic(let a, let b, let p):
                points += (1...steps).map { Bezier.cubic(current, a, b, p, Double($0) / Double(steps)) }
                current = p
            case .close: break
            }
        }
        return points
    }

    /// Whether `p` lies inside the closed polygon `polygon` (even-odd).
    static func inside(_ p: Vec2, _ polygon: [Vec2]) -> Bool {
        var result = false
        for (k, a) in polygon.enumerated() {
            let b = polygon[(k + 1) % polygon.count]
            if (a.y > p.y) != (b.y > p.y), p.x < a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x) { result.toggle() }
        }
        return result
    }

    // MARK: Face fidelity

    static func faceFidelity() {
        let m = StageMetrics.fidelity
        let neutral = StageSimulation.snapshot(pose: .neutral, metrics: m).frame
        let angel = neutral.picture.faces.angel, devil = neutral.picture.faces.devil

        // The neutral faces.
        check(angel.features.mouth == ExpressionLibrary.neutral(.angel).mouth
                  && devil.features.mouth == ExpressionLibrary.neutral(.devil).mouth,
              "the neutral faces hold their neutral mouths")
        near(angel.features.mouth.width, AngelGeometry.mouthWidth, 1e-9, "angel mouth width")
        near(angel.features.mouth.open, AngelGeometry.mouthDepth, 1e-9, "angel mouth depth")
        for sigma in [-1.0, 1] {
            near(angel.features.eyes[sigma].open, 1, 1e-9, "angel eyes open")
            near(angel.features.eyes[sigma].sclera, 0, 1e-9, "angel eyes are glossy beads")
            near(angel.features.eyes[sigma].sparkle, 1, 1e-9, "angel sparkles")
            near(devil.features.eyes[sigma].lidTop, 0.10, 1e-9, "devil lid")
            near(devil.features.eyes[sigma].lidAngle, 20, 1e-9, "devil lid angle")
        }

        // Highlights: the angel's toward the nose, the devil's to screen right in both eyes.
        for sigma in [-1.0, 1] {
            let inner = Vec2(-sigma * AngelGeometry.highlightInnerOffset.x, AngelGeometry.highlightInnerOffset.y)
            check(inner.x * sigma < 0, "the angel's highlight sits on the inner side")
        }
        check(DevilGeometry.highlightOffset.x > 0, "the devil's highlights face screen right")

        // Brows: the chords' ends, and the angel's stroke spanning x −90…−59 and y −60.5…−40.
        let (outer, inner) = BrowShape.chord(.angel, sigma: -1, params: angel.features.brows.left)
        near(outer, AngelGeometry.browOuter.sided(-1), 1e-9, "neutral angel brow outer end")
        near(inner, AngelGeometry.browInner.sided(-1), 1e-9, "neutral angel brow inner end")
        let browBox = BrowShape.angel(sigma: -1, params: angel.features.brows.left).bounds
        let pad = AngelGeometry.browStroke / 2
        near(browBox.min.x - pad, -90.04, 2, "angel brow box left")
        near(browBox.max.x + pad, -59.18, 2, "angel brow box right")
        near(browBox.min.y - pad, -60.55, 3, "angel brow box top")
        near(browBox.max.y + pad, -39.84, 2, "angel brow box bottom")
        let angle = atan2(AngelGeometry.browInner.y - AngelGeometry.browOuter.y,
                          AngelGeometry.browOuter.x - AngelGeometry.browInner.x) * 180 / Double.pi
        near(angle, AngelGeometry.browBaseAngle, 4, "angel brow base angle")
        let (dOuter, dInner) = BrowShape.chord(.devil, sigma: 1, params: devil.features.brows.right)
        near(dOuter, DevilGeometry.browOuter, 1e-9, "neutral devil brow outer end")
        near(dInner, DevilGeometry.browInner, 1e-9, "neutral devil brow inner end")
        check(dInner.y > dOuter.y, "the devil's brow drops toward the nose")

        // Mouths: the angel's open smile spans x −26.8…26.4 and y 25.4…59.8; the devil's grin has
        // its corners at (−34, +40) and (+40, +25) and its bottom at +62.5.
        let angelMouth = AngelMouthShape.outline(angel.features.mouth).map { $0 + AngelGeometry.mouthAnchor }
        let samples = (0...96).map { k -> Vec2 in
            let t = Double(k % 32) / 32, p = AngelMouthShape.points(angel.features.mouth)
            let point = switch k / 32 {
            case 0: Bezier.cubic(p[0], p[1], p[2], p[3], t)
            case 1: Bezier.cubic(p[3], p[4], p[5], p[6], t)
            default: Bezier.cubic(p[6], p[7], p[8], p[0], k == 96 ? 1 : t)
            }
            return point + AngelGeometry.mouthAnchor
        }
        let lo = Vec2(samples.map(\.x).min()!, samples.map(\.y).min()!)
        let hi = Vec2(samples.map(\.x).max()!, samples.map(\.y).max()!)
        near(lo.x, -26.76, 2, "angel mouth left")
        near(hi.x, 26.37, 2, "angel mouth right")
        near(lo.y, 25.39, 3, "angel mouth top")
        near(hi.y, 59.77, 2, "angel mouth bottom")
        check(angelMouth.bounds.max.y >= hi.y - 1e-9, "the cavity's control bounds cover it")
        let dp = DevilMouthShape.points(devil.features.mouth).map { $0 + DevilGeometry.mouthAnchor }
        near(dp[0], DevilGeometry.mouthLeftCorner, 1e-9, "devil grin left corner")
        near(dp[3], DevilGeometry.mouthRightCorner, 1e-9, "devil grin right corner")
        let bottom = (0...64).flatMap { k -> [Double] in
            let t = Double(k) / 64
            return [Bezier.cubic(dp[3], dp[4], dp[5], dp[6], t).y, Bezier.cubic(dp[6], dp[7], dp[8], dp[0], t).y]
        }.max()!
        near(bottom, DevilGeometry.mouthAnchor.y + DevilGeometry.mouthDepth, 0.5, "devil grin bottom")
        near(devil.features.mouth.fangX, DevilGeometry.fangX, 1e-9, "the fang at 0.62 of the half width")
        // Fang: about 9 × 12.5 fu, 25.6 fu right of the midline, hanging from the grin's top edge.
        let fang = DevilMouthShape.fang(devil.features.mouth)!.map { $0 + DevilGeometry.mouthAnchor }.bounds
        near((fang.min.x + fang.max.x) / 2, 25.59, 2.5, "devil fang x")
        near(fang.max.x - fang.min.x, 8.98, 2, "devil fang width")
        near(fang.max.y - fang.min.y, 12.5, 2.5, "devil fang height")
        let fangTop = InkMouth.topY(DevilMouthShape.points(devil.features.mouth), at: fang.max.x - 1
            - DevilGeometry.mouthAnchor.x) + DevilGeometry.mouthAnchor.y
        check(fang.min.y >= fangTop - 0.5 && fang.min.y <= fangTop + DevilGeometry.fangInset + 1,
              "the fang hangs from the grin's top edge (\(fang.min.y) vs \(fangTop))")

        // Halo: at rest on its anchor, level and round.
        near(angel.halo.center, angel.point(AngelGeometry.haloCenter), 1e-6, "the settled halo sits on its anchor")
        near(angel.halo.rotation, 0, 1e-9, "the halo rests level")
        near(angel.halo.squash, 1, 1e-9, "the free halo is round")

        // Wing box: x −178…−124, y −18…+72 (± 3 fu).
        var wingMin = Vec2(.infinity, .infinity), wingMax = Vec2(-.infinity, -.infinity)
        for part in WingShape.parts() {
            let b = part.bounds
            wingMin = Vec2(min(wingMin.x, b.min.x), min(wingMin.y, b.min.y))
            wingMax = Vec2(max(wingMax.x, b.max.x), max(wingMax.y, b.max.y))
        }
        near(wingMin, AngelGeometry.wingBoxMin, 3.5, "wing box min")
        near(wingMax.y, AngelGeometry.wingBoxMax.y, 3, "wing box bottom")
        check(wingMax.x <= AngelGeometry.wingBoxMax.x + 7, "the wing's inner edge stays near x −124 (\(wingMax.x))")
        near(angel.wings.left, ExpressionLibrary.neutral(.angel).accessories.wingSpread * Double.pi / 180, 1e-9,
             "wings rest at the neutral spread")

        // Horns: tips at (∓116, −117), within 2 fu, and at rest.
        let horn = HornShape.outline().points
        check(horn.contains(DevilGeometry.hornTip), "the horn outline runs through the tip")
        near(horn.map(\.y).min()!, DevilGeometry.hornTip.y - 0, 8, "nothing rises far above the horn tip")
        // One smooth closed outline with no corner anywhere, topped by the tip's round cap, widest
        // at the bulge and inside the box from the bulge to the inner base.
        let hornOutline = HornShape.outline()
        let hornCorner = sharpestJoin(hornOutline)
        check(hornCorner < 1, "the horn outline turns \(hornCorner)° at a join: it has a corner")
        let hornSamples = sampled(hornOutline)
        let hornTop = hornSamples.min { $0.y < $1.y }!, hornLeft = hornSamples.min { $0.x < $1.x }!
        near(hornTop.y, DevilGeometry.hornTip.y, 0.5, "the horn's round cap tops out at the tip")
        near(hornTop.x, DevilGeometry.hornTip.x, 2, "the horn's top is its tip")
        near(hornLeft.x, DevilGeometry.hornBulge.x, 0.2, "the horn is widest at its bulge")
        check(hornSamples.allSatisfy { $0.x <= DevilGeometry.hornInnerBase.x + 0.01 && $0.y <= DevilGeometry.hornOuterBase.y + 0.01 },
              "the horn stays inside its base corners")
        // The inner edge is concave: halfway down, it lies well inside the chord from the cap to
        // the inner base.
        let chordStart = HornShape.capEnd, chordEnd = DevilGeometry.hornInnerBase
        let chord = (chordEnd - chordStart) / (chordEnd - chordStart).length
        let innerMiddle = hornSamples.filter { $0.x > DevilGeometry.hornTip.x && abs($0.y - (chordStart.y + chordEnd.y) / 2) < 1 }
            .max { $0.x < $1.x }!
        let hollow = Vec2(-chord.y, chord.x).dot(innerMiddle - chordStart)
        check(hollow > 2, "the horn's inner edge is concave (\(hollow) fu inside its chord)")
        // The shine's bands lie inside the horn, clear of its edge, nested from the faintest
        // (widest) to the brightest.
        let shine = HornShape.shine(layers: 16)
        check(shine.count == 16, "sixteen shine bands")
        for (k, band) in shine.enumerated() {
            check(band.points.allSatisfy { inside($0, hornSamples) }, "shine band \(k) lies inside the horn")
        }
        let faintest = shine.first!.bounds, brightest = shine.last!.bounds
        check(brightest.min.y > faintest.min.y && brightest.max.y < faintest.max.y,
              "the shine fades toward both ends of its span")
        let edgeGap = shine.first!.points.map { p in hornSamples.map { ($0 - p).length }.min()! }.min()!
        check(edgeGap > 1.5, "the shine leaves a dark rim along the edge (\(edgeGap) fu)")
        near(devil.point(DevilGeometry.hornTip).y, m.y(KeyPoses.neutralDevil.eyeLine) + DevilGeometry.hornTip.y,
             1e-9, "the horn tip on the neutral devil")
        near(devil.horns.left, 0, 1e-9, "horns rest")

        // Every expression and gallery cell builds finite targets.
        for c in DuoCharacter.allCases {
            for e in FaceExpression.allCases {
                for mood in TalkingMood.allCases {
                    let t = ExpressionLibrary.targets(e, for: c, mood: mood)
                    for i in FaceTargets.channels.indices {
                        check(t.value(i).isFinite, "\(c) \(e) \(mood) channel \(i) is finite")
                    }
                }
            }
        }
        check(FaceExpression.allCases.count == 17, "17 expressions")
        check(GalleryCell.all.count == 12 && Set(GalleryCell.all.map(\.name)).count == 12, "12 gallery cells")
        for cell in GalleryCell.all {
            let still = StageSimulation.snapshot(cell: cell, metrics: m).frame
            for c in DuoCharacter.allCases {
                let face = still.picture.faces[c]
                var expected = cell[c].targets(for: c)
                expected.gaze = cell[c].gaze ?? ExpressionLibrary.gaze(cell[c].expression, for: c) ?? .zero
                let mapped = LipSyncMapping.map(expected.mouth, drive: cell[c].talkOpen.map { MouthDrive(talkOpen: $0) },
                                                talk: cell[c].talkOpen == nil ? 0 : 1, character: c)
                near(face.features.mouth.open, mapped.open, 1e-9, "\(cell.name) \(c) mouth")
                near(face.features.eyes.right.closed, expected.eyes.right.closed, 1e-9, "\(cell.name) \(c) eyes")
                near(face.features.gaze, expected.gaze, 1e-9, "\(cell.name) \(c) gaze")
            }
        }
        // The two talking stills: mouths open to ô 0.8.
        let af = StageSimulation.snapshot(pose: .angelTalking, metrics: m, talkOpen: 0.8).frame
        let spokenAngel = LipSyncMapping.map(ExpressionLibrary.targets(.talking, for: .angel).mouth,
                                             drive: MouthDrive(talkOpen: 0.8), talk: 1, character: .angel)
        near(af.picture.faces.angel.features.mouth.open, spokenAngel.open, 1e-9, "the speaking angel's mouth")
        near(af.picture.faces.devil.features.mouth.corner, -6, 1e-9, "squished, the devil frowns")
        // Squished, the volume his squash leaves over puffs his cheeks: his blush widens and
        // deepens (there are no cheek domes); the angel's blush keeps its own rule.
        let squished = af.picture.faces.devil
        check(squished.squeeze > 0.5 && squished.puff > 0.5, "squished, his cheeks puff")
        let restBlush = BlushShape.radii(devil), puffedBlush = BlushShape.radii(squished)
        near(restBlush, DevilGeometry.blush.size / 2, 1e-9, "the free devil's blush keeps its drawn size")
        check(puffedBlush.x > 1.3 * restBlush.x && puffedBlush.y > restBlush.y,
              "squished, his blush widens (\(puffedBlush) vs \(restBlush))")
        check(BlushShape.strength(squished) > squished.features.accessories.blush, "squished, his blush deepens")
        let freeAngel = af.picture.faces.angel
        near(BlushShape.radii(freeAngel), AngelGeometry.blush.size / 2 * (freeAngel.features.accessories.blushSize
                 * (1 + 0.25 * freeAngel.squeeze)), 1e-9, "the angel's blush ignores puff")
        near(BlushShape.strength(freeAngel), freeAngel.features.accessories.blush, 1e-12, "the angel's blush strength")
        let df = StageSimulation.snapshot(pose: .devilTalking, metrics: m, talkOpen: 0.8).frame
        let spokenDevil = LipSyncMapping.map(ExpressionLibrary.targets(.talking, for: .devil).mouth,
                                             drive: MouthDrive(talkOpen: 0.8), talk: 1, character: .devil)
        near(df.picture.faces.devil.features.mouth.open, spokenDevil.open, 1e-9, "the speaking devil's mouth")
        check(DevilMouthShape.fang(spokenDevil) != nil && DevilMouthShape.tongue(spokenDevil) != nil,
              "the speaking devil shows his fang and tongue")
        near(df.picture.faces.angel.features.eyes.left.sclera, 1, 1e-9, "squished, the angel shows her eye whites")
        check(df.picture.faces.devil.features.gaze.y < -0.5, "the speaking devil looks up at the angel")
    }

    // MARK: Squash and volume

    static func squashAndVolume() {
        let m = StageMetrics.iPhone18Pro
        var scripts: [(String, StageScript)] = [("preview", StageScript.previewDuo(seed: 3))]
        var devilFirst = StageScript(duration: 12)
        devilFirst.at(0.3) { $0.active = true }
        devilFirst.at(1.0) { $0.floor = .devil; $0.addressed = [.angel]; $0.captions[.devil] = "Oh, please, Angel!"; $0.talking = [.devil] }
        devilFirst.speak(.devil, from: 1.0, to: 3.5, seed: 9)
        devilFirst.at(3.5) { $0.talking = [] }
        devilFirst.at(4.0) { $0.floor = .angel; $0.addressed = []; $0.captions[.angel] = "Haha, nice try!"; $0.talking = [.angel] }
        devilFirst.speak(.angel, from: 4.0, to: 7.0, seed: 10)
        devilFirst.at(7.0) { $0.talking = [] }
        devilFirst.at(7.4) { $0.floor = .devil; $0.captions[.devil] = "Whatever."; $0.talking = [.devil] }
        devilFirst.speak(.devil, from: 7.4, to: 8.4, seed: 11)
        devilFirst.at(8.0) { $0.interruptions = 1; $0.floor = nil; $0.talking = [] }
        scripts.append(("devil first", devilFirst))
        var frames = 0
        for (name, script) in scripts {
            var sim = StageSimulation(seed: 5, metrics: m)
            var next = 0
            for k in 1...Int(script.duration * 240) {
                let time = Double(k) / 240
                while next < script.steps.count, script.steps[next].time <= time {
                    sim.receive(script.steps[next].inputs, at: script.steps[next].time)
                    next += 1
                }
                let frame = sim.advance(to: time, mouths: script)
                frames += 1
                for c in DuoCharacter.allCases {
                    let pose = frame.picture.faces[c]
                    let label = "\(name) \(c) at \(time) s"
                    near(pose.sx, pow(pose.sy, -0.4), 1e-12, "\(label): volume rule")
                    near(pose.netVertical(.eyes), c == .angel ? 1 : pose.sy.squareRoot(), 1e-9, "\(label): eye scale")
                    let listener = sim.preset.listener == c && sim.faces[c].contact != nil
                    let speaker = sim.stageFloor == c
                    if listener {
                        let range = c == .devil ? 0.70...1.0 : 0.86...1.0
                        check(range.contains(pose.sy), "\(label): listener sy \(pose.sy) within \(range)")
                    } else if speaker {
                        let range = c == .devil ? 0.70...1.18 : 0.86...1.12
                        check(range.contains(pose.sy), "\(label): speaker sy \(pose.sy) within \(range)")
                    }
                    for v in [pose.halo.center.x, pose.halo.center.y, pose.halo.rotation, pose.wings.left,
                              pose.horns.right, pose.puff] {
                        check(v.isFinite, "\(label): accessories are finite")
                    }
                    if c == .angel {
                        let top = pose.halo.center.y - AngelGeometry.haloOuterSize.y / 2 * pose.scale * pose.halo.squash
                        check(top >= m.bandTop - 6 - 1e-9, "\(label): the halo top \(top) stays below the band top − 6")
                    }
                }
            }
        }
        check(frames > 9000, "squash checks ran over every substep")
    }

    // MARK: Lip sync

    static func lipSync() {
        for c in DuoCharacter.allCases {
            let e = ExpressionLibrary.targets(.talking, for: c).mouth
            var previous = -Double.infinity
            for k in 0...100 {
                let o = Double(k) / 100
                let open = LipSyncMapping.map(e, drive: MouthDrive(openness: o, width: 0.5, rounding: 0.1), talk: 1,
                                              character: c).open
                check(open >= previous, "\(c): open height is monotonic in openness")
                previous = open
            }
            let rest = LipSyncMapping.map(e, drive: .rest, talk: 1, character: c)
            check(rest.open < 1.5, "\(c): the rest pose is nearly closed (\(rest.open))")
            if c == .angel {
                check(AngelMouthShape.depth(rest) == AngelGeometry.mouthLine && AngelMouthShape.tongue(rest) == nil,
                      "angel: the rest pose is her closed smile")
            } else {
                check(DevilMouthShape.depth(rest) == DevilGeometry.mouthLine && DevilMouthShape.tongue(rest) == nil
                          && DevilMouthShape.bowl(rest) == 0 && rest.corner > 0,
                      "devil: the rest pose is his closed smile")
                // The fang hangs under the closed line, below its bottom edge.
                let p = DevilMouthShape.points(rest), tooth = DevilMouthShape.fang(rest)!.bounds
                let x = rest.fangX * rest.width / 2 + rest.shiftX
                check(tooth.max.y > InkMouth.bottomY(p, at: x) + 0.6 * DevilGeometry.fangBelowLine,
                      "devil: the fang hangs below his closed smile")
                // His fang smirks: a bold ink outline about as heavy as the line, mostly outside
                // the white, whose sides carry on up into the line, so the fang hangs from it.
                near(DevilGeometry.fangOutline, DevilGeometry.mouthLine, 0.5, "devil: the fang's outline is as heavy as his line")
                check(DevilGeometry.fangOutline - DevilGeometry.fangEdge / 2 >= 2.5, "devil: the fang's outline is bold outside the white")
                let corners = DevilMouthShape.fangOutline(rest)!.points.prefix(2)
                check(corners.allSatisfy { $0.y < InkMouth.bottomY(p, at: $0.x) - 2 && $0.y > InkMouth.topY(p, at: $0.x) - 2 },
                      "devil: the fang's outline rises into his closed line")
            }
            let closure = LipSyncMapping.map(e, drive: MouthDrive(openness: 0.02, width: 0.3, rounding: 0.1), talk: 1,
                                             character: c)
            near(closure.open, 0, 0, "\(c): a lip closure closes the mouth")
            let wide = LipSyncMapping.map(e, drive: MouthDrive(talkOpen: 1), talk: 1, character: c)
            near(wide.open, LipSyncMapping.maxOpen(c), 1e-9, "\(c): ô = 1 opens to hMax")
            for k in 0..<25 {
                let o = Double(k) / 100
                let m = LipSyncMapping.map(e, drive: MouthDrive(talkOpen: o), talk: 1, character: c)
                if c == .angel {
                    check(AngelMouthShape.depth(m) >= AngelGeometry.tongueGrowth.from || AngelMouthShape.tongue(m) == nil,
                          "angel: no tongue in a barely parted mouth")
                } else {
                    check(DevilMouthShape.tongue(m) == nil, "devil: no tongue below ô 0.25")
                }
            }
            // The expression survives speech.
            for expression in [FaceExpression.talking, .happy, .content, .grumpy] {
                let held = ExpressionLibrary.targets(expression, for: c).mouth
                let spoken = LipSyncMapping.map(held, drive: MouthDrive(talkOpen: 0.9), talk: 1, character: c)
                check(spoken.skew == held.skew && spoken.fang == held.fang && spoken.fangX == held.fangX
                          && spoken.shiftX == held.shiftX,
                      "\(c) \(expression): skew and fang are kept while speaking")
                check(spoken.corner * held.corner >= 0 && abs(spoken.corner) >= abs(held.corner) / 2 - 1e-12,
                      "\(c) \(expression): the corner is kept while speaking")
            }
            // No lag: τ = 0 is the expression, τ = 1 follows the drive exactly.
            check(LipSyncMapping.map(e, drive: MouthDrive(talkOpen: 0.7), talk: 0, character: c).open == e.open,
                  "\(c): silent mouths hold the expression")
        }

        // The angel's mouth states (`AngelMouthSheet`): each stays about the open smile's size, the
        // visemes take their own shapes, and the outline is continuous, so speech never jumps in
        // size.
        let angelMouths = Dictionary(uniqueKeysWithValues: AngelMouthSheet.states.map { ($0.name, $0.mouth) })
        check(angelMouths.count == 12, "the angel has 12 mouth states")
        for (name, mouth) in angelMouths {
            check(mouth.width >= 14 && mouth.width <= 66 && AngelMouthShape.depth(mouth) <= 44,
                  "angel \(name): about the open smile's size")
        }
        let a = angelMouths["Talking A"]!, eMouth = angelMouths["Talking E"]!
        let o = angelMouths["Talking O"]!, u = angelMouths["Talking U"]!
        let mb = angelMouths["Talking M/B"]!
        check(eMouth.width > a.width && eMouth.open < a.open, "angel: an E is wider and shallower than an A")
        check(o.round > 0.9 && o.open > o.width, "angel: an O is a tall oval")
        check(u.width > o.width && u.open < o.open && AngelMouthShape.tongue(u) != nil,
              "angel: a U is smaller than an O and mostly tongue")
        check(mb.round < 0.05 && AngelMouthShape.tongue(mb) == nil && AngelMouthShape.bowl(mb) > 0.5,
              "angel: an M or B is a pill with no tongue")
        check(angelMouths["Concerned"]!.corner < 0 && AngelMouthShape.bowl(angelMouths["Concerned"]!) == 0,
              "angel: concerned frowns")
        var lastPoints = AngelMouthShape.points(AngelMouthSheet.states[0].mouth)
        for k in 1...200 {
            let mouth = LipSyncMapping.map(ExpressionLibrary.targets(.talking, for: .angel).mouth,
                                           drive: MouthDrive(openness: 0.14 + 0.7 * Double(k) / 200, width: 0.5, rounding: 0.6),
                                           talk: 1, character: .angel)
            let points = AngelMouthShape.points(mouth)
            if k > 1 {
                check(zip(points, lastPoints).allSatisfy { ($0 - $1).length < 2.5 }, "angel: the outline morphs continuously")
            }
            lastPoints = points
        }

        // The devil's mouth states, likewise, with his fang: near the right corner of every open
        // mouth, under the raised end of a smirk, retracted into the lip of an O or U.
        let devilMouths = Dictionary(uniqueKeysWithValues: DevilMouthSheet.states.map { ($0.name, $0.mouth) })
        check(DevilMouthSheet.states.count == 14 && devilMouths.count == 14, "the devil has 14 mouth states")
        for (name, mouth) in devilMouths {
            check(mouth.width >= 20 && mouth.width <= 90 && DevilMouthShape.depth(mouth) <= 40,
                  "devil \(name): about the open grin's size")
        }
        func thin(_ m: MouthParams) -> Bool { DevilMouthShape.bowl(m) == 0 && m.round == 0 }
        func tooth(_ name: String) -> Bool { DevilMouthShape.fang(devilMouths[name]!) != nil }
        func tongue(_ name: String) -> Bool { DevilMouthShape.tongue(devilMouths[name]!) != nil }
        let closed = devilMouths["Closed (Neutral)"]!
        check(thin(closed) && closed.corner > 0 && tooth("Closed (Neutral)") && !tongue("Closed (Neutral)"),
              "devil: the closed mouth is a smile with the fang")
        let smirkL = devilMouths["Smirk (Left)"]!, smirkR = devilMouths["Smirk (Right)"]!
        check(thin(smirkL) && thin(smirkR) && smirkL.skew < -4 && smirkR.skew > 4 && smirkL.fangX < 0 && smirkR.fangX > 0
                  && tooth("Smirk (Left)") && tooth("Smirk (Right)"),
              "devil: the smirks rise to opposite sides with the fang under the raised end")
        let small = devilMouths["Open (Small)"]!, medium = devilMouths["Open (Medium)"]!, large = devilMouths["Open (Large)"]!
        check(small.open < medium.open && medium.open < large.open && small.width < large.width,
              "devil: the open mouths grow small to large")
        check(!tongue("Open (Small)") && tongue("Open (Medium)") && tongue("Open (Large)")
                  && ["Open (Small)", "Open (Medium)", "Open (Large)"].allSatisfy(tooth),
              "devil: open mouths show the fang, and a tongue once past small")
        let devilA = devilMouths["Talking A"]!, devilE = devilMouths["Talking E"]!, devilO = devilMouths["Talking O"]!
        let devilU = devilMouths["Talking U"]!, generic = devilMouths["Talking"]!
        check(devilE.width > devilA.width && devilE.open < devilA.open && tongue("Talking E") && tooth("Talking E"),
              "devil: an E is a wide, shallow D with fang and tongue")
        check(devilO.round > 0.9 && abs(devilO.open - devilO.width) < 6 && tongue("Talking O") && !tooth("Talking O"),
              "devil: an O is small and round with coral inside")
        check(devilU.width > devilO.width && devilU.open < devilO.open && devilU.width > 2.5 * devilU.open
                  && devilU.round > 0.5 && tongue("Talking U") && !tooth("Talking U"),
              "devil: a U is a slim rounded slot showing coral")
        check(DevilMouthShape.bowl(generic) > 0.99 && tongue("Talking") && tooth("Talking") && tooth("Talking A"),
              "devil: talking is a D with fang and tongue")
        let laugh = devilMouths["Laughing"]!
        check(devilMouths.values.allSatisfy { DevilMouthShape.depth($0) <= laugh.open } && devilMouths.values.allSatisfy {
            $0.width <= laugh.width || $0.open < laugh.open / 2
        } && tongue("Laughing") && tooth("Laughing"), "devil: laughing is his biggest D")
        let grimace = devilMouths["Grimace"]!, sad = devilMouths["Sad"]!
        check(thin(grimace) && abs(grimace.skew) >= 6 && grimace.width >= 60 && tooth("Grimace"),
              "devil: a grimace is a long slanted line with the fang")
        check(thin(sad) && sad.corner < 0 && !tooth("Sad"), "devil: sad frowns, fangless")
        // Every fang's outline reaches up into the mouth's ink, and the fang itself lies under
        // the lip, so the clip that keeps the outline there (`belowTopEdge`) never cuts it.
        for (name, mouth) in devilMouths {
            guard let fang = DevilMouthShape.fang(mouth), let outline = DevilMouthShape.fangOutline(mouth) else { continue }
            let p = DevilMouthShape.points(mouth)
            check(outline.points.prefix(2).allSatisfy { $0.y < InkMouth.bottomY(p, at: $0.x) },
                  "devil \(name): the fang's outline joins the mouth's ink")
            let lip = sampled(DevilMouthShape.belowTopEdge(mouth))
            check(sampled(fang).allSatisfy { $0.y > InkMouth.topY(p, at: $0.x) && inside($0 + Vec2(0, 0.01), lip) },
                  "devil \(name): the fang lies under the lip")
        }
        // Lip sync morphs the outline and the fang continuously, from a closure to wide open with
        // the lips rounding, so the shape never jumps.
        let held = ExpressionLibrary.targets(.talking, for: .devil).mouth
        var last: MouthParams?
        for k in 0...200 {
            let u = Double(k) / 200
            let drive = MouthDrive(openness: 0.02 + 0.8 * u, width: 0.3 + 0.6 * u, rounding: 0.8 * u * u)
            let mouth = LipSyncMapping.map(held, drive: drive, talk: 1, character: .devil)
            if let last {
                check(zip(DevilMouthShape.points(mouth), DevilMouthShape.points(last)).allSatisfy { ($0 - $1).length < 2.5 },
                      "devil: the outline morphs continuously")
                let fang = DevilMouthShape.fang(mouth)?.points ?? [], lastFang = DevilMouthShape.fang(last)?.points ?? []
                if fang.count == lastFang.count {
                    check(zip(fang, lastFang).allSatisfy { ($0 - $1).length < 2.5 }, "devil: the fang moves continuously")
                } else {
                    let scale = DevilMouthShape.fangScale(fang.isEmpty ? last : mouth)
                    check(scale < 0.05, "devil: the fang only appears or goes at no size (\(scale))")
                }
            }
            last = mouth
        }

        // Each voice moves only its own mouth.
        let m = StageMetrics.iPhone18Pro
        let script = StageScript.previewDuo(seed: 2)
        func run(_ mouths: OnlyMouths, mode: StageMode = StageMode()) -> [StageFrame] {
            var sim = StageSimulation(seed: 4, metrics: m, mode: mode)
            var next = 0
            var frames: [StageFrame] = []
            for k in 1...(24 * 60) {
                let time = Double(k) / 60
                while next < script.steps.count, script.steps[next].time <= time {
                    sim.receive(script.steps[next].inputs, at: script.steps[next].time)
                    next += 1
                }
                frames.append(sim.advance(to: time, mouths: mouths))
            }
            return frames
        }
        let none = run(OnlyMouths(script: script, characters: []))
        let angelOnly = run(OnlyMouths(script: script, characters: [.angel]))
        let devilOnly = run(OnlyMouths(script: script, characters: [.devil]))
        var angelMoved = false, devilMoved = false
        for (k, base) in none.enumerated() {
            check(angelOnly[k].picture.faces.devil.features.mouth == base.picture.faces.devil.features.mouth,
                  "the angel's voice leaves the devil's mouth alone at frame \(k)")
            check(devilOnly[k].picture.faces.angel.features.mouth == base.picture.faces.angel.features.mouth,
                  "the devil's voice leaves the angel's mouth alone at frame \(k)")
            angelMoved = angelMoved || angelOnly[k].picture.faces.angel.features.mouth != base.picture.faces.angel.features.mouth
            devilMoved = devilMoved || devilOnly[k].picture.faces.devil.features.mouth != base.picture.faces.devil.features.mouth
        }
        check(angelMoved && devilMoved, "each voice moves its own mouth")

        // Under Reduce Motion the mouth follows the mapping; head, brows and seam ignore it.
        let still = StageMode(reduceMotion: true)
        let quiet = run(OnlyMouths(script: script, characters: []), mode: still)
        let spoken = run(OnlyMouths(script: script, characters: [.angel, .devil]), mode: still)
        var followed = 0
        for (k, base) in quiet.enumerated() {
            let a = spoken[k].picture, b = base.picture
            check(a.seam == b.seam, "Reduce Motion: the seam ignores speech at frame \(k)")
            for c in DuoCharacter.allCases {
                check(a.faces[c].anchor == b.faces[c].anchor && a.faces[c].scale == b.faces[c].scale
                          && a.faces[c].tilt == b.faces[c].tilt && a.faces[c].features.brows == b.faces[c].features.brows,
                      "Reduce Motion: \(c)'s head and brows ignore speech at frame \(k)")
            }
            let time = Double(k + 1) / 60
            if let speaker = script.inputs(at: time - 1e-6).floor,
               a.faces[speaker].features.mouth != b.faces[speaker].features.mouth {
                followed += 1
            }
        }
        check(followed > 300, "Reduce Motion: the mouths still follow speech (\(followed) frames)")
    }
}

// MARK: - Behaviour

extension StageRigChecks {
    /// Runs `script` at 120 Hz with `mouths`, collecting events; `each` sees every frame.
    private static func behave(_ sim: inout StageSimulation, _ script: StageScript, until end: Double,
                               mouths: (any MouthSource)? = nil,
                               each: (Double, inout StageSimulation) -> Void = { _, _ in }) -> [StageEventRecord] {
        var next = 0
        var events: [StageEventRecord] = []
        for k in 1...Int((end * 120).rounded()) {
            let time = Double(k) / 120
            while next < script.steps.count, script.steps[next].time <= time {
                sim.receive(script.steps[next].inputs, at: script.steps[next].time)
                next += 1
            }
            if let mouths {
                sim.advance(to: time, mouths: AnyMouths(base: mouths))
            } else {
                sim.advance(to: time, mouths: script)
            }
            events += sim.drainEvents()
            each(time, &sim)
        }
        return events
    }

    private static func gestures(_ events: [StageEventRecord], _ c: DuoCharacter, _ gesture: StageGesture) -> [Double] {
        events.filter { $0.event == .gesture(c, gesture) }.map(\.time)
    }

    /// An angel line from 0.5 s to 6.5 s, for `addressed`, with `caption`.
    private static func angelLine(_ caption: String, addressed: Set<DuoCharacter> = []) -> StageScript {
        var script = StageScript(duration: 8)
        script.at(0.2) { $0.active = true }
        script.at(0.5) {
            $0.floor = .angel
            $0.addressed = addressed
            $0.captions[.angel] = caption
            $0.talking = [.angel]
        }
        script.speak(.angel, from: 0.5, to: 6.5, seed: 5)
        script.at(6.5) { $0.talking = [] }
        return script
    }

    // MARK: Behaviour

    static func behaviour() {
        let m = StageMetrics.iPhone18Pro

        // The devil rolls his eyes during an angel line to the player, and never while addressed.
        for seed in UInt64(1)...6 {
            var sim = StageSimulation(seed: seed, metrics: m)
            let rolls = gestures(behave(&sim, angelLine("Go to the gym tonight."), until: 6.5), .devil, .eyeRoll)
            check(rolls.contains { $0 >= 0.5 + 1.2 && $0 <= 6.5 }, "seed \(seed): the devil rolls his eyes (\(rolls))")
            var addressed = StageSimulation(seed: seed, metrics: m)
            let glare = behave(&addressed, angelLine("Go to the gym tonight.", addressed: [.devil]), until: 6.5)
            check(gestures(glare, .devil, .eyeRoll).isEmpty, "seed \(seed): no eye roll while the devil is addressed")
            check(addressed.roles.devil == .squished(addressed: true), "seed \(seed): the addressed devil glares")
        }
        // The angel sighs while squished by a long devil line.
        var sighs = 0
        for seed in UInt64(1)...6 {
            var sim = StageSimulation(seed: seed, metrics: m)
            var script = StageScript(duration: 14)
            script.at(0.2) { $0.active = true }
            script.at(0.5) {
                $0.floor = .devil
                $0.captions[.devil] = "The sofa is so much comfier."
                $0.talking = [.devil]
            }
            script.speak(.devil, from: 0.5, to: 13.5, seed: 9)
            sighs += gestures(behave(&sim, script, until: 13.5), .angel, .sigh).count
        }
        check(sighs >= 6, "the squished angel sighs (\(sighs) sighs over six 13-s lines)")

        // Speaking to the other character, the speaker looks down (angel) or up (devil) at them.
        for (speaker, addressee) in [(DuoCharacter.angel, DuoCharacter.devil), (.devil, .angel)] {
            var sim = StageSimulation(seed: 3, metrics: m)
            var inputs = StageInputs(active: true)
            inputs.floor = speaker
            inputs.addressed = [addressee]
            sim.receive(inputs, at: 0.1)
            sim.advance(to: 0.2, mouths: SilentMouths())
            sim.settleForStill()
            let gaze = sim.frame.picture.faces[speaker].features.gaze
            check(speaker == .angel ? gaze.y > 0.5 : gaze.y < -0.5, "\(speaker) looks at \(addressee): \(gaze)")
        }

        // A laugh cue starts laughing on the caption's substep; no blink starts while the eyes are closed.
        var laugh = StageSimulation(seed: 4, metrics: m)
        var laughing = StageInputs(active: true)
        laughing.floor = .angel
        laughing.talking = [.angel]
        laughing.captions[.angel] = "Go to the gym tonight."
        laugh.receive(laughing, at: 0.5)
        for k in 1...180 { laugh.advance(to: Double(k) / 120, mouths: ConstantMouths()) }
        laughing.captions[.angel] = "Haha, nice try!"
        let cue = 1.501
        laugh.receive(laughing, at: cue)
        // The first substep boundary at or after the caption.
        laugh.advance(to: (cue * 240).rounded(.up) / 240 + 1e-9, mouths: ConstantMouths())
        check(laugh.faces.angel.directive.effectiveExpression == .laughing, "the laugh cue starts laughing at once")
        _ = laugh.drainEvents()
        var t = cue
        var blinks = 0
        while t < cue + 6 {
            t += 1.0 / 120
            laugh.advance(to: t, mouths: ConstantMouths())
            blinks += laugh.drainEvents().filter { $0.event == .gesture(.angel, .blink) }.count
        }
        check(blinks == 0, "no blink while laughing with closed eyes (\(blinks))")

        // A question tilts the speaker's head by at least 6°.
        for c in DuoCharacter.allCases {
            var sim = StageSimulation(seed: 5, metrics: m)
            var inputs = StageInputs(active: true)
            inputs.floor = c
            inputs.talking = [c]
            inputs.captions[c] = "Deal?"
            sim.receive(inputs, at: 0.5)
            var time = 0.5
            while time < 2.5 {
                time += 1.0 / 120
                sim.advance(to: time, mouths: ConstantMouths())
            }
            let tilt = abs(sim.faces[c].tilt.value) * 180 / Double.pi
            check(tilt >= 6, "\(c) tilts \(tilt)° for a question")
        }

        // The thinking gaze searches up, alternating sides.
        var thinker = StageSimulation(seed: 6, metrics: m)
        var writing = StageInputs(active: true)
        writing.thinking = [.angel]
        thinker.receive(writing, at: 0.2)
        var sides = Set<Bool>()
        var time = 0.2
        while time < 6 {
            time += 1.0 / 120
            thinker.advance(to: time, mouths: SilentMouths())
            let gaze = thinker.faces.angel.targets.gaze
            check(gaze.y < -0.5, "the thinking gaze looks up (\(gaze) at \(time) s)")
            sides.insert(gaze.x > 0)
        }
        check(sides.count == 2, "the thinking gaze alternates sides")

        // Interruptions: barge-in (captions cleared in the same update) and a cancelled request
        // (captions kept) both startle, with no verdict; the exchange ending, with the floor and
        // the addressees cleared together after the audio, or the floor clearing later, holds
        // 0.25 s and releases.
        enum Ending { case bargeIn, cancelled, endedTogether, endedLater }
        for ending in [Ending.bargeIn, .cancelled, .endedTogether, .endedLater] {
            var sim = StageSimulation(seed: 7, metrics: m)
            var script = StageScript(duration: 6)
            script.at(0.2) { $0.active = true }
            script.at(0.5) {
                $0.floor = .devil
                $0.addressed = [.angel]
                $0.captions[.devil] = "Oh, please, Angel!"
                $0.talking = [.devil]
            }
            script.speak(.devil, from: 0.5, to: 2.5, seed: 3)
            let end = 2.5
            switch ending {
            case .bargeIn:
                script.at(end) {
                    $0.interruptions += 1
                    $0.floor = nil
                    $0.addressed = []
                    $0.captions = [:]
                    $0.talking = []
                }
            case .cancelled:
                script.at(end) {
                    $0.interruptions += 1
                    $0.floor = nil
                    $0.talking = []
                }
            case .endedTogether:
                script.at(end) { $0.talking = [] }
                script.at(end + 0.01) {
                    $0.floor = nil
                    $0.addressed = []
                }
            case .endedLater:
                script.at(end) { $0.talking = [] }
                script.at(end + 1.2) { $0.floor = nil }
            }
            var released: Double?
            var snapped = false
            let events = behave(&sim, script, until: 6) { _, sim in
                if released == nil, case .release(let start) = sim.seam.motion { released = start }
                if case .interrupt = sim.seam.motion { snapped = true }
            }
            let interrupted = events.filter { $0.event == .interrupted }.map(\.time)
            let ended = events.filter { $0.event == .exchangeEnded }.map(\.time)
            switch ending {
            case .bargeIn, .cancelled:
                check(interrupted.count == 1 && ended.isEmpty, "\(ending): one interruption and no verdict")
                check(events.contains { $0.event == .floorChanged(from: .devil, to: nil) }, "\(ending): the floor ends")
                check(released == nil && snapped, "\(ending): the seam snaps back on the interrupt springs, no hold")
            case .endedTogether, .endedLater:
                check(interrupted.isEmpty && ended.count == 1, "\(ending): one exchange end and no interruption")
                let floorEnd = ending == .endedTogether ? end + 0.01 : end + 1.2
                near(ended[0], floorEnd + StageSimulation.debounce, 1.0 / 240 + 1e-9, "\(ending): the exchange ends")
                near(released ?? -1, ended[0] + StageSimulation.releaseHold, 1.0 / 240 + 1e-9,
                     "\(ending): the release follows its hold")
            }
        }

        // Reduce Motion: the preview's roles, with no gestures at all.
        let preview = StageScript.previewDuo(seed: 1)
        var still = StageSimulation(seed: 7, metrics: m, mode: StageMode(reduceMotion: true))
        var moving = StageSimulation(seed: 7, metrics: m)
        var stillRoles: [PerCharacter<CharacterRole>] = [], movingRoles: [PerCharacter<CharacterRole>] = []
        let quiet = behave(&still, preview, until: 30) { time, sim in
            if Int((time * 120).rounded()) % 30 == 0 { stillRoles.append(sim.roles) }
        }
        let lively = behave(&moving, preview, until: 30) { time, sim in
            if Int((time * 120).rounded()) % 30 == 0 { movingRoles.append(sim.roles) }
        }
        check(!quiet.contains { if case .gesture = $0.event { true } else { false } },
              "no blinks, drifts, glances, rolls or reactions under Reduce Motion")
        check(lively.contains { if case .gesture(_, .glance) = $0.event { true } else { false } }
                  && lively.contains { if case .gesture(_, .drift) = $0.event { true } else { false } },
              "glances and drift without Reduce Motion")
        check(stillRoles == movingRoles, "Reduce Motion keeps the same held expressions")
    }
}

/// A type-erased mouth source.
private struct AnyMouths: MouthSource {
    var base: any MouthSource

    func drive(_ character: DuoCharacter, at simTime: Double) -> MouthDrive? { base.drive(character, at: simTime) }
}

// MARK: - Stress and smoothness

/// A bubble as the caption layer draws it: shown at its slot, then gliding to a changed slot on
/// the bubble spring.
private struct BubbleGlide {
    var edges: [RigSpring]

    init(_ rect: StageRect) {
        edges = [rect.minX, rect.minY, rect.maxX, rect.maxY].map { RigSpring($0, spec: .bubble, range: 100) }
    }

    mutating func glide(to rect: StageRect, for seconds: Double) {
        for (i, v) in [rect.minX, rect.minY, rect.maxX, rect.maxY].enumerated() { edges[i].retarget(v) }
        for _ in 0..<Int((seconds / SpringSpec.step).rounded()) {
            for i in edges.indices { edges[i].step() }
        }
    }

    var rect: StageRect {
        StageRect(minX: edges[0].value, minY: edges[1].value, maxX: edges[2].value, maxY: edges[3].value)
    }
}

/// A frame's mouths, sampled once at its presentation time, as the app's `FrameMouths` does.
private struct FrameDrives: MouthSource {
    var drives: [DuoCharacter: MouthDrive] = [:]

    func drive(_ character: DuoCharacter, at simTime: Double) -> MouthDrive? { drives[character] }
}

extension StageRigChecks {
    /// Plays `script` as the app does: frames at `hz`, each step delivered at its time, each
    /// frame's mouths sampled once, a frame ahead, and the bubbles' and the pill's heights
    /// measured as their text changes; with `intro`, the launch intro begins at 0. `each` sees
    /// every frame.
    @discardableResult
    private static func perform(_ script: StageScript, seed: UInt64, metrics m: StageMetrics = .iPhone18Pro,
                                mode: StageMode = StageMode(), hz: Double = 120, until end: Double? = nil,
                                intro: Bool = false,
                                each: (Double, StageFrame, inout StageSimulation) -> Void) -> StageSimulation {
        var sim = StageSimulation(seed: seed, metrics: m, mode: mode)
        var heights: [DuoCharacter: Double] = [:], pill = 0.0
        sim.update(metrics: m, bubbleHeights: heights, pillHeight: pill)
        sim.settleAll()
        if intro { sim.beginIntro(at: 0) }
        var next = 0
        let frames = Int(((end ?? script.duration) * hz).rounded())
        for k in 1...frames {
            let time = Double(k) / hz
            while next < script.steps.count, script.steps[next].time <= time {
                let inputs = script.steps[next].inputs
                sim.receive(inputs, at: script.steps[next].time)
                next += 1
                var measured = heights
                for c in DuoCharacter.allCases {
                    if inputs.thinking.contains(c), inputs.floor == nil {
                        measured[c] = StageLayout.layoutHeight(measured: 44, previous: heights[c], kindChanged: true)
                    } else if let text = inputs.captions[c] {
                        let lines = min(4, max(1, (Double(text.count) / 28).rounded(.up)))
                        measured[c] = StageLayout.layoutHeight(measured: 24 + 22 * lines, previous: heights[c])
                    }
                }
                let measuredPill = inputs.userText.map { $0.count > 34 ? 68.0 : 46.0 } ?? pill
                if measured != heights || measuredPill != pill {
                    heights = measured
                    pill = measuredPill
                    sim.update(metrics: m, bubbleHeights: heights, pillHeight: pill)
                }
            }
            var mouths = FrameDrives()
            for c in sim.inputs.talking { mouths.drives[c] = script.drive(c, at: time + 1 / hz) ?? .rest }
            let frame = sim.advance(to: time, mouths: mouths, userLevel: script.userLevel(at: time))
            each(time, frame, &sim)
        }
        return sim
    }

    /// Head landmarks as drawn (stage points): the eye midpoint, both eye centres, the mouth's
    /// anchor, and the angel's halo.
    private static func landmarks(_ pose: FacePose) -> [Vec2] {
        let d = pose.drawn
        let eyes = pose.character == .angel ? AngelGeometry.eyeCenter : DevilGeometry.eyeCenter
        let mouth = pose.character == .angel ? AngelGeometry.mouthAnchor : DevilGeometry.mouthAnchor
        var points = [d.point(.zero), d.point(eyes.sided(-1)), d.point(eyes), d.point(mouth)]
        if pose.character == .angel { points.append(pose.halo.center) }
        return points
    }

    /// A seeded random conversation: lines of one to three sentences with every cue, handovers
    /// both ways after short and long gaps, the human's questions (some over a reply), writers,
    /// cancelled lines and New conversation, ending with New conversation 3 s before the end.
    private static func randomConversation(seed: UInt64, duration: Double = 24) -> StageScript {
        var random = SplitMix64(seed: seed, stream: .stage)
        let sentences = ["Go to the gym tonight.", "Haha, nice try!", "Oh, please, Angel!", "Wow, that is amazing!",
                         "Deal?", "Treat yourself, just this once!", "You will feel wonderful.", "Devil, stop it.", "No.",
                         "Pottery is calm, creative and a lovely way to meet kind people who like muddy hands.",
                         "Hehe, I knew it.", "Why not?"]
        var c = StageConversation(duration: duration)
        c.activate(at: random.uniform(in: 0.1...0.6))
        var t = random.uniform(in: 0.7...1.5)
        var speaker: DuoCharacter = random.chance(0.5) ? .angel : .devil
        // When the last line started: questions and cancels may cut into it.
        var lineStart = t
        func cutIn() -> Double { random.chance(0.4) ? max(lineStart + 0.2, t - random.uniform(in: 0.2...1.5)) : t }
        while t < duration - 4 {
            let roll = random.uniform()
            if roll < 0.15 {
                let to: [Set<DuoCharacter>] = [[], [.angel], [.devil]]
                let start = cutIn()
                t = c.ask("Should I go out tonight?", at: start, addressed: to[Int(random.uniform() * 3)],
                          interrupting: start < t || random.chance(0.3)) + random.uniform(in: 0.2...1.5)
                if random.chance(0.7) { c.write(random.chance(0.5) ? .angel : .devil, at: t - 0.1) }
            } else if roll < 0.2 {
                c.cancel(at: cutIn())
                t += random.uniform(in: 0.3...1.5)
            } else if roll < 0.23 {
                c.newConversation(at: t)
                t += random.uniform(in: 0.5...2)
                c.activate(at: t)
                t += 0.3
            } else {
                let count = 1 + Int(random.uniform() * 3)
                let lines = (0..<count).map { _ in sentences[Int(random.uniform() * Double(sentences.count))] }
                let other: DuoCharacter = speaker == .angel ? .devil : .angel
                lineStart = t
                let end = c.say(speaker, lines, at: t, to: random.chance(0.4) ? [other] : [],
                                next: random.chance(0.6) ? other : nil)
                if random.chance(0.25) { c.endExchange(at: end - 0.2) }
                t = end + random.uniform(in: 0.05...2.5)
                if random.chance(0.7) { speaker = other }
            }
        }
        c.newConversation(at: duration - 3)
        return c.script(seed: seed)
    }

    /// The eyes, brows and mouth of `pose` as drawn: the stage rect around their box's corners.
    private static func featureRect(_ pose: FacePose) -> StageRect {
        let drawn = pose.drawn, box = FaceBoxes.features(pose.character)
        let corners = [box.min, Vec2(box.max.x, box.min.y), Vec2(box.min.x, box.max.y), box.max].map { drawn.point($0) }
        return StageRect(minX: corners.map(\.x).min()!, minY: corners.map(\.y).min()!,
                         maxX: corners.map(\.x).max()!, maxY: corners.map(\.y).max()!)
    }

    /// How far `face` stays clear of `rect` on its own side; negative where they overlap.
    private static func clearance(of face: StageRect, from rect: StageRect) -> Double {
        guard face.minX < rect.maxX, rect.minX < face.maxX else { return .infinity }
        return face.midY < rect.midY ? rect.minY - face.maxY : face.minY - rect.maxY
    }

    /// One frame's invariants: a finite seam inside the band, finite poses, drawn squash within
    /// its limits, blinks and the press in range, and the angel's wings on stage.
    private static func checkInvariants(_ frame: StageFrame, metrics m: StageMetrics, _ label: String) {
        for v in frame.picture.seam {
            check(v.isFinite && v >= 0 && v <= 1, "\(label): the seam leaves the band (\(v))")
        }
        for c in DuoCharacter.allCases {
            let pose = frame.picture.faces[c]
            pose.forEachValue { check($0.isFinite, "\(label): \(c) draws a non-finite value") }
            let drawn = pose.drawn, limits = FaceRig.squashLimits(c)
            check(drawn.sy >= limits.lowerBound - 1e-9 && drawn.sy <= limits.upperBound + 1e-9,
                  "\(label): \(c)'s drawn squash \(drawn.sy) leaves \(limits)")
            check((0...1).contains(pose.blink) && pose.reopen >= 1 && pose.reopen <= 1 + BlinkEnvelope.overshoot + 1e-9
                      && (0...1).contains(pose.press) && (0...1).contains(pose.squeeze),
                  "\(label): \(c)'s blink \(pose.blink), reopen \(pose.reopen), press \(pose.press) in range")
            check(pose.scale > 0.4 * m.scale && pose.scale < 1.6 * m.scale, "\(label): \(c)'s scale \(pose.scale)")
            if c == .angel {
                for sigma in [-1.0, 1] {
                    let overhang = FaceRig.wingOverhang(drawn, sigma: sigma, angle: pose.wings[sigma], edges: 0...m.width)
                    check(overhang <= 1e-6, "\(label): the angel's wing \(sigma) reaches \(overhang) pt off screen")
                }
            }
        }
    }

    // MARK: Seeded stress

    /// Random conversations, on every device and in every motion mode: every frame keeps its
    /// invariants, the drawn heads and the seam never jump (outside Reduce Motion and
    /// cross-fades), no bubble shows over its character's eyes, brows or mouth (shown as the
    /// caption layer shows it: once its slot is clear, gliding to a changed slot), a speaker's
    /// slot opens only once their face is clear of it, and within 4.5 s of New conversation only
    /// the idle drift still moves (the halo's last wobble is the slowest spring to rest).
    static func stress() {
        let devices: [StageMetrics] = [.iPhoneSE, .iPhone18Pro, .iPhoneProMax, .iPadPortrait, .iPadLandscape]
        var frames = 0, jumpsChecked = 0, bubbleFrames = 0, speakerSlots = 0
        for seed in UInt64(1)...30 {
            let script = randomConversation(seed: seed)
            let m = devices[Int(seed) % devices.count]
            let mode = seed % 10 == 3 ? StageMode(reduceMotion: true) : seed % 10 == 7 ? StageMode(crossFadeOnly: true)
                : StageMode()
            var previous: [Vec2]?, steps: [[Double]] = [], faded = true
            var asleepAt: Double?
            var shown: [DuoCharacter: BubbleGlide] = [:], hiddenAt: [DuoCharacter: Double] = [:]
            perform(script, seed: seed, metrics: m, mode: mode, until: script.duration + 2) { time, frame, sim in
                frames += 1
                let label = "seed \(seed) at \(String(format: "%.3f", time)) s"
                checkInvariants(frame, metrics: m, label)
                let events = sim.drainEvents()
                for c in DuoCharacter.allCases {
                    let layout = sim.layout
                    // The caption layer's content: a clear slot with text, or dots while writing.
                    var slot = layout.bubbles[c]
                    if sim.pendingSlots.contains(c) { slot = nil }
                    if let kind = slot?.kind, kind == .caption ? (sim.inputs.captions[c] ?? "").isEmpty
                        : !(sim.inputs.thinking.contains(c) || sim.inputs.floor == nil) {
                        slot = nil
                    }
                    guard let slot, !mode.reduceMotion, frame.crossFade == nil else {
                        // Taken away, a bubble springs out over about 0.4 s where it is; given
                        // back sooner, the caption layer keeps its view and it glides on.
                        if shown[c] != nil, hiddenAt[c] == nil { hiddenAt[c] = time }
                        if let hidden = hiddenAt[c], time - hidden >= 0.4 { shown[c] = nil }
                        continue
                    }
                    hiddenAt[c] = nil
                    var rect = slot.rect
                    if slot.kind == .dots {
                        rect = StageRect(x: rect.midX - 42, y: rect.minY, width: 84, height: rect.height)
                    }
                    if shown[c] == nil { shown[c] = BubbleGlide(rect) } else { shown[c]!.glide(to: rect, for: 1 / 120) }
                    let face = featureRect(frame.picture.faces[c])
                    let gap = clearance(of: face, from: shown[c]!.rect)
                    check(gap > -0.5, "\(label): \(c)'s bubble shows \(-gap) pt over their face")
                    bubbleFrames += 1
                    if slot.isSpeaker, events.contains(where: { $0.event == .slotClear(c) }) {
                        let settled = layout.featureBox(c).distance(to: slot.rect)
                        check(face.distance(to: slot.rect) >= min(6, settled - 1) - 1e-6,
                              "\(label): \(c)'s slot opens \(face.distance(to: slot.rect)) pt from their face")
                        speakerSlots += 1
                    }
                }
                // A jump: a landmark or a seam sample moving over 3 pt in one frame, and over four
                // times as far as in the frames either side of it.
                let seam = frame.picture.seam.enumerated().map { Vec2(m.x(Double($0.offset) / 48), m.y($0.element)) }
                let points = DuoCharacter.allCases.flatMap { landmarks(frame.picture.faces[$0]) } + seam
                let fading = frame.crossFade != nil || mode.reduceMotion
                if let previous, !fading, !faded {
                    steps.append(zip(points, previous).map { ($0 - $1).length })
                    if steps.count == 3 {
                        let (before, step, after) = (steps[0], steps[1], steps[2])
                        for i in step.indices where step[i] > 3 && step[i] > 4 * max(before[i], after[i]) + 0.5 {
                            check(false, "\(label): landmark \(i) jumped \(step[i]) pt in the frame before "
                                + "(\(before[i]) and \(after[i]) either side)")
                        }
                        jumpsChecked += 1
                        steps.removeFirst()
                    }
                } else {
                    steps = []
                }
                previous = points
                faded = fading
                // Settled: asleep, or only the idle drift (and breath) moving.
                if time > script.duration - 3, !sim.needsFrames || sim.activity == .ambient, asleepAt == nil {
                    asleepAt = time
                }
            }
            check(asleepAt.map { $0 <= script.duration - 3 + 4.5 } == true,
                  "seed \(seed): the stage settles within 4.5 s of New conversation (\(String(describing: asleepAt)))")
        }
        check(frames > 80_000 && jumpsChecked > 60_000 && bubbleFrames > 20_000 && speakerSlots > 50,
              "the stress runs covered \(frames) frames, \(bubbleFrames) with bubbles and \(speakerSlots) speakers' slots")
        print("STAGE_RIG_STRESS: \(frames) frames of 30 random conversations, \(bubbleFrames) bubbles drawn")
    }

    // MARK: Smoothness

    /// Moments that must not pop, flash or snap, each played through and measured.
    static func smoothness() {
        let m = StageMetrics.iPhone18Pro

        // The devil's horns ease out of the seam's press as he is freed, at a handover and at the
        // release, rather than springing up in one frame (19 fu): the press (hornPress·q·press,
        // fu) moves at most 8 fu a frame, is full while he is pressed and gone once he is free.
        let handovers = StageScript.scenario("handovers", seed: 1)!
        var lastPress: Double?, pressed = false, steepest = 0.0
        let freed = perform(handovers, seed: 1) { _, frame, sim in
            let devil = frame.picture.faces.devil
            let press = DevilGeometry.hornPress * devil.squeeze * devil.press
            if let lastPress { steepest = max(steepest, abs(press - lastPress)) }
            lastPress = press
            if sim.faces.devil.contact != nil, devil.press > 0.999 { pressed = true }
            checkInvariants(frame, metrics: m, "handovers")
        }
        check(steepest <= 8, "the horns' press moves \(steepest) fu in a frame")
        check(pressed, "the horns are pressed while he is squished")
        check(freed.frame.picture.faces.devil.press < 1e-3, "the horns are freed after (\(freed.frame.picture.faces.devil.press))")

        // The talking mouth rests where lip sync's rest does, so it shows nothing of its own as
        // lip sync blends in and out: the speaker's mouth stays shut while they keep the floor in
        // silence, and closes from the listener's mouth on its springs as they take the floor,
        // opening only with the voice.
        for c in DuoCharacter.allCases {
            let e = ExpressionLibrary.targets(.talking, for: c).mouth
            let rest = LipSyncMapping.map(e, drive: .rest, talk: 1, character: c)
            check(abs(e.open - rest.open) <= 1.5 && abs(e.width - rest.width) <= 1.5,
                  "\(c): the talking mouth (\(e.open) × \(e.width)) rests where lip sync does (\(rest.open) × \(rest.width))")
        }
        var waited = 0
        perform(StageScript.scenario("waiting", seed: 1)!, seed: 1) { time, frame, sim in
            guard let speaker = sim.stageFloor, !sim.inputs.talking.contains(speaker) else { return }
            waited += 1
            let open = frame.picture.faces[speaker].features.mouth.open
            check(open <= 1.5, "\(speaker) keeps the floor in silence with the mouth open \(open) at \(time) s")
        }
        check(waited > 240, "the speaker waited in silence (\(waited) frames)")
        var opening = PerCharacter<Double?>(angel: nil, devil: nil), handed = 0
        for name in ["handovers", "rapid", "addressing"] {
            perform(StageScript.scenario(name, seed: 1)!, seed: 1) { time, frame, sim in
                for c in DuoCharacter.allCases {
                    guard sim.stageFloor == c, !sim.faces[c].voiced, sim.faces[c].talk.value < 1e-6 else {
                        opening[c] = nil
                        continue
                    }
                    // The closing spring's overshoot below 0 draws as the closed line.
                    let open = max(0, frame.picture.faces[c].features.mouth.open)
                    if let last = opening[c] {
                        check(open <= last + 0.05, "\(name): \(c)'s mouth opens to \(open) before the voice at \(time) s")
                        handed += 1
                    }
                    opening[c] = open
                }
            }
        }
        check(handed > 100, "handovers waited for the voice (\(handed) frames)")

        // Mouths never jump: a laughing line opens its mouth over a few frames, and an
        // interrupted voice hands the mouth back to the expression from where it was.
        for name in ["cues", "interrupt", "reset"] {
            var last = PerCharacter<MouthParams?>(angel: nil, devil: nil)
            perform(StageScript.scenario(name, seed: 1)!, seed: 1) { time, frame, _ in
                for c in DuoCharacter.allCases {
                    let mouth = frame.picture.faces[c].features.mouth
                    if let before = last[c] {
                        check(abs(mouth.open - before.open) <= 12 && abs(mouth.width - before.width) <= 12,
                              "\(name): \(c)'s mouth jumps from \(before.open) × \(before.width) to \(mouth.open) × "
                                  + "\(mouth.width) at \(time) s")
                    }
                    last[c] = mouth
                }
                checkInvariants(frame, metrics: m, name)
            }
        }

        // The laugh's bounce and shake fade on their own weights, so a change of expression
        // never swaps one for the other at once.
        var lastRhythm = PerCharacter<(bob: Double, shake: Double)?>(angel: nil, devil: nil)
        for name in ["human", "cues"] {
            lastRhythm = PerCharacter(angel: nil, devil: nil)
            perform(StageScript.scenario(name, seed: 1)!, seed: 1) { time, frame, _ in
                for c in DuoCharacter.allCases {
                    let pose = frame.picture.faces[c]
                    if let before = lastRhythm[c] {
                        check(abs(pose.bob - before.bob) <= 0.8 && abs(pose.shake - before.shake) <= 1.5 * Double.pi / 180,
                              "\(name): \(c)'s laugh jumps (bob \(before.bob) → \(pose.bob), shake \(before.shake) → "
                                  + "\(pose.shake)) at \(time) s")
                    }
                    lastRhythm[c] = (pose.bob, pose.shake)
                }
            }
        }

        // Taking the floor ends a listener's reaction: the angel laughing along with the devil
        // speaks her own plain line with her talking face.
        var laughedAlong = 0
        for seed in UInt64(1)...30 {
            var c = StageConversation(duration: 6)
            c.activate(at: 0.2)
            let end = c.say(.devil, ["Haha, nice try!"], at: 0.5, next: .angel)
            c.say(.angel, ["You will feel wonderful."], at: end + 0.25)
            var laughing = false
            perform(c.script(seed: seed), seed: seed) { time, _, sim in
                if sim.drainEvents().contains(where: { $0.event == .gesture(.angel, .laughAlong) }) { laughing = true }
                if laughing, sim.stageFloor == .angel {
                    check(sim.faces.angel.directive.effectiveExpression == .talking,
                          "seed \(seed): the angel speaks with \(sim.faces.angel.directive.effectiveExpression) at \(time) s")
                }
            }
            if laughing { laughedAlong += 1 }
        }
        check(laughedAlong >= 5, "the angel laughed along before speaking in \(laughedAlong) runs")

        // A face's rhythms run on its own clock, which stands still while the stage sleeps: the
        // vein throbs on from where it was, however long the stage slept.
        var rig = FaceRig(.devil, placement: StageLayout.solve(key: StageLayoutKey(), metrics: m).faces.devil)
        var grumpy = FaceDirective()
        grumpy.expression = .grumpy
        rig.direct(grumpy)
        for k in 0..<100 { _ = rig.step(at: Double(k) / 240, drive: nil, speaking: false, room: nil, beats: false) }
        let before = rig.pose().veinThrob
        _ = rig.step(at: 30, drive: nil, speaking: false, room: nil, beats: false)
        check(abs(rig.pose().veinThrob - before) <= 2 * Double.pi / DevilGeometry.angerVeinPeriod / 240 + 1e-12,
              "the vein throbs on from \(before) to \(rig.pose().veinThrob) after a sleep")

        // Blinks reopen 4% past rest.
        var widest = 1.0
        perform(StageScript.scenario("idle-active", seed: 1)!, seed: 1, until: 12) { _, frame, _ in
            widest = max(widest, frame.picture.faces.angel.reopen, frame.picture.faces.devil.reopen)
        }
        check(widest > 1.03, "a blink reopens past rest (\(widest))")
    }
}

// MARK: - Intro

extension StageRigChecks {
    /// Watches a run frame by frame as the stress and smoothness checks do: every frame keeps its
    /// invariants; no landmark or seam sample jumps (over 3 pt in a frame and over four times as
    /// far as in the frames either side); no face pops in faster than 20 of its sizes a second;
    /// and a face in sight never jumps its mouth (12 fu) or its laugh's bob and shake, each per
    /// 1/120 s.
    private struct SmoothWatch {
        let label: String
        let metrics: StageMetrics
        private var last: (time: Double, points: [Vec2], faces: PerCharacter<FacePose>)?
        private var steps: [[Double]] = []
        private(set) var jumpsChecked = 0

        init(_ label: String, metrics: StageMetrics) {
            self.label = label
            self.metrics = metrics
        }

        mutating func see(_ frame: StageFrame, at time: Double) {
            let m = metrics
            let at = "\(label) at \(String(format: "%.3f", time)) s"
            StageRigChecks.checkInvariants(frame, metrics: m, at)
            let seam = frame.picture.seam.enumerated().map { Vec2(m.x(Double($0.offset) / 48), m.y($0.element)) }
            let points = DuoCharacter.allCases.flatMap { StageRigChecks.landmarks(frame.picture.faces[$0]) } + seam
            if let last {
                steps.append(zip(points, last.points).map { ($0 - $1).length })
                if steps.count == 3 {
                    let (before, step, after) = (steps[0], steps[1], steps[2])
                    for i in step.indices where step[i] > 3 && step[i] > 4 * max(before[i], after[i]) + 0.5 {
                        check(false, "\(at): landmark \(i) jumped \(step[i]) pt in the frame before "
                            + "(\(before[i]) and \(after[i]) either side)")
                    }
                    jumpsChecked += 1
                    steps.removeFirst()
                }
                // The frame's length in 120ths of a second.
                let frames = max(1, (time - last.time) * 120)
                for c in DuoCharacter.allCases {
                    let a = last.faces[c], b = frame.picture.faces[c]
                    check(abs(b.pop.size - a.pop.size) <= 20 * (time - last.time) + 1e-9,
                          "\(at): \(c) pops from \(a.pop.size) to \(b.pop.size) in a frame")
                    guard a.pop.size > 0, b.pop.size > 0 else { continue }
                    let (was, now) = (a.features.mouth, b.features.mouth)
                    check(abs(now.open - was.open) <= 12 * frames && abs(now.width - was.width) <= 12 * frames,
                          "\(at): \(c)'s mouth jumps from \(was.open) × \(was.width) to \(now.open) × \(now.width)")
                    check(abs(b.bob - a.bob) <= 0.8 * frames
                              && abs(b.shake - a.shake) <= 1.5 * Double.pi / 180 * frames,
                          "\(at): \(c)'s laugh jumps (bob \(a.bob) → \(b.bob), shake \(a.shake) → \(b.shake))")
                }
            }
            last = (time, points, frame.picture.faces)
        }
    }

    /// The gestures only the intro starts here: with no conversation, nothing else pops in,
    /// shoves, squishes, cackles, huffs or winks, and the idle stage's first glance is 8 s off.
    private static let introGestures: Set<StageGesture> = [.popIn, .glance, .laughAlong, .shove, .squish, .huff,
                                                           .cheekyWink]

    private static func isIntroGesture(_ record: StageEventRecord) -> Bool {
        if case .gesture(_, let gesture) = record.event { introGestures.contains(gesture) } else { false }
    }

    /// A stage settled at rest that begins the intro at 0, on `metrics` in `mode`.
    private static func introduced(seed: UInt64, metrics m: StageMetrics = .iPhone18Pro,
                                   mode: StageMode = StageMode()) -> StageSimulation {
        var sim = StageSimulation(seed: seed, metrics: m, mode: mode)
        sim.update(metrics: m, bubbleHeights: [:], pillHeight: 0)
        sim.settleAll()
        sim.beginIntro(at: 0)
        return sim
    }

    // MARK: Intro

    /// The launch intro (`StageIntro`): the faces start unseen and pop in past full size,
    /// stretching tall and squashing wide; they notice each other and shove each other along the
    /// seam, each coming on top as it bows into the other's half and the other squished and
    /// pushed away; then they make up and settle into the idle stage, the angel on top as at
    /// launch, in 2.5–4 s. It never jumps, on any device or at any cadence, and replays exactly; a
    /// conversation starting at any moment hands it over smoothly; it plays once and pauses with
    /// the scene; and under Reduce Motion the faces fade in, unmoving.
    static func intro() {
        let m = StageMetrics.iPhone18Pro
        let beats = StageIntro.beats

        // The choreography: in order and 2.5–4 s long; the devil starts the shoving and the angel
        // has the last shove.
        check(zip(beats, beats.dropFirst()).allSatisfy { $0.time <= $1.time }, "the intro's beats are in order")
        let length = beats.map { time, beat -> Double in
            switch beat {
            case .pop(_, _, let length), .look(_, _, _, let length), .squish(_, let length): time + length
            case .windUp, .shove, .letGo: time
            }
        }.max()!
        check((2.5...4).contains(length), "the intro lasts \(length) s")
        let shovers = beats.compactMap { beat -> DuoCharacter? in
            if case .shove(let c) = beat.beat { c } else { nil }
        }
        check(shovers == [.devil, .angel], "the devil shoves first and the angel last (\(shovers))")
        /// The beats of an intro begun at `start` as the gestures they record, on the substeps
        /// they fall on.
        func gestures(from start: Double) -> [StageEventRecord] {
            beats.compactMap { time, beat in
                let at = Double(FixedStepper.index(atOrAfter: start + time)) / FixedStepper.rate
                return switch beat {
                case .pop(let c, _, _): StageEventRecord(time: at, event: .gesture(c, .popIn))
                case .look(let c, let gesture, _, _): StageEventRecord(time: at, event: .gesture(c, gesture))
                case .shove(let c): StageEventRecord(time: at, event: .gesture(c, .shove))
                case .squish(let c, _): StageEventRecord(time: at, event: .gesture(c, .squish))
                case .windUp, .letGo: nil
                }
            }
        }
        let expected = gestures(from: 0)
        let pops = beats.compactMap { time, beat -> (DuoCharacter, Double)? in
            if case .pop(let c, _, _) = beat { (c, time) } else { nil }
        }
        check(pops.map(\.0) == [.angel, .devil], "the angel pops in, then the devil")

        // The timeline, on a dozen seeds.
        for seed in UInt64(1)...12 {
            let label = "intro seed \(seed)"
            var watch = SmoothWatch(label, metrics: m)
            var events: [StageEventRecord] = []
            var seen = PerCharacter<Double?>(angel: nil, devil: nil)
            var peak = PerCharacter(angel: 0.0, devil: 0.0)
            var tallest = PerCharacter(angel: 1.0, devil: 1.0), widest = PerCharacter(angel: 1.0, devil: 1.0)
            var bowed = (down: 0.0, up: 0.0)
            var pushed = PerCharacter(angel: 0.0, devil: 0.0)
            let run = perform(StageScript(duration: 6), seed: seed, until: 5.9, intro: true) { time, frame, sim in
                watch.see(frame, at: time)
                events += sim.drainEvents()
                for c in DuoCharacter.allCases {
                    let pose = frame.picture.faces[c]
                    if time < pops[0].1 { check(pose.pop == .unseen, "\(label): \(c) is unseen at \(time) s") }
                    if pose.pop.size > 0, seen[c] == nil { seen[c] = time }
                    peak[c] = max(peak[c], pose.pop.size)
                    tallest[c] = max(tallest[c], pose.pop.squash)
                    widest[c] = min(widest[c], pose.pop.squash)
                    // How far the face rode away from the seam: the devil down, the angel up.
                    let rode = pose.anchor.y - sim.layout[c].anchor.y
                    pushed[c] = max(pushed[c], c == .devil ? rode : -rode)
                }
                bowed = (max(bowed.down, sim.seam.shove.value), min(bowed.up, sim.seam.shove.value))
                if time < beats.last!.time {
                    check(sim.needsFrames && sim.activity == .transition,
                          "\(label): the intro runs at the display's rate (\(sim.activity) at \(time) s)")
                }
            }
            for (c, time) in pops {
                check(seen[c].map { $0 > time && $0 <= time + 1.0 / 120 + 1e-9 } == true,
                      "\(label): \(c) appears at \(seen[c] ?? -1) s, popping in at \(time) s")
                check(peak[c] > 1.15 && peak[c] < 1.25, "\(label): \(c) pops in past full size (\(peak[c]))")
                check(tallest[c] > 1.08 && widest[c] < 0.97,
                      "\(label): \(c) stretches tall (\(tallest[c])) and squashes wide (\(widest[c])) popping in")
            }
            check(events.filter(isIntroGesture) == expected,
                  "\(label): the beats' gestures \(events.filter(isIntroGesture).map { "\($0.time) \($0.event)" })")
            let flips = events.compactMap { record -> DuoCharacter? in
                if case .flipped(let c) = record.event { c } else { nil }
            }
            check(flips == [.devil, .angel], "\(label): each shover comes on top (\(flips))")
            check(bowed.down >= 0.06 && bowed.up <= -0.06,
                  "\(label): the shoves bow the seam into each half (\(bowed))")
            check(pushed.devil >= 10 && pushed.angel >= 10, "\(label): each shoved face is pushed away (\(pushed))")
            check(watch.jumpsChecked > 600, "\(label): \(watch.jumpsChecked) frames watched")

            // Over, the faces rest as they would without the intro, the angel on top, and the seam
            // rests in its shape, only the idle drift flowing on it.
            let plain = perform(StageScript(duration: 6), seed: seed, until: 5.9) { _, _, _ in }
            check(run.intro == nil && run.frame.picture.dominant == .angel,
                  "\(label): the intro is over, the angel on top")
            check(run.roles == plain.roles && run.activity != .transition,
                  "\(label): the stage idles (\(run.activity))")
            for c in DuoCharacter.allCases {
                let a = run.frame.picture.faces[c], b = plain.frame.picture.faces[c]
                check(a.pop == FacePop() && run.directors[c].overlay == nil, "\(label): \(c)'s looks are over")
                near(a.anchor, b.anchor, 0.5, "\(label): \(c) settles where it rests")
                near(a.scale, b.scale, 1e-3, "\(label): \(c)'s settled scale")
                near(a.sy, b.sy, 2e-3, "\(label): \(c)'s settled squash")
                near(a.tilt, b.tilt, 1e-3, "\(label): \(c)'s settled tilt")
            }
            check(run.seam.isMotionSettled && run.seam.shape == run.layout.seam && abs(run.seam.shove.value) < 1e-4
                      && run.seam.rippleMagnitude < 1e-4, "\(label): the seam rests in its shape")
        }

        // On every device, at 30, 60 and 120 Hz, and with Prefer Cross-Fade Transitions, which
        // keeps the intro's motion, nothing jumps.
        let devices: [StageMetrics] = [.iPhoneSE, .iPhone18Pro, .iPhoneProMax, .iPadPortrait, .iPadLandscape]
        var watched = 0
        for (i, device) in devices.enumerated() {
            for hz in [30.0, 60, 120] {
                let mode = hz == 60 && i % 2 == 0 ? StageMode(crossFadeOnly: true) : StageMode()
                var watch = SmoothWatch("the intro on a \(device.width)-pt stage at \(Int(hz)) Hz", metrics: device)
                perform(StageScript(duration: 5), seed: UInt64(20 + i), metrics: device, mode: mode, hz: hz,
                        intro: true) { time, frame, _ in
                    watch.see(frame, at: time)
                }
                watched += watch.jumpsChecked
            }
        }
        check(watched > 5000, "the devices' intros were watched over \(watched) frames")

        // Any cadence draws the same frames at the same times: a digest every 0.25 s.
        let quarters = (1...24).map { Double($0) / 4 }
        var jitter = SplitMix64(seed: 13)
        var jittered: [Double] = []
        var clock = 0.0, hitched = false
        while clock < 6 {
            var dt = jitter.uniform(in: 0.008...0.017)
            if !hitched, clock > 1.42 {
                dt = 0.09
                hitched = true
            }
            let next = min(clock + dt, 6)
            jittered += quarters.filter { $0 > clock && $0 < next }
            jittered.append(next)
            clock = next
        }
        var replays: [(digests: [UInt64], events: [StageEventRecord])] = []
        for frames in [frameTimes(30, until: 6, quarters: quarters), frameTimes(60, until: 6, quarters: quarters),
                       frameTimes(120, until: 6, quarters: quarters), jittered] {
            var sim = introduced(seed: 9)
            var digests: [UInt64] = [], events: [StageEventRecord] = []
            for time in frames {
                let frame = sim.advance(to: time, mouths: SilentMouths())
                if quarters.contains(time) { digests.append(frame.digest()) }
                events += sim.drainEvents()
            }
            replays.append((digests, events))
        }
        check(replays[0].digests.count == quarters.count && Set(replays[0].digests).count > 16,
              "the intro's digests change as it plays")
        for replay in replays.dropFirst() {
            check(replay.digests == replays[0].digests && replay.events == replays[0].events,
                  "the intro draws the same frames and events at any cadence")
        }

        // A conversation starting at any moment (active, or preparing too) hands over smoothly:
        // from then on no beat runs, anyone unseen pops in at once, the shove lets go, and the
        // intro is over once the pops are.
        var handovers = 0
        for (k, at) in stride(from: 0.0, through: 3.6, by: 0.05).enumerated() {
            var script = StageScript(duration: at + 4)
            script.at(at) {
                $0.active = true
                $0.preparing = k % 2 == 0
            }
            let label = "a conversation at \(String(format: "%.2f", at)) s"
            let start = Double(FixedStepper.index(atOrAfter: at)) / FixedStepper.rate
            var watch = SmoothWatch(label, metrics: m)
            var events: [StageEventRecord] = []
            var unseen = Set(DuoCharacter.allCases)
            perform(script, seed: UInt64(k), intro: true) { time, frame, sim in
                watch.see(frame, at: time)
                // The conversation reaches the stage with the first frame at or after its time:
                // what came before is the intro's.
                let drained = sim.drainEvents()
                if time < at {
                    unseen = Set(DuoCharacter.allCases.filter { frame.picture.faces[$0].pop == .unseen })
                    return
                }
                events += drained
                check(sim.seam.shove.target == 0 && sim.intro?.shover == nil, "\(label): the shove lets go")
                if time >= start + FacePop.duration {
                    check(sim.intro == nil && frame.picture.faces.angel.pop == FacePop()
                              && frame.picture.faces.devil.pop == FacePop(), "\(label): the intro is over at \(time) s")
                }
            }
            for record in events where isIntroGesture(record) {
                guard case .gesture(let c, let gesture) = record.event else { continue }
                // An agenda glance may come once the conversation is under way.
                if gesture == .glance { continue }
                check(gesture == .popIn && unseen.contains(c) && abs(record.time - start) < 1e-9,
                      "\(label): \(c)'s \(gesture) at \(record.time) s, after the hand-over")
            }
            for c in unseen {
                check(events.contains(StageEventRecord(time: start, event: .gesture(c, .popIn))),
                      "\(label): \(c), unseen, pops in at the hand-over")
            }
            handovers += 1
        }
        check(handovers == 73, "\(handovers) hand-overs")

        // A whole conversation starting mid-intro, as a scripted run's tap on the microphone may:
        // the human asks, the angel answers and the devil replies, handovers both ways.
        for (k, at) in [0.1, 0.5, 1.2, 1.45, 1.6, 2.1, 2.7].enumerated() {
            var c = StageConversation(duration: at + 10)
            c.activate(at: at)
            let final = c.ask("Should I go to the gym tonight?", at: at + 0.4, addressed: [.angel])
            c.write(.angel, at: final + 0.3)
            var end = c.say(.angel, ["Yes!", "You will feel wonderful."], at: final + 1.0, next: .devil)
            end = c.say(.devil, ["Or not."], at: end + 0.3, to: [.angel])
            c.endExchange(at: end - 0.3)
            var watch = SmoothWatch("a conversation from \(at) s", metrics: m)
            var impacts = 0
            perform(c.script(seed: UInt64(k)), seed: UInt64(k), intro: true) { time, frame, sim in
                watch.see(frame, at: time)
                impacts += sim.drainEvents().filter { if case .impact = $0.event { true } else { false } }.count
            }
            check(impacts == 2,
                  "a conversation from \(at) s hands over to the angel and the devil (\(impacts) impacts)")
        }

        // Under Reduce Motion the faces fade in where they rest: one cross-fade from the stage
        // without them, nothing moving and no gesture.
        let reduced = StageMode(reduceMotion: true)
        var still = introduced(seed: 3, mode: reduced)
        check(still.intro == nil, "Reduce Motion: no beats")
        let faded = fadeRun(&still, script: StageScript(duration: 2), until: 2) { time, frame, sim, _ in
            check(sim.maxSpringSpeed == 0, "Reduce Motion: every spring rests during the intro (\(time) s)")
            for c in DuoCharacter.allCases {
                let pose = frame.picture.faces[c], placement = sim.layout[c]
                check(pose.pop == FacePop() && pose.anchor == placement.anchor && pose.scale == placement.scale
                          && pose.tilt == 0, "Reduce Motion: \(c) shows where it rests at \(time) s")
                if let fade = frame.crossFade {
                    check(fade.from.faces[c].pop == .unseen, "Reduce Motion: \(c) fades in from nothing")
                }
            }
        }
        checkFades(faded.fades, starts: [0], "Reduce Motion's intro")
        check(!faded.events.contains {
            if case .gesture = $0.event { true } else if case .flipped = $0.event { true } else { false }
        }, "Reduce Motion: no gesture or flip in the intro")

        // Turned on mid-shove, Reduce Motion ends the intro at once under one cross-fade.
        var turned = introduced(seed: 3)
        let cut = fadeRun(&turned, script: StageScript(duration: 4), until: 4, modes: [(1.6, reduced)],
                          fromSettled: false) { time, frame, sim, _ in
            guard time > 1.6 else { return }
            check(sim.intro == nil && sim.maxSpringSpeed == 0, "Reduce Motion from 1.6 s: the intro ends (\(time) s)")
            for (i, v) in frame.picture.seam.enumerated() {
                near(v, heldProfile(sim.layout.seam, i), 1e-12, "Reduce Motion from 1.6 s: the seam holds at \(time) s")
            }
            for c in DuoCharacter.allCases {
                check(frame.picture.faces[c].pop == FacePop(), "Reduce Motion from 1.6 s: \(c) is there")
            }
        }
        checkFades(cut.fades, starts: [1.6], "Reduce Motion from mid-shove")
        check(!cut.events.contains { $0.time > 1.6 && isIntroGesture($0) }, "Reduce Motion: no beat after 1.6 s")

        // Under Reduce Motion, faces held unseen for a cue fade in when a conversation starts.
        var waiting = StageSimulation(seed: 4, metrics: m, mode: reduced)
        waiting.update(metrics: m, bubbleHeights: [:], pillHeight: 0)
        waiting.settleAll()
        waiting.awaitIntro()
        var starting = StageScript(duration: 2)
        starting.at(0.5) { $0.active = true }
        let shown = fadeRun(&waiting, script: starting, until: 2, fromSettled: false) { time, frame, _, _ in
            for c in DuoCharacter.allCases where time < 0.5 {
                check(frame.picture.faces[c].pop == .unseen, "Reduce Motion: \(c) waits unseen at \(time) s")
            }
        }
        checkFades(shown.fades, starts: [0.5], "Reduce Motion: a conversation shows the waiting faces")
        check(waiting.intro == nil && waiting.frame.picture.faces.devil.pop == FacePop(), "Reduce Motion: shown")

        // Held unseen, the faces wait for the cue; the intro then plays from it.
        var cued = StageSimulation(seed: 6, metrics: m)
        cued.update(metrics: m, bubbleHeights: [:], pillHeight: 0)
        cued.settleAll()
        cued.awaitIntro()
        var cueWatch = SmoothWatch("the intro on cue", metrics: m)
        var cueEvents: [StageEventRecord] = []
        for k in 1...(7 * 120) {
            let time = Double(k) / 120
            if k == 2 * 120 { cued.beginIntro(at: time) }
            let frame = cued.advance(to: time, mouths: SilentMouths())
            cueWatch.see(frame, at: time)
            cueEvents += cued.drainEvents()
            if time <= 2.25 {
                check(frame.picture.faces.angel.pop == .unseen && frame.picture.faces.devil.pop == .unseen,
                      "the faces wait unseen for the cue at \(time) s")
            }
        }
        check(cueEvents.filter(isIntroGesture) == gestures(from: 2), "the intro plays from its cue")

        // It plays once, and a conversation already under way gets none.
        var twice = introduced(seed: 7)
        for k in 1...(5 * 120) { twice.advance(to: Double(k) / 120, mouths: SilentMouths()) }
        _ = twice.drainEvents()
        twice.beginIntro(at: 5)
        twice.awaitIntro()
        var again: [StageEventRecord] = []
        for k in 1...(4 * 120) {
            let frame = twice.advance(to: 5 + Double(k) / 120, mouths: SilentMouths())
            again += twice.drainEvents()
            check(frame.picture.faces.angel.pop == FacePop() && frame.picture.faces.devil.pop == FacePop(),
                  "a second intro shows the faces as they are")
        }
        check(twice.intro == nil && !again.contains(where: isIntroGesture), "the intro plays once")
        var busy = StageSimulation(seed: 8, metrics: m)
        busy.update(metrics: m, bubbleHeights: [:], pillHeight: 0)
        busy.settleAll()
        busy.receive(StageInputs(active: true), at: 0.1)
        var busyEvents: [StageEventRecord] = []
        for k in 1...120 {
            let time = Double(k) / 120
            if k == 24 { busy.beginIntro(at: time) }
            let frame = busy.advance(to: time, mouths: SilentMouths())
            busyEvents += busy.drainEvents()
            check(frame.picture.faces.angel.pop == FacePop() && frame.picture.faces.devil.pop == FacePop(),
                  "a conversation under way keeps its faces")
        }
        check(busy.intro == nil && !busyEvents.contains(where: isIntroGesture),
              "a conversation under way gets no intro")

        // The intro pauses with the scene and carries on where it was.
        var paused = introduced(seed: 5)
        var pauseWatch = SmoothWatch("the intro paused", metrics: m)
        var time = 0.0
        while time < 1.55 - 1e-9 {
            time += 1.0 / 120
            pauseWatch.see(paused.advance(to: time, mouths: SilentMouths()), at: time)
        }
        let frozen = paused.frame
        _ = paused.drainEvents()
        paused.receive(StageMode(sceneActive: false), at: time)
        let held = paused.advance(to: time + 30, mouths: SilentMouths())
        check(held.time == frozen.time && held.digest() == frozen.digest(), "the intro stands still while inactive")
        paused.receive(StageMode(), at: frozen.time)
        var resumed: [StageEventRecord] = []
        time = frozen.time
        while time < 5 {
            time += 1.0 / 120
            pauseWatch.see(paused.advance(to: time, mouths: SilentMouths()), at: time)
            resumed += paused.drainEvents()
        }
        check(resumed.filter(isIntroGesture) == expected.filter { $0.time > frozen.time },
              "after the pause the intro's beats come at their times")
    }
}

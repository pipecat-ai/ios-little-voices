import SwiftUI

enum VoicePalette {
    /// Settings' accent.
    static let blue = Color(red: 0.08, green: 0.36, blue: 0.87)
}

/// Which of the palette's grades a glass surface takes.
enum SoftGlassKind {
    /// The header's buttons, the dock and its side buttons.
    case chrome
    /// Bubbles, capsules, the pill and the banner: a gentler grade, as text sits on them.
    case caption
}

private struct SoftGlass<S: Shape>: ViewModifier {
    let shape: S
    let tint: RGBA
    let kind: SoftGlassKind
    let palette: StagePalette
    var shadowRadius: CGFloat?
    var shown = true

    func body(content: Content) -> some View {
        content.background { glass.opacity(shown ? 1 : 0) }
    }

    private var glass: some View {
        let colors = palette.colors
        let grade = kind == .chrome ? colors.chromeGrade : colors.captionGrade
        return ZStack {
            if let shadowRadius, let shadow = colors.bubbleShadow {
                OuterShadow(shape: shape, color: palette.color(shadow), radius: shadowRadius, y: shadowRadius / 3)
            }
            shape.fill(LinearGradient(colors: [palette.color(grade.tint(tint, at: 0)), palette.color(grade.tint(tint, at: 1))],
                                      startPoint: .top, endPoint: .bottom))
            if let light = colors.glassEdgeLight {
                // The inside half of a stroke along the edge, lit at the top and gone by the middle.
                shape.stroke(LinearGradient(colors: [palette.color(light), palette.color(light.alpha(0))],
                                            startPoint: .top, endPoint: .center), lineWidth: 2.4)
                    .clipShape(shape)
                    .blur(radius: 0.6)
            }
            if colors.bubbleStrokeAlpha > 0 {
                shape.stroke(Color.primary.opacity(colors.bubbleStrokeAlpha), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A shadow drawn only outside `shape`, so it never darkens translucent glass. The cut-out
/// reaches a point past the shape, so the casting fill's antialiased edge never shows.
private struct OuterShadow<S: Shape>: View {
    let shape: S
    let color: Color
    let radius: CGFloat
    let y: CGFloat

    var body: some View {
        shape.fill(Color.black)
            .shadow(color: color, radius: radius, y: y)
            .mask {
                ZStack {
                    Rectangle().padding(-(radius * 2 + abs(y)))
                    shape.blendMode(.destinationOut)
                    shape.stroke(lineWidth: 2).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Backs the view with the chrome's and captions' glass in `shape`: a tint graded lighter at
    /// the top, a soft light along the upper edge and, with a `shadowRadius`, a shadow outside it,
    /// but no rim. The palette makes it solid under Reduce Transparency and outlined under
    /// Increase Contrast. Not `shown`, it fades out.
    func softGlass<S: Shape>(_ shape: S, tint: RGBA, kind: SoftGlassKind, palette: StagePalette,
                             shadowRadius: CGFloat? = nil, shown: Bool = true) -> some View {
        modifier(SoftGlass(shape: shape, tint: tint, kind: kind, palette: palette, shadowRadius: shadowRadius,
                           shown: shown))
    }
}

/// A round glass button. Its glyph keeps one size at every text size, so the large content
/// viewer shows its title.
struct GlassCircleButton: View {
    let title: String
    let systemImage: String
    let tint: RGBA
    let glyph: RGBA
    let palette: StagePalette
    var diameter: CGFloat = 50
    var glyphSize: CGFloat = 19
    /// The header's buttons float on a soft shadow; the dock's sit in its glass.
    var shadow = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(palette.color(glyph).opacity(isEnabled ? 1 : 0.38))
                .frame(width: diameter, height: diameter)
                .softGlass(Circle(), tint: tint, kind: .chrome, palette: palette, shadowRadius: shadow ? 12 : nil)
                .contentShape(Circle())
        }
        .buttonStyle(VoicePressStyle())
        .accessibilityLabel(title)
        .accessibilityShowsLargeContentViewer { Label(title, systemImage: systemImage) }
    }
}

/// The dock's microphone: a glossy button, gray with a spinner while the app loads or a
/// conversation starts. Before a conversation it shows a waveform and pulses, inviting a press;
/// in one it shows a microphone, teal, or red while muted, with `MicrophoneAura`'s light while
/// the human is heard. Holding to talk, it listens while it is held, swelling well out from under
/// the thumb, and `onHold` hears each press and release (VoiceOver activates it once to talk and
/// again to finish); otherwise a tap starts a conversation, then mutes and unmutes it.
struct MicrophoneControl: View {
    let level: Double
    let muted: Bool
    let connecting: Bool
    let active: Bool
    /// Hold to talk.
    let holds: Bool
    /// Holding to talk: the human holds it, and is heard.
    let held: Bool
    let hearing: Bool
    let palette: StagePalette
    let action: () -> Void
    let onHold: (Bool) -> Void
    @GestureState private var pressed = false
    /// When the finger landed, so a listening tap that would land with the click is left out.
    @State private var pressedAt = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let diameter: CGFloat = 76
    /// Held to talk, it swells to this, so it shows all round a thumb.
    private static let heldScale: CGFloat = 1.5
    private var fill: [GradientStop] {
        connecting ? palette.colors.micLoadingFill : muted ? palette.colors.micMutedFill : palette.colors.micFill
    }
    private var listening: Bool { holds ? hearing : active && !muted && !connecting }
    private var aura: MicrophoneAura.Mode {
        listening ? .listening : !active && !connecting ? .inviting : .none
    }
    private var symbol: String { !active ? "waveform" : muted ? "mic.slash.fill" : "mic.fill" }
    private var title: String {
        if holds { return held ? "Listening" : "Hold to talk" }
        return connecting ? "Connecting" : !active ? "Start conversation" : muted ? "Unmute microphone" : "Mute microphone"
    }
    private var value: String {
        if holds { return connecting && held ? "Please wait" : held ? "Microphone on" : "Ready" }
        return connecting ? "Please wait" : !active ? "Ready" : muted ? "Muted" : "Microphone on"
    }
    private var hint: String {
        if holds { return held ? "Sends what you said." : "Listens until you activate it again." }
        return connecting ? "" : !active ? "Starts a conversation with the angel and the devil."
            : muted ? "Turns your microphone back on." : "Pauses your microphone."
    }

    var body: some View {
        control
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityHint(hint)
            .accessibilityShowsLargeContentViewer { Label(title, systemImage: symbol) }
            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: muted)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: connecting)
    }

    @ViewBuilder
    private var control: some View {
        if holds {
            let swollen = pressed || held
            face(pressed: swollen, zone: swollen)
                .scaleEffect(reduceMotion ? 1 : swollen ? Self.heldScale : 1)
                // It swells a beat after the face clicks down, so the press shows first.
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.52).delay(swollen ? 0.07 : 0),
                           value: swollen)
                // A cancelled touch, as when an alert takes over, releases it too.
                .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, pressed, _ in pressed = true })
                .onChange(of: pressed) { _, pressed in
                    if pressed { pressedAt = .now }
                    onHold(pressed)
                }
                // A click as the finger lands, and a firmer tap if listening starts only later, as
                // while a conversation starts.
                .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.75), trigger: pressed) { _, pressed in pressed }
                .sensoryFeedback(.impact(weight: .medium), trigger: hearing) { _, hearing in
                    hearing && Date.now.timeIntervalSince(pressedAt) > 0.2
                }
                .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: held) { was, held in was && !held }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onHold(!held) }
        } else {
            Button(action: action) { EmptyView() }
                .buttonStyle(MicrophonePressStyle { pressed in face(pressed: pressed, zone: false) })
                .disabled(connecting)
        }
    }

    private func face(pressed: Bool, zone: Bool) -> some View {
        MicrophoneFace(fill: fill, symbol: symbol, spinning: connecting, inviting: aura == .inviting,
                       pressed: pressed, zone: zone, palette: palette, diameter: Self.diameter,
                       resolution: Self.heldScale)
            .background {
                MicrophoneAura(mode: aura, level: level, palette: palette, diameter: Self.diameter)
            }
            .contentShape(Circle())
    }
}

/// Draws the microphone pressed into its base while a tap is held.
private struct MicrophonePressStyle<Face: View>: ButtonStyle {
    let face: (Bool) -> Face

    func makeBody(configuration: Configuration) -> some View { face(configuration.isPressed) }
}

/// The button itself, a chunky, toy-like one: a matte face with a soft pillow of light, a raised
/// bevel, light along its top and shaded along its bottom, standing on a darker base that shows
/// its thickness, with a short shadow beneath. Pressed, the face clicks down into its base,
/// darkening under an inner shadow, and pops back up when let go; held to talk, the button then
/// gives way to a zone of light under the thumb (`zone`). A soft glint
/// sits on the bevel; before a conversation it travels round as the button breathes and its
/// waveform plays. Reduce Transparency keeps only the face, base and glyph; Increase Contrast
/// adds an outline.
private struct MicrophoneFace: View {
    let fill: [GradientStop]
    let symbol: String
    let spinning: Bool
    let inviting: Bool
    let pressed: Bool
    /// Held to talk: a zone of light under the thumb in place of the button.
    let zone: Bool
    let palette: StagePalette
    let diameter: CGFloat
    /// The largest it is shown at, so it stays sharp as it swells.
    let resolution: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the face stands above its base.
    private var depth: CGFloat { diameter * 0.08 }
    /// The touch zone reaches this far past the button.
    private static let zoneScale: CGFloat = 1.15

    var body: some View {
        let top = fill.first?.color ?? RGBA(0x36C7A0)
        let bottom = fill.last?.color ?? RGBA(0x0B7A62)
        let sink = pressed && !reduceMotion ? depth : 0
        let opaque = palette.colors.opaque
        ZStack {
            ZStack {
                rendered { base($0, side: RGBA.mix(bottom, RGBA(0x000000), 0.3)) }
                    .offset(y: depth / 2)
                ZStack {
                    rendered { face($0, top: top, bottom: bottom) }
                    rendered { pressedIn($0, bottom: bottom) }
                        .opacity(pressed ? 1 : 0)
                    if !opaque {
                        RimGlint(diameter: diameter, resolution: resolution,
                                 color: palette.color(RGBA.mix(top, RGBA(0xFFFFFF), 0.65)),
                                 travelling: inviting && !reduceMotion)
                    }
                }
                .offset(y: -depth / 2 + sink)
            }
            // Held to talk, the button gives way to the zone just after it clicks down.
            .opacity(zone ? 0 : 1)
            .animation(zone ? .easeOut(duration: 0.14).delay(0.05) : .easeIn(duration: 0.12), value: zone)
            rendered { touchZone($0) }
                .blendMode(opaque ? .normal : .plusLighter)
                .scaleEffect(zone ? Self.zoneScale : 0.8)
                .opacity(zone ? 1 : 0)
                .animation(zone ? .spring(response: 0.3, dampingFraction: 0.6).delay(0.05)
                           : .easeIn(duration: 0.12), value: zone)
            Group {
                if spinning {
                    ProgressView().tint(zone && opaque ? palette.color(bottom) : .white).controlSize(.regular)
                        .scaleEffect(1.15)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: diameter * 0.38, weight: .bold))
                        .foregroundStyle(zone && opaque ? palette.color(bottom) : .white)
                        .symbolEffect(.bounce.byLayer, options: .repeat(.periodic(delay: 0.9)),
                                      isActive: inviting && !reduceMotion)
                        .contentTransition(.symbolEffect(.replace))
                        .scaleEffect(pressed && !zone && !reduceMotion ? 0.88 : 1)
                }
            }
            .offset(y: zone ? 0 : -depth / 2 + sink)
        }
        // A quick, firm click down, and a bouncy pop back up.
        .animation(reduceMotion ? .linear(duration: 0.1)
                   : pressed ? .spring(response: 0.1, dampingFraction: 0.9)
                   : .spring(response: 0.32, dampingFraction: 0.42), value: pressed)
        .frame(width: diameter, height: diameter)
        .phaseAnimator(inviting && !reduceMotion ? [1, 1.04] : [1]) { content, scale in
            content.scaleEffect(scale)
        } animation: { _ in .easeInOut(duration: 1.3) }
    }

    /// `content` drawn once, at the largest size it is shown at, and moved as a whole: redrawn as
    /// it breathes and swells, its gradients and shadow would be shaded again on every frame.
    private func rendered(@ViewBuilder _ content: (CGFloat) -> some View) -> some View {
        let d = diameter * resolution
        return content(d)
            .frame(width: d, height: d)
            .padding(d * 0.25)
            .drawingGroup()
            .scaleEffect(1 / resolution)
            .frame(width: diameter, height: diameter)
    }

    private func base(_ d: CGFloat, side: RGBA) -> some View {
        Circle().fill(palette.color(side))
            // A short shadow, close beneath it.
            .shadow(color: palette.color(side).opacity(palette.colors.opaque ? 0 : 0.5), radius: d * 0.03,
                    y: d * 0.035)
    }

    /// Under the thumb while it is held to talk: a disc of light, brightest toward its fine rim.
    private func touchZone(_ d: CGFloat) -> some View {
        let light = palette.color(palette.colors.micAura)
        return ZStack {
            Circle().fill(RadialGradient(colors: [light.opacity(0.08), light.opacity(0.32)], center: .center,
                                         startRadius: 0, endRadius: d / 2))
            if !palette.colors.opaque {
                Circle().strokeBorder(light.opacity(0.55), lineWidth: d * 0.08)
                    .blur(radius: d * 0.04)
                    .clipShape(Circle())
                Circle().strokeBorder(.white.opacity(0.85), lineWidth: d * 0.02)
            }
        }
    }

    /// Laid over the face while it is pressed: darker, with the shadow of the base's rim across its
    /// top edge.
    private func pressedIn(_ d: CGFloat, bottom: RGBA) -> some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.1))
            if !palette.colors.opaque {
                Circle().strokeBorder(LinearGradient(colors: [palette.color(bottom).opacity(0.85),
                                                              palette.color(bottom).opacity(0)],
                                                     startPoint: .top, endPoint: .center), lineWidth: d * 0.11)
                    .blur(radius: d * 0.025)
                    .clipShape(Circle())
            }
        }
    }

    private func face(_ d: CGFloat, top: RGBA, bottom: RGBA) -> some View {
        let colors = palette.colors
        // Matte: from its top colour only to its middle one.
        let middle = fill.count > 1 ? fill[fill.count / 2].color : bottom
        return ZStack {
            Circle().fill(LinearGradient(colors: [palette.color(top), palette.color(middle)],
                                         startPoint: .top, endPoint: .bottom))
            if !colors.opaque {
                // A soft pillow of light.
                Ellipse()
                    .fill(RadialGradient(colors: [.white.opacity(0.26), .white.opacity(0)], center: .center,
                                         startRadius: 0, endRadius: d * 0.34))
                    .frame(width: d * 0.78, height: d * 0.5)
                    .offset(y: -d * 0.17)
                // The bevel: light along the top, shaded along the bottom.
                Circle().strokeBorder(LinearGradient(colors: [palette.color(RGBA.mix(top, RGBA(0xFFFFFF), 0.4)),
                                                              palette.color(top).opacity(0)],
                                                     startPoint: .top, endPoint: .center), lineWidth: d * 0.065)
                Circle().strokeBorder(LinearGradient(colors: [palette.color(bottom).opacity(0),
                                                              palette.color(bottom).opacity(0.7)],
                                                     startPoint: .center, endPoint: .bottom), lineWidth: d * 0.06)
            }
            if colors.bubbleStrokeAlpha > 0 {
                Circle().strokeBorder(Color.primary.opacity(colors.bubbleStrokeAlpha), lineWidth: d / diameter)
            }
        }
    }

    /// A soft spot of light on the bevel, at the top left, or travelling round it.
    private struct RimGlint: View {
        let diameter: CGFloat
        let resolution: CGFloat
        let color: Color
        let travelling: Bool
        @State private var angle = 0.0

        var body: some View {
            let d = diameter * resolution
            let glint = AngularGradient(stops: [.init(color: color.opacity(0), location: 0),
                                                .init(color: color, location: 0.09),
                                                .init(color: color.opacity(0), location: 0.2),
                                                .init(color: color.opacity(0), location: 1)],
                                        center: .center, angle: .degrees(-135))
            ZStack {
                // Its bloom, then the glint itself.
                Circle().strokeBorder(glint, lineWidth: d * 0.08).blur(radius: d * 0.025).opacity(0.6)
                Circle().strokeBorder(glint, lineWidth: d * 0.045)
            }
                .frame(width: d, height: d)
                .padding(d * 0.1)
                .drawingGroup()
                .scaleEffect(1 / resolution)
                .frame(width: diameter, height: diameter)
                // Turned as a whole, so travelling never redraws it.
                .rotationEffect(.degrees(angle))
                .onAppear { travel(travelling) }
                .onChange(of: travelling) { _, travelling in travel(travelling) }
                .allowsHitTesting(false)
        }

        private func travel(_ travelling: Bool) {
            if travelling {
                angle = 0
                withAnimation(.linear(duration: 4.5).repeatForever(autoreverses: false)) { angle = 360 }
            } else {
                withAnimation(.easeOut(duration: 0.4)) { angle = 0 }
            }
        }
    }
}

/// Light around the microphone. Inviting a press, a ring pings out from it every couple of
/// seconds. Listening, a halo glows around it, brighter and wider as the human speaks, and waves
/// of their voice leave its edge (`VoiceWaves`), so under a thumb the voice seems to pour out from
/// beneath it. Reduce Motion holds the halo still without waves; Reduce Transparency leaves one
/// solid ring.
private struct MicrophoneAura: View {
    enum Mode { case none, inviting, listening }

    let mode: Mode
    let level: Double
    let palette: StagePalette
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The input levels over which the voice comes in: a quiet room stays below the first, speech
    /// reaches past the second.
    private static let voice = (quiet: 0.08, loud: 0.4)

    var body: some View {
        let light = palette.color(palette.colors.micAura)
        let heard = mode == .listening && level.isFinite ? RigMath.smoothstep(Self.voice.quiet, Self.voice.loud, level) : 0
        ZStack {
            switch mode {
            case .none:
                EmptyView()
            case .inviting:
                if !reduceMotion && !reduceTransparency {
                    Circle()
                        .fill(RadialGradient(colors: [light.opacity(0.6), light.opacity(0)], center: .center,
                                             startRadius: diameter * 0.4, endRadius: diameter * 0.85))
                        .frame(width: diameter * 1.8, height: diameter * 1.8)
                        .drawingGroup()
                        .phaseAnimator([0.35, 1]) { content, glow in content.opacity(glow) }
                            animation: { _ in .easeInOut(duration: 1.3) }
                    Ping(color: light, period: 2.6, reach: 1.8, width: 2.5)
                        .frame(width: diameter, height: diameter)
                }
            case .listening:
                if reduceTransparency {
                    Circle().fill(light).padding(-(5 + 10 * heard))
                } else {
                    // The halo, and a ring that follows the voice.
                    ZStack {
                        Circle()
                            .fill(RadialGradient(stops: [.init(color: light.opacity(0), location: 0),
                                                         .init(color: light.opacity(0), location: 0.3),
                                                         .init(color: light.opacity(0.7), location: 0.45),
                                                         .init(color: light.opacity(0.25), location: 0.62),
                                                         .init(color: light.opacity(0), location: 1)],
                                                 center: .center, startRadius: 0,
                                                 endRadius: diameter * (1.1 + 0.3 * heard)))
                        Circle().strokeBorder(light.opacity(0.5 + 0.3 * heard), lineWidth: 4 + diameter * 0.12 * heard)
                            .frame(width: diameter + 2 * (4 + diameter * 0.2 * (reduceMotion ? 0.5 : heard)))
                            .blur(radius: 1.5)
                    }
                    .frame(width: diameter * 2.6, height: diameter * 2.6)
                    .drawingGroup()
                    if !reduceMotion { VoiceWaves(heard: heard, color: light, diameter: diameter) }
                }
            }
        }
        // Light adds to the stage behind it, so it glows over either half instead of greying it.
        .blendMode(reduceTransparency ? .normal : .plusLighter)
        .animation(.easeOut(duration: 0.12), value: heard)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Waves of the human's voice: a slightly wobbly ring leaves the button's edge with each beat
    /// of speech, more often and stronger as they speak up, now and then while they are quiet, and
    /// spreads out and fades.
    private struct VoiceWaves: View {
        let heard: Double
        let color: Color
        let diameter: CGFloat
        @State private var train = WaveTrain()

        var body: some View {
            TimelineView(.animation) { timeline in
                let now = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                    for wave in train.waves where now >= wave.born && now - wave.born < WaveTrain.life {
                        let age = (now - wave.born) / WaveTrain.life
                        let spread = 1 - pow(1 - age, 2.2)
                        let radius = diameter / 2 * (1 + 1.3 * spread)
                        let wobble = diameter * 0.04 * wave.strength * (1 - age)
                        var path = Path()
                        for step in 0...96 {
                            let theta = Double(step) / 96 * 2 * .pi
                            let r = radius + wobble * sin(7 * theta + wave.phase + age * 5)
                            let point = CGPoint(x: centre.x + r * cos(theta), y: centre.y + r * sin(theta))
                            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                        path.closeSubpath()
                        context.stroke(path, with: .color(color.opacity((1 - age) * (0.5 + 0.5 * wave.strength))),
                                       lineWidth: (2 + 3.5 * wave.strength) * (1 - 0.5 * age))
                    }
                }
            }
            .frame(width: diameter * 3, height: diameter * 3)
            .onChange(of: heard, initial: true) { _, heard in train.heard = heard }
            .task {
                while !Task.isCancelled {
                    train.emit(at: Date.timeIntervalSinceReferenceDate)
                    try? await Task.sleep(for: .seconds(train.interval))
                }
            }
        }
    }

    @MainActor
    private final class WaveTrain {
        struct Wave {
            let born: Double
            let strength: Double
            let phase: Double
        }

        /// Seconds a wave takes to spread out and fade.
        static let life = 1.1
        private(set) var waves: [Wave] = []
        var heard = 0.0

        /// Seconds until the next wave: often while the human speaks up, now and then when quiet.
        var interval: Double { RigMath.mix(0.55, 0.15, heard) }

        func emit(at now: Double) {
            waves.removeAll { now - $0.born >= Self.life }
            waves.append(Wave(born: now, strength: heard, phase: .random(in: 0..<(2 * .pi))))
        }
    }

    /// A ring that spreads out to `reach` times the button and fades, over and over.
    private struct Ping: View {
        let color: Color
        let period: Double
        let reach: CGFloat
        let width: CGFloat
        var delay = 0.0
        @State private var spread = false

        var body: some View {
            Circle().strokeBorder(color, lineWidth: width)
                .scaleEffect(spread ? reach : 1)
                .opacity(spread ? 0 : 0.9)
                .onAppear {
                    withAnimation(.easeOut(duration: period).repeatForever(autoreverses: false).delay(delay)) {
                        spread = true
                    }
                }
        }
    }
}

/// "Hold to talk", above the microphone for a moment after it is tapped rather than held.
struct HoldToTalkHint: View {
    let palette: StagePalette

    var body: some View {
        let colors = palette.colors
        Text("Hold to talk")
            .font(.subheadline.weight(.semibold)).fontDesign(.rounded)
            .foregroundStyle(palette.color(colors.bannerText))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .softGlass(Capsule(), tint: colors.bannerTint, kind: .caption, palette: palette)
            .fixedSize()
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A press squeezes the whole button, glyph and glass together.
private struct VoicePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Three dots rising and falling in turn while a character writes their next line.
struct ThinkingDots: View {
    let color: Color
    var dotSize: CGFloat = 8
    var spacing: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { context in
            HStack(spacing: spacing) {
                ForEach(0..<3) { index in
                    let wave = reduceMotion ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate * 4 - Double(index) * 0.9) + 1) / 2
                    Circle().fill(color.opacity(0.35 + wave * 0.65))
                        .frame(width: dotSize, height: dotSize)
                        .offset(y: reduceMotion ? 0 : -wave * dotSize * 0.375)
                }
            }
        }
        .frame(height: dotSize * 1.75)
        .accessibilityHidden(true)
    }
}

/// The logo over the launch intro (`StageIntro.logo`): it drops in from above with a bounce,
/// holds in the middle of the screen, then slides back up and fades. Reduce Motion skips the
/// intro and its logo; turned on while the logo is up, it fades the logo where it rests.
struct IntroLogo: View {
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The warm cream glow behind it, which sets it apart from the stage.
    private static let glow = Color(red: 1, green: 0.97, blue: 0.86)

    var body: some View {
        // It drops in on a bouncy spring, already opaque; it leaves sliding and fading together.
        let exit = Animation.easeIn(duration: reduceMotion ? 0.3 : StageIntro.logo.exit)
        let drop = shown ? Animation.spring(response: 0.6, dampingFraction: 0.55) : exit
        let fade = shown ? Animation.easeOut(duration: reduceMotion ? 0.3 : 0.15) : exit
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.9, 480)
            ZStack {
                Ellipse()
                    .fill(EllipticalGradient(colors: [Self.glow.opacity(0.9), Self.glow.opacity(0.55), Self.glow.opacity(0)],
                                             center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                    .frame(width: width * 1.25, height: width * 0.78)
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: width)
                    .shadow(color: Self.glow.opacity(0.9), radius: 10)
            }
            // Rendered once, so its moves and fades only move and fade it: drawn as it moves, the
            // gradient and shadow would be rasterized again on every frame.
            .drawingGroup()
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .offset(y: shown || reduceMotion ? 0 : -proxy.size.height)
            .animation(drop, value: shown)
            .opacity(shown ? 1 : 0)
            .animation(fade, value: shown)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

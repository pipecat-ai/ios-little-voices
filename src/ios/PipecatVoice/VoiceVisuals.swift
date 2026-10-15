import SwiftUI

enum VoicePalette {
    /// Settings' accent, lighter in dark mode so it stays legible on the toolbar's glass.
    static let blue = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.42, green: 0.66, blue: 1, alpha: 1)
        : UIColor(red: 0.08, green: 0.36, blue: 0.87, alpha: 1) })
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

/// The dock's microphone: teal, or red while muted, with `MicrophonePulse`'s rings while the
/// human speaks.
struct MicrophoneControl: View {
    let level: Double
    let muted: Bool
    let connecting: Bool
    let active: Bool
    let palette: StagePalette
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let diameter: CGFloat = 76
    private var fill: [GradientStop] {
        connecting ? palette.colors.micLoadingFill : muted ? palette.colors.micMutedFill : palette.colors.micFill
    }
    private var listening: Bool { active && !muted && !connecting }
    private var title: String {
        connecting ? "Connecting" : !active ? "Start conversation" : muted ? "Unmute microphone" : "Mute microphone"
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(gradient: palette.gradient(fill), startPoint: .top, endPoint: .bottom))
                // A sheen across the top in place of a rim.
                if !palette.colors.opaque {
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.3), .white.opacity(0)],
                                                 center: UnitPoint(x: 0.5, y: 0.06), startRadius: 0,
                                                 endRadius: Self.diameter * 0.58))
                }
                if palette.colors.bubbleStrokeAlpha > 0 {
                    Circle().strokeBorder(Color.primary.opacity(palette.colors.bubbleStrokeAlpha), lineWidth: 1)
                }
                if connecting {
                    ProgressView().tint(.white).controlSize(.regular).scaleEffect(1.15)
                } else {
                    Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: Self.diameter * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }.frame(width: Self.diameter, height: Self.diameter)
                .shadow(color: palette.color(fill.last?.color ?? RGBA(0x0B7A62)).opacity(palette.colors.opaque ? 0 : 0.18),
                        radius: 10, y: 4)
                .background { MicrophonePulse(listening: listening, level: level, palette: palette) }
                .contentShape(Circle())
        }
        .buttonStyle(VoicePressStyle())
        .disabled(connecting)
        .accessibilityLabel(title)
        .accessibilityValue(connecting ? "Please wait" : !active ? "Ready" : muted ? "Muted" : "Microphone on")
        .accessibilityHint(connecting ? "" : !active ? "Starts a conversation with the angel and the devil."
            : muted ? "Turns your microphone back on." : "Pauses your microphone.")
        .accessibilityShowsLargeContentViewer { Label(title, systemImage: muted ? "mic.slash.fill" : "mic.fill") }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: muted)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: connecting)
    }
}

/// Rings around the microphone, only while the human speaks: two halos that grow with the voice
/// and two discs rippling out. Reduce Motion holds them still; Reduce Transparency leaves one
/// solid ring.
private struct MicrophonePulse: View {
    let listening: Bool
    let level: Double
    let palette: StagePalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var rippling = false

    /// Seconds for one ripple to spread and fade.
    private static let period = 1.8
    /// The input levels over which the rings come in: a quiet room stays below the first,
    /// speech reaches past the second.
    private static let voice = (quiet: 0.1, loud: 0.35)

    var body: some View {
        let ring = palette.color(palette.colors.micGlow)
        let heard = listening && level.isFinite ? RigMath.smoothstep(Self.voice.quiet, Self.voice.loud, level) : 0
        let grow = reduceMotion ? 1 : heard
        ZStack {
            if !reduceTransparency {
                ForEach(0..<2, id: \.self) { index in
                    Circle().fill(ring)
                        .scaleEffect(reduceMotion ? 1.25 + 0.25 * Double(index) : rippling ? 1.75 : 1)
                        .opacity(reduceMotion ? 0.8 - 0.35 * Double(index) : rippling ? 0 : 1)
                        .animation(reduceMotion ? nil : .easeOut(duration: Self.period).repeatForever(autoreverses: false)
                            .delay(Double(index) * Self.period / 2), value: rippling)
                }
                .opacity(heard > 0 ? 1 : 0)
                Circle().fill(ring.opacity(0.4))
                    .padding(-(12 + 20 * grow))
                    .blur(radius: 2)
                    .opacity(heard)
            }
            Circle().fill(ring.opacity(reduceTransparency ? 1 : 0.8))
                .padding(-(3 + 11 * grow))
                .blur(radius: reduceTransparency ? 0 : 1.5)
                .opacity(heard)
        }
        .animation(.easeOut(duration: 0.25), value: heard)
        .onAppear { rippling = listening }
        .onChange(of: listening) { rippling = $1 }
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
/// holds in the middle of the screen, then slides back up and fades. Under Reduce Motion it fades
/// in and out where it rests.
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
            let width = min(proxy.size.width * 0.98, 520)
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

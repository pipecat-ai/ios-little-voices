import SwiftUI

/// The first launch's welcome, over the stage once the intro has played: the angel and the devil
/// peek over a cream card that says who they are and how to talk to them. Once dismissed, it never
/// shows again.
struct WelcomeCard: View {
    let palette: StagePalette
    let holdsToTalk: Bool
    let dismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The tips' round wells, which grow with the text, though not past 64 pt.
    @ScaledMetric(relativeTo: .subheadline) private var scaledWell: CGFloat = 46
    private var well: CGFloat { min(scaledWell, 64) }

    private static let key = "welcome-seen"
    /// The characters' art, at its own size, and how much of it, their hands, rests on the card.
    private static let characters = UIImage(named: "WelcomeCharacters")?.size ?? CGSize(width: 300, height: 141)
    private static let handsOnCard = 0.2
    private static let card = RoundedRectangle(cornerRadius: 34, style: .continuous)

    static func seen(defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        // `--welcome` shows it whether or not it has been seen.
        if ProcessInfo.processInfo.arguments.contains("--welcome") { return false }
        #endif
        return defaults.bool(forKey: key)
    }

    static func markSeen(defaults: UserDefaults = .standard) { defaults.set(true, forKey: key) }

    var body: some View {
        // At the largest text sizes, taller than the screen, it scrolls.
        ViewThatFits(in: .vertical) {
            welcome
            ScrollView { welcome.padding(.vertical, 16) }
                .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { AccessibilityNotification.ScreenChanged(nil).post() }
    }

    private var welcome: some View {
        let hands = Self.characters.height * Self.handsOnCard
        return VStack(spacing: -hands) {
            Image("WelcomeCharacters")
                .accessibilityHidden(true)
                .zIndex(1)
            content
                .padding(.top, hands + 8)
                .background { background }
        }
        .frame(maxWidth: 400)
        .padding(.horizontal, 24)
    }

    private var content: some View {
        VStack(spacing: 18) {
            title
            // “they think” is held together, so the last line is never one word.
            Text("Your little angel and devil are on your shoulder, ready to share their opinions! Ask them a "
                 + "question and hear what they\u{00A0}think.")
                .font(.body)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                tip(holdsToTalk ? "Hold the microphone while you talk, and let go when you’re done."
                                : "Tap the microphone, then just talk.", symbol: "mic.fill")
                tip("Say “Angel” or “Devil” to ask just one of them.", symbol: "bubble.left.and.bubble.right.fill")
            }
            Button("Let’s go", action: dismiss)
                .buttonStyle(ChunkyCapsuleStyle(palette: palette))
                .padding(.top, 4)
        }
        .fontDesign(.rounded)
        .foregroundStyle(palette.color(WelcomeColors.text))
        .fixedSize(horizontal: false, vertical: true)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, 20)
        .padding(.bottom, 22)
    }

    /// The title's flares fit beside it up to this text size.
    private var flared: Bool { typeSize <= .xLarge }

    /// The title, with a flare of marks to either side while there is room for them.
    private var title: some View {
        HStack(spacing: 8) {
            if flared { TitleFlare(color: palette.color(WelcomeColors.flare)).scaleEffect(x: -1) }
            Text("Meet your\nlittle voices")
                .font(.largeTitle.weight(.black))
                .lineHeight(.multiple(factor: 0.92))
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.color(WelcomeColors.title))
                .accessibilityAddTraits(.isHeader)
            if flared { TitleFlare(color: palette.color(WelcomeColors.flare)) }
        }
    }

    private func tip(_ text: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.color(palette.colors.micFill.last?.color ?? RGBA(0x0B7A62)))
                .frame(width: well, height: well)
                .background {
                    Circle()
                        .fill(LinearGradient(colors: WelcomeColors.well.map(palette.color), startPoint: .top,
                                             endPoint: .bottom))
                        .shadow(color: palette.color(WelcomeColors.shadow).opacity(0.12), radius: 2, y: 1)
                }
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .padding(.trailing, 8)
        .background {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            shape.fill(palette.color(WelcomeColors.tip))
                .overlay { outline(shape) }
        }
    }

    /// The card: cream, lighter at the top, with a soft light along its upper edge and a shadow.
    /// Under Reduce Transparency it has neither; under Increase Contrast, an outline.
    private var background: some View {
        let colors = palette.colors
        return Self.card
            .fill(LinearGradient(colors: WelcomeColors.card.map(palette.color), startPoint: .top, endPoint: .bottom))
            .shadow(color: colors.bubbleShadow == nil ? .clear : palette.color(WelcomeColors.shadow).opacity(0.28),
                    radius: 28, y: 12)
            .overlay {
                if let light = colors.glassEdgeLight {
                    Self.card.strokeBorder(LinearGradient(colors: [palette.color(light.alpha(0.9)), .clear],
                                                          startPoint: .top, endPoint: .center), lineWidth: 2)
                }
            }
            .overlay { outline(Self.card) }
    }

    @ViewBuilder
    private func outline<S: InsettableShape>(_ shape: S) -> some View {
        if palette.colors.bubbleStrokeAlpha > 0 {
            shape.strokeBorder(Color.primary.opacity(palette.colors.bubbleStrokeAlpha), lineWidth: 1)
        }
    }
}

/// The welcome's own colours, from the warm creams and browns of the stage.
private enum WelcomeColors {
    /// The card, top to bottom, and the tips' rows on it, a shade more peach.
    static let card = [RGBA(0xFFF6E6), RGBA(0xFDEDCF)]
    static let tip = RGBA(0xFBE3C5)
    /// The round well behind each tip's symbol, lit from above.
    static let well = [RGBA(0xFFF8EC), RGBA(0xFDEBD2)]
    static let title = RGBA(0x541710)
    static let text = RGBA(0x45180C)
    static let flare = RGBA(0xFDC83F)
    static let shadow = RGBA(0x5A2200)
}

/// Two marks flaring out from beside the title, like those around the characters on the stage:
/// one up and out, one out. Drawn for the title's right; mirrored for its left.
private struct TitleFlare: View {
    let color: Color
    @ScaledMetric(relativeTo: .largeTitle) private var width: CGFloat = 24

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var marks = Path()
            marks.move(to: CGPoint(x: 0.14 * w, y: 0.42 * h))
            marks.addLine(to: CGPoint(x: 0.56 * w, y: 0.12 * h))
            marks.move(to: CGPoint(x: 0.22 * w, y: 0.78 * h))
            marks.addLine(to: CGPoint(x: 0.86 * w, y: 0.7 * h))
            context.stroke(marks, with: .color(color), style: StrokeStyle(lineWidth: 0.22 * w, lineCap: .round))
        }
        .frame(width: width, height: width * 1.15)
        .accessibilityHidden(true)
    }
}

/// A chunky teal capsule like the microphone: its face on a darker base, clicking down when pressed.
private struct ChunkyCapsuleStyle: ButtonStyle {
    let palette: StagePalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let fill = palette.colors.micFill
        let bottom = fill.last?.color ?? RGBA(0x0B7A62)
        let pressed = configuration.isPressed && !reduceMotion
        let depth: CGFloat = 6
        configuration.label
            .font(.title2.weight(.heavy))
            .foregroundStyle(.white)
            .shadow(color: palette.color(RGBA.mix(bottom, RGBA(0x000000), 0.3)).opacity(0.35), radius: 0, y: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background {
                Capsule().fill(LinearGradient(colors: [palette.color(fill.first?.color ?? RGBA(0x36C7A0)),
                                                       palette.color(fill[fill.count / 2].color)],
                                              startPoint: .top, endPoint: .bottom))
            }
            .offset(y: pressed ? 0 : -depth / 2)
            .background {
                Capsule().fill(palette.color(RGBA.mix(bottom, RGBA(0x000000), 0.3)))
                    .offset(y: depth / 2)
            }
            .animation(pressed ? .spring(response: 0.1, dampingFraction: 0.9)
                       : .spring(response: 0.3, dampingFraction: 0.5), value: pressed)
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.7), trigger: configuration.isPressed) { _, pressed in
                pressed
            }
    }
}

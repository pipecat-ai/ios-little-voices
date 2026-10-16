import SwiftUI

/// The first launch's welcome, over the stage once the intro has played: who the angel and the
/// devil are and how to talk to them. Once dismissed, it never shows again.
struct WelcomeCard: View {
    let palette: StagePalette
    let holdsToTalk: Bool
    let dismiss: () -> Void

    private static let key = "welcome-seen"

    static func seen(defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        // `--welcome` shows it whether or not it has been seen.
        if ProcessInfo.processInfo.arguments.contains("--welcome") { return false }
        #endif
        return defaults.bool(forKey: key)
    }

    static func markSeen(defaults: UserDefaults = .standard) { defaults.set(true, forKey: key) }

    var body: some View {
        let colors = palette.colors
        VStack(alignment: .leading, spacing: 16) {
            Text("Meet your little voices")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("Your little angel and devil are on your shoulder, ready to share their opinions! Ask them a "
                 + "question and hear what they think.")
                .font(.body)
            VStack(alignment: .leading, spacing: 12) {
                tip(holdsToTalk ? "Hold the microphone while you talk, and let go when you’re done."
                                : "Tap the microphone, then just talk.", symbol: "mic.fill")
                tip("Say “Angel” or “Devil” to ask just one of them.", symbol: "bubble.left.and.bubble.right.fill")
            }
            Button("Let’s go", action: dismiss)
                .buttonStyle(ChunkyCapsuleStyle(palette: palette))
                .padding(.top, 4)
        }
        .fontDesign(.rounded)
        .foregroundStyle(palette.color(colors.bannerText))
        .fixedSize(horizontal: false, vertical: true)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(24)
        .frame(maxWidth: 400)
        .softGlass(RoundedRectangle(cornerRadius: 30, style: .continuous), tint: colors.bannerTint, kind: .caption,
                   palette: palette, shadowRadius: 24)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { AccessibilityNotification.ScreenChanged(nil).post() }
    }

    private func tip(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.color(palette.colors.micFill.last?.color ?? RGBA(0x0B7A62)))
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text).font(.subheadline.weight(.medium))
        }
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
        let depth: CGFloat = 5
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
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

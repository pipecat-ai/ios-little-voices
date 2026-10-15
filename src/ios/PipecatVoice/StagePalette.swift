import SwiftUI

/// The stage's colours for an environment: `StageColors` resolved from Increase Contrast and
/// Reduce Transparency, as SwiftUI colours and gradients.
struct StagePalette: Equatable, Sendable {
    let colors: StageColors

    init(contrast: ColorSchemeContrast, reduceTransparency: Bool) {
        colors = StageColors.resolve(reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased)
    }

    func color(_ c: RGBA) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }

    func gradient(_ stops: [GradientStop]) -> Gradient {
        Gradient(stops: stops.map { Gradient.Stop(color: color($0.color), location: $0.location) })
    }

    /// A character's ink: features, outlines and the mouth's cavity.
    func ink(for c: DuoCharacter) -> Color { color(colors.ink[c]) }

    /// A character's typing dots.
    func dots(for c: DuoCharacter) -> Color { color(colors.dots[c]) }

    /// What the glow sprite depends on.
    var glowKey: GlowSprites.Key.Style {
        GlowSprites.Key.Style(color: colors.haloGlow ?? RGBA(0xFFFFFF, alpha: 0), blurFu: colors.haloGlowBlurFu)
    }
}

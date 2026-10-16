import Foundation

/// A non-premultiplied sRGB colour, components in 0…1.
struct RGBA: Equatable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// From `0xRRGGBB`.
    init(_ hex: UInt32, alpha: Double = 1) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255,
                  b: Double(hex & 0xFF) / 255, a: alpha)
    }

    func alpha(_ a: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: a) }

    /// Mixes component-wise in sRGB (as the Canvas's non-linear gradients do).
    static func mix(_ x: RGBA, _ y: RGBA, _ t: Double) -> RGBA {
        RGBA(r: RigMath.mix(x.r, y.r, t), g: RigMath.mix(x.g, y.g, t),
             b: RigMath.mix(x.b, y.b, t), a: RigMath.mix(x.a, y.a, t))
    }

    /// WCAG 2 relative luminance (alpha ignored).
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

/// How a glass surface's tint grades from its top edge to its bottom edge, as multiples of the
/// tint's alpha: lighter and denser at the top, thinner toward the bottom.
struct GlassGrade: Equatable, Sendable {
    var top: Double
    var bottom: Double

    static let flat = GlassGrade(top: 1, bottom: 1)

    /// `tint` at `position`, from 0 (the top edge) to 1 (the bottom edge).
    func tint(_ tint: RGBA, at position: Double) -> RGBA {
        tint.alpha(min(1, tint.a * RigMath.mix(top, bottom, position)))
    }
}

/// A gradient stop: `location` in 0…1 along the gradient.
struct GradientStop: Equatable, Sendable {
    var location: Double
    var color: RGBA

    init(_ location: Double, _ color: RGBA) {
        self.location = location
        self.color = color
    }
}

/// One value for each character.
struct PerCharacter<Value: Sendable>: Sendable {
    var angel: Value
    var devil: Value

    subscript(_ character: DuoCharacter) -> Value {
        get { character == .angel ? angel : devil }
        _modify {
            if character == .angel { yield &angel } else { yield &devil }
        }
    }

    func map<T: Sendable>(_ transform: (DuoCharacter, Value) -> T) -> PerCharacter<T> {
        PerCharacter<T>(angel: transform(.angel, angel), devil: transform(.devil, devil))
    }
}

extension PerCharacter: Equatable where Value: Equatable {}

/// The stage's colours as plain RGBA tables, plus the Reduce Transparency and Increase Contrast
/// variants. `StagePalette` turns these into SwiftUI colours; the contrast checks read them
/// directly.
struct StageColors: Equatable, Sendable {
    /// The angel's half: an elliptical radial about her eye midpoint + (0, −120 fu), at her halo,
    /// radii 1 × 1.05 stage widths. A pale glow about her halo and face turns a deeper yellow
    /// toward the sides and the top, and gold toward the seam.
    var angelHalf: [GradientStop]
    /// The devil's half: an elliptical radial about his eye midpoint + (0, −50 fu), radii
    /// 1.04 × 0.85 stage widths. A bright orange behind his face turns red-orange at the sides
    /// and deep red toward the bottom and its corners.
    var devilHalf: [GradientStop]
    /// Ink strokes and fills; also the mouth cavity.
    var ink: PerCharacter<RGBA>
    var tongue: PerCharacter<RGBA>
    /// Blush, drawn with a soft edge: the angel's a warm glow, the devil's a peach a little
    /// lighter than his skin.
    var blush: PerCharacter<RGBA>
    var highlight: PerCharacter<RGBA>
    var sclera: PerCharacter<RGBA>
    /// The lid's soft shade over the top of the devil's eye whites, fading out downward.
    var devilScleraShade: RGBA
    var fang: RGBA
    var haloRing: RGBA
    /// The pre-rendered halo glow; nil draws no sprite (Reduce Transparency).
    var haloGlow: RGBA?
    var haloGlowBlurFu: Double
    /// A crisp outline replacing the glow under Reduce Transparency.
    var haloOutline: RGBA?
    /// Wing fill from the hinge out to the tip: palest by the hinge, a warmer cream at the tip.
    var wingFill: [GradientStop]
    /// Horn fill, radial from the inner base corner (`HornShape.shadeCenter`) outward: warm
    /// maroon low down to dark brown at the tip.
    var horn: [GradientStop]
    /// The glossy shine along each horn's outer curve at full strength; the renderer fades it.
    var hornShine: RGBA
    var angelDashes: RGBA
    var devilMotionMarks: RGBA
    /// The anger vein (💢).
    var devilAngerVein: RGBA
    /// The dominant region's rim strokes, clipped inside the region, in drawing order: the
    /// angel's 24·s and 12·s wide, the devil's one stroke. Each colour carries its stroke's
    /// final alpha; the renderer draws them as they are.
    var rim: PerCharacter<[RGBA]>
    /// The contact shadow on the recessive side, keyed by the dominant character.
    var contactShadow: PerCharacter<RGBA>
    /// Replaces the shadow strokes with one opaque 2-pt line (Reduce Transparency), keyed by
    /// the dominant character.
    var contactLine: PerCharacter<RGBA>?
    /// The seam's soft edge at rest, stroked along the seam inside each character's own half,
    /// widest first (`StageRenderer.seamGlowWidths`): the angel's warm glow and the devil's faint
    /// shade, the strokes' overlap ramping up toward the seam. They give way to the rim and the
    /// contact shadow while someone holds the floor.
    var seamGlow: PerCharacter<[RGBA]>
    /// The typing dots.
    var dots: PerCharacter<RGBA>
    /// The tint of each character's soft glass caption bubble and typing capsule: the angel's
    /// cream, nearly opaque, and the devil's translucent peach. Under Reduce Transparency each is
    /// opaque, mixed over its half.
    var bubbleTint: PerCharacter<RGBA>
    /// The human's pill, between the halves.
    var pillTint: RGBA
    /// The human's words on the pill: final, and still being recognized.
    var pillText: RGBA
    var pillPendingText: RGBA
    /// Caption text: each character's ink on their bubble.
    var bubbleText: PerCharacter<RGBA>
    /// The error banner above the dock: its glass, its text and its alert glyph.
    var bannerTint: RGBA
    var bannerText: RGBA
    var bannerGlyph: RGBA
    /// The soft drop shadow under the bubbles, the pill, the banner and the header's buttons;
    /// nil draws none (Reduce Transparency).
    var bubbleShadow: RGBA?
    /// A 1-pt `.primary` stroke on every glass surface (Increase Contrast), as an alpha.
    var bubbleStrokeAlpha: Double
    /// The soft light along the upper edge of every glass surface, fading out by its middle; nil
    /// draws none (Reduce Transparency).
    var glassEdgeLight: RGBA?
    /// How the glass grades from top to bottom: the chrome's (the header's buttons, the dock
    /// and its side buttons) and the captions' (bubbles, capsules, the pill and the banner),
    /// gentler, as text sits on them. Flat under Increase Contrast and Reduce Transparency.
    var chromeGrade: GlassGrade
    var captionGrade: GlassGrade
    /// The chrome's glass tints, at the middle of their grade: the header's buttons over the
    /// angel's half, the dock over the devil's. Under Reduce Transparency they are opaque.
    var chromeGlass: PerCharacter<RGBA>
    /// The chrome's glyphs over each half.
    var chromeGlyph: PerCharacter<RGBA>
    /// The dock's round side buttons, a lighter soft glass inside the dock.
    var dockButton: RGBA
    /// The microphone button, top to bottom, deepening toward the bottom: teal-green, red while
    /// muted, and a warm gray while the app loads or a conversation starts.
    var micFill: [GradientStop]
    var micMutedFill: [GradientStop]
    var micLoadingFill: [GradientStop]
    /// The light around the microphone button while it invites a press or hears the human: its
    /// halo and the rings rippling from it.
    var micAura: RGBA
    /// Multiplies ink stroke widths.
    var inkStrokeScale: Double
    /// A 2-pt ink line along the seam (Increase Contrast).
    var seamLine: RGBA?
    /// Every colour is opaque and no effect blends (Reduce Transparency).
    var opaque: Bool

    static let light = StageColors(
        angelHalf: [GradientStop(0, RGBA(0xFEEFA2)), GradientStop(0.2, RGBA(0xFDEA96)),
                    GradientStop(0.32, RGBA(0xFDE385)), GradientStop(0.5, RGBA(0xFDDD78)),
                    GradientStop(0.62, RGBA(0xFCD666)), GradientStop(0.8, RGBA(0xFCCF58)),
                    GradientStop(1, RGBA(0xF8C24A))],
        devilHalf: [GradientStop(0, RGBA(0xFC8C1E)), GradientStop(0.15, RGBA(0xF97A1B)),
                    GradientStop(0.31, RGBA(0xF45815)), GradientStop(0.48, RGBA(0xEE4A16)),
                    GradientStop(0.66, RGBA(0xD83A17)), GradientStop(0.85, RGBA(0xBE3018)),
                    GradientStop(1, RGBA(0x9A221A))],
        // The devil: thick dark-brown ink, a coral tongue like the angel's, a white fang, warm
        // white highlights, cream-white sclera shaded peach under the lid, and a soft peach blush
        // a little lighter than his skin.
        ink: PerCharacter(angel: RGBA(0x2A1206), devil: RGBA(0x200A03)),
        tongue: PerCharacter(angel: RGBA(0xEE6E4D), devil: RGBA(0xEE6E4D)),
        blush: PerCharacter(angel: RGBA(0xFDCB63, alpha: 0.75), devil: RGBA(0xFFA27A, alpha: 0.46)),
        highlight: PerCharacter(angel: RGBA(0xFFFFFF), devil: RGBA(0xFFF6E8)),
        sclera: PerCharacter(angel: RGBA(0xFFFFFF), devil: RGBA(0xFFF6E2)),
        devilScleraShade: RGBA(0xF6B987, alpha: 0.75),
        fang: RGBA(0xFFFFFF),
        haloRing: RGBA(0xFFFDF4),
        // Warm gold, so the white ring stands out against the angel's yellow.
        haloGlow: RGBA(0xFFD447, alpha: 0.85),
        haloGlowBlurFu: 12,
        haloOutline: nil,
        wingFill: [GradientStop(0, RGBA(0xFDFBE9, alpha: 0.94)), GradientStop(1, RGBA(0xFBF5D7, alpha: 0.9))],
        horn: [GradientStop(0, RGBA(0x6E1F12)), GradientStop(0.25, RGBA(0x58190F)), GradientStop(0.5, RGBA(0x3E120B)),
               GradientStop(0.75, RGBA(0x2F0D07)), GradientStop(1, RGBA(0x2A0B06))],
        hornShine: RGBA(0xD65A30),
        angelDashes: RGBA(0xFFFDF0, alpha: 0.95),
        devilMotionMarks: RGBA(0xFFCE4F),
        devilAngerVein: RGBA(0xC8211A),
        rim: PerCharacter(angel: [RGBA(0xFDC54F, alpha: 0.35), RGBA(0xFDC54F, alpha: 0.5)],
                          devil: [RGBA(0xFF9A3C, alpha: 0.5)]),
        contactShadow: PerCharacter(angel: RGBA(0x8E1E08), devil: RGBA(0xB8902F)),
        contactLine: nil,
        seamGlow: PerCharacter(angel: Array(repeating: RGBA(0xF8B83E, alpha: 0.075), count: 6),
                               devil: Array(repeating: RGBA(0x8E1E08, alpha: 0.022), count: 6)),
        dots: PerCharacter(angel: RGBA(0x2A1206), devil: RGBA(0x311106)),
        bubbleTint: PerCharacter(angel: RGBA(0xFFFAEC, alpha: 0.86), devil: RGBA(0xFFD0BA, alpha: 0.6)),
        pillTint: RGBA(0xFFFAF0, alpha: 0.7),
        pillText: RGBA(0x2A1206),
        pillPendingText: RGBA(0x5C3B22),
        bubbleText: PerCharacter(angel: RGBA(0x2A1206), devil: RGBA(0x311106)),
        bannerTint: RGBA(0xFFF8EC, alpha: 0.94),
        bannerText: RGBA(0x2A1206),
        bannerGlyph: RGBA(0xD2412E),
        bubbleShadow: RGBA(0x7A3A00, alpha: 0.11),
        bubbleStrokeAlpha: 0,
        glassEdgeLight: RGBA(0xFFFFFF, alpha: 0.42),
        chromeGrade: GlassGrade(top: 1.3, bottom: 0.75),
        captionGrade: GlassGrade(top: 1.12, bottom: 0.9),
        chromeGlass: PerCharacter(angel: RGBA(0xFFF4D0, alpha: 0.5), devil: RGBA(0xFFAA5A, alpha: 0.42)),
        chromeGlyph: PerCharacter(angel: RGBA(0x3A2410), devil: RGBA(0x4A1C08)),
        dockButton: RGBA(0xFFE0C4, alpha: 0.38),
        micFill: [GradientStop(0, RGBA(0x36C7A0)), GradientStop(0.5, RGBA(0x19A383)), GradientStop(1, RGBA(0x0B7A62))],
        micMutedFill: [GradientStop(0, RGBA(0xF26A5F)), GradientStop(0.55, RGBA(0xDB4A48)), GradientStop(1, RGBA(0xB22C35))],
        micLoadingFill: [GradientStop(0, RGBA(0xACA298)), GradientStop(0.5, RGBA(0x8E867E)), GradientStop(1, RGBA(0x6B645D))],
        // The button's own aqua, added to the red-orange as light.
        micAura: RGBA(0x4DFFD2, alpha: 0.6),
        inkStrokeScale: 1,
        seamLine: nil,
        opaque: false)

    /// The colours with Increase Contrast and Reduce Transparency applied as set.
    static func resolve(reduceTransparency: Bool, increaseContrast: Bool) -> StageColors {
        var colors = light
        if increaseContrast { colors = colors.increasingContrast() }
        if reduceTransparency { colors = colors.reducingTransparency() }
        return colors
    }

    /// Increase Contrast: ink strokes × 1.2, a 2-pt ink seam line at α 0.4, and denser, evenly
    /// filled glass (bubble, pill and banner tints at least α 0.9, chrome at least 0.7, no
    /// grading, and a 1-pt stroke at α 0.15).
    func increasingContrast() -> StageColors {
        var colors = self
        colors.inkStrokeScale = 1.2
        colors.seamLine = ink.angel.alpha(0.4)
        colors.bubbleTint = bubbleTint.map { _, c in c.alpha(max(c.a, Self.contrastBubbleAlpha)) }
        colors.pillTint = pillTint.alpha(max(pillTint.a, Self.contrastBubbleAlpha))
        colors.bannerTint = bannerTint.alpha(max(bannerTint.a, Self.contrastBubbleAlpha))
        colors.chromeGlass = chromeGlass.map { _, c in c.alpha(max(c.a, 0.7)) }
        colors.dockButton = dockButton.alpha(max(dockButton.a, 0.7))
        colors.chromeGrade = .flat
        colors.captionGrade = .flat
        colors.bubbleStrokeAlpha = 0.15
        return colors
    }

    /// The least opacity of a bubble's tint under Increase Contrast.
    static let contrastBubbleAlpha = 0.9

    /// Reduce Transparency: opaque wings, no glow sprite (a solid ring with a 1.5-fu outline),
    /// blush, marks and rims pre-mixed over the half they sit on, one opaque contact line (ink
    /// mixed 25% into the recessive half), solid bubbles and chrome with no grading, edge light
    /// or shadow. Every colour ends up opaque.
    func reducingTransparency() -> StageColors {
        var colors = self
        let face = PerCharacter(angel: Self.sample(angelHalf, at: 0), devil: Self.sample(devilHalf, at: 0))
        // Between each face and the seam, where the bubbles sit.
        let atSeam = PerCharacter(angel: Self.sample(angelHalf, at: 0.55), devil: Self.sample(devilHalf, at: 0.3))
        let wing = RGBA(0xFFF7E1)
        colors.wingFill = [GradientStop(0, wing), GradientStop(1, wing)]
        colors.haloGlow = nil
        colors.haloOutline = RGBA(0xE8C35A)
        colors.haloRing = Self.composite(haloRing, over: face.angel)
        colors.blush = blush.map { c, color in Self.composite(color, over: face[c]) }
        colors.hornShine = Self.composite(hornShine, over: Self.sample(horn, at: 0.5))
        colors.devilScleraShade = Self.composite(devilScleraShade, over: sclera.devil)
        colors.angelDashes = Self.composite(angelDashes, over: face.angel)
        colors.devilMotionMarks = Self.composite(devilMotionMarks, over: face.devil)
        colors.devilAngerVein = Self.composite(devilAngerVein, over: face.devil)
        // Each rim stroke is pre-mixed over the strokes beneath it, so the opaque bands match
        // the translucent stack.
        colors.rim = rim.map { c, strokes in
            var below = atSeam[c]
            return strokes.map { stroke in
                below = Self.composite(stroke, over: below)
                return below
            }
        }
        colors.contactShadow = contactShadow.map { c, color in
            Self.composite(color, over: atSeam[c == .angel ? .devil : .angel])
        }
        // The soft edge's strokes become opaque bands, each pre-mixed over the ones beneath it.
        colors.seamGlow = seamGlow.map { c, strokes in
            var below = atSeam[c]
            return strokes.map { stroke in
                below = Self.composite(stroke, over: below)
                return below
            }
        }
        // Keyed by the dominant character, so the line lies in the other one's half.
        colors.contactLine = PerCharacter(angel: RGBA.mix(atSeam.devil, ink.devil, 0.25),
                                          devil: RGBA.mix(atSeam.angel, ink.angel, 0.25))
        colors.seamLine = seamLine.map { Self.composite($0, over: atSeam.devil) }
        // The bubbles sit by the seam, the pill on it, the header over the angel's sky and the
        // dock and the banner low in the devil's half; each solid fill is its glass mixed over
        // what it covers.
        colors.bubbleTint = bubbleTint.map { c, color in Self.composite(color, over: atSeam[c]) }
        colors.pillTint = Self.composite(pillTint, over: atSeam.angel)
        colors.bubbleShadow = nil
        colors.glassEdgeLight = nil
        colors.chromeGrade = .flat
        colors.captionGrade = .flat
        // Without its edge light and shadow the solid chrome would sink into its half, so it
        // steps a third of the way toward white to keep its shape.
        let chrome = PerCharacter(angel: Self.sample(angelHalf, at: 0.6), devil: Self.sample(devilHalf, at: 0.6))
        let lift = RGBA(0xFFFFFF)
        colors.chromeGlass = chromeGlass.map { c, color in RGBA.mix(Self.composite(color, over: chrome[c]), lift, 0.35) }
        colors.dockButton = Self.composite(dockButton, over: colors.chromeGlass.devil)
        colors.bannerTint = Self.composite(bannerTint, over: chrome.devil)
        colors.micAura = micAura.alpha(1)
        colors.opaque = true
        return colors
    }

    /// The colour of `stops` at `location`, interpolated in sRGB.
    static func sample(_ stops: [GradientStop], at location: Double) -> RGBA {
        guard let first = stops.first, let last = stops.last else { return RGBA(r: 0, g: 0, b: 0) }
        if location <= first.location { return first.color }
        for (lower, upper) in zip(stops, stops.dropFirst()) where location <= upper.location {
            let t = (location - lower.location) / max(upper.location - lower.location, 1e-12)
            return RGBA.mix(lower.color, upper.color, t)
        }
        return last.color
    }

    /// `top` composited over `bottom` (source-over, non-premultiplied, in sRGB).
    static func composite(_ top: RGBA, over bottom: RGBA) -> RGBA {
        let a = top.a + bottom.a * (1 - top.a)
        guard a > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        func channel(_ t: Double, _ b: Double) -> Double { (t * top.a + b * bottom.a * (1 - top.a)) / a }
        return RGBA(r: channel(top.r, bottom.r), g: channel(top.g, bottom.g), b: channel(top.b, bottom.b), a: a)
    }

    /// The WCAG 2 contrast ratio of two opaque colours, 1…21.
    static func contrast(_ x: RGBA, _ y: RGBA) -> Double {
        let lx = x.luminance, ly = y.luminance
        return (max(lx, ly) + 0.05) / (min(lx, ly) + 0.05)
    }
}

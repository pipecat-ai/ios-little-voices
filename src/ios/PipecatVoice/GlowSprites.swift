import CoreGraphics
import SwiftUI

/// The halo's glow, pre-rendered once per colour and size with CoreGraphics: the ring
/// (`AngelGeometry.haloRing`) filled with a soft shadow of the glow colour, so it glows both
/// outside and into the open middle. The renderer draws it under the halo's transform and the
/// crisp vector ring on top, so no per-frame blur filter runs.
enum GlowSprites {
    struct Key: Hashable, Sendable {
        struct Style: Hashable, Sendable {
            var color: RGBA
            var blurFu: Double
        }

        var style: Style
        /// Pixels per face unit, bucketed to powers of 2^(1/4).
        var bucket: Int

        var pxPerFu: Double { pow(2, Double(bucket) / 4) }
    }

    /// The sprite's size around the halo centre, in face units.
    static func extent(blurFu: Double) -> Vec2 {
        AngelGeometry.haloOuterSize + Vec2(1, 1) * (blurFu * 3)
    }

    static func key(style: Key.Style, pxPerFu: Double) -> Key {
        Key(style: style, bucket: Int((4 * log2(max(pxPerFu, 0.05))).rounded()))
    }

    /// Draws the sprite: a transparent bitmap with the ring and its glow.
    static func render(_ key: Key) -> CGImage? {
        let px = key.pxPerFu
        let size = extent(blurFu: key.style.blurFu)
        let width = max(1, Int((size.x * px).rounded(.up))), height = max(1, Int((size.y * px).rounded(.up)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let c = key.style.color
        let color = CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        let (outer, hole) = AngelGeometry.haloRing()
        func ellipse(_ size: Vec2) -> CGRect {
            CGRect(x: (Double(width) - size.x * px) / 2, y: (Double(height) - size.y * px) / 2,
                   width: size.x * px, height: size.y * px)
        }
        func ring() {
            context.addEllipse(in: ellipse(outer))
            context.addEllipse(in: ellipse(hole))
            context.fillPath(using: .evenOdd)
        }
        context.setFillColor(color)
        context.setShadow(offset: .zero, blur: key.style.blurFu * px, color: color)
        ring()
        // A second, softer pass widens the bloom.
        context.setShadow(offset: .zero, blur: key.style.blurFu * px * 2, color: color.copy(alpha: c.a * 0.6)!)
        ring()
        return context.makeImage()
    }
}

/// The sprites already drawn, by key (about 2 MB at most).
@MainActor
final class GlowSpriteCache {
    static let shared = GlowSpriteCache()
    private var images: [GlowSprites.Key: Image] = [:]

    /// The glow for `palette` at `pxPerFu` (points per fu × display scale), or nil when the
    /// palette draws none (Reduce Transparency).
    func image(for palette: StagePalette, pxPerFu: Double) -> StageGlow? {
        guard palette.colors.haloGlow != nil else { return nil }
        let key = GlowSprites.key(style: palette.glowKey, pxPerFu: pxPerFu)
        if let image = images[key] { return StageGlow(image: image, key: key) }
        guard let cg = GlowSprites.render(key) else { return nil }
        if images.count > 24 { images.removeAll() }
        let image = Image(decorative: cg, scale: 1)
        images[key] = image
        return StageGlow(image: image, key: key)
    }
}

/// A resolved glow sprite and the extent it covers.
struct StageGlow {
    var image: Image
    var key: GlowSprites.Key

    /// The sprite's size in face units.
    var extent: Vec2 { GlowSprites.extent(blurFu: key.style.blurFu) }
}

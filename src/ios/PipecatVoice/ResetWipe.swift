import SwiftUI
import UIKit

/// The screen as it was when New conversation was tapped, wiped away to reveal the reset stage.
struct ResetWipeSnapshot: Identifiable {
    let id = UUID()
    let image: UIImage

    /// The key window as it is drawn now, or nil without one.
    @MainActor static func capture() -> ResetWipeSnapshot? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        guard let window, window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return ResetWipeSnapshot(image: image)
    }
}

/// New conversation's wipe: the old screen drawn away from the top behind a glowing edge that
/// waves like the seam (a fade under Reduce Motion, a plain line under Reduce Transparency).
/// Core Animation runs it, so it keeps its pace while the conversation shuts down on the main
/// thread.
struct ResetWipeView: UIViewRepresentable {
    let snapshot: ResetWipeSnapshot
    let reduceMotion: Bool
    let finished: () -> Void

    func makeUIView(context: Context) -> ResetWipeLayerView {
        let view = ResetWipeLayerView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: ResetWipeLayerView, context: Context) {
        let environment = context.environment
        view.configure(image: snapshot.image, reduceMotion: reduceMotion,
                       reduceTransparency: environment.accessibilityReduceTransparency, finished: finished)
    }
}

/// The old screen, masked below the moving edge, under the edge's glow and line. It starts once
/// it has its size.
final class ResetWipeLayerView: UIView {
    private let screen = CALayer()
    private let remainder = CAShapeLayer()
    private let glow = CALayer()
    private let line = CAShapeLayer()
    private var image: UIImage?
    private var reduceMotion = false
    private var reduceTransparency = false
    private var finished: () -> Void = {}
    private var started = false

    /// Seconds for the edge to cross the screen.
    private static let duration = 0.75
    /// The edge's waves: their height, and how many span the screen's width.
    private static let amplitude: CGFloat = 16
    private static let wavesAcross: CGFloat = 1.2
    /// How far the waves roll sideways while the edge crosses the screen, in wavelengths.
    private static let roll: CGFloat = 0.75

    func configure(image: UIImage, reduceMotion: Bool, reduceTransparency: Bool, finished: @escaping () -> Void) {
        self.image = image
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.finished = finished
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !started, let image, bounds.width > 0, bounds.height > 0 else { return }
        started = true
        start(image: image)
    }

    private func start(image: UIImage) {
        let width = bounds.width, height = bounds.height
        let amplitude = Self.amplitude, wavelength = width / Self.wavesAcross
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screen.contents = image.cgImage
        screen.contentsScale = image.scale
        screen.contentsGravity = .resize
        screen.frame = bounds
        layer.addSublayer(screen)
        let ending = CABasicAnimation()
        var animated: [CALayer] = []
        if reduceMotion {
            ending.keyPath = "opacity"
            ending.fromValue = 1
            ending.toValue = 0
            ending.duration = 0.3
            ending.timingFunction = CAMediaTimingFunction(name: .easeOut)
            screen.opacity = 0
            animated = [screen]
        } else {
            // The edge, a wavelength wider than the screen on each side so it can roll, and
            // everything below it, in coordinates where the edge's middle line is y = 0.
            let edge = Self.wave(from: -wavelength, to: width + wavelength, wavelength: wavelength, amplitude: amplitude)
            let below = UIBezierPath(cgPath: edge)
            below.addLine(to: CGPoint(x: width + wavelength, y: height + 4 * amplitude))
            below.addLine(to: CGPoint(x: -wavelength, y: height + 4 * amplitude))
            below.close()
            remainder.path = below.cgPath
            remainder.fillColor = UIColor.black.cgColor
            screen.mask = remainder
            let edgeLayers: [CALayer]
            if reduceTransparency {
                line.path = edge
                line.fillColor = nil
                line.strokeColor = UIColor(red: 1, green: 0.95, blue: 0.82, alpha: 1).cgColor
                line.lineWidth = 3
                edgeLayers = [line]
            } else {
                // Shadows of the edge's outline alone: a wide soft glow under a brighter line.
                glow.shadowPath = edge.copy(strokingWithWidth: 28, lineCap: .round, lineJoin: .round, miterLimit: 1)
                glow.shadowColor = UIColor(red: 1, green: 0.93, blue: 0.7, alpha: 1).cgColor
                glow.shadowOpacity = 0.7
                glow.shadowRadius = 14
                glow.shadowOffset = .zero
                line.shadowPath = edge.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 1)
                line.shadowColor = UIColor.white.cgColor
                line.shadowOpacity = 0.9
                line.shadowRadius = 2
                line.shadowOffset = .zero
                edgeLayers = [glow, line]
            }
            // The edge starts above the top and ends below the bottom.
            let from = CGPoint(x: 0, y: -2 * amplitude)
            let to = CGPoint(x: -Self.roll * wavelength, y: height + 2 * amplitude)
            animated = [remainder] + edgeLayers
            for layer in animated {
                layer.bounds = bounds
                layer.anchorPoint = .zero
                layer.position = to
            }
            for layer in edgeLayers { self.layer.addSublayer(layer) }
            ending.keyPath = "position"
            ending.fromValue = NSValue(cgPoint: from)
            ending.toValue = NSValue(cgPoint: to)
            ending.duration = Self.duration
            ending.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        CATransaction.setCompletionBlock { [weak self] in self?.finished() }
        for layer in animated { layer.add(ending, forKey: "wipe") }
        CATransaction.commit()
    }

    /// The edge's line from `x0` to `x1`: a sine about y = 0.
    private static func wave(from x0: CGFloat, to x1: CGFloat, wavelength: CGFloat, amplitude: CGFloat) -> CGPath {
        let path = UIBezierPath()
        let steps = max(2, Int(((x1 - x0) / wavelength * 24).rounded(.up)))
        for i in 0...steps {
            let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(steps)
            let point = CGPoint(x: x, y: amplitude * sin(2 * .pi * x / wavelength))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path.cgPath
    }
}

import SwiftUI

/// Which edge of a bubble its tail leaves from.
private enum BubbleTailEdge: Equatable, Sendable {
    case top, bottom, leading, trailing
}

/// A rounded rectangle (a capsule for one line) with a small soft tail pointing at a face. The
/// tail sits outside the rectangle, so the text's frame is the rectangle alone.
private struct SpeechBubbleShape: Shape {
    /// Where along its edge the tail points from, in the shape's own coordinates.
    var tailPosition: CGFloat
    var edge: BubbleTailEdge
    var cornerRadius: CGFloat = 24
    var tailSize = CGSize(width: 16, height: 10)

    var animatableData: CGFloat {
        get { tailPosition }
        set { tailPosition = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.height / 2)
        let body = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        let base = Self.baseHalfWidth(tailSize)
        switch edge {
        case .top, .bottom:
            // The tail and its flare stay on the straight part of the edge.
            let inset = radius + base
            let x = min(max(tailPosition, rect.minX + inset), max(rect.minX + inset, rect.maxX - inset))
            return body.union(Self.tail(along: x, edge: edge == .top ? rect.minY : rect.maxY,
                                        outward: edge == .top ? -1 : 1, size: tailSize, depth: 1, sideways: false))
        case .leading, .trailing:
            let inset = min(radius + base, rect.height / 2)
            let y = min(max(tailPosition, rect.minY + inset), max(rect.minY + inset, rect.maxY - inset))
            // A capsule's end is round, so the tail's base reaches further in to meet it.
            let depth = 1 + radius - (radius * radius - min(base, radius) * min(base, radius)).squareRoot()
            return body.union(Self.tail(along: y, edge: edge == .leading ? rect.minX : rect.maxX,
                                        outward: edge == .leading ? -1 : 1, size: tailSize, depth: depth,
                                        sideways: true))
        }
    }

    /// Half the tail's footprint along its edge, flare included.
    private static func baseHalfWidth(_ size: CGSize) -> CGFloat { size.width / 2 * 1.6 }

    /// A tail leaving an edge at `along`, its sides flaring into the edge so it has no corner,
    /// meeting in a rounded tip `size.height` out. `outward` (±1) points across the edge, `depth`
    /// reaches into the bubble, and `sideways` is for a vertical edge.
    private static func tail(along a: CGFloat, edge e: CGFloat, outward d: CGFloat, size: CGSize,
                             depth: CGFloat, sideways: Bool) -> Path {
        // u runs along the edge, v outward from it.
        func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            sideways ? CGPoint(x: e + d * v, y: a + u) : CGPoint(x: a + u, y: e + d * v)
        }
        let half = size.width / 2, height = size.height, base = baseHalfWidth(size)
        let tip = min(half * 0.3, 2)
        var path = Path()
        path.move(to: point(-base, -depth))
        path.addCurve(to: point(-tip, height - tip * 0.9), control1: point(-half * 1.1, 0),
                      control2: point(-tip * 1.5, height * 0.5))
        path.addQuadCurve(to: point(tip, height - tip * 0.9), control: point(0, height + tip * 0.3))
        path.addCurve(to: point(base, -depth), control1: point(tip * 1.5, height * 0.5),
                      control2: point(half * 1.1, 0))
        path.closeSubpath()
        return path
    }
}

extension View {
    /// Lays the view out at `rect` (stage points) in a top-leading stack spanning the stage. Its
    /// own frame is the rect, so transitions, scales and accessibility frames belong to the rect.
    func placed(at rect: StageRect) -> some View {
        frame(width: max(1, rect.width), height: max(1, rect.height))
            .alignmentGuide(.leading) { _ in -rect.minX }
            .alignmentGuide(.top) { _ in -rect.minY }
    }
}

/// The stage's full size at its origin, which `placed(at:)` lays captions out against.
private struct StageOrigin: View {
    let metrics: StageMetrics

    var body: some View {
        Color.clear
            .frame(width: metrics.width, height: metrics.height)
            .allowsHitTesting(false)
    }
}

/// A caption's text. Measuring and drawing share it, so the height measured is the height drawn.
private struct CaptionText: View {
    let text: String
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(.body.weight(.medium)).fontDesign(.rounded)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .minimumScaleFactor(0.75)
            .foregroundStyle(color)
            .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// The human's words on the pill, shared by measuring and drawing like `CaptionText`.
private struct PillText: View {
    let text: String
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(.body.weight(.medium)).fontDesign(.rounded)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .multilineTextAlignment(.center)
            .lineLimit(2).truncationMode(.head)
            .foregroundStyle(color)
            .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// The bubbles, typing capsules and the human's pill, each at its slot in the settled layout, so
/// text never rides the seam. Heights are measured off screen at each slot's width and handed to
/// the stage, which fits the faces around them.
struct StageCaptionLayer: View {
    let driver: StageDriver
    let inputs: StageInputs
    let metrics: StageMetrics
    let palette: StagePalette
    let reduceMotion: Bool

    private static let dotsWidth = 84.0
    /// `ThinkingDots`' default 14 pt with 15 pt above and below.
    private static let dotsHeight = 8 * 1.75 + 30.0
    private static let shadowRadius: CGFloat = 18

    private var slotAnimation: Animation? {
        reduceMotion ? nil : .spring(response: SpringSpec.bubble.response, dampingFraction: SpringSpec.bubble.dampingFraction)
    }

    var body: some View {
        let layout = driver.layout
        ZStack(alignment: .topLeading) {
            measurements
            ForEach(DuoCharacter.allCases) { c in
                bubble(for: c, layout: layout)
                capsule(for: c, layout: layout)
            }
            pill(layout)
        }
        .frame(width: metrics.width, height: metrics.height, alignment: .topLeading)
    }

    // MARK: Bubbles

    /// What a character's bubble shows, when the layout has a slot for it and its slot is clear.
    private func content(for c: DuoCharacter, layout: StageLayout) -> (slot: BubbleSlot, text: String?)? {
        guard let slot = layout.bubbles[c], !driver.pendingSlots.contains(c) else { return nil }
        switch slot.kind {
        case .dots: return inputs.thinking.contains(c) || inputs.floor == nil ? (slot, nil) : nil
        case .caption:
            guard let text = inputs.captions[c], !text.isEmpty else { return nil }
            return (slot, text)
        }
    }

    @ViewBuilder
    private func bubble(for c: DuoCharacter, layout: StageLayout) -> some View {
        let shown = content(for: c, layout: layout)
        // Dots alone sit in a compact bubble centred in the slot.
        let rect: StageRect? = shown.map { shown in
            let slot = shown.slot.rect
            return shown.text == nil
                ? StageRect(x: slot.midX - Self.dotsWidth / 2, y: slot.minY, width: Self.dotsWidth, height: slot.height)
                : slot
        }
        ZStack(alignment: .topLeading) {
            StageOrigin(metrics: metrics)
            if let shown, let rect {
                let edge: BubbleTailEdge = shown.slot.tail == .top ? .top : .bottom
                let shape = SpeechBubbleShape(tailPosition: shown.slot.tailX - rect.minX, edge: edge)
                // The text sets the height. The slot's is rounded for fitting the faces, so any
                // difference grows toward the face, away from the tail.
                Group {
                    if let text = shown.text {
                        CaptionText(text: text, color: palette.color(palette.colors.bubbleText[c]))
                            .id(text)
                            .transition(.opacity.animation(reduceMotion ? nil : .easeInOut(duration: 0.2)))
                            .frame(width: rect.width)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ThinkingDots(color: palette.dots(for: c))
                            .frame(width: rect.width, height: max(rect.height, 1))
                    }
                }
                .softGlass(shape, tint: palette.colors.bubbleTint[c], kind: .caption, palette: palette,
                           shadowRadius: Self.shadowRadius)
                .frame(width: rect.width, height: max(rect.height, 1), alignment: edge == .top ? .bottom : .top)
                .placed(at: rect)
                .transition(bubbleTransition(edge: edge, tailX: (shown.slot.tailX - rect.minX) / max(rect.width, 1),
                                             waitsForFace: !shown.slot.isSpeaker))
            }
        }
        .animation(slotAnimation, value: rect)
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.62),
                   value: shown != nil)
        .accessibilityHidden(true)
    }

    /// Bubbles pop out of their tail and fade away. One that isn't the speaker's waits 0.25 s, so it
    /// never shows over a face still springing into place.
    private func bubbleTransition(edge: BubbleTailEdge, tailX: Double, waitsForFace: Bool) -> AnyTransition {
        let delay = waitsForFace ? 0.25 : 0
        if reduceMotion { return .asymmetric(insertion: .opacity.animation(.linear(duration: 0.15).delay(delay)),
                                             removal: .opacity) }
        let anchor = UnitPoint(x: tailX, y: edge == .top ? 0 : 1)
        return .asymmetric(
            insertion: .scale(scale: 0.85, anchor: anchor).combined(with: .opacity)
                .animation(.spring(response: 0.32, dampingFraction: 0.62).delay(delay)),
            removal: .scale(scale: 0.92, anchor: anchor).combined(with: .opacity)
                .animation(.easeOut(duration: 0.15)))
    }

    // MARK: Capsule

    @ViewBuilder
    private func capsule(for c: DuoCharacter, layout: StageLayout) -> some View {
        let slot = layout.capsules[c]
        let shown = slot != nil && !driver.pendingSlots.contains(c) && inputs.thinking.contains(c)
        ZStack(alignment: .topLeading) {
            StageOrigin(metrics: metrics)
            if let slot, shown {
                let rect = slot.rect
                let tail = Self.tail(from: rect, toward: slot.tailToward)
                ThinkingDots(color: palette.dots(for: c), dotSize: 6, spacing: 4)
                    .frame(width: rect.width, height: rect.height)
                    .softGlass(SpeechBubbleShape(tailPosition: tail.position, edge: tail.edge,
                                                 cornerRadius: rect.height / 2, tailSize: CGSize(width: 10, height: 6)),
                               tint: palette.colors.bubbleTint[c], kind: .caption, palette: palette, shadowRadius: 12)
                    .placed(at: rect)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(slotAnimation, value: slot?.rect)
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.62),
                   value: shown)
        .accessibilityHidden(true)
    }

    /// The capsule's tail edge and position (in its own coordinates) toward the face.
    private static func tail(from rect: StageRect, toward face: Vec2) -> (edge: BubbleTailEdge, position: CGFloat) {
        let dx = face.x - rect.midX, dy = face.y - rect.midY
        if abs(dx) > abs(dy) * 1.5 {
            return (dx < 0 ? .leading : .trailing, rect.height / 2)
        }
        let x = min(max(face.x - rect.minX, 0), rect.width)
        return (dy < 0 ? .top : .bottom, x)
    }

    // MARK: Pill

    /// The pill fades quickly when a character answers, before the handover's seam reaches it.
    @ViewBuilder
    private func pill(_ layout: StageLayout) -> some View {
        let rect = layout.pill.flatMap { $0.height > 0 ? $0 : nil }
        ZStack(alignment: .topLeading) {
            StageOrigin(metrics: metrics)
            if let text = inputs.userText, let rect {
                let ink = inputs.userFinal ? palette.colors.pillText : palette.colors.pillPendingText
                PillText(text: text, color: palette.color(ink))
                    .frame(width: rect.width, height: rect.height)
                    .softGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), tint: palette.colors.pillTint,
                               kind: .caption, palette: palette, shadowRadius: Self.shadowRadius)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("You: \(text)")
                    .accessibilityAddTraits(inputs.userFinal ? [] : .updatesFrequently)
                    .accessibilitySortPriority(1)
                    .placed(at: rect)
                    .transition(.asymmetric(
                        insertion: (reduceMotion ? AnyTransition.opacity : .scale(scale: 0.9).combined(with: .opacity))
                            .animation(reduceMotion ? .linear(duration: 0.15) : .smooth(duration: 0.3)),
                        removal: AnyTransition.opacity.animation(.easeOut(duration: 0.15))))
            }
        }
        .animation(slotAnimation, value: rect)
        .animation(reduceMotion ? .linear(duration: 0.15) : .smooth(duration: 0.3), value: inputs.userText == nil)
        .animation(.easeInOut(duration: 0.2), value: inputs.userFinal)
    }

    // MARK: Measuring

    /// Every caption, dots bubble and the pill laid out invisibly at its slot's width, so the
    /// stage knows their heights before they show.
    private var measurements: some View {
        ZStack(alignment: .topLeading) {
            ForEach(DuoCharacter.allCases) { c in
                let layout = driver.layout
                let speaker = layout.key.preset.speaker == c
                let width = layout.bubbles[c]?.rect.width
                    ?? (speaker ? StageLayout.speakerBubbleWidth(metrics.width)
                        : StageLayout.neutralBubbleWidth(metrics.width))
                let thinking = inputs.thinking.contains(c) && inputs.floor == nil
                let kind: BubbleKind = thinking ? .dots : .caption
                Group {
                    if thinking {
                        Color.clear.frame(height: Self.dotsHeight)
                    } else if let text = inputs.captions[c], !text.isEmpty {
                        CaptionText(text: text)
                    }
                }
                .frame(width: max(1, width))
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    driver.measured(bubble: height, for: c, kind: kind)
                }
            }
            if let text = inputs.userText {
                PillText(text: text)
                    .frame(width: max(1, min(380, metrics.width - 32)))
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { driver.measured(pill: $0) }
            }
        }
        .hidden()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

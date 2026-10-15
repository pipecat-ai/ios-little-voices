#if DEBUG
import SwiftUI

/// DEBUG launch modes for reviewing the stage:
///
/// - `--expression-gallery [rNcM]`: the 4 × 3 expression gallery, or one cell full screen;
/// - `--mouth-sheet`: both characters' mouth states;
/// - `--stage-pose <neutral|lean-angel|lean-devil|angel-talking|devil-talking> [--no-captions]`:
///   a settled pose on the real stage (`DuoStageView`, its captions, header and dock), the model
///   not started;
/// - `--stage-script <name>`: a scripted conversation (`StageScript.scenario`) played on the real
///   stage with synthetic mouths and microphone level, the model not started, 1.5 s after
///   launch; it logs `STAGE_SCRIPT_START`, each step and mark (`STAGE_SCRIPT`) and
///   `STAGE_SCRIPT_DONE`. `intro` replays the launch intro, its faces unseen until then, and
///   `intro-handover` starts a conversation in the middle of it; the others show no intro;
/// - `--rig-seed N`: the rig's seed (1 for the gallery, poses and scripts, otherwise random per
///   launch);
/// - `--rig-trace`: the stage's events (`STAGE_EVENT`) and frame counts (`STAGE_LINK`,
///   `STAGE_DRAWS`);
/// - `--reduce-motion`: the stage's Reduce Motion snap mode.
enum StageDebug {
    static let arguments = ProcessInfo.processInfo.arguments

    static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        return value.hasPrefix("--") ? nil : value
    }

    static var seed: UInt64 { value(after: "--rig-seed").flatMap(UInt64.init) ?? 1 }

    /// `--expression-gallery`: nil when not asked for; the named cell, or nil for the gallery.
    static var gallery: GalleryRequest? {
        guard arguments.contains("--expression-gallery") else { return nil }
        return GalleryRequest(cell: value(after: "--expression-gallery").flatMap(GalleryCell.named))
    }

    static var mouthSheet: Bool { arguments.contains("--mouth-sheet") }

    static var stagePose: StagePoseRequest? {
        guard let name = value(after: "--stage-pose"), let pose = StagePoseRequest.pose(named: name) else { return nil }
        return StagePoseRequest(pose: pose, name: name, captions: !arguments.contains("--no-captions"))
    }

    /// `--stage-script <name>`: the scenario, seeded with `--rig-seed`.
    static let stageScript: StageScriptRequest? = {
        guard let name = value(after: "--stage-script") else { return nil }
        guard let script = StageScript.scenario(name, seed: seed) else {
            log("STAGE_SCRIPT_UNKNOWN: \(name); scenarios: \(StageScript.scenarioNames.joined(separator: ", "))")
            return nil
        }
        return StageScriptRequest(name: name, script: script)
    }()

    static func log(_ line: String) {
        print(line)
        fflush(stdout)
    }
}

struct GalleryRequest: Equatable {
    var cell: GalleryCell?
}

struct StageScriptRequest {
    var name: String
    var script: StageScript
}

struct StagePoseRequest: Equatable {
    var pose: StagePose
    var name: String
    var captions: Bool

    static func pose(named name: String) -> StagePose? {
        switch name {
        case "neutral": .neutral
        case "lean-angel": .leanAngel
        case "lean-devil": .leanDevil
        case "angel-talking": .angelTalking
        case "devil-talking": .devilTalking
        default: nil
        }
    }
}

/// The palette for the current environment.
private struct StagePaletteReader<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var content: (StagePalette) -> Content

    var body: some View {
        content(StagePalette(colorScheme: colorScheme, contrast: contrast, reduceTransparency: reduceTransparency))
    }
}

/// One settled frame drawn full size.
private struct StageStill: View {
    let frame: StageFrame
    let metrics: StageMetrics
    let palette: StagePalette
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let glow = GlowSpriteCache.shared.image(for: palette, pxPerFu: metrics.scale * displayScale)
        Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
            StageRenderer.draw(frame, metrics: metrics, palette: palette, glow: glow, in: &context, size: size)
        }
    }
}

// MARK: - Gallery

/// The expression gallery: twelve cells, each the angel over the devil with the cell's
/// expressions, settled.
struct ExpressionGalleryView: View {
    let request: GalleryRequest

    var body: some View {
        StagePaletteReader { palette in
            Group {
                if let cell = request.cell {
                    GeometryReader { proxy in
                        let metrics = StageMetrics(width: proxy.size.width, height: proxy.size.height,
                                                   bandTop: proxy.safeAreaInsets.top + 8,
                                                   bandBottom: proxy.size.height - proxy.safeAreaInsets.bottom - 8)
                        StageStill(frame: StageSimulation.snapshot(cell: cell, metrics: metrics, seed: StageDebug.seed).frame,
                                   metrics: metrics, palette: palette)
                    }
                    .ignoresSafeArea()
                } else {
                    grid(palette)
                }
            }
            .onAppear {
                StageDebug.log("EXPRESSION_GALLERY_READY: \(request.cell == nil ? 12 : 1) cells, seed \(StageDebug.seed)")
            }
        }
    }

    private func grid(_ palette: StagePalette) -> some View {
        GeometryReader { proxy in
            let spacing = 8.0, pad = 10.0
            let width = (proxy.size.width - 2 * pad - 3 * spacing) / 4
            let height = min((proxy.size.height - 2 * pad - 2 * spacing) / 3, width * 1.36)
            VStack(spacing: spacing) {
                ForEach(1...3, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(1...4, id: \.self) { column in
                            let cell = GalleryCell.all[(row - 1) * 4 + (column - 1)]
                            // The cells' band reaches a little past them, so the faces fill
                            // the cell's width.
                            let metrics = StageMetrics(width: width, height: height, bandTop: -0.12 * height,
                                                       bandBottom: 1.12 * height)
                            StageStill(frame: StageSimulation.snapshot(cell: cell, metrics: metrics,
                                                                       seed: StageDebug.seed).frame,
                                       metrics: metrics, palette: palette)
                                .frame(width: width, height: height)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.vertical, 10)
        .background(Color(red: 0.96, green: 0.94, blue: 0.90).ignoresSafeArea())
    }
}

// MARK: - Mouth sheet

/// Both characters' mouth states: what their expressions hold and what lip sync makes of each
/// viseme. The angel's sit on cream tiles (`AngelMouthSheet`), the devil's on his orange
/// (`DevilMouthSheet`), each at a point per face unit.
struct MouthSheetView: View {
    private static let columns = 4

    var body: some View {
        StagePaletteReader { palette in
            GeometryReader { proxy in
                let spacing = 8.0, pad = 12.0
                let width = (proxy.size.width - 2 * pad - Double(Self.columns - 1) * spacing) / Double(Self.columns)
                VStack(alignment: .leading, spacing: 10) {
                    section(AngelMouthSheet.states, character: .angel, tile: Color(red: 1, green: 0.95, blue: 0.85),
                            width: width, spacing: spacing, palette: palette)
                    section(DevilMouthSheet.states, character: .devil, tile: Color(red: 0.96, green: 0.52, blue: 0.16),
                            width: width, spacing: spacing, palette: palette)
                }
                .padding(pad)
            }
            .background(Color(red: 0.98, green: 0.96, blue: 0.92).ignoresSafeArea())
            .onAppear {
                StageDebug.log("MOUTH_SHEET_READY: \(AngelMouthSheet.states.count) angel states, "
                    + "\(DevilMouthSheet.states.count) devil states")
            }
        }
    }

    private func section(_ states: [MouthSheetState], character c: DuoCharacter, tile: Color, width: Double,
                         spacing: Double, palette: StagePalette) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: spacing), count: Self.columns),
                  spacing: spacing) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                VStack(spacing: 3) {
                    Canvas { context, size in
                        // A point per face unit, the mouth's anchor about a third of the way down.
                        let transform = CGAffineTransform(translationX: size.width / 2, y: size.height * 0.3)
                        StageRenderer.drawMouth(state.mouth, character: c, transform: transform, ink: 1, palette: palette,
                                                in: &context)
                    }
                    .frame(width: width, height: width * 0.8)
                    .background(tile, in: RoundedRectangle(cornerRadius: 10))
                    Text(state.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
    }
}

#endif

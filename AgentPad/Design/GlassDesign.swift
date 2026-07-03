import os
import Foundation
import SwiftUI
import UIKit

struct AgentPalette {
    nonisolated(unsafe) private static var cachedPalette = AgentTheme.current.palette

    static func refreshThemeCache(_ theme: AgentTheme? = nil) {
        // Keep AgentTheme.current's cache in lockstep: nil clears it so the
        // next read re-resolves from UserDefaults, then we pin the resolved
        // value for the hot paths.
        AgentTheme.refreshCurrentCache(theme)
        let resolvedTheme = theme ?? AgentTheme.current
        AgentTheme.refreshCurrentCache(resolvedTheme)
        cachedPalette = resolvedTheme.palette
        CodeSyntaxHighlighter.themeDidChange()
    }

    private static var theme: AgentThemePalette {
        cachedPalette
    }

    static var isLight: Bool { theme.isLight }
    static var ink: Color { theme.textPrimary }
    static var secondaryText: Color { theme.textSecondary }
    static var tertiaryText: Color { theme.textTertiary }
    static var quaternaryText: Color { theme.textQuaternary }

    static var pearl: Color { theme.backgroundA }
    static var ice: Color { theme.backgroundB }
    static var lilacMist: Color { theme.backgroundC }
    static var glassFill: Color { theme.surface }
    static var mist: Color { theme.surfaceAlt }

    static var primaryAccent: Color { theme.primaryAccent }
    static var secondaryAccent: Color { theme.secondaryAccent }
    static var storageAccent: Color { theme.storageAccent }
    static var dockSelectedTint: Color { theme.textPrimary }
    static var success: Color { theme.semanticSuccess }
    static var warning: Color { theme.semanticWarning }
    static var error: Color { theme.semanticError }
    static var info: Color { theme.semanticInfo }
    static var approval: Color { theme.semanticApproval }
    static var running: Color { theme.semanticRunning }
    static var blocked: Color { theme.semanticBlocked }
    static var terminalBackground: Color { theme.terminalBackground }
    static var terminalText: Color { theme.terminalText }
    static var terminalPrompt: Color { theme.terminalPrompt }
    static var terminalCommand: Color { theme.terminalCommand }
    static var terminalOutput: Color { theme.terminalOutput }
    static var terminalWarning: Color { theme.terminalWarning }
    static var terminalError: Color { theme.terminalError }
    static var terminalSelection: Color { theme.terminalSelection }
    static var codeBackground: Color { theme.codeBackground }
    static var codeText: Color { theme.codeText }
    static var codeKeyword: Color { theme.codeKeyword }
    static var codeString: Color { theme.codeString }
    static var codeComment: Color { theme.codeComment }
    static var codeType: Color { theme.codeType }
    static var codeCursor: Color { theme.codeCursor }
    static var glassTint: Color { theme.glassTint }
    static var glassStroke: Color { theme.glassStroke }
    static var glow: Color { theme.glow }
    static var divider: Color { theme.divider }
    static var controlFill: Color { theme.controlFill }
    static var controlFillSelected: Color { theme.controlFillSelected }
    static var controlBorder: Color { theme.controlBorder }
    static var cyan: Color { theme.cyan }
    static var blue: Color { theme.cyan }
    static var accent: Color { theme.primaryAccent }
    static var lilac: Color { theme.lilac }
    static var green: Color { theme.green }
    static var rose: Color { theme.rose }
    static var indigo: Color { theme.semanticWarning }
    static var surface: Color { theme.surface }
    static var surfaceElevated: Color { theme.surfaceElevated }
    static var surfaceAlt: Color { theme.surfaceAlt }
    static var row: Color { theme.row }
    static var rowSelected: Color { theme.rowSelected }
    static var border: Color { theme.border }
    static var shadow: Color { theme.shadow }
    static var interfaceFontDesign: Font.Design { theme.typography.interfaceDesign }
    static var displayFontDesign: Font.Design { theme.typography.displayDesign }
    static var codeFontDesign: Font.Design { theme.typography.codeDesign }
}

struct AgentThemeTypographyModifier: ViewModifier {
    let theme: AgentTheme

    func body(content: Content) -> some View {
        let typography = theme.palette.typography
        content
            .font(.system(.body, design: typography.interfaceDesign))
            .fontDesign(typography.interfaceDesign)
    }
}

extension View {
    func agentThemeTypography(_ theme: AgentTheme) -> some View {
        modifier(AgentThemeTypographyModifier(theme: theme))
    }
}

enum AgentPerformance {
    static let storageKey = "novaforgePerformanceMode"
    static let launchArgument = "--performance-mode"
    static let frameRateLaunchArgument = "--profile-frame-rate"
    static let bodyEvaluationLaunchArgument = "--profile-body-evaluations"

    private static let log = OSLog(subsystem: "com.joey.NovaForge", category: "Performance")
    private static let bodyCounterLock = NSLock()
    nonisolated(unsafe) private static var bodyCounters: [String: BodyCounter] = [:]

    private struct BodyCounter {
        var count: Int
        var startedAt: TimeInterval
    }

    // Launch arguments never change during the process lifetime, so every
    // argument-derived flag is computed exactly once. The old computed
    // properties bridged ProcessInfo.arguments (an NSArray -> [String]
    // conversion) on every access — and these are read from surface modifiers
    // on every body evaluation, thousands of times per second while scrolling.
    private static let hasPerformanceLaunchArgument = ProcessInfo.processInfo.arguments.contains(launchArgument)

    /// UserDefaults-backed portion is cached; SettingsView / AppRootView call
    /// `invalidatePerformanceModeCache()` when the toggle changes.
    nonisolated(unsafe) private static var cachedPerformanceMode: Bool?

    static var isPerformanceMode: Bool {
        if let cachedPerformanceMode { return cachedPerformanceMode }
        let value = hasPerformanceLaunchArgument || UserDefaults.standard.bool(forKey: storageKey)
        cachedPerformanceMode = value
        return value
    }

    static func invalidatePerformanceModeCache() {
        cachedPerformanceMode = nil
    }

    static var allowsDecorativeMotion: Bool {
        !isPerformanceMode
    }

    static var prefersReducedVisualEffects: Bool {
        isPerformanceMode
    }

    static let shouldProfileFrameRate: Bool =
        ProcessInfo.processInfo.arguments.contains(frameRateLaunchArgument)

    static let shouldProfileBodyEvaluations: Bool =
        ProcessInfo.processInfo.arguments.contains(bodyEvaluationLaunchArgument)

    #if DEBUG
    static let shouldProfileViewChanges: Bool =
        ProcessInfo.processInfo.arguments.contains("--profile-view-changes")
    #endif

    static let shouldTraceDetailedEvents: Bool =
        ProcessInfo.processInfo.arguments.contains("--profile-events")

    enum FrameSurface: Equatable {
        case projectIdle
        case projectScroll
        case chatStreaming
    }

    static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
        if shouldTraceDetailedEvents {
            trace(String(describing: name))
        }
    }

    static func value(_ name: StaticString, _ value: Double) {
        os_signpost(.event, log: log, name: name, "%{public}.2f", value)
        if shouldTraceDetailedEvents {
            trace("\(String(describing: name)): \(value)")
        }
    }

    static func begin(_ name: StaticString) -> OSSignpostID {
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: signpostID)
        if shouldTraceDetailedEvents {
            trace("Begin \(String(describing: name))")
        }
        return signpostID
    }

    static func end(_ name: StaticString, id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
        if shouldTraceDetailedEvents {
            trace("End \(String(describing: name))")
        }
    }

    static func frameAverage(_ surface: FrameSurface, fps: Double) {
        switch surface {
        case .projectIdle:
            value("Project Idle FPS", fps)
            trace("Project Idle FPS: \(fps)")
        case .projectScroll:
            value("Project Scroll FPS", fps)
            trace("Project Scroll FPS: \(fps)")
        case .chatStreaming:
            value("Chat Streaming FPS", fps)
            trace("Chat Streaming FPS: \(fps)")
        }
    }

    static func worstFrame(_ surface: FrameSurface, milliseconds: Double) {
        switch surface {
        case .projectIdle:
            value("Project Idle Worst Frame ms", milliseconds)
            trace("Project Idle Worst Frame ms: \(milliseconds)")
        case .projectScroll:
            value("Project Scroll Worst Frame ms", milliseconds)
            trace("Project Scroll Worst Frame ms: \(milliseconds)")
        case .chatStreaming:
            value("Chat Streaming Worst Frame ms", milliseconds)
            trace("Chat Streaming Worst Frame ms: \(milliseconds)")
        }
    }

    static func hitchCount(_ surface: FrameSurface, count: Int) {
        switch surface {
        case .projectIdle:
            value("Project Idle Hitch Count", Double(count))
            trace("Project Idle Hitch Count: \(Double(count))")
        case .projectScroll:
            value("Project Scroll Hitch Count", Double(count))
            trace("Project Scroll Hitch Count: \(Double(count))")
        case .chatStreaming:
            value("Chat Streaming Hitch Count", Double(count))
            trace("Chat Streaming Hitch Count: \(Double(count))")
        }
    }

    @discardableResult
    static func bodyEvaluation(_ name: StaticString) -> Bool {
        guard shouldProfileBodyEvaluations else { return false }
        let key = String(describing: name)
        let now = ProcessInfo.processInfo.systemUptime
        var traceLine: String?

        bodyCounterLock.lock()
        var counter = bodyCounters[key] ?? BodyCounter(count: 0, startedAt: now)
        counter.count += 1
        let elapsed = max(0, now - counter.startedAt)
        if elapsed >= 1 {
            let measuredElapsed = max(elapsed, 0.001)
            let rate = Double(counter.count) / measuredElapsed
            traceLine = String(format: "Body Evaluations %@: count=%d perSecond=%.2f windowMs=%.0f", key, counter.count, rate, measuredElapsed * 1_000)
            counter = BodyCounter(count: 0, startedAt: now)
        }
        bodyCounters[key] = counter
        bodyCounterLock.unlock()

        if let traceLine {
            trace(traceLine)
        }
        return false
    }

    private static func trace(_ message: @autoclosure () -> String) {
        guard shouldProfileFrameRate || shouldProfileBodyEvaluations || shouldTraceDetailedEvents else { return }
        let line = "[NovaForgePerformance] \(message())"
        print(line)
        os_log("%{public}@", log: log, type: .info, line)
    }
}

struct PerformanceFrameProbe: UIViewRepresentable {
    let surface: AgentPerformance.FrameSurface
    let isActive: Bool
    var sampleInterval: TimeInterval = 1
    var hitchThreshold: TimeInterval = 1.0 / 30.0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        context.coordinator.update(
            surface: surface,
            isActive: isActive && AgentPerformance.shouldProfileFrameRate,
            sampleInterval: sampleInterval,
            hitchThreshold: hitchThreshold
        )
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(
            surface: surface,
            isActive: isActive && AgentPerformance.shouldProfileFrameRate,
            sampleInterval: sampleInterval,
            hitchThreshold: hitchThreshold
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        private var displayLink: CADisplayLink?
        private var surface: AgentPerformance.FrameSurface = .projectIdle
        private var sampleInterval: TimeInterval = 1
        private var hitchThreshold: TimeInterval = 1.0 / 30.0
        private var lastTimestamp: CFTimeInterval?
        private var accumulatedTime: TimeInterval = 0
        private var frameCount = 0
        private var worstFrameDuration: TimeInterval = 0
        private var hitches = 0

        deinit {
            stop()
        }

        func update(
            surface: AgentPerformance.FrameSurface,
            isActive: Bool,
            sampleInterval: TimeInterval,
            hitchThreshold: TimeInterval
        ) {
            let surfaceChanged = self.surface != surface
            self.surface = surface
            self.sampleInterval = sampleInterval
            self.hitchThreshold = hitchThreshold
            if surfaceChanged {
                flushWindow()
                resetWindow()
            }
            isActive ? start() : stop()
        }

        func stop() {
            flushWindow()
            displayLink?.invalidate()
            displayLink = nil
            lastTimestamp = nil
            resetWindow()
        }

        private func start() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(displayFrame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func displayFrame(_ link: CADisplayLink) {
            guard let previousTimestamp = lastTimestamp else {
                lastTimestamp = link.timestamp
                return
            }
            let frameDuration = link.timestamp - previousTimestamp
            lastTimestamp = link.timestamp
            guard frameDuration > 0 else { return }

            frameCount += 1
            accumulatedTime += frameDuration
            worstFrameDuration = max(worstFrameDuration, frameDuration)
            if frameDuration > hitchThreshold {
                hitches += 1
            }

            guard accumulatedTime >= sampleInterval else { return }
            flushWindow()
            resetWindow()
        }

        private func flushWindow() {
            guard frameCount > 0, accumulatedTime > 0 else { return }
            AgentPerformance.frameAverage(surface, fps: Double(frameCount) / accumulatedTime)
            AgentPerformance.worstFrame(surface, milliseconds: worstFrameDuration * 1_000)
            AgentPerformance.hitchCount(surface, count: hitches)
        }

        private func resetWindow() {
            accumulatedTime = 0
            frameCount = 0
            worstFrameDuration = 0
            hitches = 0
        }
    }
}

enum AgentDesign {
    static let cardRadius: CGFloat = 22
    static let panelRadius: CGFloat = 24
    static let rowRadius: CGFloat = 14
    static let controlRadius: CGFloat = 12
    static let chipRadius: CGFloat = 10

    static let cardPadding: CGFloat = 16
    static let rowPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 16
    static let minimumTouchTarget: CGFloat = 44
    static let controlHeight: CGFloat = 44
    static let compactControlHeight: CGFloat = 36

    static let dividerOpacity: Double = 0.34
    static let borderOpacity: Double = 0.50
    static let selectedBorderOpacity: Double = 0.28
    static let selectedFillOpacity: Double = 0.16
    static let softShadowOpacity: Double = 0.06
}

enum AgentPlatformCompatibility {
    // Both values are process-lifetime constants — computed once instead of
    // re-bridging ProcessInfo state on every surface-modifier evaluation.
    static let isIOS27OrNewer: Bool =
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    // Keep native Liquid Glass available even in performance mode. Profiling
    // showed the native effect can be cheaper than layered fallback fills on
    // simulator, while still matching the intended premium app character.
    static let usesConservativeRendering: Bool =
        ProcessInfo.processInfo.arguments.contains("--disable-liquid-glass")
}

struct AgentBackground: View {
    var isWorking: Bool = false
    var isAnimated: Bool = true
    @AppStorage(AgentTheme.storageKey) private var selectedThemeRawValue = AgentTheme.defaultTheme.rawValue
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let conservativeRendering = AgentPlatformCompatibility.usesConservativeRendering
        let theme = AgentTheme.resolved(from: selectedThemeRawValue)
        let palette = theme.palette
        // Matrix rain is now cheap enough (pre-rendered glyph atlas) to keep
        // raining in performance mode — it drops to a reduced-density layer
        // instead of freezing. Reduce Motion (accessibility) always wins.
        let isMatrixTheme = palette.backgroundEffect == .matrixRain
        let baseMotion = isAnimated && !reduceMotion && !conservativeRendering
        let allowsMotion = baseMotion &&
            (isMatrixTheme || (AgentPerformance.allowsDecorativeMotion && !reduceTransparency))
        ZStack {
            LinearGradient(
                colors: [
                    palette.backgroundA,
                    palette.backgroundB,
                    conservativeRendering ? palette.backgroundA : palette.backgroundC.opacity(0.34),
                    palette.backgroundD
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            AgentThemeBackdrop(
                theme: theme,
                allowsMotion: allowsMotion,
                reducedDetail: AgentPerformance.prefersReducedVisualEffects
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(conservativeRendering ? 0 : 1)
                // Identity is keyed by theme only. Including allowsMotion here
                // used to force a full Canvas/TimelineView teardown+rebuild on
                // every tab switch and scene-phase change — a large, invisible
                // hitch. Animation state now transitions in place.
                .id("agent-backdrop-\(theme.rawValue)")
                .ignoresSafeArea()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .compositingGroup()
    }
}

struct AgentThemeBackdrop: View {
    let theme: AgentTheme
    let allowsMotion: Bool
    var reducedDetail: Bool = false

    private var palette: AgentThemePalette { theme.palette }

    var body: some View {
        ZStack {
            switch palette.backgroundEffect {
            case .matrixRain:
                MatrixRainBackdrop(palette: palette, animated: allowsMotion, reducedDetail: reducedDetail)
            case .midnightDepth:
                AmbientThemeBackdrop(effect: .midnightDepth, palette: palette, animated: allowsMotion)
            case .whiteGoldVeil:
                AmbientThemeBackdrop(effect: .whiteGoldVeil, palette: palette, animated: allowsMotion)
            case .arcticPrism:
                AmbientThemeBackdrop(effect: .arcticPrism, palette: palette, animated: allowsMotion)
            case .emberPulse:
                AmbientThemeBackdrop(effect: .emberPulse, palette: palette, animated: allowsMotion)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct MatrixRainBackdrop: View {
    let palette: AgentThemePalette
    let animated: Bool
    var reducedDetail: Bool = false

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: reducedDetail ? 1.0 / 20.0 : 1.0 / 24.0)) { timeline in
                rainFrame(time: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            rainFrame(time: 0)
        }
    }

    private func rainFrame(time: TimeInterval) -> some View {
        // Glyph bitmaps are rendered once per (layer, palette) and blitted
        // every frame. The previous implementation laid out ~230 live `Text`
        // glyphs per frame at 30fps — text shaping was the single most
        // expensive recurring cost on the render loop. Cached image draws are
        // an order of magnitude cheaper and keep the rain affordable enough
        // to run everywhere, including sheets and performance mode.
        let nearSprites = MatrixRainGlyphAtlas.shared.sprites(for: .near, palette: palette)
        let distantSprites = MatrixRainGlyphAtlas.shared.sprites(for: .distant, palette: palette)
        let reducedSprites = MatrixRainGlyphAtlas.shared.sprites(for: .staticReduced, palette: palette)
        return Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            drawMatrixDepth(in: &context, size: size)
            if animated {
                if !reducedDetail {
                    drawMatrixColumns(in: &context, size: size, time: time, layer: .distant, sprites: distantSprites)
                }
                drawMatrixColumns(in: &context, size: size, time: time, layer: .near, sprites: nearSprites)
            } else {
                drawMatrixColumns(in: &context, size: size, time: time, layer: .staticReduced, sprites: reducedSprites)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .compositingGroup()
        .opacity(animated ? 0.78 : 0.30)
    }
}

/// Pre-renders the matrix glyph set into bitmap sprites, once per
/// (layer, palette) combination. Rendering happens on the main actor (view
/// body) and the resulting `Image` values are captured by the Canvas closure.
@MainActor
final class MatrixRainGlyphAtlas {
    static let shared = MatrixRainGlyphAtlas()

    struct LayerSprites {
        let head: [Image]
        let tail: [Image]
        let glow: [Image]
    }

    enum LayerKind: String {
        case distant
        case near
        case staticReduced

        fileprivate var layer: MatrixRainLayer {
            switch self {
            case .distant: .distant
            case .near: .near
            case .staticReduced: .staticReduced
            }
        }
    }

    private var cache: [String: LayerSprites] = [:]

    func sprites(for kind: LayerKind, palette: AgentThemePalette) -> LayerSprites {
        let key = "\(kind.rawValue)-\(palette.backgroundEffect.rawValue)"
        if let cached = cache[key] { return cached }
        let layer = kind.layer
        let sprites = LayerSprites(
            head: renderGlyphs(fontSize: layer.headFontSize, weight: .bold, color: UIColor(palette.textPrimary)),
            tail: renderGlyphs(fontSize: layer.tailFontSize, weight: .medium, color: UIColor(palette.primaryAccent)),
            glow: layer.glowRadius > 0
                ? renderGlyphs(
                    fontSize: layer.headFontSize + layer.glowRadius,
                    weight: .bold,
                    color: UIColor(palette.primaryAccent),
                    blur: 1.5
                )
                : []
        )
        cache[key] = sprites
        return sprites
    }

    private func renderGlyphs(
        fontSize: CGFloat,
        weight: UIFont.Weight,
        color: UIColor,
        blur: CGFloat = 0
    ) -> [Image] {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let probe = ("W" as NSString).size(withAttributes: attributes)
        let padding: CGFloat = blur > 0 ? 4 : 1
        let spriteSize = CGSize(
            width: ceil(probe.width) + padding * 2,
            height: ceil(probe.height) + padding * 2
        )
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: spriteSize, format: format)
        return MatrixRainSeed.glyphs.map { glyph in
            let image = renderer.image { rendererContext in
                if blur > 0 {
                    rendererContext.cgContext.setShadow(
                        offset: .zero,
                        blur: blur,
                        color: color.withAlphaComponent(0.85).cgColor
                    )
                }
                (glyph as NSString).draw(at: CGPoint(x: padding, y: padding), withAttributes: attributes)
            }
            return Image(uiImage: image).renderingMode(.original)
        }
    }
}

private extension MatrixRainBackdrop {
    func drawMatrixDepth(in context: inout GraphicsContext, size: CGSize) {
        var boundsPath = Path()
        boundsPath.addRect(CGRect(origin: .zero, size: size))
        context.fill(
            boundsPath,
            with: .linearGradient(
                Gradient(colors: [
                    Color.black.opacity(0.10),
                    palette.backgroundC.opacity(0.22),
                    Color.black.opacity(0.18)
                ]),
                startPoint: CGPoint(x: size.width * 0.18, y: 0),
                endPoint: CGPoint(x: size.width * 0.82, y: size.height)
            )
        )

        for index in 0..<4 {
            let fraction = CGFloat(index) / 6.0
            let center = CGPoint(
                x: size.width * (0.08 + fraction * 0.86),
                y: size.height * (0.18 + CGFloat((index * 13) % 29) / 55.0)
            )
            let radius = max(size.width, size.height) * (0.18 + CGFloat((index * 5) % 7) * 0.018)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 1.32
                )),
                with: .radialGradient(
                    Gradient(colors: [
                        palette.primaryAccent.opacity(0.035),
                        palette.backgroundC.opacity(0.010),
                        .clear
                    ]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }

        let streakSpacing: CGFloat = 118
        let streaks = max(1, Int(size.width / streakSpacing) + 2)
        for index in 0..<streaks {
            let x = CGFloat(index) * streakSpacing + CGFloat((index * 17) % 19) - 12
            var path = Path()
            path.move(to: CGPoint(x: x, y: -size.height * 0.04))
            path.addLine(to: CGPoint(x: x + CGFloat((index * 7) % 13) - 6, y: size.height * 1.04))
            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [
                        .clear,
                        palette.primaryAccent.opacity(0.010 * palette.backgroundMotionOpacity),
                        palette.textPrimary.opacity(0.018 * palette.backgroundMotionOpacity),
                        .clear
                    ]),
                    startPoint: CGPoint(x: x, y: 0),
                    endPoint: CGPoint(x: x, y: size.height)
                ),
                lineWidth: index % 3 == 0 ? 0.7 : 0.35
            )
        }
    }

    func drawMatrixColumns(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        layer: MatrixRainLayer,
        sprites: MatrixRainGlyphAtlas.LayerSprites
    ) {
        let columnWidth = layer.columnWidth
        let rowHeight = layer.rowHeight
        let columns = max(1, Int(size.width / columnWidth) + 4)
        let rows = max(1, Int(size.height / rowHeight) + 12)
        let heightPadding = rowHeight * 3
        let glyphCount = MatrixRainSeed.glyphs.count
        let previousOpacity = context.opacity

        for column in 0..<columns {
            let seed = MatrixRainSeed.columns[column % MatrixRainSeed.columns.count]
            let speed = layer.speedScale * seed.speed
            let phase = seed.phase * Double(rows)
            let drift = CGFloat(sin(time * 0.12 + seed.phase * 8.0)) * seed.drift * layer.driftScale
            let head = animated
                ? (time * speed / Double(rowHeight) + phase).truncatingRemainder(dividingBy: Double(rows))
                : phase.truncatingRemainder(dividingBy: Double(rows))
            let tailLength = layer.tailLength + Int(seed.tailExtra)
            let x = CGFloat(column) * columnWidth + seed.offset * layer.offsetScale + drift - columnWidth

            for tail in 0..<tailLength {
                let row = Int(head) - tail
                let wrappedRow = (row % rows + rows) % rows
                let y = CGFloat(wrappedRow) * rowHeight - heightPadding
                guard y > -rowHeight, y < size.height + rowHeight else { continue }

                let glyphIndex = (column * 17 + wrappedRow * 7 + tail * 3) % glyphCount
                let tailFade = max(0.0, 1.0 - Double(tail) / Double(max(1, tailLength)))
                let shimmer = 0.78 + 0.22 * sin(time * (1.2 + seed.speed * 0.012) + Double(column) * 0.71 + Double(tail))
                let baseAlpha = min(0.98, (0.12 + 0.86 * tailFade * shimmer) * palette.backgroundMotionOpacity * layer.alphaScale)
                let isHead = tail == 0

                if isHead {
                    if !sprites.glow.isEmpty && column.isMultiple(of: 2) {
                        context.opacity = baseAlpha * 0.62 + 0.08
                        context.draw(sprites.glow[glyphIndex], at: CGPoint(x: x - 1.5, y: y - 1.5), anchor: .topLeading)
                    }
                    context.opacity = min(0.96, baseAlpha + 0.24 * layer.alphaScale)
                    context.draw(sprites.head[glyphIndex], at: CGPoint(x: x, y: y), anchor: .topLeading)
                } else {
                    context.opacity = baseAlpha
                    context.draw(sprites.tail[glyphIndex], at: CGPoint(x: x, y: y), anchor: .topLeading)
                }
            }
        }

        context.opacity = previousOpacity
    }
}

private struct AmbientThemeBackdrop: View {
    let effect: AgentThemeBackgroundEffect
    let palette: AgentThemePalette
    let animated: Bool

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                ambientFrame(time: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            ambientFrame(time: 0)
        }
    }

    private func ambientFrame(time: TimeInterval) -> some View {
        Canvas { context, size in
            switch effect {
            case .matrixRain:
                break
            case .midnightDepth:
                drawMidnight(in: &context, size: size, time: time)
            case .whiteGoldVeil:
                drawWhiteGold(in: &context, size: size, time: time)
            case .arcticPrism:
                drawArctic(in: &context, size: size, time: time)
            case .emberPulse:
                drawEmber(in: &context, size: size, time: time)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(animated ? 1 : 0.72)
        .blendMode(palette.isLight ? .softLight : .screen)
    }

    private func drawMidnight(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        drawSoftBloom(
            in: &context,
            size: size,
            center: orbit(size: size, x: 0.74, y: 0.22, radiusX: 0.10, radiusY: 0.06, speed: 0.050, phase: 1.3, time: time),
            radius: max(size.width, size.height) * 0.46,
            colors: [palette.primaryAccent.opacity(0.16), palette.glow.opacity(0.08), .clear]
        )
        drawSoftBloom(
            in: &context,
            size: size,
            center: orbit(size: size, x: 0.22, y: 0.78, radiusX: 0.08, radiusY: 0.05, speed: -0.038, phase: 2.6, time: time),
            radius: max(size.width, size.height) * 0.34,
            colors: [palette.secondaryAccent.opacity(0.10), palette.glow.opacity(0.06), .clear]
        )
        drawRibbon(
            in: &context,
            size: size,
            y: 0.30,
            amplitude: 0.10,
            phase: time * 0.085,
            tint: palette.primaryAccent.opacity(0.13),
            secondaryTint: palette.secondaryAccent.opacity(0.05),
            lineWidth: 46
        )
        drawRibbon(
            in: &context,
            size: size,
            y: 0.62,
            amplitude: 0.07,
            phase: time * -0.065 + 1.7,
            tint: palette.glow.opacity(0.10),
            secondaryTint: palette.primaryAccent.opacity(0.035),
            lineWidth: 34
        )
        drawParticles(
            in: &context,
            size: size,
            time: time,
            count: 26,
            tint: palette.textSecondary.opacity(0.17),
            drift: CGSize(width: 18, height: 9),
            radiusRange: 0.8...1.9
        )
    }

    private func drawWhiteGold(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        drawSoftBloom(
            in: &context,
            size: size,
            center: orbit(size: size, x: 0.28, y: 0.20, radiusX: 0.09, radiusY: 0.05, speed: 0.035, phase: 0.4, time: time),
            radius: max(size.width, size.height) * 0.42,
            colors: [Color.white.opacity(0.36), palette.glow.opacity(0.14), .clear]
        )
        drawSoftBloom(
            in: &context,
            size: size,
            center: orbit(size: size, x: 0.78, y: 0.70, radiusX: 0.07, radiusY: 0.06, speed: -0.045, phase: 1.8, time: time),
            radius: max(size.width, size.height) * 0.36,
            colors: [palette.secondaryAccent.opacity(0.16), Color.white.opacity(0.10), .clear]
        )
        drawRibbon(
            in: &context,
            size: size,
            y: 0.38,
            amplitude: 0.08,
            phase: time * 0.070,
            tint: palette.secondaryAccent.opacity(0.20),
            secondaryTint: Color.white.opacity(0.18),
            lineWidth: 52
        )
        drawRibbon(
            in: &context,
            size: size,
            y: 0.76,
            amplitude: 0.045,
            phase: time * 0.055 + 2.2,
            tint: palette.primaryAccent.opacity(0.10),
            secondaryTint: Color.white.opacity(0.12),
            lineWidth: 28
        )
        drawCaustics(in: &context, size: size, time: time, tint: palette.primaryAccent.opacity(0.09))
    }

    private func drawArctic(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        drawSoftBloom(
            in: &context,
            size: size,
            center: orbit(size: size, x: 0.66, y: 0.18, radiusX: 0.12, radiusY: 0.05, speed: 0.040, phase: 0.9, time: time),
            radius: max(size.width, size.height) * 0.48,
            colors: [palette.primaryAccent.opacity(0.20), palette.secondaryAccent.opacity(0.08), .clear]
        )
        drawRibbon(
            in: &context,
            size: size,
            y: 0.26,
            amplitude: 0.12,
            phase: time * 0.075,
            tint: palette.primaryAccent.opacity(0.22),
            secondaryTint: palette.secondaryAccent.opacity(0.08),
            lineWidth: 48
        )
        drawRibbon(
            in: &context,
            size: size,
            y: 0.48,
            amplitude: 0.09,
            phase: time * -0.060 + 2.5,
            tint: palette.secondaryAccent.opacity(0.16),
            secondaryTint: Color.white.opacity(0.05),
            lineWidth: 36
        )
        drawParticles(
            in: &context,
            size: size,
            time: time,
            count: 34,
            tint: palette.textPrimary.opacity(0.15),
            drift: CGSize(width: 10, height: 18),
            radiusRange: 0.7...2.4
        )
    }

    private func drawEmber(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        drawSoftBloom(
            in: &context,
            size: size,
            center: orbit(size: size, x: 0.72, y: 0.82, radiusX: 0.11, radiusY: 0.06, speed: 0.045, phase: 0.1, time: time),
            radius: max(size.width, size.height) * 0.48,
            colors: [palette.primaryAccent.opacity(0.22), palette.secondaryAccent.opacity(0.10), .clear]
        )
        drawSoftBloom(
            in: &context,
            size: size,
            center: orbit(size: size, x: 0.28, y: 0.18, radiusX: 0.07, radiusY: 0.04, speed: -0.032, phase: 1.6, time: time),
            radius: max(size.width, size.height) * 0.28,
            colors: [palette.secondaryAccent.opacity(0.13), palette.glow.opacity(0.08), .clear]
        )
        drawRibbon(
            in: &context,
            size: size,
            y: 0.70,
            amplitude: 0.10,
            phase: time * 0.090,
            tint: palette.primaryAccent.opacity(0.20),
            secondaryTint: palette.secondaryAccent.opacity(0.08),
            lineWidth: 52
        )
        drawRibbon(
            in: &context,
            size: size,
            y: 0.42,
            amplitude: 0.065,
            phase: time * -0.075 + 2.0,
            tint: palette.secondaryAccent.opacity(0.13),
            secondaryTint: palette.primaryAccent.opacity(0.05),
            lineWidth: 30
        )
        drawParticles(
            in: &context,
            size: size,
            time: time,
            count: 30,
            tint: palette.primaryAccent.opacity(0.24),
            drift: CGSize(width: 8, height: -34),
            radiusRange: 0.9...2.8
        )
    }

    private func drawSoftBloom(
        in context: inout GraphicsContext,
        size: CGSize,
        center: CGPoint,
        radius: CGFloat,
        colors: [Color]
    ) {
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius * 0.62,
                width: radius * 2,
                height: radius * 1.24
            )),
            with: .radialGradient(
                Gradient(colors: colors),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    private func drawRibbon(
        in context: inout GraphicsContext,
        size: CGSize,
        y: CGFloat,
        amplitude: CGFloat,
        phase: Double,
        tint: Color,
        secondaryTint: Color,
        lineWidth: CGFloat
    ) {
        let baseline = size.height * y
        let amp = size.height * amplitude
        var path = Path()
        path.move(to: CGPoint(x: -size.width * 0.12, y: baseline + CGFloat(sin(phase)) * amp))
        path.addCurve(
            to: CGPoint(x: size.width * 1.12, y: baseline + CGFloat(sin(phase + 2.6)) * amp),
            control1: CGPoint(x: size.width * 0.22, y: baseline + CGFloat(sin(phase + 0.9)) * amp * 1.25),
            control2: CGPoint(x: size.width * 0.74, y: baseline + CGFloat(sin(phase + 1.8)) * amp * -1.10)
        )

        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: [.clear, secondaryTint, tint, secondaryTint, .clear]),
                startPoint: CGPoint(x: 0, y: baseline - amp),
                endPoint: CGPoint(x: size.width, y: baseline + amp)
            ),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawParticles(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        count: Int,
        tint: Color,
        drift: CGSize,
        radiusRange: ClosedRange<CGFloat>
    ) {
        let seeds = AmbientMotionSeed.particles
        for index in 0..<min(count, seeds.count) {
            let seed = seeds[index]
            let t = time * seed.speed + seed.phase
            let x = size.width * seed.x + CGFloat(sin(t)) * drift.width
            let y = size.height * seed.y + CGFloat(cos(t * 0.82)) * drift.height
            let radius = radiusRange.lowerBound + (radiusRange.upperBound - radiusRange.lowerBound) * seed.scale
            let alpha = 0.30 + 0.70 * (0.5 + 0.5 * sin(t + seed.phase))
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(tint.opacity(alpha * palette.backgroundMotionOpacity))
            )
        }
    }

    private func drawCaustics(in context: inout GraphicsContext, size: CGSize, time: TimeInterval, tint: Color) {
        for index in 0..<5 {
            let phase = time * (0.04 + Double(index) * 0.011) + Double(index) * 1.4
            let y = CGFloat(0.18 + Double(index) * 0.15) * size.height
            drawRibbon(
                in: &context,
                size: size,
                y: y / max(size.height, 1),
                amplitude: 0.020 + CGFloat(index) * 0.004,
                phase: phase,
                tint: tint,
                secondaryTint: Color.white.opacity(0.10),
                lineWidth: 6 + CGFloat(index % 2) * 5
            )
        }
    }

    private func orbit(
        size: CGSize,
        x: CGFloat,
        y: CGFloat,
        radiusX: CGFloat,
        radiusY: CGFloat,
        speed: Double,
        phase: Double,
        time: TimeInterval
    ) -> CGPoint {
        CGPoint(
            x: size.width * (x + radiusX * CGFloat(sin(time * speed + phase))),
            y: size.height * (y + radiusY * CGFloat(cos(time * speed * 0.82 + phase)))
        )
    }
}

private struct MatrixRainLayer {
    let columnWidth: CGFloat
    let rowHeight: CGFloat
    let speedScale: Double
    let driftScale: CGFloat
    let offsetScale: CGFloat
    let alphaScale: Double
    let tailLength: Int
    let headFontSize: CGFloat
    let tailFontSize: CGFloat
    let glowRadius: CGFloat

    static let distant = MatrixRainLayer(
        columnWidth: 42,
        rowHeight: 31,
        speedScale: 0.68,
        driftScale: 0.45,
        offsetScale: 0.62,
        alphaScale: 0.34,
        tailLength: 4,
        headFontSize: 11,
        tailFontSize: 8,
        glowRadius: 0
    )

    static let near = MatrixRainLayer(
        columnWidth: 30,
        rowHeight: 27,
        speedScale: 1.18,
        driftScale: 1.0,
        offsetScale: 1.0,
        alphaScale: 0.72,
        tailLength: 7,
        headFontSize: 13,
        tailFontSize: 9.5,
        glowRadius: 1.0
    )

    static let staticReduced = MatrixRainLayer(
        columnWidth: 38,
        rowHeight: 30,
        speedScale: 0,
        driftScale: 0,
        offsetScale: 0.40,
        alphaScale: 0.28,
        tailLength: 4,
        headFontSize: 11,
        tailFontSize: 8.5,
        glowRadius: 0
    )
}

private struct MatrixRainColumnSeed {
    let speed: Double
    let phase: Double
    let offset: CGFloat
    let drift: CGFloat
    let tailExtra: Double
}

private enum MatrixRainSeed {
    static let glyphs = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ$#/<>{}[]+-=*~").map { String($0) }
    static let columns: [MatrixRainColumnSeed] = (0..<128).map { index in
        let base = Double(index)
        let speed = 86.0 + Double((index * 37) % 74)
        let phase = Double((index * 53) % 127) / 127.0
        let offset = CGFloat((index * 29) % 15) - 7
        let drift = CGFloat(2 + (index * 11) % 9)
        let tailExtra = Double((index * 17) % 4)
        return MatrixRainColumnSeed(
            speed: speed + sin(base * 0.61) * 11.0,
            phase: phase,
            offset: offset,
            drift: drift,
            tailExtra: tailExtra
        )
    }
}

private struct AmbientParticleSeed {
    let x: CGFloat
    let y: CGFloat
    let speed: Double
    let phase: Double
    let scale: CGFloat
}

private enum AmbientMotionSeed {
    static let particles: [AmbientParticleSeed] = (0..<48).map { index in
        let x = CGFloat(Double((index * 37) % 101) / 100.0)
        let y = CGFloat(Double((index * 61) % 97) / 96.0)
        let speed = 0.030 + Double((index * 13) % 17) / 220.0
        let phase = Double((index * 47) % 113) / 113.0 * Double.pi * 2
        let scale = CGFloat(0.28 + Double((index * 19) % 71) / 100.0)
        return AmbientParticleSeed(x: x, y: y, speed: speed, phase: phase, scale: scale)
    }
}

struct GlassPanelModifier: ViewModifier {
    let radius: CGFloat
    let interactive: Bool
    let tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if AgentTheme.current == .matrixRain || AgentPlatformCompatibility.usesConservativeRendering || reduceTransparency {
            fallback(content: content)
        } else if #available(iOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            content
                .glassEffect(glass, in: shape)
                .shadow(
                    color: AgentPalette.shadow.opacity(interactive ? AgentDesign.softShadowOpacity : 0.035),
                    radius: interactive ? 7 : 2.5,
                    x: 0,
                    y: interactive ? 4 : 1
                )
        } else {
            fallback(content: content)
        }
    }

    private func fallback(content: Content) -> some View {
        let performanceMode = AgentPerformance.prefersReducedVisualEffects
        let isMatrix = AgentTheme.current == .matrixRain
        return content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(isMatrix ? AgentPalette.surfaceElevated.opacity(0.99) : AgentPalette.surfaceElevated)
            )
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill((tint ?? AgentPalette.glassTint).opacity(isMatrix ? 0.08 : (performanceMode ? 0.06 : 0.15)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        AgentPalette.glassStroke.opacity(isMatrix ? 0.62 : (performanceMode ? 0.34 : AgentDesign.borderOpacity)),
                        lineWidth: 0.55
                    )
            )
            .shadow(
                color: AgentPalette.shadow.opacity(performanceMode ? 0.0 : AgentDesign.softShadowOpacity),
                radius: performanceMode ? 0 : 7,
                x: 0,
                y: performanceMode ? 0 : 3
            )
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var effect = Glass.regular.tint(tint ?? AgentPalette.glassTint)
        if interactive {
            effect = effect.interactive()
        }
        return effect
    }
}

extension View {
    func minimumTapTarget(_ size: CGFloat = AgentDesign.minimumTouchTarget) -> some View {
        frame(minWidth: size, minHeight: size)
            .contentShape(Rectangle())
    }

    func agentGlass(radius: CGFloat = AgentDesign.panelRadius, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassPanelModifier(radius: radius, interactive: interactive, tint: tint))
    }

    @ViewBuilder
    func agentSurface(radius: CGFloat = AgentDesign.cardRadius, tint: Color? = nil) -> some View {
        let performanceMode = AgentPerformance.prefersReducedVisualEffects
        let isMatrix = AgentTheme.current == .matrixRain
        let usesNativeGlass = !performanceMode && !isMatrix && !AgentPlatformCompatibility.usesConservativeRendering

        if usesNativeGlass {
            self
                .agentGlass(radius: radius, interactive: false, tint: tint ?? AgentPalette.glassTint)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(AgentPalette.border.opacity(AgentDesign.borderOpacity * 0.92), lineWidth: 0.55)
                )
        } else {
            self
                .background(
                    LinearGradient(
                        colors: [
                            isMatrix ? AgentPalette.surfaceElevated.opacity(0.99) : AgentPalette.surface,
                            (tint ?? AgentPalette.accent).opacity(isMatrix ? 0.07 : (performanceMode ? 0.04 : 0.10)),
                            isMatrix ? AgentPalette.surface.opacity(0.96) : (performanceMode ? AgentPalette.surface : AgentPalette.surfaceAlt)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(AgentPalette.border.opacity(isMatrix ? 0.66 : (performanceMode ? 0.32 : AgentDesign.borderOpacity)), lineWidth: 0.55)
            )
            .shadow(
                color: AgentPalette.shadow.opacity(performanceMode ? 0.0 : AgentDesign.softShadowOpacity),
                radius: performanceMode ? 0 : 6,
                x: 0,
                y: performanceMode ? 0 : 2
            )
        }
    }

    @ViewBuilder
    func agentRowSurface(radius: CGFloat = AgentDesign.rowRadius, tint: Color? = nil, selected: Bool = false) -> some View {
        let performanceMode = AgentPerformance.prefersReducedVisualEffects
        let isMatrix = AgentTheme.current == .matrixRain
        let usesNativeGlass = selected &&
            !performanceMode &&
            !isMatrix &&
            !AgentPlatformCompatibility.usesConservativeRendering

        if usesNativeGlass {
            self
                .agentGlass(radius: radius, interactive: false, tint: (tint ?? AgentPalette.accent).opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder((tint ?? AgentPalette.accent).opacity(AgentDesign.selectedBorderOpacity), lineWidth: 0.55)
                )
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(isMatrix && selected ? AgentPalette.surfaceElevated.opacity(0.98) : (selected ? AgentPalette.rowSelected : AgentPalette.row))
                )
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(isMatrix && selected ? (tint ?? AgentPalette.accent).opacity(0.12) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            selected
                                ? (tint ?? AgentPalette.accent).opacity(isMatrix ? 0.46 : AgentDesign.selectedBorderOpacity)
                                : AgentPalette.border.opacity(isMatrix ? 0.54 : 0.42),
                            lineWidth: 0.55
                        )
                )
                .shadow(
                    color: AgentPalette.shadow.opacity(performanceMode ? 0.0 : (selected ? AgentDesign.softShadowOpacity : 0.0)),
                    radius: performanceMode ? 0 : (selected ? 6 : 0),
                    x: 0,
                    y: performanceMode ? 0 : (selected ? 2 : 0)
                )
        }
    }

    @ViewBuilder
    func agentControlSurface(radius: CGFloat = AgentDesign.controlRadius, tint: Color? = nil, selected: Bool = false) -> some View {
        let performanceMode = AgentPerformance.prefersReducedVisualEffects
        let isMatrix = AgentTheme.current == .matrixRain
        let usesNativeGlass = selected &&
            !performanceMode &&
            !isMatrix &&
            !AgentPlatformCompatibility.usesConservativeRendering

        if usesNativeGlass {
            self
                .agentGlass(radius: radius, interactive: false, tint: (tint ?? AgentPalette.accent).opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder((tint ?? AgentPalette.accent).opacity(AgentDesign.selectedBorderOpacity), lineWidth: 0.55)
                )
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(isMatrix && selected ? AgentPalette.controlFill : (selected ? AgentPalette.controlFillSelected : AgentPalette.controlFill))
                )
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(isMatrix && selected ? (tint ?? AgentPalette.accent).opacity(0.16) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            selected
                                ? (tint ?? AgentPalette.accent).opacity(isMatrix ? 0.54 : AgentDesign.selectedBorderOpacity)
                                : AgentPalette.controlBorder.opacity(isMatrix ? 0.92 : 0.82),
                            lineWidth: 0.55
                        )
                )
                .shadow(
                    color: AgentPalette.shadow.opacity(performanceMode ? 0.0 : (selected ? AgentDesign.softShadowOpacity : 0.0)),
                    radius: performanceMode ? 0 : (selected ? 5 : 0),
                    x: 0,
                    y: performanceMode ? 0 : (selected ? 2 : 0)
                )
        }
    }
}

struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if AgentPlatformCompatibility.usesConservativeRendering {
            content
        } else if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

struct BottomDockContentShield: View {
    var height: CGFloat = BottomDockMetrics.scrollClearance

    var body: some View {
        Color.clear
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The app's signature haptic vocabulary. One place, so every surface
/// speaks the same physical language: runs thump when they start, purr on
/// success, buzz on failure, and approvals knock twice.
@MainActor
enum NovaHaptics {
    static func runStarted() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.9)
    }

    static func runSucceeded() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func runFailed() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func approvalNeeded() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.impactOccurred(intensity: 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            generator.impactOccurred(intensity: 0.6)
        }
    }

    static func tick() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
    }
}

enum BottomDockMetrics {
    static let shieldHeight: CGFloat = 126
    static let scrollClearance: CGFloat = 176
    static let terminalScrollClearance: CGFloat = 224
    static let gutterScrimHeight: CGFloat = 150
}

/// Theme-aware gradient that dissolves scroll content before it reaches the
/// floating dock and home-indicator gutter. Without it, razor-sharp text
/// collides with the dock pill and refracts through its Liquid Glass as
/// doubled ghost glyphs (worst in matrix and whiteGold captures).
struct DockGutterScrim: View {
    var height: CGFloat = BottomDockMetrics.gutterScrimHeight

    var body: some View {
        let boost: Double = AgentTheme.current == .matrixRain ? 0.10 : 0
        LinearGradient(
            stops: [
                .init(color: AgentPalette.pearl.opacity(0), location: 0),
                .init(color: AgentPalette.pearl.opacity(min(1, 0.58 + boost)), location: 0.44),
                .init(color: AgentPalette.pearl.opacity(1.0), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    func bottomDockContentShield(height: CGFloat = BottomDockMetrics.scrollClearance) -> some View {
        overlay(alignment: .bottom) {
            BottomDockContentShield(height: height)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// Native iOS 26 progressive fade where scroll content passes beneath the
    /// floating tab dock. Without it, stray text renders razor-sharp in the
    /// home-indicator gutter around the dock pill (glaring in the matrix
    /// theme, where mono glyphs glow). No-ops under conservative rendering.
    @ViewBuilder
    func agentDockEdgeFade() -> some View {
        if AgentPlatformCompatibility.usesConservativeRendering {
            self
        } else if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self
        }
    }
}

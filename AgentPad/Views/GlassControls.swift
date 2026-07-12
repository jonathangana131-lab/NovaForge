import SwiftData
import SwiftUI

private struct AgentLiquidGlassSurfaceModifier: ViewModifier {
    enum Level: Equatable {
        case control
        case row
        case card

        var shadowRadius: CGFloat {
            switch self {
            case .control: 7
            case .row: 10
            case .card: 16
            }
        }

        var shadowY: CGFloat {
            switch self {
            case .control: 3
            case .row: 5
            case .card: 9
            }
        }
    }

    let radius: CGFloat
    let tint: Color?
    let selected: Bool
    let level: Level
    let interactive: Bool
    let pressed: Bool
    let enabled: Bool
    let nativeGlass: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let accent = tint ?? AgentPalette.accent
        let isMatrix = AgentTheme.current == .matrixRain
        let performanceMode = AgentPerformance.prefersReducedVisualEffects
        let shouldAnimate = AgentPerformance.allowsDecorativeMotion && !reduceMotion
        let highlightOpacity = selected ? 0.18 : 0.075
        let borderOpacity = selected ? 0.32 : 0.16
        let pressedAdjustment = pressed ? 0.82 : 1.0
        let usesNativeGlass = nativeGlass &&
            !performanceMode &&
            !reduceTransparency &&
            !isMatrix &&
            !AgentPlatformCompatibility.usesConservativeRendering &&
            (level == .card || (interactive && enabled))
        let baseSurfaceOpacity = reduceTransparency || performanceMode ? 0.98 : (isMatrix ? 0.97 : 0.74)
        let altSurfaceOpacity = reduceTransparency || performanceMode ? 0.82 : (isMatrix ? 0.88 : 0.58)
        let materialOpacity: Double = {
            guard !isMatrix else { return 0 }
            guard !usesNativeGlass, !reduceTransparency, !performanceMode else { return 0 }
            switch level {
            case .control: return interactive ? 0.24 : 0.16
            case .row: return 0.30
            case .card: return 0.42
            }
        }()
        let selectedGlowAllowed = selected && (level != .control || interactive)
        let shadowRadius = performanceMode || (level == .control && !interactive) ? 0 : level.shadowRadius
        let shadowY = performanceMode || (level == .control && !interactive) ? 0 : level.shadowY
        let accentShadowOpacity: Double = {
            guard !performanceMode, selected, level == .card || interactive else { return 0 }
            return level == .card ? 0.10 : 0.06
        }()

        if usesNativeGlass {
            content
                .clipShape(shape)
                .agentGlass(
                    radius: radius,
                    interactive: interactive && enabled,
                    tint: selected ? accent.opacity(0.20) : accent.opacity(0.06)
                )
                .scaleEffect(pressed ? 0.982 : 1)
                .brightness(pressed ? -0.018 : 0)
                .saturation(enabled ? 1 : 0.65)
                .animation(shouldAnimate ? .snappy(duration: 0.18, extraBounce: 0.04) : nil, value: pressed)
                .animation(shouldAnimate ? .snappy(duration: 0.20, extraBounce: 0.03) : nil, value: selected)
        } else {
            content
                .background(
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    AgentPalette.surface.opacity(baseSurfaceOpacity),
                                    accent.opacity((performanceMode ? highlightOpacity * 0.42 : highlightOpacity + 0.035) * pressedAdjustment),
                                    (isMatrix ? AgentPalette.surfaceElevated : AgentPalette.surfaceAlt).opacity(altSurfaceOpacity)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .background(
                    shape
                        .fill(.ultraThinMaterial)
                        .opacity(materialOpacity)
                )
                .overlay(alignment: .topLeading) {
                    shape
                        .strokeBorder(
                            AgentPalette.glassStroke
                                .opacity(performanceMode ? 0.12 : (selected ? 0.48 : 0.30)),
                            lineWidth: 0.65
                        )
                        .blendMode(isMatrix || performanceMode ? .normal : .screen)
                }
                .overlay(alignment: .bottomTrailing) {
                    shape
                        .strokeBorder(accent.opacity(borderOpacity), lineWidth: selected ? 0.85 : 0.55)
                }
                .overlay {
                    if !performanceMode && (pressed || selectedGlowAllowed) {
                        shape
                            .fill(
                                RadialGradient(
                                    colors: [
                                        accent.opacity(pressed ? 0.20 : 0.15),
                                        accent.opacity(0.04),
                                        .clear
                                    ],
                                    center: .topLeading,
                                    startRadius: 0,
                                    endRadius: 120
                                )
                            )
                            .blendMode(.plusLighter)
                            .opacity(reduceTransparency ? 0.35 : 1)
                    }
                }
                .overlay(alignment: .top) {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                    colors: [
                                        AgentPalette.glassStroke.opacity(isMatrix ? 0.36 : 0.45),
                                        AgentPalette.glassStroke.opacity(isMatrix ? 0.10 : 0.08),
                                        .clear
                                    ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1.2)
                        .padding(.horizontal, max(8, radius * 0.52))
                        .opacity(reduceTransparency ? 0.22 : (performanceMode ? 0.18 : (level == .control && !interactive ? 0.36 : 0.58)))
                }
                .clipShape(shape)
                .shadow(
                    color: AgentPalette.shadow.opacity(performanceMode || shadowRadius == 0 ? 0.0 : (selected ? 0.10 : 0.05)),
                    radius: shadowRadius,
                    x: 0,
                    y: shadowY
                )
                .shadow(
                    color: accent.opacity(accentShadowOpacity),
                    radius: accentShadowOpacity > 0 ? level.shadowRadius * 0.72 : 0,
                    x: 0,
                    y: accentShadowOpacity > 0 ? 3 : 0
                )
                .scaleEffect(pressed ? 0.985 : 1)
                .brightness(pressed ? -0.012 : 0)
                .saturation(enabled ? 1 : 0.65)
                .animation(shouldAnimate ? .snappy(duration: 0.18, extraBounce: 0.04) : nil, value: pressed)
                .animation(shouldAnimate ? .snappy(duration: 0.20, extraBounce: 0.03) : nil, value: selected)
        }
    }
}

private extension View {
    func agentLiquidSurface(
        radius: CGFloat,
        tint: Color? = nil,
        selected: Bool = false,
        level: AgentLiquidGlassSurfaceModifier.Level = .control,
        interactive: Bool = false,
        pressed: Bool = false,
        enabled: Bool = true,
        nativeGlass: Bool = false
    ) -> some View {
        modifier(
            AgentLiquidGlassSurfaceModifier(
                radius: radius,
                tint: tint,
                selected: selected,
                level: level,
                interactive: interactive,
                pressed: pressed,
                enabled: enabled,
                nativeGlass: nativeGlass
            )
        )
    }
}

private struct AgentLiquidGlassButtonStyle: ButtonStyle {
    let radius: CGFloat
    let tint: Color?
    let selected: Bool
    let level: AgentLiquidGlassSurfaceModifier.Level
    var glassID: String? = nil
    var glassNamespace: Namespace.ID? = nil

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .agentLiquidSurface(
                radius: radius,
                tint: tint,
                selected: selected,
                level: level,
                interactive: true,
                pressed: configuration.isPressed,
                enabled: isEnabled,
                nativeGlass: true
            )
            .agentGlassEffectID(glassID, in: glassNamespace)
    }
}

extension View {
    /// The shared press-responsive native glass treatment for isolated chrome
    /// buttons. Keeping the implementation here lets feature views opt into
    /// one bounded effect without exposing the surface modifier internals.
    func agentInteractiveGlassButtonStyle(
        radius: CGFloat = AgentDesign.controlRadius,
        tint: Color? = nil,
        selected: Bool = false,
        glassID: String? = nil,
        in namespace: Namespace.ID? = nil
    ) -> some View {
        buttonStyle(
            AgentLiquidGlassButtonStyle(
                radius: radius,
                tint: tint,
                selected: selected,
                level: .control,
                glassID: glassID,
                glassNamespace: namespace
            )
        )
    }
}

struct HeaderView: View {
    let title: String
    let subtitle: String
    let symbol: String
    var tint: Color = AgentPalette.accent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .agentLiquidSurface(radius: AgentDesign.rowRadius, tint: tint, selected: true, level: .control)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.title3, design: AgentPalette.interfaceFontDesign, weight: .bold))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer()
        }
    }
}

struct StatusChip: View {
    let text: String
    let symbol: String
    var tint = AgentPalette.accent

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AgentPalette.ink)
            .padding(.horizontal, AgentDesign.rowPadding - 2)
            .frame(height: AgentDesign.compactControlHeight)
            .agentLiquidSurface(radius: AgentDesign.chipRadius, tint: tint, selected: true, level: .control)
    }
}

struct MenuStatChip: View {
    let title: String
    let value: String
    let symbol: String
    var tint = AgentPalette.accent

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .agentLiquidSurface(radius: 9, tint: tint, selected: true, level: .control)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .padding(AgentDesign.rowPadding - 2)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .agentLiquidSurface(radius: AgentDesign.rowRadius, tint: tint, selected: true, level: .row)
    }
}

struct IconGlassButton: View {
    let symbol: String
    let accessibilityLabel: String
    var accessibilityIdentifier: String? = nil
    var tint: Color? = nil
    var glassID: String? = nil
    var glassNamespace: Namespace.ID? = nil
    let action: () -> Void

    var body: some View {
        let accent = tint ?? AgentPalette.secondaryText
        Button {
            NovaHaptics.tick()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint ?? AgentPalette.ink)
                .frame(width: AgentDesign.controlHeight, height: AgentDesign.controlHeight)
                .contentShape(Circle())
        }
        .agentInteractiveGlassButtonStyle(
            radius: AgentDesign.controlHeight / 2,
            tint: accent,
            selected: tint != nil,
            glassID: glassID,
            in: glassNamespace
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier ?? accessibilityLabel)
    }
}

enum AgentActionTone {
    case primary
    case secondary
    case destructive

    var tint: Color {
        switch self {
        case .primary: AgentPalette.accent
        case .secondary: AgentPalette.secondaryText
        case .destructive: AgentPalette.rose
        }
    }

    var selected: Bool {
        switch self {
        case .primary, .destructive: true
        case .secondary: false
        }
    }

    var foreground: Color {
        switch self {
        case .destructive: AgentPalette.rose
        default: AgentPalette.ink
        }
    }
}

struct AgentActionButton: View {
    let title: String
    var symbol: String? = nil
    var tone: AgentActionTone = .primary
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .lineLimit(1)
            }
            .foregroundStyle(tone.foreground)
            .frame(maxWidth: .infinity, minHeight: AgentDesign.controlHeight)
            .padding(.horizontal, AgentDesign.rowPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            AgentLiquidGlassButtonStyle(
                radius: AgentDesign.controlRadius,
                tint: tone.tint,
                selected: tone.selected,
                level: .control
            )
        )
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1.0)
    }
}

struct AgentSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .textCase(.uppercase)
                .tracking(0.4)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AgentInlineStateView: View {
    let title: String
    let detail: String
    let symbol: String
    var tint = AgentPalette.cyan
    var isLoading = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(tint)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 30, height: 30)
            .background(
                Circle()
                    .fill(tint.opacity(0.10))
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

struct AgentCenteredStateView: View {
    let title: String
    let detail: String
    let symbol: String
    var tint = AgentPalette.cyan
    var isLoading = false

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if isLoading {
                    ProgressView()
                        .tint(tint)
                } else {
                    Image(systemName: symbol)
                        .font(.title.weight(.bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 58, height: 58)
            .agentControlSurface(radius: 18, tint: tint, selected: true)

            VStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

struct WorkspaceStatusSnapshot: Equatable, Sendable {
    enum Tone: String, Equatable, Sendable {
        case approval
        case error
        case paused
        case working
        case changed
        case ready
    }

    let isVisible: Bool
    let blocksCommand: Bool
    let isWorking: Bool
    let title: String
    let detail: String
    let tone: Tone
    let changedText: String?
    let progressSteps: [WorkspaceProgressStep]

    static let hidden = WorkspaceStatusSnapshot(
        isVisible: false,
        blocksCommand: false,
        isWorking: false,
        title: "Workspace ready",
        detail: "Chat, files, runs, and terminal share this sandbox.",
        tone: .ready,
        changedText: nil,
        progressSteps: []
    )

    @MainActor
    init(runtime: AgentRuntime) {
        let artifactCount = runtime.currentArtifacts.count
        let firstArtifactTitle = runtime.currentArtifacts.first?.title
        let pendingToolName = runtime.pendingTool?.name
        let pendingToolSummary = runtime.pendingTool.map {
            AgentActivityPresentation.presentation(forToolName: $0.name, arguments: $0.arguments).title
        }
        let activeToolSummary = runtime.activeToolName.map {
            AgentActivityPresentation.presentation(forToolName: $0, detail: runtime.activeToolDetail)
        }
        let hasStartingPlannedProgress = !runtime.plannedProgressSteps.isEmpty &&
            !runtime.isWorking &&
            runtime.lastRunDuration == nil &&
            runtime.lastError == nil &&
            !runtime.wasInterrupted &&
            pendingToolName == nil &&
            artifactCount == 0 &&
            runtime.runState != .completed
        isVisible = hasStartingPlannedProgress ||
            pendingToolName != nil ||
            runtime.isWorking ||
            runtime.wasInterrupted ||
            runtime.lastError != nil ||
            artifactCount > 0 ||
            runtime.queuedPromptCount > 0
        blocksCommand = pendingToolName != nil || runtime.isWorking || hasStartingPlannedProgress
        isWorking = runtime.isWorking || hasStartingPlannedProgress

        if let pendingToolSummary {
            title = "\(pendingToolSummary) needs approval"
        } else if hasStartingPlannedProgress {
            title = AgentActivityPresentation.humanizedVisibleText(runtime.activityTitle, fallback: "Getting ready")
        } else if runtime.isWorking {
            title = activeToolSummary.map { "Running \($0.title)" } ?? AgentActivityPresentation.humanizedVisibleText(runtime.activityTitle, fallback: "Working")
        } else if runtime.wasInterrupted {
            title = "Run paused"
        } else if runtime.lastError != nil {
            title = "Recovery available"
        } else if artifactCount > 0 {
            title = "Changes ready"
        } else {
            title = "Workspace ready"
        }

        if hasStartingPlannedProgress || runtime.isWorking || runtime.wasInterrupted || runtime.lastError != nil || pendingToolName != nil {
            detail = activeToolSummary?.target ?? AgentActivityPresentation.humanizedVisibleText(runtime.activityDetail, fallback: "Working on the current run.")
        } else if let firstArtifactTitle {
            let extraCount = artifactCount - 1
            detail = extraCount > 0 ? "\(firstArtifactTitle) and \(extraCount) more changed" : "\(firstArtifactTitle) changed"
        } else {
            detail = "Chat, files, runs, and terminal share this sandbox."
        }

        if pendingToolName != nil {
            tone = .approval
        } else if runtime.lastError != nil {
            tone = .error
        } else if runtime.wasInterrupted {
            tone = .paused
        } else if runtime.isWorking || hasStartingPlannedProgress {
            tone = .working
        } else if artifactCount > 0 {
            tone = .changed
        } else {
            tone = .ready
        }

        changedText = artifactCount > 0 ? "\(artifactCount) changed" : nil
        progressSteps = Self.makeProgressSteps(
            runtime: runtime,
            artifactCount: artifactCount,
            firstArtifactTitle: firstArtifactTitle,
            pendingToolName: pendingToolName
        )
    }

    private init(
        isVisible: Bool,
        blocksCommand: Bool,
        isWorking: Bool,
        title: String,
        detail: String,
        tone: Tone,
        changedText: String?,
        progressSteps: [WorkspaceProgressStep]
    ) {
        self.isVisible = isVisible
        self.blocksCommand = blocksCommand
        self.isWorking = isWorking
        self.title = title
        self.detail = detail
        self.tone = tone
        self.changedText = changedText
        self.progressSteps = progressSteps
    }

    @MainActor
    private static func makeProgressSteps(
        runtime: AgentRuntime,
        artifactCount: Int,
        firstArtifactTitle: String?,
        pendingToolName: String?
    ) -> [WorkspaceProgressStep] {
        guard pendingToolName != nil ||
                runtime.isWorking ||
                runtime.wasInterrupted ||
                runtime.lastError != nil ||
                artifactCount > 0 ||
                runtime.queuedPromptCount > 0 ||
                !runtime.plannedProgressSteps.isEmpty ||
                !runtime.traceEvents.isEmpty else {
            return []
        }

        let traces = runtime.traceEvents
        let latestPlanning = traces.first { $0.status == .queued || $0.status == .thinking || $0.status == .planning }
        let latestTool = traces.first { $0.status == .tool || $0.status == .executing }
        let latestApproval = traces.first { $0.status == .approval }
        let latestSuccess = traces.first { $0.status == .success }
        let latestFailure = traces.first { $0.status == .failed }
        let hasFailureTrace = latestFailure != nil
        let hasSuccessTrace = latestSuccess != nil
        let isBlocked: Bool = {
            if runtime.lastError != nil { return true }
            if case .failed = runtime.runState { return true }
            return hasFailureTrace && !runtime.isWorking && pendingToolName == nil
        }()
        let hasCompletion = runtime.runState == .completed ||
            runtime.lastRunDuration != nil ||
            artifactCount > 0 ||
            (hasSuccessTrace && !runtime.isWorking && pendingToolName == nil)
        let isSavingProof = runtime.activityTitle.localizedCaseInsensitiveContains("saving") ||
            runtime.activityTitle.localizedCaseInsensitiveContains("finalizing")
        let didUseTools = latestTool != nil ||
            traces.contains { $0.title.localizedCaseInsensitiveContains("tool") || $0.title.localizedCaseInsensitiveContains("command") }
        let activeToolSummary = runtime.activeToolName.map {
            AgentActivityPresentation.presentation(forToolName: $0, detail: runtime.activeToolDetail)
        }
        let activeToolDetail = activeToolSummary.map { summary in
            [summary.title, summary.target].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        }

        func compact(_ text: String?, fallback: String) -> String {
            let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return fallback }
            let humanValue = AgentActivityPresentation.humanizedVisibleDetail(value) ?? AgentActivityPresentation.humanizedVisibleText(value, fallback: fallback)
            return humanValue.count > 86 ? String(humanValue.prefix(85)) + "..." : humanValue
        }

        if !runtime.plannedProgressSteps.isEmpty {
            return reconcilePlannedProgressSteps(
                runtime.plannedProgressSteps,
                runtime: runtime,
                pendingToolName: pendingToolName,
                hasCompletion: hasCompletion,
                isBlocked: isBlocked,
                artifactCount: artifactCount,
                firstArtifactTitle: firstArtifactTitle,
                latestFailure: latestFailure,
                compact: compact
            )
        }

        func readState(matches words: [String]) -> Bool {
            let lower = "\(runtime.activityTitle) \(runtime.activityDetail)".lowercased()
            return words.contains { lower.contains($0) }
        }

        var steps: [WorkspaceProgressStep] = [
            WorkspaceProgressStep(
                id: "decide",
                title: "Deciding next step",
                detail: compact(latestPlanning?.detail, fallback: "Project command selected from current state."),
                symbolName: "arrow.triangle.branch",
                state: runtime.isWorking && traces.isEmpty ? .current : .done
            ),
            WorkspaceProgressStep(
                id: "read",
                title: "Reading project state",
                detail: readState(matches: ["reading", "syncing", "loading", "preparing"]) ? runtime.activityDetail : "Mission, timeline, files, runs, and proof are in context.",
                symbolName: "doc.text.magnifyingglass",
                state: readState(matches: ["reading", "syncing", "loading", "preparing"]) ? .current : .done
            ),
            WorkspaceProgressStep(
                id: "inspect",
                title: "Inspecting evidence",
                detail: compact(latestPlanning?.title, fallback: "Checking recent activity and workspace evidence."),
                symbolName: "text.viewfinder",
                state: runtime.isWorking && runtime.activeToolName == nil && pendingToolName == nil ? .current : (traces.isEmpty ? .pending : .done)
            ),
            WorkspaceProgressStep(
                id: "tools",
                title: "Using tools",
                detail: activeToolDetail ?? compact(latestTool?.title, fallback: "No active tool."),
                symbolName: "wrench.and.screwdriver.fill",
                state: runtime.activeToolName != nil && pendingToolName == nil ? .current : (didUseTools ? .done : .pending)
            ),
            WorkspaceProgressStep(
                id: "approval",
                title: "Waiting for approval",
                detail: pendingToolName.map { "\($0) is paused for review." } ?? compact(latestApproval?.title, fallback: "No approval is waiting."),
                symbolName: "checkmark.shield.fill",
                state: pendingToolName != nil ? .current : (latestApproval == nil ? .pending : .done)
            ),
            WorkspaceProgressStep(
                id: "proof",
                title: "Saving proof",
                detail: firstArtifactTitle.map { "\($0) is available as proof." } ?? compact(latestSuccess?.detail, fallback: "Project evidence will be recorded when the run finishes."),
                symbolName: "checkmark.seal.fill",
                state: isBlocked ? .blocked : (isSavingProof ? .current : (hasCompletion ? .done : .pending))
            )
        ]

        if runtime.queuedPromptCount > 0 {
            steps.append(WorkspaceProgressStep(
                id: "queued",
                title: "Queued follow-up",
                detail: "\(runtime.queuedPromptCount) request\(runtime.queuedPromptCount == 1 ? "" : "s") waiting behind the active run.",
                symbolName: "tray.full.fill",
                state: .current
            ))
        }

        let finalTitle: String
        let finalDetail: String
        let finalState: WorkspaceProgressStep.State
        if isBlocked {
            finalTitle = "Blocked"
            finalDetail = runtime.lastError ?? latestFailure?.detail ?? "Review failed evidence before continuing."
            finalState = .blocked
        } else if pendingToolName != nil {
            finalTitle = "Waiting approval"
            finalDetail = "Run will continue after the approval decision."
            finalState = .current
        } else if runtime.wasInterrupted {
            finalTitle = "Paused"
            finalDetail = "Continue from the saved activity when ready."
            finalState = .current
        } else if hasCompletion {
            finalTitle = hasFailureTrace && hasSuccessTrace ? "Recovered" : "Completed"
            finalDetail = runtime.lastRunDuration.map { $0 < 1 ? String(format: "Finished in %.0fms.", $0 * 1000) : String(format: "Finished in %.1fs.", $0) } ?? "Latest proof is ready."
            finalState = .done
        } else {
            finalTitle = "Running"
            finalDetail = runtime.activityDetail
            finalState = runtime.isWorking ? .current : .pending
        }

        steps.append(WorkspaceProgressStep(
            id: "result",
            title: finalTitle,
            detail: compact(finalDetail, fallback: "Workspace ready."),
            symbolName: finalState == .blocked ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
            state: finalState
        ))

        return steps
    }

    @MainActor
    private static func reconcilePlannedProgressSteps(
        _ plannedSteps: [WorkspaceProgressStep],
        runtime: AgentRuntime,
        pendingToolName: String?,
        hasCompletion: Bool,
        isBlocked: Bool,
        artifactCount: Int,
        firstArtifactTitle: String?,
        latestFailure: AgentTraceEvent?,
        compact: (String?, String) -> String
    ) -> [WorkspaceProgressStep] {
        var steps = plannedSteps
        guard !steps.isEmpty else { return [] }

        let traceCount = runtime.traceEvents.count
        let activeToolSummary = runtime.activeToolName.map {
            AgentActivityPresentation.presentation(forToolName: $0, detail: runtime.activeToolDetail)
        }
        let activeIndex: Int
        if hasCompletion {
            activeIndex = steps.count
        } else if pendingToolName != nil {
            activeIndex = max(1, min(steps.count - 1, steps.firstIndex { $0.id.localizedCaseInsensitiveContains("proof") } ?? steps.count - 1))
        } else if runtime.activeToolName != nil {
            activeIndex = min(max(2, traceCount / 2 + 1), max(steps.count - 2, 0))
        } else if runtime.isWorking || runtime.wasInterrupted || runtime.queuedPromptCount > 0 {
            activeIndex = min(max(1, traceCount / 2), max(steps.count - 1, 0))
        } else {
            activeIndex = 0
        }

        for index in steps.indices {
            if isBlocked, index >= activeIndex {
                steps[index].state = index == activeIndex ? .blocked : .pending
            } else if hasCompletion {
                steps[index].state = .done
            } else if index < activeIndex {
                steps[index].state = .done
            } else if index == activeIndex {
                steps[index].state = .current
            } else {
                steps[index].state = .pending
            }
        }

        if let pendingToolName,
           let approvalIndex = steps.firstIndex(where: { $0.title.localizedCaseInsensitiveContains("approval") || $0.id.localizedCaseInsensitiveContains("approval") }) {
            steps[approvalIndex].title = "Waiting for approval"
            steps[approvalIndex].detail = "\(pendingToolName) is paused for review."
            steps[approvalIndex].symbolName = "checkmark.shield.fill"
            steps[approvalIndex].state = .current
        }

        if artifactCount > 0,
           let proofIndex = steps.firstIndex(where: { $0.id.localizedCaseInsensitiveContains("proof") }) {
            steps[proofIndex].detail = firstArtifactTitle.map { "\($0) is available as proof." } ?? steps[proofIndex].detail
            if !isBlocked {
                steps[proofIndex].state = hasCompletion ? .done : steps[proofIndex].state
            }
        }

        if isBlocked {
            steps.append(WorkspaceProgressStep(
                id: "planned-blocked",
                title: "Blocked",
                detail: compact(runtime.lastError ?? latestFailure?.detail, "Review failed evidence before continuing."),
                symbolName: "exclamationmark.triangle.fill",
                state: .blocked
            ))
        } else if pendingToolName != nil {
            steps.append(WorkspaceProgressStep(
                id: "planned-approval",
                title: "Approval waiting",
                detail: "Run will continue after the approval decision.",
                symbolName: "checkmark.shield.fill",
                state: .current
            ))
        } else if runtime.wasInterrupted {
            steps.append(WorkspaceProgressStep(
                id: "planned-paused",
                title: "Paused",
                detail: "Continue from the saved activity when ready.",
                symbolName: "pause.circle.fill",
                state: .current
            ))
        } else if hasCompletion {
            steps.append(WorkspaceProgressStep(
                id: "planned-complete",
                title: "Completed",
                detail: runtime.lastRunDuration.map { $0 < 1 ? String(format: "Finished in %.0fms.", $0 * 1000) : String(format: "Finished in %.1fs.", $0) } ?? "Latest proof is ready.",
                symbolName: "checkmark.circle.fill",
                state: .done
            ))
        } else if runtime.isWorking {
            steps.append(WorkspaceProgressStep(
                id: "planned-running",
                title: activeToolSummary.map { "Running \($0.title)" } ?? AgentActivityPresentation.humanizedVisibleText(runtime.activityTitle, fallback: "Working"),
                detail: activeToolSummary?.target ?? AgentActivityPresentation.humanizedVisibleText(runtime.activityDetail, fallback: "Working on the current run."),
                symbolName: "waveform",
                state: .current
            ))
        }

        return steps
    }

    var tint: Color {
        switch tone {
        case .approval: AgentPalette.cyan
        case .error: AgentPalette.rose
        case .paused: AgentPalette.cyan
        case .working: AgentPalette.lilac
        case .changed: AgentPalette.green
        case .ready: AgentPalette.lilac
        }
    }

    var symbol: String {
        switch tone {
        case .approval: "checkmark.shield.fill"
        case .error: "exclamationmark.triangle.fill"
        case .paused: "pause.fill"
        case .working: "waveform"
        case .changed: "doc.badge.gearshape.fill"
        case .ready: "sparkles"
        }
    }
}

struct WorkspaceStatusStrip: View {
    @Environment(\.modelContext) private var modelContext
    @Namespace private var glassNamespace
    private var runtime: AgentRuntime?
    let snapshot: WorkspaceStatusSnapshot
    var pause: (() -> Void)?
    let destinationSymbol: String
    let destinationAccessibilityLabel: String
    let openChat: () -> Void

    @MainActor
    init(runtime: AgentRuntime, openChat: @escaping () -> Void) {
        self.runtime = runtime
        self.snapshot = WorkspaceStatusSnapshot(runtime: runtime)
        self.pause = nil
        self.destinationSymbol = "bubble.left.and.bubble.right.fill"
        self.destinationAccessibilityLabel = "Open chat"
        self.openChat = openChat
    }

    init(
        snapshot: WorkspaceStatusSnapshot,
        pause: (() -> Void)? = nil,
        destinationSymbol: String = "bubble.left.and.bubble.right.fill",
        destinationAccessibilityLabel: String = "Open chat",
        openChat: @escaping () -> Void
    ) {
        self.runtime = nil
        self.snapshot = snapshot
        self.pause = pause
        self.destinationSymbol = destinationSymbol
        self.destinationAccessibilityLabel = destinationAccessibilityLabel
        self.openChat = openChat
    }

    var body: some View {
        let tint = snapshot.tint
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                if snapshot.isWorking && AgentPerformance.allowsDecorativeMotion {
                    Circle()
                        .stroke(tint.opacity(0.5), lineWidth: 1.4)
                        .frame(width: 15, height: 15)
                }
            }
            .frame(width: 18, height: 18)
            .shadow(color: AgentPerformance.prefersReducedVisualEffects ? .clear : tint.opacity(0.7), radius: 4)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.title)
                    .font(NovaType.headline)
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                Text(snapshot.detail)
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let changedText = snapshot.changedText {
                Text(changedText)
                    .novaLabel(AgentPalette.green)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule(style: .continuous).fill(AgentPalette.green.opacity(0.12)))
                    .overlay(Capsule(style: .continuous).strokeBorder(AgentPalette.green.opacity(0.30), lineWidth: 0.8))
            }

            if snapshot.isWorking {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if let pause {
                        pause()
                    } else {
                        runtime?.stopGenerating(context: modelContext)
                    }
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AgentPalette.rose)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .agentInteractiveGlassButtonStyle(
                    radius: 19,
                    tint: AgentPalette.rose,
                    selected: true,
                    glassID: "workspace-status-pause",
                    in: glassNamespace
                )
                .accessibilityLabel("Pause run")
                .accessibilityIdentifier("workspaceStatusPauseButton")
            }

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                openChat()
            } label: {
                Image(systemName: destinationSymbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .agentInteractiveGlassButtonStyle(
                radius: 19,
                tint: tint,
                selected: false,
                glassID: "workspace-status-destination",
                in: glassNamespace
            )
            .accessibilityLabel(destinationAccessibilityLabel)
            .accessibilityIdentifier(destinationAccessibilityLabel == "Open chat" ? "workspaceStatusOpenChatButton" : "workspaceStatusOpenDestinationButton")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .agentGlass(radius: 22, tint: tint.opacity(0.10))
        .agentGlassEffectID("workspace-status", in: glassNamespace)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspaceStatusStrip")
    }
}

struct MissionOSStatusStrip: View, Equatable {
    let contract: MissionOSContract
    var surfaceName: String

    private var tint: Color {
        if !contract.blockingGates.isEmpty { return AgentPalette.rose }
        if contract.readinessScore >= 85 && contract.decisionLabel == "Ready to review" { return AgentPalette.green }
        switch contract.phase {
        case .contract:
            return AgentPalette.cyan
        case .plan, .act:
            return AgentPalette.lilac
        case .verify:
            return AgentPalette.indigo
        case .proof, .decide:
            return AgentPalette.green
        }
    }

    private var compactDetail: String {
        let directive = contract.operatorDirective.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directive.isEmpty { return directive }
        return contract.proofRequirement
    }

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Mission OS Strip Body")
        HStack(spacing: 10) {
            Image(systemName: contract.phase.symbolName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .agentLiquidSurface(radius: 10, tint: tint, selected: true, level: .control)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Mission OS")
                        .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(contract.phase.displayName)
                        .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .agentLiquidSurface(radius: 8, tint: tint, selected: true, level: .control)
                }

                Text(compactDetail)
                    .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(contract.readinessScore)%")
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                Text(contract.decisionLabel)
                    .font(.system(size: 8, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
            }
            .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(10)
        .agentLiquidSurface(radius: 18, tint: tint, selected: true, level: .card, nativeGlass: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(surfaceName) Mission OS. \(contract.phase.displayName). \(contract.readinessScore) percent ready. \(contract.decisionLabel). \(compactDetail)")
        .accessibilityIdentifier("missionOSStatusStrip-\(surfaceName)")
    }
}

extension AgentRuntime {
    var shouldShowWorkspaceStatusStrip: Bool {
        pendingTool != nil ||
        isWorking ||
        wasInterrupted ||
        lastError != nil ||
        !currentArtifacts.isEmpty ||
        queuedPromptCount > 0
    }
}

/// Visual surface for an `AgentToast`. The data model itself lives in Models.swift
/// so it is visible to both the app and test targets.
struct AgentToastView: View {
    let toast: AgentToast
    var onDismiss: () -> Void

    @State private var dismissTask: Task<Void, Never>?

    private var tint: Color {
        switch toast.tone {
        case .success: AgentPalette.green
        case .error: AgentPalette.rose
        case .info: AgentPalette.cyan
        }
    }

    private var symbol: String {
        switch toast.tone {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)

            Text(toast.message)
                .font(.system(size: 13, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let retryAction = toast.retryAction {
                Button {
                    retryAction()
                    onDismiss()
                } label: {
                    Text("Retry")
                        .font(.system(size: 12, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(tint.opacity(0.14), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .minimumTapTarget()
                .accessibilityIdentifier("agentToastRetry")
                .minimumScaleFactor(0.8)
            } else {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .agentLiquidSurface(radius: 16, tint: tint, selected: true, level: .card, nativeGlass: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentToast")
        .onAppear { scheduleAutoDismiss() }
        .onDisappear { dismissTask?.cancel() }
    }

    private func scheduleAutoDismiss() {
        // Retry-able toasts stay until the user acts; everything else fades on its own.
        guard toast.retryAction == nil else { return }
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(toast.tone == .error ? 4.5 : 2.5))
            if !Task.isCancelled {
                await MainActor.run { onDismiss() }
            }
        }
    }
}

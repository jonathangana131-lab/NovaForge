//
//  ChatComposer.swift
//  NovaForge
//
//  Composer chrome: model picker, live run controls, glass surface, send button.
//

import AgentProviders
import SwiftData
import SwiftUI
import UIKit

struct ComposerModelPickerAnchor: View {
    @Bindable var settings: AgentSettings
    var localModels: LocalModelManager
    var compact = false
    var prepareToPresent: () -> Void = {}

    var body: some View {
        ComposerModelMenu(
            settings: settings,
            localModels: localModels,
            compact: compact,
            prepareToPresent: prepareToPresent
        )
            .frame(
                minWidth: compact ? 82 : 124,
                maxWidth: compact ? 98 : 168,
                minHeight: AgentDesign.minimumTouchTarget,
                alignment: .leading
            )
            .contentShape(Capsule(style: .continuous))
    }
}

struct ComposerReasoningControl: View {
    let provider: AIProvider
    let modelID: String

    @State private var preferences = AgentRunPreferenceStore.shared
    @State private var showingPicker = false
    @State private var presentationStartedAt: TimeInterval?

    private var tint: Color {
        switch preferences.orchestrationMode {
        case .standard: provider.tint
        case .ultra: AgentPalette.lilac
        case .ultraCode: AgentPalette.indigo
        }
    }

    private var label: String {
        return switch preferences.orchestrationMode {
        case .standard:
            switch preferences.reasoningEffort {
            case .none, .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            case .xhigh, .max: "Extra High"
            }
        case .ultra:
            "Extra High"
        case .ultraCode:
            "UltraCode"
        }
    }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Ultra was the oversized predecessor to the five-stop control.
            // Preserve the user's intent while moving that legacy state onto
            // the clear Extra High stop instead of exposing two "ultra" modes.
            if preferences.orchestrationMode == .ultra {
                preferences.reasoningEffort = .xhigh
                preferences.orchestrationMode = .standard
            }
            presentationStartedAt = ProcessInfo.processInfo.systemUptime
            showingPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: preferences.orchestrationMode.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .black))
                    .opacity(0.72)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(minWidth: 88, minHeight: AgentDesign.minimumTouchTarget)
            .agentGlass(
                radius: AgentDesign.minimumTouchTarget / 2,
                interactive: true,
                tint: tint.opacity(
                    preferences.orchestrationMode == .ultraCode ? 0.18 : 0.08
                )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        tint.opacity(
                            preferences.orchestrationMode == .ultraCode ? 0.42 : 0.16
                        ),
                        lineWidth: 0.65
                    )
            )
        }
        .buttonStyle(ComposerMenuButtonStyle())
        .popover(isPresented: $showingPicker, attachmentAnchor: .rect(.bounds)) {
            ComposerReasoningPicker(
                provider: provider,
                modelID: modelID,
                preferences: preferences,
                onPresented: recordPresentationLatency
            )
            .frame(idealWidth: 354, idealHeight: 176)
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("Reasoning and agent mode, \(label)")
        .accessibilityIdentifier("composerReasoningPickerButton")
    }

    private func recordPresentationLatency() {
        guard let presentationStartedAt else { return }
        AgentPerformance.value(
            "Reasoning Menu Open Duration ms",
            (ProcessInfo.processInfo.systemUptime - presentationStartedAt) * 1_000
        )
        self.presentationStartedAt = nil
    }
}

private struct ComposerReasoningPicker: View {
    let provider: AIProvider
    let modelID: String
    @Bindable var preferences: AgentRunPreferenceStore
    let onPresented: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Level: String, CaseIterable, Identifiable {
        case low
        case medium
        case high
        case extraHigh
        case ultraCode

        var id: String { rawValue }

        var title: String {
            switch self {
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            case .extraHigh: "Extra High"
            case .ultraCode: "UltraCode"
            }
        }

        var symbol: String? {
            self == .ultraCode ? "bolt.fill" : nil
        }

        var detail: String {
            switch self {
            case .low: "Quick answers with a small thinking budget"
            case .medium: "Balanced thinking for everyday agent work"
            case .high: "Deeper reasoning for difficult tasks"
            case .extraHigh: "Extended reasoning for complex plans and debugging"
            case .ultraCode: "Max reasoning + isolated workspace agents"
            }
        }
    }

    var body: some View {
        ZStack {
            NovaGlassSheetBackground(tint: activeTint, lightweight: true)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Reasoning")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AgentPalette.ink)
                    Spacer(minLength: 8)
                    Text(selection.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(activeTint)
                }

                reasoningSlider

                Text(selection == .ultraCode
                     ? "Max reasoning + isolated workspace agents"
                     : selection.detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .padding(14)
        }
        .onAppear(perform: onPresented)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composerReasoningPicker")
    }

    private var activeTint: Color {
        selection == .ultraCode ? AgentPalette.indigo : provider.tint
    }

    private var selection: Level {
        switch preferences.orchestrationMode {
        case .ultraCode:
            return .ultraCode
        case .ultra:
            return .extraHigh
        case .standard:
            switch preferences.reasoningEffort {
            case .none, .low: return .low
            case .medium: return .medium
            case .high: return .high
            case .xhigh, .max: return .extraHigh
            }
        }
    }

    private var reasoningSlider: some View {
        GeometryReader { geometry in
            let levels = Level.allCases
            let segmentWidth = geometry.size.width / CGFloat(levels.count)

            ZStack(alignment: .top) {
                Capsule(style: .continuous)
                    .fill(Color.clear)
                    .frame(height: 46)
                    .agentGlass(
                        radius: 23,
                        interactive: true,
                        tint: activeTint.opacity(selection == .ultraCode ? 0.18 : 0.08)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        AgentPalette.cyan.opacity(0.46),
                                        AgentPalette.lilac.opacity(0.56),
                                        AgentPalette.indigo.opacity(
                                            selection == .ultraCode ? 0.90 : 0.72
                                        ),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7)
                    )
                UltraCodePowerRipple(active: selection == .ultraCode)
                    .frame(height: 46)
                    .clipShape(Capsule(style: .continuous))

                HStack(spacing: 0) {
                    ForEach(levels) { _ in
                        Circle()
                            .fill(Color.white.opacity(0.48))
                            .frame(width: 6, height: 6)
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                }

                Circle()
                    .fill(Color.white.opacity(0.97))
                    .frame(width: 40, height: 40)
                    .overlay {
                        if let symbol = selection.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(AgentPalette.indigo)
                        } else {
                            Circle()
                                .fill(activeTint)
                                .frame(width: 7, height: 7)
                        }
                    }
                    .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 2)
                    .offset(
                        x: segmentWidth * (CGFloat(selectionIndex) + 0.5) - 20,
                        y: 3
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)

                HStack(spacing: 0) {
                    ForEach(levels) { level in
                        Text(level.title)
                            .font(.system(size: 8.5, weight: selection == level ? .black : .semibold))
                            .foregroundStyle(selection == level ? activeTint : AgentPalette.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .frame(maxWidth: .infinity)
                    }
                }
                .offset(y: 49)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        select(level(at: value.location.x, width: geometry.size.width))
                    }
            )
        }
        .frame(height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(selection.title)
        .accessibilityHint("Drag horizontally or swipe up and down to change effort")
        .accessibilityAdjustableAction { direction in
            adjustSelection(direction)
        }
        .accessibilityIdentifier("reasoningEffortSlider")
    }

    private var selectionIndex: Int {
        Level.allCases.firstIndex(of: selection) ?? 0
    }

    private func level(at xPosition: CGFloat, width: CGFloat) -> Level {
        let levels = Level.allCases
        guard width > 0 else { return selection }
        let fraction = min(max(xPosition / width, 0), 0.999_999)
        let index = min(Int(fraction * CGFloat(levels.count)), levels.count - 1)
        return levels[index]
    }

    private func adjustSelection(_ direction: AccessibilityAdjustmentDirection) {
        let levels = Level.allCases
        let nextIndex: Int
        switch direction {
        case .increment:
            nextIndex = min(selectionIndex + 1, levels.count - 1)
        case .decrement:
            nextIndex = max(selectionIndex - 1, 0)
        @unknown default:
            return
        }
        select(levels[nextIndex])
    }

    private func select(_ level: Level) {
        guard level != selection else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.34, extraBounce: 0.08)) {
            switch level {
            case .low:
                preferences.reasoningEffort = .low
                preferences.orchestrationMode = .standard
            case .medium:
                preferences.reasoningEffort = .medium
                preferences.orchestrationMode = .standard
            case .high:
                preferences.reasoningEffort = .high
                preferences.orchestrationMode = .standard
            case .extraHigh:
                preferences.reasoningEffort = .xhigh
                preferences.orchestrationMode = .standard
            case .ultraCode:
                preferences.reasoningEffort = .max
                preferences.orchestrationMode = .ultraCode
            }
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

private struct UltraCodePowerRipple: View {
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        if active {
            if reduceMotion || !AgentPerformance.allowsDecorativeMotion {
                rippleLayer(phase: 0.18)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.65) / 1.65
                    rippleLayer(phase: phase)
                }
            }
        }
    }

    private func rippleLayer(phase: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let shifted = (phase + Double(index) / 3)
                    .truncatingRemainder(dividingBy: 1)
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                AgentPalette.lilac.opacity(0.22),
                                AgentPalette.indigo.opacity(0.72),
                                AgentPalette.lilac.opacity(0.10),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1.4
                    )
                    .scaleEffect(
                        x: 1 + CGFloat(shifted) * 0.08,
                        y: 1 + CGFloat(shifted) * 0.32
                    )
                    .opacity((1 - shifted) * 0.60)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AgentOrchestrationStatusCard: View {
    let presentation: AgentOrchestrationPresentation

    private var tint: Color {
        presentation.mode == .ultraCode ? AgentPalette.indigo : AgentPalette.lilac
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: presentation.mode.symbol)
                    .font(.system(size: 18, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.mode.title)
                        .font(.headline.weight(.bold))
                    Text(presentation.headline)
                        .font(.caption)
                        .foregroundStyle(AgentPalette.secondaryText)
                }
                Spacer()
                Text("\(presentation.workers.filter(\.isComplete).count)/\(presentation.workers.count)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(tint)
            }

            VStack(spacing: 7) {
                ForEach(presentation.workers) { worker in
                    HStack(spacing: 10) {
                        Image(systemName: worker.symbol)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(worker.isComplete ? AgentPalette.green : tint)
                            .frame(width: 26, height: 26)
                            .background(
                                (worker.isComplete ? AgentPalette.green : tint)
                                    .opacity(0.10),
                                in: Circle()
                            )
                        Text(worker.title)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(worker.status)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AgentPalette.secondaryText)
                        Image(systemName: worker.isComplete
                            ? "checkmark.circle.fill" : "waveform.path")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(worker.isComplete ? AgentPalette.green : tint)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 42)
                    .agentSurface(radius: 15, tint: tint.opacity(0.055))
                }
            }
        }
        .padding(15)
        .agentSurface(radius: 22, tint: tint.opacity(0.09), nativeGlass: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentOrchestrationStatusCard")
    }
}

/// Live execution belongs to the composer while a chat-owned response is
/// growing. The disclosure and Stop action share this row so streaming never
/// creates a second floating glass slab above the input.
struct ComposerLiveRunRail: View {
    let title: String
    let expanded: Bool
    let tint: Color
    let showDetails: () -> Void
    let stop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            Button(action: showDetails) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .bold))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(tint.opacity(0.13)))

                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                .contentShape(Capsule(style: .continuous))
                .agentControlSurface(
                    radius: AgentDesign.minimumTouchTarget / 2,
                    tint: tint.opacity(0.10),
                    selected: true
                )
            }
            .buttonStyle(ComposerMenuButtonStyle())
            .accessibilityLabel(expanded ? "Hide run progress, \(title)" : "Show run progress, \(title)")
            .accessibilityIdentifier("runProgressToggle")

            Button(action: stop) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .black))
                    Text("Stop")
                        .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                }
                .foregroundStyle(AgentPalette.rose)
                .padding(.horizontal, 11)
                .frame(minHeight: AgentDesign.minimumTouchTarget)
                .contentShape(Capsule(style: .continuous))
                .agentControlSurface(
                    radius: AgentDesign.minimumTouchTarget / 2,
                    tint: AgentPalette.rose.opacity(0.10),
                    selected: true
                )
            }
            .buttonStyle(ComposerMenuButtonStyle())
            .accessibilityLabel("Stop generating")
            .accessibilityIdentifier("composerStopButton")
        }
        .frame(minHeight: AgentDesign.minimumTouchTarget)
        .animation(
            NovaMotion.enabled(reduceMotion: reduceMotion) ? .snappy(duration: 0.22) : nil,
            value: expanded
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composerLiveRunRail")
    }
}

struct ComposerChromeStyle: Equatable {
    let cornerRadius: CGFloat
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat
    let verticalPadding: CGFloat
    let minHeight: CGFloat
    let collapsedMaxHeight: CGFloat
    let expandedMaxHeight: CGFloat
    let surfaceOpacity: Double
    let focusedSurfaceOpacity: Double
    let tintOpacity: Double
    let focusedTintOpacity: Double
    let borderOpacity: Double
    let focusedBorderOpacity: Double
    let borderWidth: CGFloat
    let focusedBorderWidth: CGFloat
    let shadowOpacity: Double
    let focusedShadowOpacity: Double
    let shadowRadius: CGFloat
    let focusedShadowRadius: CGFloat
    let shadowY: CGFloat

    static let `default` = ComposerChromeStyle(
        cornerRadius: 27,
        leadingPadding: 9,
        trailingPadding: 9,
        verticalPadding: 4,
        minHeight: 60,
        collapsedMaxHeight: 72,
        expandedMaxHeight: 164,
        surfaceOpacity: 0.76,
        focusedSurfaceOpacity: 0.82,
        tintOpacity: 0.020,
        focusedTintOpacity: 0.052,
        borderOpacity: 0.16,
        focusedBorderOpacity: 0.30,
        borderWidth: 0.55,
        focusedBorderWidth: 0.85,
        shadowOpacity: 0.020,
        focusedShadowOpacity: 0.055,
        shadowRadius: 7,
        focusedShadowRadius: 12,
        shadowY: 4
    )

}

struct ComposerGlassSurfaceModifier: ViewModifier {
    let focused: Bool
    let tint: Color
    let style: ComposerChromeStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency ||
            AgentPlatformCompatibility.usesConservativeRendering ||
            AgentPerformance.prefersReducedVisualEffects {
            fallback(content: content)
        } else if #available(iOS 26.0, *) {
            glass(content: content)
        } else {
            fallback(content: content)
        }
    }

    private func decoratedContent(_ content: Content, includeSurfaceFill: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        let isMatrix = AgentTheme.current == .matrixRain
        let highlight = AgentPalette.glassStroke
        let surfaceOpacity = isMatrix ? (focused ? 0.98 : 0.94) : (focused ? style.focusedSurfaceOpacity : style.surfaceOpacity)
        return content
            .background {
                ZStack {
                    if includeSurfaceFill {
                        shape.fill(AgentPalette.surface.opacity(surfaceOpacity))
                    }
                    shape.fill(tint.opacity(focused ? style.focusedTintOpacity : style.tintOpacity))
                    shape.fill(
                        LinearGradient(
                            colors: [
                                highlight.opacity(isMatrix ? (focused ? 0.10 : 0.06) : (focused ? 0.24 : 0.16)),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                    )
                }
                .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            highlight.opacity(isMatrix ? (focused ? 0.20 : 0.12) : (focused ? style.focusedBorderOpacity : style.borderOpacity)),
                            tint.opacity(focused ? style.focusedBorderOpacity * 0.68 : style.borderOpacity * 0.56),
                            AgentPalette.border.opacity(style.borderOpacity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: focused ? style.focusedBorderWidth : style.borderWidth
                )
                .allowsHitTesting(false)
            }
            .shadow(
                color: tint.opacity(focused ? style.focusedShadowOpacity : style.shadowOpacity),
                radius: focused ? style.focusedShadowRadius : style.shadowRadius,
                x: 0,
                y: focused ? style.shadowY + 1.5 : style.shadowY
            )
    }

    private func fallback(content: Content) -> some View {
        decoratedContent(content, includeSurfaceFill: true)
    }

    @ViewBuilder
    @available(iOS 26.0, *)
    private func glass(content: Content) -> some View {
        if AgentTheme.current == .matrixRain {
            fallback(content: content)
        } else {
            let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            decoratedContent(content, includeSurfaceFill: false)
                .glassEffect(
                    Glass.regular
                        .tint(tint.opacity(focused ? 0.13 : 0.07))
                        .interactive(),
                    in: shape
                )
        }
    }
}

extension View {
    func composerGlassSurface(focused: Bool, tint: Color, style: ComposerChromeStyle) -> some View {
        modifier(ComposerGlassSurfaceModifier(focused: focused, tint: tint, style: style))
    }

    @ViewBuilder
    func runContextSurface(usesPolishedSurface: Bool, tint: Color) -> some View {
        if usesPolishedSurface || AgentPerformance.prefersReducedVisualEffects {
            agentSurface(radius: 18, tint: tint.opacity(0.07))
        } else {
            agentGlass(radius: 18, tint: tint.opacity(0.09))
        }
    }
}

struct ComposerMenuButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || AgentPerformance.prefersReducedVisualEffects ? 1 : (configuration.isPressed ? 0.95 : 1.0))
            .animation(reduceMotion || AgentPerformance.prefersReducedVisualEffects ? nil : .spring(response: 0.2, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

struct ComposerModelMenu: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var settings: AgentSettings
    var localModels: LocalModelManager
    var compact = false
    var prepareToPresent: () -> Void = {}

    @State private var showingChooser = false
    @State private var selectionError: String?
    @State private var providerCatalog = ProviderModelCatalogStore.shared
    @State private var presentationStartedAt: TimeInterval?

    var body: some View {
        Button {
            prepareToPresent()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            presentationStartedAt = ProcessInfo.processInfo.systemUptime
            showingChooser = true
        } label: {
            menuLabel
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Choose model, \(settings.provider.displayName), \(selectedModelDisplayName)")
                .accessibilityIdentifier("composerModelNativeMenu")
        }
        .buttonStyle(ComposerMenuButtonStyle())
        .accessibilityLabel("Choose model, \(settings.provider.displayName), \(selectedModelDisplayName)")
        .accessibilityIdentifier("composerModelNativeMenu")
        .sheet(isPresented: $showingChooser) {
            ComposerModelChooserSheet(
                settings: settings,
                localModels: localModels,
                selectionError: selectionError,
                selectProvider: selectProvider,
                selectModel: selectModel,
                onPresented: recordPresentationLatency
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(30)
            .presentationBackground(.clear)
        }
    }

    private func recordPresentationLatency() {
        guard let presentationStartedAt else { return }
        AgentPerformance.value(
            "Model Menu Open Duration ms",
            (ProcessInfo.processInfo.systemUptime - presentationStartedAt) * 1_000
        )
        self.presentationStartedAt = nil
    }

    private var menuLabel: some View {
        HStack(spacing: compact ? 5 : 6) {
            providerGlyph

            Text(compact ? compactProviderLabel : labelText)
                .font(.system(size: compact ? 11 : 12, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.76)
                .layoutPriority(1)

            Image(systemName: "chevron.down")
                .font(.system(size: compact ? 7 : 8, weight: .bold))
                .foregroundStyle(settings.provider.tint.opacity(0.70))
        }
        .padding(.horizontal, compact ? 8 : 9)
        .frame(height: AgentDesign.minimumTouchTarget)
        .frame(
            minWidth: compact ? 82 : 124,
            maxWidth: compact ? 98 : 168,
            alignment: .leading
        )
        .background {
            ZStack {
                Capsule(style: .continuous)
                    .fill(settings.provider.tint.opacity(0.055))

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AgentPalette.glassStroke.opacity(0.50), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .opacity(0.24)
            }
        }
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(AgentPalette.glassStroke.opacity(0.54), lineWidth: 0.55)
        )
        .shadow(color: settings.provider.tint.opacity(0.025), radius: 2, x: 0, y: 1)
    }

    private var providerGlyph: some View {
        Image(systemName: settings.provider.symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(
                LinearGradient(
                    colors: [settings.provider.tint, settings.provider.tint.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 20, height: 20)
            .background {
                Circle()
                    .fill(settings.provider.tint.opacity(0.09))
            }
    }

    private var labelText: String {
        compactComposerModelLabel
    }

    private var compactProviderLabel: String {
        switch settings.provider {
        case .openCodeZen:
            settings.modelID.localizedCaseInsensitiveContains("free") ? "Zen Free" : "Zen"
        case .openAICodex:
            "ChatGPT"
        case .openAI:
            "OpenAI"
        case .local:
            "Local"
        case .openRouter:
            "Router"
        case .custom:
            "Custom"
        }
    }

    private var compactComposerModelLabel: String {
        let modelName = compactComposerModelName
        let providerName = settings.provider.shortName
        if modelName.range(of: providerName, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return modelName
        }
        return truncatedComposerModelName("\(providerName) \(modelName)")
    }

    private var compactComposerModelName: String {
        let refinedName = refinedModelTitle(settings.modelID)
        let displayName = refinedName.split(separator: "/", maxSplits: 1).last.map(String.init) ?? refinedName
        let name = displayName
            .replacingOccurrences(of: "Qwen2.5", with: "Qwen")
            .replacingOccurrences(of: "Instruct", with: "")
            .replacingOccurrences(of: "Model", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map(compactModelToken)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return settings.provider.shortName }
        return truncatedComposerModelName(name)
    }

    private func truncatedComposerModelName(_ name: String) -> String {
        guard name.count > 18 else { return name }
        var fitted = ""
        for token in name.split(separator: " ") {
            let candidate = fitted.isEmpty ? String(token) : "\(fitted) \(token)"
            guard candidate.count + 3 <= 18 else { break }
            fitted = candidate
        }
        if !fitted.isEmpty { return "\(fitted)..." }
        return String(name.prefix(15)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func compactModelToken(_ token: Substring) -> String {
        let raw = String(token)
        let lower = raw.lowercased()
        switch lower {
        case "gpt", "glm", "ai", "api":
            return lower.uppercased()
        case "deepseek":
            return "DeepSeek"
        case "gemini":
            return "Gemini"
        case "grok":
            return "Grok"
        case "kimi":
            return "Kimi"
        case "minimax":
            return "MiniMax"
        case "qwen3":
            return "Qwen3"
        case "ios":
            return "iOS"
        default:
            return raw.prefix(1).uppercased() + String(raw.dropFirst())
        }
    }

    fileprivate func refinedModelTitle(_ model: String) -> String {
        LocalModelCatalog.variant(for: model)?.shortName
            ?? providerCatalog.displayName(
                for: settings.provider,
                modelID: model
            )
    }

    private var selectedModelDisplayName: String {
        refinedModelTitle(settings.modelID)
    }

    private func selectProvider(_ provider: AIProvider) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard settings.provider != provider else { return }
        guard persistSettingsChange(failureTitle: "Provider Not Saved", mutate: { settings in
            settings.switchProvider(to: provider)
        }) else { return }
        if provider == .local,
           let variant = LocalModelCatalog.variant(for: settings.modelID)
        {
            _ = localModels.select(variant)
        }
        selectionError = nil
    }

    private func selectModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if persistSettingsChange(failureTitle: "Model Not Saved", mutate: { settings in
            settings.modelID = trimmed
        }) {
            if let variant = LocalModelCatalog.variant(for: trimmed) {
                _ = localModels.select(variant)
            }
            selectionError = nil
        }
    }

    @discardableResult
    private func persistSettingsChange(failureTitle: String, mutate: (AgentSettings) -> Void) -> Bool {
        do {
            try AgentSettingsPersistence.persist(
                settings: settings,
                mutate: mutate,
                save: { try modelContext.save() }
            )
            return true
        } catch {
            selectionError = "\(failureTitle): \(error.localizedDescription). Your previous provider and model are still active."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }

}

private struct ComposerModelChooserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: AgentSettings
    var localModels: LocalModelManager
    let selectionError: String?
    let selectProvider: (AIProvider) -> Void
    let selectModel: (String) -> Void
    let onPresented: () -> Void

    @State private var selectedProvider: AIProvider
    @State private var readyCredentials: Set<AIProvider> = []
    @State private var providerCatalog = ProviderModelCatalogStore.shared

    init(
        settings: AgentSettings,
        localModels: LocalModelManager,
        selectionError: String?,
        selectProvider: @escaping (AIProvider) -> Void,
        selectModel: @escaping (String) -> Void,
        onPresented: @escaping () -> Void
    ) {
        self.settings = settings
        self.localModels = localModels
        self.selectionError = selectionError
        self.selectProvider = selectProvider
        self.selectModel = selectModel
        self.onPresented = onPresented
        _selectedProvider = State(initialValue: settings.provider)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NovaGlassSheetBackground(tint: selectedProvider.tint, lightweight: true)

                ScrollView {
                    // This chooser is intentionally small. Materializing the
                    // whole stack keeps VoiceOver/XCUI discovery stable and
                    // makes Local download readiness available immediately
                    // after the provider changes instead of waiting for a
                    // virtualized row to scroll on screen.
                    VStack(alignment: .leading, spacing: 18) {
                        chooserIntro
                        providerSection
                        if selectedProvider == .local {
                            localDownloadSection
                        }
                        modelSection
                        if let selectionError {
                            Label(selectionError, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AgentPalette.rose)
                                .padding(14)
                                .agentSurface(radius: 18, tint: AgentPalette.rose.opacity(0.10))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Model & provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear(perform: onPresented)
        .task(id: selectedProvider) {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            refreshCredentialReadiness()
            await providerCatalog.refresh(provider: selectedProvider)
            repairSelectionFromLiveCatalogIfNeeded()
        }
        .accessibilityIdentifier("composerModelChooserSheet")
    }

    private var chooserIntro: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Choose where NovaForge thinks")
                .font(.title3.weight(.bold))
                .foregroundStyle(AgentPalette.ink)
            Text("Provider first, then its model. Readiness stays visible before you switch.")
                .font(.subheadline)
                .foregroundStyle(AgentPalette.secondaryText)
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            chooserHeader("Provider", detail: providerSectionDetail)
            ForEach(supportedProviders) { provider in
                Button {
                    selectedProvider = provider
                    selectProvider(provider)
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: provider.symbol)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(provider.tint)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(provider.tint.opacity(0.12)))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AgentPalette.ink)
                            Text(providerStatus(provider))
                                .font(.caption)
                                .foregroundStyle(AgentPalette.secondaryText)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        if selectedProvider == provider {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(provider.tint)
                        }
                    }
                    .padding(12)
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .agentControlSurface(
                        radius: 20,
                        tint: provider.tint.opacity(0.10),
                        selected: selectedProvider == provider
                    )
                }
                .buttonStyle(ComposerMenuButtonStyle())
                .accessibilityIdentifier("composerProvider-\(provider.rawValue)")
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            chooserHeader("Model", detail: selectedProvider.displayName)
            ForEach(modelChoices, id: \.self) { model in
                Button {
                    if selectedProvider != settings.provider {
                        selectProvider(selectedProvider)
                    }
                    selectModel(model)
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: modelSymbol(model))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(selectedProvider.tint)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(selectedProvider.tint.opacity(0.10)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(modelTitle(model))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AgentPalette.ink)
                                .lineLimit(1)
                            if let detail = modelDetail(model) {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(AgentPalette.secondaryText)
                            }
                        }
                        Spacer()
                        if settings.provider == selectedProvider,
                           selectedProvider.visibleModelIdentity(settings.modelID)
                            == selectedProvider.visibleModelIdentity(model)
                        {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(selectedProvider.tint)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 50)
                    .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .agentSurface(radius: 17, tint: selectedProvider.tint.opacity(0.055))
                }
                .buttonStyle(ComposerMenuButtonStyle())
                .accessibilityIdentifier("composerModel-\(model)")
            }
        }
    }

    @ViewBuilder
    private var localDownloadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            chooserHeader("On-device model", detail: localModels.status.title)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localModels.selectedVariant.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(localModels.selectedVariant.expectedSizeLabel + " · verified after download")
                        .font(.caption)
                        .foregroundStyle(AgentPalette.secondaryText)
                    if localModels.isDownloading || localModels.isPartial {
                        ProgressView(value: localModels.progress.fraction)
                            .tint(AIProvider.local.tint)
                    }
                }
                Spacer()
                localDownloadButton
            }
            .padding(14)
            .agentSurface(radius: 20, tint: AIProvider.local.tint.opacity(0.08))
        }
    }

    @ViewBuilder
    private var localDownloadButton: some View {
        if localModels.isDownloaded {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(AIProvider.local.tint)
        } else if localModels.isDownloading {
            Button("Pause") { localModels.cancelDownload() }
                .buttonStyle(.bordered)
        } else {
            Button(localModels.isPartial ? "Resume" : "Download") {
                localModels.downloadSelected()
            }
            .buttonStyle(.borderedProminent)
            .tint(AIProvider.local.tint)
        }
    }

    private var supportedProviders: [AIProvider] {
        AIProvider.agentRuntimeProviders
    }

    private var providerSectionDetail: String {
        "Hosted, subscription, or on-device"
    }

    private var modelChoices: [String] {
        var seen = Set<String>()
        return providerCatalog.models(for: selectedProvider).compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && seen.insert(trimmed).inserted ? trimmed : nil
        }
    }

    private func providerStatus(_ provider: AIProvider) -> String {
        switch provider {
        case .local:
            return "iPhone 12 safe · \(localModels.status.title)"
        case .openCodeZen:
            return "Free models work without a key · paid models use Zen key"
        case .openAICodex:
            return readyCredentials.contains(provider)
                ? "ChatGPT connected · live models"
                : "Sign in with ChatGPT in Control"
        case .openAI:
            return readyCredentials.contains(provider)
                ? "Connected with API key"
                : "Add an API key in Control"
        case .openRouter, .custom:
            return "Configure in Control"
        }
    }

    private func modelTitle(_ model: String) -> String {
        LocalModelCatalog.variant(for: model)?.shortName
            ?? providerCatalog.displayName(
                for: selectedProvider,
                modelID: model
            )
    }

    private func modelDetail(_ model: String) -> String? {
        if let variant = LocalModelCatalog.variant(for: model) {
            return variant.isIPhone12SafeDefault
                ? "Recommended for iPhone 12"
                : variant.quantization + " · low-memory fallback"
        }
        if let detail = selectedProvider.modelDetail(model) { return detail }
        if model.localizedCaseInsensitiveContains("free") { return "Free hosted model" }
        if model == "big-pickle" { return "Limited-time hosted model" }
        return nil
    }

    private func modelSymbol(_ model: String) -> String {
        if LocalModelCatalog.variant(for: model) != nil { return "iphone.gen3" }
        if model.localizedCaseInsensitiveContains("gpt") { return "sparkles" }
        return "cube.transparent"
    }

    private func chooserHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption2.weight(.black))
                .tracking(0.8)
                .foregroundStyle(AgentPalette.secondaryText)
                .accessibilityLabel(title)
            Spacer()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(AgentPalette.tertiaryText)
                .lineLimit(1)
        }
    }

    private func refreshCredentialReadiness() {
        let keychain = KeychainStore()
        readyCredentials = Set([AIProvider.openCodeZen, .openAI, .openAICodex].filter { provider in
            guard let value = try? keychain.read(provider.apiKeyAccount) else {
                return false
            }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    private func repairSelectionFromLiveCatalogIfNeeded() {
        guard selectedProvider == settings.provider,
              providerCatalog.hasLiveCatalog(for: selectedProvider)
        else { return }
        let liveModels = providerCatalog.models(for: selectedProvider)
        let selectedIdentity = selectedProvider.visibleModelIdentity(settings.modelID)
        guard !liveModels.contains(where: {
                  selectedProvider.visibleModelIdentity($0) == selectedIdentity
              }),
              let first = liveModels.first
        else { return }
        selectModel(first)
    }
}

struct ComposerSendButton: View {
    let title: String?
    let isQueueing: Bool
    let isEnabled: Bool
    let tint: Color
    let accessibilityLabel: String
    let accessibilityValue: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                sendCapsule
                    .frame(width: title == nil ? 34 : nil, height: title == nil ? 34 : nil)

                ViewThatFits(in: .horizontal) {
                    sendLabel(showTitle: title != nil)
                    sendLabel(showTitle: false)
                }
                .foregroundStyle(isEnabled ? enabledForeground : AgentPalette.secondaryText.opacity(0.72))
                .padding(.horizontal, title == nil ? 0 : 10)
            }
            .frame(minWidth: title == nil ? 46 : 82, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("sendMessageButton")
        .accessibilityAction {
            guard isEnabled else { return }
            action()
        }
    }

    private func sendLabel(showTitle: Bool) -> some View {
        HStack(spacing: showTitle ? 6 : 0) {
            Image(systemName: isQueueing ? "plus.message.fill" : "arrow.up")
                .font(.system(size: 14, weight: .black))

            if showTitle, let title {
                Text(title)
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
    }

    private var enabledForeground: Color {
        AgentPalette.isLight ? AgentPalette.pearl : AgentPalette.ink
    }

    private var sendCapsule: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: isEnabled ? [tint.opacity(0.98), AgentPalette.lilac.opacity(0.90)] : [
                        AgentPalette.secondaryText.opacity(0.12),
                        AgentPalette.tertiaryText.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

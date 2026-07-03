//
//  ChatComposer.swift
//  NovaForge
//
//  Composer chrome: model picker, status pill, glass surface, send button.
//

import SwiftData
import SwiftUI
import UIKit

struct ComposerModelPickerAnchor: View {
    @Bindable var settings: AgentSettings

    var body: some View {
        ComposerModelMenu(settings: settings)
            .frame(minWidth: 124, maxWidth: 168, minHeight: 44, alignment: .leading)
            .contentShape(Capsule(style: .continuous))
    }
}

struct ComposerStatus {
    let title: String
    let symbol: String
    let tint: Color
}

struct ComposerStatusPill: View {
    let status: ComposerStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol)
                .font(.system(size: 10, weight: .black))
                .symbolRenderingMode(.hierarchical)
            Text(status.title)
                .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .agentControlSurface(radius: 8, tint: status.tint.opacity(0.10), selected: true)
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
        minHeight: 96,
        collapsedMaxHeight: 108,
        expandedMaxHeight: 220,
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

    static let streamingCompact = ComposerChromeStyle(
        cornerRadius: 24,
        leadingPadding: 8,
        trailingPadding: 8,
        verticalPadding: 4,
        minHeight: 62,
        collapsedMaxHeight: 72,
        expandedMaxHeight: 172,
        surfaceOpacity: 0.70,
        focusedSurfaceOpacity: 0.82,
        tintOpacity: 0.018,
        focusedTintOpacity: 0.052,
        borderOpacity: 0.14,
        focusedBorderOpacity: 0.30,
        borderWidth: 0.55,
        focusedBorderWidth: 0.85,
        shadowOpacity: 0.0,
        focusedShadowOpacity: 0.052,
        shadowRadius: 0,
        focusedShadowRadius: 11,
        shadowY: 3
    )
}

struct ComposerGlassSurfaceModifier: ViewModifier {
    let focused: Bool
    let tint: Color
    let style: ComposerChromeStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || AgentPlatformCompatibility.usesConservativeRendering {
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

    @available(iOS 26.0, *)
    private func glass(content: Content) -> some View {
        if AgentTheme.current == .matrixRain {
            return AnyView(fallback(content: content))
        }
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        return AnyView(decoratedContent(content, includeSurfaceFill: false)
            .glassEffect(
                Glass.regular
                    .tint(tint.opacity(focused ? 0.13 : 0.07))
                    .interactive(),
                in: shape
            ))
    }
}

extension View {
    func composerGlassSurface(focused: Bool, tint: Color, style: ComposerChromeStyle) -> some View {
        modifier(ComposerGlassSurfaceModifier(focused: focused, tint: tint, style: style))
    }

    @ViewBuilder
    func runContextSurface(usesPolishedSurface: Bool, tint: Color) -> some View {
        if usesPolishedSurface {
            agentSurface(radius: 18, tint: tint.opacity(0.07))
        } else {
            agentGlass(radius: 18, tint: tint.opacity(0.09))
        }
    }
}

struct ComposerMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

struct ComposerModelMenu: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var settings: AgentSettings

    @State private var selectionError: String?

    var body: some View {
        Menu {
            Section("Provider") {
                ForEach(AIProvider.allCases) { provider in
                    Button {
                        selectProvider(provider)
                    } label: {
                        Label(
                            provider.displayName,
                            systemImage: settings.provider == provider ? "checkmark.circle.fill" : provider.symbol
                        )
                    }
                }
            }

            Section("\(settings.provider.displayName) Models") {
                ForEach(modelChoices, id: \.self) { model in
                    Button {
                        selectModel(model)
                    } label: {
                        Label(
                            refinedModelTitle(model),
                            systemImage: settings.modelID == model ? "checkmark.circle.fill" : modelMenuSymbol(for: model)
                        )
                    }
                }
            }

            if let selectionError {
                Section {
                    Text(selectionError)
                }
            }
        } label: {
            menuLabel
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Choose model, \(settings.provider.displayName), \(settings.modelID)")
                .accessibilityIdentifier("composerModelNativeMenu")
        }
        .menuStyle(.button)
        .buttonStyle(ComposerMenuButtonStyle())
        .accessibilityLabel("Choose model, \(settings.provider.displayName), \(settings.modelID)")
        .accessibilityIdentifier("composerModelNativeMenu")
    }

    private var menuLabel: some View {
        HStack(spacing: 5) {
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

            Text(labelText)
                .font(.system(size: 12, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.76)
                .layoutPriority(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(settings.provider.tint.opacity(0.70))
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 34)
        .frame(minWidth: 124, maxWidth: 168, alignment: .leading)
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

    private var labelText: String {
        compactComposerModelLabel
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
            .replacingOccurrences(of: "VibeThinker", with: "")
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
        case "codex":
            return "Codex"
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

    private var modelChoices: [String] {
        uniqueModels(settings.provider.modelOptions + [settings.modelID])
    }

    private func refinedModelTitle(_ model: String) -> String {
        LocalModelCatalog.variant(for: model)?.shortName ?? model
    }

    private func modelMenuSymbol(for model: String) -> String {
        if LocalModelCatalog.variant(for: model) != nil { return "iphone.gen3" }
        if model.localizedCaseInsensitiveContains("codex") { return "terminal.fill" }
        if model.localizedCaseInsensitiveContains("gpt") { return "sparkles" }
        return "cube.transparent"
    }

    private func selectProvider(_ provider: AIProvider) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard settings.provider != provider else { return }
        guard persistSettingsChange(failureTitle: "Provider Not Saved", mutate: { settings in
            settings.switchProvider(to: provider)
        }) else { return }
        selectionError = nil
    }

    private func selectModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if persistSettingsChange(failureTitle: "Model Not Saved", mutate: { settings in
            settings.modelID = trimmed
        }) {
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

    private func uniqueModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models.compactMap { model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}

struct ComposerSendButton: View {
    let title: String?
    let isQueueing: Bool
    let isEnabled: Bool
    let tint: Color
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

//
//  ChatSupportViews.swift
//  NovaForge
//
//  Chat supporting surfaces: empty state, elsewhere cards, live island,
//  keyboard state, jump-to-latest, quick delegate rail, banners, status dot.
//

import SwiftData
import SwiftUI
import UIKit

struct CleanChatEmptyState: View {
    struct Readiness {
        let title: String
        let detail: String
        let symbol: String
        let tint: Color
        let actionTitle: String?
        let badgeTitle: String
    }

    fileprivate struct Starter: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        let prompt: String
        let tint: Color
    }

    var readiness = Readiness(
        title: "Ready for a real mission",
        detail: "Tell NovaForge what to build, fix, or inspect. It will plan, use safe tools, and bring proof back here.",
        symbol: "checkmark.seal.fill",
        tint: AgentPalette.green,
        actionTitle: nil,
        badgeTitle: "READY"
    )
    var openSettings: () -> Void = {}
    var apply: (String) -> Void = { _ in }

    private static let starters: [Starter] = [
        Starter(
            id: "prototype",
            symbol: "hammer.fill",
            title: "Build a prototype",
            detail: "Create one working artifact and show how to open it.",
            prompt: "Build a small polished prototype in this workspace. Create the working file, validate it, and tell me exactly how to open the result.",
            tint: AgentPalette.blue
        ),
        Starter(
            id: "audit",
            symbol: "doc.text.magnifyingglass",
            title: "Audit the workspace",
            detail: "Find the important files, risks, and next moves first.",
            prompt: "Audit this workspace like a senior developer. Show the important files, risks, and best next actions before changing anything risky.",
            tint: AgentPalette.cyan
        ),
        Starter(
            id: "ship",
            symbol: "checklist.checked",
            title: "Prepare to ship",
            detail: "Pick a focused polish pass, verify it, and report proof.",
            prompt: "Do a focused ship-readiness pass: choose the highest-impact safe improvement, verify it, and give me the final proof plus any remaining risks.",
            tint: AgentPalette.green
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                NovaReticleGlyph(symbol: "sparkles", tint: AgentPalette.primaryAccent, size: 48, isActive: true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("FIRST MISSION")
                        .novaLabel(AgentPalette.tertiaryText)
                    Text("Start with one clear task")
                        .font(NovaType.display)
                        .foregroundStyle(AgentPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Pick a starter or write your own. NovaForge will plan, ask before risky writes, work in the workspace, and return proof.")
                        .font(NovaType.body)
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            firstMissionReadinessCard

            VStack(spacing: 7) {
                ForEach(Self.starters, id: \.title) { starter in
                    FirstMissionStarterButton(starter: starter) {
                        apply(starter.prompt)
                    }
                }
            }
        }
        .padding(16)
        .agentSurface(radius: 24, tint: AgentPalette.primaryAccent.opacity(0.04))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("First mission ready. \(readiness.title). \(readiness.detail)")
        .accessibilityIdentifier("cleanChatEmptyState")
    }

    private var firstMissionReadinessCard: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: readiness.symbol)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(readiness.tint)
                .frame(width: 30, height: 30)
                .agentControlSurface(radius: 11, tint: readiness.tint.opacity(0.10), selected: false)

            VStack(alignment: .leading, spacing: 3) {
                Text(readiness.title)
                    .font(NovaType.headline)
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
                Text(readiness.detail)
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.84)
            }

            Spacer(minLength: 0)

            if let actionTitle = readiness.actionTitle {
                Button {
                    NovaHaptics.tick()
                    openSettings()
                } label: {
                    Text(actionTitle)
                        .font(NovaType.label)
                        .lineLimit(1)
                        .foregroundStyle(readiness.tint)
                        .frame(minWidth: 62, minHeight: AgentDesign.minimumTouchTarget)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background(Capsule(style: .continuous).fill(readiness.tint.opacity(0.11)))
                .overlay(Capsule(style: .continuous).strokeBorder(readiness.tint.opacity(0.28), lineWidth: 0.8))
                .accessibilityIdentifier("firstMissionReadinessAction")
            } else {
                Text(readiness.badgeTitle)
                    .font(NovaType.label)
                    .foregroundStyle(readiness.tint)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .agentControlSurface(radius: 10, tint: readiness.tint.opacity(0.10), selected: true)
            }
        }
        .padding(10)
        .agentRowSurface(radius: 16, tint: readiness.tint.opacity(0.07), selected: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstMissionReadiness")
    }
}

private struct FirstMissionStarterButton: View {
    let starter: CleanChatEmptyState.Starter
    let apply: () -> Void

    var body: some View {
        Button {
            NovaHaptics.tick()
            apply()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: starter.symbol)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(starter.tint)
                    .frame(width: 30, height: 30)
                    .agentControlSurface(radius: 11, tint: starter.tint.opacity(0.10), selected: false)

                VStack(alignment: .leading, spacing: 2) {
                    Text(starter.title)
                        .font(NovaType.headline)
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(starter.detail)
                        .font(NovaType.caption)
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.84)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(starter.tint)
                    .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .agentRowSurface(radius: 15, tint: starter.tint.opacity(0.08), selected: false)
        .accessibilityLabel(starter.title)
        .accessibilityIdentifier("firstMissionStarter-\(starter.id)")
    }
}

struct ActiveResponseElsewhereCard: View {
    let title: String
    let open: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProgressStatusIcon(tint: AgentPalette.cyan)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Active response")
                    .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Text("Running in \(title)")
                    .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button(action: open) {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(AgentPalette.cyan)
                    .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open running chat")
        }
        .padding(12)
        .agentSurface(radius: 18, tint: AgentPalette.cyan.opacity(0.05))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activeResponseElsewhereCard")
    }
}

struct ActiveResponseElsewhereDock: View {
    let title: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(AgentPalette.cyan)
                Text("Running in \(title)")
                    .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(AgentPalette.cyan)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: AgentDesign.minimumTouchTarget)
            .frame(maxWidth: .infinity)
            // Plain buttons otherwise preserve the transparent Spacer as a
            // visual frame but not a reliable hit target. Make the whole dock
            // respond, including its center and trailing breathing room.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .agentControlSurface(radius: 13, tint: AgentPalette.cyan.opacity(0.10), selected: true)
        .accessibilityLabel("Active response is running in \(title). Open running chat.")
        .accessibilityIdentifier("activeResponseElsewhereDock")
    }
}

struct ChatLiveResponseIsland: View {
    @ObservedObject var stream: LiveStreamBuffer
    let isWorking: Bool
    let isVisibleForFrameProfiling: Bool

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Live Response Island Body")
        ZStack(alignment: .topLeading) {
            LiveResponseView(
                isWorking: isWorking,
                isHandoffActive: !isWorking && !stream.isEmpty,
                stream: stream
            )

            if AgentPerformance.shouldProfileFrameRate {
                ChatStreamingFrameRateProbe(
                    stream: stream,
                    isWorking: isWorking || stream.isHandoffActive,
                    isVisibleForFrameProfiling: isVisibleForFrameProfiling
                )
            }
        }
    }
}

struct ChatStreamingFrameRateProbe: View {
    @ObservedObject var stream: LiveStreamBuffer
    let isWorking: Bool
    let isVisibleForFrameProfiling: Bool
    @State private var didArmProbe = false

    var body: some View {
        PerformanceFrameProbe(
            surface: .chatStreaming,
            isActive: isVisibleForFrameProfiling && didArmProbe && (isWorking || !stream.isEmpty)
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: stream.responseID) {
            didArmProbe = false
            guard AgentPerformance.shouldProfileFrameRate else { return }
            // Avoid sampling launch/first-token layout spikes; the product
            // path still renders immediately, while the gate measures sustained
            // streaming smoothness after the response stage has settled and the
            // first bottom-pin corrections have completed.
            try? await Task.sleep(for: .milliseconds(1_800))
            guard !Task.isCancelled else { return }
            didArmProbe = true
        }
    }
}

@MainActor
final class ChatKeyboardState: ObservableObject {
    @Published private(set) var snapshot = ChatKeyboardSnapshot.hidden

    var isVisible: Bool {
        snapshot.isVisible
    }

    func reset() {
        guard snapshot != .hidden else { return }
        snapshot = .hidden
    }

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleKeyboardFrameChange(_ notification: Notification) {
        let nextFrame = Self.keyboardFrame(from: notification)
        let nextHeight = Self.keyboardOverlap(for: nextFrame)
        AgentPerformance.value("Keyboard Height", Double(nextHeight))
        let nextSnapshot = ChatKeyboardSnapshot(isVisible: nextHeight > 1)
        guard snapshot != nextSnapshot else { return }
        snapshot = nextSnapshot
    }

    private static func keyboardFrame(from notification: Notification) -> CGRect {
        notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
    }

    private static func keyboardOverlap(for endFrame: CGRect) -> CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)

        let screenHeight = window?.bounds.height ?? endFrame.maxY
        let bottomSafeArea = window?.safeAreaInsets.bottom ?? 0
        return max(0, screenHeight - endFrame.minY - bottomSafeArea)
    }
}

struct ChatKeyboardSnapshot: Equatable, Sendable {
    static let hidden = ChatKeyboardSnapshot(isVisible: false)

    let isVisible: Bool
}

struct JumpToLatestButton: View {
    let tint: Color
    var glassNamespace: Namespace.ID? = nil
    let action: () -> Void
    @Namespace private var localGlassNamespace

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .black))
            .foregroundStyle(AgentPalette.ink)
            .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
            .agentControlSurface(
                radius: AgentDesign.minimumTouchTarget / 2,
                tint: tint.opacity(0.14),
                selected: true
            )
            .agentGlassEffectID("chat-latest", in: glassNamespace ?? localGlassNamespace)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("jumpToLatest")
        .accessibilityLabel("Jump to latest message")
    }
}

struct QuickDelegateSuggestion: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let prompt: String
    let tint: Color
}

struct QuickDelegateRail: View {
    let workflowSpine: ProjectWorkflowSpine?
    let send: (QuickDelegateSuggestion) -> Void

    private var suggestions: [QuickDelegateSuggestion] {
        if let workflowSpine {
            return [
                QuickDelegateSuggestion(
                    id: "continue",
                    title: "Continue",
                    symbol: "arrow.triangle.2.circlepath",
                    prompt: workflowSpine.nextActionDetail,
                    tint: AgentPalette.green
                ),
                QuickDelegateSuggestion(
                    id: "iterate",
                    title: "Iterate",
                    symbol: "wand.and.sparkles",
                    prompt: workflowSpine.iterationPrompt,
                    tint: AgentPalette.cyan
                ),
                QuickDelegateSuggestion(
                    id: "verify",
                    title: "Verify",
                    symbol: "checkmark.shield.fill",
                    prompt: "Verify \(workflowSpine.changedDetail), refresh proof, and report any remaining blocker.",
                    tint: AgentPalette.lilac
                )
            ]
        }
        return [
            QuickDelegateSuggestion(
                id: "inspect",
                title: "Inspect",
                symbol: "doc.text.magnifyingglass",
                prompt: "Inspect the workspace and tell me the important files, recent changes, and best next step.",
                tint: AgentPalette.cyan
            ),
            QuickDelegateSuggestion(
                id: "plan",
                title: "Plan",
                symbol: "checklist",
                prompt: "Plan the next safe changes for this workspace. Keep it concise and list what you would edit first.",
                tint: AgentPalette.cyan
            ),
            QuickDelegateSuggestion(
                id: "search",
                title: "Search",
                symbol: "magnifyingglass",
                prompt: "Search the workspace for TODO, FIXME, error, and failing. Summarize anything worth acting on.",
                tint: AgentPalette.lilac
            )
        ]
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(suggestions) { suggestion in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    send(suggestion)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: suggestion.symbol)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(suggestion.tint)
                            .frame(width: 10)
                        Text(suggestion.title)
                            .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                    .padding(.horizontal, 6)
                    .frame(width: chipWidth(for: suggestion), height: AgentDesign.minimumTouchTarget)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .agentControlSurface(radius: 8, tint: suggestion.tint, selected: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(suggestion.title) workspace")
                .accessibilityIdentifier("quickAction-\(suggestion.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chipWidth(for suggestion: QuickDelegateSuggestion) -> CGFloat {
        switch suggestion.id {
        case "plan": 64
        case "continue": 82
        case "iterate": 76
        case "verify": 72
        case "search": 82
        default: 84
        }
    }
}

struct ThreadWindowBanner: View {
    let hiddenCount: Int
    let showingFullThread: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: showingFullThread ? "text.alignleft" : "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 28, height: 28)
                .agentSurface(radius: 9, tint: AgentPalette.cyan.opacity(0.10))

            VStack(alignment: .leading, spacing: 1) {
                Text(showingFullThread ? "Loaded visible history" : "Earlier context retained")
                    .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                Text(showingFullThread ? "Collapse to keep this session instant" : "\(hiddenCount) older messages hidden · loads in pages")
                    .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: toggle) {
                Text(showingFullThread ? "Collapse" : "Load older")
                    .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .padding(.horizontal, 10)
                    .frame(height: AgentDesign.minimumTouchTarget)
                    .agentGlass(radius: 10, interactive: true, tint: AgentPalette.cyan.opacity(0.10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showingFullThread ? "Collapse earlier messages" : "Load older messages")
        }
        .padding(10)
        .agentSurface(radius: 16, tint: AgentPalette.cyan.opacity(0.04))
    }
}

struct StatusDot: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
            Text(text)
                .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .agentControlSurface(radius: 8, tint: tint.opacity(0.10), selected: true)
    }
}

/// First-run as a moment: when the local brain isn't on the device yet,
/// the empty chat becomes the power-up sequence — the arc-reactor gauge
/// filling as the model downloads — instead of burying setup in a clipped
/// header chip and a composer hint.
struct FirstRunPowerUp: View {
    var localModels: LocalModelManager

    private var variant: LocalModelVariant { localModels.selectedVariant }

    private var isBusy: Bool {
        if case .downloading = localModels.status { return true }
        if case .checking = localModels.status { return true }
        return false
    }

    private var fraction: Double {
        switch localModels.status {
        case .ready: return 1
        case .downloading, .partial: return localModels.progress.fraction
        default: return 0
        }
    }

    private var gaugeValue: String {
        switch localModels.status {
        case .downloading, .partial:
            return "\(Int((localModels.progress.fraction * 100).rounded()))%"
        case .ready:
            return "100%"
        default:
            return "PWR"
        }
    }

    private var headline: String {
        switch localModels.status {
        case .downloading: return "Powering up"
        case .partial: return "Power-up paused"
        case .failed: return "Power-up failed"
        case .incompatible: return "Needs a smaller core"
        default: return "Power up NovaForge"
        }
    }

    private var detail: String {
        switch localModels.status {
        case .downloading:
            return "\(variant.shortName) is landing on this device. You can keep exploring — it installs in the background."
        case .partial:
            return "Resume to finish installing \(variant.shortName). Progress is saved."
        case .failed(let message):
            return message
        case .incompatible(let message):
            return message
        default:
            return "One download and everything — chat, builds, proof — runs entirely on this device. No account, no cloud."
        }
    }

    private var actionTitle: String {
        switch localModels.status {
        case .downloading: return "Downloading…"
        case .partial: return "Resume download"
        case .failed: return "Try again"
        default: return "Download \(variant.expectedSizeLabel)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                NovaReactorGauge(
                    fraction: fraction,
                    value: gaugeValue,
                    label: variant.shortName,
                    tint: AgentPalette.cyan,
                    size: 84,
                    isLive: isBusy
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("LOCAL SETUP")
                        .novaLabel(AgentPalette.tertiaryText)
                    Text(headline)
                        .font(NovaType.display)
                        .foregroundStyle(AgentPalette.ink)
                        .contentTransition(.opacity)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(NovaType.body)
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            NovaGlassDivider(tint: AgentPalette.cyan)

            VStack(spacing: 7) {
                PowerUpReadinessRow(
                    title: "Next action",
                    value: actionTitle,
                    symbol: isBusy ? "waveform" : "arrow.down.circle.fill",
                    tint: AgentPalette.cyan
                )
                PowerUpReadinessRow(
                    title: "Unlocks",
                    value: "Starter prompts, local chat, and workspace proof",
                    symbol: "sparkles",
                    tint: AgentPalette.green
                )
                PowerUpReadinessRow(
                    title: "Safety",
                    value: "Runs stay on this iPhone; writes still ask first",
                    symbol: "lock.shield.fill",
                    tint: AgentPalette.lilac
                )
            }

            if case .incompatible = localModels.status {
                EmptyView()
            } else {
                NovaCapsuleButton(
                    title: actionTitle,
                    symbol: isBusy ? "waveform" : "bolt.fill",
                    tint: AgentPalette.cyan,
                    accessibilityIdentifier: "firstRunPowerUpButton"
                ) {
                    guard !isBusy else { return }
                    localModels.downloadSelected()
                }
                .disabled(isBusy)
                .opacity(isBusy ? 0.65 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 7) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AgentPalette.cyan)
                Text("\(variant.expectedSizeLabel) / \(variant.executionLabel) / no API key needed")
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer(minLength: 0)
                Text("LOCAL-FIRST")
                    .font(NovaType.label)
                    .foregroundStyle(AgentPalette.cyan)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .agentControlSurface(radius: 11, tint: AgentPalette.cyan.opacity(0.07), selected: false)
        }
        .padding(16)
        .agentSurface(radius: 24, tint: AgentPalette.cyan.opacity(0.07))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 10)
        .animation(.smooth(duration: 0.4), value: fraction)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRunPowerUp")
    }
}

private struct PowerUpReadinessRow: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .agentControlSurface(radius: 9, tint: tint.opacity(0.09), selected: false)

            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(NovaType.label)
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                Text(value)
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.84)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .agentRowSurface(radius: 14, tint: tint.opacity(0.06), selected: false)
    }
}

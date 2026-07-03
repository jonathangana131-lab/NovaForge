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
    var apply: (String) -> Void = { _ in }

    private static let starters: [(symbol: String, title: String, prompt: String)] = [
        ("hammer.fill", "Build something", "Build me a small SwiftUI view and save it to the workspace"),
        ("list.bullet.clipboard.fill", "Plan a mission", "Draft a step-by-step plan for my next feature and wait for my go"),
        ("doc.text.magnifyingglass", "Explore my files", "Summarize what is in my workspace right now")
    ]

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(AgentPalette.primaryAccent.opacity(0.14))
                    .frame(width: 74, height: 74)
                    .blur(radius: 14)
                Circle()
                    .fill(AgentPalette.primaryAccent.opacity(0.10))
                    .frame(width: 58, height: 58)
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(AgentPalette.primaryAccent)
            }

            VStack(spacing: 6) {
                Text("Ready when you are")
                    .font(.system(size: 19, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Text("Your on-device agent. Ask anything,\nor hand it a mission.")
                    .font(.system(size: 12.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            VStack(spacing: 8) {
                ForEach(Self.starters, id: \.title) { starter in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        apply(starter.prompt)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: starter.symbol)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AgentPalette.primaryAccent)
                                .frame(width: 24, height: 24)
                                .background(AgentPalette.primaryAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(starter.title)
                                .font(.system(size: 13, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.ink)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(AgentPalette.tertiaryText)
                        }
                        .padding(.horizontal, 13)
                        .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .agentRowSurface(radius: 15, tint: AgentPalette.primaryAccent)
                    .accessibilityLabel(starter.title)
                }
            }
            .frame(maxWidth: 340)
        }
        .padding(.top, 46)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clean chat ready")
        .accessibilityIdentifier("cleanChatEmptyState")
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
            .frame(minHeight: 38)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .agentControlSurface(radius: 13, tint: AgentPalette.cyan.opacity(0.10), selected: true)
        .accessibilityLabel("Active response is running in \(title). Open running chat.")
        .accessibilityIdentifier("activeResponseElsewhereDock")
    }
}

struct ChatLiveResponseIsland: View {
    let runtime: AgentRuntime
    let isVisibleForFrameProfiling: Bool

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Live Response Island Body")
        let isWorking = runtime.isWorking
        let stream = runtime.liveStream
        ZStack(alignment: .topLeading) {
            LiveResponseView(isWorking: isWorking, stream: stream, runtime: runtime)

            if AgentPerformance.shouldProfileFrameRate {
                ChatStreamingFrameRateProbe(
                    stream: stream,
                    isWorking: isWorking,
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

    var body: some View {
        PerformanceFrameProbe(
            surface: .chatStreaming,
            isActive: isVisibleForFrameProfiling && (isWorking || !stream.isEmpty)
        )
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

final class ChatKeyboardState: ObservableObject {
    @Published private(set) var overlapHeight: CGFloat = 0
    @Published private(set) var minY: CGFloat = .greatestFiniteMagnitude
    @Published private(set) var revision = 0

    var isVisible: Bool {
        minY < .greatestFiniteMagnitude && overlapHeight > 1
    }

    func reset() {
        overlapHeight = 0
        minY = .greatestFiniteMagnitude
        revision &+= 1
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
        let nextMinY = nextHeight > 1 ? nextFrame.minY : .greatestFiniteMagnitude
        guard abs(nextHeight - overlapHeight) > 0.5 || abs(nextMinY - minY) > 0.5 else { return }
        overlapHeight = nextHeight
        minY = nextMinY
        AgentPerformance.value("Keyboard Height", Double(nextHeight))
        revision &+= 1
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

struct JumpToLatestButton: View {
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .black))
                Text("Latest")
                    .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
            }
            .foregroundStyle(AgentPalette.ink)
            .padding(.horizontal, 12)
            .frame(height: AgentDesign.minimumTouchTarget)
            .agentGlass(radius: 14, interactive: true, tint: tint.opacity(0.14))
            .shadow(color: tint.opacity(0.16), radius: 10, x: 0, y: 5)
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

struct CodexChatTerminalCard: View {
    let isPaired: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Circle().fill(AgentPalette.rose).frame(width: 7, height: 7)
                    Circle().fill(AgentPalette.lilac).frame(width: 7, height: 7)
                    Circle().fill(AgentPalette.green).frame(width: 7, height: 7)
                }
                Text("codex simulated terminal")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(AgentPalette.terminalOutput)
                Spacer(minLength: 0)
                Text(isPaired ? "SIMULATED" : "SETUP")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(isPaired ? AgentPalette.green : AgentPalette.cyan)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("$ codex login --device-auth")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(AgentPalette.terminalText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(isPaired ? "Simulated CLI flow reviewed. Real model calls still need API setup." : "Open Settings for the Start / Safari / Copy Code / Finish flow.")
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.terminalOutput)
                    .lineLimit(2)
            }

            Button(action: openSettings) {
                Label(isPaired ? "Review Simulated Flow" : "Open Codex Terminal", systemImage: "terminal.fill")
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.terminalText)
                    .frame(maxWidth: .infinity)
                    .frame(height: AgentDesign.minimumTouchTarget)
                    .agentControlSurface(radius: 11, tint: AgentPalette.indigo.opacity(0.16), selected: true)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [AgentPalette.terminalBackground.opacity(0.96), AgentPalette.codeBackground.opacity(0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AgentPalette.terminalSelection.opacity(0.60), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codexChatTerminalCard")
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

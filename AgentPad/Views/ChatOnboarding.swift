//
//  ChatOnboarding.swift
//  First-run chat surfaces: the project launcher, starter mission cards,
//  readiness chips, and the project status board. Extracted from ChatView.swift.
//

import SwiftUI

struct FirstRunProjectLauncher: View {
    struct Starter: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let tint: Color
        let prompt: String
    }

    let runtime: AgentRuntime
    let settings: AgentSettings
    let openSettings: () -> Void
    let start: (String) -> Void

    private let starters: [Starter] = [
        Starter(
            id: "build",
            title: "Build",
            subtitle: "Prompt → playable app",
            symbol: "hammer.fill",
            tint: AgentPalette.blue,
            prompt: "Build a small polished playable HTML game in this workspace. Create the working file, validate it, and tell me exactly how to open and run the live artifact."
        ),
        Starter(
            id: "fix",
            title: "Fix",
            subtitle: "Inspect and repair",
            symbol: "stethoscope",
            tint: AgentPalette.green,
            prompt: "Inspect this project for bugs, risky files, and obvious improvements. Fix the safe issues you can verify, then summarize what changed."
        ),
        Starter(
            id: "audit",
            title: "Audit",
            subtitle: "Find weak spots",
            symbol: "checklist.checked",
            tint: AgentPalette.cyan,
            prompt: "Audit this workspace like a senior developer. Show the important files, risks, and the best next actions before changing anything risky."
        ),
        Starter(
            id: "ship",
            title: "Ship",
            subtitle: "Polish + verify",
            symbol: "paperplane.fill",
            tint: AgentPalette.lilac,
            prompt: "Do a focused ship-readiness pass: pick the highest-impact polish, verify it, and give me the final proof and any known glitches."
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(AgentPalette.cyan.opacity(0.12))
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(AgentPalette.ink)
                }
                .frame(width: 38, height: 38)
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(AgentPalette.cyan.opacity(0.32), lineWidth: 0.6)
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Launch a project")
                        .font(.system(size: 17, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                    Text(launcherSubtitle)
                        .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Text(setupBlocksStarters ? "SETUP" : "READY")
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(setupBlocksStarters ? setupTint : AgentPalette.green)
                    .padding(.horizontal, 8)
                    .frame(height: 25)
                    .agentControlSurface(
                        radius: 9,
                        tint: (setupBlocksStarters ? setupTint : AgentPalette.green).opacity(0.10),
                        selected: true
                    )
            }

            setupHonestyCard

            if setupBlocksStarters {
                lockedStarterSummary
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)],
                    spacing: 7
                ) {
                    ForEach(starters) { starter in
                        MissionStarterCard(starter: starter, disabled: false) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            start(starter.prompt)
                        }
                    }
                }
            }

            if !setupBlocksStarters {
                readinessRail
            }
        }
        .padding(12)
        .agentSurface(radius: 22, tint: AgentPalette.accent.opacity(0.04))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRunProjectLauncher")
    }

    private var launcherSubtitle: String {
        setupBlocksStarters
        ? "Finish setup once, then build, fix, audit, and ship from one prompt."
        : "Prompt-to-app flows for building, fixing, and shipping."
    }

    private var setupHonestyCard: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: setupSymbol)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(setupTint)
                .frame(width: 26, height: 26)
                .agentControlSurface(radius: AgentDesign.chipRadius, tint: setupTint, selected: false)

            VStack(alignment: .leading, spacing: 3) {
                Text(setupTitle)
                    .font(.system(size: 11.5, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Text(setupDetail)
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
            }

            Spacer(minLength: 0)

            if setupNeedsSettingsButton {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    openSettings()
                } label: {
                    Text(setupButtonTitle)
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .padding(.horizontal, 11)
                        .frame(minWidth: AgentDesign.minimumTouchTarget, minHeight: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .agentControlSurface(radius: 13, tint: setupTint.opacity(0.10), selected: true)
                .accessibilityLabel(setupButtonAccessibilityLabel)
                .accessibilityIdentifier(setupButtonIdentifier)
            }
        }
        .padding(9)
        .agentRowSurface(radius: AgentDesign.rowRadius, tint: setupTint.opacity(0.07), selected: setupBlocksStarters)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(setupTitle). \(setupDetail)")
        .accessibilityIdentifier("firstRunSetupHonesty")
    }

    private var lockedStarterSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 24, height: 24)
                .agentControlSurface(radius: 8, tint: AgentPalette.cyan.opacity(0.08), selected: false)

            VStack(alignment: .leading, spacing: 2) {
                Text("Unlocks Build · Fix · Audit · Ship")
                    .font(.system(size: 10.5, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text("One setup step turns these into starter prompts.")
                    .font(.system(size: 9.2, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AgentPalette.surface.opacity(0.26), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AgentPalette.border.opacity(0.14), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lockedStarterSummary")
    }

    private var readinessRail: some View {
        HStack(spacing: 6) {
            ReadinessChip(title: "Actions", symbol: "bolt.fill", tint: AgentPalette.green)
            ReadinessChip(title: "Files", symbol: "folder.fill", tint: AgentPalette.cyan)
            ReadinessChip(title: "Setup", symbol: "checkmark.seal.fill", tint: AgentPalette.lilac)
        }
    }

    private var setupBlocksStarters: Bool {
        missingCredentialSetup || missingLocalModelSetup
    }

    private var setupNeedsSettingsButton: Bool {
        setupBlocksStarters
    }

    private var missingCredentialSetup: Bool {
        settings.provider != .local && runtime.apiKey(for: settings.provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var missingLocalModelSetup: Bool {
        settings.provider == .local && (!runtime.localModels.isDownloaded || debugForcesLocalModelMissing)
    }

    private var debugForcesLocalModelMissing: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--first-run-local-model-missing")
        #else
        false
        #endif
    }

    private var setupButtonTitle: String {
        missingLocalModelSetup ? "Open Downloads" : "Settings"
    }

    private var setupButtonIdentifier: String {
        missingLocalModelSetup ? "firstRunSetupDownload" : "firstRunSetupSettings"
    }

    private var setupButtonAccessibilityLabel: String {
        missingLocalModelSetup ? "Open local model downloads" : "Open provider settings"
    }

    private var setupSymbol: String {
        if missingCredentialSetup { return "key.slash.fill" }
        if missingLocalModelSetup { return "arrow.down.circle.fill" }
        return "checkmark.seal.fill"
    }

    private var setupTint: Color {
        if missingCredentialSetup { return AgentPalette.rose }
        if missingLocalModelSetup { return AgentPalette.lilac }
        return AgentPalette.green
    }

    private var setupTitle: String {
        if missingCredentialSetup { return "Provider setup needed" }
        if missingLocalModelSetup { return "Local model not downloaded" }
        return "Ready for this provider"
    }

    private var setupDetail: String {
        if missingCredentialSetup {
            return "\(settings.provider.missingCredentialMessage) NovaForge will not fake responses."
        }
        if missingLocalModelSetup {
            return "Starter missions are blocked until the local model is downloaded."
        }
        return "\(settings.provider.displayName) is configured for real runs."
    }
}

struct MissionStarterCard: View {
    let starter: FirstRunProjectLauncher.Starter
    let disabled: Bool
    let start: () -> Void

    var body: some View {
        Button(action: start) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: starter.symbol)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(starter.tint)
                        .frame(width: 25, height: 25)
                        .agentControlSurface(radius: 10, tint: starter.tint.opacity(0.86), selected: false)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(starter.tint)
                        .opacity(0.78)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(starter.title)
                        .font(.system(size: 12.5, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(starter.subtitle)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .agentRowSurface(radius: 14, tint: starter.tint.opacity(0.10), selected: false)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.56 : 1.0)
        .accessibilityLabel("\(starter.title) starter")
        .accessibilityIdentifier("missionStarter-\(starter.id)")
    }
}

struct ReadinessChip: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .black))
            Text(title)
                .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .lineLimit(1)
                .minimumScaleFactor(0.94)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .agentControlSurface(radius: 10, tint: tint.opacity(0.08), selected: false)
    }
}

struct ProjectStatusBoard: View {
    var runtime: AgentRuntime

    private enum BoardState {
        case failed
        case approval
        case paused
        case live
        case done
        case ready

        var pillText: String {
            switch self {
            case .failed: return "FAILED"
            case .approval: return "APPROVAL"
            case .paused: return "PAUSED"
            case .live: return "LIVE"
            case .done: return "DONE"
            case .ready: return "READY"
            }
        }

        var modeText: String {
            switch self {
            case .failed: return "Needs review"
            case .approval: return "Awaiting approval"
            case .paused: return "Paused"
            case .live: return "Agent running"
            case .done: return "Done"
            case .ready: return "Ready"
            }
        }

        var symbol: String {
            switch self {
            case .failed: return "exclamationmark.triangle.fill"
            case .approval: return "checkmark.shield.fill"
            case .paused: return "pause.circle.fill"
            case .live: return "waveform"
            case .done: return "checkmark.seal.fill"
            case .ready: return "sparkles"
            }
        }

        var tint: Color {
            switch self {
            case .failed: return AgentPalette.rose
            case .approval, .paused, .live: return AgentPalette.cyan
            case .done, .ready: return AgentPalette.green
            }
        }
    }

    private var boardState: BoardState {
        if runtime.lastError != nil { return .failed }
        if runtime.pendingTool != nil { return .approval }
        if runtime.wasInterrupted { return .paused }
        if runtime.isWorking { return .live }
        if runtime.lastRunDuration != nil ||
            runtime.runState == .completed ||
            runtime.traceEvents.contains(where: { $0.status == .success }) ||
            runtime.currentArtifacts.isEmpty == false {
            return .done
        }
        return .ready
    }

    private var lastAction: String {
        if runtime.lastError != nil {
            return "Run needs review"
        }
        if runtime.pendingTool != nil {
            return "Approval waiting"
        }
        if runtime.wasInterrupted {
            return "Run paused"
        }
        if let activeTool = runtime.activeToolName, !activeTool.isEmpty {
            return "Running \(friendlyToolName(activeTool))"
        }
        if let artifact = runtime.currentArtifacts.first {
            return artifact.isWebPage ? "Playable artifact ready" : "Created \(artifact.title)"
        }
        if runtime.traceEvents.contains(where: { $0.status == .success }) {
            return "Run completed"
        }
        return "Ready for first task"
    }

    private var nextAction: String {
        if runtime.pendingTool != nil { return "Review the approval card" }
        if runtime.lastError != nil { return "Retry or continue the run" }
        if let artifact = runtime.currentArtifacts.first {
            return artifact.isWebPage ? "Preview \(artifact.title)" : "Open \(artifact.title)"
        }
        return "Choose a starter flow"
    }

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Project Status Board Body")
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(AgentPalette.green)
                    .frame(width: 28, height: 28)
                    .agentControlSurface(radius: 11, tint: AgentPalette.green.opacity(0.08), selected: false)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Project Status")
                        .font(.system(size: 12.5, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .accessibilityIdentifier("projectStatusTitle")
                    Text("Live handoff for this workspace")
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }

                Spacer(minLength: 0)

                Text(boardState.pillText)
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(boardState.tint)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .agentControlSurface(radius: 10, tint: boardState.tint.opacity(0.10), selected: true)
                    .accessibilityIdentifier("projectStatusStatePill")
            }

            VStack(spacing: 6) {
                StatusBoardTile(title: "Last", value: lastAction, symbol: "clock.fill", tint: AgentPalette.cyan, rowIdentifier: "projectStatusLastRow")
                StatusBoardTile(title: "Next", value: nextAction, symbol: "arrow.right.circle.fill", tint: AgentPalette.cyan, rowIdentifier: "projectStatusNextRow")
                StatusBoardTile(
                    title: "Mode",
                    value: boardState.modeText,
                    symbol: boardState.symbol,
                    tint: boardState.tint,
                    rowIdentifier: "projectStatusModeRow",
                    valueIdentifier: "projectStatusModeValue"
                )
            }
        }
        .padding(10)
        .agentSurface(radius: 18, tint: AgentPalette.green.opacity(0.04))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project Status, \(boardState.pillText), last \(lastAction), next \(nextAction), mode \(boardState.modeText)")
        .accessibilityIdentifier("projectStatusBoard")
    }

    private func friendlyToolName(_ name: String) -> String {
        switch name {
        case "read_file": return "Read File"
        case "read_file_range": return "Read Range"
        case "tail_file": return "Tail File"
        case "write_file": return "Write File"
        case "append_file", "patch_file", "replace_text": return "Edit File"
        case "list_directory": return "List Files"
        case "list_tree": return "List Tree"
        case "workspace_summary": return "Workspace Summary"
        case "file_info": return "File Info"
        case "search_text": return "Search"
        case "validate_json": return "Validate JSON"
        case "validate_html_file": return "Validate HTML"
        case "extract_outline": return "Outline"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct StatusBoardTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var rowIdentifier: String? = nil
    var valueIdentifier: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)

                Text(value)
                    .font(.system(size: 11, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(valueIdentifier ?? "statusBoard\(title)Value")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        .agentControlSurface(radius: 12, tint: tint.opacity(0.07), selected: false)
        .accessibilityIdentifier(rowIdentifier ?? "statusBoard\(title)Row")
        .accessibilityElement(children: .contain)
    }
}

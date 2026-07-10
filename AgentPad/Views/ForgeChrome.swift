//
//  ForgeChrome.swift
//  NovaForge
//
//  The Forge surface chrome — the single-deck header, the one-signal
//  context line, and the live mission strip.
//
//  Architecture note: NovaForge's core loop is "tell the agent → watch it
//  work → approve the risky step → see the result". The old five-tab
//  layout fractured that loop across Chat / Project / Runs, and every tab
//  grew duplicate status chrome to compensate (chip trains that clipped
//  mid-word, stat rows of zeros, cross-tab pill buttons). Forge puts the
//  whole loop on one surface:
//
//  - ForgeHeader: one deck that can never clip. Title + status dot on the
//    first line; the project scope pill and exactly ONE prioritized signal
//    chip on the second. No horizontal scroller, no chip train.
//  - ForgeMissionStrip: the live project mission rendered as a slim strip
//    under the header — status, current activity, and the contextual
//    action (Approve / Reject, Stop, countdown) inline. What used to
//    require a tab switch is now ambient.
//

import SwiftData
import SwiftUI

// MARK: - Forge header

struct ForgeHeader: View {
    let runtime: AgentRuntime
    let project: Project
    let projects: [Project]
    let scopedProject: Project?
    let conversation: Conversation
    @Bindable var settings: AgentSettings
    let artifacts: [WorkspaceArtifact]
    let durableSnapshot: ChatDurableRunSnapshot
    let workflowSpine: ProjectWorkflowSpine?
    let ownsActiveRunState: Bool
    let missionStripOwnsLiveState: Bool
    let hasForeignActiveRun: Bool
    let foreignActiveTitle: String
    let newChat: () -> Void
    let changeScope: (Project?) -> Void
    let createProject: () -> Void
    let openWorkspaceSurface: (AppTab) -> Void
    let openArtifact: (WorkspaceArtifact) -> Void
    let openMissionDossier: () -> Void
    let openChatDrawer: () -> Void
    var glassNamespace: Namespace.ID? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var localGlassNamespace

    private var chromeTint: Color { AgentPalette.primaryAccent }

    private var sessionTitle: String {
        let trimmed = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "NovaForge" }
        if trimmed.localizedCaseInsensitiveCompare("NovaForge Session") == .orderedSame { return "NovaForge" }
        if trimmed.localizedCaseInsensitiveCompare(LaunchConversationSelection.safeStartTitle) == .orderedSame { return "NovaForge" }
        return trimmed
    }

    private var statusText: String {
        if hasForeignActiveRun { return "Elsewhere" }
        guard ownsActiveRunState else { return "Ready" }
        if runtime.queuedPromptCount > 0 { return "\(runtime.queuedPromptCount) queued" }
        if runtime.pendingTool != nil { return "Approval" }
        if runtime.isWorking { return "Working" }
        if runtime.lastError != nil { return "Failed" }
        return "Ready"
    }

    private var statusTint: Color {
        if hasForeignActiveRun { return AgentPalette.cyan }
        guard ownsActiveRunState else { return AgentPalette.accent }
        if runtime.pendingTool != nil { return AgentPalette.cyan }
        if runtime.lastError != nil { return AgentPalette.rose }
        if runtime.isWorking { return chromeTint }
        return AgentPalette.accent
    }

    private var statusSymbol: String {
        if hasForeignActiveRun { return "arrow.up.right.circle.fill" }
        guard ownsActiveRunState else { return "circle.fill" }
        return runtime.isWorking ? "waveform" : "circle.fill"
    }

    private var sortedProjects: [Project] {
        projects.sorted { lhs, rhs in
            if lhs.id == scopedProject?.id { return true }
            if rhs.id == scopedProject?.id { return false }
            if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var signal: ForgeSignal? {
        ForgeSignal.top(
            runtime: runtime,
            artifacts: artifacts,
            durableSnapshot: durableSnapshot,
            settings: settings,
            ownsActiveRunState: ownsActiveRunState,
            missionStripOwnsLiveState: missionStripOwnsLiveState,
            hasForeignActiveRun: hasForeignActiveRun,
            foreignActiveTitle: foreignActiveTitle
        )
    }

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Forge Header Body")
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 11) {
                chromeButton(
                    symbol: "bubble.left.and.bubble.right",
                    tint: chromeTint,
                    label: "Open Forge threads",
                    identifier: "forgeChatsButton",
                    action: openChatDrawer
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(sessionTitle)
                            .font(NovaType.title)
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("currentChatTitle")

                    if !missionStripOwnsLiveState {
                        StatusDot(text: statusText, symbol: statusSymbol, tint: statusTint)
                            .transition(.scale(scale: 0.88).combined(with: .opacity))
                    }
                }

                contextLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                chromeButton(
                    symbol: "square.and.pencil",
                    tint: AgentPalette.lilac,
                    label: "New mission",
                    identifier: "forgeNewChatButton",
                    action: newChat
                )
            }

            forgeSurfaceMap
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .agentGlass(radius: 24, tint: chromeTint.opacity(0.08))
        .agentGlassEffectID("forge-header", in: resolvedGlassNamespace)
        .animation(
            NovaMotion.enabled(reduceMotion: reduceMotion) ? .snappy(duration: 0.24) : nil,
            value: missionStripOwnsLiveState
        )
    }

    private var forgeSurfaceMap: some View {
        NovaSurfaceMap(
            title: "Forge loop",
            nodes: [
                NovaSurfaceMapNode(
                    title: "Brief",
                    detail: scopeTitle,
                    symbol: scopedProject == nil ? "folder.fill" : "shippingbox.fill",
                    tint: scopeTint,
                    isActive: scopedProject != nil
                ),
                NovaSurfaceMapNode(
                    title: "Run",
                    detail: statusText,
                    symbol: statusSymbol,
                    tint: statusTint,
                    isActive: ownsActiveRunState && (runtime.isWorking || runtime.pendingTool != nil)
                ),
                NovaSurfaceMapNode(
                    title: "Proof",
                    detail: "\(artifacts.count) artifacts",
                    symbol: "checkmark.seal.fill",
                    tint: AgentPalette.green,
                    isActive: !artifacts.isEmpty
                ),
                NovaSurfaceMapNode(
                    title: "Queue",
                    detail: durableSnapshot.pendingApprovalCount > 0 ? "\(durableSnapshot.pendingApprovalCount) approvals" : "\(runtime.queuedPromptCount) queued",
                    symbol: durableSnapshot.pendingApprovalCount > 0 ? "checkmark.shield.fill" : "tray.full.fill",
                    tint: durableSnapshot.pendingApprovalCount > 0 ? AgentPalette.cyan : AgentPalette.lilac,
                    isActive: durableSnapshot.pendingApprovalCount > 0 || runtime.queuedPromptCount > 0
                )
            ],
            tint: chromeTint
        )
        .accessibilityIdentifier("forgeSurfaceMap")
    }

    /// Second deck: the scope pill plus at most ONE prioritized signal.
    /// Fixed content only — nothing here can scroll or clip mid-word.
    @ViewBuilder
    private var contextLine: some View {
        if let signal {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    scopeMenu
                    dossierShortcut

                    Text("·")
                        .font(NovaType.caption)
                        .foregroundStyle(AgentPalette.quaternaryText)

                    ForgeSignalChip(signal: signal, glassNamespace: resolvedGlassNamespace) {
                        activate(signal)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 0)
                }

                HStack(spacing: 7) {
                    scopeMenu
                    dossierShortcut
                    compactSignalButton(signal)
                    Spacer(minLength: 0)
                }
            }
        } else {
            HStack(spacing: 7) {
                scopeMenu
                dossierShortcut
                Spacer(minLength: 0)
            }
        }
    }

    private var scopeMenu: some View {
        Menu {
            Button {
                changeScope(nil)
            } label: {
                Label("General workspace", systemImage: scopedProject == nil ? "checkmark.circle.fill" : "folder.fill")
            }

            Section("Projects") {
                ForEach(sortedProjects.prefix(12), id: \.id) { candidate in
                    Button {
                        changeScope(candidate)
                    } label: {
                        Label(candidate.name, systemImage: scopedProject?.id == candidate.id ? "checkmark.circle.fill" : "shippingbox.fill")
                    }
                }

                Button {
                    createProject()
                } label: {
                    Label("New Project", systemImage: "plus.circle.fill")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: scopedProject == nil ? "folder.fill" : "shippingbox.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(scopeTint)
                Text(compactScopeTitle)
                    .font(NovaType.caption)
                    .foregroundStyle(scopeTint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: 82, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(AgentPalette.quaternaryText)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: AgentDesign.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .agentInteractiveGlassButtonStyle(
            radius: AgentDesign.minimumTouchTarget / 2,
            tint: scopeTint,
            selected: scopedProject != nil,
            glassID: "forge-scope",
            in: resolvedGlassNamespace
        )
        .layoutPriority(2)
        .accessibilityIdentifier("chatProjectScopeMenu")
    }

    private var dossierShortcut: some View {
        Button {
            openMissionDossier()
        } label: {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AgentPalette.primaryAccent)
                .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                .contentShape(Circle())
        }
        .agentInteractiveGlassButtonStyle(
            radius: AgentDesign.minimumTouchTarget / 2,
            tint: AgentPalette.primaryAccent,
            selected: false,
            glassID: "forge-dossier",
            in: resolvedGlassNamespace
        )
        .accessibilityLabel("Open Mission Dossier")
        .accessibilityIdentifier("missionDossierShortcut")
    }

    private func compactSignalButton(_ signal: ForgeSignal) -> some View {
        Button {
            activate(signal)
        } label: {
            Image(systemName: signal.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(signal.tint)
                .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                .contentShape(Circle())
        }
        .agentInteractiveGlassButtonStyle(
            radius: AgentDesign.minimumTouchTarget / 2,
            tint: signal.tint,
            selected: true,
            glassID: "forge-signal-compact",
            in: resolvedGlassNamespace
        )
        .accessibilityLabel("\(signal.title): \(signal.detail)")
        .accessibilityIdentifier(signal.accessibilityID)
    }

    private var scopeTitle: String {
        guard let scopedProject else { return "General" }
        let trimmed = scopedProject.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ProjectBootstrap.defaultProjectName : trimmed
    }

    private var compactScopeTitle: String {
        guard scopeTitle.count > 14 else { return scopeTitle }
        return String(scopeTitle.prefix(12)) + "…"
    }

    private var scopeTint: Color {
        scopedProject == nil ? AgentPalette.secondaryText : AgentPalette.cyan
    }

    private var resolvedGlassNamespace: Namespace.ID {
        glassNamespace ?? localGlassNamespace
    }

    private func activate(_ signal: ForgeSignal) {
        NovaHaptics.tick()
        switch signal.destination {
        case .tab(let tab):
            openWorkspaceSurface(tab)
        case .artifact(let path):
            openArtifact(WorkspaceArtifact(path: path))
        case .none:
            break
        }
    }

    private func chromeButton(
        symbol: String,
        tint: Color,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                .contentShape(Circle())
        }
        .agentInteractiveGlassButtonStyle(
            radius: AgentDesign.minimumTouchTarget / 2,
            tint: tint,
            selected: false,
            glassID: identifier,
            in: resolvedGlassNamespace
        )
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Forge signal

enum ForgeSignalDestination: Equatable {
    case tab(AppTab)
    case artifact(String)
    case none
}

/// The one thing worth surfacing in the header right now. Replaces the old
/// seven-chip scroller: instead of a clipped train of everything, the
/// header shows the single highest-priority signal and everything else
/// lives where it belongs (runs in History, files in Workspace).
struct ForgeSignal: Equatable {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let destination: ForgeSignalDestination
    let accessibilityID: String

    @MainActor
    static func top(
        runtime: AgentRuntime,
        artifacts: [WorkspaceArtifact],
        durableSnapshot: ChatDurableRunSnapshot,
        settings: AgentSettings,
        ownsActiveRunState: Bool,
        missionStripOwnsLiveState: Bool,
        hasForeignActiveRun: Bool,
        foreignActiveTitle: String
    ) -> ForgeSignal? {
        if hasForeignActiveRun {
            return ForgeSignal(
                title: "Running",
                detail: foreignActiveTitle,
                symbol: "arrow.up.right.circle.fill",
                tint: AgentPalette.cyan,
                destination: .none,
                accessibilityID: "forgeSignal-foreign"
            )
        }
        if ownsActiveRunState && !missionStripOwnsLiveState {
            if let pending = runtime.pendingTool {
                return ForgeSignal(
                    title: "Approval",
                    detail: pendingDetail(for: pending),
                    symbol: "checkmark.shield.fill",
                    tint: AgentPalette.cyan,
                    destination: .tab(.history),
                    accessibilityID: "forgeSignal-approval"
                )
            }
            if runtime.isWorking {
                return ForgeSignal(
                    title: "Active",
                    detail: runtime.activityTitle,
                    symbol: "waveform",
                    tint: AgentPalette.primaryAccent,
                    destination: .tab(.history),
                    accessibilityID: "forgeSignal-active"
                )
            }
            if runtime.lastError != nil || runtime.wasInterrupted {
                return ForgeSignal(
                    title: runtime.wasInterrupted ? "Paused" : "Failed",
                    detail: runtime.lastError ?? "Continue from saved progress",
                    symbol: runtime.wasInterrupted ? "pause.circle.fill" : "exclamationmark.triangle.fill",
                    tint: runtime.wasInterrupted ? AgentPalette.blue : AgentPalette.rose,
                    destination: .tab(.history),
                    accessibilityID: "forgeSignal-recover"
                )
            }
            if runtime.queuedPromptCount > 0 {
                return ForgeSignal(
                    title: "Queued",
                    detail: "\(runtime.queuedPromptCount) follow-up\(runtime.queuedPromptCount == 1 ? "" : "s")",
                    symbol: "tray.full.fill",
                    tint: AgentPalette.primaryAccent,
                    destination: .tab(.history),
                    accessibilityID: "forgeSignal-queued"
                )
            }
        }
        if !missionStripOwnsLiveState, durableSnapshot.pendingApprovalCount > 0 {
            return ForgeSignal(
                title: "Approval",
                detail: "\(durableSnapshot.pendingApprovalCount) waiting",
                symbol: "checkmark.shield.fill",
                tint: AgentPalette.cyan,
                destination: .tab(.history),
                accessibilityID: "forgeSignal-durableApproval"
            )
        }
        if settings.provider == .local, !runtime.localModels.isDownloaded {
            return ForgeSignal(
                title: "Model setup",
                detail: "Download needed",
                symbol: "arrow.down.circle.fill",
                tint: AgentPalette.cyan,
                destination: .tab(.control),
                accessibilityID: "forgeSignal-model"
            )
        }
        if let artifact = artifacts.first {
            return ForgeSignal(
                title: artifact.isSwiftGameArtifact || artifact.isPlayableWebArtifact ? "Playable" : "Artifact",
                detail: artifact.title,
                symbol: artifact.handoffSymbol,
                tint: AgentPalette.green,
                destination: .artifact(artifact.path),
                accessibilityID: "forgeSignal-artifact"
            )
        }
        return nil
    }

    @MainActor
    private static func pendingDetail(for request: ToolRequest) -> String {
        for key in ["path", "from", "to", "command", "query", "name"] {
            guard let value = request.arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            if key == "path" {
                let name = URL(fileURLWithPath: value).lastPathComponent
                return name.isEmpty ? value : name
            }
            let flattened = value.replacingOccurrences(of: "\n", with: " ")
            guard flattened.count > 40 else { return flattened }
            return String(flattened.prefix(37)) + "..."
        }
        return plainToolName(request.name)
    }
}

struct ForgeSignalChip: View {
    let signal: ForgeSignal
    var glassNamespace: Namespace.ID? = nil
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var localGlassNamespace

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                signalLine(showDetail: true)
                signalLine(showDetail: false)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: AgentDesign.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .agentInteractiveGlassButtonStyle(
            radius: AgentDesign.minimumTouchTarget / 2,
            tint: signal.tint,
            selected: true,
            glassID: signal.accessibilityID,
            in: glassNamespace ?? localGlassNamespace
        )
        .animation(NovaMotion.enabled(reduceMotion: reduceMotion) ? .snappy(duration: 0.25) : nil, value: signal)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(signal.title): \(signal.detail)")
        .accessibilityIdentifier(signal.accessibilityID)
    }

    private func signalLine(showDetail: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: signal.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(signal.tint)
            Text(signal.title)
                .novaLabel(signal.tint)
                .fixedSize(horizontal: true, vertical: false)
            if showDetail {
                Text(signal.detail)
                    .font(NovaType.caption)
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Mission strip

/// The live project mission as ambient chrome: one slim strip that shows
/// what the agent is doing in the active project and offers the one action
/// that matters right now. Replaces the Project tab for moment-to-moment
/// awareness; the full dossier (plan, ledger, proof) opens on tap.
struct ForgeMissionStrip: View {
    let project: Project
    let scopedProject: Project?
    let status: WorkspaceStatusSnapshot
    let autoContinue: ProjectAutoContinueViewState
    var glassNamespace: Namespace.ID? = nil
    let approve: () -> Void
    let reject: () -> Void
    let stop: () -> Void
    let pauseAutoContinue: () -> Void
    let openDossier: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var localGlassNamespace

    private var allowsMotion: Bool {
        NovaMotion.enabled(reduceMotion: reduceMotion) &&
            !AgentPerformance.prefersReducedVisualEffects
    }

    /// The strip surfaces whenever the project runtime has meaningful
    /// state (working, approval, error, paused, fresh changes, countdown).
    /// `WorkspaceStatusSnapshot.isVisible` already encodes "meaningful" —
    /// an idle runtime renders nothing. On general-scoped chats the detail
    /// line carries the project name so the state is attributable.
    static func isVisible(
        scopedProject: Project?,
        status: WorkspaceStatusSnapshot,
        autoContinue: ProjectAutoContinueViewState
    ) -> Bool {
        autoContinue.isCountingDown || status.isVisible
    }

    private var tint: Color {
        if autoContinue.isCountingDown { return AgentPalette.cyan }
        switch status.tone {
        case .approval: return AgentPalette.cyan
        case .error: return AgentPalette.rose
        case .paused: return AgentPalette.blue
        case .working: return AgentPalette.primaryAccent
        case .changed: return AgentPalette.green
        case .ready: return AgentPalette.accent
        }
    }

    private var symbol: String {
        if autoContinue.isCountingDown { return "timer" }
        switch status.tone {
        case .approval: return "checkmark.shield.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        case .working: return "waveform"
        case .changed: return "sparkles"
        case .ready: return "target"
        }
    }

    private var title: String {
        if autoContinue.isCountingDown {
            return "Auto-continue in \(max(0, autoContinue.remainingSeconds))s"
        }
        return status.title
    }

    private var detail: String {
        if autoContinue.isCountingDown {
            return project.name
        }
        guard scopedProject != nil else {
            return "\(project.name) · \(status.detail)"
        }
        return status.detail
    }

    private var stepReadout: String? {
        let steps = status.progressSteps
        guard !steps.isEmpty else { return nil }
        let done = steps.filter { $0.state == .done }.count
        return "\(done)/\(steps.count)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                NovaHaptics.surfaceRevealed()
                openDossier()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .strokeBorder(tint.opacity(0.30), lineWidth: 1)
                        Image(systemName: symbol)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(tint)
                            .symbolEffect(.pulse, isActive: status.isWorking && allowsMotion)
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(NovaType.headline)
                                .foregroundStyle(AgentPalette.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .contentTransition(.numericText())
                            if let stepReadout {
                                Text(stepReadout)
                                    .font(NovaType.readoutSmall)
                                    .foregroundStyle(tint)
                                    .contentTransition(.numericText())
                            }
                        }
                        Text(detail)
                            .font(NovaType.caption)
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 6)
                }
                .frame(minHeight: AgentDesign.minimumTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityLabel("Mission: \(title). \(detail). Opens the project dossier.")
            .accessibilityIdentifier("forgeMissionStrip")

            actions
                .layoutPriority(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(
            ForgeMissionStripSurface(
                tint: tint,
                usesSafetySurface: status.tone == .approval && !autoContinue.isCountingDown,
                glassNamespace: resolvedGlassNamespace
            )
        )
        .animation(allowsMotion ? .snappy(duration: 0.3) : nil, value: status)
        .animation(allowsMotion ? .snappy(duration: 0.3) : nil, value: autoContinue)
    }

    @ViewBuilder
    private var actions: some View {
        if autoContinue.isCountingDown {
            missionActionButton(
                title: "Pause",
                symbol: "pause.fill",
                tint: AgentPalette.blue,
                identifier: "missionPauseAutoContinue",
                action: pauseAutoContinue
            )
        } else if status.tone == .approval {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    approvalButtons
                }
                VStack(spacing: 6) {
                    approvalButtons
                }
            }
        } else if status.isWorking {
            missionActionButton(
                title: "Stop",
                symbol: "stop.fill",
                tint: AgentPalette.rose,
                identifier: "missionStop",
                action: stop
            )
        }
    }

    private func missionActionButton(
        title: String,
        symbol: String,
        tint: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            NovaHaptics.tick()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .heavy))
                Text(title)
                    .font(NovaType.caption)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: AgentDesign.minimumTouchTarget)
            .contentShape(Capsule())
        }
        .agentInteractiveGlassButtonStyle(
            radius: AgentDesign.minimumTouchTarget / 2,
            tint: tint,
            selected: true,
            glassID: identifier,
            in: resolvedGlassNamespace
        )
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var approvalButtons: some View {
        missionActionButton(
            title: "Reject",
            symbol: "xmark",
            tint: AgentPalette.rose,
            identifier: "missionReject",
            action: reject
        )
        missionActionButton(
            title: "Approve",
            symbol: "checkmark",
            tint: AgentPalette.green,
            identifier: "missionApprove",
            action: approve
        )
    }

    private var resolvedGlassNamespace: Namespace.ID {
        glassNamespace ?? localGlassNamespace
    }
}

private struct ForgeMissionStripSurface: ViewModifier {
    let tint: Color
    let usesSafetySurface: Bool
    let glassNamespace: Namespace.ID

    func body(content: Content) -> some View {
        if usesSafetySurface {
            let shape = RoundedRectangle(cornerRadius: AgentDesign.rowRadius, style: .continuous)
            content
                .background(
                    shape.fill(
                        LinearGradient(
                            colors: [
                                AgentPalette.surfaceElevated.opacity(0.54),
                                AgentPalette.surface.opacity(0.42),
                                tint.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .agentGlass(radius: AgentDesign.rowRadius, tint: tint.opacity(0.14))
                .agentGlassEffectID("forge-mission", in: glassNamespace)
                .overlay(shape.strokeBorder(tint.opacity(0.36), lineWidth: 0.85))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: AgentDesign.rowRadius, bottomLeadingRadius: AgentDesign.rowRadius)
                        .fill(tint.opacity(0.86))
                        .frame(width: 3)
                }
                .shadow(color: AgentPalette.shadow.opacity(0.08), radius: 10, x: 0, y: 5)
        } else {
            // Keep status color in the glyph and actions; a restrained material
            // tint lets the shared GlassGroup refract instead of reading as a
            // solid colored card. Approval keeps the dedicated safety surface.
            content
                .agentGlass(radius: AgentDesign.rowRadius, tint: tint.opacity(0.11))
                .agentGlassEffectID("forge-mission", in: glassNamespace)
        }
    }
}

// MARK: - Mission dossier cover

/// Hosts the full project dashboard as a modal dossier: the deep dive
/// (plan, activity ledger, proof, project switching) that used to occupy a
/// whole tab now opens from the mission strip and closes back to Forge.
struct MissionDossierCover<Dashboard: View>: View {
    let close: () -> Void
    @ViewBuilder var dashboard: Dashboard

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AgentBackground(isWorking: false, isAnimated: false)
                .ignoresSafeArea()

            dashboard

            Button {
                NovaHaptics.surfaceRevealed()
                close()
            } label: {
                ZStack {
                    Color.clear
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AgentPalette.secondaryText)
                }
                .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                .background(Circle().fill(AgentPalette.ink.opacity(0.08)))
                .overlay(Circle().strokeBorder(AgentPalette.divider.opacity(0.7), lineWidth: 0.8))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .padding(.top, 8)
            .accessibilityLabel("Close mission dossier")
            .accessibilityIdentifier("missionDossierClose")
        }
    }
}

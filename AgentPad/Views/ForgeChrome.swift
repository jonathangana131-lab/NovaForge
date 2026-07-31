//
//  ForgeChrome.swift
//  NovaForge
//
//  The Forge surface chrome — a compact navigation deck and the live
//  mission strip.
//
//  Architecture note: NovaForge's core loop is "tell the agent → watch it
//  work → approve the risky step → see the result". The old five-tab
//  layout fractured that loop across Chat / Project / Runs, and every tab
//  grew duplicate status chrome to compensate (chip trains that clipped
//  mid-word, stat rows of zeros, cross-tab pill buttons). Forge puts the
//  whole loop on one surface:
//
//  - ForgeHeader: one row that can never clip. Chats, the current session
//    and project scope, Mission Dossier, and New Chat are four stable
//    controls. Runtime state stays beside the work it describes.
//  - ForgeMissionStrip: the live project mission rendered as a slim strip
//    under the header — status, current activity, and the contextual
//    action (Approve / Reject, Stop, countdown) inline. What used to
//    require a tab switch is now ambient.
//

import SwiftData
import SwiftUI
import UIKit

// MARK: - Forge header

struct ForgeHeader: View {
    let projects: [Project]
    let scopedProject: Project?
    let conversation: Conversation
    let newChat: () -> Void
    let changeScope: (Project?) -> Void
    let createProject: () -> Void
    let openMissionDossier: () -> Void
    let openChatDrawer: () -> Void
    var glassNamespace: Namespace.ID? = nil

    @Namespace private var localGlassNamespace

    private var chromeTint: Color { AgentPalette.primaryAccent }

    private var sessionTitle: String {
        ForgeConversationTitle.displayTitle(conversation.title)
    }

    private var sortedProjects: [Project] {
        projects.sorted { lhs, rhs in
            if lhs.id == scopedProject?.id { return true }
            if rhs.id == scopedProject?.id { return false }
            if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Forge Header Body")
        HStack(alignment: .center, spacing: 8) {
            chromeButton(
                symbol: "bubble.left.and.bubble.right",
                tint: chromeTint,
                label: "Open chats",
                identifier: "forgeChatsButton",
                action: openChatDrawer
            )

            scopeMenu

            if scopedProject != nil {
                dossierShortcut
            }

            chromeButton(
                symbol: "square.and.pencil",
                tint: AgentPalette.lilac,
                label: "New chat",
                identifier: "forgeNewChatButton",
                action: newChat
            )
        }
        .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("forgeTopBar")
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
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(scopeTitle)
                        .font(NovaType.headline)
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 5) {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(sessionTitle)
                            .font(NovaType.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityIdentifier("currentChatTitle")
                    }
                    .foregroundStyle(scopeTint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(scopeTint.opacity(0.78))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: AgentDesign.minimumTouchTarget)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .agentInteractiveGlassButtonStyle(
            radius: AgentDesign.minimumTouchTarget / 2,
            tint: scopeTint,
            selected: scopedProject != nil,
            glassID: "forge-scope",
            in: resolvedGlassNamespace
        )
        .frame(maxWidth: .infinity)
        .layoutPriority(1)
        .accessibilityLabel("Project scope \(scopeTitle), chat \(sessionTitle)")
        .accessibilityHint("Double tap to change project scope")
        .accessibilityIdentifier("chatProjectScopeMenu")
    }

    private var dossierShortcut: some View {
        Button {
            openMissionDossier()
        } label: {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 13, weight: .bold))
                .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
            .foregroundStyle(AgentPalette.primaryAccent)
            .contentShape(Circle())
        }
        .agentInteractiveGlassButtonStyle(
            radius: AgentDesign.minimumTouchTarget / 2,
            tint: AgentPalette.primaryAccent,
            selected: false,
            glassID: "forge-dossier",
            in: resolvedGlassNamespace
        )
        .accessibilityLabel("Open Mission Dossier for \(scopeTitle)")
        .accessibilityIdentifier("missionDossierShortcut")
    }

    private var scopeTitle: String {
        guard let scopedProject else { return "General" }
        let trimmed = scopedProject.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ProjectBootstrap.defaultProjectName : trimmed
    }


    private var scopeTint: Color {
        scopedProject == nil ? AgentPalette.secondaryText : AgentPalette.cyan
    }

    private var resolvedGlassNamespace: Namespace.ID {
        glassNamespace ?? localGlassNamespace
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

enum ForgeConversationTitle {
    static func displayTitle(_ rawTitle: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New chat" }
        let genericTitles = [
            "NovaForge",
            "NovaForge Session",
            LaunchConversationSelection.safeStartTitle,
            "New chat"
        ]
        if genericTitles.contains(where: {
            trimmed.localizedCaseInsensitiveCompare($0) == .orderedSame
        }) {
            return "New chat"
        }
        if trimmed.range(
            of: #"^NovaForge\s+[A-Z]{3}\s+\d{1,2},\s+\d{1,2}:\d{2}\s+[AP]M$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return "New chat"
        }
        return trimmed
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
    @ViewBuilder var dashboard: Dashboard

    var body: some View {
        ZStack {
            AgentBackground(isWorking: false, isAnimated: false)
                .ignoresSafeArea()

            dashboard
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

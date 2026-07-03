//
//  ProjectDashboard+Overview.swift
//  NovaForge
//
//  Overview surfaces: pinned command center, hero card, review dashboard,
//  plan preview, at-a-glance, hero next action, auto-continue, live
//  progress, latest proof.
//

import SwiftData
import SwiftUI

extension ProjectDashboardView {
    var projectPinnedCommandCenter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(statusTint)
                    .frame(width: 34, height: 34)
                    .background(statusTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 15.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .truncationMode(.tail)
                    Text("\(project.workspaceName) · \(summary.statusText)")
                        .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)

                Spacer(minLength: 0)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showsProjectSwitcherSheet = true
                } label: {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(AgentPalette.cyan)
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .agentControlSurface(radius: 13, tint: AgentPalette.cyan.opacity(0.10), selected: false)
                .accessibilityLabel("Open projects")
                .accessibilityIdentifier("projectPinnedSwitcherButton")

                Menu {
                    Button {
                        showsProjectEditSheet = true
                    } label: {
                        Label("Edit Project", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        confirmingProjectDelete = true
                    } label: {
                        Label("Delete Project", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .agentControlSurface(radius: 13, tint: AgentPalette.lilac.opacity(0.08), selected: false)
                .accessibilityLabel("Project actions")
                .accessibilityIdentifier("projectPinnedActionsMenu")
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pinnedRunEyebrow)
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(pinnedRunTint)
                        .textCase(.uppercase)
                    Text(pinnedRunDetail)
                        .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectPinnedRunReason")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    handlePinnedRunButton()
                } label: {
                    Label(pinnedRunButtonTitle, systemImage: pinnedRunButtonSymbol)
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(minWidth: 104, minHeight: AgentDesign.minimumTouchTarget)
                }
                .buttonStyle(ProjectRunButtonStyle(tint: pinnedRunTint, isDisabled: pinnedRunButtonDisabled))
                .disabled(pinnedRunButtonDisabled)
                .accessibilityHint(pinnedRunButtonDisabled ? pinnedRunDisabledReason : pinnedRunAccessibilityHint)
                .accessibilityIdentifier("projectPinnedRunButton")
            }
        }
        .padding(12)
        .agentGlass(radius: 22, interactive: false, tint: pinnedRunTint.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(pinnedRunTint.opacity(0.18), lineWidth: 0.65)
        )
        .accessibilityIdentifier("projectPinnedCommandCenter")
    }

    func handlePinnedRunButton() {
        if runtimeStatus.tone == .working {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            stopWorkspaceRun()
            return
        }
        if runtimeStatus.tone == .approval {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            approvePendingTool()
            return
        }
        guard !pinnedRunButtonDisabled else { return }
        runStartFeedback = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        runProjectCommand(project, recommendedCommandIntent, trimmedCommandContext)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_000))
            runStartFeedback = false
        }
    }

    var pinnedRunEyebrow: String {
        if runStartFeedback { return "Starting" }
        if runtimeStatus.tone == .working { return "Running" }
        if runtimeStatus.tone == .approval { return "Approval Needed" }
        if runtimeStatus.tone == .paused { return "Resume Ready" }
        if runtimeStatus.tone == .error { return "Recovery" }
        if projectOSStatus == .blocked || projectOSStatus == .failed { return "Blocked" }
        if projectOSStatus == .completed { return "Proof Ready" }
        if commandRunBlocked { return "Unavailable" }
        return "Next Run"
    }

    var pinnedRunDetail: String {
        if runStartFeedback { return "NovaForge is opening the project run now." }
        if runtimeStatus.tone == .approval { return "Review the pending request. Approve here, or reject from the approval panel below." }
        if runtimeStatus.tone == .paused { return runtimeStatus.detail }
        if runtimeStatus.tone == .error { return runtimeStatus.detail }
        if runtimeStatus.isVisible { return runtimeStatus.detail }
        if projectOSStatus == .blocked || projectOSStatus == .failed { return projectOSBlockerText }
        if projectOSStatus == .completed { return projectOSProofText }
        if commandRunBlocked { return pinnedRunDisabledReason }
        return nextStepReason
    }

    var pinnedRunButtonTitle: String {
        if runStartFeedback { return "Starting" }
        if runtimeStatus.tone == .working { return "Stop" }
        if runtimeStatus.tone == .approval { return "Approve" }
        if runtimeStatus.tone == .paused { return "Resume" }
        if runtimeStatus.tone == .error { return "Retry" }
        if projectOSStatus == .blocked || projectOSStatus == .failed { return "Recover" }
        return "Run"
    }

    var pinnedRunButtonSymbol: String {
        if runStartFeedback { return "hourglass" }
        if runtimeStatus.tone == .working { return "stop.fill" }
        if runtimeStatus.tone == .approval { return "checkmark.shield.fill" }
        if runtimeStatus.tone == .paused { return "play.fill" }
        if runtimeStatus.tone == .error { return "arrow.clockwise" }
        if projectOSStatus == .blocked || projectOSStatus == .failed { return "wrench.and.screwdriver.fill" }
        return "play.fill"
    }

    var pinnedRunTint: Color {
        if runtimeStatus.tone == .working { return AgentPalette.rose }
        if runtimeStatus.tone == .approval { return AgentPalette.cyan }
        if runtimeStatus.tone == .paused { return AgentPalette.lilac }
        if runtimeStatus.tone == .error { return AgentPalette.rose }
        if runStartFeedback { return AgentPalette.green }
        if projectOSStatus == .blocked || projectOSStatus == .failed { return AgentPalette.rose }
        if projectOSStatus == .completed { return AgentPalette.green }
        return commandTint(for: recommendedCommandIntent)
    }

    var pinnedRunButtonDisabled: Bool {
        if runtimeStatus.tone == .working { return false }
        if runtimeStatus.tone == .approval { return false }
        return commandRunBlocked
    }

    var pinnedRunDisabledReason: String {
        switch runtimeStatus.tone {
        case .approval:
            return "Review the pending approval before starting another command."
        case .working:
            return "The current run can be stopped from here."
        default:
            return runtimeStatus.detail
        }
    }

    var pinnedRunAccessibilityHint: String {
        if runtimeStatus.tone == .approval { return "Approve the pending project tool request." }
        if runtimeStatus.tone == .working { return "Stop the current workspace run." }
        if runtimeStatus.tone == .paused { return "Resume the interrupted project run." }
        if runtimeStatus.tone == .error { return "Retry the recommended recovery step." }
        if projectOSStatus == .blocked || projectOSStatus == .failed { return "Start a recovery run for the active blocker." }
        return recommendedCommandIntent.instructionFocus
    }

    var projectHeroCard: some View {
        let _ = AgentPerformance.bodyEvaluation("Project Hero Body")
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(project.workspaceName)
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(1)
                        .textCase(.uppercase)

                    Text(project.name)
                        .font(.system(size: 26, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.64)
                        .accessibilityIdentifier("projectActiveName")
                }
                .layoutPriority(1)

                Spacer(minLength: 0)
                statusBadge

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showsProjectSwitcherSheet = true
                } label: {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(AgentPalette.primaryAccent)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                .contentShape(Rectangle())
                .agentGlass(radius: 15, interactive: true, tint: AgentPalette.primaryAccent.opacity(0.14))
                .glassIDIfAvailable("project-switcher-button", namespace: projectSwitchGlassNamespace)
                .accessibilityLabel("Open projects")
                .accessibilityIdentifier("projectSwitcherSheetButton")
            }

            projectMissionBrief
            if runtimeStatus.isVisible {
                projectCompactRunStatusPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            projectReviewDashboard
            projectPlanPreviewPanel
            projectEvidenceRailPanel
            projectAtAGlanceGrid
        }
        .padding(14)
        .agentGlass(radius: 24, interactive: false, tint: statusTint.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(statusTint.opacity(0.22), lineWidth: 0.7)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectHeroCard")
    }

    struct ProjectAtAGlanceItem: Identifiable {
        let id: String
        let title: String
        let value: String
        let symbol: String
        let tint: Color
    }

    var projectMissionBrief: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "scope")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 26, height: 26)
                .background(AgentPalette.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Mission")
                    .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(missionCopy)
                    .font(.system(size: 11.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("projectMissionValue")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(AgentPalette.row.opacity(0.52), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projectMissionBrief")
    }

    var projectCompactRunStatusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: runtimeStatus.symbol)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(runtimeStatus.tint)
                    .frame(width: 26, height: 26)
                    .background(runtimeStatus.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(runtimeStatus.title)
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(runtimeStatus.detail)
                        .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if !runtimeStatus.progressSteps.isEmpty {
                VStack(spacing: 5) {
                    ForEach(runtimeStatus.progressSteps.prefix(3)) { step in
                        compactRunStepRow(step)
                    }
                }
            }
        }
        .padding(10)
        .background(runtimeStatus.tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(runtimeStatus.tint.opacity(0.18), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectCompactRunStatusPanel")
    }

    func compactRunStepRow(_ step: WorkspaceProgressStep) -> some View {
        let tint = liveProgressTint(for: step.state)
        return HStack(spacing: 7) {
            Image(systemName: liveProgressSymbol(for: step))
                .font(.system(size: 8.5, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 19, height: 19)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(step.title)
                .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(liveProgressStateLabel(step.state))
                .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(AgentPalette.row.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title), \(liveProgressStateLabel(step.state))")
    }

    var projectReviewDashboard: some View {
        let review = summary.review
        let tint = self.reviewTint(for: review.recommendation)
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 12) {
                projectReviewScoreGauge(score: review.healthScore, tint: tint)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Label(review.recommendation.displayName, systemImage: review.recommendation.symbolName)
                            .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                        Text(review.proofFreshness)
                            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(self.proofFreshnessTint)
                            .lineLimit(1)
                    }

                    Text(review.headline)
                        .font(.system(size: 14.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .accessibilityIdentifier("projectReviewHeadline")

                    Text(review.detail)
                        .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectReviewDetail")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 6) {
                ForEach(Array(review.findings.prefix(3))) { finding in
                    projectReviewFindingRow(finding, compact: true)
                }
            }
        }
        .padding(11)
        .background(
            LinearGradient(
                colors: [
                    tint.opacity(0.12),
                    AgentPalette.row.opacity(0.62),
                    AgentPalette.surfaceAlt.opacity(0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 0.65)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectReviewDashboard")
    }

    func projectReviewScoreGauge(score: Int, tint: Color) -> some View {
        ZStack {
            Circle()
                .stroke(AgentPalette.border.opacity(0.26), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(score, 100))) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: 17, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                Text("health")
                    .font(.system(size: 6.8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
            }
        }
        .frame(width: 56, height: 56)
        .accessibilityLabel("Project health \(score) percent")
    }

    func projectReviewFindingRow(_ finding: ProjectReviewFinding, compact: Bool) -> some View {
        let tint = self.reviewFindingTint(finding.severity)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: finding.symbolName)
                .font(.system(size: compact ? 9 : 11, weight: .black))
                .foregroundStyle(tint)
                .frame(width: compact ? 20 : 26, height: compact ? 20 : 26)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous))

            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                Text(finding.title)
                    .font(.system(size: compact ? 9.5 : 11.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                Text(finding.detail)
                    .font(.system(size: compact ? 9 : 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(compact ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 6 : 8)
        .background(tint.opacity(compact ? 0.055 : 0.07), in: RoundedRectangle(cornerRadius: compact ? 11 : 13, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(finding.title). \(finding.detail)")
        .accessibilityIdentifier("projectReviewFinding-\(finding.id)")
    }

    var projectPlanPreviewPanel: some View {
        let contract = summary.missionContract
        let tint = missionOSTint(for: contract)
        let activeGate = contract.blockingGates.first ?? contract.gates.first { $0.state != .satisfied } ?? contract.gates.last
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Project Plan", systemImage: contract.phase.symbolName)
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text(contract.gateSummary)
                    .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }

            missionPhaseTrack(contract)

            if let activeGate {
                missionPlanActiveRow(activeGate)
            }

            nextActionSignal(
                title: "Why this is next",
                value: nextStepReason,
                symbol: "arrow.triangle.branch",
                tint: commandTint(for: recommendedCommandIntent),
                accessibilityIdentifier: "projectPlanWhyNext"
            )
        }
        .padding(11)
        .background(AgentPalette.row.opacity(0.58), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.6)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectPlanPreviewPanel")
    }

    func missionPhaseTrack(_ contract: MissionOSContract) -> some View {
        let currentIndex = self.phaseIndex(contract.phase)
        return HStack(spacing: 5) {
            ForEach(MissionOSPhase.allCases, id: \.self) { phase in
                let index = self.phaseIndex(phase)
                let isCurrent = index == currentIndex
                let tint = self.phaseTrackTint(phase, contract: contract)
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint.opacity(index <= currentIndex ? 0.92 : 0.20))
                        .frame(height: isCurrent ? 9 : 6)
                    Text(String(phase.displayName.prefix(1)))
                        .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(isCurrent ? tint : AgentPalette.tertiaryText)
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("\(phase.displayName) \(index < currentIndex ? "complete" : isCurrent ? "current" : "upcoming")")
            }
        }
        .accessibilityIdentifier("projectMissionPhaseTrack")
    }

    func missionPlanActiveRow(_ gate: MissionOSGate) -> some View {
        let tint = missionOSGateTint(gate.state)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: gate.state.symbolName)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(gate.title)
                        .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(gate.state.displayName)
                        .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                Text(gate.detail)
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projectPlanActiveGate")
    }

    struct ProjectEvidenceNode: Identifiable {
        let id: String
        let title: String
        let value: String
        let symbol: String
        let state: MissionOSGateState
    }

    var projectEvidenceRailPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Evidence Trail", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text(summary.review.evidenceTrail)
                    .font(.system(size: 8.8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                ForEach(projectEvidenceNodes) { node in
                    projectEvidenceNodeCell(node)
                }
            }
        }
        .padding(11)
        .background(AgentPalette.surfaceAlt.opacity(0.30), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(AgentPalette.green.opacity(0.14), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectEvidenceRailPanel")
    }

    var projectEvidenceNodes: [ProjectEvidenceNode] {
        let gates = Dictionary(uniqueKeysWithValues: summary.missionContract.gates.map { ($0.id, $0) })
        return [
            ProjectEvidenceNode(
                id: "contract",
                title: "Goal",
                value: gates["contract"]?.state.displayName ?? "Waiting",
                symbol: "scope",
                state: gates["contract"]?.state ?? .waiting
            ),
            ProjectEvidenceNode(
                id: "action",
                title: "Work",
                value: gates["action"]?.state.displayName ?? "Waiting",
                symbol: "hammer.fill",
                state: gates["action"]?.state ?? .waiting
            ),
            ProjectEvidenceNode(
                id: "verification",
                title: "Check",
                value: gates["verification"]?.state.displayName ?? "Waiting",
                symbol: "checkmark.shield.fill",
                state: gates["verification"]?.state ?? .waiting
            ),
            ProjectEvidenceNode(
                id: "proof",
                title: "Proof",
                value: summary.review.proofFreshness,
                symbol: "checkmark.seal.fill",
                state: gates["proof"]?.state ?? .waiting
            )
        ]
    }

    func projectEvidenceNodeCell(_ node: ProjectEvidenceNode) -> some View {
        let tint = missionOSGateTint(node.state)
        return HStack(spacing: 7) {
            Image(systemName: node.symbol)
                .font(.system(size: 9.5, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(node.value)
                    .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.title): \(node.value)")
        .accessibilityIdentifier("projectEvidenceNode-\(node.id)")
    }

    var projectAtAGlanceGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(projectAtAGlanceItems) { item in
                projectAtAGlanceCell(item)
            }
        }
        .accessibilityIdentifier("projectCommandCenterSnapshot")
    }

    var projectAtAGlanceItems: [ProjectAtAGlanceItem] {
        [
            ProjectAtAGlanceItem(
                id: "now",
                title: "Now",
                value: self.currentWorkText,
                symbol: runtimeStatus.isWorking ? "waveform" : statusSymbol,
                tint: runtimeStatus.isVisible ? runtimeStatus.tint : statusTint
            ),
            ProjectAtAGlanceItem(
                id: "last",
                title: "Last",
                value: summary.lastEventTitle,
                symbol: "clock.arrow.circlepath",
                tint: AgentPalette.cyan
            ),
            ProjectAtAGlanceItem(
                id: "proof",
                title: "Proof",
                value: latestProofText,
                symbol: "checkmark.seal.fill",
                tint: trustTint
            ),
            ProjectAtAGlanceItem(
                id: "changed",
                title: "Changed",
                value: self.changedArtifactText,
                symbol: "shippingbox.fill",
                tint: AgentPalette.green
            ),
            ProjectAtAGlanceItem(
                id: "approval",
                title: "Approval",
                value: approvalExpectationText,
                symbol: approvalExpectationSymbol,
                tint: approvalExpectationTint
            ),
            ProjectAtAGlanceItem(
                id: "blocker",
                title: "Blocker",
                value: self.blockerSnapshotText,
                symbol: summary.blocker.isEmpty && summary.failureCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: summary.blocker.isEmpty && summary.failureCount == 0 ? AgentPalette.lilac : AgentPalette.rose
            )
        ]
    }

    func projectAtAGlanceCell(_ item: ProjectAtAGlanceItem) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: item.symbol)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(item.tint)
                .frame(width: 22, height: 22)
                .background(item.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(item.value)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 54, alignment: .topLeading)
        .background(AgentPalette.row.opacity(0.46), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title): \(item.value)")
        .accessibilityIdentifier("projectCommandSnapshot-\(item.id)")
    }

    var projectHeroNextAction: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: commandSymbol(for: recommendedCommandIntent))
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(commandTint(for: recommendedCommandIntent))
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(commandTint(for: recommendedCommandIntent).opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Next Action")
                        .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                    Text("Agent-chosen step")
                        .font(.system(size: 14, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(summary.nextStep)
                        .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectNextStepValue")
                }

                Spacer(minLength: 0)
            }

            VStack(spacing: 6) {
                nextActionSignal(
                    title: "Why",
                    value: nextStepReason,
                    symbol: "arrow.triangle.branch",
                    tint: commandTint(for: recommendedCommandIntent),
                    accessibilityIdentifier: "projectNextStepReason"
                )
                nextActionSignal(
                    title: "Proof",
                    value: expectedProofText,
                    symbol: "checkmark.seal.fill",
                    tint: AgentPalette.green,
                    accessibilityIdentifier: "projectExpectedProof"
                )
                nextActionSignal(
                    title: "Approval",
                    value: approvalExpectationText,
                    symbol: approvalExpectationSymbol,
                    tint: approvalExpectationTint,
                    accessibilityIdentifier: "projectApprovalExpectation"
                )
            }

            self.autoContinueControl

            HStack(spacing: 9) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    runProjectCommand(project, recommendedCommandIntent, trimmedCommandContext)
                } label: {
                    Label(projectRunButtonTitle, systemImage: projectRunButtonSymbol)
                        .font(.system(size: 11.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(minWidth: AgentDesign.minimumTouchTarget, maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(ProjectRunButtonStyle(tint: projectRunButtonTint, isDisabled: commandRunBlocked))
                .disabled(commandRunBlocked)
                .accessibilityHint(commandRunBlocked ? "Finish the current run before starting another project command." : recommendedCommandIntent.instructionFocus)
                .accessibilityIdentifier("projectHeroRunButton")
            }
        }
        .padding(10)
        .frame(minHeight: 214, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AgentPalette.row.opacity(0.64))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(commandTint(for: recommendedCommandIntent).opacity(0.18), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectHeroNextAction")
    }

    func nextActionSignal(
        title: String,
        value: String,
        symbol: String,
        tint: Color,
        accessibilityIdentifier: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    var autoContinueControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { autoContinueState.isEnabled },
                set: { setAutoContinueEnabled(project, $0) }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: autoContinueSymbol)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(autoContinueTint)
                        .frame(width: 22, height: 22)
                        .background(autoContinueTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-continue next steps")
                            .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text(autoContinueStateLine)
                            .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(.switch)
            .tint(autoContinueTint)
            .accessibilityIdentifier("projectAutoContinueToggle")

            if autoContinueState.isCountingDown {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("Starts in \(autoContinueState.remainingSeconds)s")
                            .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(autoContinueTint)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                        Button {
                            pauseAutoContinue(project)
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                                .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .frame(minHeight: 30)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AgentPalette.secondaryText)
                        .accessibilityIdentifier("projectAutoContinuePauseButton")

                        Button {
                            cancelAutoContinue(project)
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                                .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .frame(minHeight: 30)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AgentPalette.rose)
                        .accessibilityIdentifier("projectAutoContinueCancelButton")
                    }

                    ProgressView(
                        value: Double(ProjectAutoContinuePolicy.countdownSeconds - autoContinueState.remainingSeconds),
                        total: Double(ProjectAutoContinuePolicy.countdownSeconds)
                    )
                    .progressViewStyle(.linear)
                    .tint(autoContinueTint)
                    .frame(height: 6)
                    .clipShape(Capsule())
                    .accessibilityHidden(true)
                }
                .padding(9)
                .background(autoContinueTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("projectAutoContinueCountdown")
            } else if autoContinueState.isPaused {
                HStack(spacing: 8) {
                    Text(autoContinueState.detail)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button {
                        setAutoContinueEnabled(project, true)
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .frame(minHeight: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AgentPalette.green)
                    .accessibilityIdentifier("projectAutoContinueResumeButton")
                }
                .padding(9)
                .background(AgentPalette.lilac.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityIdentifier("projectAutoContinuePaused")
            }
        }
        .padding(9)
        .background(AgentPalette.surfaceAlt.opacity(0.36), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(autoContinueTint.opacity(autoContinueState.isEnabled ? 0.18 : 0.10), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectAutoContinueControl")
    }

    var projectRunStatusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceStatusStrip(
                snapshot: runtimeStatus,
                pause: stopWorkspaceRun,
                destinationSymbol: "list.bullet.rectangle.portrait.fill",
                destinationAccessibilityLabel: "Open run log"
            ) {
                openTab(.runs)
            }

            if !runtimeStatus.progressSteps.isEmpty {
                projectLiveProgressPanel
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectRunStatusPanel")
    }

    var projectLiveProgressPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(runtimeStatus.tint)
                    .frame(width: 24, height: 24)
                    .background(runtimeStatus.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text("Run Progress")
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)

                Spacer(minLength: 0)

                Text(runtimeStatus.progressSteps.filter { $0.state == .done }.count.description)
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .monospacedDigit()
                    .foregroundStyle(runtimeStatus.tint)
                    .frame(minWidth: 24, minHeight: 22)
                    .background(runtimeStatus.tint.opacity(0.10), in: Capsule(style: .continuous))
            }

            VStack(spacing: 0) {
                ForEach(Array(runtimeStatus.progressSteps.prefix(7).enumerated()), id: \.element.id) { index, step in
                    liveProgressRow(step, isLast: index == min(runtimeStatus.progressSteps.count, 7) - 1)
                }
            }
            .background(AgentPalette.row.opacity(0.58), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(runtimeStatus.tint.opacity(0.14), lineWidth: 0.55)
            )
        }
        .padding(11)
        .frame(minHeight: 236, alignment: .top)
        .agentGlass(radius: 18, interactive: false, tint: runtimeStatus.tint.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectLiveProgressPanel")
    }

    func liveProgressRow(_ step: WorkspaceProgressStep, isLast: Bool) -> some View {
        let tint = liveProgressTint(for: step.state)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: liveProgressSymbol(for: step))
                    .font(.system(size: 9.5, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(step.detail)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Text(liveProgressStateLabel(step.state))
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .frame(height: 19)
                    .background(tint.opacity(0.10), in: Capsule(style: .continuous))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(step.title). \(liveProgressStateLabel(step.state)). \(step.detail)")
            .accessibilityIdentifier("projectLiveProgressStep-\(step.id)")

            if !isLast {
                Divider()
                    .overlay(AgentPalette.border.opacity(0.34))
                    .padding(.leading, 43)
            }
        }
    }

    @ViewBuilder
    var latestEvidenceSection: some View {
        let _ = AgentPerformance.bodyEvaluation("Project Latest Evidence Body")
        sectionShell(
            title: latestEvidenceTitle,
            subtitle: latestEvidenceSubtitle,
            symbol: latestEvidenceSymbol,
            tint: latestEvidenceTint
        ) {
            if let artifact = latestEvidenceArtifact {
                artifactFeatureCard(artifact)
            } else if let proof = latestEvidenceProof {
                latestProofCard(proof)
            } else {
                emptyState(title: "No proof yet", detail: "Artifacts, completed runs, and file evidence will appear here.", symbol: "checkmark.seal", tint: AgentPalette.green)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectLatestEvidenceSection")
    }

    var latestEvidenceTitle: String {
        latestEvidenceArtifact == nil ? "Latest Proof" : "Latest Artifact"
    }

    var latestEvidenceSubtitle: String {
        if let artifact = latestEvidenceArtifact {
            return eventTimeText(artifact.updatedAt)
        }
        if let proof = latestEvidenceProof {
            return eventTimeText(proof.createdAt)
        }
        return "Waiting"
    }

    var latestEvidenceSymbol: String {
        latestEvidenceArtifact == nil ? "checkmark.seal.fill" : "shippingbox.fill"
    }

    var latestEvidenceTint: Color {
        if latestEvidenceArtifact != nil { return AgentPalette.cyan }
        if let proof = latestEvidenceProof { return proofTint(for: proof) }
        return AgentPalette.green
    }

    var latestEvidenceProof: ProjectProofItem? {
        summary.proofItems.first
    }

    var latestEvidenceArtifact: ProjectArtifact? {
        guard let proof = latestEvidenceProof,
              proof.id.hasPrefix("artifact-"),
              let path = proof.sourcePath else {
            return nil
        }
        return projectArtifacts.first { $0.path == path }
    }

    func latestProofCard(_ item: ProjectProofItem) -> some View {
        let tint = proofTint(for: item)
        return Button {
            openProofItem(item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    Text(item.detail)
                        .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .padding(.top, 5)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .agentRowSurface(radius: 18, tint: tint, selected: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title). \(item.detail)")
        .accessibilityIdentifier("projectLatestProofCard")
    }
}

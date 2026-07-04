//
//  ProjectDashboard+CommandCenter.swift
//  NovaForge
//
//  ProjectOS command center: control center, execution state panel,
//  action row, now panel, adaptive intent, command brief, step rows.
//

import SwiftData
import SwiftUI

extension ProjectDashboardView {
    var projectOSControlCenter: some View {
        let tint = projectOSTint
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        NovaKicker(text: "Command Center", tint: tint)
                        Text(adaptiveIntent.mode.displayName)
                            .novaLabel(tint)
                            .padding(.horizontal, 8)
                            .frame(height: 19)
                            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                            .accessibilityIdentifier("projectOSIntentMode")
                    }

                    Text(projectOSMissionText)
                        .font(NovaType.display)
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(3)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectOSMission")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                if projectOSProgressFraction > 0 || runtimeStatus.isWorking {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(projectOSCompletedStepCount)/\(max(projectOSDisplaySteps.count, 1))")
                            .font(NovaType.readout)
                            .foregroundStyle(tint)
                            .contentTransition(.numericText())
                        Text("Steps")
                            .novaLabel(AgentPalette.tertiaryText)
                    }
                    .accessibilityIdentifier("projectOSProgressCount")
                }
            }

            if projectOSProgressFraction > 0 || runtimeStatus.isWorking {
                ProgressView(value: projectOSProgressFraction, total: 1)
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .frame(height: 4)
                    .clipShape(Capsule(style: .continuous))
                    .accessibilityLabel("ProjectOS progress")
                    .accessibilityValue("\(Int((projectOSProgressFraction * 100).rounded())) percent")
            }

            Rectangle()
                .fill(AgentPalette.divider.opacity(0.45))
                .frame(height: 0.7)

            projectOSExecutionStatePanel
        }
        .padding(16)
        .agentGlass(radius: 24, interactive: false, tint: tint.opacity(0.13))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 0.7)
        )
        .overlay(NovaCornerTicks(tint: tint.opacity(0.38), length: 9, thickness: 1.3, inset: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSControlCenter")
    }

    var projectOSExecutionStatePanel: some View {
        let state = dashboardExecutionState
        let tint = dashboardExecutionTint(state)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(tint)
                            .frame(width: 6, height: 6)
                            .shadow(color: AgentPerformance.prefersReducedVisualEffects ? .clear : tint.opacity(0.8), radius: 4)
                        Text(state.shortTitle)
                            .novaLabel(tint)
                            .accessibilityIdentifier("projectOSExecutionStatePill")
                    }

                    Text(state.headline)
                        .font(NovaType.title)
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .accessibilityIdentifier("projectOSExecutionStateHeadline")

                    Text(projectOSExecutionStateDetail)
                        .font(NovaType.body)
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectOSExecutionStateDetail")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                NovaReticleGlyph(
                    symbol: state.symbolName,
                    tint: tint,
                    size: 46,
                    isActive: runtimeStatus.isWorking
                )
            }

            projectOSExecutionStateLadder
            projectOSExecutionActionRow

            HStack(alignment: .top, spacing: 0) {
                projectOSExecutionSpecColumn(title: "Evidence", value: projectOSEvidenceSummaryText, tint: AgentPalette.green)
                Rectangle()
                    .fill(AgentPalette.divider.opacity(0.5))
                    .frame(width: 1, height: 30)
                    .padding(.horizontal, 12)
                projectOSExecutionSpecColumn(title: "Logs", value: projectOSLogSummaryText, tint: AgentPalette.cyan)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSExecutionStatePanel")
    }

    func projectOSExecutionSpecColumn(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .novaLabel(tint)
            Text(value)
                .font(NovaType.caption)
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    var projectOSExecutionStateLadder: some View {
        // The previous implementation rendered ALL ten execution states as a
        // permanent chip grid — a state machine dumped into the UI. This is a
        // live journey rail instead: three phases (Plan → Build → Prove), the
        // current one lit with the execution tint and shimmering while work
        // is actually happening. The state pill + headline above already name
        // the precise state.
        let state = dashboardExecutionState
        let phase: Int
        switch state {
        case .idle, .waiting, .planning:
            phase = 0
        case .running, .approvalRequired, .blocked, .failed, .resumed:
            phase = 1
        case .succeeded, .proofReady:
            phase = 2
        }
        let live: Bool
        switch state {
        case .planning, .running, .approvalRequired:
            live = true
        default:
            live = false
        }
        return NovaExecutionJourneyRail(
            activePhase: phase,
            isLive: live,
            isTrouble: state == .failed || state == .blocked,
            tint: dashboardExecutionTint(state)
        )
        .accessibilityIdentifier("projectOSExecutionStateLadder")
    }

    @ViewBuilder
    var projectOSExecutionActionRow: some View {
        // Navigation-only by design: Run / Stop / Approve / Resume live in ONE
        // place — the pinned command center at the top of the screen. This row
        // only ever offers context jumps (plus Reject during approvals, whose
        // affirmative twin is the pinned button).
        switch dashboardExecutionState {
        case .approvalRequired:
            HStack(spacing: 8) {
                projectOSIntentSmallButton(title: "Reject", symbol: "xmark.shield.fill", tint: AgentPalette.rose) {
                    rejectPendingTool()
                }
                projectOSIntentSmallButton(title: "Runs", symbol: "waveform.path.ecg", tint: AgentPalette.lilac) {
                    openTab(.runs)
                }
            }
            .accessibilityIdentifier("projectOSApprovalActions")
        case .running, .planning:
            HStack(spacing: 8) {
                projectOSIntentSmallButton(title: "Runs", symbol: "waveform.path.ecg", tint: AgentPalette.lilac) {
                    openTab(.runs)
                }
                projectOSIntentSmallButton(title: "Timeline", symbol: "timeline.selection", tint: AgentPalette.cyan) {
                    selectedDetailScope = .timeline
                }
            }
        case .blocked, .failed, .resumed:
            HStack(spacing: 8) {
                projectOSIntentSmallButton(title: "Timeline", symbol: "timeline.selection", tint: AgentPalette.cyan) {
                    selectedDetailScope = .timeline
                }
                projectOSIntentSmallButton(title: "Runs", symbol: "waveform.path.ecg", tint: AgentPalette.lilac) {
                    openTab(.runs)
                }
            }
        case .proofReady, .succeeded:
            HStack(spacing: 8) {
                projectOSIntentSmallButton(title: "Proof", symbol: "checkmark.seal.fill", tint: AgentPalette.green) {
                    selectedDetailScope = .evidence
                }
                projectOSIntentSmallButton(title: "Runs", symbol: "waveform.path.ecg", tint: AgentPalette.lilac) {
                    openTab(.runs)
                }
            }
        case .idle, .waiting:
            HStack(spacing: 8) {
                projectOSIntentSmallButton(title: "Plan", symbol: "list.bullet.clipboard.fill", tint: AgentPalette.cyan) {
                    selectedDetailScope = .plan
                }
                projectOSIntentSmallButton(title: "Runs", symbol: "waveform.path.ecg", tint: AgentPalette.lilac) {
                    openTab(.runs)
                }
            }
        }
    }

    func projectOSExecutionMetric(title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
        .background(AgentPalette.row.opacity(0.46), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    var projectOSNowPanel: some View {
        let tint = projectOSTint
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: runtimeStatus.isWorking ? "waveform" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Now")
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .textCase(.uppercase)
                    Text(projectOSCurrentActionText)
                        .font(.system(size: 14, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .accessibilityIdentifier("projectOSCurrentAction")
                    Text(projectOSCurrentReasonText)
                        .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projectOSCurrentReason")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !projectOSCurrentCommandText.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(AgentPalette.cyan)
                    Text(projectOSCurrentCommandText)
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("projectOSCurrentCommand")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(AgentPalette.row.opacity(0.50), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(11)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSNowPanel")
    }


    func projectOSIntentDatum(
        title: String,
        value: String,
        symbol: String,
        tint: Color,
        identifier: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(value.isEmpty ? "None" : value)
                    .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(AgentPalette.row.opacity(0.46), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityIdentifier("projectOSIntentDatum-\(identifier)")
    }


    func projectOSIntentSmallButton(
        title: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AgentPalette.ink)
        .agentControlSurface(radius: 12, tint: tint.opacity(0.11), selected: false)
    }

    var projectOSSnapshotGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            projectOSSnapshotCell(
                title: "Current Step",
                value: projectOSCurrentStep?.title ?? "Ready",
                symbol: projectOSCurrentStep?.symbolName ?? "scope",
                tint: projectOSTint,
                identifier: "current-step"
            )
            projectOSSnapshotCell(
                title: "Next Step",
                value: projectOSNextStep?.title ?? projectOSNextStepText,
                symbol: "arrow.right.circle.fill",
                tint: AgentPalette.cyan,
                identifier: "next-step"
            )
            projectOSSnapshotCell(
                title: "Latest Event",
                value: activeProjectOSRun?.latestEventTitle ?? summary.lastEventTitle,
                symbol: "timeline.selection",
                tint: AgentPalette.lilac,
                identifier: "latest-event"
            )
            projectOSSnapshotCell(
                title: "Proof",
                value: projectOSProofText,
                symbol: "checkmark.seal.fill",
                tint: trustTint,
                identifier: "proof"
            )
        }
        .accessibilityIdentifier("projectOSSnapshotGrid")
    }

    func projectOSSnapshotCell(
        title: String,
        value: String,
        symbol: String,
        tint: Color,
        identifier: String
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(value)
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
        .accessibilityLabel("\(title): \(value)")
        .accessibilityIdentifier("projectOSSnapshot-\(identifier)")
    }

    var projectOSPlanPreviewPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Agent Plan", systemImage: "list.bullet.clipboard.fill")
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text(activeProjectOSRun == nil ? "Preview" : "Run \(projectOSStatusText)")
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(projectOSTint)
                    .lineLimit(1)
            }

            VStack(spacing: 0) {
                ForEach(Array(projectOSDisplaySteps.prefix(5).enumerated()), id: \.element.id) { index, step in
                    projectOSStepRow(step, isLast: index == min(projectOSDisplaySteps.count, 5) - 1)
                }
            }
            .background(AgentPalette.row.opacity(0.48), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(projectOSTint.opacity(0.12), lineWidth: 0.55)
            )
        }
        .padding(11)
        .background(AgentPalette.surfaceAlt.opacity(0.30), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSPlanPanel")
    }

    func projectOSStepRow(_ step: ProjectOSDisplayStep, isLast: Bool) -> some View {
        let tint = projectOSStepTint(step.status)
        let timeText = projectOSStepTimeText(step)
        let resultText = projectOSStepResultText(step)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: step.symbolName)
                    .font(.system(size: 9.5, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(step.title)
                            .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Text(step.status.displayName)
                            .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                        if !timeText.isEmpty {
                            Text(timeText)
                                .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.tertiaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    Text(step.detail)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !step.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(step.command)
                            .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.cyan)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !resultText.isEmpty {
                        Text(resultText)
                            .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(step.title). \(step.status.displayName). \(step.detail)")
            .accessibilityIdentifier("projectOSStep-\(step.id)")

            if !isLast {
                Divider()
                    .overlay(AgentPalette.border.opacity(0.30))
                    .padding(.leading, 43)
            }
        }
    }

    func projectOSStepTimeText(_ step: ProjectOSDisplayStep) -> String {
        if let completedAt = step.completedAt {
            return "Done \(eventTimeText(completedAt))"
        }
        if let startedAt = step.startedAt {
            return "\(step.status == .waiting ? "Waiting" : "Started") \(eventTimeText(startedAt))"
        }
        if let createdAt = step.createdAt {
            return "Queued \(eventTimeText(createdAt))"
        }
        return ""
    }

    func projectOSStepResultText(_ step: ProjectOSDisplayStep) -> String {
        let proof = step.proof.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proof.isEmpty { return "Proof: \(proof)" }
        let result = step.resultSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty { return "Result: \(result)" }
        return ""
    }

    var projectOSProofBlockerBand: some View {
        VStack(spacing: 8) {
            projectOSSignalRow(
                title: "Proof / Results",
                value: projectOSProofText,
                symbol: "checkmark.seal.fill",
                tint: trustTint,
                identifier: "proof-results"
            )
            projectOSSignalRow(
                title: projectOSBlockerTitle,
                value: projectOSBlockerText,
                symbol: projectOSBlockerSymbol,
                tint: projectOSBlockerTint,
                identifier: "blocker-waiting"
            )
            projectOSSignalRow(
                title: "Iteration",
                value: summary.workflowSpine.iterationPrompt,
                symbol: "arrow.triangle.2.circlepath",
                tint: AgentPalette.lilac,
                identifier: "iteration"
            )
        }
        .accessibilityIdentifier("projectOSProofBlockerBand")
    }

    func projectOSSignalRow(
        title: String,
        value: String,
        symbol: String,
        tint: Color,
        identifier: String
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
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
        .padding(10)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityIdentifier("projectOSSignal-\(identifier)")
    }

    var projectOSWorkspaceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            projectDetailScopePicker
            projectOSWorkspaceScopeContent
        }
        .padding(12)
        .agentGlass(radius: 22, interactive: false, tint: AgentPalette.cyan.opacity(0.07))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSWorkspaceSections")
    }

    @ViewBuilder
    var projectOSWorkspaceScopeContent: some View {
        switch selectedDetailScope {
        case .review:
            projectOSOverviewDetail
        case .plan:
            projectOSPlanDetail
        case .evidence:
            projectOSProofDetail
        case .timeline:
            projectOSActivityDetail
        }
    }

    var projectOSOverviewDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            projectOSMissionCard
            projectReviewDashboard
            if runtimeStatus.isVisible {
                projectRunStatusPanel
            }
        }
        .accessibilityIdentifier("projectOSOverviewSurface")
    }

    var projectOSPlanDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            projectOSPlanPreviewPanel
            missionOSPanel
            missionOSGateSection
            projectCommandCenter
        }
        .accessibilityIdentifier("projectOSPlanSurface")
    }

    var projectOSProofDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            latestEvidenceSection
            proofLedgerSection
            artifactsSection
            fileChangesSection
        }
        .accessibilityIdentifier("projectOSProofSurface")
    }

    var projectOSActivityDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            projectOSExecutionTimelinePanel
            projectOSRunHistoryPanel
            projectSignals
            timelineSection
        }
        .accessibilityIdentifier("projectOSActivitySurface")
    }

    var projectOSExecutionTimelinePanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Execution Timeline", systemImage: "timeline.selection")
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text(projectOSExecutionTimelineSubtitle)
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(projectOSTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            VStack(spacing: 0) {
                ForEach(Array(projectOSDisplaySteps.enumerated()), id: \.element.id) { index, step in
                    projectOSStepRow(step, isLast: index == projectOSDisplaySteps.count - 1)
                }
            }
            .background(AgentPalette.row.opacity(0.52), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(projectOSTint.opacity(0.14), lineWidth: 0.55)
            )
        }
        .padding(11)
        .background(AgentPalette.surfaceAlt.opacity(0.30), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSExecutionTimeline")
    }

    var projectOSExecutionTimelineSubtitle: String {
        if let run = activeProjectOSRun {
            let elapsed = projectOSRunElapsedText(run)
            return "\(run.status.displayName) · \(elapsed)"
        }
        return "Preview plan"
    }

    var projectOSMissionCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            NovaSectionMark(title: "Next Move", tint: commandTint(for: recommendedCommandIntent))
            projectOSSignalRow(
                title: "Next Recommended Action",
                value: projectOSNextStepText,
                symbol: "arrow.right.circle.fill",
                tint: commandTint(for: recommendedCommandIntent),
                identifier: "next-action"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSMissionPanel")
    }

    var projectOSRunHistoryPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Run History", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text("\(projectOSRuns.count)")
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.cyan)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(AgentPalette.cyan.opacity(0.10), in: Capsule(style: .continuous))
            }

            if projectOSRuns.isEmpty {
                emptyState(title: "No ProjectOS runs yet", detail: "Start a mission to create a durable run with plan, steps, proof, and history.", symbol: "target", tint: AgentPalette.cyan)
            } else {
                VStack(spacing: 6) {
                    ForEach(projectOSRuns.prefix(5), id: \.id) { run in
                        projectOSRunHistoryRow(run)
                    }
                }
            }
        }
        .padding(11)
        .background(AgentPalette.row.opacity(0.52), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectOSRunHistory")
    }

    func projectOSRunHistoryRow(_ run: ProjectOSRun) -> some View {
        let tint = projectOSTint(for: run.status)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: projectOSStatusSymbol(for: run.status))
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(run.status.displayName)
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                    Text(eventTimeText(run.updatedAt))
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                    Text(projectOSRunElapsedText(run))
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                Text(run.currentAction.isEmpty ? run.latestEventTitle : run.currentAction)
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.status.displayName). \(run.currentAction)")
    }

    func projectOSRunElapsedText(_ run: ProjectOSRun) -> String {
        let startedAt = run.startedAt ?? run.createdAt
        let end = run.completedAt ?? run.updatedAt
        let seconds = max(0, end.timeIntervalSince(startedAt))
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds) % 60
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }

    var projectOSStatus: ProjectOSRunStatus {
        if let activeProjectOSRun {
            return activeProjectOSRun.status
        }
        if runStartFeedback { return .planning }
        if runtimeStatus.tone == .working { return .running }
        if runtimeStatus.tone == .approval { return .waiting }
        if runtimeStatus.tone == .error { return .failed }
        if runtimeStatus.tone == .paused { return .stopped }
        if summary.statusKind == .blocked { return .blocked }
        if summary.statusKind == .waiting { return .waiting }
        if summary.statusKind == .done { return .completed }
        return .idle
    }
}

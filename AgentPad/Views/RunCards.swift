//
//  RunCards.swift
//  NovaForge
//
//  Run list cards and their supporting strips, gates, badges, and
//  the ToolRunStatus display extension.
//

import SwiftData
import SwiftUI

struct RunCard: View {
    let row: RunsView.RunRowData
    @Binding var expanded: Bool
    let hasLivePendingApproval: Bool
    let deleteRun: () -> Void
    let openArtifact: (WorkspaceArtifact) -> Void
    let openTerminalRecord: (UUID, String, String) -> Void
    let openProject: () -> Void
    let approvePendingTool: () -> Void
    let rejectPendingTool: () -> Void
    let dismissSearch: () -> Void
    let revealCard: (UnitPoint) -> Void
    var openReplay: (() -> Void)?
    @State private var showingArguments = false
    @State private var showingOutput = false
    @State private var confirmingDelete = false

    var statusColor: Color {
        switch row.status {
        case .completed: AgentPalette.green
        case .failed, .rejected: AgentPalette.rose
        case .pendingApproval: AgentPalette.cyan
        case .approved: AgentPalette.cyan
        }
    }

    private var runOutcomeTitle: String {
        row.phaseTitle
    }

    private var runOutcomeDetail: String {
        row.phaseDetail
    }

    private var runNextAction: String {
        row.nextActionDetail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                dismissSearch()
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                    expanded.toggle()
                    if !expanded {
                        showingArguments = false
                        showingOutput = false
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: row.isMutating ? "pencil.and.outline" : "eye")
                        .font(.subheadline)
                        .foregroundStyle(row.isMutating ? AgentPalette.cyan : AgentPalette.cyan)
                        .frame(width: 32, height: 32)
                        .agentControlSurface(radius: 10, tint: row.isMutating ? AgentPalette.cyan : AgentPalette.cyan, selected: true)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let argumentSummary = row.argumentSummary {
                            Text(argumentSummary)
                                .font(.caption2)
                                .foregroundStyle(AgentPalette.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        
                        HStack(spacing: 6) {
                            Text(row.createdTimeText)
                                .font(.caption2)
                                .foregroundStyle(AgentPalette.secondaryText)
                            
                            if let durationText = row.durationText {
                                Text("•")
                                    .font(.caption2)
                                    .foregroundStyle(AgentPalette.tertiaryText)
                                
                                Text(durationText)
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(AgentPalette.secondaryText)
                                
                                if row.isFast {
                                    Text("FAST")
                                        .font(.system(size: 6, weight: .bold))
                                        .foregroundStyle(AgentPalette.green)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .agentControlSurface(radius: 4, tint: AgentPalette.green, selected: true)
                                } else if row.isHeavy {
                                    Text("HEAVY")
                                        .font(.system(size: 6, weight: .bold))
                                        .foregroundStyle(AgentPalette.rose)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .agentControlSurface(radius: 4, tint: AgentPalette.rose, selected: true)
                                }
                            }
                        }

                        if row.terminalProof != nil {
                            Label("Terminal proof", systemImage: "terminal.fill")
                                .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.cyan)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .frame(height: 20)
                                .agentControlSurface(radius: 7, tint: AgentPalette.cyan.opacity(0.12), selected: true)
                                .accessibilityIdentifier("runTerminalProofBadge")
                        }
                    }
                    .layoutPriority(1)
                    
                    Spacer()
                    
                    HStack(spacing: 6) {
                        RunStatusBadge(status: row.status, tint: statusColor)

                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AgentPalette.tertiaryText)
                    }
                    .fixedSize()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(row.name), \(row.status.displayTitle)")
            .accessibilityIdentifier("runHistoryCard")

            RunCommandStrip(row: row, tint: statusColor)

            RunTimelineStrip(phases: row.timelinePhases, tint: statusColor)

            if row.status == .pendingApproval {
                RunApprovalGate(
                    isLive: hasLivePendingApproval,
                    detail: row.phaseDetail,
                    approve: approvePendingTool,
                    reject: rejectPendingTool,
                    openProject: openProject
                )
            }

            RunOutcomeBrief(
                title: runOutcomeTitle,
                detail: runOutcomeDetail,
                nextAction: runNextAction,
                tint: statusColor
            )

            RunNextActionBar(
                row: row,
                tint: statusColor,
                openProject: openProject,
                openArtifact: openArtifact,
                openTerminalRecord: openTerminalRecord
            )

            if !expanded, let proof = row.terminalProof {
                RunTerminalProofInline(
                    proof: proof,
                    openTerminalRecord: {
                        openTerminalRecord(proof.id, proof.command, proof.terminalFocusQuery)
                    }
                )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !expanded, let artifact = row.artifact {
                RunArtifactHandoffInline(artifact: artifact) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    openArtifact(artifact)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    if let openReplay, row.status == .completed || row.status == .failed || row.status == .rejected {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            openReplay()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "memories")
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(AgentPalette.cyan)
                                Text("Replay this run")
                                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                                    .foregroundStyle(AgentPalette.ink)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(AgentPalette.tertiaryText)
                            }
                            .padding(.horizontal, 11)
                            .frame(minHeight: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .agentControlSurface(radius: 13, tint: AgentPalette.cyan.opacity(0.10), selected: false)
                        .accessibilityIdentifier("runReplayButton")
                    }

                    if let proof = row.terminalProof {
                        RunTerminalProofCard(
                            proof: proof,
                            openTerminalRecord: {
                                openTerminalRecord(proof.id, proof.command, proof.terminalFocusQuery)
                            }
                        )
                    }

                    RunDetailToggle(
                        title: "Arguments",
                        subtitle: row.argumentsByteText,
                        isExpanded: showingArguments,
                        tint: AgentPalette.cyan,
                        copy: {
                            UIPasteboard.general.string = row.argumentsJSON
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        },
                        toggle: {
                            let willShowArguments = !showingArguments
                            withAnimation(.smooth(duration: 0.2)) {
                                showingArguments.toggle()
                            }
                            if willShowArguments {
                                revealCard(.top)
                            }
                        }
                    )

                    if showingArguments {
                        Text(row.argumentsPreview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AgentPalette.terminalBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if !row.output.isEmpty {
                        RunDetailToggle(
                            title: "Output",
                            subtitle: row.outputByteText,
                            isExpanded: showingOutput,
                            tint: statusColor,
                            copy: {
                                UIPasteboard.general.string = row.output
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            },
                            toggle: {
                                let willShowOutput = !showingOutput
                                withAnimation(.smooth(duration: 0.2)) {
                                    showingOutput.toggle()
                                }
                                if willShowOutput {
                                    revealCard(.top)
                                }
                            }
                        )
                        .padding(.top, 4)

                        if showingOutput {
                            RunOutputPreview(
                                text: row.outputPreview,
                                isTruncated: row.outputPreviewIsTruncated,
                                tint: statusColor
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))

                            if let artifact = row.artifact {
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    openArtifact(artifact)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: artifact.isWebPage ? "play.rectangle.fill" : artifact.symbol)
                                            .foregroundStyle(artifact.isWebPage ? AgentPalette.green : AgentPalette.cyan)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(artifact.isWebPage ? "Open live artifact" : "Open artifact")
                                                .font(.caption.weight(.bold))
                                            Text(artifact.path)
                                                .font(.caption2)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .foregroundStyle(AgentPalette.secondaryText)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.right")
                                            .font(.caption.weight(.bold))
                                    }
                                    .foregroundStyle(AgentPalette.ink)
                                    .padding(10)
                                    .agentRowSurface(radius: 14, tint: AgentPalette.cyan, selected: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button {
                        confirmingDelete = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Label("Delete log", systemImage: "trash")
                            .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.rose)
                            .frame(maxWidth: .infinity)
                            .frame(height: AgentDesign.minimumTouchTarget)
                            .agentControlSurface(radius: 12, tint: AgentPalette.rose.opacity(0.14), selected: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("runDeleteLogButton")
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(14)
        .agentRowSurface(radius: 20, tint: statusColor, selected: expanded)
        .contextMenu {
            Button(role: .destructive) {
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
                confirmingDelete = true
            } label: {
                Label("Delete Log", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete this run log?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Log", role: .destructive) {
                deleteRun()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes the audit entry. It does not delete workspace files.")
        }
    }

}

struct RunCommandStrip: View {
    let row: RunsView.RunRowData
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            RunCommandDatum(title: "Current", value: row.phaseTitle, symbol: row.status.symbol, tint: tint)
            RunCommandDatum(title: "Elapsed", value: row.elapsedText, symbol: "timer", tint: AgentPalette.lilac)
            RunCommandDatum(title: "Evidence", value: row.evidenceSummary, symbol: "checkmark.seal.fill", tint: AgentPalette.green)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runCommandStrip")
    }
}

struct RunCommandDatum: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
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
                    .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
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
}

struct RunTimelineStrip: View {
    let phases: [RunsView.RunTimelinePhase]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "timeline.selection")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(tint)
                Text("Timeline")
                    .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                Text("\(phases.count) phases")
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
            }

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(phases.enumerated()), id: \.element.id) { index, phase in
                    RunTimelinePhaseView(
                        phase: phase,
                        tint: timelineTint(for: phase.status),
                        isLast: index == phases.count - 1
                    )
                }
            }
        }
        .padding(10)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.12), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runTimelineStrip")
    }

    private func timelineTint(for status: RunsView.RunTimelinePhase.Status) -> Color {
        switch status {
        case .pending:
            return AgentPalette.tertiaryText
        case .current:
            return AgentPalette.cyan
        case .done:
            return AgentPalette.green
        case .failed:
            return AgentPalette.rose
        }
    }
}

struct RunTimelinePhaseView: View {
    let phase: RunsView.RunTimelinePhase
    let tint: Color
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 4) {
                Image(systemName: phase.symbol)
                    .font(.system(size: 8.5, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 21, height: 21)
                    .background(tint.opacity(0.10), in: Circle())
                if !isLast {
                    Rectangle()
                        .fill(tint.opacity(0.20))
                        .frame(width: 32, height: 2)
                        .clipShape(Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(phase.title)
                    .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text(phase.timestampText.isEmpty ? phase.detail : phase.timestampText)
                    .font(.system(size: 7.8, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(phase.title). \(phase.detail)")
    }
}

struct RunApprovalGate: View {
    let isLive: Bool
    let detail: String
    let approve: () -> Void
    let reject: () -> Void
    let openProject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(AgentPalette.cyan)
                    .frame(width: 28, height: 28)
                    .background(AgentPalette.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(isLive ? "Approval is live" : "Approval log retained")
                        .font(.system(size: 11.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                    Text(detail)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                if isLive {
                    approvalButton(title: "Approve", symbol: "checkmark", tint: AgentPalette.green, action: approve)
                    approvalButton(title: "Reject", symbol: "xmark", tint: AgentPalette.rose, action: reject)
                } else {
                    approvalButton(title: "Open ProjectOS", symbol: "scope", tint: AgentPalette.cyan, action: openProject)
                }
            }
        }
        .padding(10)
        .background(AgentPalette.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AgentPalette.cyan.opacity(0.18), lineWidth: 0.65)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runApprovalGate")
    }

    private func approvalButton(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AgentPalette.ink)
        .agentControlSurface(radius: 11, tint: tint.opacity(0.14), selected: true)
    }
}

struct RunNextActionBar: View {
    let row: RunsView.RunRowData
    let tint: Color
    let openProject: () -> Void
    let openArtifact: (WorkspaceArtifact) -> Void
    let openTerminalRecord: (UUID, String, String) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.nextActionTitle)
                    .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                Text(row.logSummary)
                    .font(.system(size: 8.8, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: primaryAction) {
                Label(primaryActionTitle, systemImage: primaryActionSymbol)
                    .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(minWidth: 92, minHeight: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AgentPalette.ink)
            .agentControlSurface(radius: 11, tint: tint.opacity(0.14), selected: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AgentPalette.surfaceAlt.opacity(0.26), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.nextActionTitle). \(row.nextActionDetail)")
        .accessibilityIdentifier("runNextActionBar")
    }

    private var primaryActionTitle: String {
        if row.artifact != nil { return "Open" }
        if row.terminalProof?.canOpenTerminalRecord == true { return "Terminal" }
        if row.status == .failed || row.status == .rejected || row.status == .pendingApproval { return "ProjectOS" }
        return "ProjectOS"
    }

    private var primaryActionSymbol: String {
        if row.artifact != nil { return "arrow.up.right.square.fill" }
        if row.terminalProof?.canOpenTerminalRecord == true { return "terminal.fill" }
        if row.status == .failed || row.status == .rejected { return "wrench.and.screwdriver.fill" }
        if row.status == .pendingApproval { return "checkmark.shield.fill" }
        return "scope"
    }

    private func primaryAction() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let artifact = row.artifact {
            openArtifact(artifact)
        } else if let proof = row.terminalProof, proof.canOpenTerminalRecord {
            openTerminalRecord(proof.id, proof.command, proof.terminalFocusQuery)
        } else {
            openProject()
        }
    }
}

struct RunOutcomeBrief: View {
    let title: String
    let detail: String
    let nextAction: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 9.5, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(AgentPalette.cyan)
                    .frame(width: 20, height: 20)
                Text(nextAction)
                    .font(.system(size: 9.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.12), lineWidth: 0.55)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail). Next: \(nextAction)")
        .accessibilityIdentifier("runOutcomeBrief")
    }
}

struct RunArtifactHandoffInline: View {
    let artifact: WorkspaceArtifact
    let open: () -> Void

    private var tint: Color {
        artifact.isWebPage || artifact.isSwiftGameArtifact ? AgentPalette.green : AgentPalette.cyan
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: artifact.isWebPage || artifact.isSwiftGameArtifact ? artifact.handoffSymbol : artifact.symbol)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .agentControlSurface(radius: 10, tint: tint.opacity(0.14), selected: true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.isWebPage || artifact.isSwiftGameArtifact ? "Playable artifact ready" : "Artifact output ready")
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(artifact.path)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right.square.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(tint)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .agentRowSurface(radius: 12, tint: tint.opacity(0.05), selected: true)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open artifact \(artifact.path)")
        .accessibilityIdentifier("runArtifactHandoffInline")
    }
}

struct RunTerminalProofInline: View {
    let proof: RunsView.TerminalProofData
    let openTerminalRecord: () -> Void
    private let tint = AgentPalette.cyan

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .agentControlSurface(radius: 9, tint: tint.opacity(0.14), selected: true)

            VStack(alignment: .leading, spacing: 5) {
                Text("$ \(proof.command)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("runTerminalProofCommand")

                if !proof.outputPreview.isEmpty {
                    Text(proof.outputPreview)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("runTerminalProofOutput")
                }

                HStack(spacing: 6) {
                    RunTerminalProofPill(text: proof.statusText, symbol: "checkmark.seal.fill", tint: tint)
                    RunTerminalProofPill(text: proof.outputLineCountText, symbol: "text.alignleft", tint: tint)
                    RunTerminalProofPill(text: proof.outputByteText, symbol: "doc.text", tint: tint)
                }
            }
            .layoutPriority(1)

            VStack(spacing: 6) {
                if proof.canOpenTerminalRecord {
                    Button {
                        openTerminalRecord()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: "arrow.up.right.square.fill")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tint)
                    .accessibilityLabel("Open linked terminal record")
                    .accessibilityIdentifier("runOpenTerminalRecord")
                }

                Button {
                    UIPasteboard.general.string = proof.command
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tint)
                .accessibilityLabel("Copy terminal command")
                .accessibilityIdentifier("runCopyTerminalCommand")

                Button {
                    UIPasteboard.general.string = proof.output
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tint)
                .accessibilityLabel("Copy terminal output")
                .accessibilityIdentifier("runCopyTerminalOutput")
            }
        }
        .padding(10)
        .agentRowSurface(radius: 12, tint: tint.opacity(0.05))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runTerminalProofInline")
    }
}

struct RunTerminalProofCard: View {
    let proof: RunsView.TerminalProofData
    let openTerminalRecord: () -> Void

    private var tint: Color {
        proof.status == .completed ? AgentPalette.cyan : AgentPalette.rose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Terminal proof", systemImage: "terminal.fill")
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(tint)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(proof.statusText)
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .agentControlSurface(radius: 8, tint: tint.opacity(0.14), selected: true)
            }

            Text("$ \(proof.command)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(2)
                .textSelection(.enabled)
                .accessibilityIdentifier("runTerminalProofCommand")

            Text(proof.outputPreview.isEmpty ? "[no output]" : proof.outputPreview)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(AgentPalette.terminalText.opacity(0.90))
                .lineLimit(8)
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AgentPalette.terminalBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityIdentifier("runTerminalProofOutput")

            HStack(spacing: 6) {
                RunTerminalProofPill(text: proof.sourceText, symbol: "link", tint: tint)
                RunTerminalProofPill(text: proof.outputLineCountText, symbol: "text.alignleft", tint: tint)
                RunTerminalProofPill(text: proof.outputByteText, symbol: "doc.text", tint: tint)
                RunTerminalProofPill(text: proof.durationText, symbol: "timer", tint: tint)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if proof.canOpenTerminalRecord {
                    Button {
                        openTerminalRecord()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Label("Open Terminal", systemImage: "terminal")
                            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .frame(maxWidth: .infinity)
                            .frame(height: AgentDesign.minimumTouchTarget)
                            .agentControlSurface(radius: 10, tint: AgentPalette.green.opacity(0.16), selected: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("runOpenTerminalRecord")
                }

                Button {
                    UIPasteboard.general.string = proof.command
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label("Copy Command", systemImage: "doc.on.doc")
                        .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity)
                        .frame(height: AgentDesign.minimumTouchTarget)
                        .agentControlSurface(radius: 10, tint: AgentPalette.cyan.opacity(0.16), selected: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("runCopyTerminalCommand")

                Button {
                    UIPasteboard.general.string = proof.output
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label("Copy Proof Output", systemImage: "terminal")
                        .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity)
                        .frame(height: AgentDesign.minimumTouchTarget)
                        .agentControlSurface(radius: 10, tint: AgentPalette.lilac.opacity(0.16), selected: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("runCopyTerminalOutput")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.20), lineWidth: 0.9)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runTerminalProofCard")
    }
}

struct RunTerminalProofPill: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
            .foregroundStyle(AgentPalette.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .agentControlSurface(radius: 8, tint: tint.opacity(0.10), selected: true)
    }
}

struct RunDetailToggle: View {
    let title: String
    let subtitle: String
    let isExpanded: Bool
    let tint: Color
    let copy: () -> Void
    let toggle: () -> Void
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(title)
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .frame(height: AgentDesign.minimumTouchTarget)
                .frame(maxWidth: .infinity, alignment: .leading)
                .agentControlSurface(radius: 10, tint: tint.opacity(0.14), selected: isExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("runToggle\(title)")

            Button {
                copy()
                copied = true
                resetTask?.cancel()
                resetTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.4))
                    guard !Task.isCancelled else { return }
                    copied = false
                    resetTask = nil
                }
            } label: {
                Label(copied ? "Copied" : (title == "Arguments" ? "Copy Args" : "Copy Output"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .foregroundStyle(AgentPalette.ink)
                    .padding(.horizontal, 10)
                    .frame(height: AgentDesign.minimumTouchTarget)
                    .agentControlSurface(radius: 10, tint: AgentPalette.cyan.opacity(0.18), selected: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "\(title) copied" : "Copy \(title)")
            .accessibilityIdentifier("runCopy\(title)")
        }
        .padding(.vertical, 2)
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }
}

struct RunOutputPreview: View {
    let text: String
    let isTruncated: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isTruncated {
                Label("Preview capped for smooth scrolling — Copy Output keeps the full log.", systemImage: "scissors")
                    .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.terminalOutput.opacity(0.78))
                    .lineLimit(2)
            }

            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(AgentPalette.terminalText.opacity(0.90))
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentPalette.terminalBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 0.9)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runOutputPreview")
    }
}

struct RunFocusMetric: View {
    let value: String
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .monospacedDigit()
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .agentRowSurface(radius: 13, tint: tint.opacity(0.06))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

struct AuditMetric: View {
    let value: String
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .heavy))
                Text(label)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .textCase(.uppercase)
            }
            .foregroundStyle(AgentPalette.tertiaryText)
            Text(value)
                .font(.system(size: 14, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .agentRowSurface(radius: 13, tint: tint.opacity(0.07))
    }
}

struct RunStatusBadge: View {
    let status: ToolRunStatus
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol)
                .font(.system(size: 9, weight: .bold))
            Text(status.displayTitle)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.28), lineWidth: 0.8)
        )
    }
}

extension ToolRunStatus {
    var displayTitle: String {
        switch self {
        case .pendingApproval: "Needs approval"
        case .approved: "Running approved"
        case .completed: "Done"
        case .failed: "Failed"
        case .rejected: "Rejected"
        }
    }

    var symbol: String {
        switch self {
        case .pendingApproval: "shield.lefthalf.filled"
        case .approved: "checkmark.shield.fill"
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .rejected: "xmark"
        }
    }
}

enum RunArgumentSummary {
    private static let priorityKeys = ["path", "command", "query", "url", "file", "filename", "name"]
    private static let maximumJSONCharacters = 2_000
    private static let maximumSummaryCharacters = 96

    static func make(from json: String) -> String? {
        let cleaned = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let bounded = String(cleaned.prefix(maximumJSONCharacters))
        guard let data = bounded.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return shorten(cleaned)
        }

        for key in priorityKeys {
            if let value = object[key],
               let formatted = format(key: key, value: value) {
                return formatted
            }
        }

        for key in object.keys.sorted() {
            if let value = object[key],
               let formatted = format(key: key, value: value) {
                return formatted
            }
        }

        return nil
    }

    private static func format(key: String, value: Any) -> String? {
        if let string = value as? String {
            let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            return "\(key): \(shorten(cleaned))"
        }

        if let number = value as? NSNumber {
            return "\(key): \(number)"
        }

        if let values = value as? [Any] {
            return "\(key): \(values.count) items"
        }

        if let fields = value as? [String: Any] {
            return "\(key): \(fields.count) fields"
        }

        return nil
    }

    private static func shorten(_ text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard singleLine.count > maximumSummaryCharacters else { return singleLine }
        return String(singleLine.prefix(maximumSummaryCharacters)) + "..."
    }
}

struct RunSparkline: View {
    let durations: [Double]
    
    var body: some View {
        let maxDuration = durations.max() ?? 1.0
        let normalized = durations.map { maxDuration > 0 ? CGFloat($0 / maxDuration) : 0.0 }
        
        return GeometryReader { geo in
            Path { path in
                guard normalized.count > 1 else { return }
                let dx = geo.size.width / CGFloat(normalized.count - 1)
                
                for (idx, val) in normalized.enumerated() {
                    let x = CGFloat(idx) * dx
                    let y = geo.size.height * (1.0 - val * 0.8)
                    if idx == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(
                LinearGradient(colors: [AgentPalette.primaryAccent, AgentPalette.secondaryAccent], startPoint: .leading, endPoint: .trailing),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            )
            .shadow(color: AgentPalette.primaryAccent.opacity(0.3), radius: 3)
        }
        .frame(height: 30)
    }
}

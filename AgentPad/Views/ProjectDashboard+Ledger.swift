//
//  ProjectDashboard+Ledger.swift
//  NovaForge
//
//  Evidence ledger: execution loop, signals, artifacts, proof sheets,
//  timeline rows.
//

import SwiftData
import SwiftUI

extension ProjectDashboardView {


    func signalCard(_ metric: ProjectMetricCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: metric.symbol)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(metric.tint)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(metric.tint.opacity(0.12))
                    )
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(metric.value)
                    .font(.system(size: 25, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(metric.label)
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                Text(metric.detail)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .agentSurface(radius: 18, tint: metric.tint.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.label): \(metric.value). \(metric.detail)")
        .accessibilityIdentifier("projectMetric-\(metric.id)")
    }

    @ViewBuilder
    var artifactsSection: some View {
        sectionShell(
            title: "Project Artifacts",
            subtitle: artifactSectionSubtitle,
            symbol: "shippingbox.fill",
            tint: AgentPalette.green
        ) {
            let visibleArtifacts = Array(projectArtifacts.prefix(5))
            if visibleArtifacts.isEmpty {
                emptyState(title: "No artifacts yet", detail: "Generated files and previews will land here.", symbol: "shippingbox", tint: AgentPalette.green)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    artifactFeatureCard(visibleArtifacts[0])

                    if visibleArtifacts.count > 1 {
                        VStack(spacing: 0) {
                            ForEach(Array(visibleArtifacts.dropFirst().enumerated()), id: \.element.id) { index, artifact in
                                Button {
                                    openProjectArtifact(artifact)
                                } label: {
                                    artifactRow(artifact)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("projectArtifact-\(artifact.path)")

                                if index < visibleArtifacts.dropFirst().count - 1 {
                                    Divider()
                                        .overlay(AgentPalette.border.opacity(0.42))
                                        .padding(.leading, 44)
                                }
                            }
                        }
                    }

                    if projectArtifacts.count > visibleArtifacts.count {
                        Button {
                            openTab(.files)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 10, weight: .black))
                                Text("\(projectArtifacts.count - visibleArtifacts.count) more in Files")
                                    .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .black))
                            }
                            .foregroundStyle(AgentPalette.green)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 36)
                            .background(AgentPalette.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("projectArtifactOverflowButton")
                    }
                }
            }
        }
    }

    var timelineSection: some View {
        sectionShell(
            title: "Project Timeline",
            subtitle: summary.timelineItems.isEmpty ? "No timeline events yet" : "\(summary.timelineItems.count) event\(summary.timelineItems.count == 1 ? "" : "s")",
            symbol: "timeline.selection",
            tint: AgentPalette.indigo
        ) {
            let visibleEvents = Array(summary.timelineItems.prefix(12))
            if visibleEvents.isEmpty {
                emptyState(title: "Waiting", detail: "No project events recorded yet.", symbol: "circle.dashed", tint: AgentPalette.secondaryText)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleEvents.enumerated()), id: \.element.id) { index, item in
                        timelineRow(item)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(item.title). \(item.detail)")
                            .accessibilityIdentifier("projectTimelineRow-\(index)")

                        if index < visibleEvents.count - 1 {
                            Divider()
                                .overlay(AgentPalette.border.opacity(0.36))
                                .padding(.leading, 42)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectTimelineSection")
    }

    var proofLedgerSection: some View {
        sectionShell(
            title: "Proof Ledger",
            subtitle: summary.proofItems.isEmpty ? "No proof captured yet" : "\(summary.proofItems.count) proof item\(summary.proofItems.count == 1 ? "" : "s")",
            symbol: "checkmark.seal.fill",
            tint: AgentPalette.green
        ) {
            let visibleProof = Array(summary.proofItems.prefix(6))
            if visibleProof.isEmpty {
                emptyState(title: "No proof captured yet", detail: "Screenshots, artifacts, completed runs, and file evidence will appear here.", symbol: "checkmark.seal", tint: AgentPalette.green)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleProof.enumerated()), id: \.element.id) { index, item in
                        Button {
                            openProofItem(item)
                        } label: {
                            proofLedgerRow(item)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(item.title). \(item.detail)")
                        .accessibilityIdentifier("projectProofLedgerRow-\(index)")

                        if index < visibleProof.count - 1 {
                            Divider()
                                .overlay(AgentPalette.border.opacity(0.36))
                                .padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectProofLedgerSection")
    }

    var fileChangesSection: some View {
        sectionShell(
            title: "Changes",
            subtitle: fileChangesSectionSubtitle,
            symbol: "doc.badge.gearshape.fill",
            tint: AgentPalette.cyan
        ) {
            let visibleChanges = Array(projectFileChanges.prefix(4))
            if visibleChanges.isEmpty {
                emptyState(title: "No file changes yet", detail: "Workspace edits will appear here as project-owned records.", symbol: "doc.badge.plus", tint: AgentPalette.cyan)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleChanges.enumerated()), id: \.element.id) { index, change in
                        fileChangeRow(change)

                        if index < visibleChanges.count - 1 {
                            Divider()
                                .overlay(AgentPalette.border.opacity(0.36))
                                .padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    func openProjectArtifact(_ artifact: ProjectArtifact) {
        let workspaceArtifact = WorkspaceArtifact(path: artifact.path)
        ProjectEventRecorder.noteArtifactPreview(
            workspaceArtifact,
            project: project,
            context: modelContext
        )
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            dashboardSaveError = "NovaForge opened the artifact, but could not save the preview event. \(error.localizedDescription)"
        }
        if workspaceArtifact.isWebPage || workspaceArtifact.isSwiftGameArtifact {
            openArtifactLandscapeFullScreen(workspaceArtifact)
        } else {
            openTab(.files)
        }
    }

    func openProofItem(_ item: ProjectProofItem) {
        guard let path = item.sourcePath, !path.isEmpty else {
            selectedProofItem = item
            return
        }
        if let artifact = projectArtifacts.first(where: { $0.path == path }) {
            openProjectArtifact(artifact)
            return
        }
        selectedProofItem = item
    }

    func proofLedgerRow(_ item: ProjectProofItem) -> some View {
        let tint = proofTint(for: item)
        return HStack(spacing: 11) {
            Image(systemName: item.symbolName)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Text(eventTimeText(item.createdAt))
                .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.tertiaryText)
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    func proofDetailSheet(_ item: ProjectProofItem) -> some View {
        let tint = proofTint(for: item)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Proof Detail")
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                    Text(item.title)
                        .font(.system(size: 18, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            Text(item.detail)
                .font(.system(size: 13, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let path = item.sourcePath, !path.isEmpty {
                Text(path)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(4)
                    .truncationMode(.middle)
            }

            Button("Open Files") {
                selectedProofItem = nil
                openTab(.files)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .accessibilityIdentifier("projectProofDetailOpenFiles")
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectProofDetailSheet")
    }

    func artifactFeatureCard(_ artifact: ProjectArtifact) -> some View {
        let type = artifact.type
        let isPlayable = type == .html || type == .swiftGame
        let tint = isPlayable ? AgentPalette.green : AgentPalette.cyan
        let title = artifact.title.isEmpty ? URL(fileURLWithPath: artifact.path).lastPathComponent : artifact.title

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: type.symbolName)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(type == .swiftGame ? "Playable Game" : "Latest Output")
                            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                        Text(eventTimeText(artifact.updatedAt))
                            .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.tertiaryText)
                    }

                    Text(title)
                        .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    Text(artifact.path)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 9) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    openProjectArtifact(artifact)
                } label: {
                    Label(isPlayable ? "Preview" : "Open", systemImage: isPlayable ? "arrow.up.right" : "folder.fill")
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AgentPalette.ink)
                .agentControlSurface(radius: 13, tint: tint.opacity(0.12), selected: true)
                .accessibilityIdentifier("projectFeaturedArtifactOpen")

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    draftProjectCommand(project, .improveArtifact, "Focus on \(artifact.path).")
                } label: {
                    Label("Improve", systemImage: "wand.and.sparkles")
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AgentPalette.ink)
                .agentControlSurface(radius: 13, tint: AgentPalette.green.opacity(0.10), selected: false)
                .accessibilityIdentifier("projectFeaturedArtifactImprove")
            }
        }
        .padding(12)
        .background(AgentPalette.row.opacity(0.70), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 0.65)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectFeaturedArtifact")
    }

    func artifactRow(_ artifact: ProjectArtifact) -> some View {
        let type = artifact.type
        let isPlayable = type == .html || type == .swiftGame
        let tint = isPlayable ? AgentPalette.green : AgentPalette.cyan
        return HStack(spacing: 11) {
            Image(systemName: type.symbolName)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.11))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.title.isEmpty ? URL(fileURLWithPath: artifact.path).lastPathComponent : artifact.title)
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(artifact.path)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Image(systemName: isPlayable ? "arrow.up.right" : "folder.fill")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(AgentPalette.secondaryText)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    func fileChangeRow(_ change: ProjectFileChange) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AgentPalette.cyan.opacity(0.11))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(change.action)
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                Text(change.path)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Text(eventTimeText(change.createdAt))
                .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.tertiaryText)
                .lineLimit(1)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    func sectionShell<Content: View>(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        usesGlass: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shell = VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text(subtitle)
                    .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }

            content()
        }
        .padding(14)

        if usesGlass {
            shell
                .agentGlass(radius: 22, interactive: false, tint: tint.opacity(0.12))
        } else {
            shell
                .agentSurface(radius: 20, tint: tint.opacity(0.06))
        }
    }

    func emptyState(title: String, detail: String, symbol: String, tint: Color) -> some View {
        AgentInlineStateView(title: title, detail: detail, symbol: symbol, tint: tint)
    }

    func timelineRow(_ item: ProjectTimelineItem) -> some View {
        let tint = tint(for: item.severity)

        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                Image(systemName: symbol(for: item.severity))
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(tint.opacity(0.12))
                    )
                Rectangle()
                    .fill(tint.opacity(0.22))
                    .frame(width: 2, height: 28)
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.kindTitle)
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(eventTimeText(item.createdAt))
                        .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(1)
                }

                Text(item.title)
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                if !item.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(item.detail)
                        .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 10)
    }

    func eventKindTitle(_ kind: ProjectEventKind) -> String {
        kind.rawValue
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }

    func eventTimeText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none)
    }

    func runStatusText(_ status: ToolRunStatus) -> String {
        switch status {
        case .pendingApproval: "Waiting approval"
        case .approved: "Approved"
        case .rejected: "Rejected"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    var statusTint: Color {
        switch summary.statusKind {
        case .active, .done: AgentPalette.green
        case .waiting: AgentPalette.lilac
        case .blocked: AgentPalette.rose
        }
    }

    var statusSymbol: String {
        switch summary.statusKind {
        case .active: "checkmark.seal.fill"
        case .waiting: "hourglass"
        case .blocked: "hand.raised.fill"
        case .done: "flag.checkered"
        }
    }

    func tint(for severity: ProjectEventSeverity) -> Color {
        switch severity {
        case .info: AgentPalette.cyan
        case .running: AgentPalette.lilac
        case .success: AgentPalette.green
        case .warning: AgentPalette.indigo
        case .failure: AgentPalette.rose
        }
    }

    func proofTint(for item: ProjectProofItem) -> Color {
        switch item.severity {
        case .failure:
            AgentPalette.rose
        case .warning:
            AgentPalette.indigo
        case .running:
            AgentPalette.lilac
        case .info:
            AgentPalette.cyan
        case .success:
            AgentPalette.green
        }
    }

    func symbol(for severity: ProjectEventSeverity) -> String {
        switch severity {
        case .info: "info.circle.fill"
        case .running: "waveform"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }
}

//
//  ChatProgressDrawer.swift
//  NovaForge
//
//  Run progress drawer: context bar, trace rows, inline approval, proof cards.
//

import SwiftData
import SwiftUI
import UIKit

struct ChatContextBar: View {
    let runtime: AgentRuntime
    let settings: AgentSettings
    let artifacts: [WorkspaceArtifact]
    let durableSnapshot: ChatDurableRunSnapshot
    let workflowSpine: ProjectWorkflowSpine?
    let openArtifact: (WorkspaceArtifact) -> Void
    let retry: () -> Void
    let continueRun: () -> Void
    let stop: () -> Void
    let openWorkspaceSurface: (AppTab) -> Void
    let clear: () -> Void
    @Binding var expanded: Bool

    private var primaryArtifact: WorkspaceArtifact? { artifacts.first }
    private var hasCompletedRunEvidence: Bool {
        runtime.lastRunDuration != nil ||
            runtime.runState == .completed ||
            runtime.hasSuccessfulTraceEvent ||
            primaryArtifact != nil ||
            durableSnapshot.hasCompletionEvidence
    }

    private var visibleTraceEvents: [AgentTraceEvent] {
        ChatDurableRunSnapshot.mergedTraceEvents(
            runtime: runtime.traceEvents,
            durable: durableSnapshot.traceEvents
        )
    }

    private var lastRunDuration: TimeInterval? {
        runtime.lastRunDuration ?? durableSnapshot.lastRunDuration
    }

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Context Bar Body")
        VStack(spacing: 10) {
            Button {
                toggleExpanded()
            } label: {
                HStack(spacing: 10) {
                    contextIcon

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(NovaType.headline)
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(NovaType.caption)
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    statusPill

                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(tint.opacity(0.10)))
                        .overlay(Circle().strokeBorder(tint.opacity(0.26), lineWidth: 0.9))
                        .contentShape(Circle())
                }
                .padding(.leading, 2)
                .frame(minHeight: AgentDesign.minimumTouchTarget)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide progress details" : "Show progress details")
            .accessibilityIdentifier("runProgressToggle")

            if expanded {
                ScrollView(.vertical, showsIndicators: false) {
                    AgentProgressDrawer(
                        runtime: runtime,
                        tint: tint,
                        artifacts: artifacts,
                        durableSnapshot: durableSnapshot,
                        workflowSpine: workflowSpine,
                        openArtifact: openArtifact,
                        retry: retry,
                        continueRun: continueRun,
                        stop: stop,
                        openWorkspaceSurface: openWorkspaceSurface,
                        clear: clear
                    )
                    .padding(.bottom, 2)
                }
                .frame(maxHeight: 430)
                .scrollBounceBehavior(.basedOnSize)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .runContextSurface(usesPolishedSurface: AgentPerformance.prefersReducedVisualEffects && runtime.isWorking && !expanded, tint: tint)
    }

    @ViewBuilder
    private var contextIcon: some View {
        if runtime.isWorking {
            ProgressStatusIcon(tint: tint)
        } else {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .agentControlSurface(radius: 12, tint: tint.opacity(0.14), selected: true)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 5.5, height: 5.5)
                .shadow(
                    color: runtime.isWorking && !AgentPerformance.prefersReducedVisualEffects ? tint.opacity(0.85) : .clear,
                    radius: 4
                )
            Text(statusPillText)
                .novaLabel(tint)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.11)))
        .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.28), lineWidth: 0.8))
    }

    private var title: String {
        if runtime.lastError != nil { return "Run failed" }
        if runtime.wasInterrupted { return "Run paused" }
        if let pending = runtime.pendingTool { return "Approval needed: \(plainToolName(pending.name))" }
        if runtime.queuedPromptCount > 0 { return "\(runtime.queuedPromptCount) follow-up queued" }
        if runtime.isWorking { return runtime.activityTitle }
        if hasCompletedRunEvidence { return "Run complete" }
        if primaryArtifact != nil { return "Latest artifact" }
        return "Ready"
    }

    private var subtitle: String {
        if runtime.lastError != nil { return "Retry or clear from the menu" }
        if runtime.wasInterrupted { return "Continue, retry, or inspect what changed" }
        if runtime.pendingTool != nil { return "Approve or reject before sending the next message." }
        if runtime.isWorking { return runtime.activityDetail }
        if hasCompletedRunEvidence || !visibleTraceEvents.isEmpty {
            if let workflowSpine {
                return "\(workflowSpine.nextActionTitle): \(workflowSpine.nextActionDetail)"
            }
            return completionSummary
        }
        if let artifact = primaryArtifact { return artifact.path }
        return "\(settings.provider.displayName) · \(settings.modelID)"
    }

    private var icon: String {
        if runtime.lastError != nil { return "exclamationmark.triangle.fill" }
        if runtime.wasInterrupted { return "pause.circle.fill" }
        if runtime.pendingTool != nil { return "checkmark.shield.fill" }
        if hasCompletedRunEvidence { return "checkmark.circle.fill" }
        if !artifacts.isEmpty { return "paperclip" }
        return "sparkles"
    }

    private var statusPillText: String {
        if runtime.lastError != nil { return "Failed" }
        if runtime.wasInterrupted { return "Paused" }
        if runtime.pendingTool != nil { return "Approve" }
        if runtime.isWorking { return "Live" }
        if hasCompletedRunEvidence { return "Done" }
        if !artifacts.isEmpty { return "New" }
        return "Ready"
    }

    private var tint: Color {
        if runtime.lastError != nil { return AgentPalette.rose }
        if runtime.wasInterrupted { return AgentPalette.cyan }
        if runtime.pendingTool != nil { return AgentPalette.cyan }
        if runtime.isWorking { return AgentPalette.primaryAccent }
        if hasCompletedRunEvidence { return AgentPalette.green }
        return AgentPalette.cyan
    }

    private var completionSummary: String {
        let stepCount = visibleTraceEvents.count
        let stepText = "\(stepCount) visible step\(stepCount == 1 ? "" : "s")"
        let artifactPrefix = primaryArtifact.map { "\($0.title) ready · " } ?? ""
        if let duration = lastRunDuration {
            return "\(artifactPrefix)\(stepText) · \(formatDuration(duration))"
        }
        return "\(artifactPrefix)\(stepText)"
    }

    private func toggleExpanded() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.smooth(duration: 0.22)) {
            expanded.toggle()
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        duration < 1 ? String(format: "%.0fms", duration * 1000) : String(format: "%.1fs", duration)
    }
}

struct AgentProgressDrawer: View {
    let runtime: AgentRuntime
    let tint: Color
    let artifacts: [WorkspaceArtifact]
    let durableSnapshot: ChatDurableRunSnapshot
    let workflowSpine: ProjectWorkflowSpine?
    let openArtifact: (WorkspaceArtifact) -> Void
    let retry: () -> Void
    let continueRun: () -> Void
    let stop: () -> Void
    let openWorkspaceSurface: (AppTab) -> Void
    let clear: () -> Void

    private var visibleTraceEvents: [AgentTraceEvent] {
        ChatDurableRunSnapshot.mergedTraceEvents(
            runtime: runtime.traceEvents,
            durable: durableSnapshot.traceEvents
        )
    }

    private var secondaryArtifacts: [WorkspaceArtifact] {
        Array(artifacts.dropFirst())
    }


    private var issueCount: Int {
        visibleTraceEvents.filter { $0.status == .failed || $0.status == .paused }.count
    }

    private var runDurationText: String {
        guard let duration = runtime.lastRunDuration ?? durableSnapshot.lastRunDuration else {
            if runtime.isWorking { return "Live" }
            if runtime.lastError != nil { return "Failed" }
            if runtime.pendingTool != nil { return "Pending" }
            if runtime.wasInterrupted { return "Paused" }
            if runtime.runState == .completed ||
                visibleTraceEvents.contains(where: { $0.status == .success }) ||
                durableSnapshot.hasCompletionEvidence {
                return "Done"
            }
            return "Ready"
        }
        return duration < 1 ? String(format: "%.0fms", duration * 1000) : String(format: "%.1fs", duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            runHeader

            if let pending = runtime.pendingTool {
                runSection(title: "Approval Queue", symbol: "checkmark.shield.fill", tint: AgentPalette.cyan) {
                    PendingApprovalInlineCard(request: pending)
                }
            }

            if runtime.activeToolName != nil {
                activeToolPanel
            }

            if !artifacts.isEmpty {
                runSection(title: artifacts[0].handoffTitle, symbol: artifacts[0].handoffSymbol, tint: AgentPalette.green) {
                    ArtifactHandoffCard(artifact: artifacts[0], openArtifact: openArtifact)
                }

                if !secondaryArtifacts.isEmpty {
                    runSection(title: "Also changed", symbol: "paperclip", tint: AgentPalette.cyan) {
                        artifactStrip(secondaryArtifacts)
                    }
                }
            }

            if !durableSnapshot.fileChanges.isEmpty {
                runSection(title: "Changed Files", symbol: "doc.text.fill", tint: AgentPalette.indigo) {
                    fileChangeStrip(durableSnapshot.fileChanges)
                }
            }

            if durableSnapshot.latestProof != nil || durableSnapshot.latestTerminalProof != nil || !durableSnapshot.reviewHeadline.isEmpty {
                runSection(title: "Proof", symbol: "checkmark.seal.fill", tint: AgentPalette.lilac) {
                    ProofContextCard(
                        durableSnapshot: durableSnapshot,
                        openArtifact: openArtifact,
                        openRuns: {
                            openWorkspaceSurface(.runs)
                        }
                    )
                }
            }

            if !visibleTraceEvents.isEmpty {
                runSection(title: "Progress", symbol: "timeline.selection", tint: tint) {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleTraceEvents.enumerated()), id: \.element.id) { index, event in
                            AgentTraceRow(
                                event: event,
                                isFirst: index == 0,
                                isLast: index == visibleTraceEvents.count - 1
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    .agentRowSurface(radius: 14, tint: tint.opacity(0.05))
                }
            }

            HStack(alignment: .top, spacing: 10) {
                runSection(title: "Workspace", symbol: "square.grid.2x2.fill", tint: AgentPalette.indigo) {
                    workspaceShortcuts
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                runSection(title: "Next", symbol: "arrow.triangle.branch", tint: AgentPalette.blue) {
                    nextActions
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runControlDrawer")
    }

    private var runHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Run Control")
                    .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text(runtime.isWorking ? "IN PROGRESS" : issueCount > 0 ? "NEEDS REVIEW" : "FINISHED")
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(issueCount > 0 ? AgentPalette.rose : tint)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .agentControlSurface(radius: 8, tint: (issueCount > 0 ? AgentPalette.rose : tint).opacity(0.12), selected: true)
            }

            HStack(spacing: 8) {
                RunMetric(value: "\(visibleTraceEvents.count)", label: "Steps", symbol: "checklist", tint: tint, valueIdentifier: "runStepsMetric")
                RunMetric(value: "\(artifacts.count)", label: "Files", symbol: "paperclip", tint: AgentPalette.cyan, valueIdentifier: "runFilesMetric")
                RunMetric(value: runDurationText, label: "Time", symbol: "timer", tint: AgentPalette.lilac, valueIdentifier: "runTimeMetric")
            }
        }
        .padding(11)
        .background(
            LinearGradient(
                colors: [AgentPalette.surface, tint.opacity(0.10), AgentPalette.lilac.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .agentSurface(radius: 16, tint: tint.opacity(0.08))
    }

    @ViewBuilder
    private func runSection<Content: View>(
        title: String,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ProgressDrawerLabel(text: title, symbol: symbol, tint: tint)
            content()
        }
    }

    private var activeToolPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(AgentPalette.cyan.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(AgentPalette.cyan)
            }

            VStack(alignment: .leading, spacing: 4) {
                ProgressDrawerLabel(text: "Running Tool", symbol: "wrench.and.screwdriver.fill", tint: AgentPalette.cyan)
                Text(runtime.activeToolName ?? "Tool")
                    .font(.system(size: 13, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                if !runtime.activeToolDetail.isEmpty {
                    Text(runtime.activeToolDetail)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)

            Text("live")
                .font(.system(size: 9, weight: .heavy, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.cyan)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .agentControlSurface(radius: 8, tint: AgentPalette.cyan.opacity(0.12), selected: true)
        }
        .padding(11)
        .background(
            LinearGradient(
                colors: [AgentPalette.surface, AgentPalette.cyan.opacity(0.10), AgentPalette.cyan.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .agentSurface(radius: 15, tint: AgentPalette.cyan.opacity(0.10))
    }

    private func artifactStrip(_ artifacts: [WorkspaceArtifact]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(artifacts.prefix(5)) { artifact in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        openArtifact(artifact)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: artifact.isWebPage || artifact.isSwiftGameArtifact ? artifact.handoffSymbol : artifact.symbol)
                                .font(.system(size: 10, weight: .bold))
                            Text(artifact.title)
                                .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(AgentPalette.ink)
                        .padding(.horizontal, 9)
                        .frame(height: 40)
                        .frame(maxWidth: 172)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .agentControlSurface(radius: 14, tint: AgentPalette.cyan.opacity(0.10), selected: true)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 128, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Preview artifact \(artifact.title)")
                    .accessibilityIdentifier("artifactSecondaryOpenButton")
                }
                if artifacts.count > 5 {
                    Text("+\(artifacts.count - 5)")
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.cyan)
                        .frame(width: 34, height: 30)
                        .agentControlSurface(radius: 10, tint: AgentPalette.cyan.opacity(0.10), selected: true)
                }
            }
        }
    }

    private func fileChangeStrip(_ changes: [ChatFileChangeSnapshot]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(changes.prefix(5)) { change in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        openWorkspaceSurface(.files)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(AgentPalette.indigo)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(change.displayAction)
                                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                                    .foregroundStyle(AgentPalette.indigo)
                                    .textCase(.uppercase)
                                    .lineLimit(1)
                                Text(change.displayPath)
                                    .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                    .foregroundStyle(AgentPalette.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .padding(.horizontal, 9)
                        .frame(width: 154, height: 42, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .agentControlSurface(radius: 13, tint: AgentPalette.indigo.opacity(0.09), selected: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open changed file \(change.displayPath)")
                    .accessibilityIdentifier("progressChangedFileButton")
                }
            }
        }
    }

    private var workspaceShortcuts: some View {
        VStack(spacing: 7) {
            ProgressActionButton(title: "Files", symbol: "folder.fill", tint: AgentPalette.cyan, identifier: "progressFilesButton") {
                openWorkspaceSurface(.files)
            }
            ProgressActionButton(title: "History", symbol: "list.bullet.rectangle.portrait.fill", tint: AgentPalette.cyan, identifier: "progressRunsButton") {
                openWorkspaceSurface(.runs)
            }
        }
    }

    private var nextActions: some View {
        VStack(spacing: 7) {
            if let workflowSpine {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workflowSpine.nextActionTitle)
                        .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .textCase(.uppercase)
                    Text(workflowSpine.iterationPrompt)
                        .font(.system(size: 9.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .agentRowSurface(radius: 10, tint: AgentPalette.blue.opacity(0.08), selected: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(workflowSpine.nextActionTitle). \(workflowSpine.iterationPrompt)")
                .accessibilityIdentifier("progressProjectNextAction")
            }

            if runtime.isWorking {
                ProgressActionButton(title: "Pause", symbol: "pause.fill", tint: AgentPalette.rose, identifier: "progressPauseButton", action: stop)
            } else if runtime.pendingTool != nil {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("Approve / Reject")
                        .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                }
                .foregroundStyle(AgentPalette.cyan)
                .frame(maxWidth: .infinity)
                .frame(height: AgentDesign.minimumTouchTarget)
                .agentControlSurface(radius: 10, tint: AgentPalette.cyan.opacity(0.10), selected: true)
            } else if runtime.wasInterrupted || runtime.lastError != nil {
                ProgressActionButton(title: "Continue", symbol: "play.fill", tint: AgentPalette.blue, identifier: "progressContinueButton", action: continueRun)
                ProgressActionButton(title: "Retry", symbol: "arrow.clockwise", tint: AgentPalette.cyan, identifier: "progressRetryButton", action: retry)
            } else {
                ProgressActionButton(title: "Clear", symbol: "checkmark", tint: AgentPalette.blue, identifier: "progressClearButton", action: clear)
            }

            if runtime.queuedPromptCount > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(runtime.queuedPromptCount) queued")
                        .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                }
                .foregroundStyle(AgentPalette.cyan)
                .frame(maxWidth: .infinity)
                .frame(height: AgentDesign.minimumTouchTarget)
                .agentControlSurface(radius: 10, tint: AgentPalette.cyan.opacity(0.10), selected: true)
            }
        }
    }
}

struct PendingApprovalInlineCard: View {
    let request: ToolRequest

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: request.isMutating ? "pencil.and.outline" : "eye.fill")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 36, height: 36)
                .agentControlSurface(radius: 13, tint: AgentPalette.cyan.opacity(0.14), selected: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(plainToolName(request.name))
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(request.isMutating ? "changes files" : "read only")
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(request.isMutating ? AgentPalette.cyan : AgentPalette.green)
                        .textCase(.uppercase)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .agentControlSurface(
                            radius: 7,
                            tint: (request.isMutating ? AgentPalette.cyan : AgentPalette.green).opacity(0.10),
                            selected: true
                        )
                }

                Text(argumentSummary)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text("Open the approval sheet to approve or reject; the run is paused.")
                    .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            LinearGradient(
                colors: [AgentPalette.surface, AgentPalette.cyan.opacity(0.10), AgentPalette.lilac.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .agentRowSurface(radius: 16, tint: AgentPalette.cyan.opacity(0.08), selected: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pendingApprovalInlineCard")
    }

    private var argumentSummary: String {
        for key in ["path", "from", "to", "query", "command"] {
            guard let value = request.arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            let oneLine = value.replacingOccurrences(of: "\n", with: " ")
            return oneLine.count > 96 ? String(oneLine.prefix(96)) + "..." : oneLine
        }
        return "\(request.arguments.count) argument\(request.arguments.count == 1 ? "" : "s") ready"
    }
}

struct ProofContextCard: View {
    let durableSnapshot: ChatDurableRunSnapshot
    let openArtifact: (WorkspaceArtifact) -> Void
    let openRuns: () -> Void

    private var tint: Color {
        if durableSnapshot.latestProof?.severity == .failure ||
            durableSnapshot.latestTerminalProof?.status == .failed {
            return AgentPalette.rose
        }
        if durableSnapshot.proofFreshness.localizedCaseInsensitiveContains("stale") {
            return AgentPalette.rose
        }
        return AgentPalette.lilac
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbolName)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .agentControlSurface(radius: 12, tint: tint.opacity(0.14), selected: true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                Text(durableSnapshot.proofFreshness.isEmpty ? "Proof" : durableSnapshot.proofFreshness)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(tint)
                    .textCase(.uppercase)
                    .padding(.horizontal, 7)
                    .frame(height: 21)
                    .agentControlSurface(radius: 8, tint: tint.opacity(0.12), selected: true)
            }

            HStack(spacing: 7) {
                if let sourcePath = durableSnapshot.latestProof?.sourcePath {
                    ProgressActionButton(title: "Open Proof", symbol: "arrow.up.right.square.fill", tint: AgentPalette.lilac, identifier: "progressOpenProofButton") {
                        openArtifact(WorkspaceArtifact(path: sourcePath))
                    }
                }

                ProgressActionButton(title: "History", symbol: "list.bullet.rectangle.portrait.fill", tint: AgentPalette.lilac, identifier: "progressProofRunsButton", action: openRuns)
            }

            if !evidenceTrail.isEmpty {
                Text(evidenceTrail)
                    .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(11)
        .agentRowSurface(radius: 16, tint: tint.opacity(0.08), selected: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("proofContextCard")
    }

    private var symbolName: String {
        durableSnapshot.latestProof?.symbolName ?? "checkmark.seal.fill"
    }

    private var title: String {
        if let proof = durableSnapshot.latestProof,
           !proof.title.localizedCaseInsensitiveContains("Project created") {
            return proof.title
        }
        if durableSnapshot.latestTerminalProof != nil {
            return "Terminal proof captured"
        }
        return durableSnapshot.reviewHeadline.isEmpty ? "Proof status" : durableSnapshot.reviewHeadline
    }

    private var detail: String {
        if let proof = durableSnapshot.latestProof,
           !proof.title.localizedCaseInsensitiveContains("Project created") {
            return proof.detail
        }
        if let terminal = durableSnapshot.latestTerminalProof {
            let preview = terminal.outputPreview.isEmpty ? "Command finished." : terminal.outputPreview
            return "$ \(terminal.command) · \(preview)"
        }
        return durableSnapshot.reviewDetail.isEmpty ? "Capture proof for the latest work before final review." : durableSnapshot.reviewDetail
    }

    private var evidenceTrail: String {
        durableSnapshot.evidenceTrail
    }
}

struct ArtifactHandoffCard: View {
    let artifact: WorkspaceArtifact
    let openArtifact: (WorkspaceArtifact) -> Void

    private var handoffText: String {
        if artifact.isSwiftGameArtifact {
            return "Open the native preview, then rotate sideways for handheld play."
        }
        if artifact.isPlayableWebArtifact {
            return "Open the live preview, then use Full Screen for landscape play."
        }
        if artifact.isWebPage {
            return "Open the responsive preview without switching into game mode."
        }
        return "Open the generated file in the workspace preview."
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: artifact.handoffSymbol)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(artifact.isWebPage || artifact.isSwiftGameArtifact ? AgentPalette.green : AgentPalette.cyan)
                .frame(width: 38, height: 38)
                .agentControlSurface(radius: 14, tint: (artifact.isWebPage || artifact.isSwiftGameArtifact ? AgentPalette.green : AgentPalette.cyan).opacity(0.14), selected: true)

            VStack(alignment: .leading, spacing: 3) {
                Text(artifact.title)
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(handoffText)
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                openArtifact(artifact)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square.fill")
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .padding(.horizontal, 10)
                    .frame(height: AgentDesign.minimumTouchTarget)
                    .agentGlass(radius: 13, interactive: true, tint: AgentPalette.green.opacity(0.16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open artifact preview for \(artifact.title)")
            .accessibilityIdentifier("artifactPrimaryOpenButton")
        }
        .padding(10)
        .agentRowSurface(radius: 16, tint: AgentPalette.green.opacity(0.06))
    }
}

struct RunMetric: View {
    let value: String
    let label: String
    let symbol: String
    let tint: Color
    var valueIdentifier: String? = nil

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
                .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .accessibilityIdentifier(valueIdentifier ?? "run\(label)Metric")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .agentRowSurface(radius: 12, tint: tint.opacity(0.06))
    }
}

struct ProgressDrawerLabel: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
            .foregroundStyle(tint)
            .textCase(.uppercase)
    }
}

struct AgentTraceRow: View {
    let event: AgentTraceEvent
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : tint.opacity(0.24))
                    .frame(width: 2, height: 7)
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .agentSurface(radius: 8, tint: tint.opacity(0.10))
                Rectangle()
                    .fill(isLast ? Color.clear : tint.opacity(0.24))
                    .frame(width: 2)
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .accessibilityIdentifier(isFirst ? "latestTraceEventTitle" : "traceEventTitle")
                if !displayDetail.isEmpty {
                    Text(displayDetail)
                        .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 7)

            Spacer(minLength: 0)

            Text(event.createdAt, style: .time)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(AgentPalette.tertiaryText)
                .padding(.top, 9)
        }
        .padding(.horizontal, 8)
    }

    private var displayTitle: String {
        let title = event.title
        for prefix in ["Finished", "Running", "Queued", "Approved", "Rejected"] {
            let marker = prefix + " "
            guard title.hasPrefix(marker) else { continue }
            let toolName = String(title.dropFirst(marker.count))
            switch prefix {
            case "Finished":
                return completedTitle(for: toolName)
            case "Running":
                return runningTitle(for: toolName)
            case "Queued":
                return "Queued \(plainToolName(toolName))"
            case "Approved":
                return "Approved \(plainToolName(toolName))"
            case "Rejected":
                return "Rejected \(plainToolName(toolName))"
            default:
                break
            }
        }
        return title
    }

    private var displayDetail: String {
        let cleaned = event.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        if let summary = jsonArgumentSummary(from: cleaned) {
            return summary
        }
        return cleaned
    }

    private func completedTitle(for toolName: String) -> String {
        switch toolName {
        case "write_file": "Wrote file"
        case "append_file": "Updated file"
        case "read_file": "Read file"
        case "list_directory": "Listed folder"
        case "search_text": "Searched workspace"
        case "validate_html_file": "Validated HTML"
        case "file_info": "Checked file info"
        case "run_command": "Ran command"
        case "make_directory": "Created folder"
        case "delete_path": "Deleted item"
        case "move_path": "Moved item"
        case "copy_path": "Copied item"
        default: "Finished \(plainToolName(toolName))"
        }
    }

    private func runningTitle(for toolName: String) -> String {
        switch toolName {
        case "write_file": "Writing file"
        case "append_file": "Updating file"
        case "read_file": "Reading file"
        case "list_directory": "Listing folder"
        case "search_text": "Searching workspace"
        case "validate_html_file": "Validating HTML"
        case "file_info": "Checking file info"
        case "run_command": "Running command"
        case "make_directory": "Creating folder"
        case "delete_path": "Deleting item"
        case "move_path": "Moving item"
        case "copy_path": "Copying item"
        default: "Running \(plainToolName(toolName))"
        }
    }

    private func plainToolName(_ toolName: String) -> String {
        toolName
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func jsonArgumentSummary(from text: String) -> String? {
        guard text.hasPrefix("{") else { return nil }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let path = roughJSONStringValue(for: "path", in: text) {
                return "path: \(shorten(path))"
            }
            if let command = roughJSONStringValue(for: "command", in: text) {
                return "command: \(shorten(command))"
            }
            if text.localizedCaseInsensitiveContains("contents") {
                return "file contents prepared"
            }
            return nil
        }
        for key in ["path", "file", "filename", "command", "query", "url", "name"] {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(key): \(shorten(value))"
            }
        }
        if let count = object["contents"].map({ "\($0)" })?.count {
            return "content prepared · \(count) chars"
        }
        return "\(object.count) argument\(object.count == 1 ? "" : "s") ready"
    }

    private func roughJSONStringValue(for key: String, in text: String) -> String? {
        let marker = "\"\(key)\":\""
        guard let startRange = text.range(of: marker) else { return nil }
        let valueStart = startRange.upperBound
        var value = ""
        var cursor = valueStart
        var escaped = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                value.append(character)
            }
            cursor = text.index(after: cursor)
        }
        return value.isEmpty ? nil : value
    }

    private func shorten(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard oneLine.count > 88 else { return oneLine }
        return String(oneLine.prefix(88)) + "…"
    }

    private var symbol: String {
        switch event.status {
        case .queued: "tray.full.fill"
        case .thinking: "sparkles"
        case .planning: "map.fill"
        case .tool: "wrench.and.screwdriver.fill"
        case .approval: "checkmark.shield.fill"
        case .executing: "play.fill"
        case .paused: "pause.circle.fill"
        case .success: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch event.status {
        case .queued: AgentPalette.indigo
        case .thinking, .planning: AgentPalette.cyan
        case .tool, .executing: AgentPalette.cyan
        case .approval: AgentPalette.green
        case .paused: AgentPalette.cyan
        case .success: AgentPalette.green
        case .failed: AgentPalette.rose
        }
    }
}

struct ProgressActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .padding(.horizontal, 9)
                .frame(height: AgentDesign.minimumTouchTarget)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .agentGlass(radius: 12, interactive: true, tint: tint.opacity(0.12))
        }
        .buttonStyle(.plain)
        .frame(minHeight: AgentDesign.minimumTouchTarget)
        .contentShape(Rectangle())
        .accessibilityIdentifier(identifier ?? "progress\(title)Button")
    }
}

struct ProgressStatusIcon: View {
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(AgentPalette.glassStroke.opacity(0.48), lineWidth: 2)
            Image(systemName: "hourglass")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: 22, height: 22)
    }
}

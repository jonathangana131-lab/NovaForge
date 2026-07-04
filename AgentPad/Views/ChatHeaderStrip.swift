//
//  ChatHeaderStrip.swift
//  NovaForge
//
//  Chat header and the context memory chip strip.
//

import SwiftData
import SwiftUI
import UIKit

struct ChatHeaderView: View {
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
    let hasForeignActiveRun: Bool
    let foreignActiveTitle: String
    let newChat: () -> Void
    let changeScope: (Project?) -> Void
    let openWorkspaceSurface: (AppTab) -> Void
    let openArtifact: (WorkspaceArtifact) -> Void
    let openChatDrawer: () -> Void

    private var chatChromeTint: Color { AgentPalette.primaryAccent }

    private var sessionTitle: String {
        let trimmed = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "NovaForge" }
        if trimmed.localizedCaseInsensitiveCompare("NovaForge Session") == .orderedSame { return "NovaForge" }
        if trimmed.localizedCaseInsensitiveCompare(LaunchConversationSelection.safeStartTitle) == .orderedSame { return "NovaForge" }
        return trimmed
    }

    private var projectTitle: String {
        guard let scopedProject else { return "Choose project" }
        let trimmed = scopedProject.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ProjectBootstrap.defaultProjectName : trimmed
    }

    private var scopeSymbol: String {
        scopedProject == nil ? "folder.fill" : "shippingbox.fill"
    }

    private var scopeModeLabel: String {
        // Single-word labels: the old two-word versions truncated to
        // "GENERAL C..." inside the fixed-height chip.
        scopedProject == nil ? "General" : "Project"
    }

    private var scopeModeTint: Color {
        scopedProject == nil ? AgentPalette.secondaryText : AgentPalette.cyan
    }

    private var sortedProjects: [Project] {
        projects.sorted { lhs, rhs in
            if lhs.id == scopedProject?.id { return true }
            if rhs.id == scopedProject?.id { return false }
            if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Header Body")
        VStack(alignment: .leading, spacing: 9) {
            headerRow

            ChatMemoryStrip(
                runtime: runtime,
                project: project,
                scopedProject: scopedProject,
                conversation: conversation,
                settings: settings,
                artifacts: artifacts,
                durableSnapshot: durableSnapshot,
                workflowSpine: workflowSpine,
                ownsActiveRunState: ownsActiveRunState,
                hasForeignActiveRun: hasForeignActiveRun,
                foreignActiveTitle: foreignActiveTitle,
                openWorkspaceSurface: openWorkspaceSurface,
                openArtifact: openArtifact
            )
        }
    }

    private var headerRow: some View {
        HStack(spacing: 11) {
            chatChromeButton(
                symbol: "bubble.left.and.bubble.right",
                tint: chatChromeTint,
                label: "Open chats",
                action: openChatDrawer
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(sessionTitle)
                        .font(NovaType.title)
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("currentChatTitle")

                    StatusDot(text: statusText, symbol: statusSymbol, tint: statusTint)
                }

                HStack(spacing: 6) {
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
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(scopeModeLabel)
                                .novaLabel(scopeModeTint)
                                .accessibilityIdentifier("chatScopeModePill")
                            Text(projectTitle)
                                .font(NovaType.caption)
                                .foregroundStyle(scopedProject == nil ? AgentPalette.secondaryText : AgentPalette.cyan)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(AgentPalette.quaternaryText)
                        }
                        .layoutPriority(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chatProjectScopeMenu")

                    Text("·")
                        .foregroundStyle(AgentPalette.quaternaryText)

                    Label(settings.provider.shortName, systemImage: settings.provider.symbol)
                        .font(NovaType.caption)
                        .foregroundStyle(settings.provider.tint)
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(2)

                    if conversation.messageCount > 0 {
                        Text("·")
                            .foregroundStyle(AgentPalette.quaternaryText)

                        Text(messageCountText)
                            .font(NovaType.caption)
                            .foregroundStyle(AgentPalette.tertiaryText)
                            .lineLimit(1)
                    }

                    if hasForeignActiveRun {
                        Text("·")
                            .foregroundStyle(AgentPalette.quaternaryText)

                        Text("Running in \(foreignActiveTitle)")
                            .font(NovaType.caption)
                            .foregroundStyle(AgentPalette.cyan)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("chatActiveElsewhereHeader")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            chatChromeButton(
                symbol: "square.and.pencil",
                tint: AgentPalette.lilac,
                label: "New chat",
                action: newChat
            )
        }
    }

    private func chatChromeButton(symbol: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(Circle().fill(tint.opacity(0.10)))
                .overlay(Circle().strokeBorder(tint.opacity(0.26), lineWidth: 0.9))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var messageCountText: String {
        "\(conversation.messageCount)"
    }


    private var statusTint: Color {
        if hasForeignActiveRun { return AgentPalette.cyan }
        guard ownsActiveRunState else { return AgentPalette.accent }
        if runtime.pendingTool != nil { return AgentPalette.cyan }
        if runtime.lastError != nil { return AgentPalette.rose }
        if runtime.isWorking { return chatChromeTint }
        return AgentPalette.accent
    }

    private var statusSymbol: String {
        if hasForeignActiveRun { return "arrow.up.right.circle.fill" }
        guard ownsActiveRunState else { return "circle.fill" }
        return runtime.isWorking ? "waveform" : "circle.fill"
    }

}

enum ChatMemoryChipTone: Equatable {
    case project
    case run
    case approval
    case file
    case artifact
    case proof
    case resume
    case model
    case warning

    var tint: Color {
        switch self {
        case .project: AgentPalette.cyan
        case .run: AgentPalette.primaryAccent
        case .approval: AgentPalette.cyan
        case .file: AgentPalette.indigo
        case .artifact: AgentPalette.green
        case .proof: AgentPalette.lilac
        case .resume: AgentPalette.blue
        case .model: AgentPalette.cyan
        case .warning: AgentPalette.rose
        }
    }
}

enum ChatMemoryChipDestination: Equatable {
    case tab(AppTab)
    case artifact(String)
    case none
}

struct ChatMemoryChip: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let tone: ChatMemoryChipTone
    let destination: ChatMemoryChipDestination
    var isProminent = false
}

struct ChatMemoryStrip: View {
    let runtime: AgentRuntime
    let project: Project
    let scopedProject: Project?
    let conversation: Conversation
    let settings: AgentSettings
    let artifacts: [WorkspaceArtifact]
    let durableSnapshot: ChatDurableRunSnapshot
    let workflowSpine: ProjectWorkflowSpine?
    let ownsActiveRunState: Bool
    let hasForeignActiveRun: Bool
    let foreignActiveTitle: String
    let openWorkspaceSurface: (AppTab) -> Void
    let openArtifact: (WorkspaceArtifact) -> Void

    private var chips: [ChatMemoryChip] {
        var result: [ChatMemoryChip] = [projectChip]

        if let runChip {
            result.append(runChip)
        }
        if let resumeChip {
            result.append(resumeChip)
        }
        if let fileChip {
            result.append(fileChip)
        }
        if let artifactChip {
            result.append(artifactChip)
        }
        if let proofChip {
            result.append(proofChip)
        }
        if let modelChip {
            result.append(modelChip)
        }
        if result.count == 1, let workflowSpine {
            result.append(ChatMemoryChip(
                id: "next",
                title: workflowSpine.nextActionTitle,
                detail: workflowSpine.nextActionDetail,
                symbol: "arrow.triangle.branch",
                tone: .run,
                destination: .tab(.project)
            ))
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(chips) { chip in
                    ChatMemoryChipButton(chip: chip) {
                        activate(chip)
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatContextMemoryStrip")
    }

    private var projectChip: ChatMemoryChip {
        let scopedName = scopedProject?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = scopedProject == nil ? "General" : "Project"
        let detail = scopedProject == nil
            ? "Default workspace"
            : (scopedName?.isEmpty == false ? scopedName! : project.name)
        return ChatMemoryChip(
            id: "project",
            title: title,
            detail: detail,
            symbol: scopedProject == nil ? "folder.fill" : "shippingbox.fill",
            tone: .project,
            destination: .tab(.project),
            isProminent: scopedProject != nil
        )
    }

    private var runChip: ChatMemoryChip? {
        if hasForeignActiveRun {
            return ChatMemoryChip(
                id: "foreign-run",
                title: "Running",
                detail: foreignActiveTitle,
                symbol: "arrow.up.right.circle.fill",
                tone: .run,
                destination: .none,
                isProminent: true
            )
        }
        guard ownsActiveRunState else { return nil }
        if let pending = runtime.pendingTool {
            return ChatMemoryChip(
                id: "pending-runtime",
                title: "Approval",
                detail: pendingDetail(for: pending),
                symbol: "checkmark.shield.fill",
                tone: .approval,
                destination: .tab(.runs),
                isProminent: true
            )
        }
        if runtime.isWorking {
            return ChatMemoryChip(
                id: "active-run",
                title: "Active Run",
                detail: runtime.activityTitle,
                symbol: "waveform",
                tone: .run,
                destination: .tab(.runs),
                isProminent: true
            )
        }
        if runtime.wasInterrupted || runtime.lastError != nil {
            return ChatMemoryChip(
                id: "recover-run",
                title: runtime.wasInterrupted ? "Paused" : "Failed",
                detail: runtime.lastError ?? "Continue from saved progress",
                symbol: runtime.wasInterrupted ? "pause.circle.fill" : "exclamationmark.triangle.fill",
                tone: runtime.wasInterrupted ? .resume : .warning,
                destination: .tab(.runs),
                isProminent: true
            )
        }
        if runtime.queuedPromptCount > 0 {
            return ChatMemoryChip(
                id: "queued",
                title: "Queued",
                detail: "\(runtime.queuedPromptCount) follow-up\(runtime.queuedPromptCount == 1 ? "" : "s")",
                symbol: "tray.full.fill",
                tone: .run,
                destination: .tab(.runs)
            )
        }
        if durableSnapshot.pendingApprovalCount > 0 {
            return ChatMemoryChip(
                id: "pending-durable",
                title: "Approval",
                detail: "\(durableSnapshot.pendingApprovalCount) waiting",
                symbol: "checkmark.shield.fill",
                tone: .approval,
                destination: .tab(.runs),
                isProminent: true
            )
        }
        return nil
    }

    private var resumeChip: ChatMemoryChip? {
        guard let projectOSRun = durableSnapshot.projectOSRun, projectOSRun.hasResumeCue else { return nil }
        return ChatMemoryChip(
            id: "projectos-\(projectOSRun.id.uuidString)",
            title: projectOSRun.displayTitle,
            detail: projectOSRun.displayDetail,
            symbol: "arrow.triangle.2.circlepath",
            tone: .resume,
            destination: .tab(.project),
            isProminent: true
        )
    }

    private var fileChip: ChatMemoryChip? {
        if let change = durableSnapshot.fileChanges.first {
            return ChatMemoryChip(
                id: "file-\(change.id.uuidString)",
                title: change.displayAction,
                detail: change.displayPath,
                symbol: "doc.text.fill",
                tone: .file,
                destination: .tab(.files)
            )
        }
        if let changedPath = workflowSpine?.latestChangedPath {
            return ChatMemoryChip(
                id: "file-\(changedPath)",
                title: workflowSpine?.changedTitle ?? "Changed",
                detail: shortPath(changedPath),
                symbol: "doc.text.fill",
                tone: .file,
                destination: .tab(.files)
            )
        }
        return nil
    }

    private var artifactChip: ChatMemoryChip? {
        guard let artifact = artifacts.first else { return nil }
        return ChatMemoryChip(
            id: "artifact-\(artifact.path)",
            title: artifact.isSwiftGameArtifact || artifact.isPlayableWebArtifact ? "Playable" : "Artifact",
            detail: artifact.title,
            symbol: artifact.handoffSymbol,
            tone: .artifact,
            destination: .artifact(artifact.path),
            isProminent: true
        )
    }

    private var proofChip: ChatMemoryChip? {
        if let proof = durableSnapshot.latestProof,
           !proof.title.localizedCaseInsensitiveContains("Project created") {
            return ChatMemoryChip(
                id: "proof-\(proof.id)",
                title: durableSnapshot.proofFreshness.isEmpty ? "Proof" : durableSnapshot.proofFreshness,
                detail: proof.title,
                symbol: proof.symbolName,
                tone: proof.severity == .failure ? .warning : .proof,
                destination: proof.sourcePath.map { .artifact($0) } ?? .tab(.runs)
            )
        }
        if let terminal = durableSnapshot.latestTerminalProof {
            return ChatMemoryChip(
                id: "terminal-\(terminal.id.uuidString)",
                title: "Terminal proof",
                detail: shortCommand(terminal.command),
                symbol: "terminal.fill",
                tone: terminal.status == .failed ? .warning : .proof,
                destination: .tab(.runs)
            )
        }
        return nil
    }

    private var modelChip: ChatMemoryChip? {
        guard settings.provider == .local, !runtime.localModels.isDownloaded else { return nil }
        return ChatMemoryChip(
            id: "model",
            title: "Model setup",
            detail: "Download needed",
            symbol: "arrow.down.circle.fill",
            tone: .model,
            destination: .tab(.settings),
            isProminent: true
        )
    }

    private func activate(_ chip: ChatMemoryChip) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch chip.destination {
        case .tab(let tab):
            openWorkspaceSurface(tab)
        case .artifact(let path):
            openArtifact(WorkspaceArtifact(path: path))
        case .none:
            break
        }
    }

    private func pendingDetail(for request: ToolRequest) -> String {
        for key in ["path", "from", "to", "command", "query", "name"] {
            guard let value = request.arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            return key == "path" ? shortPath(value) : shorten(value, limit: 44)
        }
        return plainToolName(request.name)
    }

    private func shortPath(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? shorten(path, limit: 44) : name
    }

    private func shortCommand(_ command: String) -> String {
        shorten(command.replacingOccurrences(of: "\n", with: " "), limit: 48)
    }

    private func shorten(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(max(1, limit - 3))) + "..."
    }
}

struct ChatMemoryChipButton: View {
    let chip: ChatMemoryChip
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: chip.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(chip.tone.tint)

                Text(chip.title)
                    .novaLabel(chip.tone.tint)

                Text(chip.detail)
                    .font(NovaType.caption)
                    .foregroundStyle(chip.isProminent ? AgentPalette.ink : AgentPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if chip.destination != .none {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(AgentPalette.quaternaryText)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .frame(maxWidth: 230)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(
            Capsule(style: .continuous)
                .fill(chip.tone.tint.opacity(chip.isProminent ? 0.13 : 0.06))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(chip.tone.tint.opacity(chip.isProminent ? 0.40 : 0.18), lineWidth: 0.8)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chip.title): \(chip.detail)")
        .accessibilityIdentifier("chatContextChip-\(chip.id)")
    }
}

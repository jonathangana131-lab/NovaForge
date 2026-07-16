//
//  ChatRunSnapshots.swift
//  NovaForge
//
//  Durable run snapshots derived for the chat surface.
//

import SwiftData
import SwiftUI
import UIKit

struct ChatFileChangeSnapshot: Identifiable, Equatable {
    let id: UUID
    let action: String
    let path: String
    let createdAt: Date

    init(change: ProjectFileChange) {
        id = change.id
        action = change.action
        path = change.path
        createdAt = change.createdAt
    }

    var displayAction: String {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "File changed" : trimmed
    }

    var displayPath: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}

struct ChatProofSnapshot: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let createdAt: Date
    let symbolName: String
    let sourcePath: String?
    let severity: ProjectEventSeverity

    init(item: ProjectProofItem) {
        id = item.id
        title = item.title
        detail = item.detail
        createdAt = item.createdAt
        symbolName = item.symbolName
        sourcePath = item.sourcePath
        severity = item.severity
    }
}

struct ChatTerminalProofSnapshot: Identifiable, Equatable {
    let id: UUID
    let command: String
    let status: TerminalCommandStatus
    let completedAt: Date
    let outputPreview: String

    init(command: TerminalCommandRecord) {
        id = command.id
        self.command = command.command
        status = command.status
        completedAt = command.completedAt
        outputPreview = Self.preview(command.output)
    }

    private static func preview(_ output: String) -> String {
        let oneLine = output
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > 96 else { return oneLine }
        return String(oneLine.prefix(96)) + "..."
    }
}

struct ChatProjectOSRunSnapshot: Identifiable, Equatable {
    let id: UUID
    let status: ProjectOSRunStatus
    let currentAction: String
    let nextStep: String
    let resumeState: String
    let proofSummary: String
    let changedFilesSummary: String
    let updatedAt: Date
    let recommendedAction: String

    init(run: ProjectOSRun) {
        id = run.id
        status = run.status
        currentAction = run.currentAction
        nextStep = run.nextStep
        resumeState = run.resumeState
        proofSummary = run.proofSummary
        changedFilesSummary = run.changedFilesSummary
        updatedAt = run.updatedAt
        recommendedAction = run.currentIntent.recommendedAction
    }

    var hasResumeCue: Bool {
        status == .stopped ||
            status == .blocked ||
            status == .failed ||
            !resumeState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayTitle: String {
        if hasResumeCue { return "Resume available" }
        switch status {
        case .planning, .running:
            return "ProjectOS active"
        case .waiting:
            return "ProjectOS waiting"
        case .completed:
            return "ProjectOS complete"
        case .blocked:
            return "ProjectOS blocked"
        case .failed:
            return "ProjectOS failed"
        case .stopped:
            return "ProjectOS stopped"
        case .idle:
            return "ProjectOS ready"
        }
    }

    var displayDetail: String {
        for candidate in [resumeState, currentAction, recommendedAction, nextStep] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return status.displayName
    }
}

struct ChatDurableRunSnapshot: Equatable {
    var artifacts: [WorkspaceArtifact]
    var traceEvents: [AgentTraceEvent]
    var fileChanges: [ChatFileChangeSnapshot]
    var pendingApprovalCount: Int
    var latestProof: ChatProofSnapshot?
    var latestTerminalProof: ChatTerminalProofSnapshot?
    var projectOSRun: ChatProjectOSRunSnapshot?
    var reviewHeadline: String
    var reviewDetail: String
    var proofFreshness: String
    var evidenceTrail: String
    var lastRunDuration: TimeInterval?
    var hasCompletedRun: Bool

    static let empty = ChatDurableRunSnapshot(
        artifacts: [],
        traceEvents: [],
        fileChanges: [],
        pendingApprovalCount: 0,
        latestProof: nil,
        latestTerminalProof: nil,
        projectOSRun: nil,
        reviewHeadline: "",
        reviewDetail: "",
        proofFreshness: "",
        evidenceTrail: "",
        lastRunDuration: nil,
        hasCompletedRun: false
    )

    var hasCompletionEvidence: Bool {
        hasCompletedRun ||
            lastRunDuration != nil ||
            !artifacts.isEmpty ||
            !fileChanges.isEmpty ||
            latestProof != nil ||
            latestTerminalProof != nil ||
            projectOSRun?.hasResumeCue == true ||
            traceEvents.contains { $0.status == .success }
    }

    static func make(
        project: Project?,
        conversation: Conversation,
        context: ModelContext
    ) -> ChatDurableRunSnapshot {
        let scopeProjectID = project?.id
        let fetchedArtifacts = fetchRecentArtifacts(context: context, projectID: scopeProjectID)
        let fetchedRuns = fetchRecentToolRuns(context: context, projectID: scopeProjectID)
        let fetchedFileChanges = fetchRecentFileChanges(context: context, projectID: scopeProjectID)
        let fetchedTerminalCommands = fetchRecentTerminalCommands(context: context, projectID: scopeProjectID)
        let fetchedProjectOSRuns = fetchRecentProjectOSRuns(context: context, projectID: scopeProjectID)
        let summary = project.map { ProjectMissionSummarizer.summarize(project: $0, context: context) }
        let latestArtifacts = uniqueArtifacts(
            project.map { scopedProject in
                scopedProject.artifacts + fetchedArtifacts.filter { $0.project?.id == scopedProject.id }
            } ?? fetchedArtifacts.filter { $0.project == nil }
        ).sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.path < rhs.path
        }
        let latestRuns = uniqueRuns(
            project.map { scopedProject in
                scopedProject.toolRuns + fetchedRuns.filter { $0.project?.id == scopedProject.id }
            } ?? fetchedRuns.filter { $0.project == nil }
        ).sorted { lhs, rhs in
            let lhsDate = lhs.completedAt ?? lhs.createdAt
            let rhsDate = rhs.completedAt ?? rhs.createdAt
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let latestFileChanges = uniqueFileChanges(
            project.map { scopedProject in
                scopedProject.fileChanges + fetchedFileChanges.filter { $0.project?.id == scopedProject.id }
            } ?? fetchedFileChanges.filter { $0.project == nil }
        ).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.path < rhs.path
        }
        let latestTerminalCommands = uniqueTerminalCommands(
            project.map { scopedProject in
                scopedProject.terminalCommands + fetchedTerminalCommands.filter { $0.project?.id == scopedProject.id }
            } ?? fetchedTerminalCommands.filter { $0.project == nil }
        ).sorted { lhs, rhs in
            if lhs.completedAt != rhs.completedAt { return lhs.completedAt > rhs.completedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let latestProjectOSRun = uniqueProjectOSRuns(
            project.map { scopedProject in
                scopedProject.projectOSRuns + fetchedProjectOSRuns.filter { $0.project?.id == scopedProject.id }
            } ?? []
        ).sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }.first

        var seenArtifactPaths = Set<String>()
        var artifacts: [WorkspaceArtifact] = []
        for artifact in latestArtifacts {
            guard seenArtifactPaths.insert(artifact.path).inserted else { continue }
            artifacts.append(WorkspaceArtifact(path: artifact.path))
            if artifacts.count >= 4 { break }
        }
        if artifacts.count < 4 {
            for run in latestRuns {
                guard let artifact = WorkspaceArtifact.fromToolOutput(run.output),
                      seenArtifactPaths.insert(artifact.path).inserted else { continue }
                artifacts.append(artifact)
                if artifacts.count >= 4 { break }
            }
        }

        var traceEvents = latestRuns.prefix(6).map(Self.traceEvent)
        if traceEvents.isEmpty, let artifact = artifacts.first {
            traceEvents.append(AgentTraceEvent(
                title: "Run complete",
                detail: artifact.path,
                status: .success
            ))
        }

        let latestCompletedRun = latestRuns.first { run in
            run.completedAt != nil && (run.status == .completed || run.status == .failed || run.status == .rejected)
        }
        let duration = latestCompletedRun.flatMap { run -> TimeInterval? in
            guard let completedAt = run.completedAt else { return nil }
            return completedAt.timeIntervalSince(run.createdAt)
        }

        return ChatDurableRunSnapshot(
            artifacts: artifacts,
            traceEvents: Array(traceEvents.prefix(6)),
            fileChanges: latestFileChanges.prefix(5).map { ChatFileChangeSnapshot(change: $0) },
            pendingApprovalCount: summary?.pendingApprovalCount ?? latestRuns.filter { $0.status == .pendingApproval }.count,
            latestProof: summary?.proofItems.first.map { ChatProofSnapshot(item: $0) },
            latestTerminalProof: latestTerminalCommands.first.map { ChatTerminalProofSnapshot(command: $0) },
            projectOSRun: latestProjectOSRun.map { ChatProjectOSRunSnapshot(run: $0) },
            reviewHeadline: summary?.review.headline ?? "",
            reviewDetail: summary?.review.detail ?? "",
            proofFreshness: summary?.review.proofFreshness ?? "",
            evidenceTrail: summary?.review.evidenceTrail ?? "",
            lastRunDuration: duration,
            hasCompletedRun: latestRuns.contains { $0.status == .completed }
        )
    }

    static func mergedTraceEvents(
        runtime: [AgentTraceEvent],
        durable: [AgentTraceEvent],
        limit: Int = 6
    ) -> [AgentTraceEvent] {
        var seen = Set<String>()
        var events: [AgentTraceEvent] = []
        for event in runtime + durable {
            let key = "\(event.title)|\(event.detail)|\(event.status.rawValue)"
            guard seen.insert(key).inserted else { continue }
            events.append(event)
            if events.count >= limit { break }
        }
        return events
    }

    private static func traceEvent(for run: ToolRun) -> AgentTraceEvent {
        AgentTraceEvent(
            title: traceTitle(for: run),
            detail: traceDetail(for: run),
            status: traceStatus(for: run.status)
        )
    }

    private static func traceTitle(for run: ToolRun) -> String {
        switch run.status {
        case .pendingApproval:
            return "Queued \(run.name)"
        case .approved:
            return "Approved \(run.name)"
        case .rejected:
            return "Rejected \(run.name)"
        case .completed:
            return run.requiresApproval ? "Approved \(run.name)" : "Finished \(run.name)"
        case .failed:
            return "Failed \(run.name)"
        }
    }

    private static func traceDetail(for run: ToolRun) -> String {
        // This is a compact V1 fallback, not an argument inspector. Raw JSON,
        // command text, file contents, and output remain in the durable History
        // receipt instead of being copied into the Forge progress timeline.
        legacyTraceDetail(for: run.status)
    }

    static func legacyTraceDetail(for status: ToolRunStatus) -> String {
        switch status {
        case .pendingApproval:
            return "Decision required before this action runs."
        case .approved:
            return "Approved action is ready to continue."
        case .rejected:
            return "The action was not applied."
        case .completed:
            return "Receipt saved in History."
        case .failed:
            return "Action failed. Open History for diagnostics."
        }
    }

    private static func traceStatus(for status: ToolRunStatus) -> AgentTraceStatus {
        switch status {
        case .pendingApproval, .approved:
            return .approval
        case .rejected, .failed:
            return .failed
        case .completed:
            return .success
        }
    }

    private static func fetchRecentArtifacts(context: ModelContext, projectID: UUID?) -> [ProjectArtifact] {
        var descriptor: FetchDescriptor<ProjectArtifact>
        if let projectID {
            descriptor = FetchDescriptor<ProjectArtifact>(
                predicate: #Predicate { $0.project?.id == projectID },
                sortBy: [SortDescriptor(\ProjectArtifact.updatedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<ProjectArtifact>(
                predicate: #Predicate { $0.project == nil },
                sortBy: [SortDescriptor(\ProjectArtifact.updatedAt, order: .reverse)]
            )
        }
        descriptor.fetchLimit = 24
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchRecentToolRuns(context: ModelContext, projectID: UUID?) -> [ToolRun] {
        var descriptor: FetchDescriptor<ToolRun>
        if let projectID {
            descriptor = FetchDescriptor<ToolRun>(
                predicate: #Predicate { $0.project?.id == projectID },
                sortBy: [SortDescriptor(\ToolRun.createdAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<ToolRun>(
                predicate: #Predicate { $0.project == nil },
                sortBy: [SortDescriptor(\ToolRun.createdAt, order: .reverse)]
            )
        }
        descriptor.fetchLimit = 24
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchRecentFileChanges(context: ModelContext, projectID: UUID?) -> [ProjectFileChange] {
        var descriptor: FetchDescriptor<ProjectFileChange>
        if let projectID {
            descriptor = FetchDescriptor<ProjectFileChange>(
                predicate: #Predicate { $0.project?.id == projectID },
                sortBy: [SortDescriptor(\ProjectFileChange.createdAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<ProjectFileChange>(
                predicate: #Predicate { $0.project == nil },
                sortBy: [SortDescriptor(\ProjectFileChange.createdAt, order: .reverse)]
            )
        }
        descriptor.fetchLimit = 24
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchRecentTerminalCommands(context: ModelContext, projectID: UUID?) -> [TerminalCommandRecord] {
        var descriptor: FetchDescriptor<TerminalCommandRecord>
        if let projectID {
            descriptor = FetchDescriptor<TerminalCommandRecord>(
                predicate: #Predicate { $0.project?.id == projectID },
                sortBy: [SortDescriptor(\TerminalCommandRecord.completedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<TerminalCommandRecord>(
                predicate: #Predicate { $0.project == nil },
                sortBy: [SortDescriptor(\TerminalCommandRecord.completedAt, order: .reverse)]
            )
        }
        descriptor.fetchLimit = 24
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchRecentProjectOSRuns(context: ModelContext, projectID: UUID?) -> [ProjectOSRun] {
        guard let projectID else { return [] }
        var descriptor = FetchDescriptor<ProjectOSRun>(
            predicate: #Predicate { $0.project?.id == projectID },
            sortBy: [SortDescriptor(\ProjectOSRun.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 12
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func uniqueArtifacts(_ artifacts: [ProjectArtifact]) -> [ProjectArtifact] {
        var seen = Set<String>()
        var result: [ProjectArtifact] = []
        for artifact in artifacts {
            guard seen.insert(artifact.path).inserted else { continue }
            result.append(artifact)
        }
        return result
    }

    private static func uniqueRuns(_ runs: [ToolRun]) -> [ToolRun] {
        var seen = Set<UUID>()
        var result: [ToolRun] = []
        for run in runs {
            guard seen.insert(run.id).inserted else { continue }
            result.append(run)
        }
        return result
    }

    private static func uniqueFileChanges(_ changes: [ProjectFileChange]) -> [ProjectFileChange] {
        var seen = Set<UUID>()
        var result: [ProjectFileChange] = []
        for change in changes {
            guard seen.insert(change.id).inserted else { continue }
            result.append(change)
        }
        return result
    }

    private static func uniqueTerminalCommands(_ commands: [TerminalCommandRecord]) -> [TerminalCommandRecord] {
        var seen = Set<UUID>()
        var result: [TerminalCommandRecord] = []
        for command in commands {
            guard seen.insert(command.id).inserted else { continue }
            result.append(command)
        }
        return result
    }

    private static func uniqueProjectOSRuns(_ runs: [ProjectOSRun]) -> [ProjectOSRun] {
        var seen = Set<UUID>()
        var result: [ProjectOSRun] = []
        for run in runs {
            guard seen.insert(run.id).inserted else { continue }
            result.append(run)
        }
        return result
    }

}

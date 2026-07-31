//
//  ProjectOSEngine.swift
//  NovaForge
//
//  ProjectOS operational engine: bootstrap, event recording, command
//  intents, plan building, intent derivation, and the run ledger.
//

import Foundation
import SwiftData

enum ProjectBootstrap {
    static let defaultProjectName = "NovaForge Project"
    /// Legacy releases predated General-scoped evidence and treated every nil
    /// project link as an orphan. This marker makes that conversion exactly
    /// once; after it is set, nil is an intentional General scope forever.
    static let legacyOwnershipMigrationKey = "NovaForge.legacyProjectOwnershipMigration.v2"
    /// Set at every launch after the persistent container is selected. An
    /// unknown-model compatibility store is a separate durable branch, not the
    /// legacy source store, so it must neither consume nor perform the source
    /// store's one-time ownership migration.
    static let compatibilityFallbackActiveKey = "NovaForge.compatibilityFallbackActive.v1"

    /// All storage reads needed to select a project and perform the one-time
    /// ownership migration. Keeping these injectable makes a failed fetch a
    /// first-class launch error instead of indistinguishable from an empty
    /// store.
    struct Fetches {
        var projects: (ModelContext) throws -> [Project]
        var runRecords: (ModelContext) throws -> [AgentRunRecord]
        var toolRuns: (ModelContext) throws -> [ToolRun]
        var terminalCommands: (ModelContext) throws -> [TerminalCommandRecord]
        var artifacts: (ModelContext) throws -> [ProjectArtifact]
        var fileChanges: (ModelContext) throws -> [ProjectFileChange]
        var events: (ModelContext) throws -> [ProjectEvent]

        static var live: Fetches {
            Fetches(
                projects: { try $0.fetch(FetchDescriptor<Project>()) },
                runRecords: { try $0.fetch(FetchDescriptor<AgentRunRecord>()) },
                toolRuns: { try $0.fetch(FetchDescriptor<ToolRun>()) },
                terminalCommands: { try $0.fetch(FetchDescriptor<TerminalCommandRecord>()) },
                artifacts: { try $0.fetch(FetchDescriptor<ProjectArtifact>()) },
                fileChanges: { try $0.fetch(FetchDescriptor<ProjectFileChange>()) },
                events: { try $0.fetch(FetchDescriptor<ProjectEvent>()) }
            )
        }
    }

    struct PrefetchedRecords {
        fileprivate let projects: [Project]
        fileprivate let legacyOwnership: LegacyOwnershipRecords?
    }

    fileprivate struct LegacyOwnershipRecords {
        let runRecords: [AgentRunRecord]
        let toolRuns: [ToolRun]
        let terminalCommands: [TerminalCommandRecord]
        let artifacts: [ProjectArtifact]
        let fileChanges: [ProjectFileChange]
        let events: [ProjectEvent]
    }

    static func preferredProject(from projects: [Project], settings: AgentSettings?) -> Project? {
        if let activeProjectID = settings?.activeProjectID,
           let match = projects.first(where: { $0.id == activeProjectID }) {
            return match
        }
        if let defaultProject = projects.first(where: { $0.name == defaultProjectName }) {
            return defaultProject
        }
        return projects.sorted { lhs, rhs in
            if lhs.lastActivityAt != rhs.lastActivityAt {
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
            return lhs.createdAt < rhs.createdAt
        }.first
    }

    @discardableResult
    static func ensureDefaultProject(
        in context: ModelContext,
        settings: AgentSettings?,
        now: Date = Date(),
        migrationStore: UserDefaults = .standard,
        fetches: Fetches = .live
    ) throws -> Project {
        let records = try prefetchRecords(
            in: context,
            migrationStore: migrationStore,
            fetches: fetches
        )
        return ensureDefaultProject(
            in: context,
            settings: settings,
            now: now,
            prefetched: records
        )
    }

    /// Read every legacy collection before applying any relationship changes.
    /// If one read fails, the caller can abort the enclosing launch transaction
    /// with no partial migration to unwind.
    static func prefetchRecords(
        in context: ModelContext,
        migrationStore: UserDefaults = .standard,
        fetches: Fetches = .live
    ) throws -> PrefetchedRecords {
        let projects = try fetches.projects(context)
        let legacyOwnership: LegacyOwnershipRecords?
        if migrationStore.bool(forKey: legacyOwnershipMigrationKey) ||
            migrationStore.bool(forKey: compatibilityFallbackActiveKey) {
            legacyOwnership = nil
        } else {
            // Evaluate these reads before returning the snapshot. Do not move
            // any relationships until the entire legacy store is readable.
            legacyOwnership = LegacyOwnershipRecords(
                runRecords: try fetches.runRecords(context),
                toolRuns: try fetches.toolRuns(context),
                terminalCommands: try fetches.terminalCommands(context),
                artifacts: try fetches.artifacts(context),
                fileChanges: try fetches.fileChanges(context),
                events: try fetches.events(context)
            )
        }
        return PrefetchedRecords(projects: projects, legacyOwnership: legacyOwnership)
    }

    @discardableResult
    static func ensureDefaultProject(
        in context: ModelContext,
        settings: AgentSettings?,
        now: Date = Date(),
        prefetched records: PrefetchedRecords
    ) -> Project {
        let project: Project
        if let preferred = preferredProject(from: records.projects, settings: settings) {
            project = preferred
        } else {
            let workspaceName = settings?.activeWorkspaceName ?? "Default"
            let created = Project(name: defaultProjectName, workspaceName: workspaceName, now: now)
            context.insert(created)
            project = created
            ProjectEventRecorder.record(
                project: project,
                kind: .projectCreated,
                title: "Default project created",
                detail: "NovaForge created a durable project for project-scoped missions and workspace activity.",
                severity: .success,
                sourceType: .system,
                context: context,
                now: now
            )
        }

        if let legacyOwnership = records.legacyOwnership {
            let linkedCount = linkLegacyOrphans(to: project, records: legacyOwnership)
            if linkedCount > 0 {
                ProjectEventRecorder.record(
                    project: project,
                    kind: .migrationLinked,
                    title: "Existing work linked",
                    detail: "\(linkedCount) existing records now belong to \(project.name).",
                    severity: .info,
                    sourceType: .system,
                    context: context,
                    now: now
                )
            }
        }

        if settings?.activeProjectID != project.id {
            settings?.activeProjectID = project.id
            settings?.updatedAt = now
        }
        if project.workspaceName.isEmpty {
            project.workspaceName = settings?.activeWorkspaceName ?? "Default"
        }
        project.updatedAt = max(project.updatedAt, now)
        return project
    }

    /// Call only after the enclosing SwiftData transaction commits. Keeping
    /// this separate means a disk-full error cannot permanently skip the
    /// one-time legacy conversion just because UserDefaults wrote first.
    static func markLegacyOwnershipMigrationComplete(in store: UserDefaults = .standard) {
        guard !store.bool(forKey: compatibilityFallbackActiveKey) else {
            // AppRoot can finish additional launch repairs after App.init. Keep
            // every such call from consuming the source store's migration while
            // this process is rendering the separate compatibility branch. The
            // source marker may already be true, so preserve it byte-for-byte.
            return
        }
        store.set(true, forKey: legacyOwnershipMigrationKey)
    }

    /// Must be called once per launch before bootstrap reads UserDefaults.
    /// Compatibility mode must preserve the source store's migration marker:
    /// false remains eligible for a later normal migration, while true prevents
    /// modern General evidence from being mistaken for legacy ownership.
    static func setCompatibilityFallbackActive(
        _ isActive: Bool,
        in store: UserDefaults = .standard
    ) {
        store.set(isActive, forKey: compatibilityFallbackActiveKey)
    }

    /// Old nil links are migrated once, but any evidence already tied to a
    /// nil-scoped canonical run is modern General work and must never move.
    private static func linkLegacyOrphans(to project: Project, records: LegacyOwnershipRecords) -> Int {
        let generalRunIDs = Set(
            records.runRecords
                .filter { $0.projectIDString == nil }
                .map { $0.id.uuidString }
        )
        let generalToolRunIDs = Set(
            records.toolRuns
                .filter { run in
                    guard let runIDString = normalizedUUIDString(run.runIDString) else { return false }
                    return generalRunIDs.contains(runIDString)
                }
                .map { $0.id.uuidString }
        )
        func belongsToGeneralRun(_ sourceRunID: String?) -> Bool {
            guard let sourceRunID = normalizedUUIDString(sourceRunID) else { return false }
            return generalToolRunIDs.contains(sourceRunID)
        }

        var count = 0
        for run in records.toolRuns where run.project == nil && !generalRunIDs.contains(normalizedUUIDString(run.runIDString) ?? "") {
            run.project = project
            count += 1
        }
        for command in records.terminalCommands
            where command.project == nil && !belongsToGeneralRun(command.sourceToolRunIDString) {
            command.project = project
            count += 1
        }
        for artifact in records.artifacts
            where artifact.project == nil && !belongsToGeneralRun(artifact.sourceToolRunIDString) {
            artifact.project = project
            count += 1
        }
        for change in records.fileChanges
            where change.project == nil && !belongsToGeneralRun(change.sourceToolRunIDString) {
            change.project = project
            count += 1
        }
        for event in records.events where event.project == nil {
            event.project = project
            count += 1
        }
        return count
    }

    /// UUID strings have historically been stored by multiple schema versions.
    /// Normalize valid values before ownership checks so a lowercase legacy
    /// reference cannot pull modern General evidence into a project migration.
    private static func normalizedUUIDString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return UUID(uuidString: trimmed)?.uuidString ?? trimmed
    }

}

/// Project deletion retains transcripts and canonical run receipts in General.
/// Relationship-backed records are nullified by SwiftData; scalar run links
/// need the same policy explicitly so History never strands a deleted UUID.
enum ProjectDeletionRetention {
    static func clearScalarProjectLinks(projectID: UUID, context: ModelContext) {
        let projectIDString = projectID.uuidString
        let runDescriptor = FetchDescriptor<AgentRunRecord>(
            predicate: #Predicate { $0.projectIDString == projectIDString }
        )
        let operationDescriptor = FetchDescriptor<ToolOperationRecord>(
            predicate: #Predicate { $0.projectIDString == projectIDString }
        )
        for record in (try? context.fetch(runDescriptor)) ?? [] {
            record.projectIDString = nil
        }
        for operation in (try? context.fetch(operationDescriptor)) ?? [] {
            operation.projectIDString = nil
        }
    }
}

enum ProjectEventRecorder {
    @discardableResult
    static func record(
        project: Project?,
        kind: ProjectEventKind,
        title: String,
        detail: String = "",
        severity: ProjectEventSeverity = .info,
        sourceType: ProjectEventSourceType? = nil,
        sourceID: UUID? = nil,
        metadata: [String: String] = [:],
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectEvent? {
        guard let project else { return nil }
        let metadataJSON = encodeMetadata(metadata)
        let event = ProjectEvent(
            project: project,
            kind: kind,
            title: title,
            detail: detail,
            severity: severity,
            sourceType: sourceType,
            sourceID: sourceID,
            metadataJSON: metadataJSON,
            createdAt: now
        )
        context.insert(event)
        update(project: project, with: event, now: now)
        ProjectOSRunLedger.apply(event: event, to: project, context: context, now: now)
        return event
    }

    @discardableResult
    static func recordMissionCheckpoint(
        project: Project?,
        trigger: String,
        sourceType: ProjectEventSourceType? = nil,
        sourceID: UUID? = nil,
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectEvent? {
        guard let project else { return nil }
        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        return recordMissionCheckpoint(
            project: project,
            contract: summary.missionContract,
            trigger: trigger,
            sourceType: sourceType,
            sourceID: sourceID,
            context: context,
            now: now
        )
    }

    @discardableResult
    static func recordMissionCheckpoint(
        project: Project?,
        contract: MissionOSContract,
        trigger: String,
        sourceType: ProjectEventSourceType? = nil,
        sourceID: UUID? = nil,
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectEvent? {
        guard let project else { return nil }
        let checkpoint = MissionOSCheckpoint(contract: contract, trigger: trigger)
        return record(
            project: project,
            kind: .missionCheckpoint,
            title: "Mission OS checkpoint: \(contract.decisionLabel)",
            detail: contract.operatorDirective,
            severity: checkpoint.eventSeverity,
            sourceType: sourceType ?? .system,
            sourceID: sourceID,
            metadata: checkpoint.metadata,
            context: context,
            now: now
        )
    }

    @discardableResult
    static func ensureArtifact(
        _ artifact: WorkspaceArtifact,
        project: Project?,
        sourceToolRunID: UUID? = nil,
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectArtifact? {
        let persisted = upsertArtifact(
            artifact,
            project: project,
            sourceToolRunID: sourceToolRunID,
            context: context,
            now: now
        )

        // General is a first-class scope. Persist its evidence, but do not
        // create a project event or mutate a project's mission ledger.
        if let project {
            record(
                project: project,
                kind: .artifactCreated,
                title: artifact.isSwiftGameArtifact ? "Swift game artifact ready" : artifact.isWebPage ? "Web artifact ready" : "Artifact ready",
                detail: artifact.path,
                severity: .success,
                sourceType: .artifact,
                sourceID: persisted.id,
                metadata: ["path": artifact.path, "type": artifact.artifactType.rawValue],
                context: context,
                now: now
            )
        }
        return persisted
    }

    @discardableResult
    static func noteArtifactPreview(
        _ artifact: WorkspaceArtifact,
        project: Project?,
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectArtifact? {
        let persisted = upsertArtifact(
            artifact,
            project: project,
            sourceToolRunID: nil,
            context: context,
            now: now
        )
        if let project {
            record(
                project: project,
                kind: .artifactPreviewed,
                title: artifact.isSwiftGameArtifact ? "Swift game artifact previewed" : artifact.isWebPage ? "Web artifact previewed" : "Artifact previewed",
                detail: artifact.path,
                severity: .info,
                sourceType: .artifact,
                sourceID: persisted.id,
                metadata: ["path": artifact.path, "type": artifact.artifactType.rawValue],
                context: context,
                now: now
            )
        }
        return persisted
    }

    @discardableResult
    static func recordFileChange(
        project: Project?,
        action: String,
        path: String,
        sourceToolRunID: UUID? = nil,
        sourceTerminalCommandID: UUID? = nil,
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectFileChange? {
        let change = ProjectFileChange(
            project: project,
            action: action,
            path: path,
            sourceToolRunID: sourceToolRunID,
            sourceTerminalCommandID: sourceTerminalCommandID,
            createdAt: now
        )
        context.insert(change)

        if let project {
            let event = record(
                project: project,
                kind: .fileChanged,
                title: action,
                detail: path,
                severity: .success,
                sourceType: .workspace,
                sourceID: change.id,
                metadata: ["path": path, "action": action],
                context: context,
                now: now
            )
            change.sourceEventIDString = event?.id.uuidString
        }
        return change
    }

    @discardableResult
    static func recordSettingsChange(
        project: Project?,
        detail: String,
        title: String = "Settings changed",
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectEvent? {
        record(
            project: project,
            kind: .settingsChanged,
            title: title,
            detail: detail,
            severity: .info,
            sourceType: .settings,
            context: context,
            now: now
        )
    }

    private static func update(project: Project, with event: ProjectEvent, now: Date) {
        project.updatedAt = now
        project.lastActivityAt = now
        if event.kind == .missionCheckpoint {
            let metadata = event.metadata
            let directive = metadata["operatorDirective"] ?? event.detail
            let nextAction = metadata["nextAction"] ?? directive
            if event.severity == .running {
                project.status = .running
            } else if event.severity == .success, project.status == .running || project.status == .needsReview {
                project.status = .active
            }
            if event.severity == .success {
                project.blocker = ""
            }
            if !nextAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                project.nextStep = nextAction
            }
            return
        }
        switch event.severity {
        case .failure:
            project.status = .needsReview
            project.blocker = event.title
            project.nextStep = "Review the failed event and retry or continue."
        case .warning:
            if project.status != .needsReview {
                project.status = .active
            }
            project.nextStep = event.title
        case .running:
            project.status = .running
            project.nextStep = event.title
        case .success:
            if project.status == .running || project.status == .needsReview {
                project.status = .active
            }
            if clearsBlocker(event) {
                project.blocker = ""
            }
            if event.kind == .runCompleted {
                project.nextStep = "Review the result or send the next request."
            } else if event.kind == .artifactCreated {
                project.nextStep = "Preview the latest artifact."
            } else if event.kind == .fileChanged {
                project.nextStep = "Verify the latest file change."
            } else if event.kind == .terminalCommand {
                project.nextStep = "Review the command output or run the next check."
            } else if event.kind == .agentProofCreated {
                project.nextStep = "Review the latest proof."
            }
        case .info:
            if project.nextStep.isEmpty {
                project.nextStep = event.title
            }
        }
    }

    private static func clearsBlocker(_ event: ProjectEvent) -> Bool {
        switch event.kind {
        case .runCompleted, .agentProofCreated, .artifactCreated, .fileChanged, .missionCheckpoint:
            return true
        default:
            return false
        }
    }

    private static func upsertArtifact(
        _ artifact: WorkspaceArtifact,
        project: Project?,
        sourceToolRunID: UUID?,
        context: ModelContext,
        now: Date
    ) -> ProjectArtifact {
        let existing = ((try? context.fetch(FetchDescriptor<ProjectArtifact>())) ?? []).first { candidate in
            candidate.path == artifact.path && candidate.project?.id == project?.id
        }
        if let existing {
            existing.updatedAt = now
            existing.type = artifact.artifactType
            existing.kind = ProjectArtifact.kind(for: artifact.artifactType)
            existing.previewMode = artifact.previewMode
            existing.orientationPreference = artifact.orientationPreference
            if artifact.isSwiftGameArtifact {
                existing.status = .playable
                existing.exportStatus = .exported
                existing.aspectRatioValue = 16.0 / 9.0
            }
            if let sourceToolRunID {
                existing.sourceToolRunIDString = sourceToolRunID.uuidString
            }
            return existing
        }

        let persisted = ProjectArtifact(
            project: project,
            path: artifact.path,
            kind: ProjectArtifact.kind(for: artifact.artifactType),
            type: artifact.artifactType,
            description: artifact.isSwiftGameArtifact ? "Playable native Swift game artifact." : "",
            previewMode: artifact.previewMode,
            orientationPreference: artifact.orientationPreference,
            aspectRatio: artifact.isSwiftGameArtifact ? 16.0 / 9.0 : nil,
            status: artifact.isSwiftGameArtifact ? .playable : .generated,
            generatedFiles: [artifact.path],
            exportStatus: artifact.isSwiftGameArtifact ? .exported : .generated,
            sourceToolRunID: sourceToolRunID,
            now: now
        )
        context.insert(persisted)
        return persisted
    }

    private static func encodeMetadata(_ metadata: [String: String]) -> String? {
        guard !metadata.isEmpty,
              JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

enum ProjectMissionStatusKind: String, Equatable {
    case active
    case waiting
    case blocked
    case done

    var displayName: String {
        switch self {
        case .active: "Active"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        case .done: "Done"
        }
    }
}

enum ProjectCommandIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case continueMission
    case planNext
    case verifyWork
    case improveArtifact
    case fixBlocker
    case reviewEvidence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .continueMission: "Continue Mission"
        case .planNext: "Plan Next"
        case .verifyWork: "Verify Work"
        case .improveArtifact: "Improve Artifact"
        case .fixBlocker: "Fix Blocker"
        case .reviewEvidence: "Review Evidence"
        }
    }

    var compactName: String {
        switch self {
        case .continueMission: "Continue"
        case .planNext: "Plan"
        case .verifyWork: "Verify"
        case .improveArtifact: "Artifact"
        case .fixBlocker: "Fix"
        case .reviewEvidence: "Review"
        }
    }

    var instructionFocus: String {
        switch self {
        case .continueMission:
            return "Choose and execute the highest-leverage next project step from the mission, current evidence, and workspace state."
        case .planNext:
            return "Inspect the project state and produce a concrete next-step plan before making changes unless an obvious low-risk action is available."
        case .verifyWork:
            return "Run appropriate checks, inspect recent changes, capture proof, and identify any remaining risk or blocker."
        case .improveArtifact:
            return "Inspect the latest artifact or project output, improve its usefulness and polish, then preview or validate it when possible."
        case .fixBlocker:
            return "Start from the blocker or failure evidence, reproduce or inspect it, patch the smallest useful fix, and verify the result."
        case .reviewEvidence:
            return "Review timeline, proof, artifacts, files, and runs; summarize what matters, then take the next safe action if it is clear."
        }
    }
}

struct ProjectOSPlannedStep: Identifiable, Equatable, Sendable {
    var id: String { key }
    var key: String
    var title: String
    var detail: String
    var reason: String
    var symbolName: String
    var startingStatus: ProjectOSStepStatus
}

enum ProjectOSPlanBuilder {
    static func makeSteps(
        project: Project,
        summary: ProjectMissionSummary,
        intent: ProjectCommandIntent,
        operatorNote: String
    ) -> [ProjectOSPlannedStep] {
        let note = operatorNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let mission = summary.missionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextStep = summary.nextStep.trimmingCharacters(in: .whitespacesAndNewlines)
        let proof = summary.missionContract.proofRequirement.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = mission.isEmpty ? project.mission : mission
        let agentChoice = note.isEmpty ? (nextStep.isEmpty ? intent.instructionFocus : nextStep) : note

        var steps: [ProjectOSPlannedStep] = [
            ProjectOSPlannedStep(
                key: "context",
                title: "Read project context",
                detail: target.isEmpty ? "Load mission, files, timeline, runs, and proof." : target,
                reason: "ProjectOS grounds the run in project-owned state before it acts.",
                symbolName: "doc.text.magnifyingglass",
                startingStatus: .planning
            ),
            ProjectOSPlannedStep(
                key: "plan",
                title: "Create agent plan",
                detail: agentChoice,
                reason: "The plan should come from current evidence instead of a canned checklist.",
                symbolName: "list.bullet.clipboard.fill",
                startingStatus: .pending
            )
        ]

        switch intent {
        case .continueMission:
            steps.append(ProjectOSPlannedStep(
                key: "choose",
                title: "Choose next action",
                detail: nextStep.isEmpty ? "Pick the highest-leverage build step from evidence." : nextStep,
                reason: "The agent chooses the next step from mission, proof, blocker, and run history.",
                symbolName: "arrow.triangle.branch",
                startingStatus: .pending
            ))
            steps.append(ProjectOSPlannedStep(
                key: "execute",
                title: "Execute task",
                detail: "Edit, create, inspect, or run the concrete project action.",
                reason: "Visible work should map to tools, commands, files, or artifacts.",
                symbolName: "hammer.fill",
                startingStatus: .pending
            ))
        case .planNext:
            steps.append(ProjectOSPlannedStep(
                key: "draft-plan",
                title: "Draft task plan",
                detail: "Turn the mission into ordered next tasks, blockers, and proof checks.",
                reason: "ProjectOS needs an inspectable plan before deep work.",
                symbolName: "checklist",
                startingStatus: .pending
            ))
            steps.append(ProjectOSPlannedStep(
                key: "save-direction",
                title: "Save direction",
                detail: "Record the chosen next step so future runs know what to do.",
                reason: "The run should be resumable after relaunch.",
                symbolName: "tray.and.arrow.down.fill",
                startingStatus: .pending
            ))
        case .verifyWork:
            steps.append(ProjectOSPlannedStep(
                key: "verify",
                title: "Run verification",
                detail: proof.isEmpty ? "Use the fastest relevant build, test, screenshot, or smoke check." : proof,
                reason: "Completed work needs durable proof before review.",
                symbolName: "checkmark.shield.fill",
                startingStatus: .pending
            ))
            steps.append(ProjectOSPlannedStep(
                key: "risks",
                title: "Report risks",
                detail: "Name what passed, what changed, and what remains uncertain.",
                reason: "Proof should include remaining limitations.",
                symbolName: "exclamationmark.magnifyingglass",
                startingStatus: .pending
            ))
        case .improveArtifact:
            steps.append(ProjectOSPlannedStep(
                key: "inspect-artifact",
                title: "Inspect artifact",
                detail: summary.latestProofTitle.isEmpty ? "Find the latest project output or file to improve." : summary.latestProofTitle,
                reason: "Artifact work starts from the current proof surface.",
                symbolName: "shippingbox.fill",
                startingStatus: .pending
            ))
            steps.append(ProjectOSPlannedStep(
                key: "polish",
                title: "Polish output",
                detail: "Improve usefulness, clarity, and proof quality before handing it back.",
                reason: "The result should become easier to inspect or ship.",
                symbolName: "wand.and.stars",
                startingStatus: .pending
            ))
        case .fixBlocker:
            steps.append(ProjectOSPlannedStep(
                key: "inspect-blocker",
                title: "Inspect blocker",
                detail: summary.blocker.isEmpty ? "Find the failing run, error, or stuck approval." : summary.blocker,
                reason: "Recovery starts from the evidence that blocked the run.",
                symbolName: "exclamationmark.triangle.fill",
                startingStatus: .pending
            ))
            steps.append(ProjectOSPlannedStep(
                key: "repair",
                title: "Apply fix",
                detail: "Make the smallest useful repair and then verify it.",
                reason: "A blocker should produce a focused recovery path.",
                symbolName: "wrench.adjustable.fill",
                startingStatus: .pending
            ))
        case .reviewEvidence:
            steps.append(ProjectOSPlannedStep(
                key: "review-evidence",
                title: "Review evidence",
                detail: "Read timeline, runs, proof, artifacts, and file changes.",
                reason: "The next decision should be grounded in proof.",
                symbolName: "text.viewfinder",
                startingStatus: .pending
            ))
            steps.append(ProjectOSPlannedStep(
                key: "recommend",
                title: "Recommend action",
                detail: nextStep.isEmpty ? "Summarize what matters and choose the next safe move." : nextStep,
                reason: "ProjectOS should make the next action obvious.",
                symbolName: "lightbulb.fill",
                startingStatus: .pending
            ))
        }

        steps.append(ProjectOSPlannedStep(
            key: "proof",
            title: "Capture proof",
            detail: proof.isEmpty ? "Finish with checks, artifacts, files changed, and any remaining blocker." : proof,
            reason: "Every run should end with visible evidence or a named limitation.",
            symbolName: "checkmark.seal.fill",
            startingStatus: .pending
        ))
        return steps
    }
}

enum ProjectOSIntentDeriver {
    static func makeRunStartIntent(
        project: Project,
        summary: ProjectMissionSummary,
        intent: ProjectCommandIntent,
        operatorNote: String,
        now: Date
    ) -> ProjectOSIntentSnapshot {
        let note = operatorNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = note.isEmpty ? intent.instructionFocus : note
        return ProjectOSIntentSnapshot(
            mode: .readingContext,
            source: .runState,
            confidence: .observed,
            summary: "Reading project context for \(intent.displayName).",
            objectKind: .project,
            objectTitle: project.name,
            objectDetail: summary.missionText,
            filePath: "",
            command: "",
            toolName: "",
            testBuildGate: "",
            artifactPath: "",
            blocker: summary.blocker,
            proof: "",
            reason: reason,
            recommendedAction: summary.nextStep,
            timestamp: now
        )
    }

    static func makeIdleIntent(project: Project, now: Date = Date()) -> ProjectOSIntentSnapshot {
        ProjectOSIntentSnapshot.idle(project: project, now: now)
    }

    static func makeRecoveryIntent(run: ProjectOSRun, now: Date) -> ProjectOSIntentSnapshot {
        ProjectOSIntentSnapshot(
            mode: .stoppedResumable,
            source: .recovery,
            confidence: .observed,
            summary: "Stopped after relaunch; the run can be resumed from ProjectOS.",
            objectKind: .step,
            objectTitle: run.currentAction.isEmpty ? "Recovered ProjectOS run" : run.currentAction,
            objectDetail: run.resumeState,
            filePath: "",
            command: run.currentCommand,
            toolName: "",
            testBuildGate: "",
            artifactPath: run.artifactsSummary,
            blocker: run.blockerReason,
            proof: run.proofSummary,
            reason: run.resumeState.isEmpty ? "The app relaunched before the ProjectOS run completed." : run.resumeState,
            recommendedAction: run.nextStep.isEmpty ? "Resume the project run when ready." : run.nextStep,
            timestamp: now
        )
    }

    static func makeIntent(
        for event: ProjectEvent,
        run: ProjectOSRun,
        project: Project,
        activeStep: ProjectOSStep?,
        now: Date
    ) -> ProjectOSIntentSnapshot {
        let metadata = mergedMetadata(for: event)
        let activeTitle = activeStep?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let eventDetail = clean(event.detail)
        let fallbackObject = activeTitle.isEmpty ? run.currentAction : activeTitle

        switch event.kind {
        case .conversationContinued, .autoContinueStarted:
            return snapshot(
                mode: .readingContext,
                source: .projectEvent,
                confidence: .observed,
                summary: event.title.isEmpty ? "Project run started." : event.title,
                objectKind: .project,
                objectTitle: project.name,
                objectDetail: project.mission,
                reason: eventDetail.isEmpty ? "ProjectOS is loading project-owned mission, history, files, and proof." : eventDetail,
                recommendedAction: run.nextStep.isEmpty ? project.nextStep : run.nextStep,
                now: now
            )
        case .promptQueued:
            return snapshot(
                mode: .planning,
                source: .projectEvent,
                confidence: .observed,
                summary: event.title.isEmpty ? "Prompt queued for ProjectOS." : event.title,
                objectKind: .project,
                objectTitle: project.name,
                objectDetail: eventDetail,
                reason: "ProjectOS queued the run behind the project surface.",
                recommendedAction: run.nextStep.isEmpty ? project.nextStep : run.nextStep,
                now: now
            )
        case .responseSaved where event.severity == .running:
            return snapshot(
                mode: .planning,
                source: .runtimeTrace,
                confidence: .inferred,
                summary: event.title.isEmpty ? "Saving the agent plan." : event.title,
                objectKind: .step,
                objectTitle: fallbackObject.isEmpty ? "Create agent plan" : fallbackObject,
                objectDetail: eventDetail,
                reason: "The runtime saved planning text before tool execution.",
                recommendedAction: run.nextStep,
                now: now
            )
        case .agentPlanCreated:
            return snapshot(
                mode: .planning,
                source: .projectEvent,
                confidence: .observed,
                summary: event.title.isEmpty ? "Agent plan prepared." : event.title,
                objectKind: .step,
                objectTitle: activeTitle.isEmpty ? "Create agent plan" : activeTitle,
                objectDetail: eventDetail,
                reason: eventDetail.isEmpty ? "The agent produced a structured plan from current project evidence." : eventDetail,
                recommendedAction: run.nextStep,
                now: now
            )
        case .toolQueued:
            let tool = metadata["tool"] ?? eventDetail
            return snapshot(
                mode: toolLooksLikeRead(tool) ? .inspectingFiles : .runningTool,
                source: .projectEvent,
                confidence: .observed,
                summary: event.title.isEmpty ? "Tool queued." : event.title,
                objectKind: .tool,
                objectTitle: tool.isEmpty ? "Tool" : tool,
                objectDetail: eventDetail,
                toolName: tool,
                reason: "The runtime selected a concrete tool for the active ProjectOS step.",
                recommendedAction: run.nextStep,
                now: now
            )
        case .toolApprovalRequested:
            let tool = metadata["tool"] ?? metadata["name"] ?? toolName(from: event.title)
            let path = metadata["path"] ?? metadata["file"] ?? pathFromMetadata(metadata)
            return snapshot(
                mode: .waitingApproval,
                source: .toolApproval,
                confidence: .observed,
                summary: event.title.isEmpty ? "Approval needed." : event.title,
                objectKind: .approval,
                objectTitle: tool.isEmpty ? "Approval required" : tool,
                objectDetail: eventDetail,
                filePath: path,
                toolName: tool,
                blocker: eventDetail,
                reason: eventDetail.isEmpty ? "A mutating tool must be reviewed before it can continue." : eventDetail,
                recommendedAction: "Approve or reject the pending tool.",
                now: now
            )
        case .toolApproved:
            let tool = metadata["tool"] ?? metadata["name"] ?? toolName(from: event.title)
            return snapshot(
                mode: .runningTool,
                source: .toolApproval,
                confidence: .observed,
                summary: event.title.isEmpty ? "Approval resolved." : event.title,
                objectKind: .tool,
                objectTitle: tool.isEmpty ? "Approved tool" : tool,
                objectDetail: eventDetail,
                toolName: tool,
                reason: "The approved tool is now running from the ProjectOS approval gate.",
                recommendedAction: run.nextStep,
                now: now
            )
        case .toolRejected:
            return snapshot(
                mode: .stoppedResumable,
                source: .toolApproval,
                confidence: .observed,
                summary: event.title.isEmpty ? "Tool rejected." : event.title,
                objectKind: .approval,
                objectTitle: toolName(from: event.title),
                objectDetail: eventDetail,
                blocker: eventDetail,
                reason: "The user rejected the pending tool before it changed the workspace.",
                recommendedAction: "Review the rejected action or rerun with a safer path.",
                now: now
            )
        case .toolCompleted:
            let tool = metadata["tool"] ?? metadata["name"] ?? toolName(from: event.title)
            return snapshot(
                mode: .runningTool,
                source: .projectEvent,
                confidence: .observed,
                summary: event.title.isEmpty ? "Tool completed." : event.title,
                objectKind: .tool,
                objectTitle: tool.isEmpty ? "Completed tool" : tool,
                objectDetail: eventDetail,
                toolName: tool,
                reason: "A tool finished and ProjectOS is choosing the next visible step.",
                recommendedAction: run.nextStep,
                now: now
            )
        case .terminalCommand:
            let command = metadata["command"] ?? eventDetail
            let mode = commandIntentMode(command)
            return snapshot(
                mode: event.severity == .failure ? .blocked : mode,
                source: .terminalCommand,
                confidence: .observed,
                summary: event.title.isEmpty ? "Terminal command recorded." : event.title,
                objectKind: mode == .runningTests || mode == .verifyingOutput || mode == .capturingScreenshot ? .testBuildGate : .command,
                objectTitle: commandTitle(command),
                objectDetail: command,
                command: command,
                testBuildGate: mode == .runningTests || mode == .verifyingOutput || mode == .capturingScreenshot ? command : "",
                blocker: event.severity == .failure ? eventDetail : "",
                reason: commandReason(command, mode: mode, failed: event.severity == .failure),
                recommendedAction: event.severity == .failure ? "Inspect the failed command output and retry." : run.nextStep,
                now: now
            )
        case .fileChanged:
            let path = metadata["path"] ?? eventDetail
            return snapshot(
                mode: .editingCode,
                source: .fileChange,
                confidence: .observed,
                summary: event.title.isEmpty ? "File changed." : event.title,
                objectKind: .file,
                objectTitle: filename(path),
                objectDetail: path,
                filePath: path,
                reason: "A project-owned file change was recorded in the ledger.",
                recommendedAction: "Verify the latest file change.",
                now: now
            )
        case .artifactCreated, .artifactPreviewed:
            let path = metadata["path"] ?? eventDetail
            return snapshot(
                mode: .producingProof,
                source: .artifact,
                confidence: .observed,
                summary: event.title.isEmpty ? "Artifact ready." : event.title,
                objectKind: .artifact,
                objectTitle: filename(path),
                objectDetail: path,
                artifactPath: path,
                proof: path,
                reason: event.kind == .artifactPreviewed ? "The user opened a project artifact for inspection." : "A project artifact became available as proof.",
                recommendedAction: event.kind == .artifactPreviewed ? run.nextStep : "Preview the latest artifact.",
                now: now
            )
        case .agentProofCreated:
            let failed = event.severity == .failure
            return snapshot(
                mode: failed ? .blocked : .completedProof,
                source: .proof,
                confidence: .observed,
                summary: event.title.isEmpty ? "Agent proof captured." : event.title,
                objectKind: failed ? .blocker : .proof,
                objectTitle: failed ? "Proof failed" : "Agent proof",
                objectDetail: eventDetail,
                blocker: failed ? eventDetail : "",
                proof: failed ? "" : eventDetail,
                reason: failed ? "The proof event recorded a failure." : "The run closed with visible ProjectOS proof.",
                recommendedAction: failed ? "Fix the failed proof path." : project.nextStep,
                now: now
            )
        case .runCompleted:
            return snapshot(
                mode: .summarizingCompletion,
                source: .runState,
                confidence: .observed,
                summary: event.title.isEmpty ? "Run completed." : event.title,
                objectKind: .proof,
                objectTitle: "Completion summary",
                objectDetail: eventDetail,
                proof: eventDetail,
                reason: "The runtime reported a completed ProjectOS run.",
                recommendedAction: project.nextStep,
                now: now
            )
        case .runFailed, .toolFailed:
            return snapshot(
                mode: .blocked,
                source: .runState,
                confidence: .observed,
                summary: event.title.isEmpty ? "Run failed." : event.title,
                objectKind: .blocker,
                objectTitle: event.title.isEmpty ? "Failed evidence" : event.title,
                objectDetail: eventDetail,
                blocker: eventDetail,
                reason: eventDetail.isEmpty ? "The latest runtime event failed." : eventDetail,
                recommendedAction: "Review the failed evidence and retry.",
                now: now
            )
        case .runPaused:
            return snapshot(
                mode: .stoppedResumable,
                source: .runState,
                confidence: .observed,
                summary: event.title.isEmpty ? "Run stopped." : event.title,
                objectKind: .step,
                objectTitle: fallbackObject.isEmpty ? "Stopped ProjectOS run" : fallbackObject,
                objectDetail: eventDetail,
                reason: eventDetail.isEmpty ? "The run paused before completion." : eventDetail,
                recommendedAction: "Resume or retry the project run.",
                now: now
            )
        case .missionCheckpoint:
            return checkpointIntent(event: event, run: run, project: project, activeStep: activeStep, metadata: metadata, now: now)
        default:
            return snapshot(
                mode: run.status.isTerminal ? .summarizingCompletion : .runningTool,
                source: .projectEvent,
                confidence: .inferred,
                summary: event.title.isEmpty ? "Project event recorded." : event.title,
                objectKind: .step,
                objectTitle: fallbackObject.isEmpty ? run.status.displayName : fallbackObject,
                objectDetail: eventDetail,
                reason: eventDetail,
                recommendedAction: run.nextStep.isEmpty ? project.nextStep : run.nextStep,
                now: now
            )
        }
    }

    private static func checkpointIntent(
        event: ProjectEvent,
        run: ProjectOSRun,
        project: Project,
        activeStep: ProjectOSStep?,
        metadata: [String: String],
        now: Date
    ) -> ProjectOSIntentSnapshot {
        let phase = metadata["phase"]?.lowercased() ?? ""
        let mode: ProjectOSIntentMode = {
            if event.severity == .failure { return .blocked }
            if event.severity == .warning { return .waitingApproval }
            if phase.contains("plan") { return .planning }
            if phase.contains("verify") { return .verifyingOutput }
            if phase.contains("proof") { return .producingProof }
            if phase.contains("decide") { return .summarizingCompletion }
            return run.status == .planning ? .planning : .readingContext
        }()
        let activeTitle = activeStep?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return snapshot(
            mode: mode,
            source: .projectEvent,
            confidence: .inferred,
            summary: event.title.isEmpty ? "Mission checkpoint." : event.title,
            objectKind: .step,
            objectTitle: activeTitle.isEmpty ? (metadata["decisionLabel"] ?? mode.displayName) : activeTitle,
            objectDetail: clean(event.detail),
            blocker: event.severity == .failure ? clean(event.detail) : "",
            reason: metadata["operatorDirective"] ?? clean(event.detail),
            recommendedAction: metadata["nextAction"] ?? (run.nextStep.isEmpty ? project.nextStep : run.nextStep),
            now: now
        )
    }

    private static func snapshot(
        mode: ProjectOSIntentMode,
        source: ProjectOSIntentSource,
        confidence: ProjectOSIntentConfidence,
        summary: String,
        objectKind: ProjectOSWorkObjectKind,
        objectTitle: String,
        objectDetail: String,
        filePath: String = "",
        command: String = "",
        toolName: String = "",
        testBuildGate: String = "",
        artifactPath: String = "",
        blocker: String = "",
        proof: String = "",
        reason: String,
        recommendedAction: String,
        now: Date
    ) -> ProjectOSIntentSnapshot {
        ProjectOSIntentSnapshot(
            mode: mode,
            source: source,
            confidence: confidence,
            summary: summary,
            objectKind: objectKind,
            objectTitle: objectTitle,
            objectDetail: objectDetail,
            filePath: filePath,
            command: command,
            toolName: toolName,
            testBuildGate: testBuildGate,
            artifactPath: artifactPath,
            blocker: blocker,
            proof: proof,
            reason: reason,
            recommendedAction: recommendedAction,
            timestamp: now
        )
    }

    private static func mergedMetadata(for event: ProjectEvent) -> [String: String] {
        var metadata = event.metadata
        if let detailMetadata = decodeDictionary(event.detail) {
            for (key, value) in detailMetadata where metadata[key] == nil {
                metadata[key] = value
            }
        }
        return metadata
    }

    private static func decodeDictionary(_ value: String) -> [String: String]? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary.reduce(into: [:]) { result, pair in
            result[pair.key] = "\(pair.value)"
        }
    }

    private static func pathFromMetadata(_ metadata: [String: String]) -> String {
        metadata["path"] ?? metadata["filePath"] ?? metadata["target"] ?? ""
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func filename(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func toolName(from title: String) -> String {
        let pieces = title.split(separator: " ")
        return pieces.last.map(String.init) ?? title
    }

    private static func toolLooksLikeRead(_ tool: String) -> Bool {
        let lower = tool.lowercased()
        return lower.contains("read") || lower.contains("list") || lower.contains("search") || lower.contains("inspect")
    }

    private static func commandIntentMode(_ command: String) -> ProjectOSIntentMode {
        let lower = command.lowercased()
        if lower.contains("screenshot") || lower.contains("simctl io") {
            return .capturingScreenshot
        }
        if lower.contains("test") || lower.contains("xcodebuild") || lower.contains("build") {
            return .runningTests
        }
        if lower.contains("validate") || lower.contains("check") || lower.contains("smoke") || lower.contains("tour") || lower.contains("proof") {
            return .verifyingOutput
        }
        return .runningCommand
    }

    private static func commandTitle(_ command: String) -> String {
        let trimmed = clean(command)
        guard !trimmed.isEmpty else { return "Command" }
        let first = trimmed.split(separator: " ").prefix(2).joined(separator: " ")
        return first.isEmpty ? trimmed : first
    }

    private static func commandReason(_ command: String, mode: ProjectOSIntentMode, failed: Bool) -> String {
        if failed { return "The command failed and now blocks the ProjectOS run." }
        switch mode {
        case .runningTests:
            return "A build or test command is checking the current work."
        case .verifyingOutput:
            return "A verification command is producing durable evidence."
        case .capturingScreenshot:
            return "A screenshot command is capturing visual proof."
        default:
            return "A terminal command is running or has just completed for the active step."
        }
    }
}

enum ProjectOSRunLedger {
    @discardableResult
    static func startRun(
        project: Project,
        summary: ProjectMissionSummary,
        intent: ProjectCommandIntent,
        operatorNote: String,
        sourceConversationID: UUID?,
        origin: ProjectOSRunOrigin,
        context: ModelContext,
        now: Date = Date()
    ) -> ProjectOSRun {
        let run = ProjectOSRun(
            project: project,
            projectName: project.name,
            mission: summary.missionText,
            status: .planning,
            origin: origin,
            sourceConversationID: sourceConversationID,
            now: now
        )
        run.currentAction = "Reading project context"
        run.currentCommand = intent.displayName
        run.nextStep = summary.nextStep
        run.latestEventTitle = "ProjectOS run started"
        run.latestEventDetail = intent.instructionFocus
        context.insert(run)
        if !project.projectOSRuns.contains(where: { $0.id == run.id }) {
            project.projectOSRuns.append(run)
        }

        let plannedSteps = ProjectOSPlanBuilder.makeSteps(
            project: project,
            summary: summary,
            intent: intent,
            operatorNote: operatorNote
        )
        for (index, plannedStep) in plannedSteps.enumerated() {
            let step = ProjectOSStep(
                run: run,
                key: plannedStep.key,
                orderIndex: index,
                title: plannedStep.title,
                detail: plannedStep.detail,
                reason: plannedStep.reason,
                status: plannedStep.startingStatus,
                command: index == 0 ? intent.displayName : "",
                now: now
            )
            context.insert(step)
            run.steps.append(step)
        }
        run.currentAction = sortedSteps(for: run).first?.title ?? run.currentAction
        run.nextStep = sortedSteps(for: run).dropFirst().first?.title ?? summary.nextStep
        run.applyIntent(ProjectOSIntentDeriver.makeRunStartIntent(
            project: project,
            summary: summary,
            intent: intent,
            operatorNote: operatorNote,
            now: now
        ))
        return run
    }

    static func apply(
        event: ProjectEvent,
        to project: Project,
        context: ModelContext,
        now: Date = Date()
    ) {
        guard shouldApply(event) else { return }
        guard let run = runForEvent(event, project: project, context: context, now: now) else { return }

        run.projectName = project.name
        run.mission = project.mission
        run.latestEventTitle = event.title
        run.latestEventDetail = event.detail
        run.progressEventCount += 1
        run.updatedAt = now

        switch event.kind {
        case .conversationContinued, .autoContinueStarted:
            run.status = .planning
            run.planningState = "Starting project run"
            run.currentAction = event.title.isEmpty ? "Starting project run" : event.title
            run.nextStep = event.detail.isEmpty ? project.nextStep : event.detail
            markStep(run, keys: ["context"], status: .planning, result: event.detail, now: now)
        case .promptQueued where event.severity == .running:
            run.status = .planning
            run.planningState = "Prompt queued behind ProjectOS"
            run.currentAction = "Preparing project run"
        case .agentPlanCreated:
            run.status = .running
            run.planningState = "Agent-authored plan recorded"
            run.currentAction = event.title.isEmpty ? "Agent plan created" : event.title
            run.nextStep = nextOpenStep(after: "plan", in: run)?.title ?? project.nextStep
            markStep(run, keys: ["context", "plan", "draft-plan"], status: .completed, result: event.detail, now: now)
            markNextOpenStepRunning(run, detail: event.detail, now: now)
        case .missionCheckpoint:
            applyMissionCheckpoint(event, to: run, project: project, now: now)
        case .responseSaved where event.severity == .running:
            run.status = .planning
            run.currentAction = event.title.isEmpty ? "Saving agent plan" : event.title
            markStep(run, keys: ["plan"], status: .planning, result: event.detail, now: now)
        case .toolQueued:
            run.status = .running
            run.currentAction = event.title.isEmpty ? "Tool queued" : event.title
            run.currentCommand = event.detail
            markNextOpenStepRunning(run, detail: event.detail, now: now)
        case .toolApprovalRequested:
            run.status = .waiting
            run.waitingReason = event.detail.isEmpty ? event.title : event.detail
            run.currentAction = event.title.isEmpty ? "Waiting for approval" : event.title
            run.currentCommand = event.detail
            markActiveStep(run, status: .waiting, result: run.waitingReason, now: now)
        case .toolApproved:
            run.status = .running
            run.waitingReason = ""
            run.currentAction = event.title.isEmpty ? "Approval resolved" : event.title
            markActiveStep(run, status: .running, result: event.detail, now: now)
        case .toolRejected:
            run.status = .stopped
            run.resumeState = "Rejected approval can be retried after review."
            run.completedAt = now
            run.currentAction = event.title.isEmpty ? "Tool rejected" : event.title
            markActiveStep(run, status: .stopped, result: event.detail, now: now)
        case .toolCompleted:
            run.status = .running
            run.currentAction = event.title.isEmpty ? "Tool completed" : event.title
            run.currentCommand = event.detail
            markStep(run, keys: ["execute", "repair", "polish"], status: .completed, result: event.detail, now: now)
            markNextOpenStepRunning(run, detail: event.detail, now: now)
        case .terminalCommand:
            run.currentCommand = event.metadata["command"] ?? event.detail
            if event.severity == .failure {
                fail(run, reason: event.detail.isEmpty ? event.title : event.detail, now: now)
            } else {
                run.status = .running
                run.currentAction = event.title.isEmpty ? "Command completed" : event.title
                let command = run.currentCommand.lowercased()
                let keys = command.contains("test") || command.contains("build") || command.contains("validate") || command.contains("screenshot") || command.contains("smoke")
                    ? ["verify", "risks"]
                    : ["execute", "review-evidence"]
                markStep(run, keys: keys, status: .completed, result: event.detail, command: run.currentCommand, now: now)
                markNextOpenStepRunning(run, detail: event.detail, now: now)
            }
        case .fileChanged:
            run.status = .running
            run.changedFilesSummary = event.detail.isEmpty ? event.title : event.detail
            run.currentAction = event.title.isEmpty ? "File changed" : event.title
            markStep(run, keys: ["execute", "repair", "polish", "save-direction"], status: .completed, result: event.detail, now: now)
            markNextOpenStepRunning(run, detail: event.detail, now: now)
        case .artifactCreated, .artifactPreviewed:
            run.status = .running
            run.artifactsSummary = event.detail.isEmpty ? event.title : event.detail
            run.currentAction = event.title.isEmpty ? "Artifact ready" : event.title
            markStep(run, keys: ["proof", "inspect-artifact"], status: event.kind == .artifactCreated ? .completed : .running, result: event.detail, now: now)
        case .agentProofCreated:
            if event.severity == .failure {
                run.proofSummary = event.detail
                fail(run, reason: event.detail.isEmpty ? event.title : event.detail, now: now)
            } else {
                run.status = .completed
                run.proofSummary = event.detail.isEmpty ? event.title : event.detail
                run.currentAction = "Proof captured"
                run.nextStep = project.nextStep
                run.completedAt = now
                completeOpenSteps(run, result: run.proofSummary, now: now)
            }
        case .runCompleted:
            run.status = .completed
            run.proofSummary = run.proofSummary.isEmpty ? (event.detail.isEmpty ? event.title : event.detail) : run.proofSummary
            run.currentAction = "Run complete"
            run.nextStep = project.nextStep
            run.completedAt = now
            completeOpenSteps(run, result: run.proofSummary, now: now)
        case .runFailed, .toolFailed:
            fail(run, reason: event.detail.isEmpty ? event.title : event.detail, now: now)
        case .runPaused:
            run.status = .stopped
            run.resumeState = event.detail.isEmpty ? "Stopped before completion." : event.detail
            run.currentAction = event.title.isEmpty ? "Run stopped" : event.title
            run.completedAt = now
            markActiveStep(run, status: .stopped, result: run.resumeState, now: now)
        default:
            break
        }

        run.applyIntent(ProjectOSIntentDeriver.makeIntent(
            for: event,
            run: run,
            project: project,
            activeStep: activeStep(for: run),
            now: now
        ))
    }

    private static func shouldApply(_ event: ProjectEvent) -> Bool {
        switch event.kind {
        case .conversationContinued, .promptQueued, .agentPlanCreated, .agentProofCreated, .missionCheckpoint,
             .responseSaved, .toolQueued, .toolApprovalRequested, .toolApproved, .toolRejected,
             .toolCompleted, .toolFailed, .runCompleted, .runFailed, .runPaused, .artifactCreated,
             .artifactPreviewed, .fileChanged, .terminalCommand, .autoContinueStarted:
            return true
        default:
            return false
        }
    }

    private static func runForEvent(
        _ event: ProjectEvent,
        project: Project,
        context: ModelContext,
        now: Date
    ) -> ProjectOSRun? {
        let runs = project.projectOSRuns.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.createdAt > rhs.createdAt
        }
        if let sourceID = event.sourceIDString,
           event.sourceType == .conversation,
           let matching = runs.first(where: { $0.sourceConversationIDString == sourceID && !$0.status.isTerminal }) {
            return matching
        }
        if let open = runs.first(where: { !$0.status.isTerminal }) {
            return open
        }
        guard shouldSynthesizeRun(for: event) else { return nil }
        return synthesizeRun(for: event, project: project, context: context, now: now)
    }

    private static func shouldSynthesizeRun(for event: ProjectEvent) -> Bool {
        switch event.kind {
        case .agentPlanCreated, .toolApprovalRequested, .runCompleted, .runFailed, .runPaused, .autoContinueStarted:
            return true
        case .promptQueued:
            return event.severity == .running
        default:
            return false
        }
    }

    private static func synthesizeRun(
        for event: ProjectEvent,
        project: Project,
        context: ModelContext,
        now: Date
    ) -> ProjectOSRun {
        let sourceConversationID = event.sourceType == .conversation ? event.sourceIDString.flatMap { UUID(uuidString: $0) } : nil
        let run = ProjectOSRun(
            project: project,
            projectName: project.name,
            mission: project.mission,
            status: .planning,
            origin: .recovered,
            sourceConversationID: sourceConversationID,
            now: now
        )
        context.insert(run)
        if !project.projectOSRuns.contains(where: { $0.id == run.id }) {
            project.projectOSRuns.append(run)
        }
        let steps = [
            ProjectOSPlannedStep(key: "context", title: "Read project context", detail: project.mission, reason: "Recovered from persisted project events.", symbolName: "doc.text.magnifyingglass", startingStatus: .completed),
            ProjectOSPlannedStep(key: "plan", title: "Create agent plan", detail: event.detail, reason: "Recovered from the event ledger.", symbolName: "list.bullet.clipboard.fill", startingStatus: .planning),
            ProjectOSPlannedStep(key: "execute", title: "Execute visible work", detail: "Tools, files, commands, or artifacts advance this step.", reason: "Runtime events supply the proof trail.", symbolName: "hammer.fill", startingStatus: .pending),
            ProjectOSPlannedStep(key: "verify", title: "Verify work", detail: "Run a check, build, test, screenshot, or proof review.", reason: "Verification keeps ProjectOS honest.", symbolName: "checkmark.shield.fill", startingStatus: .pending),
            ProjectOSPlannedStep(key: "proof", title: "Capture proof", detail: "Summarize results, files, artifacts, commands, and limitations.", reason: "ProjectOS completes with proof.", symbolName: "checkmark.seal.fill", startingStatus: .pending)
        ]
        for (index, planned) in steps.enumerated() {
            let step = ProjectOSStep(
                run: run,
                key: planned.key,
                orderIndex: index,
                title: planned.title,
                detail: planned.detail,
                reason: planned.reason,
                status: planned.startingStatus,
                now: now
            )
            context.insert(step)
            run.steps.append(step)
        }
        return run
    }

    private static func applyMissionCheckpoint(
        _ event: ProjectEvent,
        to run: ProjectOSRun,
        project: Project,
        now: Date
    ) {
        let metadata = event.metadata
        let nextAction = metadata["nextAction"] ?? project.nextStep
        run.currentAction = event.title.isEmpty ? "Mission checkpoint" : event.title
        run.nextStep = nextAction
        if let phase = metadata["phase"] {
            run.planningState = phase.capitalized
        }
        switch event.severity {
        case .failure:
            fail(run, reason: event.detail.isEmpty ? event.title : event.detail, now: now)
        case .warning:
            run.status = .waiting
            run.waitingReason = event.detail
            markActiveStep(run, status: .waiting, result: event.detail, now: now)
        case .running:
            run.status = .running
            markNextOpenStepRunning(run, detail: event.detail, now: now)
        case .success, .info:
            if !run.status.isTerminal {
                run.status = .running
            }
        }
    }

    private static func fail(_ run: ProjectOSRun, reason: String, now: Date) {
        run.status = .failed
        run.failureReason = reason
        run.blockerReason = reason
        run.currentAction = "Blocked by failed evidence"
        run.completedAt = now
        markActiveStep(run, status: .failed, result: reason, now: now)
    }

    private static func sortedSteps(for run: ProjectOSRun) -> [ProjectOSStep] {
        run.steps.sorted { lhs, rhs in
            if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private static func activeStep(for run: ProjectOSRun) -> ProjectOSStep? {
        sortedSteps(for: run).first {
            $0.status == .running || $0.status == .planning || $0.status == .waiting || $0.status == .blocked
        } ?? sortedSteps(for: run).first { !$0.status.isTerminal } ?? sortedSteps(for: run).last
    }

    private static func nextOpenStep(after key: String, in run: ProjectOSRun) -> ProjectOSStep? {
        let steps = sortedSteps(for: run)
        guard let index = steps.firstIndex(where: { $0.key == key }) else {
            return steps.first(where: { !$0.status.isTerminal })
        }
        return steps.dropFirst(index + 1).first { !$0.status.isTerminal }
    }

    private static func markNextOpenStepRunning(_ run: ProjectOSRun, detail: String, now: Date) {
        guard let step = sortedSteps(for: run).first(where: { !$0.status.isTerminal }) else { return }
        mark(step, status: .running, result: detail, now: now)
        run.currentAction = step.title
        run.nextStep = nextOpenStep(after: step.key, in: run)?.title ?? run.nextStep
    }

    private static func markActiveStep(_ run: ProjectOSRun, status: ProjectOSStepStatus, result: String, now: Date) {
        let active = sortedSteps(for: run).first { $0.status == .running || $0.status == .planning || $0.status == .waiting } ??
            sortedSteps(for: run).first { !$0.status.isTerminal }
        guard let active else { return }
        mark(active, status: status, result: result, now: now)
    }

    private static func markStep(
        _ run: ProjectOSRun,
        keys: [String],
        status: ProjectOSStepStatus,
        result: String,
        command: String = "",
        now: Date
    ) {
        guard let step = sortedSteps(for: run).first(where: { keys.contains($0.key) && !$0.status.isTerminal }) ??
            sortedSteps(for: run).first(where: { keys.contains($0.key) }) else { return }
        mark(step, status: status, result: result, command: command, now: now)
    }

    private static func mark(
        _ step: ProjectOSStep,
        status: ProjectOSStepStatus,
        result: String,
        command: String = "",
        now: Date
    ) {
        step.status = status
        if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            step.resultSummary = result
        }
        if !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            step.command = command
        }
        if step.startedAt == nil, status != .pending {
            step.startedAt = now
        }
        if status.isTerminal {
            step.completedAt = now
            if status == .completed {
                step.proof = result
            }
        }
        step.updatedAt = now
    }

    private static func completeOpenSteps(_ run: ProjectOSRun, result: String, now: Date) {
        for step in sortedSteps(for: run) where !step.status.isTerminal {
            mark(step, status: .completed, result: result, now: now)
        }
    }
}

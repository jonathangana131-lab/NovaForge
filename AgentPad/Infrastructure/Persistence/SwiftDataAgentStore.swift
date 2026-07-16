import AgentDomain
import AgentEngine
import AgentProviders
import AgentStore
import AgentTools
import CryptoKit
import Foundation
import SwiftData

enum SwiftDataAgentStoreBoundary: Sendable {
    case beforeSave(AgentStoreOperation)
}

typealias SwiftDataAgentStoreFailureInjector = @Sendable (SwiftDataAgentStoreBoundary) throws -> Void

enum SwiftDataLegacyIdentityKind: String, Equatable, Sendable {
    case run
    case message
    case conversation
    case project
    case tool
    case projectOSRun
}

/// V1 model identifiers predate uniqueness constraints. Projection code must
/// never pick an arbitrary row when a damaged store contains duplicates.
enum SwiftDataAgentStoreIntegrityError: Error, Equatable, Sendable {
    case duplicateLegacyIdentity(kind: SwiftDataLegacyIdentityKind, id: UUID)
}

/// Fail-closed validation for the durable user policy that controls which
/// canonical scopes may be recreated in app-facing materialized views.
enum SwiftDataMaterializationDispositionError: Error, Equatable, Sendable {
    case malformedRecord(String)
    case conflictingRecord(String)
    case staleProjectionPlan(expected: String, actual: String)
    case disposedAcceptance(scopeKind: AgentMaterializationDispositionScopeKind, scopeID: UUID)
    case conversationNotFound(UUID)
    case projectNotFound(UUID)
}

/// Immutable policy input shared by a validated journal read and its
/// projection plan. The fingerprint makes the read/commit boundary
/// optimistic-concurrency safe without weakening canonical replay.
struct SwiftDataMaterializationDispositionSnapshot: Equatable, Sendable {
    let suppressedConversationIDs: Set<UUID>
    let rehomedProjectIDs: Set<UUID>
    let fingerprint: String

    static let empty = make(
        suppressedConversationIDs: [],
        rehomedProjectIDs: []
    )

    func suppressesConversation(_ conversationID: UUID) -> Bool {
        suppressedConversationIDs.contains(conversationID)
    }

    func rehomesProject(_ projectID: UUID?) -> Bool {
        projectID.map(rehomedProjectIDs.contains) ?? false
    }

    func effectiveProjectID(_ canonicalProjectID: UUID?) -> UUID? {
        guard let canonicalProjectID,
              !rehomedProjectIDs.contains(canonicalProjectID)
        else { return nil }
        return canonicalProjectID
    }

    fileprivate static func make(
        suppressedConversationIDs: Set<UUID>,
        rehomedProjectIDs: Set<UUID>,
        canonicalEntries: [String]? = nil
    ) -> Self {
        let entries = canonicalEntries ?? (suppressedConversationIDs.map {
            "conversation|\($0.uuidString.lowercased())|suppressChat"
        } + rehomedProjectIDs.map {
            "project|\($0.uuidString.lowercased())|rehomeToGeneral"
        })
        let payload = (["novaforge-materialization-disposition-v1"] + entries.sorted())
            .joined(separator: "\n")
        return Self(
            suppressedConversationIDs: suppressedConversationIDs,
            rehomedProjectIDs: rehomedProjectIDs,
            fingerprint: "sha256:\(SwiftDataAgentStore.sha256(Data(payload.utf8)))"
        )
    }
}

/// Everything the app needs after a project is atomically removed while its
/// durable run receipts are retained in General.
struct SwiftDataProjectDeletionReceipt: Equatable, Sendable {
    let deletedProjectName: String
    let fallbackProjectID: UUID
    let fallbackWorkspaceName: String
    let replacedActiveProject: Bool
}

enum NovaForgeAgentProjection {
    static let canonicalReducer = AgentProjectionID(rawValue: "canonical-reducer")
    static let canonicalReducerVersion = 1
}

struct SwiftDataLegacyAcceptanceProjection: Equatable, Sendable {
    let runID: UUID
    let conversationID: UUID
    let projectID: UUID?
    let workspaceID: UUID
    let workspaceName: String
    let requestMessageID: UUID
    /// Exact user item accepted by the canonical engine. This is checked at
    /// the atomic acceptance boundary but is not copied into legacy UI rows
    /// when a separately classified public summary is available.
    let acceptedRequestText: String
    let requestText: String
    let origin: AgentRunRecordOrigin
    let providerRawValue: String?
    let modelID: String?

    init(
        runID: UUID,
        conversationID: UUID,
        projectID: UUID?,
        workspaceID: UUID,
        workspaceName: String,
        requestMessageID: UUID,
        acceptedRequestText: String? = nil,
        requestText: String,
        origin: AgentRunRecordOrigin = .user,
        providerRawValue: String? = nil,
        modelID: String? = nil
    ) {
        self.runID = runID
        self.conversationID = conversationID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.requestMessageID = requestMessageID
        self.acceptedRequestText = acceptedRequestText ?? requestText
        self.requestText = requestText
        self.origin = origin
        self.providerRawValue = providerRawValue
        self.modelID = modelID
    }
}

struct SwiftDataLegacyRunTransition: Equatable, Sendable {
    let runID: UUID
    let expectedStatus: AgentRunStatus
    let status: AgentRunStatus
    let at: AgentInstant
    let errorKind: AgentRunErrorKind?
    let errorMessage: String?

    init(
        runID: UUID,
        expectedStatus: AgentRunStatus,
        status: AgentRunStatus,
        at: AgentInstant,
        errorKind: AgentRunErrorKind? = nil,
        errorMessage: String? = nil
    ) {
        self.runID = runID
        self.expectedStatus = expectedStatus
        self.status = status
        self.at = at
        self.errorKind = errorKind
        self.errorMessage = errorMessage
    }
}

enum SwiftDataAgentProjectionMutation: Equatable, Sendable {
    case resetLegacyRuns([SwiftDataCanonicalAcceptanceScope])
    case replaceLegacyRun(SwiftDataLegacyRunSnapshot)
    case reconcileLegacyConversations([SwiftDataLegacyConversationReconciliation])
    case pruneProjectOSRuns([SwiftDataCanonicalAcceptanceScope])
    case replaceProjectOSRun(SwiftDataProjectOSRunSnapshot)
    case suppressProjectOSRun(SwiftDataProjectOSRunSuppression)
    case transitionLegacyRun(SwiftDataLegacyRunTransition)
    case verifyLegacyAcceptance(SwiftDataLegacyAcceptanceCheck)
    case setLegacyRunStatus(SwiftDataLegacyRunStatusProjection)
    case updateLegacyRoute(SwiftDataLegacyRouteProjection)
    case upsertLegacyMessage(SwiftDataLegacyMessageProjection)
    case upsertLegacyTool(SwiftDataLegacyToolProjection)
    case upsertApprovalRequest(SwiftDataApprovalRequestProjection)
    case resolveApprovalRequest(SwiftDataApprovalResolutionProjection)
    case insertToolEvidence(SwiftDataToolEvidenceProjection)
    case acceptProjectOSRun(SwiftDataProjectOSAcceptanceProjection)
    case updateProjectOSRun(SwiftDataProjectOSRunProjection)
}

struct SwiftDataProjectOSRunSuppression: Equatable, Sendable {
    let runID: UUID
    let conversationID: UUID
    let projectID: UUID
}

struct SwiftDataLegacyConversationReconciliation: Equatable, Sendable {
    let conversationID: UUID
    let projectedThrough: AgentInstant?
}

struct SwiftDataCanonicalAcceptanceScope: Equatable, Sendable {
    let acceptance: SwiftDataLegacyAcceptanceCheck

    var runID: RunID { RunID(rawValue: acceptance.runID) }
    var conversationID: ConversationID {
        ConversationID(rawValue: acceptance.conversationID)
    }
    var projectID: ProjectID? {
        acceptance.projectID.map { ProjectID(rawValue: $0) }
    }
    var workspaceID: WorkspaceID {
        WorkspaceID(rawValue: acceptance.workspaceID)
    }
}

struct SwiftDataAgentProjectionPlan: Equatable, Sendable {
    let mutations: [SwiftDataAgentProjectionMutation]
    let evidenceProjectIDs: [UUID]
    let expectedDispositionFingerprint: String?

    init(
        mutations: [SwiftDataAgentProjectionMutation],
        evidenceProjectIDs: [UUID] = [],
        expectedDispositionFingerprint: String? = nil
    ) {
        self.mutations = mutations
        self.evidenceProjectIDs = Array(Set(evidenceProjectIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        self.expectedDispositionFingerprint = expectedDispositionFingerprint
    }
}

/// A bounded global batch plus the complete, reducer-validated prefix for each
/// run represented in that batch. Projectors build absolute values from these
/// prefixes instead of replaying state transitions against an existing view.
struct SwiftDataValidatedProjectionBatch: Sendable {
    let batch: AgentProjectionBatch
    let runPrefixes: [RunID: [StoredAgentEvent]]
    let canonicalAcceptanceScopes: [SwiftDataCanonicalAcceptanceScope]
    let materializationDisposition: SwiftDataMaterializationDispositionSnapshot
}

private struct SwiftDataValidatedJournal: Sendable {
    let metadataByRunID: [RunID: AgentStore.AgentRunMetadataRecord]
    let executionCompositionsByRunID: [RunID: AgentRunExecutionComposition]
    let records: [StoredAgentEvent]
    let recordsByRunID: [RunID: [StoredAgentEvent]]
    let highWaterMark: AgentJournalOffset
}

/// Exact immutable inputs required to rebuild one accepted run after launch.
/// Both records are decoded and context-bound in one non-autosaving snapshot.
struct SwiftDataAcceptedRunRecoveryRecord: Equatable, Sendable {
    let metadata: AgentStore.AgentRunMetadataRecord
    let executionComposition: AgentRunExecutionComposition
}

/// App-facing journal capability for exactly one accepted run. Fresh mode owns
/// the legacy projection that must commit atomically with acceptance. Recovery
/// mode owns only the immutable run/composition binding, so it cannot invent a
/// request projection or accidentally accept the run a second time.
struct SwiftDataProjectedRunJournal: AgentEventJournal, Sendable {
    private enum Mode: Sendable {
        case fresh(
            legacyAcceptanceProjection: SwiftDataLegacyAcceptanceProjection,
            executionComposition: AgentRunExecutionComposition
        )
        case recovery(
            runID: RunID,
            executionComposition: AgentRunExecutionComposition
        )

        var runID: RunID {
            switch self {
            case let .fresh(_, composition):
                return composition.runID
            case let .recovery(runID, _):
                return runID
            }
        }

        var executionComposition: AgentRunExecutionComposition {
            switch self {
            case let .fresh(_, composition):
                return composition
            case let .recovery(_, composition):
                return composition
            }
        }
    }

    let store: SwiftDataAgentStore
    private let mode: Mode

    var boundRunID: RunID { mode.runID }
    var executionComposition: AgentRunExecutionComposition {
        mode.executionComposition
    }

    init(
        store: SwiftDataAgentStore,
        legacyAcceptanceProjection: SwiftDataLegacyAcceptanceProjection,
        executionComposition: AgentRunExecutionComposition
    ) throws {
        guard legacyAcceptanceProjection.runID == executionComposition.runID.rawValue,
              legacyAcceptanceProjection.conversationID ==
                  executionComposition.conversationID.rawValue,
              legacyAcceptanceProjection.projectID ==
                  executionComposition.projectID?.rawValue,
              legacyAcceptanceProjection.workspaceID ==
                  executionComposition.workspaceID.rawValue
        else {
            throw AgentStoreError.persistenceFailure(
                operation: .acceptRun,
                code: "projected_journal_run_mismatch"
            )
        }
        do {
            try executionComposition.validate()
        } catch {
            throw AgentStoreError.persistenceFailure(
                operation: .acceptRun,
                code: "execution_composition_invalid"
            )
        }
        self.store = store
        mode = .fresh(
            legacyAcceptanceProjection: legacyAcceptanceProjection,
            executionComposition: executionComposition
        )
    }

    private init(
        store: SwiftDataAgentStore,
        recoveryRecord: SwiftDataAcceptedRunRecoveryRecord
    ) throws {
        do {
            try recoveryRecord.executionComposition.validate(
                matching: recoveryRecord.metadata.context
            )
        } catch {
            throw AgentStoreError.persistenceFailure(
                operation: .readMetadata,
                code: "execution_composition_invalid"
            )
        }
        self.store = store
        mode = .recovery(
            runID: recoveryRecord.metadata.runID,
            executionComposition: recoveryRecord.executionComposition
        )
    }

    /// The only production recovery constructor. It reloads the immutable
    /// record and proves the current executable dependencies are exact before
    /// returning a journal that can append or read the run.
    static func recovering(
        store: SwiftDataAgentStore,
        runID: RunID,
        runtimeBinding: AgentRunExecutionRuntimeBinding
    ) async throws -> Self {
        guard let recoveryRecord = try await store.acceptedRunRecoveryRecord(
            for: runID
        ) else {
            throw AgentStoreError.runNotFound(runID)
        }
        do {
            try recoveryRecord.executionComposition.validateRuntimeBinding(
                runtimeBinding,
                matching: recoveryRecord.metadata.context
            )
        } catch {
            throw AgentStoreError.persistenceFailure(
                operation: .readMetadata,
                code: "execution_composition_runtime_binding_mismatch"
            )
        }
        return try Self(store: store, recoveryRecord: recoveryRecord)
    }

    func accept(_ acceptance: AgentRunAcceptance) async throws -> AgentJournalCommit {
        guard acceptance.metadata.runID == boundRunID,
              acceptance.envelope.runID == boundRunID,
              executionComposition.runID == acceptance.metadata.runID
        else {
            throw AgentStoreError.persistenceFailure(
                operation: .acceptRun,
                code: "projected_journal_run_mismatch"
            )
        }
        guard case let .fresh(legacyAcceptanceProjection, _) = mode else {
            throw AgentStoreError.persistenceFailure(
                operation: .acceptRun,
                code: "recovery_journal_accept_forbidden"
            )
        }
        return try await store.accept(
            acceptance,
            executionComposition: executionComposition,
            legacyProjection: legacyAcceptanceProjection
        )
    }

    func append(_ envelope: AgentEventEnvelope) async throws -> AgentJournalCommit {
        guard envelope.runID == boundRunID else {
            throw AgentStoreError.persistenceFailure(
                operation: .appendEvent,
                code: "projected_journal_run_mismatch"
            )
        }
        return try await store.append(
            envelope,
            expectedExecutionComposition: executionComposition
        )
    }

    func metadata(
        for runID: RunID
    ) async throws -> AgentStore.AgentRunMetadataRecord? {
        guard runID == boundRunID else {
            throw AgentStoreError.persistenceFailure(
                operation: .readMetadata,
                code: "projected_journal_run_mismatch"
            )
        }
        if case .recovery = mode {
            return try await store.metadata(
                for: runID,
                expectedExecutionComposition: executionComposition
            )
        }
        return try await store.metadata(for: runID)
    }

    func acceptedRunRecoveryRecord(
        for runID: RunID
    ) async throws -> SwiftDataAcceptedRunRecoveryRecord? {
        guard runID == boundRunID else {
            throw AgentStoreError.persistenceFailure(
                operation: .readMetadata,
                code: "projected_journal_run_mismatch"
            )
        }
        let record = try await store.acceptedRunRecoveryRecord(for: runID)
        guard record?.executionComposition == executionComposition else {
            throw AgentStoreError.runConflict(runID)
        }
        return record
    }

    func events(
        for runID: RunID,
        after sequence: EventSequence?
    ) async throws -> [StoredAgentEvent] {
        guard runID == boundRunID else {
            throw AgentStoreError.persistenceFailure(
                operation: .readEvents,
                code: "projected_journal_run_mismatch"
            )
        }
        if case .recovery = mode {
            return try await store.events(
                for: runID,
                after: sequence,
                expectedExecutionComposition: executionComposition
            )
        }
        return try await store.events(for: runID, after: sequence)
    }

    func projectionBatch(
        after offset: AgentJournalOffset,
        limit: Int
    ) async throws -> AgentProjectionBatch {
        try await store.projectionBatch(after: offset, limit: limit)
    }

    func loadCursor(
        for projectionID: AgentProjectionID
    ) async throws -> AgentProjectionCursor? {
        try await store.loadCursor(for: projectionID)
    }

    func saveCursor(
        _ cursor: AgentProjectionCursor,
        expectedPreviousOffset: AgentJournalOffset
    ) async throws -> AgentProjectionCursorCommit {
        try await store.saveCursor(
            cursor,
            expectedPreviousOffset: expectedPreviousOffset
        )
    }
}

private actor SwiftDataAgentStoreProcessGate {
    static let shared = SwiftDataAgentStoreProcessGate()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func unlock() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

/// SwiftData-backed canonical event journal.
///
/// The actor serializes offset assignment, idempotency checks, reducer replay,
/// and saves. Every mutating call uses a fresh non-autosaving context so a
/// failed save can be rolled back without leaking partially staged records to
/// the app's rendered `mainContext`.
actor SwiftDataAgentStore {
    private static let eventEncodingName = "agent-event-json"
    private static let metadataEncodingName = "agent-run-metadata-json"
    private static let executionCompositionEncodingName =
        "agent-run-execution-composition-json"
    private static let stateEncodingName = "agent-run-state-json"
    private static let artifactEncodingName = "agent-artifact-reference-json"
    private static let encodingVersion = 1

    private let container: ModelContainer
    private let codec: any AgentEventCodec
    private let now: @Sendable () -> AgentInstant
    private let failureInjector: SwiftDataAgentStoreFailureInjector

    init(
        container: ModelContainer,
        codec: any AgentEventCodec = JSONAgentEventCodec(),
        now: @escaping @Sendable () -> AgentInstant = { AgentInstant(Date()) },
        failureInjector: @escaping SwiftDataAgentStoreFailureInjector = { _ in }
    ) {
        self.container = container
        self.codec = codec
        self.now = now
        self.failureInjector = failureInjector
    }

    func deleteConversationFromHistory(
        conversationID: UUID,
        deletedAt: Date
    ) async throws {
        try await withProcessLock {
            try deleteConversationFromHistoryTransaction(
                conversationID: conversationID,
                deletedAt: deletedAt
            )
        }
    }

    private func deleteConversationFromHistoryTransaction(
        conversationID: UUID,
        deletedAt: Date
    ) throws {
        let operation = AgentStoreOperation.saveProjectionCursor
        let context = makeContext()
        do {
            try validateLegacyIdentityUniqueness(in: context)
            let disposition = try validatedMaterializationDisposition(in: context)
            if disposition.suppressesConversation(conversationID) {
                guard try fetchConversation(id: conversationID, in: context) == nil else {
                    throw SwiftDataMaterializationDispositionError.conflictingRecord(
                        AgentMaterializationDispositionRecord.makeKey(
                            scopeKind: .conversation,
                            scopeID: conversationID
                        )
                    )
                }
                return
            }

            guard let conversation = try fetchConversation(
                id: conversationID,
                in: context
            ) else {
                throw SwiftDataMaterializationDispositionError.conversationNotFound(
                    conversationID
                )
            }
            let deletedInstant = AgentInstant(deletedAt)
            _ = try stageMaterializationDisposition(
                scopeKind: .conversation,
                scopeID: conversationID,
                action: .suppressChat,
                at: deletedInstant,
                validated: disposition,
                in: context
            )
            if let project = conversation.project {
                ProjectEventRecorder.record(
                    project: project,
                    kind: .conversationDeleted,
                    title: "Chat deleted",
                    detail: conversation.title,
                    severity: .info,
                    sourceType: .conversation,
                    sourceID: conversationID,
                    context: context,
                    now: deletedInstant.date
                )
                project.conversations.removeAll { $0.id == conversationID }
            }
            context.delete(conversation)
            try failureInjector(.beforeSave(operation))
            try context.save()
        } catch {
            // This operation owns a fresh, non-autosaving context. Discarding
            // that context is the rollback boundary for an unsaved destructive
            // transaction. Calling `ModelContext.rollback()` after deleting a
            // cascade parent can make SwiftData snapshot a child backed by
            // `_FullFutureBackingData` and trap before the error is returned.
            throw map(error, operation: operation)
        }
    }

    func deleteProjectRetainingRunsInGeneral(
        projectID: UUID,
        deletedAt: Date
    ) async throws -> SwiftDataProjectDeletionReceipt {
        try await withProcessLock {
            try deleteProjectRetainingRunsInGeneralTransaction(
                projectID: projectID,
                deletedAt: deletedAt
            )
        }
    }

    private func deleteProjectRetainingRunsInGeneralTransaction(
        projectID: UUID,
        deletedAt: Date
    ) throws -> SwiftDataProjectDeletionReceipt {
        let operation = AgentStoreOperation.saveProjectionCursor
        let context = makeContext()
        do {
            try validateLegacyIdentityUniqueness(in: context)
            let disposition = try validatedMaterializationDisposition(in: context)
            let allProjects = try context.fetch(FetchDescriptor<Project>())
            let remainingProjects = allProjects.filter { $0.id != projectID }
            if disposition.rehomedProjectIDs.contains(projectID) {
                guard try fetchProject(id: projectID, in: context) == nil,
                      let fallback = preferredFallbackProject(from: remainingProjects)
                else {
                    throw SwiftDataMaterializationDispositionError.conflictingRecord(
                        AgentMaterializationDispositionRecord.makeKey(
                            scopeKind: .project,
                            scopeID: projectID
                        )
                    )
                }
                return SwiftDataProjectDeletionReceipt(
                    deletedProjectName: "Deleted Project",
                    fallbackProjectID: fallback.id,
                    fallbackWorkspaceName: SandboxWorkspace.sanitizedWorkspaceName(
                        fallback.workspaceName
                    ),
                    replacedActiveProject: false
                )
            }

            guard let project = try fetchProject(id: projectID, in: context) else {
                throw SwiftDataMaterializationDispositionError.projectNotFound(projectID)
            }
            let deletedProjectName = project.name

            // Fetch every retained scalar collection before staging changes.
            // Any read failure aborts the transaction rather than silently
            // stranding a deleted project identifier in History or evidence.
            let runRecords = try context.fetch(FetchDescriptor<AgentRunRecord>())
            let operationRecords = try context.fetch(FetchDescriptor<ToolOperationRecord>())
            let artifactRecords = try context.fetch(
                FetchDescriptor<AgentArtifactProjectionRecord>()
            )
            let settingsRecords = try context.fetch(FetchDescriptor<AgentSettings>())
            let projectOSRuns = try context.fetch(FetchDescriptor<ProjectOSRun>())
            let revision = try fetchMaterializedEvidenceRevision(
                projectID: projectID,
                in: context
            )

            let deletedInstant = AgentInstant(deletedAt)
            _ = try stageMaterializationDisposition(
                scopeKind: .project,
                scopeID: projectID,
                action: .rehomeToGeneral,
                at: deletedInstant,
                validated: disposition,
                in: context
            )

            for record in runRecords where normalizedUUID(record.projectIDString) == projectID {
                record.projectID = nil
            }
            for record in operationRecords where normalizedUUID(record.projectIDString) == projectID {
                record.projectID = nil
            }
            for record in artifactRecords where normalizedUUID(record.projectIDString) == projectID {
                record.projectIDString = nil
            }

            // Nullify the relationships explicitly so their General scope is
            // already visible inside this transaction, independent of when
            // SwiftData applies the model's nullify rule.
            for conversation in Array(project.conversations) {
                conversation.project = nil
            }
            for tool in Array(project.toolRuns) {
                tool.project = nil
            }

            for run in projectOSRuns where run.project?.id == projectID {
                guard project.projectOSRuns.contains(where: { $0.id == run.id }) else {
                    throw SwiftDataMaterializationDispositionError.conflictingRecord(
                        "projectos:\(run.id.uuidString.lowercased())"
                    )
                }
                context.delete(run)
            }
            if let revision { context.delete(revision) }

            let fallback: Project
            if let existing = preferredFallbackProject(from: remainingProjects) {
                fallback = existing
            } else {
                let created = Project(
                    name: ProjectBootstrap.defaultProjectName,
                    mission: "Build and verify useful work in NovaForge.",
                    workspaceName: "Default",
                    now: deletedInstant.date
                )
                context.insert(created)
                ProjectEventRecorder.record(
                    project: created,
                    kind: .projectCreated,
                    title: "Fallback project created",
                    detail: "NovaForge kept a safe project available after deletion.",
                    severity: .success,
                    sourceType: .system,
                    context: context,
                    now: deletedInstant.date
                )
                fallback = created
            }
            let fallbackWorkspaceName = SandboxWorkspace.sanitizedWorkspaceName(
                fallback.workspaceName
            )
            var replacedActiveProject = false
            for settings in settingsRecords where settings.activeProjectID == projectID {
                settings.activeProjectID = fallback.id
                settings.activeWorkspaceName = fallbackWorkspaceName
                settings.updatedAt = deletedInstant.date
                replacedActiveProject = true
            }

            context.delete(project)
            try failureInjector(.beforeSave(operation))
            try context.save()
            return SwiftDataProjectDeletionReceipt(
                deletedProjectName: deletedProjectName,
                fallbackProjectID: fallback.id,
                fallbackWorkspaceName: fallbackWorkspaceName,
                replacedActiveProject: replacedActiveProject
            )
        } catch {
            context.rollback()
            throw map(error, operation: operation)
        }
    }

    private func preferredFallbackProject(from projects: [Project]) -> Project? {
        projects.sorted { lhs, rhs in
            if lhs.lastActivityAt != rhs.lastActivityAt {
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
            return lhs.createdAt < rhs.createdAt
        }.first
    }

    private func normalizedUUID(_ value: String?) -> UUID? {
        guard let value else { return nil }
        return UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func accept(
        _ acceptance: AgentRunAcceptance,
        executionComposition: AgentRunExecutionComposition,
        legacyProjection: SwiftDataLegacyAcceptanceProjection
    ) async throws -> AgentJournalCommit {
        try await withProcessLock {
            try acceptTransaction(
                acceptance,
                executionComposition: executionComposition,
                legacyProjection: legacyProjection
            )
        }
    }

#if DEBUG
    /// Compatibility seam for persistence/projector tests that predate V4.
    /// Production acceptance is available only through the projected journal,
    /// whose initializer requires an explicit immutable composition.
    func accept(
        _ acceptance: AgentRunAcceptance,
        legacyProjection: SwiftDataLegacyAcceptanceProjection
    ) async throws -> AgentJournalCommit {
        let composition = try Self.debugCompatibilityComposition(
            acceptance: acceptance,
            legacyProjection: legacyProjection
        )
        return try await accept(
            acceptance,
            executionComposition: composition,
            legacyProjection: legacyProjection
        )
    }
#endif

    private func acceptTransaction(
        _ acceptance: AgentRunAcceptance,
        executionComposition: AgentRunExecutionComposition,
        legacyProjection: SwiftDataLegacyAcceptanceProjection
    ) throws -> AgentJournalCommit {
        let operation = AgentStoreOperation.acceptRun
        let context = makeContext()
        do {
            _ = try AgentJournalValidation.validateAcceptance(acceptance)
            do {
                try executionComposition.validate(
                    matching: acceptance.metadata.context
                )
            } catch {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "execution_composition_invalid"
                )
            }
            let disposition = try validatedMaterializationDisposition(in: context)

            let runID = acceptance.metadata.runID
            if let existing = try fetchMetadata(runID: runID, in: context) {
                // Exact retries are successful only against a globally valid
                // ledger; an unrelated gap or reducer-invalid run must not be
                // hidden by the idempotent fast path.
                _ = try validatedJournal(operation: operation, in: context)
                let storedMetadata = try decodeMetadata(existing, operation: operation)
                guard storedMetadata == acceptance.metadata else {
                    throw AgentStoreError.runConflict(runID)
                }
                guard let existingCompositionRecord = try fetchExecutionComposition(
                    runID: runID,
                    in: context
                ) else {
                    throw AgentStoreError.persistenceFailure(
                        operation: operation,
                        code: "execution_composition_missing"
                    )
                }
                let storedComposition = try decodeExecutionComposition(
                    existingCompositionRecord,
                    metadata: storedMetadata,
                    operation: operation
                )
                guard storedComposition == executionComposition else {
                    throw AgentStoreError.runConflict(runID)
                }
                guard let eventRecord = try fetchEvent(
                    eventID: acceptance.envelope.event.header.eventID,
                    in: context
                ) else {
                    throw AgentStoreError.corruptJournal(runID: runID, reason: .emptyLedger)
                }
                let stored = try decodeStoredEvent(eventRecord, operation: operation)
                guard stored.envelope == acceptance.envelope else {
                    throw AgentStoreError.runConflict(runID)
                }
                try validateExistingLegacyAcceptance(
                    legacyProjection,
                    acceptance: acceptance,
                    disposition: disposition,
                    in: context
                )
                return AgentJournalCommit(disposition: .alreadyCommitted, record: stored)
            }

            let orphanedRunRecords = try fetchEvents(
                runID: runID,
                after: nil,
                operation: operation,
                in: context
            )
            guard orphanedRunRecords.isEmpty else {
                throw AgentStoreError.corruptJournal(
                    runID: runID,
                    reason: .metadataMissing
                )
            }
            guard try fetchExecutionComposition(runID: runID, in: context) == nil else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "execution_composition_orphaned"
                )
            }

            if let existingCommand = try fetchMetadata(
                acceptanceCommandID: acceptance.metadata.acceptanceCommandID,
                in: context
            ) {
                let existingMetadata = try decodeMetadata(
                    existingCommand,
                    operation: operation
                )
                throw AgentStoreError.acceptanceCommandConflict(
                    commandID: acceptance.metadata.acceptanceCommandID,
                    existingRunID: existingMetadata.runID,
                    incomingRunID: runID
                )
            }

            if let eventRecord = try fetchEvent(
                eventID: acceptance.envelope.event.header.eventID,
                in: context
            ) {
                let existing = try decodeStoredEvent(eventRecord, operation: operation)
                throw AgentStoreError.eventIDConflict(
                    eventID: acceptance.envelope.event.header.eventID,
                    existingRunID: existing.runID,
                    incomingRunID: acceptance.envelope.runID
                )
            }

            // A brand-new canonical run must never target UI scope the user
            // already deleted. Exact retries above remain legal because the
            // immutable canonical journal was accepted before that policy.
            try validateLegacyAcceptanceBinding(
                legacyProjection,
                acceptance: acceptance
            )
            try rejectDisposedAcceptance(
                conversationID: legacyProjection.conversationID,
                projectID: legacyProjection.projectID,
                disposition: disposition
            )

            let committedAt = now()
            let offset = try nextOffset(in: context, operation: operation)
            let eventRecord = try makeEventRecord(
                envelope: acceptance.envelope,
                offset: offset,
                committedAt: committedAt
            )
            let metadataRecord = try makeMetadataRecord(
                acceptance.metadata,
                createdAt: committedAt
            )
            let executionCompositionRecord = try makeExecutionCompositionRecord(
                executionComposition,
                createdAt: committedAt
            )
            context.insert(metadataRecord)
            context.insert(executionCompositionRecord)
            context.insert(eventRecord)
            try stageLegacyAcceptance(
                legacyProjection,
                acceptance: acceptance,
                in: context
            )
            try failureInjector(.beforeSave(operation))
            try context.save()

            return AgentJournalCommit(
                disposition: .committed,
                record: try decodeStoredEvent(eventRecord, operation: operation)
            )
        } catch {
            context.rollback()
            throw map(error, operation: operation)
        }
    }

    func append(_ envelope: AgentEventEnvelope) async throws -> AgentJournalCommit {
        try await withProcessLock {
            try appendTransaction(
                envelope,
                expectedExecutionComposition: nil
            )
        }
    }

    func append(
        _ envelope: AgentEventEnvelope,
        expectedExecutionComposition: AgentRunExecutionComposition
    ) async throws -> AgentJournalCommit {
        try await withProcessLock {
            try appendTransaction(
                envelope,
                expectedExecutionComposition: expectedExecutionComposition
            )
        }
    }

    private func appendTransaction(
        _ envelope: AgentEventEnvelope,
        expectedExecutionComposition: AgentRunExecutionComposition?
    ) throws -> AgentJournalCommit {
        let operation = AgentStoreOperation.appendEvent
        let context = makeContext()
        do {
            try AgentJournalValidation.validateEnvelope(envelope)
            let runID = envelope.runID
            guard let metadataRecord = try fetchMetadata(runID: runID, in: context) else {
                throw AgentStoreError.runNotFound(runID)
            }
            let runMetadata = try decodeMetadata(metadataRecord, operation: operation)
            if let expectedExecutionComposition {
                guard let compositionRecord = try fetchExecutionComposition(
                    runID: runID,
                    in: context
                ) else {
                    throw AgentStoreError.persistenceFailure(
                        operation: operation,
                        code: "execution_composition_missing"
                    )
                }
                let storedComposition = try decodeExecutionComposition(
                    compositionRecord,
                    metadata: runMetadata,
                    operation: operation
                )
                guard storedComposition == expectedExecutionComposition else {
                    throw AgentStoreError.runConflict(runID)
                }
            }
            guard runMetadata.writerID == envelope.writerID else {
                throw AgentStoreError.writerMismatch(
                    runID: runID,
                    expected: runMetadata.writerID,
                    actual: envelope.writerID
                )
            }

            if let record = try fetchIdempotencyMatch(for: envelope, in: context) {
                _ = try validatedJournal(operation: operation, in: context)
                let existing = try decodeStoredEvent(record, operation: operation)
                guard existing.envelope == envelope else {
                    throw AgentStoreError.idempotencyConflict(
                        runID: runID,
                        writerID: envelope.writerID,
                        key: envelope.idempotencyKey,
                        existingEventID: existing.event.header.eventID,
                        incomingEventID: envelope.event.header.eventID
                    )
                }
                return AgentJournalCommit(disposition: .alreadyCommitted, record: existing)
            }

            if let record = try fetchEvent(eventID: envelope.event.header.eventID, in: context) {
                let existing = try decodeStoredEvent(record, operation: operation)
                throw AgentStoreError.eventIDConflict(
                    eventID: envelope.event.header.eventID,
                    existingRunID: existing.runID,
                    incomingRunID: runID
                )
            }

            if let record = try fetchRunSequenceMatch(for: envelope, in: context) {
                let existing = try decodeStoredEvent(record, operation: operation)
                throw AgentStoreError.sequenceConflict(
                    runID: runID,
                    sequence: envelope.writerSequence,
                    existingEventID: existing.event.header.eventID,
                    incomingEventID: envelope.event.header.eventID
                )
            }

            let priorRecords = try fetchEvents(
                runID: runID,
                after: nil,
                operation: operation,
                in: context
            )
            let priorStored = try priorRecords.map {
                try decodeStoredEvent($0, operation: operation)
            }
            _ = try AgentJournalValidation.validateAppend(
                envelope,
                metadata: runMetadata,
                existingRecords: priorStored
            )

            let committedAt = now()
            let offset = try nextOffset(in: context, operation: operation)
            let record = try makeEventRecord(
                envelope: envelope,
                offset: offset,
                committedAt: committedAt
            )
            context.insert(record)
            try failureInjector(.beforeSave(operation))
            try context.save()

            return AgentJournalCommit(
                disposition: .committed,
                record: try decodeStoredEvent(record, operation: operation)
            )
        } catch {
            context.rollback()
            throw map(error, operation: operation)
        }
    }

    func metadata(for runID: RunID) async throws -> AgentStore.AgentRunMetadataRecord? {
        try await withProcessLock {
            try metadataTransaction(
                for: runID,
                expectedExecutionComposition: nil
            )
        }
    }

    func metadata(
        for runID: RunID,
        expectedExecutionComposition: AgentRunExecutionComposition
    ) async throws -> AgentStore.AgentRunMetadataRecord? {
        try await withProcessLock {
            try metadataTransaction(
                for: runID,
                expectedExecutionComposition: expectedExecutionComposition
            )
        }
    }

    private func metadataTransaction(
        for runID: RunID,
        expectedExecutionComposition: AgentRunExecutionComposition?
    ) throws -> AgentStore.AgentRunMetadataRecord? {
        let operation = AgentStoreOperation.readMetadata
        let context = makeContext()
        do {
            guard let record = try fetchMetadata(runID: runID, in: context) else { return nil }
            let metadata = try decodeMetadata(record, operation: operation)
            if let expectedExecutionComposition {
                guard let compositionRecord = try fetchExecutionComposition(
                    runID: runID,
                    in: context
                ) else {
                    throw AgentStoreError.persistenceFailure(
                        operation: operation,
                        code: "execution_composition_missing"
                    )
                }
                let storedComposition = try decodeExecutionComposition(
                    compositionRecord,
                    metadata: metadata,
                    operation: operation
                )
                guard storedComposition == expectedExecutionComposition else {
                    throw AgentStoreError.runConflict(runID)
                }
            }
            return metadata
        } catch {
            throw map(error, operation: operation)
        }
    }

    func acceptedRunRecoveryRecord(
        for runID: RunID
    ) async throws -> SwiftDataAcceptedRunRecoveryRecord? {
        try await withProcessLock {
            try acceptedRunRecoveryRecordTransaction(for: runID)
        }
    }

    private func acceptedRunRecoveryRecordTransaction(
        for runID: RunID
    ) throws -> SwiftDataAcceptedRunRecoveryRecord? {
        let operation = AgentStoreOperation.readMetadata
        let context = makeContext()
        do {
            let metadataRecord = try fetchMetadata(runID: runID, in: context)
            let compositionRecord = try fetchExecutionComposition(
                runID: runID,
                in: context
            )
            switch (metadataRecord, compositionRecord) {
            case (nil, nil):
                return nil
            case (nil, .some):
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "execution_composition_orphaned"
                )
            case (.some, nil):
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "execution_composition_missing"
                )
            case let (.some(metadataRecord), .some(compositionRecord)):
                let metadata = try decodeMetadata(
                    metadataRecord,
                    operation: operation
                )
                let composition = try decodeExecutionComposition(
                    compositionRecord,
                    metadata: metadata,
                    operation: operation
                )
                return SwiftDataAcceptedRunRecoveryRecord(
                    metadata: metadata,
                    executionComposition: composition
                )
            }
        } catch {
            throw map(error, operation: operation)
        }
    }

    func events(
        for runID: RunID,
        after sequence: EventSequence?
    ) async throws -> [StoredAgentEvent] {
        try await withProcessLock {
            try eventsTransaction(
                for: runID,
                after: sequence,
                expectedExecutionComposition: nil
            )
        }
    }

    func events(
        for runID: RunID,
        after sequence: EventSequence?,
        expectedExecutionComposition: AgentRunExecutionComposition
    ) async throws -> [StoredAgentEvent] {
        try await withProcessLock {
            try eventsTransaction(
                for: runID,
                after: sequence,
                expectedExecutionComposition: expectedExecutionComposition
            )
        }
    }

    private func eventsTransaction(
        for runID: RunID,
        after sequence: EventSequence?,
        expectedExecutionComposition: AgentRunExecutionComposition?
    ) throws -> [StoredAgentEvent] {
        let operation = AgentStoreOperation.readEvents
        let context = makeContext()
        do {
            let validated = try validatedJournal(operation: operation, in: context)
            if let expectedExecutionComposition {
                guard validated.metadataByRunID[runID] != nil else {
                    throw AgentStoreError.runNotFound(runID)
                }
                guard let storedComposition =
                    validated.executionCompositionsByRunID[runID]
                else {
                    throw AgentStoreError.persistenceFailure(
                        operation: operation,
                        code: "execution_composition_missing"
                    )
                }
                guard storedComposition == expectedExecutionComposition else {
                    throw AgentStoreError.runConflict(runID)
                }
            }
            let records = validated.recordsByRunID[runID] ?? []
            guard let sequence else { return records }
            guard Int64(exactly: sequence.rawValue) != nil else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "sequence_out_of_range"
                )
            }
            return records.filter { $0.envelope.writerSequence > sequence }
        } catch {
            throw map(error, operation: operation)
        }
    }

    /// One validated ledger read for a bounded collection of exact run IDs.
    /// Forge uses this after indexed scope discovery so rendering N activity
    /// groups does not perform N complete canonical-journal validations.
    func events(
        forOrderedRunIDs runIDs: [RunID],
        maximumRunCount: Int
    ) async throws -> [RunID: [StoredAgentEvent]] {
        try await withProcessLock {
            let operation = AgentStoreOperation.readEvents
            guard maximumRunCount > 0,
                  maximumRunCount <= 1_024,
                  runIDs.count <= maximumRunCount,
                  Set(runIDs).count == runIDs.count
            else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "invalid_scoped_run_batch"
                )
            }
            let context = makeContext()
            do {
                let validated = try validatedJournal(
                    operation: operation,
                    in: context
                )
                return Dictionary(uniqueKeysWithValues: runIDs.map { runID in
                    (runID, validated.recordsByRunID[runID] ?? [])
                })
            } catch {
                throw map(error, operation: operation)
            }
        }
    }

    func projectionBatch(
        after offset: AgentJournalOffset,
        limit: Int
    ) async throws -> AgentProjectionBatch {
        try await withProcessLock {
            try validatedProjectionBatchTransaction(
                after: offset,
                limit: limit,
                includeMaterializationDisposition: false
            ).batch
        }
    }

    /// Returns the complete metadata map and bounded canonical event prefix
    /// from one actor/process-lock critical section. Startup recovery uses
    /// this instead of repeatedly invoking `projectionBatch`/`metadata`, each
    /// of which deliberately performs a full ledger validation.
    func acceptedRunRecoverySnapshot(
        limit: Int
    ) async throws -> AgentAcceptedRunRecoverySnapshot {
        try await withProcessLock {
            let operation = AgentStoreOperation.readProjection
            guard limit > 0 else {
                throw AgentStoreError.invalidBatchLimit(limit)
            }
            let context = makeContext()
            do {
                let validated = try validatedJournal(
                    operation: operation,
                    in: context
                )
                return AgentAcceptedRunRecoverySnapshot(
                    batch: AgentProjectionBatch(
                        afterOffset: .origin,
                        highWaterMark: validated.highWaterMark,
                        records: Array(validated.records.prefix(limit))
                    ),
                    metadataByRunID: validated.metadataByRunID
                )
            } catch {
                throw map(error, operation: operation)
            }
        }
    }

    func validatedProjectionBatch(
        after offset: AgentJournalOffset,
        limit: Int
    ) async throws -> SwiftDataValidatedProjectionBatch {
        try await withProcessLock {
            try validatedProjectionBatchTransaction(
                after: offset,
                limit: limit,
                includeMaterializationDisposition: true
            )
        }
    }

    private func validatedProjectionBatchTransaction(
        after offset: AgentJournalOffset,
        limit: Int,
        includeMaterializationDisposition: Bool
    ) throws -> SwiftDataValidatedProjectionBatch {
        let operation = AgentStoreOperation.readProjection
        guard limit > 0 else { throw AgentStoreError.invalidBatchLimit(limit) }
        let context = makeContext()
        do {
            let validated = try validatedJournal(operation: operation, in: context)
            // The protocol-level canonical journal batch remains independent
            // from UI materialization policy. Only the projector-specific
            // validated batch reads and fingerprints dispositions.
            let disposition = includeMaterializationDisposition
                ? try validatedMaterializationDisposition(in: context)
                : .empty
            let highWaterMark = validated.highWaterMark
            guard offset <= highWaterMark else {
                throw AgentStoreError.offsetBeyondHighWaterMark(
                    requested: offset,
                    highWaterMark: highWaterMark
                )
            }
            let records = Array(
                validated.records.lazy
                    .filter { $0.offset > offset }
                    .prefix(limit)
            )
            let batch = AgentProjectionBatch(
                afterOffset: offset,
                highWaterMark: highWaterMark,
                records: records
            )
            let throughOffset = batch.throughOffset
            var prefixes: [RunID: [StoredAgentEvent]] = [:]
            for runID in validated.recordsByRunID.keys {
                let prefix = (validated.recordsByRunID[runID] ?? []).filter {
                    $0.offset <= throughOffset
                }
                if !prefix.isEmpty { prefixes[runID] = prefix }
            }
            let scopes = try validated.recordsByRunID.map { runID, records in
                guard let first = records.first,
                      case let .runAccepted(payload) = first.event.payload
                else {
                    throw AgentStoreError.corruptJournal(
                        runID: runID,
                        reason: .emptyLedger
                    )
                }
                let header = first.event.header
                return SwiftDataCanonicalAcceptanceScope(
                    acceptance: SwiftDataLegacyAcceptanceCheck(
                        runID: runID.rawValue,
                        conversationID: header.conversationID.rawValue,
                        projectID: header.projectID?.rawValue,
                        workspaceID: header.workspaceID.rawValue,
                        requestText: canonicalAcceptedUserText(payload.initialItems)
                    )
                )
            }.sorted { $0.runID.description < $1.runID.description }
            return SwiftDataValidatedProjectionBatch(
                batch: batch,
                runPrefixes: prefixes,
                canonicalAcceptanceScopes: scopes,
                materializationDisposition: disposition
            )
        } catch {
            throw map(error, operation: operation)
        }
    }

    func loadCursor(
        for projectionID: AgentProjectionID
    ) async throws -> AgentProjectionCursor? {
        try await withProcessLock {
            try loadCursorTransaction(for: projectionID)
        }
    }

    private func loadCursorTransaction(
        for projectionID: AgentProjectionID
    ) throws -> AgentProjectionCursor? {
        let operation = AgentStoreOperation.loadProjectionCursor
        let key = try validatedProjectionKey(projectionID)
        let context = makeContext()
        do {
            try validateLegacyIdentityUniqueness(in: context)
            guard let record = try fetchCursor(key: key, in: context) else { return nil }
            let highWaterMark = try validatedJournal(
                operation: operation,
                in: context
            ).highWaterMark
            let cursor = try makeCursor(
                record,
                expectedKey: key,
                operation: operation
            )
            guard cursor.projectionID == projectionID,
                  cursor.throughOffset <= highWaterMark
            else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "projection_cursor_integrity_failed"
                )
            }
            return cursor
        } catch {
            throw map(error, operation: operation)
        }
    }

    func saveCursor(
        _ cursor: AgentProjectionCursor,
        expectedPreviousOffset: AgentJournalOffset
    ) async throws -> AgentProjectionCursorCommit {
        try await withProcessLock {
            try saveCursorTransaction(
                cursor,
                expectedPreviousOffset: expectedPreviousOffset
            )
        }
    }

    private func saveCursorTransaction(
        _ cursor: AgentProjectionCursor,
        expectedPreviousOffset: AgentJournalOffset
    ) throws -> AgentProjectionCursorCommit {
        let operation = AgentStoreOperation.saveProjectionCursor
        let context = makeContext()
        do {
            try validateLegacyIdentityUniqueness(in: context)
            let commit = try stageCursor(
                cursor,
                expectedPreviousOffset: expectedPreviousOffset,
                operation: operation,
                in: context
            )
            guard commit.disposition == .committed else { return commit }
            try failureInjector(.beforeSave(operation))
            try context.save()
            return commit
        } catch {
            context.rollback()
            throw map(error, operation: operation)
        }
    }

    func commitProjection(
        _ plan: SwiftDataAgentProjectionPlan,
        cursor: AgentProjectionCursor,
        expectedPreviousOffset: AgentJournalOffset
    ) async throws -> AgentProjectionCursorCommit {
        try await withProcessLock {
            try commitProjectionTransaction(
                plan,
                cursor: cursor,
                expectedPreviousOffset: expectedPreviousOffset
            )
        }
    }

    private func commitProjectionTransaction(
        _ plan: SwiftDataAgentProjectionPlan,
        cursor: AgentProjectionCursor,
        expectedPreviousOffset: AgentJournalOffset
    ) throws -> AgentProjectionCursorCommit {
        let operation = AgentStoreOperation.saveProjectionCursor
        let context = makeContext()
        do {
            try validateLegacyIdentityUniqueness(in: context)
            let disposition = try validatedMaterializationDisposition(in: context)
            if let expected = plan.expectedDispositionFingerprint,
               expected != disposition.fingerprint {
                throw SwiftDataMaterializationDispositionError.staleProjectionPlan(
                    expected: expected,
                    actual: disposition.fingerprint
                )
            }
            let commit = try stageCursor(
                cursor,
                expectedPreviousOffset: expectedPreviousOffset,
                operation: operation,
                in: context
            )
            guard commit.disposition == .committed else { return commit }
            try applyProjection(plan, disposition: disposition, in: context)
            try advanceMaterializedEvidenceRevisions(
                for: plan.evidenceProjectIDs,
                disposition: disposition,
                in: context
            )
            try failureInjector(.beforeSave(operation))
            try context.save()
            return commit
        } catch {
            context.rollback()
            throw map(error, operation: operation)
        }
    }

    /// Rebuilds canonical run state from the newest verified snapshot and all
    /// later events. A corrupt snapshot or rejected event stops recovery.
    func replay(runID: RunID) async throws -> AgentDomain.AgentRunState {
        try await withProcessLock {
            try replayTransaction(runID: runID)
        }
    }

    private func replayTransaction(runID: RunID) throws -> AgentDomain.AgentRunState {
        let operation = AgentStoreOperation.restoreSnapshot
        let context = makeContext()
        do {
            guard let metadataRecord = try fetchMetadata(runID: runID, in: context) else {
                throw AgentStoreError.runNotFound(runID)
            }
            let metadata = try decodeMetadata(metadataRecord, operation: operation)
            let records = try fetchEvents(
                runID: runID,
                after: nil,
                operation: operation,
                in: context
            ).map {
                try decodeStoredEvent($0, operation: operation)
            }
            let replayed = try AgentJournalReplay.replay(records, metadata: metadata)

            let snapshot = try fetchLatestSnapshot(runID: runID, in: context)
            if let snapshot {
                let cached = try decodeState(snapshot, runID: runID, operation: operation)
                let prefix = records.filter {
                    $0.envelope.writerSequence.rawValue <= UInt64(snapshot.throughSequenceValue)
                }
                guard prefix.last?.envelope.writerSequence.rawValue == UInt64(snapshot.throughSequenceValue),
                      prefix.last?.event.header.eventID.description == snapshot.throughEventIDString,
                      try AgentJournalReplay.replay(prefix, metadata: metadata) == cached
                else {
                    throw AgentStoreError.persistenceFailure(
                        operation: operation,
                        code: "snapshot_replay_mismatch"
                    )
                }
            }
            return replayed
        } catch {
            throw map(error, operation: operation)
        }
    }

    /// Saves a reducer checkpoint only when it names an existing event and the
    /// state's own last-sequence/event fields match that durable boundary.
    func saveSnapshot(
        _ state: AgentDomain.AgentRunState,
        projectionID: AgentProjectionID,
        projectionVersion: Int,
        runID: RunID
    ) async throws {
        try await withProcessLock {
            try saveSnapshotTransaction(
                state,
                projectionID: projectionID,
                projectionVersion: projectionVersion,
                runID: runID
            )
        }
    }

    private func saveSnapshotTransaction(
        _ state: AgentDomain.AgentRunState,
        projectionID: AgentProjectionID,
        projectionVersion: Int,
        runID: RunID
    ) throws {
        let operation = AgentStoreOperation.restoreSnapshot
        let key = try validatedProjectionKey(projectionID)
        let context = makeContext()
        do {
            guard projectionVersion > 0,
                  state.context?.lineage.runID == runID,
                  let sequence = state.lastSequence,
                  let eventID = state.lastEventID,
                  let sequenceValue = Int64(exactly: sequence.rawValue)
            else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "snapshot_boundary_mismatch"
                )
            }
            guard let metadataRecord = try fetchMetadata(runID: runID, in: context) else {
                throw AgentStoreError.runNotFound(runID)
            }
            let metadata = try decodeMetadata(metadataRecord, operation: operation)
            let storedPrefix = try fetchEvents(
                runID: runID,
                after: nil,
                operation: operation,
                in: context
            ).map {
                try decodeStoredEvent($0, operation: operation)
            }.filter {
                $0.envelope.writerSequence.rawValue <= sequence.rawValue
            }
            guard storedPrefix.last?.envelope.writerSequence == sequence,
                  try AgentJournalReplay.replay(storedPrefix, metadata: metadata) == state
            else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "snapshot_state_mismatch"
                )
            }
            guard let eventRecord = try fetchRunSequenceMatch(
                runID: runID,
                sequenceValue: sequenceValue,
                in: context
            ), eventRecord.eventIDString == eventID.description else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "snapshot_event_missing"
                )
            }

            let encoded = try encodeDeterministically(state, operation: operation)
            let digest = Self.sha256(encoded)
            let snapshotKey = ProjectionSnapshotRecord.makeSnapshotKey(
                projectionName: key,
                projectionVersion: projectionVersion,
                runIDString: runID.description,
                throughSequenceValue: sequenceValue
            )
            if let existing = try fetchSnapshot(key: snapshotKey, in: context) {
                guard existing.stateDigest == digest, existing.encodedState == encoded else {
                    throw AgentStoreError.persistenceFailure(
                        operation: operation,
                        code: "snapshot_conflict"
                    )
                }
                return
            }

            context.insert(
                ProjectionSnapshotRecord(
                    projectionName: key,
                    projectionVersion: projectionVersion,
                    runIDString: runID.description,
                    throughSequenceValue: sequenceValue,
                    throughEventIDString: eventID.description,
                    stateEncodingName: Self.stateEncodingName,
                    stateEncodingVersion: Self.encodingVersion,
                    encodedState: encoded,
                    stateDigest: digest,
                    createdAt: now().date
                )
            )
            try failureInjector(.beforeSave(operation))
            try context.save()
        } catch {
            context.rollback()
            throw map(error, operation: operation)
        }
    }
}

private extension SwiftDataAgentStore {
    func withProcessLock<Value: Sendable>(
        _ operation: () throws -> Value
    ) async throws -> Value {
        await SwiftDataAgentStoreProcessGate.shared.lock()
        let result: Result<Value, Error>
        do {
            result = .success(try operation())
        } catch {
            result = .failure(error)
        }
        await SwiftDataAgentStoreProcessGate.shared.unlock()
        return try result.get()
    }

    func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    func stageCursor(
        _ cursor: AgentProjectionCursor,
        expectedPreviousOffset: AgentJournalOffset,
        operation: AgentStoreOperation,
        in context: ModelContext
    ) throws -> AgentProjectionCursorCommit {
        let key = try validatedProjectionKey(cursor.projectionID)
        let requested = cursor.throughOffset
        let highWaterMark = try validatedJournal(
            operation: operation,
            in: context
        ).highWaterMark
        guard requested <= highWaterMark else {
            throw AgentStoreError.cursorBeyondHighWaterMark(
                projectionID: cursor.projectionID,
                requested: requested,
                highWaterMark: highWaterMark
            )
        }

        if let record = try fetchCursor(key: key, in: context) {
            _ = try makeCursor(
                record,
                expectedKey: key,
                operation: operation
            )
            let current = try journalOffset(record.throughOffsetValue, operation: operation)
            guard expectedPreviousOffset == current else {
                throw AgentStoreError.cursorConflict(
                    projectionID: cursor.projectionID,
                    expected: expectedPreviousOffset,
                    actual: current
                )
            }
            if requested == current {
                return AgentProjectionCursorCommit(
                    disposition: .alreadyCommitted,
                    cursor: try makeCursor(
                        record,
                        expectedKey: key,
                        operation: operation
                    )
                )
            }
            guard requested > current else {
                throw AgentStoreError.cursorRegression(
                    projectionID: cursor.projectionID,
                    current: current,
                    requested: requested
                )
            }
            record.throughOffsetValue = try persisted(requested, operation: operation)
            record.updatedAtMilliseconds = cursor.updatedAt.rawValue
            record.updatedAt = cursor.updatedAt.date
            return AgentProjectionCursorCommit(disposition: .committed, cursor: cursor)
        }

        guard expectedPreviousOffset == .origin else {
            throw AgentStoreError.cursorConflict(
                projectionID: cursor.projectionID,
                expected: expectedPreviousOffset,
                actual: .origin
            )
        }
        let record = ProjectionCursorRecord(
            projectionIDString: key,
            throughOffsetValue: try persisted(requested, operation: operation),
            updatedAtMilliseconds: cursor.updatedAt.rawValue,
            updatedAt: cursor.updatedAt.date
        )
        context.insert(record)
        return AgentProjectionCursorCommit(disposition: .committed, cursor: cursor)
    }

    func applyProjection(
        _ plan: SwiftDataAgentProjectionPlan,
        disposition: SwiftDataMaterializationDispositionSnapshot,
        in context: ModelContext
    ) throws {
        for mutation in plan.mutations {
            switch mutation {
            case let .resetLegacyRuns(scope):
                try resetLegacyProjectedState(
                    scope,
                    disposition: disposition,
                    in: context
                )
            case let .replaceLegacyRun(snapshot):
                try replaceLegacyRun(
                    snapshot,
                    disposition: disposition,
                    in: context
                )
            case let .reconcileLegacyConversations(reconciliations):
                try reconcileLegacyConversations(
                    reconciliations,
                    disposition: disposition,
                    in: context
                )
            case let .pruneProjectOSRuns(scope):
                try pruneProjectOSRuns(
                    scope,
                    disposition: disposition,
                    in: context
                )
            case let .replaceProjectOSRun(snapshot):
                if disposition.rehomesProject(snapshot.projectID),
                   let projectID = snapshot.projectID {
                    try suppressProjectOSRun(
                        SwiftDataProjectOSRunSuppression(
                            runID: snapshot.runID,
                            conversationID: snapshot.conversationID,
                            projectID: projectID
                        ),
                        disposition: disposition,
                        in: context
                    )
                } else {
                    try replaceProjectOSRun(snapshot, in: context)
                }
            case let .suppressProjectOSRun(suppression):
                try suppressProjectOSRun(
                    suppression,
                    disposition: disposition,
                    in: context
                )
            case let .transitionLegacyRun(transition):
                guard let run = try fetchLegacyRun(id: transition.runID, in: context) else {
                    throw AgentStoreError.persistenceFailure(
                        operation: .saveProjectionCursor,
                        code: "projection_run_missing"
                    )
                }
                guard run.status == transition.expectedStatus else {
                    throw AgentStoreError.persistenceFailure(
                        operation: .saveProjectionCursor,
                        code: "projection_precondition_failed"
                    )
                }
                run.transition(
                    to: transition.status,
                    at: transition.at.date,
                    errorKind: transition.errorKind,
                    errorMessage: transition.errorMessage
                )
                try stampLegacyRunStatus(
                    transition.status,
                    runID: transition.runID,
                    in: context
                )
            case let .verifyLegacyAcceptance(check):
                try verifyLegacyAcceptance(
                    check,
                    disposition: disposition,
                    in: context
                )
            case let .setLegacyRunStatus(projection):
                try setLegacyRunStatus(projection, in: context)
            case let .updateLegacyRoute(projection):
                try updateLegacyRoute(projection, in: context)
            case let .upsertLegacyMessage(projection):
                if !disposition.suppressesConversation(projection.conversationID) {
                    try upsertLegacyMessage(projection, in: context)
                }
            case let .upsertLegacyTool(projection):
                try upsertLegacyTool(
                    SwiftDataLegacyToolProjection(
                        callID: projection.callID,
                        runID: projection.runID,
                        projectID: disposition.effectiveProjectID(projection.projectID),
                        sequence: projection.sequence,
                        name: projection.name,
                        argumentsJSON: projection.argumentsJSON,
                        outputJSON: projection.outputJSON,
                        status: projection.status,
                        requiresApproval: projection.requiresApproval,
                        isMutating: projection.isMutating,
                        occurredAt: projection.occurredAt
                    ),
                    in: context
                )
            case let .upsertApprovalRequest(projection):
                try upsertApprovalRequest(projection, in: context)
            case let .resolveApprovalRequest(projection):
                try resolveApprovalRequest(projection, in: context)
            case let .insertToolEvidence(projection):
                try insertToolEvidence(projection, in: context)
            case let .acceptProjectOSRun(projection):
                if disposition.rehomesProject(projection.projectID),
                   let projectID = projection.projectID {
                    try suppressProjectOSRun(
                        SwiftDataProjectOSRunSuppression(
                            runID: projection.runID,
                            conversationID: projection.conversationID,
                            projectID: projectID
                        ),
                        disposition: disposition,
                        in: context
                    )
                } else {
                    try acceptProjectOSRun(projection, in: context)
                }
            case let .updateProjectOSRun(projection):
                if !disposition.rehomesProject(projection.projectID) {
                    try updateProjectOSRun(projection, in: context)
                }
            }
        }
    }

    func advanceMaterializedEvidenceRevisions(
        for projectIDs: [UUID],
        disposition: SwiftDataMaterializationDispositionSnapshot,
        in context: ModelContext
    ) throws {
        for projectID in projectIDs where !disposition.rehomedProjectIDs.contains(projectID) {
            guard try fetchProject(id: projectID, in: context) != nil else {
                throw AgentStoreError.persistenceFailure(
                    operation: .saveProjectionCursor,
                    code: "projection_evidence_project_missing"
                )
            }

            if let record = try fetchMaterializedEvidenceRevision(
                projectID: projectID,
                in: context
            ) {
                let nextRevision = record.revision.addingReportingOverflow(1)
                guard !nextRevision.overflow else {
                    throw AgentStoreError.persistenceFailure(
                        operation: .saveProjectionCursor,
                        code: "projection_evidence_revision_overflow"
                    )
                }
                record.revision = nextRevision.partialValue
            } else {
                context.insert(ProjectMaterializedEvidenceRevisionRecord(
                    projectID: projectID,
                    revision: 1
                ))
            }
        }
    }

    /// Removes only state owned by the asynchronous legacy projector. The
    /// acceptance run and request message were committed atomically with the
    /// journal and remain as the durable baseline for a run beyond this
    /// projection cursor.
    func resetLegacyProjectedState(
        _ scopes: [SwiftDataCanonicalAcceptanceScope],
        disposition: SwiftDataMaterializationDispositionSnapshot,
        in context: ModelContext
    ) throws {
        for scope in scopes {
            let runID = scope.runID.rawValue
            try verifyLegacyAcceptance(
                scope.acceptance,
                disposition: disposition,
                in: context
            )
            guard let run = try fetchLegacyRun(id: runID, in: context) else {
                throw projectionFailure("projection_run_missing")
            }
            run.projectID = disposition.effectiveProjectID(scope.acceptance.projectID)
            run.status = .queued
            run.queuedAt = run.createdAt
            run.startedAt = nil
            run.updatedAt = run.createdAt
            run.completedAt = nil
            run.responseMessageID = nil
            run.provider = nil
            run.modelID = nil
            run.errorKind = nil
            run.errorMessage = nil

            let runIDString = runID.uuidString
            let requestMessageID = run.requestMessageID
            let messages = try context.fetch(
                FetchDescriptor<ChatMessage>(
                    predicate: #Predicate { message in
                        message.runIDString == runIDString
                    }
                )
            )
            try requireUniqueLegacyIDs(
                messages.map(\.id),
                kind: .message
            )
            for message in messages {
                if !disposition.suppressesConversation(scope.acceptance.conversationID),
                   message.id == requestMessageID {
                    message.runSequence = 0
                    message.runStatus = .queued
                } else {
                    message.conversation?.messages.removeAll { $0.id == message.id }
                    context.delete(message)
                }
            }

            let tools = try context.fetch(
                FetchDescriptor<ToolRun>(
                    predicate: #Predicate { tool in
                        tool.runIDString == runIDString
                    }
                )
            )
            try requireUniqueLegacyIDs(
                tools.map(\.id),
                kind: .tool
            )
            for tool in tools {
                tool.project?.toolRuns.removeAll { $0.id == tool.id }
                context.delete(tool)
            }

            let normalizedRunID = runID.uuidString.lowercased()
            for approval in try context.fetch(
                FetchDescriptor<ApprovalRequestRecord>(
                    predicate: #Predicate { row in
                        row.runIDString == normalizedRunID
                    }
                )
            ) {
                context.delete(approval)
            }
            for evidence in try context.fetch(
                FetchDescriptor<ToolEffectEvidenceRecord>(
                    predicate: #Predicate { row in
                        row.runIDString == normalizedRunID
                    }
                )
            ) {
                context.delete(evidence)
            }
            for artifact in try context.fetch(
                FetchDescriptor<AgentArtifactProjectionRecord>(
                    predicate: #Predicate { row in
                        row.runIDString == normalizedRunID
                    }
                )
            ) {
                context.delete(artifact)
            }
        }
    }

    func reconcileLegacyConversations(
        _ reconciliations: [SwiftDataLegacyConversationReconciliation],
        disposition: SwiftDataMaterializationDispositionSnapshot,
        in context: ModelContext
    ) throws {
        for reconciliation in reconciliations where
            !disposition.suppressesConversation(reconciliation.conversationID) {
            guard let conversation = try fetchConversation(
                id: reconciliation.conversationID,
                in: context
            ) else {
                throw projectionFailure("projection_conversation_missing")
            }
            let messageTimestamp = conversation.messages.map(\.createdAt).max()
            let projectedTimestamp = reconciliation.projectedThrough?.date
            let candidates = [conversation.createdAt, messageTimestamp, projectedTimestamp]
                .compactMap { $0 }
            conversation.refreshMessageMetadata(
                updateTimestamp: candidates.max() ?? conversation.createdAt
            )
        }
    }

    func pruneProjectOSRuns(
        _ scopes: [SwiftDataCanonicalAcceptanceScope],
        disposition: SwiftDataMaterializationDispositionSnapshot,
        in context: ModelContext
    ) throws {
        for scope in scopes {
            let runID = scope.runID.rawValue
            if disposition.rehomesProject(scope.projectID?.rawValue),
               let projectID = scope.projectID?.rawValue {
                try suppressProjectOSRun(
                    SwiftDataProjectOSRunSuppression(
                        runID: runID,
                        conversationID: scope.conversationID.rawValue,
                        projectID: projectID
                    ),
                    disposition: disposition,
                    in: context
                )
                continue
            }
            guard let run = try fetchProjectOSRun(id: runID, in: context) else {
                continue
            }
            guard let projectID = scope.projectID?.rawValue,
                  run.project?.id == projectID,
                  run.sourceConversationIDString == scope.conversationID.rawValue.uuidString
            else {
                // A projectless canonical run never owns a ProjectOS row. Any
                // same-UUID row is therefore an identity collision, even when
                // its conversation happens to match.
                throw projectionFailure("projectos_acceptance_conflict")
            }
            run.project?.projectOSRuns.removeAll { $0.id == run.id }
            context.delete(run)
        }
    }

    func replaceLegacyRun(
        _ snapshot: SwiftDataLegacyRunSnapshot,
        disposition: SwiftDataMaterializationDispositionSnapshot,
        in context: ModelContext
    ) throws {
        try verifyLegacyAcceptance(
            snapshot.acceptance,
            disposition: disposition,
            in: context
        )
        guard let run = try fetchLegacyRun(
            id: snapshot.acceptance.runID,
            in: context
        ), let requestMessageID = run.requestMessageID
        else {
            throw projectionFailure("projection_run_missing")
        }

        let conversationSuppressed = disposition.suppressesConversation(
            snapshot.acceptance.conversationID
        )
        let conversation: Conversation?
        if conversationSuppressed {
            conversation = nil
        } else {
            guard let existing = try fetchConversation(
                id: snapshot.acceptance.conversationID,
                in: context
            ) else {
                throw projectionFailure("projection_conversation_missing")
            }
            conversation = existing
        }
        let effectiveProjectID = disposition.effectiveProjectID(
            snapshot.acceptance.projectID
        )
        run.projectID = effectiveProjectID

        run.status = snapshot.status
        run.updatedAt = snapshot.updatedAt.date
        run.startedAt = snapshot.startedAt?.date
        run.completedAt = snapshot.completedAt?.date
        run.errorKind = snapshot.errorKind
        run.errorMessage = snapshot.errorMessage
        run.responseMessageID = snapshot.responseMessageID
        // Route is canonical projection state, not an incremental patch. An
        // acceptance-only prefix has not observed a provider yet and must clear
        // any value left by a previously projected future prefix.
        run.provider = snapshot.observedRoute.map { legacyProvider($0.provider) }
        run.modelID = snapshot.observedRoute?.modelID

        let runIDString = snapshot.acceptance.runID.uuidString
        let linkedMessages = try context.fetch(
            FetchDescriptor<ChatMessage>(
                predicate: #Predicate { message in
                    message.runIDString == runIDString
                }
            )
        )
        try requireUniqueLegacyIDs(
            linkedMessages.map(\.id),
            kind: .message
        )
        let desiredMessages: [UUID: SwiftDataLegacyMessageSnapshot] =
            conversationSuppressed ? [:] : Dictionary(
            uniqueKeysWithValues: snapshot.messages.map { ($0.messageID, $0) }
        )
        var existingMessages = Dictionary(
            uniqueKeysWithValues: linkedMessages.map { ($0.id, $0) }
        )
        for message in linkedMessages where
            (conversationSuppressed || message.id != requestMessageID) &&
            desiredMessages[message.id] == nil {
            message.conversation?.messages.removeAll { $0.id == message.id }
            context.delete(message)
            existingMessages.removeValue(forKey: message.id)
        }
        let projectedMessages: [SwiftDataLegacyMessageSnapshot] =
            conversationSuppressed ? [] : snapshot.messages
        for desired in projectedMessages {
            if let globallyExisting = try fetchLegacyMessage(
                id: desired.messageID,
                in: context
            ), existingMessages[desired.messageID] == nil {
                _ = globallyExisting
                throw projectionFailure("projection_message_identity_conflict")
            }
            let message: ChatMessage
            if let existing = existingMessages[desired.messageID] {
                guard existing.id != requestMessageID else {
                    throw projectionFailure("projection_message_conflict")
                }
                message = existing
                message.role = desired.role
                message.content = PersistedPayloadBudget.compactMessageContent(
                    desired.content,
                    role: desired.role
                )
                message.conversation = conversation
                message.runID = snapshot.acceptance.runID
                message.runSequence = desired.sequence
                message.runStatus = snapshot.status
                message.createdAt = desired.createdAt.date
            } else {
                message = ChatMessage(
                    id: desired.messageID,
                    role: desired.role,
                    content: desired.content,
                    conversation: conversation,
                    runID: snapshot.acceptance.runID,
                    runSequence: desired.sequence,
                    runStatus: snapshot.status
                )
                message.createdAt = desired.createdAt.date
                context.insert(message)
            }
            conversation?.appendMessage(
                message,
                updateTimestamp: snapshot.updatedAt.date
            )
        }
        try stampLegacyRunStatus(
            snapshot.status,
            runID: snapshot.acceptance.runID,
            in: context
        )
        conversation?.refreshMessageMetadata(
            updateTimestamp: snapshot.updatedAt.date
        )

        let linkedTools = try context.fetch(
            FetchDescriptor<ToolRun>(
                predicate: #Predicate { tool in
                    tool.runIDString == runIDString
                }
            )
        )
        try requireUniqueLegacyIDs(
            linkedTools.map(\.id),
            kind: .tool
        )
        let desiredTools = Dictionary(
            uniqueKeysWithValues: snapshot.tools.map { ($0.callID, $0) }
        )
        var existingTools = Dictionary(
            uniqueKeysWithValues: linkedTools.map { ($0.id, $0) }
        )
        for tool in linkedTools where desiredTools[tool.id] == nil {
            tool.project?.toolRuns.removeAll { $0.id == tool.id }
            context.delete(tool)
            existingTools.removeValue(forKey: tool.id)
        }
        let project: Project?
        if let projectID = effectiveProjectID {
            guard let existingProject = try fetchProject(id: projectID, in: context) else {
                throw projectionFailure("projection_project_missing")
            }
            project = existingProject
        } else {
            project = nil
        }
        for desired in snapshot.tools {
            if let globallyExisting = try fetchLegacyTool(
                id: desired.callID,
                in: context
            ), existingTools[desired.callID] == nil {
                _ = globallyExisting
                throw projectionFailure("projection_tool_identity_conflict")
            }
            let tool: ToolRun
            if let existing = existingTools[desired.callID] {
                tool = existing
                tool.name = desired.name
                tool.argumentsJSON = PersistedPayloadBudget.compactToolRunArguments(
                    desired.argumentsJSON
                )
                tool.output = PersistedPayloadBudget.compactToolRunOutput(
                    desired.outputJSON
                )
                tool.status = desired.status
                tool.requiresApproval = desired.requiresApproval
                tool.isMutating = desired.isMutating
                tool.project = project
                tool.runID = snapshot.acceptance.runID
                tool.runSequence = desired.sequence
                tool.runStatus = snapshot.status
                tool.createdAt = desired.createdAt.date
                tool.completedAt = desired.completedAt?.date
            } else {
                tool = ToolRun(
                    name: desired.name,
                    argumentsJSON: desired.argumentsJSON,
                    output: desired.outputJSON,
                    status: desired.status,
                    requiresApproval: desired.requiresApproval,
                    isMutating: desired.isMutating,
                    project: project,
                    runID: snapshot.acceptance.runID,
                    runSequence: desired.sequence,
                    runStatus: snapshot.status
                )
                tool.id = desired.callID
                tool.createdAt = desired.createdAt.date
                tool.completedAt = desired.completedAt?.date
                context.insert(tool)
            }
            if let project, !project.toolRuns.contains(where: { $0.id == tool.id }) {
                project.toolRuns.append(tool)
            }
        }

        try replaceApprovals(snapshot, in: context)
        try replaceEvidence(snapshot, in: context)
        try replaceArtifacts(
            snapshot,
            effectiveProjectID: effectiveProjectID,
            in: context
        )
    }

    func replaceApprovals(
        _ snapshot: SwiftDataLegacyRunSnapshot,
        in context: ModelContext
    ) throws {
        let runIDString = snapshot.acceptance.runID.uuidString.lowercased()
        let existingRows = try context.fetch(
            FetchDescriptor<ApprovalRequestRecord>(
                predicate: #Predicate { record in
                    record.runIDString == runIDString
                }
            )
        )
        let desiredIDs = Set(snapshot.approvals.map { $0.request.requestID.description })
        for existing in existingRows where !desiredIDs.contains(
            existing.approvalRequestIDString
        ) {
            context.delete(existing)
        }
        for desired in snapshot.approvals {
            let requestID = desired.request.requestID.description
            let encodedRequest = try encodeDeterministically(
                desired.request,
                operation: .saveProjectionCursor
            )
            let encodedResolution = try desired.resolution.map {
                try encodeDeterministically($0, operation: .saveProjectionCursor)
            }
            let status: ApprovalRequestStatus
            switch desired.resolution?.decision {
            case .approved?: status = .approved
            case .rejected?: status = .rejected
            case nil: status = .pending
            }
            let record: ApprovalRequestRecord
            if let existing = try fetchApproval(id: requestID, in: context) {
                guard existing.runIDString == runIDString else {
                    throw projectionFailure("projection_approval_conflict")
                }
                record = existing
                record.toolCallIDString = desired.request.binding.callID.description
                record.workspaceIDString = snapshot.acceptance.workspaceID.uuidString.lowercased()
                record.requestedEventIDString = desired.requestEventID.uuidString.lowercased()
                record.encodedRequest = encodedRequest
                record.requestedAtMilliseconds = desired.request.requestedAt.rawValue
            } else {
                record = ApprovalRequestRecord(
                    approvalRequestIDString: requestID,
                    runIDString: runIDString,
                    toolCallIDString: desired.request.binding.callID.description,
                    workspaceIDString: snapshot.acceptance.workspaceID.uuidString.lowercased(),
                    requestedEventIDString: desired.requestEventID.uuidString.lowercased(),
                    statusRawValue: status.rawValue,
                    encodedRequest: encodedRequest,
                    requestedAtMilliseconds: desired.request.requestedAt.rawValue,
                    updatedAt: desired.request.requestedAt.date
                )
                context.insert(record)
            }
            record.resolvedEventIDString = desired.resolutionEventID?.uuidString.lowercased()
            record.statusRawValue = status.rawValue
            record.encodedResolution = encodedResolution
            record.resolvedAtMilliseconds = desired.resolution?.resolvedAt.rawValue
            record.updatedAt = desired.resolution?.resolvedAt.date
                ?? desired.request.requestedAt.date
        }
    }

    func replaceEvidence(
        _ snapshot: SwiftDataLegacyRunSnapshot,
        in context: ModelContext
    ) throws {
        let runIDString = snapshot.acceptance.runID.uuidString.lowercased()
        var desiredByKey: [String: (SwiftDataCanonicalEvidenceSnapshot, Data)] = [:]
        for desired in snapshot.evidence {
            guard !desired.evidence.digest.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw projectionFailure("projection_evidence_digest_invalid")
            }
            let key = ToolEffectEvidenceRecord.makeEvidenceKey(
                appliedEventIDString: desired.eventID.uuidString,
                evidenceDigest: desired.evidence.digest
            )
            let encoded = try encodeDeterministically(
                desired.evidence,
                operation: .saveProjectionCursor
            )
            if let existing = desiredByKey[key] {
                guard existing.0 == desired, existing.1 == encoded else {
                    throw projectionFailure("projection_evidence_conflict")
                }
            } else {
                desiredByKey[key] = (desired, encoded)
            }
        }
        let existingRows = try context.fetch(
            FetchDescriptor<ToolEffectEvidenceRecord>(
                predicate: #Predicate { record in
                    record.runIDString == runIDString
                }
            )
        )
        for existing in existingRows where desiredByKey[existing.evidenceKey] == nil {
            context.delete(existing)
        }
        for (key, value) in desiredByKey {
            let desired = value.0
            let encoded = value.1
            if let existing = try fetchEvidence(key: key, in: context) {
                guard existing.runIDString == runIDString,
                      existing.toolCallIDString == desired.callID.uuidString.lowercased(),
                      existing.appliedEventIDString == desired.eventID.uuidString.lowercased(),
                      existing.workspaceIDString == snapshot.acceptance.workspaceID.uuidString.lowercased(),
                      existing.evidenceKind == desired.evidence.kind,
                      existing.encodedEvidence == encoded,
                      existing.evidenceDigest == desired.evidence.digest,
                      existing.appliedAtMilliseconds == desired.occurredAt.rawValue
                else {
                    throw projectionFailure("projection_evidence_conflict")
                }
                existing.createdAt = desired.occurredAt.date
                continue
            }
            context.insert(
                ToolEffectEvidenceRecord(
                    runIDString: runIDString,
                    toolCallIDString: desired.callID.uuidString.lowercased(),
                    appliedEventIDString: desired.eventID.uuidString.lowercased(),
                    workspaceIDString: snapshot.acceptance.workspaceID.uuidString.lowercased(),
                    evidenceKind: desired.evidence.kind,
                    encodedEvidence: encoded,
                    evidenceDigest: desired.evidence.digest,
                    appliedAtMilliseconds: desired.occurredAt.rawValue,
                    createdAt: desired.occurredAt.date
                )
            )
        }
    }

    func replaceArtifacts(
        _ snapshot: SwiftDataLegacyRunSnapshot,
        effectiveProjectID: UUID?,
        in context: ModelContext
    ) throws {
        let runIDString = snapshot.acceptance.runID.uuidString.lowercased()
        var desiredByKey: [String: (SwiftDataCanonicalArtifactSnapshot, Data)] = [:]
        for desired in snapshot.artifacts {
            guard !desired.artifact.mediaType.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
                  !desired.artifact.contentDigest.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  !desired.artifact.displayName.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty
            else {
                throw projectionFailure("projection_artifact_identity_invalid")
            }
            let key = AgentArtifactProjectionRecord.makeArtifactProjectionKey(
                artifactIDString: desired.artifact.artifactID.description,
                eventIDString: desired.eventID.uuidString
            )
            let encoded = try encodeDeterministically(
                desired.artifact,
                operation: .saveProjectionCursor
            )
            if let existing = desiredByKey[key] {
                guard existing.0 == desired, existing.1 == encoded else {
                    throw projectionFailure("projection_artifact_conflict")
                }
            } else {
                desiredByKey[key] = (desired, encoded)
            }
        }
        let existingRows = try context.fetch(
            FetchDescriptor<AgentArtifactProjectionRecord>(
                predicate: #Predicate { record in
                    record.runIDString == runIDString
                }
            )
        )
        for existing in existingRows where desiredByKey[
            existing.artifactProjectionKey
        ] == nil {
            context.delete(existing)
        }
        for (key, value) in desiredByKey {
            let desired = value.0
            let encoded = value.1
            let encodedDigest = Self.sha256(encoded)
            if let existing = try fetchArtifact(key: key, in: context) {
                guard existing.artifactIDString == desired.artifact.artifactID.description,
                      existing.eventIDString == desired.eventID.uuidString.lowercased(),
                      existing.runIDString == runIDString,
                      existing.projectIDString == effectiveProjectID?.uuidString.lowercased(),
                      existing.workspaceIDString == snapshot.acceptance.workspaceID.uuidString.lowercased(),
                      existing.toolCallIDString == desired.callID?.uuidString.lowercased(),
                      existing.sourceKind == desired.source.rawValue,
                      existing.mediaType == desired.artifact.mediaType,
                      existing.displayName == desired.artifact.displayName,
                      existing.encodingName == Self.artifactEncodingName,
                      existing.encodingVersion == Self.encodingVersion,
                      existing.encodedArtifact == encoded,
                      existing.artifactDigest == desired.artifact.contentDigest,
                      existing.encodedArtifactSHA256 == encodedDigest,
                      existing.occurredAtMilliseconds == desired.occurredAt.rawValue
                else {
                    throw projectionFailure("projection_artifact_conflict")
                }
                existing.createdAt = desired.occurredAt.date
                continue
            }
            context.insert(
                AgentArtifactProjectionRecord(
                    artifactIDString: desired.artifact.artifactID.description,
                    eventIDString: desired.eventID.uuidString.lowercased(),
                    runIDString: runIDString,
                    projectIDString: effectiveProjectID?.uuidString.lowercased(),
                    workspaceIDString: snapshot.acceptance.workspaceID.uuidString.lowercased(),
                    toolCallIDString: desired.callID?.uuidString.lowercased(),
                    sourceKind: desired.source.rawValue,
                    mediaType: desired.artifact.mediaType,
                    displayName: desired.artifact.displayName,
                    encodingName: Self.artifactEncodingName,
                    encodingVersion: Self.encodingVersion,
                    encodedArtifact: encoded,
                    artifactDigest: desired.artifact.contentDigest,
                    encodedArtifactSHA256: encodedDigest,
                    occurredAtMilliseconds: desired.occurredAt.rawValue,
                    createdAt: desired.occurredAt.date
                )
            )
        }
    }

    func replaceProjectOSRun(
        _ snapshot: SwiftDataProjectOSRunSnapshot,
        in context: ModelContext
    ) throws {
        guard let projectID = snapshot.projectID else {
            if try fetchProjectOSRun(id: snapshot.runID, in: context) != nil {
                throw projectionFailure("projectos_acceptance_conflict")
            }
            return
        }
        guard let project = try fetchProject(id: projectID, in: context) else {
            throw projectionFailure("projection_project_missing")
        }
        let run: ProjectOSRun
        if let existing = try fetchProjectOSRun(id: snapshot.runID, in: context) {
            guard existing.project?.id == projectID,
                  existing.sourceConversationIDString == snapshot.conversationID.uuidString
            else {
                throw projectionFailure("projectos_acceptance_conflict")
            }
            run = existing
        } else {
            run = ProjectOSRun(
                project: project,
                projectName: project.name,
                mission: snapshot.mission,
                status: .planning,
                origin: .manual,
                sourceConversationID: snapshot.conversationID,
                now: snapshot.acceptedAt.date
            )
            run.id = snapshot.runID
            context.insert(run)
        }
        run.mission = compactProjectOSText(snapshot.mission, limit: 1_000)
        run.status = snapshot.status
        run.planningState = snapshot.planningState
        run.currentAction = snapshot.currentAction
        run.currentCommand = snapshot.currentCommand
        run.nextStep = snapshot.nextStep
        run.latestEventTitle = snapshot.latestEventTitle
        run.latestEventDetail = snapshot.latestEventDetail
        run.changedFilesSummary = snapshot.changedFilesSummary
        run.artifactsSummary = snapshot.artifactsSummary
        run.proofSummary = snapshot.proofSummary
        run.blockerReason = snapshot.blockerReason
        run.waitingReason = snapshot.waitingReason
        run.failureReason = snapshot.failureReason
        run.resumeState = snapshot.resumeState
        run.progressEventCount = snapshot.progressEventCount
        run.createdAt = snapshot.acceptedAt.date
        run.updatedAt = snapshot.updatedAt.date
        run.completedAt = snapshot.completedAt?.date
        if !project.projectOSRuns.contains(where: { $0.id == run.id }) {
            project.projectOSRuns.append(run)
        }
    }

    /// Removes a ProjectOS row only when the row still proves canonical
    /// ownership by both project and source conversation. A same-RunID row
    /// with different or missing ownership is an identity collision, not an
    /// orphan to clean up opportunistically.
    func suppressProjectOSRun(
        _ suppression: SwiftDataProjectOSRunSuppression,
        disposition: SwiftDataMaterializationDispositionSnapshot,
        in context: ModelContext
    ) throws {
        guard disposition.rehomedProjectIDs.contains(suppression.projectID) else {
            throw projectionFailure("projectos_suppression_policy_missing")
        }
        guard let run = try fetchProjectOSRun(id: suppression.runID, in: context) else {
            return
        }
        guard run.project?.id == suppression.projectID,
              run.sourceConversationIDString.flatMap(UUID.init(uuidString:)) ==
                suppression.conversationID
        else {
            throw projectionFailure("projectos_acceptance_conflict")
        }
        run.project?.projectOSRuns.removeAll { $0.id == run.id }
        context.delete(run)
    }

    func requireUniqueLegacyIDs(
        _ ids: [UUID],
        kind: SwiftDataLegacyIdentityKind
    ) throws {
        var seen = Set<UUID>()
        for id in ids where !seen.insert(id).inserted {
            throw SwiftDataAgentStoreIntegrityError.duplicateLegacyIdentity(
                kind: kind,
                id: id
            )
        }
    }

    /// V1 identifiers were not unique SwiftData attributes. Scan every
    /// projection-owned legacy entity so an unrelated duplicate cannot hide
    /// behind a targeted fetch or an already-advanced projection cursor.
    func validateLegacyIdentityUniqueness(in context: ModelContext) throws {
        try requireUniqueLegacyIDs(
            context.fetch(FetchDescriptor<AgentRunRecord>()).map(\.id),
            kind: .run
        )
        try requireUniqueLegacyIDs(
            context.fetch(FetchDescriptor<ChatMessage>()).map(\.id),
            kind: .message
        )
        try requireUniqueLegacyIDs(
            context.fetch(FetchDescriptor<Conversation>()).map(\.id),
            kind: .conversation
        )
        try requireUniqueLegacyIDs(
            context.fetch(FetchDescriptor<Project>()).map(\.id),
            kind: .project
        )
        try requireUniqueLegacyIDs(
            context.fetch(FetchDescriptor<ToolRun>()).map(\.id),
            kind: .tool
        )
        try requireUniqueLegacyIDs(
            context.fetch(FetchDescriptor<ProjectOSRun>()).map(\.id),
            kind: .projectOSRun
        )
    }

    func validatedMaterializationDisposition(
        in context: ModelContext
    ) throws -> SwiftDataMaterializationDispositionSnapshot {
        let records = try context.fetch(
            FetchDescriptor<AgentMaterializationDispositionRecord>()
        )
        var suppressedConversationIDs = Set<UUID>()
        var rehomedProjectIDs = Set<UUID>()
        var canonicalEntries: [String] = []
        canonicalEntries.reserveCapacity(records.count)

        for record in records {
            guard let scopeKind = AgentMaterializationDispositionScopeKind(
                rawValue: record.scopeKindRawValue
            ), let action = AgentMaterializationDispositionAction(
                rawValue: record.actionRawValue
            ) else {
                throw SwiftDataMaterializationDispositionError.malformedRecord(
                    record.dispositionKey
                )
            }
            let expectedKey = AgentMaterializationDispositionRecord.makeKey(
                scopeKind: scopeKind,
                scopeID: record.scopeID
            )
            guard record.dispositionKey == expectedKey,
                  AgentInstant(record.createdAt).rawValue == record.createdAtMilliseconds
            else {
                throw SwiftDataMaterializationDispositionError.malformedRecord(
                    record.dispositionKey
                )
            }

            switch (scopeKind, action) {
            case (.conversation, .suppressChat):
                guard suppressedConversationIDs.insert(record.scopeID).inserted else {
                    throw SwiftDataMaterializationDispositionError.conflictingRecord(
                        expectedKey
                    )
                }
            case (.project, .rehomeToGeneral):
                guard rehomedProjectIDs.insert(record.scopeID).inserted else {
                    throw SwiftDataMaterializationDispositionError.conflictingRecord(
                        expectedKey
                    )
                }
            default:
                throw SwiftDataMaterializationDispositionError.conflictingRecord(
                    expectedKey
                )
            }
            canonicalEntries.append(
                "\(record.dispositionKey)|\(action.rawValue)|\(record.createdAtMilliseconds)"
            )
        }

        return .make(
            suppressedConversationIDs: suppressedConversationIDs,
            rehomedProjectIDs: rehomedProjectIDs,
            canonicalEntries: canonicalEntries
        )
    }

    @discardableResult
    func stageMaterializationDisposition(
        scopeKind: AgentMaterializationDispositionScopeKind,
        scopeID: UUID,
        action: AgentMaterializationDispositionAction,
        at instant: AgentInstant,
        validated snapshot: SwiftDataMaterializationDispositionSnapshot,
        in context: ModelContext
    ) throws -> Bool {
        let isExactRetry: Bool
        switch (scopeKind, action) {
        case (.conversation, .suppressChat):
            isExactRetry = snapshot.suppressedConversationIDs.contains(scopeID)
        case (.project, .rehomeToGeneral):
            isExactRetry = snapshot.rehomedProjectIDs.contains(scopeID)
        default:
            throw SwiftDataMaterializationDispositionError.conflictingRecord(
                AgentMaterializationDispositionRecord.makeKey(
                    scopeKind: scopeKind,
                    scopeID: scopeID
                )
            )
        }
        guard !isExactRetry else { return false }

        context.insert(
            AgentMaterializationDispositionRecord(
                scopeKind: scopeKind,
                scopeID: scopeID,
                action: action,
                createdAtMilliseconds: instant.rawValue,
                createdAt: instant.date
            )
        )
        return true
    }

    func rejectDisposedAcceptance(
        conversationID: UUID,
        projectID: UUID?,
        disposition: SwiftDataMaterializationDispositionSnapshot
    ) throws {
        if disposition.suppressesConversation(conversationID) {
            throw SwiftDataMaterializationDispositionError.disposedAcceptance(
                scopeKind: .conversation,
                scopeID: conversationID
            )
        }
        if let projectID, disposition.rehomedProjectIDs.contains(projectID) {
            throw SwiftDataMaterializationDispositionError.disposedAcceptance(
                scopeKind: .project,
                scopeID: projectID
            )
        }
    }

    func compactProjectOSText(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "..."
    }

    func verifyLegacyAcceptance(
        _ check: SwiftDataLegacyAcceptanceCheck,
        disposition: SwiftDataMaterializationDispositionSnapshot,
        in context: ModelContext
    ) throws {
        let effectiveProjectID = disposition.effectiveProjectID(check.projectID)
        guard let run = try fetchLegacyRun(id: check.runID, in: context),
              run.id == check.runID,
              run.conversationID == check.conversationID,
              run.projectID == effectiveProjectID,
              run.workspaceID == check.workspaceID,
              let requestMessageID = run.requestMessageID
        else {
            throw projectionFailure("legacy_acceptance_projection_mismatch")
        }

        if disposition.suppressesConversation(check.conversationID) {
            let runIDString = check.runID.uuidString
            let linkedMessages = try context.fetch(
                FetchDescriptor<ChatMessage>(
                    predicate: #Predicate { $0.runIDString == runIDString }
                )
            )
            guard try fetchConversation(id: check.conversationID, in: context) == nil,
                  try fetchLegacyMessage(id: requestMessageID, in: context) == nil,
                  linkedMessages.isEmpty
            else {
                throw projectionFailure("legacy_acceptance_projection_mismatch")
            }
            return
        }

        guard let conversation = try fetchConversation(
            id: check.conversationID,
            in: context
        ), conversation.project?.id == effectiveProjectID,
              let message = try fetchLegacyMessage(id: requestMessageID, in: context),
              message.role == .user,
              // The canonical prompt was already bound atomically through
              // `acceptedRequestText`. This row may intentionally hold a
              // separately classified public summary, so its text is display
              // state rather than replay authority.
              !message.content.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              message.conversation?.id == check.conversationID,
              message.runID == check.runID
        else {
            throw projectionFailure("legacy_acceptance_projection_mismatch")
        }
    }

    func setLegacyRunStatus(
        _ projection: SwiftDataLegacyRunStatusProjection,
        in context: ModelContext
    ) throws {
        guard let run = try fetchLegacyRun(id: projection.runID, in: context) else {
            throw projectionFailure("projection_run_missing")
        }
        guard projection.allowedStatuses.contains(run.status) else {
            throw projectionFailure("projection_precondition_failed")
        }
        run.transition(
            to: projection.status,
            at: projection.at.date,
            errorKind: projection.errorKind,
            errorMessage: projection.errorMessage
        )
        try stampLegacyRunStatus(
            projection.status,
            runID: projection.runID,
            in: context
        )
    }

    func stampLegacyRunStatus(
        _ status: AgentRunStatus,
        runID: UUID,
        in context: ModelContext
    ) throws {
        let runIDString = runID.uuidString
        let messages = try context.fetch(
            FetchDescriptor<ChatMessage>(
                predicate: #Predicate { message in
                    message.runIDString == runIDString
                }
            )
        )
        let tools = try context.fetch(
            FetchDescriptor<ToolRun>(
                predicate: #Predicate { tool in
                    tool.runIDString == runIDString
                }
            )
        )
        try requireUniqueLegacyIDs(messages.map(\.id), kind: .message)
        try requireUniqueLegacyIDs(tools.map(\.id), kind: .tool)
        for message in messages { message.runStatus = status }
        for tool in tools { tool.runStatus = status }
    }

    func updateLegacyRoute(
        _ projection: SwiftDataLegacyRouteProjection,
        in context: ModelContext
    ) throws {
        guard let run = try fetchLegacyRun(id: projection.runID, in: context) else {
            throw projectionFailure("projection_run_missing")
        }
        run.provider = legacyProvider(projection.provider)
        run.modelID = projection.modelID
    }

    func upsertLegacyMessage(
        _ projection: SwiftDataLegacyMessageProjection,
        in context: ModelContext
    ) throws {
        guard let run = try fetchLegacyRun(id: projection.runID, in: context),
              run.conversationID == projection.conversationID,
              let conversation = try fetchConversation(
                  id: projection.conversationID,
                  in: context
              )
        else {
            throw projectionFailure("projection_message_binding_missing")
        }
        if let existing = try fetchLegacyMessage(id: projection.messageID, in: context) {
            guard existing.runID == projection.runID,
                  existing.conversation?.id == projection.conversationID,
                  existing.runSequence == projection.sequence,
                  existing.role == projection.role,
                  existing.content == projection.content
            else {
                throw projectionFailure("projection_message_conflict")
            }
            return
        }
        let message = ChatMessage(
            id: projection.messageID,
            role: projection.role,
            content: projection.content,
            conversation: conversation,
            runID: projection.runID,
            runSequence: projection.sequence,
            runStatus: run.status
        )
        message.createdAt = projection.createdAt.date
        context.insert(message)
        conversation.appendMessage(message, updateTimestamp: projection.createdAt.date)
        if projection.role == .assistant {
            run.responseMessageID = projection.messageID
        }
    }

    func upsertLegacyTool(
        _ projection: SwiftDataLegacyToolProjection,
        in context: ModelContext
    ) throws {
        guard let run = try fetchLegacyRun(id: projection.runID, in: context),
              run.projectID == projection.projectID
        else {
            throw projectionFailure("projection_tool_run_missing")
        }
        if let existing = try fetchLegacyTool(id: projection.callID, in: context) {
            guard existing.runID == projection.runID,
                  existing.project?.id == projection.projectID
            else {
                throw projectionFailure("projection_tool_conflict")
            }
            if !projection.name.isEmpty {
                existing.name = projection.name
            }
            if let argumentsJSON = projection.argumentsJSON {
                existing.argumentsJSON = PersistedPayloadBudget.compactToolRunArguments(argumentsJSON)
            }
            if let outputJSON = projection.outputJSON {
                existing.output = PersistedPayloadBudget.compactToolRunOutput(outputJSON)
            }
            if let requiresApproval = projection.requiresApproval {
                existing.requiresApproval = requiresApproval
            }
            if let isMutating = projection.isMutating {
                existing.isMutating = isMutating
            }
            existing.status = projection.status
            existing.runSequence = projection.sequence
            existing.runStatus = run.status
            existing.completedAt = projection.status == .completed ||
                projection.status == .failed || projection.status == .rejected
                ? projection.occurredAt.date
                : nil
            return
        }

        guard !projection.name.isEmpty, let argumentsJSON = projection.argumentsJSON else {
            throw projectionFailure("projection_tool_missing_proposal")
        }
        let project: Project?
        if let projectID = projection.projectID {
            guard let matched = try fetchProject(id: projectID, in: context) else {
                throw projectionFailure("projection_project_missing")
            }
            project = matched
        } else {
            project = nil
        }
        let tool = ToolRun(
            name: projection.name,
            argumentsJSON: argumentsJSON,
            output: projection.outputJSON ?? "",
            status: projection.status,
            requiresApproval: projection.requiresApproval ?? false,
            isMutating: projection.isMutating ?? false,
            project: project,
            runID: projection.runID,
            runSequence: projection.sequence,
            runStatus: run.status
        )
        tool.id = projection.callID
        tool.createdAt = projection.occurredAt.date
        if projection.status == .completed || projection.status == .failed ||
            projection.status == .rejected {
            tool.completedAt = projection.occurredAt.date
        }
        context.insert(tool)
        if let project, !project.toolRuns.contains(where: { $0.id == tool.id }) {
            project.toolRuns.append(tool)
        }
    }

    func upsertApprovalRequest(
        _ projection: SwiftDataApprovalRequestProjection,
        in context: ModelContext
    ) throws {
        let request = projection.request
        guard request.binding.runID.rawValue == projection.runID,
              request.binding.workspaceID.rawValue == projection.workspaceID
        else {
            throw projectionFailure("projection_approval_binding_mismatch")
        }
        let requestID = request.requestID.description
        let encoded = try encodeDeterministically(
            request,
            operation: .saveProjectionCursor
        )
        if let existing = try fetchApproval(id: requestID, in: context) {
            guard existing.runIDString == projection.runID.uuidString.lowercased(),
                  existing.toolCallIDString == request.binding.callID.description,
                  existing.workspaceIDString == projection.workspaceID.uuidString.lowercased(),
                  existing.requestedEventIDString == projection.eventID.uuidString.lowercased(),
                  existing.encodedRequest == encoded
            else {
                throw projectionFailure("projection_approval_conflict")
            }
            return
        }
        context.insert(
            ApprovalRequestRecord(
                approvalRequestIDString: requestID,
                runIDString: projection.runID.uuidString.lowercased(),
                toolCallIDString: request.binding.callID.description,
                workspaceIDString: projection.workspaceID.uuidString.lowercased(),
                requestedEventIDString: projection.eventID.uuidString.lowercased(),
                statusRawValue: ApprovalRequestStatus.pending.rawValue,
                encodedRequest: encoded,
                requestedAtMilliseconds: request.requestedAt.rawValue,
                updatedAt: request.requestedAt.date
            )
        )
    }

    func resolveApprovalRequest(
        _ projection: SwiftDataApprovalResolutionProjection,
        in context: ModelContext
    ) throws {
        let resolution = projection.resolution
        guard let record = try fetchApproval(
            id: resolution.requestID.description,
            in: context
        ), record.runIDString == projection.runID.uuidString.lowercased(),
           record.toolCallIDString == resolution.callID.description,
           record.statusRawValue == ApprovalRequestStatus.pending.rawValue
        else {
            throw projectionFailure("projection_pending_approval_missing")
        }
        record.resolvedEventIDString = projection.eventID.uuidString.lowercased()
        record.statusRawValue = resolution.decision == .approved
            ? ApprovalRequestStatus.approved.rawValue
            : ApprovalRequestStatus.rejected.rawValue
        record.encodedResolution = try encodeDeterministically(
            resolution,
            operation: .saveProjectionCursor
        )
        record.resolvedAtMilliseconds = resolution.resolvedAt.rawValue
        record.updatedAt = resolution.resolvedAt.date
    }

    func insertToolEvidence(
        _ projection: SwiftDataToolEvidenceProjection,
        in context: ModelContext
    ) throws {
        let eventID = projection.eventID.uuidString.lowercased()
        var pendingByKey: [String: (ToolEvidence, Data)] = [:]
        for evidence in projection.evidence {
            guard !evidence.digest.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw projectionFailure("projection_evidence_digest_invalid")
            }
            let encoded = try encodeDeterministically(
                evidence,
                operation: .saveProjectionCursor
            )
            let key = ToolEffectEvidenceRecord.makeEvidenceKey(
                appliedEventIDString: eventID,
                evidenceDigest: evidence.digest
            )
            if let pending = pendingByKey[key] {
                guard pending.0 == evidence, pending.1 == encoded else {
                    throw projectionFailure("projection_evidence_conflict")
                }
                continue
            }
            pendingByKey[key] = (evidence, encoded)
        }

        for (key, pending) in pendingByKey.sorted(by: { $0.key < $1.key }) {
            let evidence = pending.0
            let encoded = pending.1
            if let existing = try fetchEvidence(key: key, in: context) {
                guard existing.runIDString == projection.runID.uuidString.lowercased(),
                      existing.toolCallIDString == projection.callID.uuidString.lowercased(),
                      existing.appliedEventIDString == eventID,
                      existing.workspaceIDString == projection.workspaceID.uuidString.lowercased(),
                      existing.evidenceKind == evidence.kind,
                      existing.evidenceDigest == evidence.digest,
                      existing.encodedEvidence == encoded,
                      existing.appliedAtMilliseconds == projection.occurredAt.rawValue,
                      existing.createdAt == projection.occurredAt.date
                else {
                    throw projectionFailure("projection_evidence_conflict")
                }
                continue
            }
            let record = ToolEffectEvidenceRecord(
                runIDString: projection.runID.uuidString.lowercased(),
                toolCallIDString: projection.callID.uuidString.lowercased(),
                appliedEventIDString: eventID,
                workspaceIDString: projection.workspaceID.uuidString.lowercased(),
                evidenceKind: evidence.kind,
                encodedEvidence: encoded,
                evidenceDigest: evidence.digest,
                appliedAtMilliseconds: projection.occurredAt.rawValue,
                createdAt: projection.occurredAt.date
            )
            context.insert(record)
        }
    }

    func acceptProjectOSRun(
        _ projection: SwiftDataProjectOSAcceptanceProjection,
        in context: ModelContext
    ) throws {
        guard let projectID = projection.projectID else { return }
        guard let project = try fetchProject(id: projectID, in: context) else {
            throw projectionFailure("projection_project_missing")
        }
        if let existing = try fetchProjectOSRun(id: projection.runID, in: context) {
            guard existing.project?.id == projectID,
                  existing.sourceConversationIDString == projection.conversationID.uuidString
            else {
                throw projectionFailure("projectos_acceptance_conflict")
            }
            return
        }
        let run = ProjectOSRun(
            project: project,
            projectName: project.name,
            mission: projection.mission,
            status: .planning,
            origin: .manual,
            sourceConversationID: projection.conversationID,
            now: projection.acceptedAt.date
        )
        run.id = projection.runID
        run.latestEventTitle = "Run accepted"
        run.latestEventDetail = projection.mission
        run.currentAction = "Waiting to start"
        context.insert(run)
        if !project.projectOSRuns.contains(where: { $0.id == run.id }) {
            project.projectOSRuns.append(run)
        }
    }

    func updateProjectOSRun(
        _ projection: SwiftDataProjectOSRunProjection,
        in context: ModelContext
    ) throws {
        guard let projectID = projection.projectID else { return }
        guard let run = try fetchProjectOSRun(id: projection.runID, in: context),
              run.id == projection.runID,
              run.project?.id == projectID
        else {
            throw projectionFailure("projectos_run_missing")
        }
        if let status = projection.status { run.status = status }
        if let planningState = projection.planningState { run.planningState = planningState }
        if let currentAction = projection.currentAction { run.currentAction = currentAction }
        if let currentCommand = projection.currentCommand { run.currentCommand = currentCommand }
        if let nextStep = projection.nextStep { run.nextStep = nextStep }
        if let changedFilesSummary = projection.changedFilesSummary {
            run.changedFilesSummary = changedFilesSummary
        }
        if let artifactsSummary = projection.artifactsSummary {
            run.artifactsSummary = artifactsSummary
        }
        if let proofSummary = projection.proofSummary { run.proofSummary = proofSummary }
        if let blockerReason = projection.blockerReason { run.blockerReason = blockerReason }
        if let waitingReason = projection.waitingReason { run.waitingReason = waitingReason }
        if let failureReason = projection.failureReason { run.failureReason = failureReason }
        if let resumeState = projection.resumeState { run.resumeState = resumeState }
        run.latestEventTitle = projection.latestEventTitle
        run.latestEventDetail = projection.latestEventDetail
        run.progressEventCount += 1
        run.updatedAt = projection.occurredAt.date
        if projection.marksComplete {
            run.completedAt = projection.occurredAt.date
        }
    }

    func projectionFailure(_ code: String) -> AgentStoreError {
        .persistenceFailure(operation: .saveProjectionCursor, code: code)
    }

    func legacyProvider(_ rawValue: String) -> AIProvider {
        switch rawValue.lowercased().replacingOccurrences(of: "_", with: "") {
        case "local", "ondevice": .local
        case "openai": .openAI
        case "openaicodex", "codex": .openAICodex
        case "openrouter": .openRouter
        case "opencodezen", "zen": .openCodeZen
        default: .custom
        }
    }

    func stageLegacyAcceptance(
        _ projection: SwiftDataLegacyAcceptanceProjection,
        acceptance: AgentRunAcceptance,
        in context: ModelContext
    ) throws {
        try validateLegacyAcceptanceBinding(projection, acceptance: acceptance)
        guard try fetchLegacyRun(id: projection.runID, in: context) == nil,
              try fetchLegacyMessage(id: projection.requestMessageID, in: context) == nil
        else {
            throw AgentStoreError.persistenceFailure(
                operation: .acceptRun,
                code: "legacy_acceptance_conflict"
            )
        }
        guard let conversation = try fetchConversation(
            id: projection.conversationID,
            in: context
        ) else {
            throw AgentStoreError.persistenceFailure(
                operation: .acceptRun,
                code: "legacy_conversation_missing"
            )
        }
        try stageLegacyProjectBinding(
            projection.projectID,
            conversation: conversation,
            in: context
        )
        let provider: AIProvider?
        if let rawValue = projection.providerRawValue {
            guard let decoded = AIProvider(rawValue: rawValue) else {
                throw AgentStoreError.persistenceFailure(
                    operation: .acceptRun,
                    code: "legacy_provider_invalid"
                )
            }
            provider = decoded
        } else {
            provider = nil
        }

        let acceptedAt = acceptance.metadata.context.acceptedAt.date
        let message = ChatMessage(
            id: projection.requestMessageID,
            role: .user,
            content: projection.requestText,
            conversation: conversation,
            runID: projection.runID,
            runSequence: 0,
            runStatus: .queued
        )
        message.createdAt = acceptedAt
        let run = AgentRunRecord(
            id: projection.runID,
            status: .queued,
            origin: projection.origin,
            conversationID: projection.conversationID,
            projectID: projection.projectID,
            workspaceID: projection.workspaceID,
            workspaceName: projection.workspaceName,
            requestMessageID: projection.requestMessageID,
            provider: provider,
            modelID: projection.modelID,
            now: acceptedAt
        )
        context.insert(message)
        context.insert(run)
        conversation.appendMessage(message, updateTimestamp: acceptedAt)
    }

    func validateExistingLegacyAcceptance(
        _ projection: SwiftDataLegacyAcceptanceProjection,
        acceptance: AgentRunAcceptance,
        disposition: SwiftDataMaterializationDispositionSnapshot,
        in context: ModelContext
    ) throws {
        try validateLegacyAcceptanceBinding(projection, acceptance: acceptance)
        let effectiveProjectID = disposition.effectiveProjectID(projection.projectID)
        guard let run = try fetchLegacyRun(id: projection.runID, in: context),
              run.id == projection.runID,
              run.origin == projection.origin,
              run.conversationID == projection.conversationID,
              run.projectID == effectiveProjectID,
              run.workspaceID == projection.workspaceID,
              run.workspaceName == projection.workspaceName,
              run.requestMessageID == projection.requestMessageID
        else {
            throw AgentStoreError.persistenceFailure(
                operation: .acceptRun,
                code: "legacy_acceptance_conflict"
            )
        }

        if disposition.suppressesConversation(projection.conversationID) {
            let runIDString = projection.runID.uuidString
            let linkedMessages = try context.fetch(
                FetchDescriptor<ChatMessage>(
                    predicate: #Predicate { $0.runIDString == runIDString }
                )
            )
            guard try fetchConversation(id: projection.conversationID, in: context) == nil,
                  try fetchLegacyMessage(id: projection.requestMessageID, in: context) == nil,
                  linkedMessages.isEmpty
            else {
                throw AgentStoreError.persistenceFailure(
                    operation: .acceptRun,
                    code: "legacy_acceptance_conflict"
                )
            }
            return
        }

        guard let message = try fetchLegacyMessage(
            id: projection.requestMessageID,
            in: context
        ), let conversation = try fetchConversation(
            id: projection.conversationID,
            in: context
        ), conversation.project?.id == effectiveProjectID,
              message.role == .user,
              message.content == projection.requestText,
              message.conversation?.id == projection.conversationID,
              message.runID == projection.runID
        else {
            throw AgentStoreError.persistenceFailure(
                operation: .acceptRun,
                code: "legacy_acceptance_conflict"
            )
        }
    }

    func stageLegacyProjectBinding(
        _ projectedProjectID: UUID?,
        conversation: Conversation,
        in context: ModelContext
    ) throws {
        if let boundProject = conversation.project {
            guard boundProject.id == projectedProjectID else {
                throw AgentStoreError.persistenceFailure(
                    operation: .acceptRun,
                    code: "legacy_project_binding_mismatch"
                )
            }
            return
        }

        guard let projectedProjectID else {
            return
        }
        guard let project = try fetchProject(id: projectedProjectID, in: context) else {
            throw AgentStoreError.persistenceFailure(
                operation: .acceptRun,
                code: "legacy_project_missing"
            )
        }
        conversation.project = project
    }

    func validateLegacyAcceptanceBinding(
        _ projection: SwiftDataLegacyAcceptanceProjection,
        acceptance: AgentRunAcceptance
    ) throws {
        let runContext = acceptance.metadata.context
        guard projection.runID == runContext.lineage.runID.rawValue,
              projection.conversationID == runContext.conversationID.rawValue,
              projection.projectID == runContext.projectID?.rawValue,
              projection.workspaceID == runContext.workspaceID.rawValue,
              !projection.workspaceName.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              !projection.requestText.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              !projection.acceptedRequestText.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              acceptedUserText(from: acceptance) ==
                projection.acceptedRequestText
        else {
            throw AgentStoreError.persistenceFailure(
                operation: .acceptRun,
                code: "legacy_acceptance_binding_mismatch"
            )
        }
    }

    func acceptedUserText(from acceptance: AgentRunAcceptance) -> String? {
        guard case let .runAccepted(payload) = acceptance.envelope.event.payload else {
            return nil
        }
        return canonicalAcceptedUserText(payload.initialItems)
    }

    func nextOffset(
        in context: ModelContext,
        operation: AgentStoreOperation
    ) throws -> AgentJournalOffset {
        let current = try validatedJournal(
            operation: operation,
            in: context
        ).highWaterMark
        guard let next = current.successor else {
            throw AgentStoreError.journalOffsetExhausted
        }
        return next
    }

    func currentHighWaterMark(
        in context: ModelContext,
        operation: AgentStoreOperation
    ) throws -> AgentJournalOffset {
        var descriptor = FetchDescriptor<AgentEventRecord>(
            sortBy: [SortDescriptor(\AgentEventRecord.journalOffsetValue, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let value = try context.fetch(descriptor).first?.journalOffsetValue else {
            return .origin
        }
        return try journalOffset(value, operation: operation)
    }

    /// Validates the complete canonical store before any caller may apply a
    /// sequence/global cursor. This deliberately favors correctness over query
    /// cost; a future verified-watermark optimization must preserve the same
    /// fail-closed result.
    func validatedJournal(
        operation: AgentStoreOperation,
        in context: ModelContext
    ) throws -> SwiftDataValidatedJournal {
        let metadataRows = try context.fetch(
            FetchDescriptor<PersistedAgentRunMetadataRecord>()
        )
        var metadataByRunID: [RunID: AgentStore.AgentRunMetadataRecord] = [:]
        var runIDByAcceptanceCommand: [CommandID: RunID] = [:]
        for row in metadataRows {
            let metadata = try decodeMetadata(row, operation: operation)
            guard metadataByRunID.updateValue(
                metadata,
                forKey: metadata.runID
            ) == nil else {
                throw AgentStoreError.runConflict(metadata.runID)
            }
            if runIDByAcceptanceCommand.updateValue(
                metadata.runID,
                forKey: metadata.acceptanceCommandID
            ) != nil {
                throw AgentStoreError.corruptJournal(
                    runID: metadata.runID,
                    reason: .duplicateAcceptanceCommand(
                        metadata.acceptanceCommandID
                    )
                )
            }
        }

        // V1-V3 stores can legitimately contain accepted metadata without a
        // V4 composition because those released schemas never captured one.
        // Such a run remains replayable, but its recovery lookup fails closed
        // instead of fabricating route/tool/policy inputs. Every V4 row that is
        // present must be unique, canonical, and bound to existing metadata.
        let compositionRows = try context.fetch(
            FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
        )
        var executionCompositionsByRunID: [RunID: AgentRunExecutionComposition] = [:]
        for row in compositionRows {
            guard let rawRunID = UUID(uuidString: row.runIDString) else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "execution_composition_binding_mismatch"
                )
            }
            let runID = RunID(rawValue: rawRunID)
            guard let metadata = metadataByRunID[runID] else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "execution_composition_orphaned"
                )
            }
            let composition = try decodeExecutionComposition(
                row,
                metadata: metadata,
                operation: operation
            )
            guard executionCompositionsByRunID.updateValue(
                composition,
                forKey: runID
            ) == nil else {
                throw AgentStoreError.runConflict(runID)
            }
        }

        let eventRows = try context.fetch(
            FetchDescriptor<AgentEventRecord>(
                sortBy: [SortDescriptor(\AgentEventRecord.journalOffsetValue)]
            )
        )
        var records: [StoredAgentEvent] = []
        records.reserveCapacity(eventRows.count)
        var expectedOffset = AgentJournalOffset.origin
        var eventIDs = Set<EventID>()
        var idempotencyKeys = Set<String>()
        for row in eventRows {
            guard let nextOffset = expectedOffset.successor else {
                throw AgentStoreError.journalOffsetExhausted
            }
            let record = try decodeStoredEvent(row, operation: operation)
            guard record.offset == nextOffset else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "non_contiguous_offsets"
                )
            }
            expectedOffset = record.offset
            guard eventIDs.insert(record.event.header.eventID).inserted else {
                throw AgentStoreError.corruptJournal(
                    runID: record.runID,
                    reason: .duplicateEventID(record.event.header.eventID)
                )
            }
            let idempotencyIdentity = "\(record.runID.description):\(record.envelope.writerID.description):\(record.envelope.idempotencyKey)"
            guard idempotencyKeys.insert(idempotencyIdentity).inserted else {
                throw AgentStoreError.corruptJournal(
                    runID: record.runID,
                    reason: .duplicateIdempotencyKey(
                        writerID: record.envelope.writerID,
                        key: record.envelope.idempotencyKey
                    )
                )
            }
            records.append(record)
        }

        var recordsByRunID: [RunID: [StoredAgentEvent]] = [:]
        for record in records {
            recordsByRunID[record.runID, default: []].append(record)
        }
        for (runID, runRecords) in recordsByRunID {
            guard let metadata = metadataByRunID[runID] else {
                throw AgentStoreError.corruptJournal(
                    runID: runID,
                    reason: .metadataMissing
                )
            }
            _ = try AgentJournalReplay.replay(runRecords, metadata: metadata)
        }
        for runID in metadataByRunID.keys where recordsByRunID[runID] == nil {
            throw AgentStoreError.corruptJournal(
                runID: runID,
                reason: .emptyLedger
            )
        }

        return SwiftDataValidatedJournal(
            metadataByRunID: metadataByRunID,
            executionCompositionsByRunID: executionCompositionsByRunID,
            records: records,
            recordsByRunID: recordsByRunID,
            highWaterMark: records.last?.offset ?? .origin
        )
    }

    func fetchMetadata(
        runID: RunID,
        in context: ModelContext
    ) throws -> PersistedAgentRunMetadataRecord? {
        let value = runID.description
        var descriptor = FetchDescriptor<PersistedAgentRunMetadataRecord>(
            predicate: #Predicate { record in record.runIDString == value }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchMetadata(
        acceptanceCommandID: CommandID,
        in context: ModelContext
    ) throws -> PersistedAgentRunMetadataRecord? {
        let value = acceptanceCommandID.description
        var descriptor = FetchDescriptor<PersistedAgentRunMetadataRecord>(
            predicate: #Predicate { record in
                record.acceptanceCommandIDString == value
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchExecutionComposition(
        runID: RunID,
        in context: ModelContext
    ) throws -> PersistedAgentRunExecutionCompositionRecord? {
        let value = runID.description
        var descriptor = FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>(
            predicate: #Predicate { record in record.runIDString == value }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchLegacyRun(
        id: UUID,
        in context: ModelContext
    ) throws -> AgentRunRecord? {
        var descriptor = FetchDescriptor<AgentRunRecord>(
            predicate: #Predicate { record in record.id == id }
        )
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw SwiftDataAgentStoreIntegrityError.duplicateLegacyIdentity(
                kind: .run,
                id: id
            )
        }
        return matches.first
    }

    func fetchLegacyMessage(
        id: UUID,
        in context: ModelContext
    ) throws -> ChatMessage? {
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { record in record.id == id }
        )
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw SwiftDataAgentStoreIntegrityError.duplicateLegacyIdentity(
                kind: .message,
                id: id
            )
        }
        return matches.first
    }

    func fetchConversation(
        id: UUID,
        in context: ModelContext
    ) throws -> Conversation? {
        var descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { record in record.id == id }
        )
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw SwiftDataAgentStoreIntegrityError.duplicateLegacyIdentity(
                kind: .conversation,
                id: id
            )
        }
        return matches.first
    }

    func fetchProject(
        id: UUID,
        in context: ModelContext
    ) throws -> Project? {
        var descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { record in record.id == id }
        )
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw SwiftDataAgentStoreIntegrityError.duplicateLegacyIdentity(
                kind: .project,
                id: id
            )
        }
        return matches.first
    }

    func fetchMaterializedEvidenceRevision(
        projectID: UUID,
        in context: ModelContext
    ) throws -> ProjectMaterializedEvidenceRevisionRecord? {
        var descriptor = FetchDescriptor<ProjectMaterializedEvidenceRevisionRecord>(
            predicate: #Predicate { record in record.projectID == projectID }
        )
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw AgentStoreError.persistenceFailure(
                operation: .saveProjectionCursor,
                code: "duplicate_projection_evidence_revision_identity"
            )
        }
        return matches.first
    }

    func fetchLegacyTool(
        id: UUID,
        in context: ModelContext
    ) throws -> ToolRun? {
        var descriptor = FetchDescriptor<ToolRun>(
            predicate: #Predicate { record in record.id == id }
        )
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw SwiftDataAgentStoreIntegrityError.duplicateLegacyIdentity(
                kind: .tool,
                id: id
            )
        }
        return matches.first
    }

    func fetchApproval(
        id: String,
        in context: ModelContext
    ) throws -> ApprovalRequestRecord? {
        var descriptor = FetchDescriptor<ApprovalRequestRecord>(
            predicate: #Predicate { record in
                record.approvalRequestIDString == id
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchEvidence(
        key: String,
        in context: ModelContext
    ) throws -> ToolEffectEvidenceRecord? {
        var descriptor = FetchDescriptor<ToolEffectEvidenceRecord>(
            predicate: #Predicate { record in record.evidenceKey == key }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchArtifact(
        key: String,
        in context: ModelContext
    ) throws -> AgentArtifactProjectionRecord? {
        var descriptor = FetchDescriptor<AgentArtifactProjectionRecord>(
            predicate: #Predicate { record in
                record.artifactProjectionKey == key
            }
        )
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw projectionFailure("duplicate_artifact_projection_identity")
        }
        return matches.first
    }

    func fetchProjectOSRun(
        id: UUID,
        in context: ModelContext
    ) throws -> ProjectOSRun? {
        var descriptor = FetchDescriptor<ProjectOSRun>(
            predicate: #Predicate { record in record.id == id }
        )
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw SwiftDataAgentStoreIntegrityError.duplicateLegacyIdentity(
                kind: .projectOSRun,
                id: id
            )
        }
        return matches.first
    }

    func fetchEvent(
        eventID: EventID,
        in context: ModelContext
    ) throws -> AgentEventRecord? {
        let value = eventID.description
        var descriptor = FetchDescriptor<AgentEventRecord>(
            predicate: #Predicate { record in record.eventIDString == value }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchIdempotencyMatch(
        for envelope: AgentEventEnvelope,
        in context: ModelContext
    ) throws -> AgentEventRecord? {
        let key = AgentEventRecord.makeWriterIdempotencyKey(
            runIDString: envelope.runID.description,
            writerIDString: envelope.writerID.description,
            idempotencyKey: envelope.idempotencyKey
        )
        var descriptor = FetchDescriptor<AgentEventRecord>(
            predicate: #Predicate { record in record.writerIdempotencyKey == key }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchRunSequenceMatch(
        for envelope: AgentEventEnvelope,
        in context: ModelContext
    ) throws -> AgentEventRecord? {
        guard let value = Int64(exactly: envelope.writerSequence.rawValue) else { return nil }
        return try fetchRunSequenceMatch(runID: envelope.runID, sequenceValue: value, in: context)
    }

    func fetchRunSequenceMatch(
        runID: RunID,
        sequenceValue: Int64,
        in context: ModelContext
    ) throws -> AgentEventRecord? {
        let key = AgentEventRecord.makeRunSequenceKey(
            runIDString: runID.description,
            sequenceValue: sequenceValue
        )
        var descriptor = FetchDescriptor<AgentEventRecord>(
            predicate: #Predicate { record in record.runSequenceKey == key }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchEvents(
        runID: RunID,
        after sequence: EventSequence?,
        operation: AgentStoreOperation,
        in context: ModelContext
    ) throws -> [AgentEventRecord] {
        let runIDValue = runID.description
        let afterValue: Int64
        if let sequence {
            guard let exact = Int64(exactly: sequence.rawValue) else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "sequence_out_of_range"
                )
            }
            afterValue = exact
        } else {
            afterValue = 0
        }
        let records = try context.fetch(
            FetchDescriptor<AgentEventRecord>(
                predicate: #Predicate { record in
                    record.runIDString == runIDValue
                },
                sortBy: [SortDescriptor(\AgentEventRecord.sequenceValue)]
            )
        )
        // A cursor must never hide corruption in the durable prefix. Validate
        // the complete run ledger first, then return only the requested suffix.
        // This also prevents negative persisted sequences from being silently
        // excluded by a `sequenceValue > 0` predicate.
        for record in records {
            _ = try decodeStoredEvent(record, operation: operation)
        }
        return records.filter { $0.sequenceValue > afterValue }
    }

    func fetchCursor(key: String, in context: ModelContext) throws -> ProjectionCursorRecord? {
        var descriptor = FetchDescriptor<ProjectionCursorRecord>(
            predicate: #Predicate { record in
                record.cursorKey == key || record.projectionIDString == key
            }
        )
        descriptor.fetchLimit = 2
        let matches = try context.fetch(descriptor)
        guard matches.count <= 1 else {
            throw AgentStoreError.persistenceFailure(
                operation: .loadProjectionCursor,
                code: "duplicate_projection_cursor_identity"
            )
        }
        return matches.first
    }

    func fetchSnapshot(key: String, in context: ModelContext) throws -> ProjectionSnapshotRecord? {
        var descriptor = FetchDescriptor<ProjectionSnapshotRecord>(
            predicate: #Predicate { record in record.snapshotKey == key }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func fetchLatestSnapshot(
        runID: RunID,
        in context: ModelContext
    ) throws -> ProjectionSnapshotRecord? {
        let value = runID.description
        let projectionName = NovaForgeAgentProjection.canonicalReducer.rawValue
        let projectionVersion = NovaForgeAgentProjection.canonicalReducerVersion
        let encodingName = Self.stateEncodingName
        var descriptor = FetchDescriptor<ProjectionSnapshotRecord>(
            predicate: #Predicate { record in
                record.runIDString == value &&
                    record.projectionName == projectionName &&
                    record.projectionVersion == projectionVersion &&
                    record.stateEncodingName == encodingName
            },
            sortBy: [SortDescriptor(\ProjectionSnapshotRecord.throughSequenceValue, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func makeEventRecord(
        envelope: AgentEventEnvelope,
        offset: AgentJournalOffset,
        committedAt: AgentInstant
    ) throws -> AgentEventRecord {
        let operation = envelope.writerSequence == .first
            ? AgentStoreOperation.acceptRun
            : AgentStoreOperation.appendEvent
        let encoded: Data
        do {
            encoded = try codec.encode(envelope.event)
        } catch {
            throw AgentStoreError.persistenceFailure(operation: operation, code: "event_encode_failed")
        }
        guard let sequence = Int64(exactly: envelope.event.header.sequence.rawValue),
              let writerSequence = Int64(exactly: envelope.writerSequence.rawValue)
        else {
            throw AgentStoreError.sequenceExhausted(
                runID: envelope.runID,
                writerID: envelope.writerID
            )
        }
        let header = envelope.event.header
        return AgentEventRecord(
            journalOffsetValue: try persisted(offset, operation: operation),
            eventIDString: header.eventID.description,
            writerIDString: envelope.writerID.description,
            writerSequenceValue: writerSequence,
            idempotencyKey: envelope.idempotencyKey,
            runIDString: header.runID.description,
            rootRunIDString: header.rootRunID.description,
            parentRunIDString: header.parentRunID?.description,
            sequenceValue: sequence,
            timestampMilliseconds: header.timestamp.rawValue,
            executionNodeIDString: header.executionNodeID.description,
            conversationIDString: header.conversationID.description,
            projectIDString: header.projectID?.description,
            workspaceIDString: header.workspaceID.description,
            causationIDString: header.causationID?.description,
            correlationIDString: header.correlationID.description,
            schemaMajor: Int(header.schemaVersion.major),
            schemaMinor: Int(header.schemaVersion.minor),
            engineVersion: header.engineVersion.rawValue,
            eventKind: envelope.event.payload.kind.rawValue,
            encodingName: Self.eventEncodingName,
            encodingVersion: Self.encodingVersion,
            encodedEvent: encoded,
            payloadDigest: Self.sha256(encoded),
            committedAtMilliseconds: committedAt.rawValue,
            insertedAt: committedAt.date
        )
    }

    func makeMetadataRecord(
        _ metadata: AgentStore.AgentRunMetadataRecord,
        createdAt: AgentInstant
    ) throws -> PersistedAgentRunMetadataRecord {
        let encoded = try encodeDeterministically(metadata, operation: .acceptRun)
        let context = metadata.context
        let features = try encodeDeterministically(context.features.values, operation: .acceptRun)
        return PersistedAgentRunMetadataRecord(
            runIDString: metadata.runID.description,
            rootRunIDString: context.lineage.rootRunID.description,
            parentRunIDString: context.lineage.parentRunID?.description,
            writerIDString: metadata.writerID.description,
            acceptanceCommandIDString: metadata.acceptanceCommandID.description,
            engineVersion: context.engineVersion.rawValue,
            enabledFeaturesJSON: features,
            executionNodeIDString: context.executionNodeID.description,
            conversationIDString: context.conversationID.description,
            projectIDString: context.projectID?.description,
            workspaceIDString: context.workspaceID.description,
            acceptedEventIDString: metadata.acceptanceEventID.description,
            acceptedAtMilliseconds: context.acceptedAt.rawValue,
            encodingName: Self.metadataEncodingName,
            encodingVersion: Self.encodingVersion,
            encodedMetadata: encoded,
            metadataDigest: Self.sha256(encoded),
            createdAt: createdAt.date
        )
    }

    func decodeMetadata(
        _ record: PersistedAgentRunMetadataRecord,
        operation: AgentStoreOperation
    ) throws -> AgentStore.AgentRunMetadataRecord {
        guard record.encodingName == Self.metadataEncodingName,
              record.encodingVersion == Self.encodingVersion,
              Self.sha256(record.encodedMetadata) == record.metadataDigest
        else {
            throw AgentStoreError.persistenceFailure(operation: operation, code: "metadata_integrity_failed")
        }
        do {
            let metadata = try JSONDecoder().decode(
                AgentStore.AgentRunMetadataRecord.self,
                from: record.encodedMetadata
            )
            let context = metadata.context
            let encodedFeatures = try encodeDeterministically(
                context.features.values,
                operation: operation
            )
            guard metadata.runID.description == record.runIDString,
                  context.lineage.rootRunID.description == record.rootRunIDString,
                  context.lineage.parentRunID?.description == record.parentRunIDString,
                  metadata.writerID.description == record.writerIDString,
                  metadata.acceptanceCommandID.description == record.acceptanceCommandIDString,
                  context.engineVersion.rawValue == record.engineVersion,
                  encodedFeatures == record.enabledFeaturesJSON,
                  context.executionNodeID.description == record.executionNodeIDString,
                  context.conversationID.description == record.conversationIDString,
                  context.projectID?.description == record.projectIDString,
                  context.workspaceID.description == record.workspaceIDString,
                  metadata.acceptanceEventID.description == record.acceptedEventIDString,
                  context.acceptedAt.rawValue == record.acceptedAtMilliseconds
            else {
                throw AgentStoreError.corruptJournal(
                    runID: metadata.runID,
                    reason: .metadataContextMismatch
                )
            }
            return metadata
        } catch let error as AgentStoreError {
            throw error
        } catch {
            throw AgentStoreError.persistenceFailure(operation: operation, code: "metadata_decode_failed")
        }
    }

    func makeExecutionCompositionRecord(
        _ composition: AgentRunExecutionComposition,
        createdAt: AgentInstant
    ) throws -> PersistedAgentRunExecutionCompositionRecord {
        do {
            try composition.validate()
        } catch {
            throw AgentStoreError.persistenceFailure(
                operation: .acceptRun,
                code: "execution_composition_invalid"
            )
        }
        let encoded = try encodeDeterministically(
            composition,
            operation: .acceptRun
        )
        return PersistedAgentRunExecutionCompositionRecord(
            runIDString: composition.runID.description,
            conversationIDString: composition.conversationID.description,
            projectIDString: composition.projectID?.description,
            workspaceIDString: composition.workspaceID.description,
            executionNodeIDString: composition.executionNodeID.description,
            runContextDigest: composition.runContextDigest,
            providerID: composition.providerRoute.providerID.rawValue,
            modelID: composition.providerRoute.modelID.rawValue,
            adapterID: composition.providerRoute.adapterID.rawValue,
            toolRegistryDigest: composition.toolRegistryDigest,
            toolLocalitiesDigest: composition.toolLocalitiesDigest,
            policyVersion: composition.policyVersion,
            contextPreparationVersion: composition.contextPreparationVersion,
            systemInstructionDigest: composition.systemInstructionDigest,
            developerInstructionDigest: composition.developerInstructionDigest,
            encodingName: Self.executionCompositionEncodingName,
            encodingVersion: Self.encodingVersion,
            encodedComposition: encoded,
            compositionDigest: Self.sha256(encoded),
            createdAt: createdAt.date
        )
    }

    func decodeExecutionComposition(
        _ record: PersistedAgentRunExecutionCompositionRecord,
        metadata: AgentStore.AgentRunMetadataRecord,
        operation: AgentStoreOperation
    ) throws -> AgentRunExecutionComposition {
        guard record.encodingName == Self.executionCompositionEncodingName,
              record.encodingVersion == Self.encodingVersion,
              Self.sha256(record.encodedComposition) == record.compositionDigest
        else {
            throw AgentStoreError.persistenceFailure(
                operation: operation,
                code: "execution_composition_integrity_failed"
            )
        }
        do {
            let composition = try JSONDecoder().decode(
                AgentRunExecutionComposition.self,
                from: record.encodedComposition
            )
            try composition.validate(matching: metadata.context)
            let canonical = try encodeDeterministically(
                composition,
                operation: operation
            )
            guard canonical == record.encodedComposition else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "execution_composition_noncanonical"
                )
            }
            guard composition.runID.description == record.runIDString,
                  composition.conversationID.description == record.conversationIDString,
                  composition.projectID?.description == record.projectIDString,
                  composition.workspaceID.description == record.workspaceIDString,
                  composition.executionNodeID.description == record.executionNodeIDString,
                  composition.runContextDigest == record.runContextDigest,
                  composition.providerRoute.providerID.rawValue == record.providerID,
                  composition.providerRoute.modelID.rawValue == record.modelID,
                  composition.providerRoute.adapterID.rawValue == record.adapterID,
                  composition.toolRegistryDigest == record.toolRegistryDigest,
                  composition.toolLocalitiesDigest == record.toolLocalitiesDigest,
                  composition.policyVersion == record.policyVersion,
                  composition.contextPreparationVersion == record.contextPreparationVersion,
                  composition.systemInstructionDigest == record.systemInstructionDigest,
                  composition.developerInstructionDigest == record.developerInstructionDigest
            else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "execution_composition_binding_mismatch"
                )
            }
            return composition
        } catch let error as AgentStoreError {
            throw error
        } catch is AgentRunExecutionCompositionError {
            throw AgentStoreError.persistenceFailure(
                operation: operation,
                code: "execution_composition_invalid"
            )
        } catch {
            throw AgentStoreError.persistenceFailure(
                operation: operation,
                code: "execution_composition_decode_failed"
            )
        }
    }

    func decodeStoredEvent(
        _ record: AgentEventRecord,
        operation: AgentStoreOperation
    ) throws -> StoredAgentEvent {
        guard record.encodingName == Self.eventEncodingName,
              record.encodingVersion == Self.encodingVersion,
              Self.sha256(record.encodedEvent) == record.payloadDigest
        else {
            throw AgentStoreError.persistenceFailure(operation: operation, code: "event_integrity_failed")
        }
        let event: AgentEvent
        do {
            event = try codec.decode(record.encodedEvent)
        } catch {
            throw AgentStoreError.persistenceFailure(operation: operation, code: "event_decode_failed")
        }
        guard record.sequenceValue > 0, record.writerSequenceValue > 0 else {
            throw AgentStoreError.persistenceFailure(
                operation: operation,
                code: "negative_or_zero_sequence"
            )
        }
        guard record.journalOffsetValue > 0 else {
            throw AgentStoreError.persistenceFailure(
                operation: operation,
                code: "invalid_journal_offset"
            )
        }
        guard let indexedRunUUID = UUID(uuidString: record.runIDString) else {
            throw AgentStoreError.persistenceFailure(
                operation: operation,
                code: "indexed_run_id_invalid"
            )
        }
        let indexedRunID = RunID(rawValue: indexedRunUUID)
        guard event.header.runID == indexedRunID else {
            throw AgentStoreError.corruptJournal(
                runID: event.header.runID,
                reason: .runMismatch(
                    expected: indexedRunID,
                    actual: event.header.runID
                )
            )
        }
        guard let writerUUID = UUID(uuidString: record.writerIDString) else {
            throw AgentStoreError.persistenceFailure(operation: operation, code: "writer_id_invalid")
        }
        let indexedWriterID = AgentEventWriterID(rawValue: writerUUID)
        let expectedWriterID = AgentEventWriterID(runID: indexedRunID)
        guard indexedWriterID == expectedWriterID else {
            throw AgentStoreError.corruptJournal(
                runID: indexedRunID,
                reason: .writerMismatch(
                    expected: expectedWriterID,
                    actual: indexedWriterID
                )
            )
        }
        let eventSequence = EventSequence(rawValue: UInt64(record.sequenceValue))
        let writerSequence = EventSequence(rawValue: UInt64(record.writerSequenceValue))
        let indexedHeaderMatches =
            event.header.eventID.description == record.eventIDString &&
            event.header.rootRunID.description == record.rootRunIDString &&
            event.header.parentRunID?.description == record.parentRunIDString &&
            event.header.sequence == eventSequence &&
            event.header.timestamp.rawValue == record.timestampMilliseconds &&
            event.header.executionNodeID.description == record.executionNodeIDString &&
            event.header.conversationID.description == record.conversationIDString &&
            event.header.projectID?.description == record.projectIDString &&
            event.header.workspaceID.description == record.workspaceIDString &&
            event.header.causationID?.description == record.causationIDString &&
            event.header.correlationID.description == record.correlationIDString &&
            Int(event.header.schemaVersion.major) == record.schemaMajor &&
            Int(event.header.schemaVersion.minor) == record.schemaMinor &&
            event.header.engineVersion.rawValue == record.engineVersion &&
            event.payload.kind.rawValue == record.eventKind &&
            eventSequence == writerSequence &&
            record.runSequenceKey == AgentEventRecord.makeRunSequenceKey(
                runIDString: record.runIDString,
                sequenceValue: record.sequenceValue
            ) &&
            record.writerSequenceKey == AgentEventRecord.makeWriterSequenceKey(
                runIDString: record.runIDString,
                writerIDString: record.writerIDString,
                writerSequenceValue: record.writerSequenceValue
            ) &&
            record.writerIdempotencyKey == AgentEventRecord.makeWriterIdempotencyKey(
                runIDString: record.runIDString,
                writerIDString: record.writerIDString,
                idempotencyKey: record.idempotencyKey
            )
        guard indexedHeaderMatches else {
            throw AgentStoreError.persistenceFailure(
                operation: operation,
                code: "event_header_index_mismatch"
            )
        }
        return StoredAgentEvent(
            offset: try journalOffset(record.journalOffsetValue, operation: operation),
            committedAt: AgentInstant(rawValue: record.committedAtMilliseconds),
            envelope: AgentEventEnvelope(
                writerID: indexedWriterID,
                writerSequence: writerSequence,
                idempotencyKey: record.idempotencyKey,
                event: event
            )
        )
    }

    func decodeState(
        _ record: ProjectionSnapshotRecord,
        runID: RunID,
        operation: AgentStoreOperation
    ) throws -> AgentDomain.AgentRunState {
        guard record.stateEncodingName == Self.stateEncodingName,
              record.stateEncodingVersion == Self.encodingVersion,
              record.runIDString == runID.description,
              record.throughSequenceValue > 0,
              Self.sha256(record.encodedState) == record.stateDigest
        else {
            throw AgentStoreError.persistenceFailure(operation: operation, code: "snapshot_integrity_failed")
        }
        do {
            let state = try JSONDecoder().decode(
                AgentDomain.AgentRunState.self,
                from: record.encodedState
            )
            guard state.context?.lineage.runID == runID,
                  state.lastSequence?.rawValue == UInt64(record.throughSequenceValue),
                  state.lastEventID?.description == record.throughEventIDString
            else {
                throw AgentStoreError.persistenceFailure(
                    operation: operation,
                    code: "snapshot_boundary_mismatch"
                )
            }
            return state
        } catch let error as AgentStoreError {
            throw error
        } catch {
            throw AgentStoreError.persistenceFailure(operation: operation, code: "snapshot_decode_failed")
        }
    }

    func makeCursor(
        _ record: ProjectionCursorRecord,
        expectedKey: String? = nil,
        operation: AgentStoreOperation
    ) throws -> AgentProjectionCursor {
        let derivedKey = ProjectionCursorRecord.makeCursorKey(
            projectionIDString: record.projectionIDString
        )
        guard record.cursorKey == derivedKey,
              expectedKey == nil || expectedKey == record.cursorKey,
              !record.projectionIDString.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            throw AgentStoreError.persistenceFailure(
                operation: operation,
                code: "projection_cursor_integrity_failed"
            )
        }
        return AgentProjectionCursor(
            projectionID: AgentProjectionID(rawValue: record.projectionIDString),
            throughOffset: try journalOffset(record.throughOffsetValue, operation: operation),
            updatedAt: AgentInstant(rawValue: record.updatedAtMilliseconds)
        )
    }

    func validatedProjectionKey(_ projectionID: AgentProjectionID) throws -> String {
        let key = projectionID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw AgentStoreError.invalidProjectionID
        }
        return projectionID.rawValue
    }

    func persisted(
        _ offset: AgentJournalOffset,
        operation: AgentStoreOperation
    ) throws -> Int64 {
        guard let value = Int64(exactly: offset.rawValue) else {
            throw AgentStoreError.persistenceFailure(operation: operation, code: "offset_out_of_range")
        }
        return value
    }

    func journalOffset(
        _ persisted: Int64,
        operation: AgentStoreOperation
    ) throws -> AgentJournalOffset {
        guard persisted >= 0 else {
            throw AgentStoreError.persistenceFailure(operation: operation, code: "negative_offset")
        }
        return AgentJournalOffset(rawValue: UInt64(persisted))
    }

    func encodeDeterministically<Value: Encodable>(
        _ value: Value,
        operation: AgentStoreOperation
    ) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(value)
        } catch {
            throw AgentStoreError.persistenceFailure(operation: operation, code: "json_encode_failed")
        }
    }

#if DEBUG
    static func debugCompatibilityComposition(
        acceptance: AgentRunAcceptance,
        legacyProjection: SwiftDataLegacyAcceptanceProjection
    ) throws -> AgentRunExecutionComposition {
        try AgentRunExecutionComposition(
            context: acceptance.metadata.context,
            providerRoute: ProviderRoute(
                providerID: ProviderID(
                    rawValue: legacyProjection.providerRawValue ?? "debug-test-provider"
                ),
                modelID: ProviderModelID(
                    rawValue: legacyProjection.modelID ?? "debug-test-model"
                ),
                adapterID: ProviderAdapterID(
                    rawValue: "debug-persistence-test-adapter-v1"
                ),
                capabilities: .openAIChatBaseline,
                deployment: .callerManaged,
                provenance: .callerConfigured
            ),
            providerOptions: ProviderGenerationOptions(
                maximumOutputTokens: 1_024,
                temperature: 0,
                parallelToolCalls: false,
                toolChoice: .none
            ),
            toolRegistry: try ToolRegistry(tools: []),
            toolLocalities: [:],
            policyVersion: "debug-persistence-test-policy-v1",
            contextPreparationVersion: "debug-persistence-test-context-v1",
            systemInstruction: nil,
            developerInstruction: nil
        )
    }
#endif

    func map(_ error: Error, operation: AgentStoreOperation) -> Error {
        if let storeError = error as? AgentStoreError { return storeError }
        if let integrityError = error as? SwiftDataAgentStoreIntegrityError {
            return integrityError
        }
        if let dispositionError = error as? SwiftDataMaterializationDispositionError {
            return dispositionError
        }
        if error is AgentEventCodecError {
            return AgentStoreError.persistenceFailure(operation: operation, code: "event_codec_failed")
        }
        return AgentStoreError.persistenceFailure(operation: operation, code: "swiftdata_operation_failed")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

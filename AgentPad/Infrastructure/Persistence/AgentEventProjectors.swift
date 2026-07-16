import AgentDomain
import AgentStore
import Foundation

enum NovaForgeMaterializedProjection {
    static let legacyRun = AgentProjectionID(rawValue: "legacy-run-projector:v1")
    static let projectOS = AgentProjectionID(rawValue: "projectos-projector:v1")
}

struct AgentEventProjectionReport: Equatable, Sendable {
    let projectionID: AgentProjectionID
    let startingOffset: AgentJournalOffset
    let endingOffset: AgentJournalOffset
    let projectedEventCount: Int
    let committedBatchCount: Int
}

enum AgentEventProjectorError: Error, Equatable, Sendable {
    case sequenceOutOfRange(EventSequence)
    case valueEncodingFailed
    case emptyRunPrefix
    case mixedRunPrefix
    case projectionConflict(String)
}

struct SwiftDataLegacyAcceptanceCheck: Equatable, Sendable {
    let runID: UUID
    let conversationID: UUID
    let projectID: UUID?
    let workspaceID: UUID
    let requestText: String
}

struct SwiftDataLegacyRunStatusProjection: Equatable, Sendable {
    let runID: UUID
    let allowedStatuses: [AgentRunStatus]
    let status: AgentRunStatus
    let at: AgentInstant
    let errorKind: AgentRunErrorKind?
    let errorMessage: String?

    init(
        runID: UUID,
        allowedStatuses: [AgentRunStatus],
        status: AgentRunStatus,
        at: AgentInstant,
        errorKind: AgentRunErrorKind? = nil,
        errorMessage: String? = nil
    ) {
        self.runID = runID
        self.allowedStatuses = allowedStatuses
        self.status = status
        self.at = at
        self.errorKind = errorKind
        self.errorMessage = errorMessage
    }
}

struct SwiftDataLegacyRouteProjection: Equatable, Sendable {
    let runID: UUID
    let provider: String
    let modelID: String
}

struct SwiftDataLegacyMessageProjection: Equatable, Sendable {
    let messageID: UUID
    let runID: UUID
    let conversationID: UUID
    let sequence: Int
    let role: ChatRole
    let content: String
    let createdAt: AgentInstant
}

struct SwiftDataLegacyToolProjection: Equatable, Sendable {
    let callID: UUID
    let runID: UUID
    let projectID: UUID?
    let sequence: Int
    let name: String
    let argumentsJSON: String?
    let outputJSON: String?
    let status: ToolRunStatus
    let requiresApproval: Bool?
    let isMutating: Bool?
    let occurredAt: AgentInstant
}

struct SwiftDataApprovalRequestProjection: Equatable, Sendable {
    let eventID: UUID
    let runID: UUID
    let workspaceID: UUID
    let request: ApprovalRequest
}

struct SwiftDataApprovalResolutionProjection: Equatable, Sendable {
    let eventID: UUID
    let runID: UUID
    let resolution: ApprovalResolution
}

struct SwiftDataToolEvidenceProjection: Equatable, Sendable {
    let eventID: UUID
    let runID: UUID
    let workspaceID: UUID
    let callID: UUID
    let occurredAt: AgentInstant
    let evidence: [ToolEvidence]
}

struct SwiftDataCanonicalApprovalSnapshot: Equatable, Sendable {
    let requestEventID: UUID
    let resolutionEventID: UUID?
    let request: ApprovalRequest
    let resolution: ApprovalResolution?
}

struct SwiftDataCanonicalEvidenceSnapshot: Equatable, Sendable {
    let eventID: UUID
    let callID: UUID
    let occurredAt: AgentInstant
    let evidence: ToolEvidence
}

struct SwiftDataCanonicalArtifactSnapshot: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case artifactCaptured
        case toolResult
    }

    let eventID: UUID
    let callID: UUID?
    let occurredAt: AgentInstant
    let source: Source
    let artifact: ArtifactReference
}

struct SwiftDataLegacyMessageSnapshot: Equatable, Sendable {
    let messageID: UUID
    let sequence: Int
    let role: ChatRole
    let content: String
    let createdAt: AgentInstant
}

struct SwiftDataLegacyToolSnapshot: Equatable, Sendable {
    let callID: UUID
    let sequence: Int
    let name: String
    let argumentsJSON: String
    let outputJSON: String
    let status: ToolRunStatus
    let requiresApproval: Bool
    let isMutating: Bool
    let createdAt: AgentInstant
    let completedAt: AgentInstant?
}

/// Absolute, canonical-owned legacy state through one validated run prefix.
/// Existing V1 rows that are not linked to this RunID are outside its scope.
struct SwiftDataLegacyRunSnapshot: Equatable, Sendable {
    let acceptance: SwiftDataLegacyAcceptanceCheck
    let status: AgentRunStatus
    let updatedAt: AgentInstant
    let startedAt: AgentInstant?
    let completedAt: AgentInstant?
    let errorKind: AgentRunErrorKind?
    let errorMessage: String?
    let observedRoute: SwiftDataLegacyRouteProjection?
    let responseMessageID: UUID?
    let messages: [SwiftDataLegacyMessageSnapshot]
    let tools: [SwiftDataLegacyToolSnapshot]
    let approvals: [SwiftDataCanonicalApprovalSnapshot]
    let evidence: [SwiftDataCanonicalEvidenceSnapshot]
    let artifacts: [SwiftDataCanonicalArtifactSnapshot]
}

struct SwiftDataProjectOSAcceptanceProjection: Equatable, Sendable {
    let runID: UUID
    let conversationID: UUID
    let projectID: UUID?
    let mission: String
    let acceptedAt: AgentInstant
}

struct SwiftDataProjectOSRunProjection: Equatable, Sendable {
    let runID: UUID
    let projectID: UUID?
    let status: ProjectOSRunStatus?
    let planningState: String?
    let currentAction: String?
    let currentCommand: String?
    let nextStep: String?
    let latestEventTitle: String
    let latestEventDetail: String
    let changedFilesSummary: String?
    let artifactsSummary: String?
    let proofSummary: String?
    let blockerReason: String?
    let waitingReason: String?
    let failureReason: String?
    let resumeState: String?
    let occurredAt: AgentInstant
    let marksComplete: Bool

    init(
        runID: UUID,
        projectID: UUID?,
        status: ProjectOSRunStatus? = nil,
        planningState: String? = nil,
        currentAction: String? = nil,
        currentCommand: String? = nil,
        nextStep: String? = nil,
        latestEventTitle: String,
        latestEventDetail: String = "",
        changedFilesSummary: String? = nil,
        artifactsSummary: String? = nil,
        proofSummary: String? = nil,
        blockerReason: String? = nil,
        waitingReason: String? = nil,
        failureReason: String? = nil,
        resumeState: String? = nil,
        occurredAt: AgentInstant,
        marksComplete: Bool = false
    ) {
        self.runID = runID
        self.projectID = projectID
        self.status = status
        self.planningState = planningState
        self.currentAction = currentAction
        self.currentCommand = currentCommand
        self.nextStep = nextStep
        self.latestEventTitle = latestEventTitle
        self.latestEventDetail = latestEventDetail
        self.changedFilesSummary = changedFilesSummary
        self.artifactsSummary = artifactsSummary
        self.proofSummary = proofSummary
        self.blockerReason = blockerReason
        self.waitingReason = waitingReason
        self.failureReason = failureReason
        self.resumeState = resumeState
        self.occurredAt = occurredAt
        self.marksComplete = marksComplete
    }
}

/// Absolute ProjectOS-owned fields through one validated run prefix.
struct SwiftDataProjectOSRunSnapshot: Equatable, Sendable {
    let runID: UUID
    let conversationID: UUID
    let projectID: UUID?
    let workspaceID: UUID
    let mission: String
    let status: ProjectOSRunStatus
    let planningState: String
    let currentAction: String
    let currentCommand: String
    let nextStep: String
    let latestEventTitle: String
    let latestEventDetail: String
    let changedFilesSummary: String
    let artifactsSummary: String
    let proofSummary: String
    let blockerReason: String
    let waitingReason: String
    let failureReason: String
    let resumeState: String
    let acceptedAt: AgentInstant
    let updatedAt: AgentInstant
    let completedAt: AgentInstant?
    let progressEventCount: Int
}

/// Read-model projector for the existing chat, run-history, tool, approval,
/// and effect-evidence surfaces. It only translates committed journal events;
/// it cannot invoke providers, tools, or workspace mutations.
struct LegacyRunProjector: Sendable {
    static let projectionID = NovaForgeMaterializedProjection.legacyRun

    let store: SwiftDataAgentStore
    let batchSize: Int
    let projectionID: AgentProjectionID

    init(
        store: SwiftDataAgentStore,
        batchSize: Int = 64,
        projectionID: AgentProjectionID = Self.projectionID
    ) {
        self.store = store
        self.batchSize = max(1, batchSize)
        self.projectionID = projectionID
    }

    func projectAvailableEvents() async throws -> AgentEventProjectionReport {
        let startingOffset = try await store.loadCursor(for: projectionID)?.throughOffset ?? .origin
        var expectedOffset = startingOffset
        var eventCount = 0
        var batchCount = 0

        while true {
            let validated = try await store.validatedProjectionBatch(
                after: expectedOffset,
                limit: batchSize
            )
            let batch = validated.batch
            guard !batch.records.isEmpty else { break }
            let plan = try Self.plan(
                forRunPrefixes: validated.runPrefixes,
                canonicalScopes: validated.canonicalAcceptanceScopes,
                disposition: validated.materializationDisposition
            )
            let cursor = AgentProjectionCursor(
                projectionID: projectionID,
                throughOffset: batch.throughOffset,
                updatedAt: batch.records.last?.committedAt ?? AgentInstant(rawValue: 0)
            )
            do {
                _ = try await store.commitProjection(
                    plan,
                    cursor: cursor,
                    expectedPreviousOffset: expectedOffset
                )
            } catch let error as SwiftDataMaterializationDispositionError {
                guard case .staleProjectionPlan = error else { throw error }
                // Re-read the exact same offset and batch under the new policy.
                // Counts and cursor state advance only after a successful commit.
                continue
            }
            expectedOffset = batch.throughOffset
            eventCount += batch.records.count
            batchCount += 1
            if !batch.hasMore { break }
        }

        return AgentEventProjectionReport(
            projectionID: projectionID,
            startingOffset: startingOffset,
            endingOffset: expectedOffset,
            projectedEventCount: eventCount,
            committedBatchCount: batchCount
        )
    }

    static func plan(
        for records: [StoredAgentEvent],
        disposition: SwiftDataMaterializationDispositionSnapshot = .empty
    ) throws -> SwiftDataAgentProjectionPlan {
        var grouped: [RunID: [StoredAgentEvent]] = [:]
        for record in records {
            grouped[record.runID, default: []].append(record)
        }
        let scopes = grouped.compactMap { runID, values -> SwiftDataCanonicalAcceptanceScope? in
            guard let first = values.min(by: {
                $0.envelope.writerSequence < $1.envelope.writerSequence
            }), case let .runAccepted(payload) = first.event.payload else { return nil }
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
        }
        return try plan(
            forRunPrefixes: grouped,
            canonicalScopes: scopes,
            disposition: disposition
        )
    }

    static func plan(
        forRunPrefixes prefixes: [RunID: [StoredAgentEvent]],
        canonicalScopes: [SwiftDataCanonicalAcceptanceScope]? = nil,
        disposition: SwiftDataMaterializationDispositionSnapshot = .empty
    ) throws -> SwiftDataAgentProjectionPlan {
        let snapshots = try prefixes.values.map(snapshot(for:)).sorted {
            $0.acceptance.runID.uuidString < $1.acceptance.runID.uuidString
        }
        let scopes = canonicalScopes ?? snapshots.map {
            SwiftDataCanonicalAcceptanceScope(
                acceptance: $0.acceptance
            )
        }
        let retainedRunIDs = Set(snapshots.map { $0.acceptance.runID })
        let futureScopes = scopes.filter {
            !retainedRunIDs.contains($0.runID.rawValue)
        }
        let conversationIDs = Set(scopes.map(\.conversationID.rawValue)).filter {
            !disposition.suppressesConversation($0)
        }
        let reconciliations = conversationIDs.map { conversationID in
            SwiftDataLegacyConversationReconciliation(
                conversationID: conversationID,
                projectedThrough: snapshots
                    .filter { $0.acceptance.conversationID == conversationID }
                    .map(\.updatedAt)
                    .max()
            )
        }.sorted { $0.conversationID.uuidString < $1.conversationID.uuidString }
        return SwiftDataAgentProjectionPlan(
            mutations: [
                .resetLegacyRuns(futureScopes)
            ] + snapshots.map(SwiftDataAgentProjectionMutation.replaceLegacyRun) + [
                .reconcileLegacyConversations(reconciliations)
            ],
            evidenceProjectIDs: (
                scopes.compactMap { $0.projectID?.rawValue }
                    + snapshots.compactMap { $0.acceptance.projectID }
            ).filter { !disposition.rehomedProjectIDs.contains($0) },
            expectedDispositionFingerprint: disposition.fingerprint
        )
    }

    private static func snapshot(
        for unsortedRecords: [StoredAgentEvent]
    ) throws -> SwiftDataLegacyRunSnapshot {
        let records = unsortedRecords.sorted {
            $0.envelope.writerSequence < $1.envelope.writerSequence
        }
        guard let first = records.first else {
            throw AgentEventProjectorError.emptyRunPrefix
        }
        let runID = first.runID
        guard records.allSatisfy({ $0.runID == runID }),
              case let .runAccepted(accepted) = first.event.payload
        else {
            throw AgentEventProjectorError.mixedRunPrefix
        }
        let state = try AgentJournalReplay.replay(records)
        let context = accepted.context
        let finalStatus = legacyStatus(state.phase)

        var route: SwiftDataLegacyRouteProjection?
        var messagesByID: [UUID: SwiftDataLegacyMessageSnapshot] = [:]
        var latestAssistantID: UUID?
        var toolSequence: [ToolCallID: Int] = [:]
        var toolCreatedAt: [ToolCallID: AgentInstant] = [:]
        var toolCompletedAt: [ToolCallID: AgentInstant] = [:]
        var requestEventID: [ApprovalRequestID: UUID] = [:]
        var resolutionEventID: [ApprovalRequestID: UUID] = [:]
        var evidenceByKey: [String: SwiftDataCanonicalEvidenceSnapshot] = [:]
        var artifactsByKey: [String: SwiftDataCanonicalArtifactSnapshot] = [:]
        var startedAt: AgentInstant?

        for record in records {
            let event = record.event
            let header = event.header
            let sequence = try persistedSequence(header.sequence)
            switch event.payload {
            case .runStarted:
                if startedAt == nil { startedAt = header.timestamp }
            case let .modelRequestStarted(payload):
                route = SwiftDataLegacyRouteProjection(
                    runID: runID.rawValue,
                    provider: payload.route.provider,
                    modelID: payload.route.model
                )
            case let .providerRouteChanged(payload):
                route = SwiftDataLegacyRouteProjection(
                    runID: runID.rawValue,
                    provider: payload.to.provider,
                    modelID: payload.to.model
                )
            case let .modelResponseCommitted(payload):
                for item in payload.items {
                    guard case let .message(message) = item.payload else { continue }
                    let projected = SwiftDataLegacyMessageSnapshot(
                        messageID: item.id.rawValue,
                        sequence: sequence,
                        role: legacyRole(message.role),
                        content: canonicalRenderedContent(message.content),
                        createdAt: item.createdAt
                    )
                    if let existing = messagesByID[projected.messageID],
                       existing != projected {
                        throw AgentEventProjectorError.projectionConflict(
                            "message:\(projected.messageID.uuidString)"
                        )
                    }
                    messagesByID[projected.messageID] = projected
                    if projected.role == .assistant {
                        latestAssistantID = projected.messageID
                    }
                }
            case let .toolProposed(payload):
                let callID = payload.invocation.callID
                toolSequence[callID] = sequence
                toolCreatedAt[callID] = header.timestamp
            case let .approvalRequested(payload):
                let callID = payload.request.binding.callID
                toolSequence[callID] = sequence
                requestEventID[payload.request.requestID] = header.eventID.rawValue
            case let .approvalResolved(payload):
                let callID = payload.resolution.callID
                toolSequence[callID] = sequence
                resolutionEventID[payload.resolution.requestID] = header.eventID.rawValue
                if payload.resolution.decision == .rejected {
                    toolCompletedAt[callID] = header.timestamp
                }
            case let .toolScheduled(payload):
                toolSequence[payload.callID] = sequence
            case let .toolStarted(payload):
                toolSequence[payload.callID] = sequence
            case let .toolApplied(payload):
                toolSequence[payload.callID] = sequence
                try collectEvidence(
                    payload.evidence,
                    eventID: header.eventID.rawValue,
                    callID: payload.callID.rawValue,
                    occurredAt: header.timestamp,
                    into: &evidenceByKey
                )
            case let .toolCompleted(payload):
                let callID = payload.result.callID
                toolSequence[callID] = sequence
                toolCompletedAt[callID] = header.timestamp
                try collectEvidence(
                    payload.result.evidence,
                    eventID: header.eventID.rawValue,
                    callID: callID.rawValue,
                    occurredAt: header.timestamp,
                    into: &evidenceByKey
                )
                try collectArtifacts(
                    payload.result.artifacts,
                    eventID: header.eventID.rawValue,
                    callID: callID.rawValue,
                    occurredAt: header.timestamp,
                    source: .toolResult,
                    into: &artifactsByKey
                )
            case let .artifactCaptured(payload):
                try collectArtifacts(
                    [payload.artifact],
                    eventID: header.eventID.rawValue,
                    callID: nil,
                    occurredAt: header.timestamp,
                    source: .artifactCaptured,
                    into: &artifactsByKey
                )
            default:
                break
            }
        }

        var tools: [SwiftDataLegacyToolSnapshot] = []
        tools.reserveCapacity(state.tools.count)
        for tool in state.tools {
            let invocation = tool.invocation
            guard let createdAt = toolCreatedAt[invocation.callID],
                  let sequence = toolSequence[invocation.callID]
            else {
                throw AgentEventProjectorError.projectionConflict(
                    "tool:\(invocation.callID.description)"
                )
            }
            let status: ToolRunStatus
            switch tool.status {
            case .proposed:
                status = invocation.effectClass == .readOnlyLocal
                    ? .approved
                    : .pendingApproval
            case .awaitingApproval:
                status = .pendingApproval
            case .approved, .scheduled, .running, .applied:
                status = .approved
            case .rejected:
                status = .rejected
            case .completed:
                status = tool.result?.status == .succeeded ? .completed : .failed
            }
            tools.append(
                SwiftDataLegacyToolSnapshot(
                    callID: invocation.callID.rawValue,
                    sequence: sequence,
                    name: invocation.tool.name,
                    argumentsJSON: try encodedString(invocation.arguments),
                    outputJSON: try tool.result.map { try encodedString($0.output) } ?? "",
                    status: status,
                    requiresApproval: invocation.effectClass != .readOnlyLocal,
                    isMutating: invocation.effectClass != .readOnlyLocal,
                    createdAt: createdAt,
                    completedAt: toolCompletedAt[invocation.callID]
                )
            )
        }

        var approvals: [SwiftDataCanonicalApprovalSnapshot] = []
        approvals.reserveCapacity(state.approvals.count)
        for approval in state.approvals {
            guard let requestedEvent = requestEventID[approval.request.requestID] else {
                throw AgentEventProjectorError.projectionConflict(
                    "approval:\(approval.request.requestID.description)"
                )
            }
            approvals.append(
                SwiftDataCanonicalApprovalSnapshot(
                    requestEventID: requestedEvent,
                    resolutionEventID: resolutionEventID[approval.request.requestID],
                    request: approval.request,
                    resolution: approval.resolution
                )
            )
        }

        let lastTimestamp = records.last?.event.header.timestamp
            ?? context.acceptedAt
        let completedAt = finalStatus.isTerminal ? lastTimestamp : nil
        if startedAt == nil, finalStatus.isTerminal { startedAt = completedAt }
        let error = state.lastError
        let errorKind: AgentRunErrorKind?
        switch finalStatus {
        case .cancelled:
            errorKind = .cancelled
        case .interrupted:
            errorKind = .interrupted
        case .failed:
            errorKind = error.map(legacyErrorKind) ?? .unknown
        default:
            errorKind = nil
        }

        return SwiftDataLegacyRunSnapshot(
            acceptance: SwiftDataLegacyAcceptanceCheck(
                runID: runID.rawValue,
                conversationID: context.conversationID.rawValue,
                projectID: context.projectID?.rawValue,
                workspaceID: context.workspaceID.rawValue,
                requestText: canonicalAcceptedUserText(accepted.initialItems)
            ),
            status: finalStatus,
            updatedAt: lastTimestamp,
            startedAt: startedAt,
            completedAt: completedAt,
            errorKind: errorKind,
            errorMessage: error?.publicMessage,
            observedRoute: route,
            responseMessageID: latestAssistantID,
            messages: messagesByID.values.sorted {
                if $0.sequence == $1.sequence {
                    return $0.messageID.uuidString < $1.messageID.uuidString
                }
                return $0.sequence < $1.sequence
            },
            tools: tools.sorted { $0.callID.uuidString < $1.callID.uuidString },
            approvals: approvals.sorted {
                $0.request.requestID.description < $1.request.requestID.description
            },
            evidence: evidenceByKey.values.sorted {
                evidenceKey($0) < evidenceKey($1)
            },
            artifacts: artifactsByKey.values.sorted {
                artifactKey($0) < artifactKey($1)
            }
        )
    }

    private static func legacyStatus(_ phase: AgentRunPhase) -> AgentRunStatus {
        switch phase {
        case .uninitialized, .accepted, .queued:
            .queued
        case .running, .cancelling:
            .running
        case .awaitingApproval:
            .awaitingApproval
        case .completed:
            .completed
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        case .interrupted:
            .interrupted
        }
    }

    private static func collectEvidence(
        _ values: [ToolEvidence],
        eventID: UUID,
        callID: UUID,
        occurredAt: AgentInstant,
        into collected: inout [String: SwiftDataCanonicalEvidenceSnapshot]
    ) throws {
        for evidence in values {
            let snapshot = SwiftDataCanonicalEvidenceSnapshot(
                eventID: eventID,
                callID: callID,
                occurredAt: occurredAt,
                evidence: evidence
            )
            let key = evidenceKey(snapshot)
            if let existing = collected[key], existing != snapshot {
                throw AgentEventProjectorError.projectionConflict(
                    "evidence:\(key)"
                )
            }
            collected[key] = snapshot
        }
    }

    private static func evidenceKey(
        _ snapshot: SwiftDataCanonicalEvidenceSnapshot
    ) -> String {
        ToolEffectEvidenceRecord.makeEvidenceKey(
            appliedEventIDString: snapshot.eventID.uuidString,
            evidenceDigest: snapshot.evidence.digest
        )
    }

    private static func collectArtifacts(
        _ values: [ArtifactReference],
        eventID: UUID,
        callID: UUID?,
        occurredAt: AgentInstant,
        source: SwiftDataCanonicalArtifactSnapshot.Source,
        into collected: inout [String: SwiftDataCanonicalArtifactSnapshot]
    ) throws {
        for artifact in values {
            let snapshot = SwiftDataCanonicalArtifactSnapshot(
                eventID: eventID,
                callID: callID,
                occurredAt: occurredAt,
                source: source,
                artifact: artifact
            )
            let key = artifactKey(snapshot)
            if let existing = collected[key], existing != snapshot {
                throw AgentEventProjectorError.projectionConflict(
                    "artifact:\(key)"
                )
            }
            collected[key] = snapshot
        }
    }

    private static func artifactKey(
        _ snapshot: SwiftDataCanonicalArtifactSnapshot
    ) -> String {
        AgentArtifactProjectionRecord.makeArtifactProjectionKey(
            artifactIDString: snapshot.artifact.artifactID.description,
            eventIDString: snapshot.eventID.uuidString
        )
    }

    private static func mutations(
        for record: StoredAgentEvent
    ) throws -> [SwiftDataAgentProjectionMutation] {
        let event = record.event
        let header = event.header
        let runID = header.runID.rawValue
        let projectID = header.projectID?.rawValue
        let at = header.timestamp
        let sequence = try persistedSequence(header.sequence)

        switch event.payload {
        case let .runAccepted(payload):
            return [
                .verifyLegacyAcceptance(
                    SwiftDataLegacyAcceptanceCheck(
                        runID: runID,
                        conversationID: header.conversationID.rawValue,
                        projectID: projectID,
                        workspaceID: header.workspaceID.rawValue,
                        requestText: canonicalAcceptedUserText(payload.initialItems)
                    )
                )
            ]

        case .runQueued:
            return []

        case .runStarted:
            return [.setLegacyRunStatus(
                SwiftDataLegacyRunStatusProjection(
                    runID: runID,
                    allowedStatuses: [.queued],
                    status: .running,
                    at: at
                )
            )]

        case let .modelRequestStarted(payload):
            return [.updateLegacyRoute(
                SwiftDataLegacyRouteProjection(
                    runID: runID,
                    provider: payload.route.provider,
                    modelID: payload.route.model
                )
            )]

        case let .modelResponseCommitted(payload):
            return payload.items.compactMap { item in
                guard case let .message(message) = item.payload else { return nil }
                return .upsertLegacyMessage(
                    SwiftDataLegacyMessageProjection(
                        messageID: item.id.rawValue,
                        runID: runID,
                        conversationID: header.conversationID.rawValue,
                        sequence: sequence,
                        role: legacyRole(message.role),
                        content: canonicalRenderedContent(message.content),
                        createdAt: item.createdAt
                    )
                )
            }

        case let .providerRouteChanged(payload):
            return [.updateLegacyRoute(
                SwiftDataLegacyRouteProjection(
                    runID: runID,
                    provider: payload.to.provider,
                    modelID: payload.to.model
                )
            )]

        case let .toolProposed(payload):
            let invocation = payload.invocation
            let requiresApproval = invocation.effectClass != .readOnlyLocal
            return [.upsertLegacyTool(
                SwiftDataLegacyToolProjection(
                    callID: invocation.callID.rawValue,
                    runID: runID,
                    projectID: projectID,
                    sequence: sequence,
                    name: invocation.tool.name,
                    argumentsJSON: try encodedString(invocation.arguments),
                    outputJSON: nil,
                    status: requiresApproval ? .pendingApproval : .approved,
                    requiresApproval: requiresApproval,
                    isMutating: invocation.effectClass != .readOnlyLocal,
                    occurredAt: at
                )
            )]

        case let .approvalRequested(payload):
            return [
                .setLegacyRunStatus(
                    SwiftDataLegacyRunStatusProjection(
                        runID: runID,
                        allowedStatuses: [.running],
                        status: .awaitingApproval,
                        at: at
                    )
                ),
                .upsertLegacyTool(
                    SwiftDataLegacyToolProjection(
                        callID: payload.request.binding.callID.rawValue,
                        runID: runID,
                        projectID: projectID,
                        sequence: sequence,
                        name: payload.request.binding.tool.name,
                        argumentsJSON: nil,
                        outputJSON: nil,
                        status: .pendingApproval,
                        requiresApproval: true,
                        isMutating: nil,
                        occurredAt: at
                    )
                ),
                .upsertApprovalRequest(
                    SwiftDataApprovalRequestProjection(
                        eventID: header.eventID.rawValue,
                        runID: runID,
                        workspaceID: header.workspaceID.rawValue,
                        request: payload.request
                    )
                )
            ]

        case let .approvalResolved(payload):
            let approved = payload.resolution.decision == .approved
            return [
                .setLegacyRunStatus(
                    SwiftDataLegacyRunStatusProjection(
                        runID: runID,
                        allowedStatuses: [.awaitingApproval],
                        status: .running,
                        at: at
                    )
                ),
                .upsertLegacyTool(
                    SwiftDataLegacyToolProjection(
                        callID: payload.resolution.callID.rawValue,
                        runID: runID,
                        projectID: projectID,
                        sequence: sequence,
                        name: "",
                        argumentsJSON: nil,
                        outputJSON: nil,
                        status: approved ? .approved : .rejected,
                        requiresApproval: true,
                        isMutating: nil,
                        occurredAt: at
                    )
                ),
                .resolveApprovalRequest(
                    SwiftDataApprovalResolutionProjection(
                        eventID: header.eventID.rawValue,
                        runID: runID,
                        resolution: payload.resolution
                    )
                )
            ]

        case let .toolScheduled(payload):
            return [toolStatusMutation(
                callID: payload.callID,
                runID: runID,
                projectID: projectID,
                sequence: sequence,
                status: .approved,
                at: at
            )]

        case let .toolStarted(payload):
            return [toolStatusMutation(
                callID: payload.callID,
                runID: runID,
                projectID: projectID,
                sequence: sequence,
                status: .approved,
                at: at
            )]

        case let .toolApplied(payload):
            return [.insertToolEvidence(
                SwiftDataToolEvidenceProjection(
                    eventID: header.eventID.rawValue,
                    runID: runID,
                    workspaceID: header.workspaceID.rawValue,
                    callID: payload.callID.rawValue,
                    occurredAt: at,
                    evidence: payload.evidence
                )
            )]

        case let .toolCompleted(payload):
            let result = payload.result
            let status: ToolRunStatus = result.status == .succeeded ? .completed : .failed
            var values: [SwiftDataAgentProjectionMutation] = [
                .upsertLegacyTool(
                    SwiftDataLegacyToolProjection(
                        callID: result.callID.rawValue,
                        runID: runID,
                        projectID: projectID,
                        sequence: sequence,
                        name: "",
                        argumentsJSON: nil,
                        outputJSON: try encodedString(result.output),
                        status: status,
                        requiresApproval: nil,
                        isMutating: nil,
                        occurredAt: at
                    )
                )
            ]
            if !result.evidence.isEmpty {
                values.append(.insertToolEvidence(
                    SwiftDataToolEvidenceProjection(
                        eventID: header.eventID.rawValue,
                        runID: runID,
                        workspaceID: header.workspaceID.rawValue,
                        callID: result.callID.rawValue,
                        occurredAt: at,
                        evidence: result.evidence
                    )
                ))
            }
            return values

        case .cancellationRequested:
            return []

        case .runCompleted:
            return [.setLegacyRunStatus(terminalStatus(
                runID: runID,
                status: .completed,
                at: at
            ))]

        case let .runFailed(payload):
            return [.setLegacyRunStatus(terminalStatus(
                runID: runID,
                status: .failed,
                at: at,
                error: payload.error
            ))]

        case .runCancelled:
            return [.setLegacyRunStatus(
                SwiftDataLegacyRunStatusProjection(
                    runID: runID,
                    allowedStatuses: [.queued, .running, .awaitingApproval],
                    status: .cancelled,
                    at: at,
                    errorKind: .cancelled,
                    errorMessage: "Run cancelled"
                )
            )]

        case let .runInterrupted(payload):
            return [.setLegacyRunStatus(
                SwiftDataLegacyRunStatusProjection(
                    runID: runID,
                    allowedStatuses: [.queued, .running, .awaitingApproval],
                    status: .interrupted,
                    at: at,
                    errorKind: .interrupted,
                    errorMessage: payload.error.publicMessage
                )
            )]

        case .contextPrepared, .contextCompressed, .modelRequestFailed,
             .planUpdated, .artifactCaptured, .checkpointCreated, .retryScheduled:
            return []
        }
    }

    private static func terminalStatus(
        runID: UUID,
        status: AgentRunStatus,
        at: AgentInstant,
        error: AgentErrorInfo? = nil
    ) -> SwiftDataLegacyRunStatusProjection {
        SwiftDataLegacyRunStatusProjection(
            runID: runID,
            allowedStatuses: [.queued, .running, .awaitingApproval],
            status: status,
            at: at,
            errorKind: error.map(legacyErrorKind),
            errorMessage: error?.publicMessage
        )
    }

    private static func toolStatusMutation(
        callID: ToolCallID,
        runID: UUID,
        projectID: UUID?,
        sequence: Int,
        status: ToolRunStatus,
        at: AgentInstant
    ) -> SwiftDataAgentProjectionMutation {
        .upsertLegacyTool(
            SwiftDataLegacyToolProjection(
                callID: callID.rawValue,
                runID: runID,
                projectID: projectID,
                sequence: sequence,
                name: "",
                argumentsJSON: nil,
                outputJSON: nil,
                status: status,
                requiresApproval: nil,
                isMutating: nil,
                occurredAt: at
            )
        )
    }
}

/// ProjectOS is a materialized view of the canonical journal. A ProjectOS row
/// is created only while applying `runAccepted`, and its ID is the canonical
/// RunID; subsequent events can only update that exact row.
struct ProjectOSProjector: Sendable {
    static let projectionID = NovaForgeMaterializedProjection.projectOS

    let store: SwiftDataAgentStore
    let batchSize: Int
    let projectionID: AgentProjectionID

    init(
        store: SwiftDataAgentStore,
        batchSize: Int = 64,
        projectionID: AgentProjectionID = Self.projectionID
    ) {
        self.store = store
        self.batchSize = max(1, batchSize)
        self.projectionID = projectionID
    }

    func projectAvailableEvents() async throws -> AgentEventProjectionReport {
        let startingOffset = try await store.loadCursor(for: projectionID)?.throughOffset ?? .origin
        var expectedOffset = startingOffset
        var eventCount = 0
        var batchCount = 0

        while true {
            let validated = try await store.validatedProjectionBatch(
                after: expectedOffset,
                limit: batchSize
            )
            let batch = validated.batch
            guard !batch.records.isEmpty else { break }
            let plan = try Self.plan(
                forRunPrefixes: validated.runPrefixes,
                canonicalScopes: validated.canonicalAcceptanceScopes,
                disposition: validated.materializationDisposition
            )
            let cursor = AgentProjectionCursor(
                projectionID: projectionID,
                throughOffset: batch.throughOffset,
                updatedAt: batch.records.last?.committedAt ?? AgentInstant(rawValue: 0)
            )
            do {
                _ = try await store.commitProjection(
                    plan,
                    cursor: cursor,
                    expectedPreviousOffset: expectedOffset
                )
            } catch let error as SwiftDataMaterializationDispositionError {
                guard case .staleProjectionPlan = error else { throw error }
                continue
            }
            expectedOffset = batch.throughOffset
            eventCount += batch.records.count
            batchCount += 1
            if !batch.hasMore { break }
        }

        return AgentEventProjectionReport(
            projectionID: projectionID,
            startingOffset: startingOffset,
            endingOffset: expectedOffset,
            projectedEventCount: eventCount,
            committedBatchCount: batchCount
        )
    }

    static func plan(
        for records: [StoredAgentEvent],
        disposition: SwiftDataMaterializationDispositionSnapshot = .empty
    ) throws -> SwiftDataAgentProjectionPlan {
        var grouped: [RunID: [StoredAgentEvent]] = [:]
        for record in records {
            grouped[record.runID, default: []].append(record)
        }
        let scopes = grouped.compactMap { runID, values -> SwiftDataCanonicalAcceptanceScope? in
            guard let first = values.min(by: {
                $0.envelope.writerSequence < $1.envelope.writerSequence
            }), case let .runAccepted(payload) = first.event.payload else { return nil }
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
        }
        return try plan(
            forRunPrefixes: grouped,
            canonicalScopes: scopes,
            disposition: disposition
        )
    }

    static func plan(
        forRunPrefixes prefixes: [RunID: [StoredAgentEvent]],
        canonicalScopes: [SwiftDataCanonicalAcceptanceScope]? = nil,
        disposition: SwiftDataMaterializationDispositionSnapshot = .empty
    ) throws -> SwiftDataAgentProjectionPlan {
        let snapshots = try prefixes.values.map(snapshot(for:)).sorted {
            $0.runID.uuidString < $1.runID.uuidString
        }
        let scopes = canonicalScopes ?? snapshots.map {
            SwiftDataCanonicalAcceptanceScope(
                acceptance: SwiftDataLegacyAcceptanceCheck(
                    runID: $0.runID,
                    conversationID: $0.conversationID,
                    projectID: $0.projectID,
                    workspaceID: $0.workspaceID,
                    requestText: $0.mission
                )
            )
        }
        let retainedRunIDs = Set(snapshots.map(\.runID))
        let futureScopes = scopes.filter {
            !retainedRunIDs.contains($0.runID.rawValue)
        }
        let snapshotMutations = snapshots.map { snapshot in
            if let projectID = snapshot.projectID,
               disposition.rehomedProjectIDs.contains(projectID) {
                return SwiftDataAgentProjectionMutation.suppressProjectOSRun(
                    SwiftDataProjectOSRunSuppression(
                        runID: snapshot.runID,
                        conversationID: snapshot.conversationID,
                        projectID: projectID
                    )
                )
            }
            return SwiftDataAgentProjectionMutation.replaceProjectOSRun(snapshot)
        }
        return SwiftDataAgentProjectionPlan(
            mutations: [
                .pruneProjectOSRuns(futureScopes)
            ] + snapshotMutations,
            evidenceProjectIDs: (
                scopes.compactMap { $0.projectID?.rawValue }
                    + snapshots.compactMap(\.projectID)
            ).filter { !disposition.rehomedProjectIDs.contains($0) },
            expectedDispositionFingerprint: disposition.fingerprint
        )
    }

    private static func snapshot(
        for unsortedRecords: [StoredAgentEvent]
    ) throws -> SwiftDataProjectOSRunSnapshot {
        let records = unsortedRecords.sorted {
            $0.envelope.writerSequence < $1.envelope.writerSequence
        }
        guard let first = records.first,
              case let .runAccepted(accepted) = first.event.payload
        else {
            throw AgentEventProjectorError.emptyRunPrefix
        }
        let runID = first.runID.rawValue
        guard records.allSatisfy({ $0.runID.rawValue == runID }) else {
            throw AgentEventProjectorError.mixedRunPrefix
        }

        let context = accepted.context
        let mission = canonicalAcceptedUserText(accepted.initialItems)
        var status = ProjectOSRunStatus.planning
        var planningState = "Creating agent plan"
        var currentAction = "Waiting to start"
        var currentCommand = ""
        var nextStep = "Read project context"
        var latestEventTitle = "Run accepted"
        var latestEventDetail = mission
        var changedFilesSummary = ""
        var artifactsSummary = ""
        var proofSummary = ""
        var blockerReason = ""
        var waitingReason = ""
        var failureReason = ""
        var resumeState = ""
        var completedAt: AgentInstant?

        for record in records.dropFirst() {
            for mutation in mutations(for: record) {
                guard case let .updateProjectOSRun(update) = mutation else { continue }
                if let value = update.status { status = value }
                if let value = update.planningState { planningState = value }
                if let value = update.currentAction { currentAction = value }
                if let value = update.currentCommand { currentCommand = value }
                if let value = update.nextStep { nextStep = value }
                latestEventTitle = update.latestEventTitle
                latestEventDetail = update.latestEventDetail
                if let value = update.changedFilesSummary { changedFilesSummary = value }
                if let value = update.artifactsSummary { artifactsSummary = value }
                if let value = update.proofSummary { proofSummary = value }
                if let value = update.blockerReason { blockerReason = value }
                if let value = update.waitingReason { waitingReason = value }
                if let value = update.failureReason { failureReason = value }
                if let value = update.resumeState { resumeState = value }
                if update.marksComplete { completedAt = update.occurredAt }
            }
        }

        return SwiftDataProjectOSRunSnapshot(
            runID: runID,
            conversationID: context.conversationID.rawValue,
            projectID: context.projectID?.rawValue,
            workspaceID: context.workspaceID.rawValue,
            mission: mission,
            status: status,
            planningState: planningState,
            currentAction: currentAction,
            currentCommand: currentCommand,
            nextStep: nextStep,
            latestEventTitle: latestEventTitle,
            latestEventDetail: latestEventDetail,
            changedFilesSummary: changedFilesSummary,
            artifactsSummary: artifactsSummary,
            proofSummary: proofSummary,
            blockerReason: blockerReason,
            waitingReason: waitingReason,
            failureReason: failureReason,
            resumeState: resumeState,
            acceptedAt: first.event.header.timestamp,
            updatedAt: records.last?.event.header.timestamp
                ?? first.event.header.timestamp,
            completedAt: completedAt,
            progressEventCount: max(0, records.count - 1)
        )
    }

    private static func mutations(
        for record: StoredAgentEvent
    ) -> [SwiftDataAgentProjectionMutation] {
        let event = record.event
        let header = event.header
        let runID = header.runID.rawValue
        let projectID = header.projectID?.rawValue
        let at = header.timestamp

        switch event.payload {
        case let .runAccepted(payload):
            return [.acceptProjectOSRun(
                SwiftDataProjectOSAcceptanceProjection(
                    runID: runID,
                    conversationID: header.conversationID.rawValue,
                    projectID: projectID,
                    mission: canonicalAcceptedUserText(payload.initialItems),
                    acceptedAt: at
                )
            )]
        case let .runQueued(payload):
            return [update(
                header,
                status: .planning,
                planningState: "Queued",
                currentAction: "Waiting to start",
                title: "Run queued",
                detail: payload.reason ?? ""
            )]
        case let .runStarted(payload):
            return [update(
                header,
                status: .running,
                planningState: payload.resumed ? "Resumed" : "Running",
                currentAction: payload.resumed ? "Resuming the run" : "Preparing context",
                title: payload.resumed ? "Run resumed" : "Run started",
                blockerReason: "",
                waitingReason: "",
                failureReason: ""
            )]
        case let .contextPrepared(payload):
            return [update(
                header,
                status: .running,
                planningState: "Context ready",
                currentAction: "Reading project context",
                title: "Context prepared",
                detail: "\(payload.itemIDs.count) items · \(payload.estimatedTokens) estimated tokens"
            )]
        case let .contextCompressed(payload):
            return [update(
                header,
                status: .running,
                currentAction: "Compacting context",
                title: "Context checkpointed",
                detail: payload.checkpoint.summary
            )]
        case let .modelRequestStarted(payload):
            return [update(
                header,
                status: .running,
                currentAction: "Asking \(payload.route.model)",
                title: "Model request started",
                detail: payload.route.provider,
                blockerReason: "",
                waitingReason: ""
            )]
        case let .modelResponseCommitted(payload):
            return [update(
                header,
                status: .running,
                currentAction: payload.finishReason == .toolCalls ? "Preparing tool work" : "Reviewing model output",
                title: "Model response committed",
                detail: responseSummary(payload.items)
            )]
        case let .modelRequestFailed(payload):
            return [update(
                header,
                status: .waiting,
                currentAction: "Recovering model request",
                title: "Model request failed",
                detail: payload.error.publicMessage,
                blockerReason: payload.error.retryable ? nil : payload.error.publicMessage,
                waitingReason: payload.error.retryable ? payload.error.publicMessage : nil
            )]
        case let .providerRouteChanged(payload):
            return [update(
                header,
                status: .running,
                currentAction: "Switching model route",
                title: "Provider route changed",
                detail: "\(payload.from.provider) → \(payload.to.provider): \(payload.reason)"
            )]
        case let .planUpdated(payload):
            return [update(
                header,
                status: .running,
                planningState: "Plan revision \(payload.revision)",
                currentAction: payload.summary,
                title: "Plan updated",
                detail: payload.summary
            )]
        case let .toolProposed(payload):
            return [update(
                header,
                status: .running,
                currentAction: "Preparing \(payload.invocation.tool.name)",
                currentCommand: payload.invocation.tool.name,
                title: "Tool proposed",
                detail: payload.invocation.tool.name
            )]
        case let .approvalRequested(payload):
            return [update(
                header,
                status: .waiting,
                currentAction: "Waiting for approval",
                currentCommand: payload.request.binding.tool.name,
                title: "Approval requested",
                detail: payload.request.summary,
                waitingReason: payload.request.summary
            )]
        case let .approvalResolved(payload):
            let approved = payload.resolution.decision == .approved
            return [update(
                header,
                status: approved ? .running : .blocked,
                currentAction: approved ? "Approval granted" : "Approval rejected",
                title: approved ? "Tool approved" : "Tool rejected",
                detail: payload.resolution.rationale ?? "",
                blockerReason: approved ? "" : (payload.resolution.rationale ?? "Approval rejected"),
                waitingReason: ""
            )]
        case let .toolScheduled(payload):
            return [update(
                header,
                status: .running,
                currentAction: "Tool scheduled",
                title: "Tool scheduled",
                detail: payload.callID.description
            )]
        case let .toolStarted(payload):
            return [update(
                header,
                status: .running,
                currentAction: "Running tool",
                title: "Tool started",
                detail: payload.callID.description
            )]
        case let .toolApplied(payload):
            let summary = payload.evidence.map(\.kind).joined(separator: ", ")
            return [update(
                header,
                status: .running,
                currentAction: "Recording applied changes",
                title: "Tool effects applied",
                detail: summary,
                changedFilesSummary: summary
            )]
        case let .toolCompleted(payload):
            let failed = payload.result.status != .succeeded
            let detail = payload.result.error?.publicMessage
                ?? payload.result.warnings.joined(separator: " · ")
            return [update(
                header,
                status: .running,
                currentAction: failed ? "Reviewing tool failure" : "Tool completed",
                title: failed ? "Tool failed" : "Tool completed",
                detail: detail,
                blockerReason: failed ? detail : ""
            )]
        case let .artifactCaptured(payload):
            return [update(
                header,
                status: .running,
                currentAction: "Capturing proof",
                title: "Artifact captured",
                detail: payload.artifact.displayName,
                artifactsSummary: payload.artifact.displayName
            )]
        case let .checkpointCreated(payload):
            return [update(
                header,
                status: .running,
                currentAction: "Saving checkpoint",
                title: "Checkpoint created",
                detail: payload.checkpoint.summary,
                nextStep: payload.checkpoint.summary
            )]
        case let .retryScheduled(payload):
            return [update(
                header,
                status: .waiting,
                currentAction: "Retrying model request",
                title: "Retry scheduled",
                detail: payload.reason,
                waitingReason: payload.reason
            )]
        case let .cancellationRequested(payload):
            return [update(
                header,
                status: .waiting,
                currentAction: "Stopping run",
                title: "Cancellation requested",
                detail: payload.reason.rawValue,
                waitingReason: "Stopping safely"
            )]
        case let .runCompleted(payload):
            let proof = payload.summary ?? "Run completed"
            return [update(
                header,
                status: .completed,
                currentAction: "Run complete",
                title: "Run completed",
                detail: proof,
                proofSummary: proof,
                blockerReason: "",
                waitingReason: "",
                failureReason: "",
                resumeState: "",
                marksComplete: true
            )]
        case let .runFailed(payload):
            return [update(
                header,
                status: .failed,
                currentAction: "Run failed",
                title: "Run failed",
                detail: payload.error.publicMessage,
                blockerReason: payload.error.publicMessage,
                waitingReason: "",
                failureReason: payload.error.publicMessage,
                marksComplete: true
            )]
        case let .runCancelled(payload):
            return [update(
                header,
                status: .stopped,
                currentAction: "Run cancelled",
                title: "Run cancelled",
                detail: payload.reason.rawValue,
                resumeState: "Cancelled after a durable stop request.",
                marksComplete: true
            )]
        case let .runInterrupted(payload):
            return [update(
                header,
                status: .stopped,
                currentAction: "Run interrupted",
                title: "Run interrupted",
                detail: payload.error.publicMessage,
                blockerReason: payload.error.publicMessage,
                failureReason: payload.error.publicMessage,
                resumeState: payload.safeToResume ? "Safe to resume from the journal." : "Review before resuming.",
                marksComplete: true
            )]
        }
    }

    private static func update(
        _ header: AgentEventHeader,
        status: ProjectOSRunStatus? = nil,
        planningState: String? = nil,
        currentAction: String? = nil,
        currentCommand: String? = nil,
        title: String,
        detail: String = "",
        changedFilesSummary: String? = nil,
        artifactsSummary: String? = nil,
        proofSummary: String? = nil,
        blockerReason: String? = nil,
        waitingReason: String? = nil,
        failureReason: String? = nil,
        resumeState: String? = nil,
        nextStep: String? = nil,
        marksComplete: Bool = false
    ) -> SwiftDataAgentProjectionMutation {
        .updateProjectOSRun(
            SwiftDataProjectOSRunProjection(
                runID: header.runID.rawValue,
                projectID: header.projectID?.rawValue,
                status: status,
                planningState: planningState,
                currentAction: currentAction,
                currentCommand: currentCommand,
                nextStep: nextStep,
                latestEventTitle: title,
                latestEventDetail: detail,
                changedFilesSummary: changedFilesSummary,
                artifactsSummary: artifactsSummary,
                proofSummary: proofSummary,
                blockerReason: blockerReason,
                waitingReason: waitingReason,
                failureReason: failureReason,
                resumeState: resumeState,
                occurredAt: header.timestamp,
                marksComplete: marksComplete
            )
        )
    }
}

private func persistedSequence(_ sequence: EventSequence) throws -> Int {
    guard let value = Int(exactly: sequence.rawValue) else {
        throw AgentEventProjectorError.sequenceOutOfRange(sequence)
    }
    return value
}

func canonicalAcceptedUserText(_ items: [ModelItem]) -> String {
    items.compactMap { item -> String? in
        guard case let .message(message) = item.payload, message.role == .user else {
            return nil
        }
        let content = canonicalRenderedContent(message.content)
        return content.isEmpty ? nil : content
    }.joined(separator: "\n")
}

private func responseSummary(_ items: [ModelItem]) -> String {
    let messages = items.compactMap { item -> String? in
        guard case let .message(message) = item.payload else { return nil }
        let rendered = canonicalRenderedContent(message.content)
        return rendered.isEmpty ? nil : rendered
    }
    return messages.joined(separator: "\n")
}

func canonicalRenderedContent(_ parts: [ModelContentPart]) -> String {
    parts.map { part in
        switch part {
        case let .text(value):
            value
        case let .structured(value):
            (try? encodedString(value)) ?? "[Structured output]"
        case let .image(value):
            "[Image: \(value.mediaType)]"
        case let .artifact(value):
            "[Artifact: \(value.displayName)]"
        }
    }.joined(separator: "\n")
}

private func legacyRole(_ role: ModelRole) -> ChatRole {
    switch role {
    case .user: .user
    case .assistant: .assistant
    }
}

private func legacyErrorKind(_ error: AgentErrorInfo) -> AgentRunErrorKind {
    switch error.category {
    case .cancelled: .cancelled
    case .provider, .authentication, .authorization, .rateLimited,
         .contextLimit, .transport, .unavailable:
        .provider
    case .tool: .tool
    case .persistence: .persistence
    case .invalidInput: .invalidRequest
    case .invariantViolation: .workspaceConflict
    case .timeout, .unknown: .unknown
    }
}

private func encodedString<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let encoded = String(data: try encoder.encode(value), encoding: .utf8) else {
        throw AgentEventProjectorError.valueEncodingFailed
    }
    return encoded
}

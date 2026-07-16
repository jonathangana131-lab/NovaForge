import AgentDomain
import AgentTools
import Foundation

enum AgentActivityCanonicalIdentityKind: String, Equatable, Sendable {
    case attempt
    case toolCall
    case approvalRequest
    case artifact
}

enum AgentActivityProjectionError: Error, Equatable, Sendable {
    case duplicateEventID(EventID)
    case runIdentityConflict(RunID)
    case acceptanceNotFirst(RunID)
    case duplicateAcceptance(RunID)
    case acceptanceHeaderMismatch(RunID)
    case missingAcceptance(RunID)
    case sequenceNotIncreasing(
        runID: RunID,
        previous: EventSequence,
        actual: EventSequence
    )
    case canonicalIdentityReused(
        kind: AgentActivityCanonicalIdentityKind,
        firstRunID: RunID,
        secondRunID: RunID
    )
    case duplicateAttempt(runID: RunID, attemptID: AttemptID)
    case unknownAttempt(runID: RunID, attemptID: AttemptID)
    case duplicateTool(runID: RunID, callID: ToolCallID)
    case unknownTool(runID: RunID, callID: ToolCallID)
    case duplicateApproval(runID: RunID, requestID: ApprovalRequestID)
    case unknownApproval(runID: RunID, requestID: ApprovalRequestID)
    case approvalBindingMismatch(runID: RunID, requestID: ApprovalRequestID)
    case artifactIdentityConflict(runID: RunID, artifactID: ArtifactID)
    case stateWithoutEvents(RunID)
    case stateIdentityMismatch(RunID)
    case stateSequenceMismatch(RunID)
    case stateProjectionMismatch(RunID)
}

/// Pure projection boundary between the canonical harness journal and Forge UI.
/// It never reads persistence, creates IDs, interprets argument JSON, or executes
/// a command.
enum AgentCanonicalActivityProjector {
    static func project(
        orderedEvents: [AgentEvent],
        states: [RunID: AgentDomain.AgentRunState] = [:],
        scope: AgentActivityProjectionScope
    ) throws -> [AgentActivityGroup] {
        let preflight = try preflight(orderedEvents)
        var groups: [AgentActivityGroup] = []

        for runID in preflight.runOrder {
            guard let record = preflight.runs[runID] else { continue }
            guard scope.contains(record.identity) else { continue }
            guard record.accepted else {
                throw AgentActivityProjectionError.missingAcceptance(runID)
            }

            var builder = try GroupBuilder(firstEvent: record.events[0])
            for event in record.events.dropFirst() {
                try builder.apply(event)
            }
            let group = try builder.makeGroup(validating: states[runID])
            groups.append(group)
        }

        for (runID, state) in states {
            guard let context = state.context else { continue }
            let identity = AgentActivityRunIdentity(context: context)
            guard scope.contains(identity) else { continue }
            guard preflight.runs[runID] != nil else {
                throw AgentActivityProjectionError.stateWithoutEvents(runID)
            }
        }

        return groups
    }
}

private extension AgentCanonicalActivityProjector {
    struct PreflightRecord {
        let identity: AgentActivityRunIdentity
        var events: [AgentEvent]
        var accepted: Bool
    }

    struct PreflightResult {
        let runs: [RunID: PreflightRecord]
        let runOrder: [RunID]
    }

    struct CanonicalOwners {
        var attempts: [AttemptID: RunID] = [:]
        var toolCalls: [ToolCallID: RunID] = [:]
        var approvals: [ApprovalRequestID: RunID] = [:]
        var artifacts: [ArtifactID: RunID] = [:]

        mutating func claim(_ attemptID: AttemptID, runID: RunID) throws {
            try Self.claim(
                attemptID,
                runID: runID,
                owners: &attempts,
                kind: .attempt
            )
        }

        mutating func claim(_ callID: ToolCallID, runID: RunID) throws {
            try Self.claim(
                callID,
                runID: runID,
                owners: &toolCalls,
                kind: .toolCall
            )
        }

        mutating func claim(_ requestID: ApprovalRequestID, runID: RunID) throws {
            try Self.claim(
                requestID,
                runID: runID,
                owners: &approvals,
                kind: .approvalRequest
            )
        }

        mutating func claim(_ artifactID: ArtifactID, runID: RunID) throws {
            try Self.claim(
                artifactID,
                runID: runID,
                owners: &artifacts,
                kind: .artifact
            )
        }

        private static func claim<ID: Hashable>(
            _ id: ID,
            runID: RunID,
            owners: inout [ID: RunID],
            kind: AgentActivityCanonicalIdentityKind
        ) throws {
            if let firstRunID = owners[id], firstRunID != runID {
                throw AgentActivityProjectionError.canonicalIdentityReused(
                    kind: kind,
                    firstRunID: firstRunID,
                    secondRunID: runID
                )
            }
            owners[id] = runID
        }
    }

    static func preflight(_ events: [AgentEvent]) throws -> PreflightResult {
        var runs: [RunID: PreflightRecord] = [:]
        var runOrder: [RunID] = []
        var seenEventIDs: Set<EventID> = []
        var owners = CanonicalOwners()

        for event in events {
            guard seenEventIDs.insert(event.header.eventID).inserted else {
                throw AgentActivityProjectionError.duplicateEventID(event.header.eventID)
            }

            let runID = event.header.runID
            let identity = AgentActivityRunIdentity(header: event.header)
            if var record = runs[runID] {
                guard record.identity == identity else {
                    throw AgentActivityProjectionError.runIdentityConflict(runID)
                }
                guard let previous = record.events.last?.header.sequence,
                      event.header.sequence > previous
                else {
                    throw AgentActivityProjectionError.sequenceNotIncreasing(
                        runID: runID,
                        previous: record.events.last?.header.sequence ?? .first,
                        actual: event.header.sequence
                    )
                }
                if case let .runAccepted(payload) = event.payload {
                    guard !record.accepted else {
                        throw AgentActivityProjectionError.duplicateAcceptance(runID)
                    }
                    try validateAcceptance(payload.context, against: event.header)
                    record.accepted = true
                }
                record.events.append(event)
                runs[runID] = record
            } else {
                guard case let .runAccepted(payload) = event.payload else {
                    throw AgentActivityProjectionError.acceptanceNotFirst(runID)
                }
                try validateAcceptance(payload.context, against: event.header)
                runs[runID] = PreflightRecord(
                    identity: identity,
                    events: [event],
                    accepted: true
                )
                runOrder.append(runID)
            }

            try owners.claimCanonicalIDs(in: event)
        }

        return PreflightResult(runs: runs, runOrder: runOrder)
    }

    static func validateAcceptance(
        _ context: AgentRunContext,
        against header: AgentEventHeader
    ) throws {
        guard context.schemaVersion == header.schemaVersion,
              context.lineage.runID == header.runID,
              context.lineage.rootRunID == header.rootRunID,
              context.lineage.parentRunID == header.parentRunID,
              context.conversationID == header.conversationID,
              context.projectID == header.projectID,
              context.workspaceID == header.workspaceID,
              context.executionNodeID == header.executionNodeID,
              context.engineVersion == header.engineVersion,
              context.lineage.validationError == nil
        else {
            throw AgentActivityProjectionError.acceptanceHeaderMismatch(header.runID)
        }
    }
}

private extension AgentCanonicalActivityProjector.CanonicalOwners {
    mutating func claimCanonicalIDs(in event: AgentEvent) throws {
        let runID = event.header.runID

        switch event.payload {
        case let .runAccepted(payload):
            try claimIDs(in: payload.initialItems, runID: runID)
        case let .modelRequestStarted(payload):
            try claim(payload.attemptID, runID: runID)
        case let .modelResponseCommitted(payload):
            try claim(payload.attemptID, runID: runID)
            try claimIDs(in: payload.items, runID: runID)
        case let .modelRequestFailed(payload):
            try claim(payload.attemptID, runID: runID)
        case let .toolProposed(payload):
            try claim(payload.invocation.modelAttemptID, runID: runID)
            try claim(payload.invocation.callID, runID: runID)
        case let .approvalRequested(payload):
            try claim(payload.request.requestID, runID: runID)
            try claim(payload.request.binding.callID, runID: runID)
        case let .approvalResolved(payload):
            try claim(payload.resolution.requestID, runID: runID)
            try claim(payload.resolution.callID, runID: runID)
        case let .toolScheduled(payload):
            try claim(payload.callID, runID: runID)
        case let .toolStarted(payload):
            try claim(payload.callID, runID: runID)
        case let .toolApplied(payload):
            try claim(payload.callID, runID: runID)
        case let .toolCompleted(payload):
            try claim(payload.result.callID, runID: runID)
            for artifact in payload.result.artifacts {
                try claim(artifact.artifactID, runID: runID)
            }
        case let .artifactCaptured(payload):
            try claim(payload.artifact.artifactID, runID: runID)
        case let .retryScheduled(payload):
            try claim(payload.failedAttemptID, runID: runID)
            try claim(payload.nextAttemptID, runID: runID)
        case .runQueued, .runStarted, .contextPrepared, .contextCompressed,
             .providerRouteChanged, .planUpdated, .checkpointCreated,
             .cancellationRequested, .runCompleted, .runFailed, .runCancelled,
             .runInterrupted:
            break
        }
    }

    private mutating func claimIDs(
        in items: [ModelItem],
        runID: RunID
    ) throws {
        for item in items {
            switch item.payload {
            case let .message(message):
                for part in message.content {
                    if case let .artifact(artifact) = part {
                        try claim(artifact.artifactID, runID: runID)
                    }
                }
            case let .toolInvocation(invocation):
                try claim(invocation.modelAttemptID, runID: runID)
                try claim(invocation.callID, runID: runID)
            case let .toolResult(result):
                try claim(result.callID, runID: runID)
                for artifact in result.artifacts {
                    try claim(artifact.artifactID, runID: runID)
                }
            case .reasoningSummary, .contextCheckpoint:
                break
            }
        }
    }
}

private extension AgentActivityRunIdentity {
    init(header: AgentEventHeader) {
        self.init(
            projectID: header.projectID,
            conversationID: header.conversationID,
            workspaceID: header.workspaceID,
            runID: header.runID,
            rootRunID: header.rootRunID
        )
    }

    init(context: AgentRunContext) {
        self.init(
            projectID: context.projectID,
            conversationID: context.conversationID,
            workspaceID: context.workspaceID,
            runID: context.lineage.runID,
            rootRunID: context.lineage.rootRunID
        )
    }
}

private struct GroupBuilder {
    private struct ItemBuilder {
        let id: AgentActivityItemID
        let kind: AgentActivitySemanticKind
        var state: AgentActivityState
        let summary: String
        let target: String?
        let attemptID: AttemptID?
        let toolCallID: ToolCallID?
        let firstSequence: EventSequence
        var lastSequence: EventSequence
        let startedAt: AgentInstant
        var endedAt: AgentInstant
        var errorMessage: String?
        var evidenceIDs: [AgentActivityEvidenceID] = []
        var artifactIDs: [ArtifactID] = []

        var value: AgentActivityItem {
            AgentActivityItem(
                id: id,
                kind: kind,
                state: state,
                summary: summary,
                target: target,
                attemptID: attemptID,
                toolCallID: toolCallID,
                span: AgentActivityEventSpan(
                    firstSequence: firstSequence,
                    lastSequence: lastSequence,
                    startedAt: startedAt,
                    endedAt: endedAt
                ),
                errorMessage: errorMessage,
                evidenceIDs: evidenceIDs,
                artifactIDs: artifactIDs
            )
        }
    }

    private struct AttemptBuilder {
        let id: AttemptID
        var state: AgentActivityState
        let route: AgentActivityRoute
        let firstSequence: EventSequence
        var lastSequence: EventSequence
        let startedAt: AgentInstant
        var endedAt: AgentInstant
        var itemIDs: [AgentActivityItemID]
        var retryOfAttemptID: AttemptID?
        var nextAttemptID: AttemptID?
        var errorMessage: String?

        var value: AgentActivityAttempt {
            AgentActivityAttempt(
                id: id,
                state: state,
                route: route,
                span: AgentActivityEventSpan(
                    firstSequence: firstSequence,
                    lastSequence: lastSequence,
                    startedAt: startedAt,
                    endedAt: endedAt
                ),
                itemIDs: itemIDs,
                retryOfAttemptID: retryOfAttemptID,
                nextAttemptID: nextAttemptID,
                errorMessage: errorMessage
            )
        }
    }

    private struct ApprovalBuilder {
        let id: ApprovalRequestID
        let run: AgentActivityRunIdentity
        let callID: ToolCallID
        var state: AgentActivityState
        let publicSummary: String
        let requestedAt: AgentInstant
        var resolvedAt: AgentInstant?

        var value: AgentActivityApproval {
            AgentActivityApproval(
                id: id,
                run: run,
                callID: callID,
                state: state,
                publicSummary: publicSummary,
                requestedAt: requestedAt,
                resolvedAt: resolvedAt
            )
        }
    }

    private struct EvidenceBuilder {
        let id: AgentActivityEvidenceID
        let firstSequence: EventSequence
        var sourceToolCallIDs: [ToolCallID]

        var value: AgentActivityEvidence {
            AgentActivityEvidence(
                id: id,
                firstSequence: firstSequence,
                sourceToolCallIDs: sourceToolCallIDs
            )
        }
    }

    private struct ToolBinding {
        let tool: ToolIdentity
        let canonicalArgumentDigest: String
    }

    private enum ArtifactKey: Hashable {
        case digest(String)
        case artifactID(ArtifactID)
    }

    private struct ArtifactBuilder {
        let reference: ArtifactReference
        let run: AgentActivityRunIdentity
        var equivalentArtifactIDs: [ArtifactID]
        let firstSequence: EventSequence
        var sourceToolCallIDs: [ToolCallID]

        var value: AgentActivityArtifact {
            AgentActivityArtifact(
                id: reference.artifactID,
                run: run,
                equivalentArtifactIDs: equivalentArtifactIDs,
                contentDigest: reference.contentDigest,
                mediaType: reference.mediaType,
                displayName: reference.displayName,
                firstSequence: firstSequence,
                sourceToolCallIDs: sourceToolCallIDs
            )
        }
    }

    private let context: AgentRunContext
    private let identity: AgentActivityRunIdentity
    private var phase: AgentRunPhase = .accepted
    private let firstSequence: EventSequence
    private var lastSequence: EventSequence
    private let startedAt: AgentInstant
    private var endedAt: AgentInstant
    private var orderedEventIDs: [EventID]
    private var orderedSequences: [EventSequence]
    private var items: [ItemBuilder] = []
    private var itemIndex: [AgentActivityItemID: Int] = [:]
    private var toolBindings: [ToolCallID: ToolBinding] = [:]
    private var attempts: [AttemptBuilder] = []
    private var attemptIndex: [AttemptID: Int] = [:]
    private var approvals: [ApprovalBuilder] = []
    private var approvalIndex: [ApprovalRequestID: Int] = [:]
    private var evidence: [EvidenceBuilder] = []
    private var evidenceIndex: [AgentActivityEvidenceID: Int] = [:]
    private var artifacts: [ArtifactBuilder] = []
    private var artifactIndex: [ArtifactKey: Int] = [:]
    private var artifactKeyByID: [ArtifactID: ArtifactKey] = [:]
    private var retryOfByAttempt: [AttemptID: AttemptID] = [:]
    private var lastErrorMessage: String?

    init(firstEvent: AgentEvent) throws {
        guard case let .runAccepted(payload) = firstEvent.payload else {
            throw AgentActivityProjectionError.acceptanceNotFirst(firstEvent.header.runID)
        }
        context = payload.context
        identity = AgentActivityRunIdentity(context: payload.context)
        firstSequence = firstEvent.header.sequence
        lastSequence = firstEvent.header.sequence
        startedAt = firstEvent.header.timestamp
        endedAt = firstEvent.header.timestamp
        orderedEventIDs = [firstEvent.header.eventID]
        orderedSequences = [firstEvent.header.sequence]

    }

    mutating func apply(_ event: AgentEvent) throws {
        lastSequence = event.header.sequence
        endedAt = event.header.timestamp
        orderedEventIDs.append(event.header.eventID)
        orderedSequences.append(event.header.sequence)

        switch event.payload {
        case .runAccepted:
            throw AgentActivityProjectionError.duplicateAcceptance(identity.runID)
        case .runQueued:
            phase = .queued
        case .runStarted:
            phase = .running
        case .contextPrepared:
            break
        case let .contextCompressed(payload):
            addItem(
                id: .checkpoint(payload.checkpoint.checkpointID),
                kind: .checkpoint,
                state: .succeeded,
                summary: "Compacted context",
                event: event
            )
        case let .modelRequestStarted(payload):
            try startAttempt(payload, event: event)
        case let .modelResponseCommitted(payload):
            try finishAttempt(
                payload.attemptID,
                state: .succeeded,
                errorMessage: nil,
                event: event
            )
            for item in payload.items {
                try collectArtifacts(
                    in: item,
                    sequence: event.header.sequence,
                    sourceCallID: nil
                )
            }
        case let .modelRequestFailed(payload):
            lastErrorMessage = payload.error.publicMessage
            try finishAttempt(
                payload.attemptID,
                state: .failed,
                errorMessage: payload.error.publicMessage,
                event: event
            )
        case .providerRouteChanged:
            addItem(
                id: .routeChange(event.header.eventID),
                kind: .routeChange,
                state: .succeeded,
                summary: "Changed model route",
                event: event
            )
        case let .planUpdated(payload):
            addItem(
                id: .plan(runID: identity.runID, revision: payload.revision),
                kind: .plan,
                state: .succeeded,
                summary: "Updated plan",
                event: event
            )
        case let .toolProposed(payload):
            try proposeTool(payload.invocation, event: event)
        case let .approvalRequested(payload):
            try requestApproval(payload.request, event: event)
        case let .approvalResolved(payload):
            try resolveApproval(payload.resolution, event: event)
        case let .toolScheduled(payload):
            try updateTool(payload.callID, state: .queued, event: event)
        case let .toolStarted(payload):
            try updateTool(payload.callID, state: .running, event: event)
        case let .toolApplied(payload):
            try updateTool(payload.callID, state: .running, event: event)
            try addEvidence(payload.evidence, to: payload.callID, event: event)
        case let .toolCompleted(payload):
            try completeTool(payload.result, event: event)
        case let .artifactCaptured(payload):
            _ = try addArtifact(
                payload.artifact,
                sequence: event.header.sequence,
                sourceCallID: nil
            )
        case let .checkpointCreated(payload):
            addItem(
                id: .checkpoint(payload.checkpoint.checkpointID),
                kind: .checkpoint,
                state: .succeeded,
                summary: "Saved a checkpoint",
                event: event
            )
        case let .retryScheduled(payload):
            try scheduleRetry(payload, event: event)
        case let .cancellationRequested(payload):
            phase = .cancelling
            addItem(
                id: .cancellation(event.header.eventID),
                kind: .cancellation,
                state: .cancelling,
                summary: cancellationSummary(payload.reason),
                event: event
            )
        case .runCompleted:
            phase = .completed
        case let .runFailed(payload):
            phase = .failed
            lastErrorMessage = payload.error.publicMessage
            addItem(
                id: .failure(event.header.eventID),
                kind: .failure,
                state: .failed,
                summary: payload.error.publicMessage,
                event: event,
                errorMessage: payload.error.publicMessage
            )
        case let .runCancelled(payload):
            phase = .cancelled
            addItem(
                id: .cancellation(event.header.eventID),
                kind: .cancellation,
                state: .cancelled,
                summary: cancellationSummary(payload.reason),
                event: event
            )
        case let .runInterrupted(payload):
            phase = .interrupted
            lastErrorMessage = payload.error.publicMessage
            addItem(
                id: .failure(event.header.eventID),
                kind: .failure,
                state: .interrupted,
                summary: payload.error.publicMessage,
                event: event,
                errorMessage: payload.error.publicMessage
            )
        }
    }

    func makeGroup(
        validating state: AgentDomain.AgentRunState?
    ) throws -> AgentActivityGroup {
        let groupState = presentationState(for: phase)
        let group = AgentActivityGroup(
            identity: identity,
            state: groupState,
            summary: groupSummary(state: groupState, actionCount: toolItemCount),
            span: AgentActivityEventSpan(
                firstSequence: firstSequence,
                lastSequence: lastSequence,
                startedAt: startedAt,
                endedAt: endedAt
            ),
            items: items.map(\.value),
            attempts: attempts.map(\.value),
            approvals: approvals.map(\.value),
            artifacts: artifacts.map(\.value),
            evidence: evidence.map(\.value),
            errorMessage: lastErrorMessage,
            replayIdentity: AgentActivityReplayIdentity(
                orderedEventIDs: orderedEventIDs,
                orderedSequences: orderedSequences
            )
        )
        if let state {
            try validate(state, matches: group)
        }
        return group
    }

    private var toolItemCount: Int {
        items.lazy.filter { $0.kind == .tool }.count
    }

    private mutating func startAttempt(
        _ payload: ModelRequestStartedEvent,
        event: AgentEvent
    ) throws {
        guard attemptIndex[payload.attemptID] == nil else {
            throw AgentActivityProjectionError.duplicateAttempt(
                runID: identity.runID,
                attemptID: payload.attemptID
            )
        }
        let itemID = AgentActivityItemID.modelAttempt(payload.attemptID)
        addItem(
            id: itemID,
            kind: .modelAttempt,
            state: .running,
            summary: "Contacted model",
            event: event,
            attemptID: payload.attemptID
        )
        let index = attempts.count
        attempts.append(
            AttemptBuilder(
                id: payload.attemptID,
                state: .running,
                route: AgentActivityRoute(
                    provider: payload.route.provider,
                    model: payload.route.model,
                    adapter: payload.route.adapter
                ),
                firstSequence: event.header.sequence,
                lastSequence: event.header.sequence,
                startedAt: event.header.timestamp,
                endedAt: event.header.timestamp,
                itemIDs: [itemID],
                retryOfAttemptID: retryOfByAttempt[payload.attemptID],
                nextAttemptID: nil,
                errorMessage: nil
            )
        )
        attemptIndex[payload.attemptID] = index
    }

    private mutating func finishAttempt(
        _ attemptID: AttemptID,
        state: AgentActivityState,
        errorMessage: String?,
        event: AgentEvent
    ) throws {
        guard let index = attemptIndex[attemptID] else {
            throw AgentActivityProjectionError.unknownAttempt(
                runID: identity.runID,
                attemptID: attemptID
            )
        }
        attempts[index].state = state
        attempts[index].lastSequence = event.header.sequence
        attempts[index].endedAt = event.header.timestamp
        attempts[index].errorMessage = errorMessage
        try updateItem(
            .modelAttempt(attemptID),
            state: state,
            event: event,
            errorMessage: errorMessage
        )
    }

    private mutating func proposeTool(
        _ invocation: ToolInvocation,
        event: AgentEvent
    ) throws {
        let itemID = AgentActivityItemID.tool(invocation.callID)
        guard itemIndex[itemID] == nil else {
            throw AgentActivityProjectionError.duplicateTool(
                runID: identity.runID,
                callID: invocation.callID
            )
        }
        guard let attempt = attemptIndex[invocation.modelAttemptID] else {
            throw AgentActivityProjectionError.unknownAttempt(
                runID: identity.runID,
                attemptID: invocation.modelAttemptID
            )
        }
        addItem(
            id: itemID,
            kind: .tool,
            state: .pending,
            summary: toolSummary(invocation),
            event: event,
            attemptID: invocation.modelAttemptID,
            toolCallID: invocation.callID
        )
        toolBindings[invocation.callID] = ToolBinding(
            tool: invocation.tool,
            canonicalArgumentDigest: invocation.canonicalArgumentDigest
        )
        attempts[attempt].itemIDs.append(itemID)
        attempts[attempt].lastSequence = event.header.sequence
        attempts[attempt].endedAt = event.header.timestamp
    }

    private mutating func requestApproval(
        _ request: ApprovalRequest,
        event: AgentEvent
    ) throws {
        guard request.binding.runID == identity.runID,
              request.binding.workspaceID == identity.workspaceID,
              let tool = toolItemIndex(request.binding.callID),
              let binding = toolBindings[request.binding.callID],
              binding.tool == request.binding.tool,
              binding.canonicalArgumentDigest == request.binding.canonicalArgumentDigest
        else {
            throw AgentActivityProjectionError.approvalBindingMismatch(
                runID: identity.runID,
                requestID: request.requestID
            )
        }
        guard approvalIndex[request.requestID] == nil else {
            throw AgentActivityProjectionError.duplicateApproval(
                runID: identity.runID,
                requestID: request.requestID
            )
        }
        let index = approvals.count
        approvals.append(
            ApprovalBuilder(
                id: request.requestID,
                run: identity,
                callID: request.binding.callID,
                state: .awaitingApproval,
                publicSummary: "Review this action before it runs.",
                requestedAt: request.requestedAt,
                resolvedAt: nil
            )
        )
        approvalIndex[request.requestID] = index
        let itemID = AgentActivityItemID.approval(request.requestID)
        addItem(
            id: itemID,
            kind: .approval,
            state: .awaitingApproval,
            summary: "Approval needed",
            event: event,
            attemptID: items[tool].attemptID,
            toolCallID: request.binding.callID
        )
        if let attemptID = items[tool].attemptID,
           let attempt = attemptIndex[attemptID] {
            attempts[attempt].itemIDs.append(itemID)
            attempts[attempt].lastSequence = event.header.sequence
            attempts[attempt].endedAt = event.header.timestamp
        }
        items[tool].state = .awaitingApproval
        items[tool].lastSequence = event.header.sequence
        items[tool].endedAt = event.header.timestamp
        phase = .awaitingApproval
    }

    private mutating func resolveApproval(
        _ resolution: ApprovalResolution,
        event: AgentEvent
    ) throws {
        guard let index = approvalIndex[resolution.requestID] else {
            throw AgentActivityProjectionError.unknownApproval(
                runID: identity.runID,
                requestID: resolution.requestID
            )
        }
        guard approvals[index].callID == resolution.callID else {
            throw AgentActivityProjectionError.approvalBindingMismatch(
                runID: identity.runID,
                requestID: resolution.requestID
            )
        }
        let resolvedState: AgentActivityState = resolution.decision == .approved
            ? .succeeded
            : .rejected
        approvals[index].state = resolvedState
        approvals[index].resolvedAt = resolution.resolvedAt
        try updateItem(
            .approval(resolution.requestID),
            state: resolvedState,
            event: event
        )
        try updateTool(
            resolution.callID,
            state: resolution.decision == .approved ? .pending : .rejected,
            event: event
        )
        phase = approvals.contains { $0.state == .awaitingApproval }
            ? .awaitingApproval
            : .running
    }

    private mutating func updateTool(
        _ callID: ToolCallID,
        state: AgentActivityState,
        event: AgentEvent
    ) throws {
        try updateItem(.tool(callID), state: state, event: event)
        if let tool = toolItemIndex(callID),
           let attemptID = items[tool].attemptID,
           let attempt = attemptIndex[attemptID] {
            attempts[attempt].lastSequence = event.header.sequence
            attempts[attempt].endedAt = event.header.timestamp
        }
    }

    private mutating func completeTool(
        _ result: ToolResult,
        event: AgentEvent
    ) throws {
        let state: AgentActivityState
        switch result.status {
        case .succeeded: state = .succeeded
        case .failed: state = .failed
        case .cancelled: state = .cancelled
        }
        let errorMessage = result.error?.publicMessage
        try updateItem(
            .tool(result.callID),
            state: state,
            event: event,
            errorMessage: errorMessage
        )
        if let errorMessage {
            lastErrorMessage = errorMessage
        }
        try addEvidence(result.evidence, to: result.callID, event: event)
        for artifact in result.artifacts {
            let canonicalID = try addArtifact(
                artifact,
                sequence: event.header.sequence,
                sourceCallID: result.callID
            )
            try appendArtifact(canonicalID, to: result.callID)
        }
    }

    private mutating func scheduleRetry(
        _ payload: RetryScheduledEvent,
        event: AgentEvent
    ) throws {
        guard let failedIndex = attemptIndex[payload.failedAttemptID] else {
            throw AgentActivityProjectionError.unknownAttempt(
                runID: identity.runID,
                attemptID: payload.failedAttemptID
            )
        }
        attempts[failedIndex].state = .retrying
        attempts[failedIndex].nextAttemptID = payload.nextAttemptID
        attempts[failedIndex].lastSequence = event.header.sequence
        attempts[failedIndex].endedAt = event.header.timestamp
        retryOfByAttempt[payload.nextAttemptID] = payload.failedAttemptID
        try updateItem(
            .modelAttempt(payload.failedAttemptID),
            state: .retrying,
            event: event
        )
        let itemID = AgentActivityItemID.retry(
            failedAttemptID: payload.failedAttemptID,
            nextAttemptID: payload.nextAttemptID
        )
        addItem(
            id: itemID,
            kind: .retry,
            state: .retrying,
            summary: "Retrying model request",
            event: event,
            attemptID: payload.failedAttemptID
        )
        attempts[failedIndex].itemIDs.append(itemID)
    }

    private mutating func addEvidence(
        _ values: [ToolEvidence],
        to callID: ToolCallID,
        event: AgentEvent
    ) throws {
        guard let tool = toolItemIndex(callID) else {
            throw AgentActivityProjectionError.unknownTool(
                runID: identity.runID,
                callID: callID
            )
        }
        for value in values {
            let id = AgentActivityEvidenceID(kind: value.kind, digest: value.digest)
            if let index = evidenceIndex[id] {
                if !evidence[index].sourceToolCallIDs.contains(callID) {
                    evidence[index].sourceToolCallIDs.append(callID)
                }
            } else {
                evidenceIndex[id] = evidence.count
                evidence.append(
                    EvidenceBuilder(
                        id: id,
                        firstSequence: event.header.sequence,
                        sourceToolCallIDs: [callID]
                    )
                )
            }
            if !items[tool].evidenceIDs.contains(id) {
                items[tool].evidenceIDs.append(id)
            }
        }
    }

    @discardableResult
    private mutating func addArtifact(
        _ reference: ArtifactReference,
        sequence: EventSequence,
        sourceCallID: ToolCallID?
    ) throws -> ArtifactID {
        let key: ArtifactKey = reference.contentDigest.isEmpty
            ? .artifactID(reference.artifactID)
            : .digest(reference.contentDigest)

        if let previousKey = artifactKeyByID[reference.artifactID] {
            guard let previousIndex = artifactIndex[previousKey],
                  artifacts[previousIndex].reference == reference
            else {
                throw AgentActivityProjectionError.artifactIdentityConflict(
                    runID: identity.runID,
                    artifactID: reference.artifactID
                )
            }
            if let sourceCallID,
               !artifacts[previousIndex].sourceToolCallIDs.contains(sourceCallID) {
                artifacts[previousIndex].sourceToolCallIDs.append(sourceCallID)
            }
            return artifacts[previousIndex].reference.artifactID
        }

        if let index = artifactIndex[key] {
            artifactKeyByID[reference.artifactID] = key
            if !artifacts[index].equivalentArtifactIDs.contains(reference.artifactID) {
                artifacts[index].equivalentArtifactIDs.append(reference.artifactID)
            }
            if let sourceCallID,
               !artifacts[index].sourceToolCallIDs.contains(sourceCallID) {
                artifacts[index].sourceToolCallIDs.append(sourceCallID)
            }
            return artifacts[index].reference.artifactID
        }

        let index = artifacts.count
        artifactIndex[key] = index
        artifactKeyByID[reference.artifactID] = key
        artifacts.append(
            ArtifactBuilder(
                reference: reference,
                run: identity,
                equivalentArtifactIDs: [reference.artifactID],
                firstSequence: sequence,
                sourceToolCallIDs: sourceCallID.map { [$0] } ?? []
            )
        )
        return reference.artifactID
    }

    private mutating func collectArtifacts(
        in item: ModelItem,
        sequence: EventSequence,
        sourceCallID: ToolCallID?
    ) throws {
        switch item.payload {
        case let .message(message):
            for part in message.content {
                if case let .artifact(artifact) = part {
                    _ = try addArtifact(
                        artifact,
                        sequence: sequence,
                        sourceCallID: sourceCallID
                    )
                }
            }
        case let .toolResult(result):
            for artifact in result.artifacts {
                _ = try addArtifact(
                    artifact,
                    sequence: sequence,
                    sourceCallID: result.callID
                )
            }
        case .reasoningSummary, .toolInvocation, .contextCheckpoint:
            break
        }
    }

    private mutating func appendArtifact(
        _ artifactID: ArtifactID,
        to callID: ToolCallID
    ) throws {
        guard let tool = toolItemIndex(callID) else {
            throw AgentActivityProjectionError.unknownTool(
                runID: identity.runID,
                callID: callID
            )
        }
        if !items[tool].artifactIDs.contains(artifactID) {
            items[tool].artifactIDs.append(artifactID)
        }
    }

    private mutating func addItem(
        id: AgentActivityItemID,
        kind: AgentActivitySemanticKind,
        state: AgentActivityState,
        summary: String,
        event: AgentEvent,
        attemptID: AttemptID? = nil,
        toolCallID: ToolCallID? = nil,
        errorMessage: String? = nil
    ) {
        guard itemIndex[id] == nil else { return }
        itemIndex[id] = items.count
        items.append(
            ItemBuilder(
                id: id,
                kind: kind,
                state: state,
                summary: summary,
                target: nil,
                attemptID: attemptID,
                toolCallID: toolCallID,
                firstSequence: event.header.sequence,
                lastSequence: event.header.sequence,
                startedAt: event.header.timestamp,
                endedAt: event.header.timestamp,
                errorMessage: errorMessage
            )
        )
    }

    private mutating func updateItem(
        _ id: AgentActivityItemID,
        state: AgentActivityState,
        event: AgentEvent,
        errorMessage: String? = nil
    ) throws {
        guard let index = itemIndex[id] else {
            if case let .tool(callID) = id {
                throw AgentActivityProjectionError.unknownTool(
                    runID: identity.runID,
                    callID: callID
                )
            }
            return
        }
        items[index].state = state
        items[index].lastSequence = event.header.sequence
        items[index].endedAt = event.header.timestamp
        items[index].errorMessage = errorMessage
    }

    private func toolItemIndex(_ callID: ToolCallID) -> Int? {
        itemIndex[.tool(callID)]
    }

    private func toolSummary(_ invocation: ToolInvocation) -> String {
        if let descriptor = Self.canonicalToolDescriptors[invocation.tool],
           descriptor.effectClass == invocation.effectClass {
            return descriptor.receipt.successSummary
        }
        switch invocation.effectClass {
        case .readOnlyLocal:
            return "Inspected workspace"
        case .scopedReversibleWrite:
            return "Updated workspace"
        case .broadOrDestructiveWrite:
            return "Performed a broad change"
        case .externalSideEffect:
            return "Performed an external action"
        case .credentialBearingOrPrivileged:
            return "Performed a privileged action"
        case .unrecoverableDenied:
            return "Blocked an unsafe action"
        }
    }

    private static let canonicalToolDescriptors: [ToolIdentity: ToolDescriptor] =
        Dictionary(
            uniqueKeysWithValues: SandboxToolCatalog.all.map { tool in
                (tool.descriptor.identity, tool.descriptor)
            }
        )

    private func cancellationSummary(_ reason: AgentCancellationReason) -> String {
        switch reason {
        case .userRequested: "Stopped by user"
        case .parentCancelled: "Stopped with parent run"
        case .budgetExhausted: "Stopped at budget limit"
        case .superseded: "Replaced by a newer run"
        case .shutdown: "Stopped during shutdown"
        case .policy: "Stopped by policy"
        }
    }

    private func presentationState(for phase: AgentRunPhase) -> AgentActivityState {
        switch phase {
        case .uninitialized, .accepted: .pending
        case .queued: .queued
        case .running: .running
        case .awaitingApproval: .awaitingApproval
        case .cancelling: .cancelling
        case .completed: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        case .interrupted: .interrupted
        }
    }

    private func groupSummary(
        state: AgentActivityState,
        actionCount: Int
    ) -> String {
        switch state {
        case .pending: "Preparing run"
        case .queued: "Run queued"
        case .running: actionCount == 0 ? "Working" : "Running \(actionCount) actions"
        case .awaitingApproval: "Approval needed"
        case .retrying: "Retrying"
        case .succeeded:
            actionCount == 0
                ? "Completed"
                : "Completed \(actionCount) \(actionCount == 1 ? "action" : "actions")"
        case .failed: lastErrorMessage ?? "Run failed"
        case .rejected: "Action rejected"
        case .cancelling: "Stopping"
        case .cancelled: "Run stopped"
        case .interrupted: lastErrorMessage ?? "Run interrupted"
        }
    }

    private func validate(
        _ state: AgentDomain.AgentRunState,
        matches group: AgentActivityGroup
    ) throws {
        guard let stateContext = state.context,
              AgentActivityRunIdentity(context: stateContext) == identity
        else {
            throw AgentActivityProjectionError.stateIdentityMismatch(identity.runID)
        }
        guard state.lastSequence == lastSequence else {
            throw AgentActivityProjectionError.stateSequenceMismatch(identity.runID)
        }
        guard presentationState(for: state.phase) == group.state,
              state.modelAttempts.map(\.attemptID) == group.attempts.map(\.id),
              state.tools.map(\.invocation.callID) == group.items.compactMap({ item in
                  item.kind == .tool ? item.toolCallID : nil
              }),
              state.approvals.map(\.request.requestID) == group.approvals.map(\.id)
        else {
            throw AgentActivityProjectionError.stateProjectionMismatch(identity.runID)
        }

        for stateAttempt in state.modelAttempts {
            guard let projected = group.attempts.first(where: {
                $0.id == stateAttempt.attemptID
            }), projected.state == presentationState(for: stateAttempt.status) else {
                throw AgentActivityProjectionError.stateProjectionMismatch(identity.runID)
            }
        }
        for stateTool in state.tools {
            guard let projected = group.items.first(where: {
                $0.toolCallID == stateTool.invocation.callID && $0.kind == .tool
            }), projected.state == presentationState(for: stateTool) else {
                throw AgentActivityProjectionError.stateProjectionMismatch(identity.runID)
            }
        }
        for stateApproval in state.approvals {
            guard let projected = group.approvals.first(where: {
                $0.id == stateApproval.request.requestID
            }), projected.state == presentationState(for: stateApproval.status) else {
                throw AgentActivityProjectionError.stateProjectionMismatch(identity.runID)
            }
        }
    }

    private func presentationState(for status: ModelAttemptStatus) -> AgentActivityState {
        switch status {
        case .active: .running
        case .responseCommitted: .succeeded
        case .failedBeforeCommit, .failedAfterCommit: .failed
        case .retryScheduled: .retrying
        }
    }

    private func presentationState(for tool: ToolExecutionState) -> AgentActivityState {
        switch tool.status {
        case .proposed, .approved: .pending
        case .awaitingApproval: .awaitingApproval
        case .rejected: .rejected
        case .scheduled: .queued
        case .running, .applied: .running
        case .completed:
            switch tool.result?.status {
            case .failed: .failed
            case .cancelled: .cancelled
            case .succeeded, .none: .succeeded
            }
        }
    }

    private func presentationState(
        for status: ApprovalRequestStatus
    ) -> AgentActivityState {
        switch status {
        case .pending: .awaitingApproval
        case .approved: .succeeded
        case .rejected: .rejected
        }
    }
}

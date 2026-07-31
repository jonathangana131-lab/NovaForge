import AgentDomain
import Foundation

public enum AgentHeaderField: String, Codable, Hashable, Sendable {
    case schemaVersion
    case runID
    case rootRunID
    case parentRunID
    case executionNodeID
    case conversationID
    case projectID
    case workspaceID
    case engineVersion
}

public enum AgentInvariantFailure: Error, Equatable, Sendable {
    case unsupportedEventSchema(actual: AgentSchemaVersion, supported: AgentSchemaVersion)
    case unsupportedContextSchema(actual: AgentSchemaVersion, supported: AgentSchemaVersion)
    case unexpectedFirstEvent(AgentEventKind)
    case invalidFirstSequence(EventSequence)
    case invalidLineage(AgentRunLineageError)
    case acceptanceTimestampMismatch
    case invalidInitialItems
    case acceptedEngineVersionMismatch
    case duplicateEventID(EventID)
    case sequenceOverflow
    case nonMonotonicSequence(expected: EventSequence, actual: EventSequence)
    case headerContextMismatch(AgentHeaderField)
    case alreadyTerminal(terminalEventID: EventID)
    case invalidTransition(phase: AgentRunPhase, event: AgentEventKind)
    case duplicateModelItem(ModelItemID)
    case duplicateAttempt(AttemptID)
    case missingProviderAttemptMetadata(AttemptID)
    case duplicateProviderAttemptScope
    case duplicateProviderAttemptOrdinal(UInt32)
    case unknownAttempt(AttemptID)
    case attemptMismatch(expected: AttemptID, actual: AttemptID)
    case attemptAlreadyActive(AttemptID)
    case retryNotAllowed(AttemptID)
    case retryTargetMismatch(expected: AttemptID, actual: AttemptID)
    case budgetExhausted(AgentBudgetDimension)
    case budgetOverflow(AgentBudgetDimension)
    case invalidModelUsage
    case planRevisionNotMonotonic(previous: UInt64, actual: UInt64)
    case duplicateToolCall(ToolCallID)
    case invalidProviderToolCallID(ToolCallID)
    case duplicateProviderToolCallID(String)
    case modelAttemptToolCallMismatch(ToolCallID)
    case duplicateIdempotencyKey(String)
    case unknownToolCall(ToolCallID)
    case toolInvocationNotCommitted(ToolCallID)
    case invalidToolTransition(callID: ToolCallID, from: ToolExecutionStatus, event: AgentEventKind)
    case missingToolEffect(ToolCallID)
    case unexpectedToolEffect(ToolCallID)
    case toolEffectMismatch(ToolCallID)
    case duplicateApproval(ApprovalRequestID)
    case unknownApproval(ApprovalRequestID)
    case approvalMismatch
    case invalidApprovalBinding
    case invalidToolResult(ToolCallID)
    case invalidApprovalRejectionResult(ToolCallID)
    case duplicateArtifact(ArtifactID)
    case duplicateCheckpoint(ContextCheckpointID)
    case unsettledWork
    case cancellationNotRequested
    case internalReducerError
}

/// Pure event reducer. Rejected events return a failure and leave the input value untouched.
public enum AgentReducer {
    public static func reduce(
        _ state: AgentRunState,
        event: AgentEvent
    ) -> Result<AgentRunState, AgentInvariantFailure> {
        do {
            return .success(try applying(event, to: state))
        } catch let failure as AgentInvariantFailure {
            return .failure(failure)
        } catch {
            return .failure(.internalReducerError)
        }
    }

    private static func applying(
        _ event: AgentEvent,
        to state: AgentRunState
    ) throws -> AgentRunState {
        guard event.header.schemaVersion.canBeDecoded() else {
            throw AgentInvariantFailure.unsupportedEventSchema(
                actual: event.header.schemaVersion,
                supported: .current
            )
        }

        if state.phase == .uninitialized {
            return try applyingAcceptance(event, to: state)
        }

        guard let context = state.context else {
            throw AgentInvariantFailure.invalidTransition(
                phase: state.phase,
                event: event.payload.kind
            )
        }
        try validate(event.header, against: context)

        if state.appliedEventIDs.contains(event.header.eventID) {
            throw AgentInvariantFailure.duplicateEventID(event.header.eventID)
        }

        guard let expected = state.lastSequence?.successor else {
            throw AgentInvariantFailure.sequenceOverflow
        }
        guard event.header.sequence == expected else {
            throw AgentInvariantFailure.nonMonotonicSequence(
                expected: expected,
                actual: event.header.sequence
            )
        }

        if state.phase.isTerminal {
            throw AgentInvariantFailure.alreadyTerminal(
                terminalEventID: state.terminalEventID ?? state.lastEventID ?? event.header.eventID
            )
        }

        var next = state
        switch event.payload {
        case .runAccepted:
            throw AgentInvariantFailure.invalidTransition(
                phase: state.phase,
                event: .runAccepted
            )

        case .runQueued:
            try require(state.phase, isOneOf: [.accepted], event: .runQueued)
            next.phase = .queued

        case .runStarted:
            try require(state.phase, isOneOf: [.accepted, .queued], event: .runStarted)
            next.phase = .running

        case .contextPrepared:
            try require(state.phase, isOneOf: [.running], event: .contextPrepared)

        case let .contextCompressed(payload):
            try require(state.phase, isOneOf: [.running], event: .contextCompressed)
            guard !next.checkpoints.contains(where: { $0.checkpointID == payload.checkpoint.checkpointID }) else {
                throw AgentInvariantFailure.duplicateCheckpoint(payload.checkpoint.checkpointID)
            }
            next.checkpoints.append(payload.checkpoint)

        case let .modelRequestStarted(payload):
            try require(state.phase, isOneOf: [.running], event: .modelRequestStarted)
            if let active = state.activeAttemptID {
                throw AgentInvariantFailure.attemptAlreadyActive(active)
            }
            guard !state.modelAttempts.contains(where: { $0.attemptID == payload.attemptID }) else {
                throw AgentInvariantFailure.duplicateAttempt(payload.attemptID)
            }
            if let scheduled = state.scheduledAttemptID, scheduled != payload.attemptID {
                throw AgentInvariantFailure.retryTargetMismatch(
                    expected: scheduled,
                    actual: payload.attemptID
                )
            }
            if context.schemaVersion >= .v1_1 {
                guard !payload.providerAttempt.isLegacyV1 else {
                    throw AgentInvariantFailure.missingProviderAttemptMetadata(
                        payload.attemptID
                    )
                }
            }
            if case let .recordedV1_1(_, scope, ordinal, _) = payload.providerAttempt {
                guard !state.modelAttempts.contains(where: { attempt in
                    guard case let .recordedV1_1(_, priorScope, _, _) =
                        attempt.providerAttempt
                    else { return false }
                    return priorScope == scope
                }) else {
                    throw AgentInvariantFailure.duplicateProviderAttemptScope
                }
                guard !state.modelAttempts.contains(where: { attempt in
                    guard case let .recordedV1_1(_, _, priorOrdinal, _) =
                        attempt.providerAttempt
                    else { return false }
                    return priorOrdinal == ordinal
                }) else {
                    throw AgentInvariantFailure.duplicateProviderAttemptOrdinal(ordinal)
                }
            }
            try requireBudgetAvailable(.iterations, in: state)
            try requireBudgetAvailable(.providerAttempts, in: state)
            next.budget = try applyBudget(
                AgentBudgetUsage(iterations: 1, providerAttempts: 1),
                to: state
            )
            next.modelAttempts.append(
                ModelAttemptState(
                    attemptID: payload.attemptID,
                    route: payload.route,
                    providerAttempt: payload.providerAttempt,
                    status: .active
                )
            )
            next.activeAttemptID = payload.attemptID
            next.scheduledAttemptID = nil

        case let .modelResponseCommitted(payload):
            try require(state.phase, isOneOf: [.running], event: .modelResponseCommitted)
            try requireActiveAttempt(payload.attemptID, in: state)
            guard payload.usage.cachedInputTokens <= payload.usage.inputTokens else {
                throw AgentInvariantFailure.invalidModelUsage
            }
            var providerCallIDs = Set<String>(state.modelItems.compactMap { item in
                guard case let .toolInvocation(invocation) = item.payload else {
                    return nil
                }
                return invocation.providerCallID
            })
            for item in payload.items {
                guard case let .toolInvocation(invocation) = item.payload else {
                    continue
                }
                guard invocation.modelAttemptID == payload.attemptID else {
                    throw AgentInvariantFailure.modelAttemptToolCallMismatch(
                        invocation.callID
                    )
                }
                if context.schemaVersion >= .v1_1,
                   !invocation.hasCanonicalProviderCallID
                {
                    throw AgentInvariantFailure.invalidProviderToolCallID(
                        invocation.callID
                    )
                }
                if context.schemaVersion >= .v1_1,
                   let providerCallID = invocation.providerCallID,
                   !providerCallIDs.insert(providerCallID).inserted
                {
                    throw AgentInvariantFailure.duplicateProviderToolCallID(
                        providerCallID
                    )
                }
            }
            try ensureUniqueItems(payload.items, existing: state.modelItems)
            guard let index = next.modelAttempts.firstIndex(where: { $0.attemptID == payload.attemptID }) else {
                throw AgentInvariantFailure.unknownAttempt(payload.attemptID)
            }
            next.modelAttempts[index].status = .responseCommitted
            if context.schemaVersion >= .v1_1 {
                next.modelAttempts[index].usage = payload.usage
                next.modelAttempts[index].finishReason = payload.finishReason
            }
            next.modelItems.append(contentsOf: payload.items)
            next.activeAttemptID = nil
            next.budget = try applyBudget(payload.usage.budgetUsage, to: state)

        case let .modelRequestFailed(payload):
            try require(state.phase, isOneOf: [.running], event: .modelRequestFailed)
            try requireActiveAttempt(payload.attemptID, in: state)
            guard let index = next.modelAttempts.firstIndex(where: { $0.attemptID == payload.attemptID }) else {
                throw AgentInvariantFailure.unknownAttempt(payload.attemptID)
            }
            next.modelAttempts[index].status = payload.outputWasCommitted
                ? .failedAfterCommit
                : .failedBeforeCommit
            next.modelAttempts[index].error = payload.error
            next.activeAttemptID = nil
            next.lastError = payload.error

        case .providerRouteChanged:
            try require(state.phase, isOneOf: [.running], event: .providerRouteChanged)
            if let active = state.activeAttemptID {
                throw AgentInvariantFailure.attemptAlreadyActive(active)
            }

        case let .planUpdated(payload):
            try require(state.phase, isOneOf: [.running], event: .planUpdated)
            if let previous = state.latestPlanRevision, payload.revision <= previous {
                throw AgentInvariantFailure.planRevisionNotMonotonic(
                    previous: previous,
                    actual: payload.revision
                )
            }
            next.latestPlanRevision = payload.revision

        case let .toolProposed(payload):
            try require(state.phase, isOneOf: [.running], event: .toolProposed)
            let invocation = payload.invocation
            guard !state.tools.contains(where: { $0.invocation.callID == invocation.callID }) else {
                throw AgentInvariantFailure.duplicateToolCall(invocation.callID)
            }
            guard !state.tools.contains(where: { $0.invocation.idempotencyKey == invocation.idempotencyKey }) else {
                throw AgentInvariantFailure.duplicateIdempotencyKey(invocation.idempotencyKey)
            }
            guard state.modelItems.contains(where: {
                guard case let .toolInvocation(committed) = $0.payload else { return false }
                return committed == invocation
            }) else {
                throw AgentInvariantFailure.toolInvocationNotCommitted(invocation.callID)
            }
            try requireBudgetAvailable(.toolInvocations, in: state)
            next.budget = try applyBudget(
                AgentBudgetUsage(toolInvocations: 1),
                to: state
            )
            next.tools.append(ToolExecutionState(invocation: invocation))

        case let .approvalRequested(payload):
            try require(state.phase, isOneOf: [.running], event: .approvalRequested)
            let request = payload.request
            guard !state.approvals.contains(where: { $0.request.requestID == request.requestID }) else {
                throw AgentInvariantFailure.duplicateApproval(request.requestID)
            }
            guard let toolIndex = next.tools.firstIndex(where: { $0.invocation.callID == request.binding.callID }) else {
                throw AgentInvariantFailure.unknownToolCall(request.binding.callID)
            }
            let tool = next.tools[toolIndex]
            guard tool.status == .proposed else {
                throw AgentInvariantFailure.invalidToolTransition(
                    callID: tool.invocation.callID,
                    from: tool.status,
                    event: .approvalRequested
                )
            }
            guard request.binding.runID == context.lineage.runID,
                  request.binding.workspaceID == context.workspaceID,
                  request.binding.tool == tool.invocation.tool,
                  request.binding.canonicalArgumentDigest == tool.invocation.canonicalArgumentDigest
            else {
                throw AgentInvariantFailure.invalidApprovalBinding
            }
            next.tools[toolIndex].status = .awaitingApproval
            next.approvals.append(ApprovalRequestState(request: request))
            next.phase = .awaitingApproval

        case let .approvalResolved(payload):
            try require(state.phase, isOneOf: [.awaitingApproval], event: .approvalResolved)
            let resolution = payload.resolution
            guard let approvalIndex = next.approvals.firstIndex(where: {
                $0.request.requestID == resolution.requestID
            }) else {
                throw AgentInvariantFailure.unknownApproval(resolution.requestID)
            }
            let approval = next.approvals[approvalIndex]
            guard approval.status == .pending,
                  approval.request.binding.callID == resolution.callID
            else {
                throw AgentInvariantFailure.approvalMismatch
            }
            guard let toolIndex = next.tools.firstIndex(where: {
                $0.invocation.callID == resolution.callID
            }) else {
                throw AgentInvariantFailure.unknownToolCall(resolution.callID)
            }
            guard next.tools[toolIndex].status == .awaitingApproval else {
                throw AgentInvariantFailure.invalidToolTransition(
                    callID: resolution.callID,
                    from: next.tools[toolIndex].status,
                    event: .approvalResolved
                )
            }
            switch resolution.decision {
            case .approved:
                next.approvals[approvalIndex].status = .approved
                next.tools[toolIndex].status = .approved
            case .rejected:
                next.approvals[approvalIndex].status = .rejected
                next.tools[toolIndex].status = .rejected
            }
            next.approvals[approvalIndex].resolution = resolution
            next.phase = next.approvals.contains(where: { $0.status == .pending })
                ? .awaitingApproval
                : .running

        case let .toolScheduled(payload):
            try require(state.phase, isOneOf: [.running], event: .toolScheduled)
            let index = try toolIndex(payload.callID, in: next)
            let status = next.tools[index].status
            guard status == .proposed || status == .approved else {
                throw AgentInvariantFailure.invalidToolTransition(
                    callID: payload.callID,
                    from: status,
                    event: .toolScheduled
                )
            }
            let mutation = isMutation(next.tools[index].invocation)
            if context.schemaVersion >= .v1_1 {
                if mutation, payload.effect == nil {
                    throw AgentInvariantFailure.missingToolEffect(payload.callID)
                }
                if !mutation, payload.effect != nil {
                    throw AgentInvariantFailure.unexpectedToolEffect(payload.callID)
                }
            }
            next.tools[index].effectKey = payload.effect
            next.tools[index].status = .scheduled

        case let .toolStarted(payload):
            try require(state.phase, isOneOf: [.running], event: .toolStarted)
            let index = try toolIndex(payload.callID, in: next)
            let status = next.tools[index].status
            guard status == .scheduled else {
                throw AgentInvariantFailure.invalidToolTransition(
                    callID: payload.callID,
                    from: status,
                    event: .toolStarted
                )
            }
            if payload.effect != next.tools[index].effectKey {
                throw AgentInvariantFailure.toolEffectMismatch(payload.callID)
            }
            if context.schemaVersion >= .v1_1,
               isMutation(next.tools[index].invocation),
               payload.effect == nil
            {
                throw AgentInvariantFailure.missingToolEffect(payload.callID)
            }
            next.tools[index].status = .running

        case let .toolApplied(payload):
            try require(state.phase, isOneOf: [.running], event: .toolApplied)
            let index = try toolIndex(payload.callID, in: next)
            let status = next.tools[index].status
            guard status == .running else {
                throw AgentInvariantFailure.invalidToolTransition(
                    callID: payload.callID,
                    from: status,
                    event: .toolApplied
                )
            }
            let mutation = isMutation(next.tools[index].invocation)
            if context.schemaVersion >= .v1_1 {
                if mutation, payload.effect == nil {
                    throw AgentInvariantFailure.missingToolEffect(payload.callID)
                }
                if !mutation, payload.effect != nil {
                    throw AgentInvariantFailure.unexpectedToolEffect(payload.callID)
                }
            }
            if let effect = payload.effect {
                guard effect.effectKey == next.tools[index].effectKey else {
                    throw AgentInvariantFailure.toolEffectMismatch(payload.callID)
                }
            } else if next.tools[index].effectKey != nil && mutation {
                throw AgentInvariantFailure.missingToolEffect(payload.callID)
            }
            next.tools[index].status = .applied
            next.tools[index].effectReceipt = payload.effect
            next.tools[index].applicationEvidence = payload.evidence

        case let .toolCompleted(payload):
            try require(state.phase, isOneOf: [.running], event: .toolCompleted)
            let result = payload.result
            let index = try toolIndex(result.callID, in: next)
            let status = next.tools[index].status
            if status == .rejected {
                guard context.schemaVersion >= .v1_1,
                      next.tools[index].result == nil,
                      result.isCanonicalApprovalRejection,
                      payload.effect == nil
                else {
                    throw AgentInvariantFailure.invalidApprovalRejectionResult(
                        result.callID
                    )
                }
                try appendToolResult(
                    result,
                    at: event.header.timestamp,
                    to: &next
                )
                // Preserve the rejected status as the durable proof that the
                // tool never crossed schedule/start/apply.
                next.tools[index].result = result
                break
            }
            guard status == .running || status == .applied else {
                throw AgentInvariantFailure.invalidToolTransition(
                    callID: result.callID,
                    from: status,
                    event: .toolCompleted
                )
            }
            let mutation = isMutation(next.tools[index].invocation)
            if context.schemaVersion >= .v1_1 {
                if mutation && result.status == .succeeded && status != .applied {
                    throw AgentInvariantFailure.missingToolEffect(result.callID)
                }
                if status == .applied && mutation {
                    guard let applied = next.tools[index].effectReceipt,
                          payload.effect == applied
                    else {
                        throw AgentInvariantFailure.toolEffectMismatch(result.callID)
                    }
                } else if payload.effect != nil {
                    throw AgentInvariantFailure.unexpectedToolEffect(result.callID)
                }
                if !mutation, payload.effect != nil {
                    throw AgentInvariantFailure.unexpectedToolEffect(result.callID)
                }
            } else if let effect = payload.effect,
                      effect != next.tools[index].effectReceipt
            {
                throw AgentInvariantFailure.toolEffectMismatch(result.callID)
            }
            guard (result.status == .succeeded && result.error == nil)
                    || (result.status == .failed && result.error != nil)
                    || result.status == .cancelled
            else {
                throw AgentInvariantFailure.invalidToolResult(result.callID)
            }
            try appendToolResult(result, at: event.header.timestamp, to: &next)
            next.tools[index].status = .completed
            next.tools[index].result = result

        case let .artifactCaptured(payload):
            try require(state.phase, isOneOf: [.running], event: .artifactCaptured)
            guard !state.artifacts.contains(where: { $0.artifactID == payload.artifact.artifactID }) else {
                throw AgentInvariantFailure.duplicateArtifact(payload.artifact.artifactID)
            }
            next.artifacts.append(payload.artifact)

        case let .checkpointCreated(payload):
            try require(state.phase, isOneOf: [.running], event: .checkpointCreated)
            guard !state.checkpoints.contains(where: { $0.checkpointID == payload.checkpoint.checkpointID }) else {
                throw AgentInvariantFailure.duplicateCheckpoint(payload.checkpoint.checkpointID)
            }
            next.checkpoints.append(payload.checkpoint)

        case let .retryScheduled(payload):
            try require(state.phase, isOneOf: [.running], event: .retryScheduled)
            if let active = state.activeAttemptID {
                throw AgentInvariantFailure.attemptAlreadyActive(active)
            }
            if let scheduled = state.scheduledAttemptID {
                throw AgentInvariantFailure.retryTargetMismatch(
                    expected: scheduled,
                    actual: payload.nextAttemptID
                )
            }
            guard payload.failedAttemptID != payload.nextAttemptID else {
                throw AgentInvariantFailure.retryNotAllowed(payload.failedAttemptID)
            }
            guard !state.modelAttempts.contains(where: { $0.attemptID == payload.nextAttemptID }) else {
                throw AgentInvariantFailure.duplicateAttempt(payload.nextAttemptID)
            }
            guard let failedIndex = next.modelAttempts.firstIndex(where: {
                $0.attemptID == payload.failedAttemptID
            }) else {
                throw AgentInvariantFailure.unknownAttempt(payload.failedAttemptID)
            }
            guard next.modelAttempts[failedIndex].status == .failedBeforeCommit else {
                throw AgentInvariantFailure.retryNotAllowed(payload.failedAttemptID)
            }
            try requireBudgetAvailable(.retries, in: state)
            next.budget = try applyBudget(AgentBudgetUsage(retries: 1), to: state)
            next.modelAttempts[failedIndex].status = .retryScheduled
            next.scheduledAttemptID = payload.nextAttemptID
            next.retryLineage.append(
                AttemptRetryLineage(
                    failedAttemptID: payload.failedAttemptID,
                    nextAttemptID: payload.nextAttemptID,
                    reason: payload.reason
                )
            )

        case let .cancellationRequested(payload):
            try require(
                state.phase,
                isOneOf: [.accepted, .queued, .running, .awaitingApproval],
                event: .cancellationRequested
            )
            next.phase = .cancelling
            next.cancellation = CancellationRequestState(
                reason: payload.reason,
                propagateToDescendants: payload.propagateToDescendants,
                eventID: event.header.eventID
            )

        case .runCompleted:
            try require(state.phase, isOneOf: [.running], event: .runCompleted)
            guard state.activeAttemptID == nil,
                  state.scheduledAttemptID == nil,
                  !state.approvals.contains(where: { $0.status == .pending }),
                  state.tools.allSatisfy({ $0.status.isSettled }),
                  state.budget?.exceededDimensions.isEmpty != false
            else {
                throw AgentInvariantFailure.unsettledWork
            }
            next.phase = .completed
            next.terminalEventID = event.header.eventID

        case let .runFailed(payload):
            try require(
                state.phase,
                isOneOf: [.accepted, .queued, .running, .awaitingApproval, .cancelling],
                event: .runFailed
            )
            next.phase = .failed
            next.activeAttemptID = nil
            next.scheduledAttemptID = nil
            next.lastError = payload.error
            next.terminalEventID = event.header.eventID

        case let .runCancelled(payload):
            try require(state.phase, isOneOf: [.cancelling], event: .runCancelled)
            guard state.cancellation != nil else {
                throw AgentInvariantFailure.cancellationNotRequested
            }
            next.phase = .cancelled
            next.activeAttemptID = nil
            next.scheduledAttemptID = nil
            next.lastError = AgentErrorInfo(
                category: .cancelled,
                code: payload.reason.rawValue,
                publicMessage: "Run cancelled",
                retryable: payload.reason != .policy
            )
            next.terminalEventID = event.header.eventID

        case let .runInterrupted(payload):
            try require(
                state.phase,
                isOneOf: [.accepted, .queued, .running, .awaitingApproval, .cancelling],
                event: .runInterrupted
            )
            next.phase = .interrupted
            next.activeAttemptID = nil
            next.scheduledAttemptID = nil
            next.lastError = payload.error
            next.terminalEventID = event.header.eventID
        }

        next.lastSequence = event.header.sequence
        next.lastEventID = event.header.eventID
        next.appliedEventIDs.append(event.header.eventID)
        return next
    }

    private static func applyingAcceptance(
        _ event: AgentEvent,
        to state: AgentRunState
    ) throws -> AgentRunState {
        guard case let .runAccepted(payload) = event.payload else {
            throw AgentInvariantFailure.unexpectedFirstEvent(event.payload.kind)
        }
        guard event.header.sequence == .first else {
            throw AgentInvariantFailure.invalidFirstSequence(event.header.sequence)
        }
        guard payload.context.schemaVersion.canBeDecoded() else {
            throw AgentInvariantFailure.unsupportedContextSchema(
                actual: payload.context.schemaVersion,
                supported: .current
            )
        }
        if let error = payload.context.lineage.validationError {
            throw AgentInvariantFailure.invalidLineage(error)
        }
        guard payload.acceptedEngineVersion == payload.context.engineVersion else {
            throw AgentInvariantFailure.acceptedEngineVersionMismatch
        }
        try validate(event.header, against: payload.context)
        guard event.header.timestamp == payload.context.acceptedAt else {
            throw AgentInvariantFailure.acceptanceTimestampMismatch
        }
        guard payload.initialItems.contains(where: {
            guard case let .message(message) = $0.payload else { return false }
            return message.role == .user
        }) else {
            throw AgentInvariantFailure.invalidInitialItems
        }
        try ensureUniqueItems(payload.initialItems, existing: [])

        var next = state
        next.schemaVersion = payload.context.schemaVersion
        next.context = payload.context
        next.phase = .accepted
        next.lastSequence = event.header.sequence
        next.lastEventID = event.header.eventID
        next.appliedEventIDs = [event.header.eventID]
        next.budget = payload.context.initialBudget
        next.modelItems = payload.initialItems
        return next
    }

    private static func validate(
        _ header: AgentEventHeader,
        against context: AgentRunContext
    ) throws {
        if header.schemaVersion != context.schemaVersion {
            throw AgentInvariantFailure.headerContextMismatch(.schemaVersion)
        }
        if header.runID != context.lineage.runID {
            throw AgentInvariantFailure.headerContextMismatch(.runID)
        }
        if header.rootRunID != context.lineage.rootRunID {
            throw AgentInvariantFailure.headerContextMismatch(.rootRunID)
        }
        if header.parentRunID != context.lineage.parentRunID {
            throw AgentInvariantFailure.headerContextMismatch(.parentRunID)
        }
        if header.executionNodeID != context.executionNodeID {
            throw AgentInvariantFailure.headerContextMismatch(.executionNodeID)
        }
        if header.conversationID != context.conversationID {
            throw AgentInvariantFailure.headerContextMismatch(.conversationID)
        }
        if header.projectID != context.projectID {
            throw AgentInvariantFailure.headerContextMismatch(.projectID)
        }
        if header.workspaceID != context.workspaceID {
            throw AgentInvariantFailure.headerContextMismatch(.workspaceID)
        }
        if header.engineVersion != context.engineVersion {
            throw AgentInvariantFailure.headerContextMismatch(.engineVersion)
        }
    }

    private static func require(
        _ phase: AgentRunPhase,
        isOneOf allowed: Set<AgentRunPhase>,
        event: AgentEventKind
    ) throws {
        guard allowed.contains(phase) else {
            throw AgentInvariantFailure.invalidTransition(phase: phase, event: event)
        }
    }

    private static func requireActiveAttempt(
        _ attemptID: AttemptID,
        in state: AgentRunState
    ) throws {
        guard let active = state.activeAttemptID else {
            throw AgentInvariantFailure.unknownAttempt(attemptID)
        }
        guard active == attemptID else {
            throw AgentInvariantFailure.attemptMismatch(expected: active, actual: attemptID)
        }
    }

    private static func toolIndex(
        _ callID: ToolCallID,
        in state: AgentRunState
    ) throws -> Int {
        guard let index = state.tools.firstIndex(where: { $0.invocation.callID == callID }) else {
            throw AgentInvariantFailure.unknownToolCall(callID)
        }
        return index
    }

    private static func isMutation(_ invocation: ToolInvocation) -> Bool {
        invocation.effectClass != .readOnlyLocal
    }

    private static func appendToolResult(
        _ result: ToolResult,
        at timestamp: AgentInstant,
        to state: inout AgentRunState
    ) throws {
        let item = ModelItem(
            id: result.modelItemID,
            createdAt: timestamp,
            payload: .toolResult(result)
        )
        try ensureUniqueItems([item], existing: state.modelItems)
        state.modelItems.append(item)
    }

    private static func ensureUniqueItems(
        _ items: [ModelItem],
        existing: [ModelItem]
    ) throws {
        var seen = Set(existing.map(\.id))
        for item in items {
            guard seen.insert(item.id).inserted else {
                throw AgentInvariantFailure.duplicateModelItem(item.id)
            }
        }
    }

    private static func requireBudgetAvailable(
        _ dimension: AgentBudgetDimension,
        in state: AgentRunState
    ) throws {
        guard let budget = state.budget else {
            throw AgentInvariantFailure.budgetExhausted(dimension)
        }
        if budget.exhaustedDimensions.contains(dimension) {
            throw AgentInvariantFailure.budgetExhausted(dimension)
        }
    }

    private static func applyBudget(
        _ delta: AgentBudgetUsage,
        to state: AgentRunState
    ) throws -> AgentBudget {
        guard let budget = state.budget else {
            throw AgentInvariantFailure.budgetExhausted(.iterations)
        }
        do {
            return try budget.applying(delta)
        } catch let error as AgentBudgetArithmeticError {
            switch error {
            case let .overflow(dimension):
                throw AgentInvariantFailure.budgetOverflow(dimension)
            }
        }
    }
}

import Foundation

public struct AgentEventHeader: Codable, Equatable, Sendable {
    public let eventID: EventID
    public let schemaVersion: AgentSchemaVersion
    public let runID: RunID
    public let rootRunID: RunID
    public let parentRunID: RunID?
    public let sequence: EventSequence
    public let timestamp: AgentInstant
    public let executionNodeID: ExecutionNodeID
    public let conversationID: ConversationID
    public let projectID: ProjectID?
    public let workspaceID: WorkspaceID
    public let causationID: CausationID?
    public let correlationID: CorrelationID
    public let engineVersion: EngineVersion

    public init(
        eventID: EventID,
        schemaVersion: AgentSchemaVersion = .current,
        runID: RunID,
        rootRunID: RunID,
        parentRunID: RunID?,
        sequence: EventSequence,
        timestamp: AgentInstant,
        executionNodeID: ExecutionNodeID,
        conversationID: ConversationID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        causationID: CausationID?,
        correlationID: CorrelationID,
        engineVersion: EngineVersion
    ) {
        self.eventID = eventID
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.rootRunID = rootRunID
        self.parentRunID = parentRunID
        self.sequence = sequence
        self.timestamp = timestamp
        self.executionNodeID = executionNodeID
        self.conversationID = conversationID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.causationID = causationID
        self.correlationID = correlationID
        self.engineVersion = engineVersion
    }

    public init(
        eventID: EventID,
        schemaVersion: AgentSchemaVersion = .current,
        context: AgentRunContext,
        sequence: EventSequence,
        timestamp: AgentInstant,
        causationID: CausationID?,
        correlationID: CorrelationID
    ) {
        self.init(
            eventID: eventID,
            schemaVersion: schemaVersion,
            runID: context.lineage.runID,
            rootRunID: context.lineage.rootRunID,
            parentRunID: context.lineage.parentRunID,
            sequence: sequence,
            timestamp: timestamp,
            executionNodeID: context.executionNodeID,
            conversationID: context.conversationID,
            projectID: context.projectID,
            workspaceID: context.workspaceID,
            causationID: causationID,
            correlationID: correlationID,
            engineVersion: context.engineVersion
        )
    }
}

public struct RunAcceptedEvent: Codable, Equatable, Sendable {
    public let context: AgentRunContext
    /// Engine selected once, at acceptance. This duplicates the immutable
    /// context value intentionally so acceptance records can bind it directly.
    public let acceptedEngineVersion: EngineVersion
    public let initialItems: [ModelItem]

    public init(
        context: AgentRunContext,
        acceptedEngineVersion: EngineVersion? = nil,
        initialItems: [ModelItem]
    ) {
        self.context = context
        self.acceptedEngineVersion = acceptedEngineVersion ?? context.engineVersion
        self.initialItems = initialItems
    }

    private enum CodingKeys: String, CodingKey {
        case context
        case acceptedEngineVersion
        case initialItems
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let context = try container.decode(AgentRunContext.self, forKey: .context)
        let acceptedEngineVersion: EngineVersion
        if context.schemaVersion >= .v1_1 {
            acceptedEngineVersion = try container.decode(
                EngineVersion.self,
                forKey: .acceptedEngineVersion
            )
        } else {
            acceptedEngineVersion = try container.decodeIfPresent(
                EngineVersion.self,
                forKey: .acceptedEngineVersion
            ) ?? context.engineVersion
        }
        self.init(
            context: context,
            acceptedEngineVersion: acceptedEngineVersion,
            initialItems: try container.decode([ModelItem].self, forKey: .initialItems)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(context, forKey: .context)
        if context.schemaVersion >= .v1_1 {
            try container.encode(acceptedEngineVersion, forKey: .acceptedEngineVersion)
        }
        try container.encode(initialItems, forKey: .initialItems)
    }
}

public struct RunQueuedEvent: Codable, Equatable, Sendable {
    public let reason: String?
    public init(reason: String? = nil) { self.reason = reason }
}

public struct RunStartedEvent: Codable, Equatable, Sendable {
    public let resumed: Bool
    public init(resumed: Bool = false) { self.resumed = resumed }
}

public struct ContextPreparedEvent: Codable, Equatable, Sendable {
    public let itemIDs: [ModelItemID]
    public let estimatedTokens: UInt64
    public let contextDigest: String

    public init(itemIDs: [ModelItemID], estimatedTokens: UInt64, contextDigest: String) {
        self.itemIDs = itemIDs
        self.estimatedTokens = estimatedTokens
        self.contextDigest = contextDigest
    }
}

public struct ContextCompressedEvent: Codable, Equatable, Sendable {
    public let checkpoint: ContextCheckpointReference
    public init(checkpoint: ContextCheckpointReference) { self.checkpoint = checkpoint }
}

public struct ModelRequestStartedEvent: Codable, Equatable, Sendable {
    public let attemptID: AttemptID
    public let route: ModelRoute
    public let providerAttempt: ProviderAttemptJournalMetadata

    public init(
        attemptID: AttemptID,
        route: ModelRoute,
        providerAttempt: ProviderAttemptJournalMetadata = .legacyV1
    ) {
        self.attemptID = attemptID
        self.route = route
        self.providerAttempt = providerAttempt
    }

    private enum CodingKeys: String, CodingKey {
        case attemptID
        case route
        case providerAttempt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            attemptID: try container.decode(AttemptID.self, forKey: .attemptID),
            route: try container.decode(ModelRoute.self, forKey: .route),
            providerAttempt: try container.decodeIfPresent(
                ProviderAttemptJournalMetadata.self,
                forKey: .providerAttempt
            ) ?? .legacyV1
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attemptID, forKey: .attemptID)
        try container.encode(route, forKey: .route)
        if !providerAttempt.isLegacyV1 {
            try container.encode(providerAttempt, forKey: .providerAttempt)
        }
    }
}

public struct ModelResponseCommittedEvent: Codable, Equatable, Sendable {
    public let attemptID: AttemptID
    public let items: [ModelItem]
    public let usage: ModelUsage
    public let finishReason: ModelFinishReason

    public init(
        attemptID: AttemptID,
        items: [ModelItem],
        usage: ModelUsage,
        finishReason: ModelFinishReason
    ) {
        self.attemptID = attemptID
        self.items = items
        self.usage = usage
        self.finishReason = finishReason
    }
}

public struct ModelRequestFailedEvent: Codable, Equatable, Sendable {
    public let attemptID: AttemptID
    public let error: AgentErrorInfo
    public let outputWasCommitted: Bool

    public init(attemptID: AttemptID, error: AgentErrorInfo, outputWasCommitted: Bool) {
        self.attemptID = attemptID
        self.error = error
        self.outputWasCommitted = outputWasCommitted
    }
}

public struct ProviderRouteChangedEvent: Codable, Equatable, Sendable {
    public let from: ModelRoute
    public let to: ModelRoute
    public let reason: String

    public init(from: ModelRoute, to: ModelRoute, reason: String) {
        self.from = from
        self.to = to
        self.reason = reason
    }
}

public struct PlanUpdatedEvent: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let summary: String

    public init(revision: UInt64, summary: String) {
        self.revision = revision
        self.summary = summary
    }
}

public struct ToolProposedEvent: Codable, Equatable, Sendable {
    public let invocation: ToolInvocation
    public init(invocation: ToolInvocation) { self.invocation = invocation }
}

public struct ApprovalRequestedEvent: Codable, Equatable, Sendable {
    public let request: ApprovalRequest
    public init(request: ApprovalRequest) { self.request = request }
}

public struct ApprovalResolvedEvent: Codable, Equatable, Sendable {
    public let resolution: ApprovalResolution
    public init(resolution: ApprovalResolution) { self.resolution = resolution }
}

public struct ToolScheduledEvent: Codable, Equatable, Sendable {
    public let callID: ToolCallID
    public let effect: ToolEffectKeyReference?

    public init(callID: ToolCallID, effect: ToolEffectKeyReference? = nil) {
        self.callID = callID
        self.effect = effect
    }
}

public struct ToolStartedEvent: Codable, Equatable, Sendable {
    public let callID: ToolCallID
    public let effect: ToolEffectKeyReference?

    public init(callID: ToolCallID, effect: ToolEffectKeyReference? = nil) {
        self.callID = callID
        self.effect = effect
    }
}

public struct ToolAppliedEvent: Codable, Equatable, Sendable {
    public let callID: ToolCallID
    public let effect: ToolEffectReceiptReference?
    public let evidence: [ToolEvidence]

    public init(
        callID: ToolCallID,
        effect: ToolEffectReceiptReference? = nil,
        evidence: [ToolEvidence]
    ) {
        self.callID = callID
        self.effect = effect
        self.evidence = evidence
    }
}

public struct ToolCompletedEvent: Codable, Equatable, Sendable {
    public let result: ToolResult
    public let effect: ToolEffectReceiptReference?

    public init(result: ToolResult, effect: ToolEffectReceiptReference? = nil) {
        self.result = result
        self.effect = effect
    }
}

public struct ArtifactCapturedEvent: Codable, Equatable, Sendable {
    public let artifact: ArtifactReference
    public init(artifact: ArtifactReference) { self.artifact = artifact }
}

public struct CheckpointCreatedEvent: Codable, Equatable, Sendable {
    public let checkpoint: ContextCheckpointReference
    public init(checkpoint: ContextCheckpointReference) { self.checkpoint = checkpoint }
}

public struct RetryScheduledEvent: Codable, Equatable, Sendable {
    public let failedAttemptID: AttemptID
    public let nextAttemptID: AttemptID
    public let reason: String

    public init(failedAttemptID: AttemptID, nextAttemptID: AttemptID, reason: String) {
        self.failedAttemptID = failedAttemptID
        self.nextAttemptID = nextAttemptID
        self.reason = reason
    }
}

public struct CancellationRequestedEvent: Codable, Equatable, Sendable {
    public let reason: AgentCancellationReason
    public let propagateToDescendants: Bool

    public init(reason: AgentCancellationReason, propagateToDescendants: Bool) {
        self.reason = reason
        self.propagateToDescendants = propagateToDescendants
    }
}

public struct RunCompletedEvent: Codable, Equatable, Sendable {
    public let summary: String?
    public init(summary: String? = nil) { self.summary = summary }
}

public struct RunFailedEvent: Codable, Equatable, Sendable {
    public let error: AgentErrorInfo
    public init(error: AgentErrorInfo) { self.error = error }
}

public struct RunCancelledEvent: Codable, Equatable, Sendable {
    public let reason: AgentCancellationReason
    public init(reason: AgentCancellationReason) { self.reason = reason }
}

public struct RunInterruptedEvent: Codable, Equatable, Sendable {
    public let error: AgentErrorInfo
    public let safeToResume: Bool

    public init(error: AgentErrorInfo, safeToResume: Bool) {
        self.error = error
        self.safeToResume = safeToResume
    }
}

public enum AgentEventPayload: Codable, Equatable, Sendable {
    case runAccepted(RunAcceptedEvent)
    case runQueued(RunQueuedEvent)
    case runStarted(RunStartedEvent)
    case contextPrepared(ContextPreparedEvent)
    case contextCompressed(ContextCompressedEvent)
    case modelRequestStarted(ModelRequestStartedEvent)
    case modelResponseCommitted(ModelResponseCommittedEvent)
    case modelRequestFailed(ModelRequestFailedEvent)
    case providerRouteChanged(ProviderRouteChangedEvent)
    case planUpdated(PlanUpdatedEvent)
    case toolProposed(ToolProposedEvent)
    case approvalRequested(ApprovalRequestedEvent)
    case approvalResolved(ApprovalResolvedEvent)
    case toolScheduled(ToolScheduledEvent)
    case toolStarted(ToolStartedEvent)
    case toolApplied(ToolAppliedEvent)
    case toolCompleted(ToolCompletedEvent)
    case artifactCaptured(ArtifactCapturedEvent)
    case checkpointCreated(CheckpointCreatedEvent)
    case retryScheduled(RetryScheduledEvent)
    case cancellationRequested(CancellationRequestedEvent)
    case runCompleted(RunCompletedEvent)
    case runFailed(RunFailedEvent)
    case runCancelled(RunCancelledEvent)
    case runInterrupted(RunInterruptedEvent)

    fileprivate enum CodingKeys: String, CodingKey { case kind, body }
    fileprivate enum Kind: String, Codable {
        case runAccepted, runQueued, runStarted
        case contextPrepared, contextCompressed
        case modelRequestStarted, modelResponseCommitted, modelRequestFailed, providerRouteChanged
        case planUpdated, toolProposed, approvalRequested, approvalResolved
        case toolScheduled, toolStarted, toolApplied, toolCompleted
        case artifactCaptured, checkpointCreated, retryScheduled, cancellationRequested
        case runCompleted, runFailed, runCancelled, runInterrupted
    }

    public var kind: AgentEventKind {
        switch self {
        case .runAccepted: .runAccepted
        case .runQueued: .runQueued
        case .runStarted: .runStarted
        case .contextPrepared: .contextPrepared
        case .contextCompressed: .contextCompressed
        case .modelRequestStarted: .modelRequestStarted
        case .modelResponseCommitted: .modelResponseCommitted
        case .modelRequestFailed: .modelRequestFailed
        case .providerRouteChanged: .providerRouteChanged
        case .planUpdated: .planUpdated
        case .toolProposed: .toolProposed
        case .approvalRequested: .approvalRequested
        case .approvalResolved: .approvalResolved
        case .toolScheduled: .toolScheduled
        case .toolStarted: .toolStarted
        case .toolApplied: .toolApplied
        case .toolCompleted: .toolCompleted
        case .artifactCaptured: .artifactCaptured
        case .checkpointCreated: .checkpointCreated
        case .retryScheduled: .retryScheduled
        case .cancellationRequested: .cancellationRequested
        case .runCompleted: .runCompleted
        case .runFailed: .runFailed
        case .runCancelled: .runCancelled
        case .runInterrupted: .runInterrupted
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .runAccepted: self = .runAccepted(try container.decode(RunAcceptedEvent.self, forKey: .body))
        case .runQueued: self = .runQueued(try container.decode(RunQueuedEvent.self, forKey: .body))
        case .runStarted: self = .runStarted(try container.decode(RunStartedEvent.self, forKey: .body))
        case .contextPrepared: self = .contextPrepared(try container.decode(ContextPreparedEvent.self, forKey: .body))
        case .contextCompressed: self = .contextCompressed(try container.decode(ContextCompressedEvent.self, forKey: .body))
        case .modelRequestStarted: self = .modelRequestStarted(try container.decode(ModelRequestStartedEvent.self, forKey: .body))
        case .modelResponseCommitted: self = .modelResponseCommitted(try container.decode(ModelResponseCommittedEvent.self, forKey: .body))
        case .modelRequestFailed: self = .modelRequestFailed(try container.decode(ModelRequestFailedEvent.self, forKey: .body))
        case .providerRouteChanged: self = .providerRouteChanged(try container.decode(ProviderRouteChangedEvent.self, forKey: .body))
        case .planUpdated: self = .planUpdated(try container.decode(PlanUpdatedEvent.self, forKey: .body))
        case .toolProposed: self = .toolProposed(try container.decode(ToolProposedEvent.self, forKey: .body))
        case .approvalRequested: self = .approvalRequested(try container.decode(ApprovalRequestedEvent.self, forKey: .body))
        case .approvalResolved: self = .approvalResolved(try container.decode(ApprovalResolvedEvent.self, forKey: .body))
        case .toolScheduled: self = .toolScheduled(try container.decode(ToolScheduledEvent.self, forKey: .body))
        case .toolStarted: self = .toolStarted(try container.decode(ToolStartedEvent.self, forKey: .body))
        case .toolApplied: self = .toolApplied(try container.decode(ToolAppliedEvent.self, forKey: .body))
        case .toolCompleted: self = .toolCompleted(try container.decode(ToolCompletedEvent.self, forKey: .body))
        case .artifactCaptured: self = .artifactCaptured(try container.decode(ArtifactCapturedEvent.self, forKey: .body))
        case .checkpointCreated: self = .checkpointCreated(try container.decode(CheckpointCreatedEvent.self, forKey: .body))
        case .retryScheduled: self = .retryScheduled(try container.decode(RetryScheduledEvent.self, forKey: .body))
        case .cancellationRequested: self = .cancellationRequested(try container.decode(CancellationRequestedEvent.self, forKey: .body))
        case .runCompleted: self = .runCompleted(try container.decode(RunCompletedEvent.self, forKey: .body))
        case .runFailed: self = .runFailed(try container.decode(RunFailedEvent.self, forKey: .body))
        case .runCancelled: self = .runCancelled(try container.decode(RunCancelledEvent.self, forKey: .body))
        case .runInterrupted: self = .runInterrupted(try container.decode(RunInterruptedEvent.self, forKey: .body))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .runAccepted(value): try container.encodeTagged(Kind.runAccepted, value)
        case let .runQueued(value): try container.encodeTagged(Kind.runQueued, value)
        case let .runStarted(value): try container.encodeTagged(Kind.runStarted, value)
        case let .contextPrepared(value): try container.encodeTagged(Kind.contextPrepared, value)
        case let .contextCompressed(value): try container.encodeTagged(Kind.contextCompressed, value)
        case let .modelRequestStarted(value): try container.encodeTagged(Kind.modelRequestStarted, value)
        case let .modelResponseCommitted(value): try container.encodeTagged(Kind.modelResponseCommitted, value)
        case let .modelRequestFailed(value): try container.encodeTagged(Kind.modelRequestFailed, value)
        case let .providerRouteChanged(value): try container.encodeTagged(Kind.providerRouteChanged, value)
        case let .planUpdated(value): try container.encodeTagged(Kind.planUpdated, value)
        case let .toolProposed(value): try container.encodeTagged(Kind.toolProposed, value)
        case let .approvalRequested(value): try container.encodeTagged(Kind.approvalRequested, value)
        case let .approvalResolved(value): try container.encodeTagged(Kind.approvalResolved, value)
        case let .toolScheduled(value): try container.encodeTagged(Kind.toolScheduled, value)
        case let .toolStarted(value): try container.encodeTagged(Kind.toolStarted, value)
        case let .toolApplied(value): try container.encodeTagged(Kind.toolApplied, value)
        case let .toolCompleted(value): try container.encodeTagged(Kind.toolCompleted, value)
        case let .artifactCaptured(value): try container.encodeTagged(Kind.artifactCaptured, value)
        case let .checkpointCreated(value): try container.encodeTagged(Kind.checkpointCreated, value)
        case let .retryScheduled(value): try container.encodeTagged(Kind.retryScheduled, value)
        case let .cancellationRequested(value): try container.encodeTagged(Kind.cancellationRequested, value)
        case let .runCompleted(value): try container.encodeTagged(Kind.runCompleted, value)
        case let .runFailed(value): try container.encodeTagged(Kind.runFailed, value)
        case let .runCancelled(value): try container.encodeTagged(Kind.runCancelled, value)
        case let .runInterrupted(value): try container.encodeTagged(Kind.runInterrupted, value)
        }
    }
}

public enum AgentEventKind: String, Codable, CaseIterable, Hashable, Sendable {
    case runAccepted, runQueued, runStarted
    case contextPrepared, contextCompressed
    case modelRequestStarted, modelResponseCommitted, modelRequestFailed, providerRouteChanged
    case planUpdated, toolProposed, approvalRequested, approvalResolved
    case toolScheduled, toolStarted, toolApplied, toolCompleted
    case artifactCaptured, checkpointCreated, retryScheduled, cancellationRequested
    case runCompleted, runFailed, runCancelled, runInterrupted
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public let header: AgentEventHeader
    public let payload: AgentEventPayload

    public init(header: AgentEventHeader, payload: AgentEventPayload) {
        self.header = header
        self.payload = payload
    }
}

private extension KeyedEncodingContainer where Key == AgentEventPayload.CodingKeys {
    mutating func encodeTagged<Value: Encodable>(
        _ kind: AgentEventPayload.Kind,
        _ value: Value
    ) throws {
        try encode(kind, forKey: .kind)
        try encode(value, forKey: .body)
    }
}

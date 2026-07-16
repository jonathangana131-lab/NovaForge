import Foundation

public enum AgentRunPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case uninitialized
    case accepted
    case queued
    case running
    case awaitingApproval
    case cancelling
    case completed
    case failed
    case cancelled
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted:
            true
        default:
            false
        }
    }
}

public enum ModelAttemptStatus: String, Codable, Hashable, Sendable {
    case active
    case responseCommitted
    case failedBeforeCommit
    case failedAfterCommit
    case retryScheduled
}

public struct ModelAttemptState: Codable, Equatable, Sendable {
    public let attemptID: AttemptID
    public let route: ModelRoute
    public let providerAttempt: ProviderAttemptJournalMetadata
    public var status: ModelAttemptStatus
    public var error: AgentErrorInfo?
    public var usage: ModelUsage?
    public var finishReason: ModelFinishReason?

    public init(
        attemptID: AttemptID,
        route: ModelRoute,
        providerAttempt: ProviderAttemptJournalMetadata = .legacyV1,
        status: ModelAttemptStatus,
        error: AgentErrorInfo? = nil,
        usage: ModelUsage? = nil,
        finishReason: ModelFinishReason? = nil
    ) {
        self.attemptID = attemptID
        self.route = route
        self.providerAttempt = providerAttempt
        self.status = status
        self.error = error
        self.usage = usage
        self.finishReason = finishReason
    }

    private enum CodingKeys: String, CodingKey {
        case attemptID
        case route
        case providerAttempt
        case status
        case error
        case usage
        case finishReason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            attemptID: try container.decode(AttemptID.self, forKey: .attemptID),
            route: try container.decode(ModelRoute.self, forKey: .route),
            providerAttempt: try container.decodeIfPresent(
                ProviderAttemptJournalMetadata.self,
                forKey: .providerAttempt
            ) ?? .legacyV1,
            status: try container.decode(ModelAttemptStatus.self, forKey: .status),
            error: try container.decodeIfPresent(AgentErrorInfo.self, forKey: .error),
            usage: try container.decodeIfPresent(ModelUsage.self, forKey: .usage),
            finishReason: try container.decodeIfPresent(
                ModelFinishReason.self,
                forKey: .finishReason
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(attemptID, forKey: .attemptID)
        try container.encode(route, forKey: .route)
        if !providerAttempt.isLegacyV1 {
            try container.encode(providerAttempt, forKey: .providerAttempt)
        }
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(finishReason, forKey: .finishReason)
    }
}

public enum ToolExecutionStatus: String, Codable, Hashable, Sendable {
    case proposed
    case awaitingApproval
    case approved
    case rejected
    case scheduled
    case running
    case applied
    case completed

    public var isSettled: Bool {
        self == .rejected || self == .completed
    }
}

public struct ToolExecutionState: Codable, Equatable, Sendable {
    public let invocation: ToolInvocation
    public var status: ToolExecutionStatus
    public var result: ToolResult?
    public var applicationEvidence: [ToolEvidence]
    public var effectKey: ToolEffectKeyReference?
    public var effectReceipt: ToolEffectReceiptReference?

    public init(
        invocation: ToolInvocation,
        status: ToolExecutionStatus = .proposed,
        result: ToolResult? = nil,
        applicationEvidence: [ToolEvidence] = [],
        effectKey: ToolEffectKeyReference? = nil,
        effectReceipt: ToolEffectReceiptReference? = nil
    ) {
        self.invocation = invocation
        self.status = status
        self.result = result
        self.applicationEvidence = applicationEvidence
        self.effectKey = effectKey
        self.effectReceipt = effectReceipt
    }
}

public enum ApprovalRequestStatus: String, Codable, Hashable, Sendable {
    case pending
    case approved
    case rejected
}

public struct ApprovalRequestState: Codable, Equatable, Sendable {
    public let request: ApprovalRequest
    public var status: ApprovalRequestStatus
    public var resolution: ApprovalResolution?

    public init(
        request: ApprovalRequest,
        status: ApprovalRequestStatus = .pending,
        resolution: ApprovalResolution? = nil
    ) {
        self.request = request
        self.status = status
        self.resolution = resolution
    }
}

public struct AttemptRetryLineage: Codable, Equatable, Sendable {
    public let failedAttemptID: AttemptID
    public let nextAttemptID: AttemptID
    public let reason: String

    public init(failedAttemptID: AttemptID, nextAttemptID: AttemptID, reason: String) {
        self.failedAttemptID = failedAttemptID
        self.nextAttemptID = nextAttemptID
        self.reason = reason
    }
}

public struct CancellationRequestState: Codable, Equatable, Sendable {
    public let reason: AgentCancellationReason
    public let propagateToDescendants: Bool
    public let eventID: EventID

    public init(
        reason: AgentCancellationReason,
        propagateToDescendants: Bool,
        eventID: EventID
    ) {
        self.reason = reason
        self.propagateToDescendants = propagateToDescendants
        self.eventID = eventID
    }
}

/// Replayable run projection. Canonical state changes should be produced by AgentReducer.
public struct AgentRunState: Codable, Equatable, Sendable {
    public var schemaVersion: AgentSchemaVersion
    public var context: AgentRunContext?
    public var phase: AgentRunPhase
    public var lastSequence: EventSequence?
    public var lastEventID: EventID?
    public var appliedEventIDs: [EventID]
    public var terminalEventID: EventID?
    public var budget: AgentBudget?
    public var modelItems: [ModelItem]
    public var modelAttempts: [ModelAttemptState]
    public var activeAttemptID: AttemptID?
    public var scheduledAttemptID: AttemptID?
    public var retryLineage: [AttemptRetryLineage]
    public var tools: [ToolExecutionState]
    public var approvals: [ApprovalRequestState]
    public var artifacts: [ArtifactReference]
    public var checkpoints: [ContextCheckpointReference]
    public var cancellation: CancellationRequestState?
    public var latestPlanRevision: UInt64?
    public var lastError: AgentErrorInfo?

    public init(
        schemaVersion: AgentSchemaVersion = .current,
        context: AgentRunContext? = nil,
        phase: AgentRunPhase = .uninitialized,
        lastSequence: EventSequence? = nil,
        lastEventID: EventID? = nil,
        appliedEventIDs: [EventID] = [],
        terminalEventID: EventID? = nil,
        budget: AgentBudget? = nil,
        modelItems: [ModelItem] = [],
        modelAttempts: [ModelAttemptState] = [],
        activeAttemptID: AttemptID? = nil,
        scheduledAttemptID: AttemptID? = nil,
        retryLineage: [AttemptRetryLineage] = [],
        tools: [ToolExecutionState] = [],
        approvals: [ApprovalRequestState] = [],
        artifacts: [ArtifactReference] = [],
        checkpoints: [ContextCheckpointReference] = [],
        cancellation: CancellationRequestState? = nil,
        latestPlanRevision: UInt64? = nil,
        lastError: AgentErrorInfo? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.context = context
        self.phase = phase
        self.lastSequence = lastSequence
        self.lastEventID = lastEventID
        self.appliedEventIDs = appliedEventIDs
        self.terminalEventID = terminalEventID
        self.budget = budget
        self.modelItems = modelItems
        self.modelAttempts = modelAttempts
        self.activeAttemptID = activeAttemptID
        self.scheduledAttemptID = scheduledAttemptID
        self.retryLineage = retryLineage
        self.tools = tools
        self.approvals = approvals
        self.artifacts = artifacts
        self.checkpoints = checkpoints
        self.cancellation = cancellation
        self.latestPlanRevision = latestPlanRevision
        self.lastError = lastError
    }

    public static let initial = AgentRunState()
}

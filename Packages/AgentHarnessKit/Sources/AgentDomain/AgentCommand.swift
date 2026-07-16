import Foundation

public struct AgentCommandHeader: Codable, Equatable, Sendable {
    public let commandID: CommandID
    public let schemaVersion: AgentSchemaVersion
    public let runID: RunID
    public let issuedAt: AgentInstant
    public let correlationID: CorrelationID
    public let causationID: CausationID?

    public init(
        commandID: CommandID,
        schemaVersion: AgentSchemaVersion = .current,
        runID: RunID,
        issuedAt: AgentInstant,
        correlationID: CorrelationID,
        causationID: CausationID? = nil
    ) {
        self.commandID = commandID
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.issuedAt = issuedAt
        self.correlationID = correlationID
        self.causationID = causationID
    }
}

public struct SendCommand: Codable, Equatable, Sendable {
    public let context: AgentRunContext
    public let userItem: ModelItem

    public init(context: AgentRunContext, userItem: ModelItem) {
        self.context = context
        self.userItem = userItem
    }
}

public struct ApprovalDecisionCommand: Codable, Equatable, Sendable {
    public let requestID: ApprovalRequestID
    public let callID: ToolCallID
    public let decision: ApprovalDecision
    public let decidedAt: AgentInstant
    public let rationale: String?

    public init(
        requestID: ApprovalRequestID,
        callID: ToolCallID,
        decision: ApprovalDecision,
        decidedAt: AgentInstant,
        rationale: String? = nil
    ) {
        self.requestID = requestID
        self.callID = callID
        self.decision = decision
        self.decidedAt = decidedAt
        self.rationale = rationale
    }
}

public enum AgentCancellationReason: String, Codable, Hashable, Sendable {
    case userRequested
    case parentCancelled
    case budgetExhausted
    case superseded
    case shutdown
    case policy
}

public struct CancelCommand: Codable, Equatable, Sendable {
    public let reason: AgentCancellationReason
    public let propagateToDescendants: Bool

    public init(reason: AgentCancellationReason, propagateToDescendants: Bool = true) {
        self.reason = reason
        self.propagateToDescendants = propagateToDescendants
    }
}

public struct RetryCommand: Codable, Equatable, Sendable {
    public let replacementRunID: RunID
    public let retryOfRunID: RunID
    public let reason: String

    public init(replacementRunID: RunID, retryOfRunID: RunID, reason: String) {
        self.replacementRunID = replacementRunID
        self.retryOfRunID = retryOfRunID
        self.reason = reason
    }
}

public struct RedirectCommand: Codable, Equatable, Sendable {
    public let executionNodeID: ExecutionNodeID
    public let reason: String

    public init(executionNodeID: ExecutionNodeID, reason: String) {
        self.executionNodeID = executionNodeID
        self.reason = reason
    }
}

public struct ContinueCommand: Codable, Equatable, Sendable {
    public let checkpointID: ContextCheckpointID?
    public let reason: String

    public init(checkpointID: ContextCheckpointID? = nil, reason: String) {
        self.checkpointID = checkpointID
        self.reason = reason
    }
}

public enum AgentCommandPayload: Codable, Equatable, Sendable {
    case send(SendCommand)
    case approvalDecision(ApprovalDecisionCommand)
    case cancel(CancelCommand)
    case retry(RetryCommand)
    case redirect(RedirectCommand)
    case continueRun(ContinueCommand)

    private enum CodingKeys: String, CodingKey { case kind, body }
    private enum Kind: String, Codable {
        case send
        case approvalDecision
        case cancel
        case retry
        case redirect
        case continueRun
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .send:
            self = .send(try container.decode(SendCommand.self, forKey: .body))
        case .approvalDecision:
            self = .approvalDecision(try container.decode(ApprovalDecisionCommand.self, forKey: .body))
        case .cancel:
            self = .cancel(try container.decode(CancelCommand.self, forKey: .body))
        case .retry:
            self = .retry(try container.decode(RetryCommand.self, forKey: .body))
        case .redirect:
            self = .redirect(try container.decode(RedirectCommand.self, forKey: .body))
        case .continueRun:
            self = .continueRun(try container.decode(ContinueCommand.self, forKey: .body))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .send(value):
            try container.encode(Kind.send, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .approvalDecision(value):
            try container.encode(Kind.approvalDecision, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .cancel(value):
            try container.encode(Kind.cancel, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .retry(value):
            try container.encode(Kind.retry, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .redirect(value):
            try container.encode(Kind.redirect, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .continueRun(value):
            try container.encode(Kind.continueRun, forKey: .kind)
            try container.encode(value, forKey: .body)
        }
    }
}

public struct AgentCommand: Codable, Equatable, Sendable {
    public let header: AgentCommandHeader
    public let payload: AgentCommandPayload

    public init(header: AgentCommandHeader, payload: AgentCommandPayload) {
        self.header = header
        self.payload = payload
    }
}

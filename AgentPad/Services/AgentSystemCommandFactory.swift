import AgentDomain
import Foundation

enum AgentSystemCommandFactoryError: Error, Equatable, Sendable {
    case emptyPrompt
    case promptTooLarge(actualBytes: Int, maximumBytes: Int)
    case promptContainsNull
    case identityCollision
    case invalidLineage
}

struct AgentFreshSendCommandIdentity: Equatable, Sendable {
    let commandID: CommandID
    let runID: RunID
    let userItemID: ModelItemID
    let correlationID: CorrelationID
    let cancellationScopeID: CancellationScopeID

    init(
        commandID: CommandID,
        runID: RunID,
        userItemID: ModelItemID,
        correlationID: CorrelationID,
        cancellationScopeID: CancellationScopeID
    ) {
        self.commandID = commandID
        self.runID = runID
        self.userItemID = userItemID
        self.correlationID = correlationID
        self.cancellationScopeID = cancellationScopeID
    }

    static func fresh() -> Self {
        Self(
            commandID: CommandID(rawValue: UUID()),
            runID: RunID(rawValue: UUID()),
            userItemID: ModelItemID(rawValue: UUID()),
            correlationID: CorrelationID(rawValue: UUID()),
            cancellationScopeID: CancellationScopeID(rawValue: UUID())
        )
    }
}

struct AgentFreshSendCommandRequest: Equatable, Sendable {
    let identity: AgentFreshSendCommandIdentity
    let lineage: AgentRunLineage
    let conversationID: ConversationID
    let projectID: ProjectID?
    let workspaceID: WorkspaceID
    let executionNodeID: ExecutionNodeID
    let prompt: String
    let acceptedAt: AgentInstant
    let features: AgentFeatureSet
    let budget: AgentBudget

    init(
        identity: AgentFreshSendCommandIdentity,
        conversationID: ConversationID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        executionNodeID: ExecutionNodeID,
        prompt: String,
        acceptedAt: AgentInstant,
        features: AgentFeatureSet,
        budget: AgentBudget,
        lineage: AgentRunLineage? = nil
    ) {
        self.identity = identity
        self.lineage = lineage ?? .root(identity.runID)
        self.conversationID = conversationID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.executionNodeID = executionNodeID
        self.prompt = prompt
        self.acceptedAt = acceptedAt
        self.features = features
        self.budget = budget
    }
}

enum AgentSystemCommandFactory {
    static let maximumPromptBytes = 1_048_576

    static func send(
        _ request: AgentFreshSendCommandRequest
    ) throws -> AgentCommand {
        let promptBytes = request.prompt.utf8.count
        guard !request.prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw AgentSystemCommandFactoryError.emptyPrompt
        }
        guard promptBytes <= maximumPromptBytes else {
            throw AgentSystemCommandFactoryError.promptTooLarge(
                actualBytes: promptBytes,
                maximumBytes: maximumPromptBytes
            )
        }
        guard !request.prompt.utf8.contains(0) else {
            throw AgentSystemCommandFactoryError.promptContainsNull
        }
        let rawIdentities: Set<UUID> = [
            request.identity.commandID.rawValue,
            request.identity.runID.rawValue,
            request.identity.userItemID.rawValue,
            request.identity.correlationID.rawValue,
            request.identity.cancellationScopeID.rawValue,
        ]
        guard rawIdentities.count == 5 else {
            throw AgentSystemCommandFactoryError.identityCollision
        }

        let lineage = request.lineage
        guard lineage.runID == request.identity.runID,
              lineage.validationError == nil else {
            throw AgentSystemCommandFactoryError.invalidLineage
        }
        let context = AgentRunContext(
            lineage: lineage,
            conversationID: request.conversationID,
            projectID: request.projectID,
            workspaceID: request.workspaceID,
            executionNodeID: request.executionNodeID,
            engineVersion: .agentHarnessV2,
            acceptedAt: request.acceptedAt,
            features: request.features,
            cancellation: CancellationLineage(
                scopeID: request.identity.cancellationScopeID
            ),
            initialBudget: request.budget
        )
        let userItem = ModelItem(
            id: request.identity.userItemID,
            createdAt: request.acceptedAt,
            payload: .message(ModelMessage(
                role: .user,
                content: [.text(request.prompt)]
            ))
        )
        return AgentCommand(
            header: AgentCommandHeader(
                commandID: request.identity.commandID,
                runID: request.identity.runID,
                issuedAt: request.acceptedAt,
                correlationID: request.identity.correlationID
            ),
            payload: .send(SendCommand(
                context: context,
                userItem: userItem
            ))
        )
    }

    static func cancel(
        commandID: CommandID,
        runID: RunID,
        issuedAt: AgentInstant,
        correlationID: CorrelationID,
        causationID: CausationID? = nil,
        reason: AgentCancellationReason = .userRequested
    ) -> AgentCommand {
        AgentCommand(
            header: AgentCommandHeader(
                commandID: commandID,
                runID: runID,
                issuedAt: issuedAt,
                correlationID: correlationID,
                causationID: causationID
            ),
            payload: .cancel(CancelCommand(
                reason: reason,
                propagateToDescendants: true
            ))
        )
    }

    static func approvalDecision(
        commandID: CommandID,
        runID: RunID,
        correlationID: CorrelationID,
        causationID: CausationID?,
        requestID: ApprovalRequestID,
        callID: ToolCallID,
        decision: ApprovalDecision,
        decidedAt: AgentInstant,
        rationale: String? = nil
    ) -> AgentCommand {
        AgentCommand(
            header: AgentCommandHeader(
                commandID: commandID,
                runID: runID,
                issuedAt: decidedAt,
                correlationID: correlationID,
                causationID: causationID
            ),
            payload: .approvalDecision(ApprovalDecisionCommand(
                requestID: requestID,
                callID: callID,
                decision: decision,
                decidedAt: decidedAt,
                rationale: rationale
            ))
        )
    }
}

import AgentDomain
import AgentPolicy
import CryptoKit
import Foundation

enum AgentPolicyMutationRuntimeError: Error, Equatable, Sendable {
    case coordinatorUnavailable
}

/// Process-wide app composition for the M6 mutation boundary.
///
/// Every product surface receives the same approval broker, coordinator, and
/// stable execution-node identity. Initialization fails closed: if protected
/// policy composition cannot be created, callers receive an error before any
/// workspace effect can begin.
@MainActor
final class AgentPolicyMutationRuntime {
    static let shared = AgentPolicyMutationRuntime()

    let approvalPromptCenter: AgentApprovalPromptCenter
    let executionNodeID: ExecutionNodeID

    private let policyCoordinator: AgentPolicyMutationCoordinator?

    private init() {
        let promptCenter = AgentApprovalPromptCenter.shared
        approvalPromptCenter = promptCenter
        executionNodeID = Self.persistedExecutionNodeID()
        policyCoordinator = try? AgentPolicyMutationCoordinator(
            approvalPrompt: promptCenter
        )
    }

    /// Deterministic composition seam for focused tests. The supplied actor is
    /// still the sole mutation owner; this initializer cannot replace its
    /// fixed-origin APIs or inject an effect closure.
    init(
        approvalPromptCenter: AgentApprovalPromptCenter,
        policyCoordinator: AgentPolicyMutationCoordinator,
        executionNodeID: ExecutionNodeID
    ) {
        self.approvalPromptCenter = approvalPromptCenter
        self.policyCoordinator = policyCoordinator
        self.executionNodeID = executionNodeID
    }

    func coordinator() throws -> AgentPolicyMutationCoordinator {
        guard let policyCoordinator else {
            throw AgentPolicyMutationRuntimeError.coordinatorUnavailable
        }
        return policyCoordinator
    }

    /// Builds the typed run/call/attempt lineage shared by non-provider app
    /// writers. A missing chat scope receives a domain-separated synthetic
    /// conversation identity for this operation; it never aliases the run,
    /// tool call, attempt, cancellation, or raw operation UUID domains.
    func makeExecutionContext(
        workspace: SandboxWorkspace,
        operationID: UUID,
        idempotencyKey: String,
        runID: UUID? = nil,
        callID: UUID? = nil,
        operationAttemptID: UUID? = nil,
        conversationID: UUID? = nil,
        projectID: UUID? = nil,
        acceptedAt: Date = Date(),
        sessionID: String? = nil
    ) throws -> AgentPolicyMutationExecutionContext {
        try AgentPolicyMutationExecutionContext(
            workspace: workspace,
            operationID: operationID,
            idempotencyKey: idempotencyKey,
            lineage: runID.map { .root(RunID(rawValue: $0)) },
            callID: callID.map(ToolCallID.init(rawValue:)),
            operationAttemptID: operationAttemptID.map(
                AttemptID.init(rawValue:)
            ),
            conversationID: ConversationID(rawValue:
                conversationID ?? Self.derivedUUID(
                    from: operationID,
                    domain: "conversation"
                )
            ),
            projectID: projectID.map(ProjectID.init(rawValue:)),
            executionNodeID: executionNodeID,
            acceptedAt: AgentInstant(acceptedAt),
            sessionID: sessionID,
            backend: .onDevice
        )
    }

    private static let executionNodeStorageKey =
        "novaforge.agent-policy.execution-node-id.v1"

    private static func persistedExecutionNodeID(
        defaults: UserDefaults = .standard
    ) -> ExecutionNodeID {
        if let rawValue = defaults.string(forKey: executionNodeStorageKey),
           let uuid = UUID(uuidString: rawValue)
        {
            return ExecutionNodeID(rawValue: uuid)
        }

        let uuid = UUID()
        defaults.set(uuid.uuidString.lowercased(), forKey: executionNodeStorageKey)
        return ExecutionNodeID(rawValue: uuid)
    }

    private static func derivedUUID(from operationID: UUID, domain: String)
        -> UUID
    {
        let material = [
            "novaforge-policy-operation-identity-v1",
            domain,
            operationID.uuidString.lowercased(),
        ].joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(material.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

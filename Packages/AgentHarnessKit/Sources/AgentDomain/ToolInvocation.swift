import Foundation

public struct ToolIdentity: Codable, Hashable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public enum ToolEffectClass: String, Codable, CaseIterable, Hashable, Sendable {
    case readOnlyLocal
    case scopedReversibleWrite
    case broadOrDestructiveWrite
    case externalSideEffect
    case credentialBearingOrPrivileged
    case unrecoverableDenied
}

public enum ToolExecutionLocality: String, Codable, CaseIterable, Hashable, Sendable {
    case onDevice
    case worker
    case either
}

public struct ToolInvocation: Codable, Equatable, Sendable {
    public let callID: ToolCallID
    /// Provider-owned call identity needed to reconstruct the exact
    /// assistant-call/tool-result envelope on a later model round. Historical
    /// events omit this field and decode it as `nil`.
    public let providerCallID: String?
    public let modelAttemptID: AttemptID
    public let tool: ToolIdentity
    public let arguments: JSONValue
    public let canonicalArgumentDigest: String
    public let idempotencyKey: String
    public let effectClass: ToolEffectClass
    public let locality: ToolExecutionLocality

    public init(
        callID: ToolCallID,
        providerCallID: String? = nil,
        modelAttemptID: AttemptID,
        tool: ToolIdentity,
        arguments: JSONValue,
        canonicalArgumentDigest: String,
        idempotencyKey: String,
        effectClass: ToolEffectClass,
        locality: ToolExecutionLocality
    ) {
        self.callID = callID
        self.providerCallID = providerCallID
        self.modelAttemptID = modelAttemptID
        self.tool = tool
        self.arguments = arguments
        self.canonicalArgumentDigest = canonicalArgumentDigest
        self.idempotencyKey = idempotencyKey
        self.effectClass = effectClass
        self.locality = locality
    }

    public var hasCanonicalProviderCallID: Bool {
        guard let providerCallID,
              !providerCallID.isEmpty,
              providerCallID.utf8.count <= 512,
              providerCallID == providerCallID.trimmingCharacters(
                  in: .whitespacesAndNewlines
              )
        else { return false }
        return providerCallID.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

public struct ApprovalBinding: Codable, Equatable, Sendable {
    public let runID: RunID
    public let callID: ToolCallID
    public let tool: ToolIdentity
    public let canonicalArgumentDigest: String
    public let workspaceID: WorkspaceID
    public let previewDigest: String
    public let workspaceRevision: String

    public init(
        runID: RunID,
        callID: ToolCallID,
        tool: ToolIdentity,
        canonicalArgumentDigest: String,
        workspaceID: WorkspaceID,
        previewDigest: String,
        workspaceRevision: String
    ) {
        self.runID = runID
        self.callID = callID
        self.tool = tool
        self.canonicalArgumentDigest = canonicalArgumentDigest
        self.workspaceID = workspaceID
        self.previewDigest = previewDigest
        self.workspaceRevision = workspaceRevision
    }
}

public struct ApprovalRequest: Codable, Equatable, Sendable {
    public let requestID: ApprovalRequestID
    public let binding: ApprovalBinding
    public let summary: String
    public let requestedAt: AgentInstant
    public let expiresAt: AgentInstant?

    public init(
        requestID: ApprovalRequestID,
        binding: ApprovalBinding,
        summary: String,
        requestedAt: AgentInstant,
        expiresAt: AgentInstant? = nil
    ) {
        self.requestID = requestID
        self.binding = binding
        self.summary = summary
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }
}

public enum ApprovalDecision: String, Codable, Hashable, Sendable {
    case approved
    case rejected
}

public struct ApprovalResolution: Codable, Equatable, Sendable {
    public let requestID: ApprovalRequestID
    public let callID: ToolCallID
    public let decision: ApprovalDecision
    public let resolvedAt: AgentInstant
    public let rationale: String?

    public init(
        requestID: ApprovalRequestID,
        callID: ToolCallID,
        decision: ApprovalDecision,
        resolvedAt: AgentInstant,
        rationale: String? = nil
    ) {
        self.requestID = requestID
        self.callID = callID
        self.decision = decision
        self.resolvedAt = resolvedAt
        self.rationale = rationale
    }
}

public struct ArtifactReference: Codable, Equatable, Sendable {
    public let artifactID: ArtifactID
    public let mediaType: String
    public let contentDigest: String
    public let displayName: String

    public init(
        artifactID: ArtifactID,
        mediaType: String,
        contentDigest: String,
        displayName: String
    ) {
        self.artifactID = artifactID
        self.mediaType = mediaType
        self.contentDigest = contentDigest
        self.displayName = displayName
    }
}

public struct ToolEvidence: Codable, Equatable, Sendable {
    public let kind: String
    public let digest: String
    public let metadata: JSONValue

    public init(kind: String, digest: String, metadata: JSONValue = .object([:])) {
        self.kind = kind
        self.digest = digest
        self.metadata = metadata
    }
}

public enum AgentErrorCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case cancelled
    case timeout
    case authentication
    case authorization
    case invalidInput
    case unavailable
    case rateLimited
    case contextLimit
    case transport
    case provider
    case tool
    case persistence
    case invariantViolation
    case unknown
}

/// Sanitized error metadata. Raw provider responses, paths, and credentials do not belong here.
public struct AgentErrorInfo: Codable, Equatable, Sendable {
    public let category: AgentErrorCategory
    public let code: String
    public let publicMessage: String
    public let retryable: Bool

    public init(
        category: AgentErrorCategory,
        code: String,
        publicMessage: String,
        retryable: Bool
    ) {
        self.category = category
        self.code = code
        self.publicMessage = publicMessage
        self.retryable = retryable
    }
}

public enum ToolResultStatus: String, Codable, Hashable, Sendable {
    case succeeded
    case failed
    case cancelled
}

public struct ToolResult: Codable, Equatable, Sendable {
    /// Stable item ID supplied by the event writer; reducers never generate IDs.
    public let modelItemID: ModelItemID
    public let callID: ToolCallID
    public let status: ToolResultStatus
    public let output: JSONValue
    public let artifacts: [ArtifactReference]
    public let evidence: [ToolEvidence]
    public let warnings: [String]
    public let error: AgentErrorInfo?

    public init(
        modelItemID: ModelItemID,
        callID: ToolCallID,
        status: ToolResultStatus,
        output: JSONValue,
        artifacts: [ArtifactReference] = [],
        evidence: [ToolEvidence] = [],
        warnings: [String] = [],
        error: AgentErrorInfo? = nil
    ) {
        self.modelItemID = modelItemID
        self.callID = callID
        self.status = status
        self.output = output
        self.artifacts = artifacts
        self.evidence = evidence
        self.warnings = warnings
        self.error = error
    }

    /// Exact provider-visible result used when a human rejects an approval.
    /// It settles the tool envelope without claiming that any effect occurred.
    public static func approvalRejected(
        modelItemID: ModelItemID,
        callID: ToolCallID
    ) -> Self {
        Self(
            modelItemID: modelItemID,
            callID: callID,
            status: .failed,
            output: .object(["status": .string("approval_rejected")]),
            artifacts: [],
            evidence: [],
            warnings: [],
            error: AgentErrorInfo(
                category: .authorization,
                code: "approval_rejected",
                publicMessage: "The tool request was not approved.",
                retryable: false
            )
        )
    }

    public var isCanonicalApprovalRejection: Bool {
        self == Self.approvalRejected(
            modelItemID: modelItemID,
            callID: callID
        )
    }
}

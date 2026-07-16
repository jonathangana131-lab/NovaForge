import AgentDomain
import AgentPolicy
import AgentTools
import struct CryptoKit.SHA256
import Foundation

extension WorkspaceResourceIdentity {
    /// Side-effect-free scalar identity for a canonical workspace location,
    /// including a root that does not exist yet and will be created only by a
    /// permitted seed operation. This mirrors the existing SHA-256/UUIDv8
    /// representation without resolving or creating the leaf on disk.
    init(agentPolicyCanonicalRootURL rootURL: URL) throws {
        guard rootURL.isFileURL,
              rootURL.path.hasPrefix("/"),
              rootURL.standardizedFileURL.path != "/"
        else { throw AgentPolicySystemError.invalidWorkspaceComposition }

        let canonicalRoot = rootURL.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
        let digest = Array(SHA256.hash(
            data: Data(canonicalRoot.utf8)
        ))
        let digestHex = digest.map {
            String(format: "%02x", $0)
        }.joined()
        resourceKey = "workspace:sha256:\(digestHex)"

        var uuidBytes = Array(digest.prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x80
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80
        persistentID = UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }
}

/// Frozen identity for one concrete sandbox root. The policy WorkspaceID is
/// always derived from the existing canonical WorkspaceResourceIdentity; a
/// caller cannot pair an arbitrary WorkspaceID with a different root.
struct AgentPolicyWorkspaceBinding: Equatable, Sendable {
    let workspace: SandboxWorkspace
    let resourceIdentity: WorkspaceResourceIdentity
    let workspaceID: WorkspaceID

    init(workspace: SandboxWorkspace) throws {
        let canonicalRootURL = workspace.rootURL.standardizedFileURL
        let location = try AgentWorkspaceRootLocation(
            rootURL: canonicalRootURL
        )
        // A seed permit can create the workspace root, but the fd-anchored
        // resolver and applier deliberately open its parent container before
        // they evaluate that permit. On a true first launch, Documents exists
        // while Documents/Workspaces does not. Prepare only that infrastructure
        // container here; the workspace root and every user-visible file still
        // remain owned by the typed, journaled seed operation.
        try Self.prepareWorkspaceContainer(at: location.containerURL)
        let identity = try WorkspaceResourceIdentity(
            agentPolicyCanonicalRootURL: location.rootURL
        )
        self.workspace = workspace
        resourceIdentity = identity
        workspaceID = WorkspaceID(rawValue: identity.persistentID)
    }

    private static func prepareWorkspaceContainer(
        at containerURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let parentURL = containerURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: parentURL.path,
            isDirectory: &parentIsDirectory
        ), parentIsDirectory.boolValue else {
            throw AgentPolicySystemError.invalidWorkspaceComposition
        }

        func verifyContainer() throws {
            let values = try containerURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            // macOS exposes /tmp as the fixed system alias to /private/tmp.
            // Unit-test workspaces intentionally use that spelling; accepting
            // this one OS-owned alias preserves canonical-root cache tests
            // without allowing an arbitrary workspace container symlink.
            var temporaryTargetIsDirectory: ObjCBool = false
            let isSystemTemporaryAlias =
                containerURL.standardizedFileURL.path == "/tmp" &&
                fileManager.fileExists(
                    atPath: "/private/tmp",
                    isDirectory: &temporaryTargetIsDirectory
                ) && temporaryTargetIsDirectory.boolValue
            let isDirectDirectory = values.isDirectory == true &&
                values.isSymbolicLink != true
            guard isDirectDirectory || isSystemTemporaryAlias
            else {
                throw AgentPolicySystemError.invalidWorkspaceComposition
            }
        }

        if fileManager.fileExists(atPath: containerURL.path) {
            try verifyContainer()
            return
        }

        do {
            try fileManager.createDirectory(
                at: containerURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch let error as CocoaError
            where error.code == .fileWriteFileExists
        {
            // A concurrent coordinator may have won the same first-use race.
        }
        try verifyContainer()
    }

    static func == (
        lhs: AgentPolicyWorkspaceBinding,
        rhs: AgentPolicyWorkspaceBinding
    ) -> Bool {
        lhs.resourceIdentity == rhs.resourceIdentity
            && lhs.workspaceID == rhs.workspaceID
    }
}

/// Stable scope shared by provider and human-initiated mutation requests.
/// Mutation origin is deliberately absent: each facade entry point below binds
/// its own origin before the request reaches AgentPolicy.
struct AgentPolicyMutationScope: Sendable {
    let runContext: AgentRunContext
    let workspaceBinding: AgentPolicyWorkspaceBinding
    let sessionID: String?
    let backend: PolicyBackend

    var runID: RunID { runContext.lineage.runID }
    var projectID: ProjectID? { runContext.projectID }
    var workspaceID: WorkspaceID { workspaceBinding.workspaceID }

    init(
        runContext: AgentRunContext,
        workspaceBinding: AgentPolicyWorkspaceBinding,
        sessionID: String?,
        backend: PolicyBackend
    ) throws {
        guard runContext.lineage.validationError == nil,
              runContext.workspaceID == workspaceBinding.workspaceID
        else { throw AgentPolicyMutationServiceError.requestRejected }
        self.runContext = runContext
        self.workspaceBinding = workspaceBinding
        self.sessionID = sessionID
        self.backend = backend
    }
}

/// Identifiers required to turn one typed, non-provider operation into a
/// canonical invocation. There is no descriptor, raw argument payload, or
/// origin parameter for a surface caller to substitute.
struct AgentPolicyLocalMutationContext: Sendable {
    let scope: AgentPolicyMutationScope
    let callID: ToolCallID
    let operationAttemptID: AttemptID
    let idempotencyKey: String

    init(
        scope: AgentPolicyMutationScope,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String
    ) {
        self.scope = scope
        self.callID = callID
        self.operationAttemptID = operationAttemptID
        self.idempotencyKey = idempotencyKey
    }
}

/// Mutation output is intentionally not UI-safe. Callers must hand
/// `unclassifiedOutput` to a separate sanitizer/public-copy boundary before
/// using any summary, text, path, command output, accessibility label, or log.
struct AgentPolicyUnclassifiedMutationResult: Equatable, Sendable {
    let origin: MutationOrigin
    let effectKeySHA256: SHA256Digest
    let applicationSHA256: SHA256Digest
    let evidenceSHA256: SHA256Digest
    let finalRecordSHA256: SHA256Digest
    let receiptSHA256: SHA256Digest
    let unclassifiedOutput: MutationEffectOutput
    let unclassifiedEvidence: [MutationEffectEvidenceFact]

    fileprivate init(receipt: MutationEffectExecutionReceipt) {
        precondition(
            MutationEffectOutput.presentationClassification == .unclassified
        )
        origin = receipt.origin
        effectKeySHA256 = receipt.effectKeySHA256
        applicationSHA256 = receipt.applicationSHA256
        evidenceSHA256 = receipt.evidenceSHA256
        finalRecordSHA256 = receipt.finalRecordSHA256
        receiptSHA256 = receipt.receiptSHA256
        unclassifiedOutput = receipt.output
        unclassifiedEvidence = receipt.evidence
    }
}

enum AgentPolicyMutationServiceError: Error, Equatable, Sendable {
    case invalidComposition
    case cancelled
    case requestRejected
    case policyDenied
    case policyIndeterminate
    case approvalRejected
    case approvalFailed
    case authorizationFailed
    case claimFailed
    case effectFailed
    case recoveryFailed
    case stagedAutomaticAuthorizationUnsupported
    case stagedPreparationMismatch
    case approvalBindingMismatch
}

enum AgentPolicyMutationRecoveryDisposition: Equatable, Sendable {
    case evidenceSettled(AgentPolicyUnclassifiedMutationResult)
    case alreadySettled(AgentPolicyUnclassifiedMutationResult)
    case reconciliationRequired(SHA256Digest)
    case noDurableRecord
}

/// Opaque app-side staging authority for one canonical Agent V2 mutation.
///
/// It intentionally carries no executable permit. Approval and claim permits
/// are reminted only from the configured durable M6 authorities immediately
/// before apply. A host may retain this value only for the lifetime of one
/// engine process; restart identity lives in the separate durable preparation
/// record owned by the M7 adapter.
struct AgentPolicyStagedAgentV2Mutation: Sendable {
    enum Authorization: Sendable {
        case durableApproval(
            durableRequest: DurableApprovalRequest,
            domainRequest: ApprovalRequest
        )
        case reevaluablePolicy
    }

    let request: RiskPolicyRequest
    let policySHA256: SHA256Digest
    let effectKeySHA256: SHA256Digest
    let authorization: Authorization

    var approvalRequest: ApprovalRequest? {
        guard case let .durableApproval(_, request) = authorization else {
            return nil
        }
        return request
    }
}

/// Reproduces AgentPolicy's public, versioned tool-effect-key contract from a
/// resolved request. The actual package-minted permit is compared with this
/// projection before any claim or effect can cross the gateway.
private enum AgentPolicyToolEffectKeyProjection {
    private struct Material: Codable {
        let origin: MutationOrigin
        let requestSHA256: SHA256Digest
        let policySHA256: SHA256Digest
        let tool: ToolIdentity
        let effectClass: ToolEffectClass
        let canonicalArgumentDigest: String
        let operationPayloadSHA256: SHA256Digest
        let operationPreviewSHA256: SHA256Digest?
        let callID: ToolCallID
        let idempotencyKey: String
        let workspaceID: WorkspaceID
        let resolutionAttestationSHA256: SHA256Digest
    }

    private struct Envelope<Value: Encodable>: Encodable {
        let scheme: String
        let domain: String
        let value: Value
    }

    static func digest(
        request: RiskPolicyRequest,
        policySHA256: SHA256Digest
    ) throws -> SHA256Digest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Envelope(
            scheme: "novaforge-policy-canonical-json-v1",
            domain: "tool-effect-key-v1",
            value: Material(
                origin: request.origin,
                requestSHA256: request.requestSHA256,
                policySHA256: policySHA256,
                tool: request.invocation.tool,
                effectClass: request.invocation.effectClass,
                canonicalArgumentDigest:
                    request.invocation.canonicalArgumentDigest,
                operationPayloadSHA256: request.argumentSHA256,
                operationPreviewSHA256: request.operationPreviewSHA256,
                callID: request.invocation.callID,
                idempotencyKey: request.invocation.idempotencyKey,
                workspaceID: request.workspaceID,
                resolutionAttestationSHA256:
                    request.targetAttestationSHA256
            )
        ))
        let hexadecimal = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        return try SHA256Digest("sha256:" + hexadecimal)
    }
}

/// One reference-owned package gateway is shared by normal execution and
/// recovery. Recovery can only inspect/settle the existing lifecycle ledger;
/// it cannot accept an effect closure or mint a replacement permit.
final class AgentPolicyMutationGatewayAuthority: Sendable {
    private let gateway: MutationEffectGateway

    init(gateway: MutationEffectGateway) {
        self.gateway = gateway
    }

    func apply(
        _ claimedPermit: consuming ClaimedToolEffectPermit
    ) async throws -> MutationEffectExecutionReceipt {
        try await gateway.apply(claimedPermit)
    }

    func recover(
        effectKeySHA256: SHA256Digest
    ) async throws -> AgentPolicyMutationRecoveryDisposition {
        let recovered: MutationEffectRecoveryDisposition
        do {
            recovered = try await gateway.recover(
                effectKeySHA256: effectKeySHA256
            )
        } catch let error as MutationEffectLifecycleError {
            if case .recordNotFound = error { return .noDurableRecord }
            throw error
        }
        switch recovered {
        case let .evidenceSettled(receipt):
            return .evidenceSettled(
                AgentPolicyUnclassifiedMutationResult(receipt: receipt)
            )
        case let .alreadySettled(receipt):
            return .alreadySettled(
                AgentPolicyUnclassifiedMutationResult(receipt: receipt)
            )
        case let .reconciliationRequired(digest):
            return .reconciliationRequired(digest)
        }
    }
}

/// Internal sum type used only after a fixed-origin public facade has selected
/// an operation family. App callers never construct a generic origin-bearing
/// request and the production pipeline never changes one case into another.
enum AgentPolicyBoundMutationRequest: Sendable {
    case agentV2(
        AgentPolicyMutationScope,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    )
    case v1Fallback(
        AgentPolicyMutationScope,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    )
    case editorCanonical(
        AgentPolicyLocalMutationContext,
        EditorCanonicalMutationOperation
    )
    case editorPolicy(
        AgentPolicyLocalMutationContext,
        EditorPolicyMutationOperation
    )
    case filesCanonical(
        AgentPolicyLocalMutationContext,
        FilesCanonicalMutationOperation
    )
    case filesPolicy(
        AgentPolicyLocalMutationContext,
        FilesPolicyMutationOperation
    )
    case terminal(
        AgentPolicyLocalMutationContext,
        TerminalCanonicalMutationOperation
    )
    case artifact(
        AgentPolicyLocalMutationContext,
        ArtifactCanonicalMutationOperation
    )
    case control(
        AgentPolicyLocalMutationContext,
        ControlPolicyMutationOperation
    )
    case projectOSCanonical(
        AgentPolicyLocalMutationContext,
        ProjectOSCanonicalMutationOperation
    )
    case projectOSPolicy(
        AgentPolicyLocalMutationContext,
        ProjectOSPolicyMutationOperation
    )
    case trustedSystemCanonical(
        AgentPolicyLocalMutationContext,
        TrustedSystemCanonicalMutationOperation
    )
    case trustedSystemPolicy(
        AgentPolicyLocalMutationContext,
        TrustedSystemPolicyMutationOperation
    )

    var fixedOrigin: MutationOrigin {
        switch self {
        case .agentV2:
            .agentV2
        case .v1Fallback:
            .v1Fallback
        case .editorCanonical, .editorPolicy:
            .editor
        case .filesCanonical, .filesPolicy:
            .files
        case .terminal:
            .terminal
        case .artifact:
            .artifact
        case .control:
            .control
        case .projectOSCanonical, .projectOSPolicy:
            .projectOS
        case .trustedSystemCanonical, .trustedSystemPolicy:
            .trustedSystem
        }
    }

    var operationFamily: AgentPolicyMutationOperationFamily {
        switch self {
        case .agentV2, .v1Fallback:
            .providerCanonical
        case .editorCanonical, .filesCanonical, .terminal, .artifact,
             .projectOSCanonical, .trustedSystemCanonical:
            .surfaceCanonical
        case .editorPolicy, .filesPolicy, .control, .projectOSPolicy,
             .trustedSystemPolicy:
            .policyOnly
        }
    }

    var workspaceBinding: AgentPolicyWorkspaceBinding {
        switch self {
        case let .agentV2(scope, _, _),
             let .v1Fallback(scope, _, _):
            scope.workspaceBinding
        case let .editorCanonical(context, _),
             let .editorPolicy(context, _),
             let .filesCanonical(context, _),
             let .filesPolicy(context, _),
             let .terminal(context, _),
             let .artifact(context, _),
             let .control(context, _),
             let .projectOSCanonical(context, _),
             let .projectOSPolicy(context, _),
             let .trustedSystemCanonical(context, _),
             let .trustedSystemPolicy(context, _):
            context.scope.workspaceBinding
        }
    }
}

enum AgentPolicyMutationOperationFamily: Equatable, Sendable {
    case providerCanonical
    case surfaceCanonical
    case policyOnly
}

protocol AgentPolicyMutationPipeline: Sendable {
    /// The reference is part of the app composition invariant. A facade
    /// created against any other policy authority fails before first use.
    var policyRevisionAuthority: PolicyRevisionAuthority { get }

    func execute(
        _ request: AgentPolicyBoundMutationRequest
    ) async throws -> AgentPolicyUnclassifiedMutationResult

    func prepareAgentV2(
        _ request: AgentPolicyBoundMutationRequest
    ) async throws -> AgentPolicyStagedAgentV2Mutation

    func resolveApproval(
        for prepared: AgentPolicyStagedAgentV2Mutation
    ) async throws -> ApprovalResolution

    func applyAgentV2(
        _ prepared: AgentPolicyStagedAgentV2Mutation,
        approval: ApprovalResolution?
    ) async throws -> AgentPolicyUnclassifiedMutationResult
}

extension AgentPolicyMutationPipeline {
    func prepareAgentV2(
        _: AgentPolicyBoundMutationRequest
    ) async throws -> AgentPolicyStagedAgentV2Mutation {
        throw AgentPolicyMutationServiceError.invalidComposition
    }

    func resolveApproval(
        for _: AgentPolicyStagedAgentV2Mutation
    ) async throws -> ApprovalResolution {
        throw AgentPolicyMutationServiceError.invalidComposition
    }

    func applyAgentV2(
        _: AgentPolicyStagedAgentV2Mutation,
        approval _: ApprovalResolution?
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        throw AgentPolicyMutationServiceError.invalidComposition
    }
}

/// Sealed app mutation facade. It exposes no generic `MutationOrigin`, no raw
/// scalar approval, and no arbitrary effect closure. Every effect must cross
/// the package's request, policy, durable approval, claim, and gateway chain.
struct AgentPolicyMutationService: Sendable {
    private let authority: PolicyRevisionAuthority
    private let workspaceBinding: AgentPolicyWorkspaceBinding
    private let pipeline: any AgentPolicyMutationPipeline

    init(
        policyRevisionAuthority: PolicyRevisionAuthority,
        workspaceBinding: AgentPolicyWorkspaceBinding,
        pipeline: any AgentPolicyMutationPipeline
    ) throws {
        guard pipeline.policyRevisionAuthority === policyRevisionAuthority
        else { throw AgentPolicyMutationServiceError.invalidComposition }
        authority = policyRevisionAuthority
        self.workspaceBinding = workspaceBinding
        self.pipeline = pipeline
    }

    var policyRevisionAuthorityIdentity: ObjectIdentifier {
        ObjectIdentifier(authority)
    }

    func isBound(to candidate: PolicyRevisionAuthority) -> Bool {
        authority === candidate
    }

    func performAgentV2(
        scope: AgentPolicyMutationScope,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await execute(.agentV2(
            scope,
            descriptor: descriptor,
            invocation: invocation
        ))
    }

    func prepareAgentV2(
        scope: AgentPolicyMutationScope,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) async throws -> AgentPolicyStagedAgentV2Mutation {
        let request = AgentPolicyBoundMutationRequest.agentV2(
            scope,
            descriptor: descriptor,
            invocation: invocation
        )
        guard request.workspaceBinding == workspaceBinding else {
            throw AgentPolicyMutationServiceError.requestRejected
        }
        return try await pipeline.prepareAgentV2(request)
    }

    func resolveApproval(
        for prepared: AgentPolicyStagedAgentV2Mutation
    ) async throws -> ApprovalResolution {
        try await pipeline.resolveApproval(for: prepared)
    }

    func applyAgentV2(
        _ prepared: AgentPolicyStagedAgentV2Mutation,
        approval: ApprovalResolution?
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await pipeline.applyAgentV2(prepared, approval: approval)
    }

    func performV1Fallback(
        scope: AgentPolicyMutationScope,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await execute(.v1Fallback(
            scope,
            descriptor: descriptor,
            invocation: invocation
        ))
    }

    func performEditor(
        context: AgentPolicyLocalMutationContext,
        operation: EditorCanonicalMutationOperation
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await execute(.editorCanonical(context, operation))
    }

    func performEditor(
        context: AgentPolicyLocalMutationContext,
        operation: EditorPolicyMutationOperation
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await execute(.editorPolicy(context, operation))
    }

    func performFiles(
        context: AgentPolicyLocalMutationContext,
        operation: FilesCanonicalMutationOperation
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await execute(.filesCanonical(context, operation))
    }

    func performFiles(
        context: AgentPolicyLocalMutationContext,
        operation: FilesPolicyMutationOperation
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await execute(.filesPolicy(context, operation))
    }

    func performTerminal(
        context: AgentPolicyLocalMutationContext,
        operation: TerminalCanonicalMutationOperation
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await execute(.terminal(context, operation))
    }

    func performArtifact(
        context: AgentPolicyLocalMutationContext,
        operation: ArtifactCanonicalMutationOperation
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await execute(.artifact(context, operation))
    }

    func performControl(
        context: AgentPolicyLocalMutationContext,
        operation: ControlPolicyMutationOperation
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await execute(.control(context, operation))
    }

    func performProjectOS(
        context: AgentPolicyLocalMutationContext,
        operation: ProjectOSCanonicalMutationOperation
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await execute(.projectOSCanonical(context, operation))
    }

    func performProjectOS(
        context: AgentPolicyLocalMutationContext,
        operation: ProjectOSPolicyMutationOperation
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await execute(.projectOSPolicy(context, operation))
    }

    func performTrustedSystem(
        context: AgentPolicyLocalMutationContext,
        operation: TrustedSystemCanonicalMutationOperation
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await execute(.trustedSystemCanonical(context, operation))
    }

    func performTrustedSystem(
        context: AgentPolicyLocalMutationContext,
        operation: TrustedSystemPolicyMutationOperation
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        try await execute(.trustedSystemPolicy(context, operation))
    }

    private func execute(
        _ request: AgentPolicyBoundMutationRequest
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        guard request.workspaceBinding == workspaceBinding else {
            throw AgentPolicyMutationServiceError.requestRejected
        }
        return try await pipeline.execute(request)
    }
}

/// Production implementation kept private to the app service layer so no
/// caller can skip a stage or inject an effect closure.
final class AgentPolicyProductionMutationPipeline: AgentPolicyMutationPipeline {
    let policyRevisionAuthority: PolicyRevisionAuthority

    private let resolver: WorkspaceTargetResolverAuthority
    private let evaluator: LayeredRiskPolicyEvaluator
    private let approvalAuthority: DurableApprovalAuthority
    private let approvalStore: any DurableApprovalStore
    private let claimAuthority: ToolEffectClaimAuthority
    let gatewayAuthority: AgentPolicyMutationGatewayAuthority
    private let approvalLifetimeMilliseconds: UInt64

    init(
        policyRevisionAuthority: PolicyRevisionAuthority,
        resolver: WorkspaceTargetResolverAuthority,
        evaluator: LayeredRiskPolicyEvaluator,
        approvalAuthority: DurableApprovalAuthority,
        approvalStore: any DurableApprovalStore,
        claimAuthority: ToolEffectClaimAuthority,
        gatewayAuthority: AgentPolicyMutationGatewayAuthority,
        approvalLifetimeMilliseconds: UInt64
    ) throws {
        guard (1 ... 86_400_000).contains(approvalLifetimeMilliseconds)
        else { throw AgentPolicyMutationServiceError.invalidComposition }
        self.policyRevisionAuthority = policyRevisionAuthority
        self.resolver = resolver
        self.evaluator = evaluator
        self.approvalAuthority = approvalAuthority
        self.approvalStore = approvalStore
        self.claimAuthority = claimAuthority
        self.gatewayAuthority = gatewayAuthority
        self.approvalLifetimeMilliseconds = approvalLifetimeMilliseconds
    }

    func prepareAgentV2(
        _ boundRequest: AgentPolicyBoundMutationRequest
    ) async throws -> AgentPolicyStagedAgentV2Mutation {
        guard !Task.isCancelled else {
            throw AgentPolicyMutationServiceError.cancelled
        }
        guard case .agentV2 = boundRequest,
              boundRequest.fixedOrigin == .agentV2
        else { throw AgentPolicyMutationServiceError.requestRejected }

        let request: RiskPolicyRequest
        do {
            request = try await resolve(boundRequest)
        } catch is CancellationError {
            throw AgentPolicyMutationServiceError.cancelled
        } catch {
            throw AgentPolicyMutationServiceError.requestRejected
        }
        guard request.origin == .agentV2 else {
            throw AgentPolicyMutationServiceError.requestRejected
        }

        let evaluation = await evaluator.evaluate(request)
        let effectKey = try AgentPolicyToolEffectKeyProjection.digest(
            request: request,
            policySHA256: evaluation.policySHA256
        )
        switch evaluation.decision {
        case .allow:
            guard let preliminary = evaluation.executionPermit else {
                throw AgentPolicyMutationServiceError.authorizationFailed
            }
            // A one-time grant is redeemed while evaluating and AgentPolicy
            // intentionally exposes no durable recovery API that can remint
            // its opaque preliminary permit. Refuse this staged route rather
            // than make correctness depend on process memory.
            guard preliminary.oneTimeRedemption == nil else {
                throw AgentPolicyMutationServiceError
                    .stagedAutomaticAuthorizationUnsupported
            }
            return AgentPolicyStagedAgentV2Mutation(
                request: request,
                policySHA256: evaluation.policySHA256,
                effectKeySHA256: effectKey,
                authorization: .reevaluablePolicy
            )

        case .requiresApproval:
            let durable: DurableApprovalRequest
            do {
                durable = try await approvalAuthority.register(
                    for: request,
                    evaluation: evaluation,
                    lifetimeMilliseconds: approvalLifetimeMilliseconds
                )
            } catch is CancellationError {
                throw AgentPolicyMutationServiceError.cancelled
            } catch {
                throw AgentPolicyMutationServiceError.approvalFailed
            }
            let domain = Self.domainApprovalRequest(durable)
            return AgentPolicyStagedAgentV2Mutation(
                request: request,
                policySHA256: evaluation.policySHA256,
                effectKeySHA256: effectKey,
                authorization: .durableApproval(
                    durableRequest: durable,
                    domainRequest: domain
                )
            )

        case .deny:
            throw AgentPolicyMutationServiceError.policyDenied
        case .indeterminate:
            throw AgentPolicyMutationServiceError.policyIndeterminate
        }
    }

    func resolveApproval(
        for prepared: AgentPolicyStagedAgentV2Mutation
    ) async throws -> ApprovalResolution {
        guard !Task.isCancelled else {
            throw AgentPolicyMutationServiceError.cancelled
        }
        guard case let .durableApproval(durable, domain) =
            prepared.authorization,
            domain == Self.domainApprovalRequest(durable)
        else {
            throw AgentPolicyMutationServiceError.approvalBindingMismatch
        }
        let resolution: DurableApprovalResolution
        do {
            // This is the sole trusted UI prompt. `applyAgentV2` below reads
            // the durable result and never calls this method again.
            resolution = try await approvalAuthority.resolve(
                requestID: durable.requestID,
                for: prepared.request
            )
        } catch let error as DurableApprovalAuthorityError
            where error == .approvalRejected
        {
            throw AgentPolicyMutationServiceError.approvalRejected
        } catch is CancellationError {
            throw AgentPolicyMutationServiceError.cancelled
        } catch {
            throw AgentPolicyMutationServiceError.approvalFailed
        }
        return Self.domainApprovalResolution(
            resolution,
            callID: durable.binding.callID
        )
    }

    func applyAgentV2(
        _ prepared: AgentPolicyStagedAgentV2Mutation,
        approval: ApprovalResolution?
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        guard !Task.isCancelled else {
            throw AgentPolicyMutationServiceError.cancelled
        }
        let permit: ToolEffectPermit
        switch prepared.authorization {
        case let .durableApproval(durable, domainRequest):
            guard let approval,
                  domainRequest == Self.domainApprovalRequest(durable),
                  approval.requestID == durable.requestID,
                  approval.callID == durable.binding.callID
            else {
                throw AgentPolicyMutationServiceError.approvalBindingMismatch
            }
            let state: DurableApprovalState
            do {
                guard let existing = try await approvalStore.state(
                    requestID: durable.requestID
                ) else {
                    throw AgentPolicyMutationServiceError
                        .approvalBindingMismatch
                }
                state = existing
            } catch let error as AgentPolicyMutationServiceError {
                throw error
            } catch {
                throw AgentPolicyMutationServiceError.approvalFailed
            }
            guard state.request == durable,
                  let trusted = state.resolution,
                  approval == Self.domainApprovalResolution(
                      trusted,
                      callID: durable.binding.callID
                  )
            else {
                throw AgentPolicyMutationServiceError.approvalBindingMismatch
            }
            guard trusted.decision == .approved,
                  approval.decision == .approved
            else { throw AgentPolicyMutationServiceError.approvalRejected }

            do {
                let lease = try await approvalAuthority.authorize(
                    requestID: durable.requestID,
                    for: prepared.request
                )
                permit = try await approvalAuthority.finalizeForExecution(
                    lease
                )
            } catch let error as DurableApprovalAuthorityError
                where error == .approvalRejected
            {
                throw AgentPolicyMutationServiceError.approvalRejected
            } catch is CancellationError {
                throw AgentPolicyMutationServiceError.cancelled
            } catch {
                throw AgentPolicyMutationServiceError.authorizationFailed
            }

        case .reevaluablePolicy:
            guard approval == nil else {
                throw AgentPolicyMutationServiceError.approvalBindingMismatch
            }
            let evaluation = await evaluator.evaluate(prepared.request)
            guard case .allow = evaluation.decision,
                  evaluation.policySHA256 == prepared.policySHA256,
                  let preliminary = evaluation.executionPermit,
                  preliminary.oneTimeRedemption == nil
            else {
                throw AgentPolicyMutationServiceError.authorizationFailed
            }
            do {
                permit = try await evaluator.finalizeForExecution(preliminary)
            } catch is CancellationError {
                throw AgentPolicyMutationServiceError.cancelled
            } catch {
                throw AgentPolicyMutationServiceError.authorizationFailed
            }
        }

        guard permit.origin == .agentV2,
              permit.effectKeySHA256 == prepared.effectKeySHA256,
              permit.requestSHA256 == prepared.request.requestSHA256,
              permit.policySHA256 == prepared.policySHA256,
              permit.callID == prepared.request.invocation.callID,
              permit.workspaceID == prepared.request.workspaceID,
              permit.canonicalArgumentDigest
                == prepared.request.invocation.canonicalArgumentDigest,
              permit.resolutionAttestationSHA256
                == prepared.request.targetAttestationSHA256
        else {
            throw AgentPolicyMutationServiceError.stagedPreparationMismatch
        }

        let claimed: ClaimedToolEffectPermit
        do {
            claimed = try await claimAuthority.claim(permit)
        } catch is CancellationError {
            throw AgentPolicyMutationServiceError.cancelled
        } catch {
            throw AgentPolicyMutationServiceError.claimFailed
        }
        do {
            let receipt = try await gatewayAuthority.apply(claimed)
            guard receipt.origin == .agentV2,
                  receipt.effectKeySHA256 == prepared.effectKeySHA256
            else { throw AgentPolicyMutationServiceError.effectFailed }
            return AgentPolicyUnclassifiedMutationResult(receipt: receipt)
        } catch let error as AgentPolicyMutationServiceError {
            throw error
        } catch is CancellationError {
            throw AgentPolicyMutationServiceError.cancelled
        } catch {
            throw AgentPolicyMutationServiceError.effectFailed
        }
    }

    private static func domainApprovalRequest(
        _ request: DurableApprovalRequest
    ) -> ApprovalRequest {
        let binding = request.binding
        return ApprovalRequest(
            requestID: request.requestID,
            binding: ApprovalBinding(
                runID: binding.runID,
                callID: binding.callID,
                tool: binding.tool,
                canonicalArgumentDigest: binding.canonicalArgumentDigest,
                workspaceID: binding.workspaceID,
                previewDigest: binding.operationPreviewSHA256.rawValue,
                workspaceRevision: binding.workspaceRevision
            ),
            summary: "Approval required for \(binding.tool.name)",
            requestedAt: binding.issuedAt,
            expiresAt: binding.expiresAt
        )
    }

    private static func domainApprovalResolution(
        _ resolution: DurableApprovalResolution,
        callID: ToolCallID
    ) -> ApprovalResolution {
        ApprovalResolution(
            requestID: resolution.requestID,
            callID: callID,
            decision: resolution.decision,
            resolvedAt: resolution.resolvedAt,
            rationale: nil
        )
    }

    func execute(
        _ boundRequest: AgentPolicyBoundMutationRequest
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        guard !Task.isCancelled else {
            throw AgentPolicyMutationServiceError.cancelled
        }

        let request: RiskPolicyRequest
        do {
            request = try await resolve(boundRequest)
        } catch is CancellationError {
            throw AgentPolicyMutationServiceError.cancelled
        } catch {
            throw AgentPolicyMutationServiceError.requestRejected
        }

        guard request.origin == boundRequest.fixedOrigin else {
            throw AgentPolicyMutationServiceError.requestRejected
        }

        let evaluation = await evaluator.evaluate(request)
        let effectPermit: ToolEffectPermit
        switch evaluation.decision {
        case .allow:
            guard let preliminaryPermit = evaluation.executionPermit else {
                throw AgentPolicyMutationServiceError.authorizationFailed
            }
            do {
                effectPermit = try await evaluator.finalizeForExecution(
                    preliminaryPermit
                )
            } catch {
                throw AgentPolicyMutationServiceError.authorizationFailed
            }

        case .requiresApproval:
            effectPermit = try await approvedPermit(
                request: request,
                evaluation: evaluation
            )

        case .deny:
            throw AgentPolicyMutationServiceError.policyDenied

        case .indeterminate:
            throw AgentPolicyMutationServiceError.policyIndeterminate
        }

        guard effectPermit.origin == boundRequest.fixedOrigin else {
            throw AgentPolicyMutationServiceError.authorizationFailed
        }

        let claimed: ClaimedToolEffectPermit
        do {
            claimed = try await claimAuthority.claim(effectPermit)
        } catch {
            throw AgentPolicyMutationServiceError.claimFailed
        }

        do {
            let receipt = try await gatewayAuthority.apply(claimed)
            guard receipt.origin == boundRequest.fixedOrigin else {
                throw AgentPolicyMutationServiceError.effectFailed
            }
            return AgentPolicyUnclassifiedMutationResult(receipt: receipt)
        } catch let error as AgentPolicyMutationServiceError {
            throw error
        } catch {
            throw AgentPolicyMutationServiceError.effectFailed
        }
    }

    private func approvedPermit(
        request: RiskPolicyRequest,
        evaluation: RiskPolicyEvaluation
    ) async throws -> ToolEffectPermit {
        let approvalRequest: DurableApprovalRequest
        do {
            approvalRequest = try await approvalAuthority.register(
                for: request,
                evaluation: evaluation,
                lifetimeMilliseconds: approvalLifetimeMilliseconds
            )
            _ = try await approvalAuthority.resolve(
                requestID: approvalRequest.requestID,
                for: request
            )
            let lease = try await approvalAuthority.authorize(
                requestID: approvalRequest.requestID,
                for: request
            )
            return try await approvalAuthority.finalizeForExecution(lease)
        } catch let error as DurableApprovalAuthorityError
            where error == .approvalRejected
        {
            throw AgentPolicyMutationServiceError.approvalRejected
        } catch is CancellationError {
            throw AgentPolicyMutationServiceError.cancelled
        } catch let error as AgentPolicyMutationServiceError {
            throw error
        } catch {
            throw AgentPolicyMutationServiceError.approvalFailed
        }
    }

    private func resolve(
        _ request: AgentPolicyBoundMutationRequest
    ) async throws -> RiskPolicyRequest {
        switch request {
        case let .agentV2(scope, descriptor, invocation):
            return try await RiskPolicyRequest.resolveAgentV2(
                runID: scope.runID,
                projectID: scope.projectID,
                workspaceID: scope.workspaceID,
                sessionID: scope.sessionID,
                backend: scope.backend,
                descriptor: descriptor,
                invocation: invocation,
                using: resolver
            )

        case let .v1Fallback(scope, descriptor, invocation):
            return try await RiskPolicyRequest.resolveV1Fallback(
                runID: scope.runID,
                projectID: scope.projectID,
                workspaceID: scope.workspaceID,
                sessionID: scope.sessionID,
                backend: scope.backend,
                descriptor: descriptor,
                invocation: invocation,
                using: resolver
            )

        case let .editorCanonical(context, operation):
            return try await RiskPolicyRequest.resolveEditor(
                context: context,
                operation: operation,
                using: resolver
            )

        case let .editorPolicy(context, operation):
            return try await RiskPolicyRequest.resolveEditor(
                context: context,
                operation: operation,
                using: resolver
            )

        case let .filesCanonical(context, operation):
            return try await RiskPolicyRequest.resolveFiles(
                context: context,
                operation: operation,
                using: resolver
            )

        case let .filesPolicy(context, operation):
            return try await RiskPolicyRequest.resolveFiles(
                context: context,
                operation: operation,
                using: resolver
            )

        case let .terminal(context, operation):
            return try await RiskPolicyRequest.resolveTerminal(
                context: context,
                operation: operation,
                using: resolver
            )

        case let .artifact(context, operation):
            return try await RiskPolicyRequest.resolveArtifact(
                context: context,
                operation: operation,
                using: resolver
            )

        case let .control(context, operation):
            return try await RiskPolicyRequest.resolveControl(
                context: context,
                operation: operation,
                using: resolver
            )

        case let .projectOSCanonical(context, operation):
            return try await RiskPolicyRequest.resolveProjectOS(
                context: context,
                operation: operation,
                using: resolver
            )

        case let .projectOSPolicy(context, operation):
            return try await RiskPolicyRequest.resolveProjectOS(
                context: context,
                operation: operation,
                using: resolver
            )

        case let .trustedSystemCanonical(context, operation):
            return try await RiskPolicyRequest.resolveTrustedSystem(
                context: context,
                operation: operation,
                using: resolver
            )

        case let .trustedSystemPolicy(context, operation):
            return try await RiskPolicyRequest.resolveTrustedSystem(
                context: context,
                operation: operation,
                using: resolver
            )
        }
    }
}

private extension RiskPolicyRequest {
    static func resolveEditor(
        context: AgentPolicyLocalMutationContext,
        operation: EditorCanonicalMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveEditor(
            runID: context.scope.runID,
            projectID: context.scope.projectID,
            workspaceID: context.scope.workspaceID,
            sessionID: context.scope.sessionID,
            backend: context.scope.backend,
            callID: context.callID,
            operationAttemptID: context.operationAttemptID,
            idempotencyKey: context.idempotencyKey,
            operation: operation,
            using: resolver
        )
    }

    static func resolveEditor(
        context: AgentPolicyLocalMutationContext,
        operation: EditorPolicyMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveEditor(
            runID: context.scope.runID,
            projectID: context.scope.projectID,
            workspaceID: context.scope.workspaceID,
            sessionID: context.scope.sessionID,
            backend: context.scope.backend,
            callID: context.callID,
            operationAttemptID: context.operationAttemptID,
            idempotencyKey: context.idempotencyKey,
            operation: operation,
            using: resolver
        )
    }

    static func resolveFiles(
        context: AgentPolicyLocalMutationContext,
        operation: FilesCanonicalMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveFiles(
            runID: context.scope.runID,
            projectID: context.scope.projectID,
            workspaceID: context.scope.workspaceID,
            sessionID: context.scope.sessionID,
            backend: context.scope.backend,
            callID: context.callID,
            operationAttemptID: context.operationAttemptID,
            idempotencyKey: context.idempotencyKey,
            operation: operation,
            using: resolver
        )
    }

    static func resolveFiles(
        context: AgentPolicyLocalMutationContext,
        operation: FilesPolicyMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveFiles(
            runID: context.scope.runID,
            projectID: context.scope.projectID,
            workspaceID: context.scope.workspaceID,
            sessionID: context.scope.sessionID,
            backend: context.scope.backend,
            callID: context.callID,
            operationAttemptID: context.operationAttemptID,
            idempotencyKey: context.idempotencyKey,
            operation: operation,
            using: resolver
        )
    }

    static func resolveTerminal(
        context: AgentPolicyLocalMutationContext,
        operation: TerminalCanonicalMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveTerminal(
            runID: context.scope.runID,
            projectID: context.scope.projectID,
            workspaceID: context.scope.workspaceID,
            sessionID: context.scope.sessionID,
            backend: context.scope.backend,
            callID: context.callID,
            operationAttemptID: context.operationAttemptID,
            idempotencyKey: context.idempotencyKey,
            operation: operation,
            using: resolver
        )
    }

    static func resolveArtifact(
        context: AgentPolicyLocalMutationContext,
        operation: ArtifactCanonicalMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveArtifact(
            runID: context.scope.runID,
            projectID: context.scope.projectID,
            workspaceID: context.scope.workspaceID,
            sessionID: context.scope.sessionID,
            backend: context.scope.backend,
            callID: context.callID,
            operationAttemptID: context.operationAttemptID,
            idempotencyKey: context.idempotencyKey,
            operation: operation,
            using: resolver
        )
    }

    static func resolveControl(
        context: AgentPolicyLocalMutationContext,
        operation: ControlPolicyMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveControl(
            runID: context.scope.runID,
            projectID: context.scope.projectID,
            workspaceID: context.scope.workspaceID,
            sessionID: context.scope.sessionID,
            backend: context.scope.backend,
            callID: context.callID,
            operationAttemptID: context.operationAttemptID,
            idempotencyKey: context.idempotencyKey,
            operation: operation,
            using: resolver
        )
    }

    static func resolveProjectOS(
        context: AgentPolicyLocalMutationContext,
        operation: ProjectOSCanonicalMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveProjectOS(
            runID: context.scope.runID,
            projectID: context.scope.projectID,
            workspaceID: context.scope.workspaceID,
            sessionID: context.scope.sessionID,
            backend: context.scope.backend,
            callID: context.callID,
            operationAttemptID: context.operationAttemptID,
            idempotencyKey: context.idempotencyKey,
            operation: operation,
            using: resolver
        )
    }

    static func resolveProjectOS(
        context: AgentPolicyLocalMutationContext,
        operation: ProjectOSPolicyMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveProjectOS(
            runID: context.scope.runID,
            projectID: context.scope.projectID,
            workspaceID: context.scope.workspaceID,
            sessionID: context.scope.sessionID,
            backend: context.scope.backend,
            callID: context.callID,
            operationAttemptID: context.operationAttemptID,
            idempotencyKey: context.idempotencyKey,
            operation: operation,
            using: resolver
        )
    }

    static func resolveTrustedSystem(
        context: AgentPolicyLocalMutationContext,
        operation: TrustedSystemCanonicalMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveTrustedSystem(
            runID: context.scope.runID,
            projectID: context.scope.projectID,
            workspaceID: context.scope.workspaceID,
            sessionID: context.scope.sessionID,
            backend: context.scope.backend,
            callID: context.callID,
            operationAttemptID: context.operationAttemptID,
            idempotencyKey: context.idempotencyKey,
            operation: operation,
            using: resolver
        )
    }

    static func resolveTrustedSystem(
        context: AgentPolicyLocalMutationContext,
        operation: TrustedSystemPolicyMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveTrustedSystem(
            runID: context.scope.runID,
            projectID: context.scope.projectID,
            workspaceID: context.scope.workspaceID,
            sessionID: context.scope.sessionID,
            backend: context.scope.backend,
            callID: context.callID,
            operationAttemptID: context.operationAttemptID,
            idempotencyKey: context.idempotencyKey,
            operation: operation,
            using: resolver
        )
    }
}

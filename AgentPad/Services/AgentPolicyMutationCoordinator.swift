import AgentDomain
import AgentPolicy
import AgentTools
import CryptoKit
import Foundation

enum AgentPolicyMutationCoordinatorError: Error, Equatable, Sendable {
    case invalidWorkspace
    case invalidLineage
    case invalidIdempotencyKey
    case invalidSessionID
    case workspaceBindingMismatch
    case workspaceIdentityCollision
    case systemBindingMismatch
    case providerInvocationIdentityMismatch
    case receiptOriginMismatch
}

/// Stable, caller-owned identity and typed lineage for one policy mutation.
/// Default typed IDs are deterministic, domain-separated UUIDv8 derivations
/// of the operation UUID, so retries are stable without aliasing semantic ID
/// domains. Explicit caller lineage and attempt identity remain authoritative.
struct AgentPolicyMutationExecutionContext: Sendable {
    let workspace: SandboxWorkspace
    let operationID: UUID
    let idempotencyKey: String
    let lineage: AgentRunLineage
    let callID: ToolCallID
    let operationAttemptID: AttemptID
    let conversationID: ConversationID
    let projectID: ProjectID?
    let executionNodeID: ExecutionNodeID
    let acceptedAt: AgentInstant
    let features: AgentFeatureSet
    let cancellation: CancellationLineage
    let initialBudget: AgentBudget
    let sessionID: String?
    let backend: PolicyBackend

    init(
        workspace: SandboxWorkspace,
        operationID: UUID,
        idempotencyKey: String,
        lineage: AgentRunLineage? = nil,
        callID: ToolCallID? = nil,
        operationAttemptID: AttemptID? = nil,
        conversationID: ConversationID,
        projectID: ProjectID?,
        executionNodeID: ExecutionNodeID,
        acceptedAt: AgentInstant,
        features: AgentFeatureSet = AgentFeatureSet([]),
        cancellation: CancellationLineage? = nil,
        initialBudget: AgentBudget = AgentBudget(limits: .standard),
        sessionID: String? = nil,
        backend: PolicyBackend = .onDevice
    ) throws {
        let resolvedLineage = lineage ?? .root(RunID(rawValue: Self.derivedUUID(
            from: operationID,
            domain: .run
        )))
        guard resolvedLineage.validationError == nil else {
            throw AgentPolicyMutationCoordinatorError.invalidLineage
        }
        guard Self.isValidToken(idempotencyKey) else {
            throw AgentPolicyMutationCoordinatorError.invalidIdempotencyKey
        }
        if let sessionID, !Self.isValidToken(sessionID) {
            throw AgentPolicyMutationCoordinatorError.invalidSessionID
        }

        self.workspace = workspace
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.lineage = resolvedLineage
        self.callID = callID ?? ToolCallID(rawValue: Self.derivedUUID(
                from: operationID,
                domain: .toolCall
            ))
        self.operationAttemptID = operationAttemptID
            ?? AttemptID(rawValue: Self.derivedUUID(
                from: operationID,
                domain: .attempt
            ))
        self.conversationID = conversationID
        self.projectID = projectID
        self.executionNodeID = executionNodeID
        self.acceptedAt = acceptedAt
        self.features = features
        self.cancellation = cancellation ?? CancellationLineage(
            scopeID: CancellationScopeID(rawValue: Self.derivedUUID(
                from: operationID,
                domain: .cancellation
            ))
        )
        self.initialBudget = initialBudget
        self.sessionID = sessionID
        self.backend = backend
    }

    private static func isValidToken(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.isEmpty
            && value.utf8.count <= 512
            && value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    && scalar.properties.generalCategory != .format
            }
    }

    private enum DerivedIdentityDomain: String {
        case run
        case toolCall = "tool-call"
        case attempt
        case cancellation
    }

    private static func derivedUUID(
        from operationID: UUID,
        domain: DerivedIdentityDomain
    ) -> UUID {
        let material = [
            "novaforge-policy-operation-identity-v1",
            domain.rawValue,
            operationID.uuidString.lowercased(),
        ].joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(material.utf8)).prefix(16))
        // RFC 9562 UUIDv8: application-defined digest with RFC variant bits.
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

/// The only mutation result that may leave this coordinator. It contains
/// stable typed identity and content-addressed integrity facts, but no tool
/// arguments, paths, summaries, command text, command output, or evidence.
struct AgentPolicyMutationReceipt: Codable, Equatable, Sendable {
    let operationID: UUID
    let runID: RunID
    let conversationID: ConversationID
    let projectID: ProjectID?
    let workspaceID: WorkspaceID
    let callID: ToolCallID
    let operationAttemptID: AttemptID
    let origin: MutationOrigin
    let effectKeySHA256: AgentPolicy.SHA256Digest
    let applicationSHA256: AgentPolicy.SHA256Digest
    let evidenceSHA256: AgentPolicy.SHA256Digest
    let finalRecordSHA256: AgentPolicy.SHA256Digest
    let receiptSHA256: AgentPolicy.SHA256Digest
}

/// Explicitly unclassified construction boundary used by the production
/// adapter and by hostile tests. The coordinator sanitizer never reads the
/// private output or evidence fields.
struct AgentPolicyCoordinatorUnclassifiedResult: Sendable {
    let origin: MutationOrigin
    let effectKeySHA256: AgentPolicy.SHA256Digest
    let applicationSHA256: AgentPolicy.SHA256Digest
    let evidenceSHA256: AgentPolicy.SHA256Digest
    let finalRecordSHA256: AgentPolicy.SHA256Digest
    let receiptSHA256: AgentPolicy.SHA256Digest
    private let unclassifiedOutput: MutationEffectOutput
    private let unclassifiedEvidence: [MutationEffectEvidenceFact]

    init(_ result: AgentPolicyUnclassifiedMutationResult) {
        origin = result.origin
        effectKeySHA256 = result.effectKeySHA256
        applicationSHA256 = result.applicationSHA256
        evidenceSHA256 = result.evidenceSHA256
        finalRecordSHA256 = result.finalRecordSHA256
        receiptSHA256 = result.receiptSHA256
        unclassifiedOutput = result.unclassifiedOutput
        unclassifiedEvidence = result.unclassifiedEvidence
    }

    init(
        origin: MutationOrigin,
        effectKeySHA256: AgentPolicy.SHA256Digest,
        applicationSHA256: AgentPolicy.SHA256Digest,
        evidenceSHA256: AgentPolicy.SHA256Digest,
        finalRecordSHA256: AgentPolicy.SHA256Digest,
        receiptSHA256: AgentPolicy.SHA256Digest,
        unclassifiedOutput: MutationEffectOutput,
        unclassifiedEvidence: [MutationEffectEvidenceFact]
    ) {
        self.origin = origin
        self.effectKeySHA256 = effectKeySHA256
        self.applicationSHA256 = applicationSHA256
        self.evidenceSHA256 = evidenceSHA256
        self.finalRecordSHA256 = finalRecordSHA256
        self.receiptSHA256 = receiptSHA256
        self.unclassifiedOutput = unclassifiedOutput
        self.unclassifiedEvidence = unclassifiedEvidence
    }
}

/// Internal construction seam. Every method binds a concrete origin and a
/// concrete operation family; there is no origin-bearing generic request and
/// no caller-supplied effect closure.
protocol AgentPolicyMutationSystemServing: Sendable {
    var workspaceBinding: AgentPolicyWorkspaceBinding { get }

    func performAgentV2(
        scope: AgentPolicyMutationScope,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult

    func performV1Fallback(
        scope: AgentPolicyMutationScope,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult

    func performEditor(
        context: AgentPolicyLocalMutationContext,
        operation: EditorCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult

    func performEditor(
        context: AgentPolicyLocalMutationContext,
        operation: EditorPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult

    func performFiles(
        context: AgentPolicyLocalMutationContext,
        operation: FilesCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult

    func performFiles(
        context: AgentPolicyLocalMutationContext,
        operation: FilesPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult

    func performTerminal(
        context: AgentPolicyLocalMutationContext,
        operation: TerminalCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult

    func performArtifact(
        context: AgentPolicyLocalMutationContext,
        operation: ArtifactCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult

    func performControl(
        context: AgentPolicyLocalMutationContext,
        operation: ControlPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult

    func performProjectOS(
        context: AgentPolicyLocalMutationContext,
        operation: ProjectOSCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult

    func performProjectOS(
        context: AgentPolicyLocalMutationContext,
        operation: ProjectOSPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult

    func performTrustedSystem(
        context: AgentPolicyLocalMutationContext,
        operation: TrustedSystemCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult

    func performTrustedSystem(
        context: AgentPolicyLocalMutationContext,
        operation: TrustedSystemPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult
}

typealias AgentPolicyMutationSystemFactory = @Sendable (
    RiskPolicyConfiguration,
    AgentPolicyWorkspaceBinding,
    any ApprovalDecisionPrompting
) throws -> any AgentPolicyMutationSystemServing

typealias AgentPolicyWorkspaceBindingFactory = @Sendable (
    SandboxWorkspace
) throws -> AgentPolicyWorkspaceBinding

/// App ownership root for policy mutation systems. Construction is synchronous
/// inside this actor, so concurrent first-use requests cannot create two
/// systems for one workspace. Awaiting actual effects happens only after the
/// canonical identity has been committed to the cache.
actor AgentPolicyMutationCoordinator {
    private struct CachedSystem: Sendable {
        let canonicalRootPath: String
        let binding: AgentPolicyWorkspaceBinding
        let system: any AgentPolicyMutationSystemServing
    }

    private struct PreparedRequest: Sendable {
        let system: any AgentPolicyMutationSystemServing
        let scope: AgentPolicyMutationScope
        let localContext: AgentPolicyLocalMutationContext
        let executionContext: AgentPolicyMutationExecutionContext
    }

    private let configuration: RiskPolicyConfiguration
    private let approvalPrompt: any ApprovalDecisionPrompting
    private let systemFactory: AgentPolicyMutationSystemFactory
    private let bindingFactory: AgentPolicyWorkspaceBindingFactory
    private var systems: [WorkspaceResourceIdentity: CachedSystem] = [:]

    /// Production default: fail closed except for the exact trusted-system
    /// bootstrap seed session. That narrow grant prevents first launch from
    /// presenting an approval sheet before the user has reached the app while
    /// preserving target resolution, revalidation, checkpointing, claiming,
    /// journaling, and the effect receipt for the seed itself.
    init(
        approvalPrompt: any ApprovalDecisionPrompting,
        configuration: RiskPolicyConfiguration? = nil,
        storeFileSystem: any AgentPolicyStoreFileSystem =
            AgentPolicyDefaultStoreFileSystem(),
        signingKeyStore: AgentApprovalSigningKeyStore =
            AgentApprovalSigningKeyStore()
    ) throws {
        let resolvedConfiguration: RiskPolicyConfiguration
        if let configuration {
            resolvedConfiguration = configuration
        } else {
            resolvedConfiguration = try Self.productionConfiguration()
        }
        self.configuration = resolvedConfiguration
        self.approvalPrompt = approvalPrompt
        systemFactory = { configuration, binding, prompt in
            let system = try AgentPolicySystem.productionPOSIX(
                configuration: configuration,
                workspaceBinding: binding,
                approvalPrompt: prompt,
                storeFileSystem: storeFileSystem,
                signingKeyStore: signingKeyStore
            )
            return AgentPolicyProductionMutationSystem(system: system)
        }
        bindingFactory = { workspace in
            try AgentPolicyWorkspaceBinding(workspace: workspace)
        }
    }

    nonisolated static func failClosedConfiguration() throws
        -> RiskPolicyConfiguration
    {
        try RiskPolicyConfiguration(
            administrative: PolicyRestrictionSet(),
            user: UserPolicyRestrictions(),
            grants: [],
            advisoryTimeoutMilliseconds: 1_000
        )
    }

    nonisolated static func productionConfiguration() throws
        -> RiskPolicyConfiguration
    {
        let bootstrapSeedGrant = try PolicyGrant(
            grantID: "novaforge-trusted-bootstrap-seed-v1",
            scope: .session(sessionID: "agent-runtime-seed-v1"),
            tool: ToolIdentity(name: "seed_workspace", version: "1.0.0"),
            targetPrefixes: [""],
            expiresAt: AgentInstant(rawValue: .max)
        )
        return try RiskPolicyConfiguration(
            administrative: PolicyRestrictionSet(),
            user: UserPolicyRestrictions(),
            grants: [bootstrapSeedGrant],
            advisoryTimeoutMilliseconds: 1_000
        )
    }

    /// Test/composition seam. Supplying a system factory avoids touching real
    /// Application Support, ledgers, checkpoints, or Keychain material.
    init(
        configuration: RiskPolicyConfiguration,
        approvalPrompt: any ApprovalDecisionPrompting,
        systemFactory: @escaping AgentPolicyMutationSystemFactory,
        bindingFactory: @escaping AgentPolicyWorkspaceBindingFactory = {
            try AgentPolicyWorkspaceBinding(workspace: $0)
        }
    ) {
        self.configuration = configuration
        self.approvalPrompt = approvalPrompt
        self.systemFactory = systemFactory
        self.bindingFactory = bindingFactory
    }

    var cachedWorkspaceCount: Int { systems.count }

    func performAgentV2(
        context: AgentPolicyMutationExecutionContext,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) async throws -> AgentPolicyMutationReceipt {
        try validateProviderInvocation(invocation, context: context)
        let prepared = try prepare(context, engineVersion: .agentHarnessV2)
        let result = try await prepared.system.performAgentV2(
            scope: prepared.scope,
            descriptor: descriptor,
            invocation: invocation
        )
        return try sanitize(
            result,
            expectedOrigin: .agentV2,
            prepared: prepared
        )
    }

    func performV1Fallback(
        context: AgentPolicyMutationExecutionContext,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) async throws -> AgentPolicyMutationReceipt {
        try validateProviderInvocation(invocation, context: context)
        let prepared = try prepare(context, engineVersion: .agentHarnessV1)
        let result = try await prepared.system.performV1Fallback(
            scope: prepared.scope,
            descriptor: descriptor,
            invocation: invocation
        )
        return try sanitize(
            result,
            expectedOrigin: .v1Fallback,
            prepared: prepared
        )
    }

    func performEditor(
        context: AgentPolicyMutationExecutionContext,
        operation: EditorCanonicalMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        let prepared = try prepare(context, engineVersion: .agentHarnessV2)
        return try sanitize(
            try await prepared.system.performEditor(
                context: prepared.localContext,
                operation: operation
            ),
            expectedOrigin: .editor,
            prepared: prepared
        )
    }

    func performEditor(
        context: AgentPolicyMutationExecutionContext,
        operation: EditorPolicyMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        let prepared = try prepare(context, engineVersion: .agentHarnessV2)
        return try sanitize(
            try await prepared.system.performEditor(
                context: prepared.localContext,
                operation: operation
            ),
            expectedOrigin: .editor,
            prepared: prepared
        )
    }

    func performFiles(
        context: AgentPolicyMutationExecutionContext,
        operation: FilesCanonicalMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        let prepared = try prepare(context, engineVersion: .agentHarnessV2)
        return try sanitize(
            try await prepared.system.performFiles(
                context: prepared.localContext,
                operation: operation
            ),
            expectedOrigin: .files,
            prepared: prepared
        )
    }

    func performFiles(
        context: AgentPolicyMutationExecutionContext,
        operation: FilesPolicyMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        let prepared = try prepare(context, engineVersion: .agentHarnessV2)
        return try sanitize(
            try await prepared.system.performFiles(
                context: prepared.localContext,
                operation: operation
            ),
            expectedOrigin: .files,
            prepared: prepared
        )
    }

    func performTerminal(
        context: AgentPolicyMutationExecutionContext,
        operation: TerminalCanonicalMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        let prepared = try prepare(context, engineVersion: .agentHarnessV2)
        return try sanitize(
            try await prepared.system.performTerminal(
                context: prepared.localContext,
                operation: operation
            ),
            expectedOrigin: .terminal,
            prepared: prepared
        )
    }

    func performArtifact(
        context: AgentPolicyMutationExecutionContext,
        operation: ArtifactCanonicalMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        let prepared = try prepare(context, engineVersion: .agentHarnessV2)
        return try sanitize(
            try await prepared.system.performArtifact(
                context: prepared.localContext,
                operation: operation
            ),
            expectedOrigin: .artifact,
            prepared: prepared
        )
    }

    func performControl(
        context: AgentPolicyMutationExecutionContext,
        operation: ControlPolicyMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        let prepared = try prepare(context, engineVersion: .agentHarnessV2)
        return try sanitize(
            try await prepared.system.performControl(
                context: prepared.localContext,
                operation: operation
            ),
            expectedOrigin: .control,
            prepared: prepared
        )
    }

    func performProjectOS(
        context: AgentPolicyMutationExecutionContext,
        operation: ProjectOSCanonicalMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        let prepared = try prepare(context, engineVersion: .agentHarnessV2)
        return try sanitize(
            try await prepared.system.performProjectOS(
                context: prepared.localContext,
                operation: operation
            ),
            expectedOrigin: .projectOS,
            prepared: prepared
        )
    }

    func performProjectOS(
        context: AgentPolicyMutationExecutionContext,
        operation: ProjectOSPolicyMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        let prepared = try prepare(context, engineVersion: .agentHarnessV2)
        return try sanitize(
            try await prepared.system.performProjectOS(
                context: prepared.localContext,
                operation: operation
            ),
            expectedOrigin: .projectOS,
            prepared: prepared
        )
    }

    func performTrustedSystem(
        context: AgentPolicyMutationExecutionContext,
        operation: TrustedSystemCanonicalMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        let prepared = try prepare(context, engineVersion: .agentHarnessV2)
        return try sanitize(
            try await prepared.system.performTrustedSystem(
                context: prepared.localContext,
                operation: operation
            ),
            expectedOrigin: .trustedSystem,
            prepared: prepared
        )
    }

    func performTrustedSystem(
        context: AgentPolicyMutationExecutionContext,
        operation: TrustedSystemPolicyMutationOperation
    ) async throws -> AgentPolicyMutationReceipt {
        let prepared = try prepare(context, engineVersion: .agentHarnessV2)
        return try sanitize(
            try await prepared.system.performTrustedSystem(
                context: prepared.localContext,
                operation: operation
            ),
            expectedOrigin: .trustedSystem,
            prepared: prepared
        )
    }

    private func prepare(
        _ context: AgentPolicyMutationExecutionContext,
        engineVersion: EngineVersion
    ) throws -> PreparedRequest {
        let cached = try cachedSystem(for: context.workspace)
        let runContext = AgentRunContext(
            schemaVersion: .current,
            lineage: context.lineage,
            conversationID: context.conversationID,
            projectID: context.projectID,
            workspaceID: cached.binding.workspaceID,
            executionNodeID: context.executionNodeID,
            engineVersion: engineVersion,
            acceptedAt: context.acceptedAt,
            features: context.features,
            cancellation: context.cancellation,
            initialBudget: context.initialBudget
        )
        let scope = try AgentPolicyMutationScope(
            runContext: runContext,
            workspaceBinding: cached.binding,
            sessionID: context.sessionID,
            backend: context.backend
        )
        let localContext = AgentPolicyLocalMutationContext(
            scope: scope,
            callID: context.callID,
            operationAttemptID: context.operationAttemptID,
            idempotencyKey: context.idempotencyKey
        )
        return PreparedRequest(
            system: cached.system,
            scope: scope,
            localContext: localContext,
            executionContext: context
        )
    }

    private func cachedSystem(
        for workspace: SandboxWorkspace
    ) throws -> CachedSystem {
        let canonicalRootPath = try Self.canonicalRootPath(for: workspace)
        let binding = try bindingFactory(workspace)
        guard try Self.canonicalRootPath(for: binding.workspace)
                == canonicalRootPath
        else {
            throw AgentPolicyMutationCoordinatorError.workspaceBindingMismatch
        }

        if let existing = systems[binding.resourceIdentity] {
            guard existing.canonicalRootPath == canonicalRootPath,
                  existing.binding == binding
            else {
                throw AgentPolicyMutationCoordinatorError
                    .workspaceIdentityCollision
            }
            return existing
        }

        // No await occurs before this synchronous factory returns and the
        // cache entry is committed. Actor reentrancy therefore cannot start a
        // duplicate construction for this canonical workspace identity.
        let system = try systemFactory(
            configuration,
            binding,
            approvalPrompt
        )
        guard system.workspaceBinding == binding,
              try Self.canonicalRootPath(
                for: system.workspaceBinding.workspace
              ) == canonicalRootPath
        else {
            throw AgentPolicyMutationCoordinatorError.systemBindingMismatch
        }
        let entry = CachedSystem(
            canonicalRootPath: canonicalRootPath,
            binding: binding,
            system: system
        )
        systems[binding.resourceIdentity] = entry
        return entry
    }

    private func validateProviderInvocation(
        _ invocation: ToolInvocation,
        context: AgentPolicyMutationExecutionContext
    ) throws {
        guard invocation.callID == context.callID,
              invocation.modelAttemptID == context.operationAttemptID,
              invocation.idempotencyKey == context.idempotencyKey
        else {
            throw AgentPolicyMutationCoordinatorError
                .providerInvocationIdentityMismatch
        }
    }

    private func sanitize(
        _ result: AgentPolicyCoordinatorUnclassifiedResult,
        expectedOrigin: MutationOrigin,
        prepared: PreparedRequest
    ) throws -> AgentPolicyMutationReceipt {
        guard result.origin == expectedOrigin else {
            throw AgentPolicyMutationCoordinatorError.receiptOriginMismatch
        }
        let context = prepared.executionContext
        return AgentPolicyMutationReceipt(
            operationID: context.operationID,
            runID: prepared.scope.runID,
            conversationID: context.conversationID,
            projectID: context.projectID,
            workspaceID: prepared.scope.workspaceID,
            callID: context.callID,
            operationAttemptID: context.operationAttemptID,
            origin: result.origin,
            effectKeySHA256: result.effectKeySHA256,
            applicationSHA256: result.applicationSHA256,
            evidenceSHA256: result.evidenceSHA256,
            finalRecordSHA256: result.finalRecordSHA256,
            receiptSHA256: result.receiptSHA256
        )
    }

    private static func canonicalRootPath(
        for workspace: SandboxWorkspace
    ) throws -> String {
        let root = workspace.rootURL
        guard root.isFileURL,
              root.path.hasPrefix("/"),
              root.standardizedFileURL.path != "/"
        else {
            throw AgentPolicyMutationCoordinatorError.invalidWorkspace
        }
        return root.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
    }
}

private struct AgentPolicyProductionMutationSystem:
    AgentPolicyMutationSystemServing
{
    let system: AgentPolicySystem

    var workspaceBinding: AgentPolicyWorkspaceBinding {
        system.workspaceBinding
    }

    func performAgentV2(
        scope: AgentPolicyMutationScope,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        AgentPolicyCoordinatorUnclassifiedResult(
            try await system.mutationService.performAgentV2(
                scope: scope,
                descriptor: descriptor,
                invocation: invocation
            )
        )
    }

    func performV1Fallback(
        scope: AgentPolicyMutationScope,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        AgentPolicyCoordinatorUnclassifiedResult(
            try await system.mutationService.performV1Fallback(
                scope: scope,
                descriptor: descriptor,
                invocation: invocation
            )
        )
    }

    func performEditor(
        context: AgentPolicyLocalMutationContext,
        operation: EditorCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        AgentPolicyCoordinatorUnclassifiedResult(
            try await system.mutationService.performEditor(
                context: context,
                operation: operation
            )
        )
    }

    func performEditor(
        context: AgentPolicyLocalMutationContext,
        operation: EditorPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        AgentPolicyCoordinatorUnclassifiedResult(
            try await system.mutationService.performEditor(
                context: context,
                operation: operation
            )
        )
    }

    func performFiles(
        context: AgentPolicyLocalMutationContext,
        operation: FilesCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        AgentPolicyCoordinatorUnclassifiedResult(
            try await system.mutationService.performFiles(
                context: context,
                operation: operation
            )
        )
    }

    func performFiles(
        context: AgentPolicyLocalMutationContext,
        operation: FilesPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        AgentPolicyCoordinatorUnclassifiedResult(
            try await system.mutationService.performFiles(
                context: context,
                operation: operation
            )
        )
    }

    func performTerminal(
        context: AgentPolicyLocalMutationContext,
        operation: TerminalCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        AgentPolicyCoordinatorUnclassifiedResult(
            try await system.mutationService.performTerminal(
                context: context,
                operation: operation
            )
        )
    }

    func performArtifact(
        context: AgentPolicyLocalMutationContext,
        operation: ArtifactCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        AgentPolicyCoordinatorUnclassifiedResult(
            try await system.mutationService.performArtifact(
                context: context,
                operation: operation
            )
        )
    }

    func performControl(
        context: AgentPolicyLocalMutationContext,
        operation: ControlPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        AgentPolicyCoordinatorUnclassifiedResult(
            try await system.mutationService.performControl(
                context: context,
                operation: operation
            )
        )
    }

    func performProjectOS(
        context: AgentPolicyLocalMutationContext,
        operation: ProjectOSCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        AgentPolicyCoordinatorUnclassifiedResult(
            try await system.mutationService.performProjectOS(
                context: context,
                operation: operation
            )
        )
    }

    func performProjectOS(
        context: AgentPolicyLocalMutationContext,
        operation: ProjectOSPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        AgentPolicyCoordinatorUnclassifiedResult(
            try await system.mutationService.performProjectOS(
                context: context,
                operation: operation
            )
        )
    }

    func performTrustedSystem(
        context: AgentPolicyLocalMutationContext,
        operation: TrustedSystemCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        AgentPolicyCoordinatorUnclassifiedResult(
            try await system.mutationService.performTrustedSystem(
                context: context,
                operation: operation
            )
        )
    }

    func performTrustedSystem(
        context: AgentPolicyLocalMutationContext,
        operation: TrustedSystemPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        AgentPolicyCoordinatorUnclassifiedResult(
            try await system.mutationService.performTrustedSystem(
                context: context,
                operation: operation
            )
        )
    }
}

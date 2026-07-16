import AgentDomain
import AgentPolicy
import AgentTools
import Foundation

enum AgentPolicySystemError: Error, Equatable, Sendable {
    case invalidPolicyConfiguration
    case protectedStorageUnavailable
    case signingKeyUnavailable
    case durableAuthorityStoreUnavailable
    case durableLifecycleStoreUnavailable
    case invalidWorkspaceComposition
    case approvalAuthorityUnavailable
    case invalidComposition
}

/// Target resolution implementations used by the production policy system
/// must declare the frozen workspace identity they are anchored to.
protocol AgentPolicyWorkspaceBoundTargetResolutionBackend:
    WorkspaceTargetResolutionBackend
{
    var agentPolicyWorkspaceResourceIdentity: WorkspaceResourceIdentity { get }
}

/// Checkpoints must be bound both to the same workspace and to the exact
/// protected directory returned by AgentPolicyStorePaths.prepare().
protocol AgentPolicyWorkspaceBoundCheckpointing: MutationEffectCheckpointing {
    var agentPolicyWorkspaceResourceIdentity: WorkspaceResourceIdentity { get }
    var agentPolicyCheckpointDirectory: URL { get }
}

/// Effect application must be anchored to the same frozen workspace identity
/// used by target resolution and checkpointing.
protocol AgentPolicyWorkspaceBoundApplying: MutationEffectApplying {
    var agentPolicyWorkspaceResourceIdentity: WorkspaceResourceIdentity { get }
}

typealias AgentPolicyTargetBackendFactory = @Sendable (
    AgentPolicyWorkspaceBinding
) throws -> any AgentPolicyWorkspaceBoundTargetResolutionBackend

typealias AgentPolicyCheckpointFactory = @Sendable (
    AgentPolicyWorkspaceBinding,
    URL
) throws -> any AgentPolicyWorkspaceBoundCheckpointing

typealias AgentPolicyEffectApplierFactory = @Sendable (
    AgentPolicyWorkspaceBinding
) throws -> any AgentPolicyWorkspaceBoundApplying

enum AgentPolicyWorkspaceComposition {
    static func validate(
        binding: AgentPolicyWorkspaceBinding,
        targetIdentity: WorkspaceResourceIdentity,
        checkpointIdentity: WorkspaceResourceIdentity,
        checkpointDirectory: URL,
        applierIdentity: WorkspaceResourceIdentity,
        protectedCheckpointDirectory: URL
    ) throws {
        let expectedIdentity = binding.resourceIdentity
        guard targetIdentity == expectedIdentity,
              checkpointIdentity == expectedIdentity,
              checkpointDirectory.standardizedFileURL
                == protectedCheckpointDirectory.standardizedFileURL,
              applierIdentity == expectedIdentity
        else {
            throw AgentPolicySystemError.invalidWorkspaceComposition
        }
    }
}

enum AgentPolicyGatewayComposition {
    static func validate(
        executionIdentity: ObjectIdentifier,
        recoveryIdentity: ObjectIdentifier
    ) throws {
        guard executionIdentity == recoveryIdentity else {
            throw AgentPolicySystemError.invalidComposition
        }
    }
}

/// Production ownership root for the AgentPolicy mutation chain. Construction
/// is all-or-nothing: no partially composed service escapes when protected
/// storage, key material, workspace binding, or an authority fails validation.
struct AgentPolicySystem: Sendable {
    let mutationService: AgentPolicyMutationService

    let workspaceBinding: AgentPolicyWorkspaceBinding
    let storePaths: AgentPolicyStorePaths
    let policyRevisionAuthority: PolicyRevisionAuthority
    let policyAuthorityStore: FilePolicyAuthorityStore
    let targetAuthority: WorkspaceTargetResolverAuthority
    let approvalAuthority: DurableApprovalAuthority
    let effectClaimAuthority: ToolEffectClaimAuthority
    let mutationLifecycleStore: FileMutationEffectLifecycleStore
    let mutationGatewayAuthority: AgentPolicyMutationGatewayAuthority

    /// Sealed recovery against the same gateway, lifecycle store, FIFO, and
    /// process arbiter used by normal execution. No permit is reminted and no
    /// caller-provided effect can run from this entry point.
    func recoverMutation(
        effectKeySHA256: SHA256Digest
    ) async throws -> AgentPolicyMutationRecoveryDisposition {
        guard !Task.isCancelled else {
            throw AgentPolicyMutationServiceError.cancelled
        }
        do {
            return try await mutationGatewayAuthority.recover(
                effectKeySHA256: effectKeySHA256
            )
        } catch is CancellationError {
            throw AgentPolicyMutationServiceError.cancelled
        } catch {
            throw AgentPolicyMutationServiceError.recoveryFailed
        }
    }

    /// Builds one workspace-scoped production system. The package gateway owns
    /// its process-wide FIFO and, because `mutationLifecycleStore` is the file
    /// store, consumes that store's OS-backed process arbiter. A second,
    /// disconnected coordinator is intentionally not created here.
    static func production(
        configuration: RiskPolicyConfiguration,
        workspaceBinding: AgentPolicyWorkspaceBinding,
        approvalPrompt: any ApprovalDecisionPrompting,
        targetBackendFactory: AgentPolicyTargetBackendFactory,
        checkpointFactory: AgentPolicyCheckpointFactory,
        effectApplierFactory: AgentPolicyEffectApplierFactory,
        advisory: (any RiskPolicyAdvisoryTransport)? = nil,
        clock: any PolicyClock = SystemPolicyClock(),
        synchronousClock: any MutationEffectSynchronousClock =
            SystemMutationEffectSynchronousClock(),
        approvalLifetimeMilliseconds: UInt64 = 300_000,
        storeFileSystem: any AgentPolicyStoreFileSystem =
            AgentPolicyDefaultStoreFileSystem(),
        signingKeyStore: AgentApprovalSigningKeyStore =
            AgentApprovalSigningKeyStore()
    ) throws -> Self {
        let policyRevisionAuthority: PolicyRevisionAuthority
        do {
            policyRevisionAuthority = try PolicyRevisionAuthority(
                configuration: configuration
            )
        } catch {
            throw AgentPolicySystemError.invalidPolicyConfiguration
        }

        let paths: AgentPolicyStorePaths
        do {
            paths = try AgentPolicyStorePaths.prepare(
                fileSystem: storeFileSystem
            )
        } catch {
            throw AgentPolicySystemError.protectedStorageUnavailable
        }

        let signingKey: AgentApprovalSigningKey
        do {
            signingKey = try signingKeyStore.readOrCreateKey()
        } catch {
            throw AgentPolicySystemError.signingKeyUnavailable
        }

        let policyStore: FilePolicyAuthorityStore
        do {
            policyStore = try FilePolicyAuthorityStore(
                fileURL: paths.policyAuthorityLedgerURL
            )
        } catch {
            throw AgentPolicySystemError.durableAuthorityStoreUnavailable
        }

        let lifecycleStore: FileMutationEffectLifecycleStore
        do {
            lifecycleStore = try FileMutationEffectLifecycleStore(
                fileURL: paths.mutationEffectLifecycleLedgerURL
            )
        } catch {
            throw AgentPolicySystemError.durableLifecycleStoreUnavailable
        }

        let targetBackend: any AgentPolicyWorkspaceBoundTargetResolutionBackend
        let checkpointer: any AgentPolicyWorkspaceBoundCheckpointing
        let applier: any AgentPolicyWorkspaceBoundApplying
        do {
            targetBackend = try targetBackendFactory(workspaceBinding)
            checkpointer = try checkpointFactory(
                workspaceBinding,
                paths.checkpointDirectory
            )
            applier = try effectApplierFactory(workspaceBinding)
        } catch {
            throw AgentPolicySystemError.invalidWorkspaceComposition
        }

        try AgentPolicyWorkspaceComposition.validate(
            binding: workspaceBinding,
            targetIdentity:
                targetBackend.agentPolicyWorkspaceResourceIdentity,
            checkpointIdentity:
                checkpointer.agentPolicyWorkspaceResourceIdentity,
            checkpointDirectory:
                checkpointer.agentPolicyCheckpointDirectory,
            applierIdentity:
                applier.agentPolicyWorkspaceResourceIdentity,
            protectedCheckpointDirectory: paths.checkpointDirectory
        )

        let resolver = WorkspaceTargetResolverAuthority(
            trustedBackend: targetBackend
        )

        let trustedUIAuthority: TrustedApprovalUIAuthority
        do {
            trustedUIAuthority = try signingKey.withKeyData { keyData in
                try TrustedApprovalUIAuthority(
                    signingKey: keyData,
                    prompt: approvalPrompt,
                    clock: clock
                )
            }
        } catch {
            throw AgentPolicySystemError.approvalAuthorityUnavailable
        }

        let approvalAuthority = DurableApprovalAuthority(
            store: policyStore,
            clock: clock,
            resolver: resolver,
            uiAuthority: trustedUIAuthority,
            policyRevisionAuthority: policyRevisionAuthority
        )
        let claimAuthority = ToolEffectClaimAuthority(
            store: policyStore,
            clock: clock,
            resolver: resolver,
            policyRevisionAuthority: policyRevisionAuthority
        )

        let evaluator: LayeredRiskPolicyEvaluator
        let gateway: MutationEffectGateway
        let gatewayAuthority: AgentPolicyMutationGatewayAuthority
        let pipeline: AgentPolicyProductionMutationPipeline
        let service: AgentPolicyMutationService
        do {
            evaluator = try LayeredRiskPolicyEvaluator(
                policyRevisionAuthority: policyRevisionAuthority,
                clock: clock,
                resolver: resolver,
                grantStore: policyStore,
                advisory: advisory
            )
            gateway = try MutationEffectGateway(
                store: lifecycleStore,
                resolver: resolver,
                policyRevisionAuthority: policyRevisionAuthority,
                clock: synchronousClock,
                checkpointer: checkpointer,
                applier: applier
            )
            gatewayAuthority = AgentPolicyMutationGatewayAuthority(
                gateway: gateway
            )
            pipeline = try AgentPolicyProductionMutationPipeline(
                policyRevisionAuthority: policyRevisionAuthority,
                resolver: resolver,
                evaluator: evaluator,
                approvalAuthority: approvalAuthority,
                approvalStore: policyStore,
                claimAuthority: claimAuthority,
                gatewayAuthority: gatewayAuthority,
                approvalLifetimeMilliseconds: approvalLifetimeMilliseconds
            )
            service = try AgentPolicyMutationService(
                policyRevisionAuthority: policyRevisionAuthority,
                workspaceBinding: workspaceBinding,
                pipeline: pipeline
            )
            try AgentPolicyGatewayComposition.validate(
                executionIdentity: ObjectIdentifier(
                    pipeline.gatewayAuthority
                ),
                recoveryIdentity: ObjectIdentifier(gatewayAuthority)
            )
        } catch {
            throw AgentPolicySystemError.invalidComposition
        }

        guard service.isBound(to: policyRevisionAuthority) else {
            throw AgentPolicySystemError.invalidComposition
        }

        return Self(
            mutationService: service,
            workspaceBinding: workspaceBinding,
            storePaths: paths,
            policyRevisionAuthority: policyRevisionAuthority,
            policyAuthorityStore: policyStore,
            targetAuthority: resolver,
            approvalAuthority: approvalAuthority,
            effectClaimAuthority: claimAuthority,
            mutationLifecycleStore: lifecycleStore,
            mutationGatewayAuthority: gatewayAuthority
        )
    }

    /// Concrete fd-anchored production composition. One frozen root provider
    /// is shared by target resolution, checkpoint capture, and effect apply;
    /// the checkpoint adapter receives only the protected directory prepared
    /// by `AgentPolicyStorePaths` inside `production`.
    static func productionPOSIX(
        configuration: RiskPolicyConfiguration,
        workspaceBinding: AgentPolicyWorkspaceBinding,
        approvalPrompt: any ApprovalDecisionPrompting,
        advisory: (any RiskPolicyAdvisoryTransport)? = nil,
        clock: any PolicyClock = SystemPolicyClock(),
        synchronousClock: any MutationEffectSynchronousClock =
            SystemMutationEffectSynchronousClock(),
        approvalLifetimeMilliseconds: UInt64 = 300_000,
        storeFileSystem: any AgentPolicyStoreFileSystem =
            AgentPolicyDefaultStoreFileSystem(),
        signingKeyStore: AgentApprovalSigningKeyStore =
            AgentApprovalSigningKeyStore()
    ) throws -> Self {
        let roots: AgentPolicySharedWorkspaceRootProvider
        do {
            roots = AgentPolicySharedWorkspaceRootProvider(
                bound: try BoundAgentWorkspaceRootProvider(
                    workspaceID: workspaceBinding.workspaceID,
                    rootURL: workspaceBinding.workspace.rootURL
                )
            )
        } catch {
            throw AgentPolicySystemError.invalidWorkspaceComposition
        }

        return try production(
            configuration: configuration,
            workspaceBinding: workspaceBinding,
            approvalPrompt: approvalPrompt,
            targetBackendFactory: { candidate in
                guard candidate == workspaceBinding else {
                    throw AgentPolicySystemError.invalidWorkspaceComposition
                }
                return AgentPolicyBoundPOSIXTargetBackend(
                    resourceIdentity: candidate.resourceIdentity,
                    backend: POSIXWorkspaceTargetResolutionBackend(
                        roots: roots
                    )
                )
            },
            checkpointFactory: { candidate, protectedDirectory in
                guard candidate == workspaceBinding else {
                    throw AgentPolicySystemError.invalidWorkspaceComposition
                }
                return AgentPolicyBoundPOSIXCheckpointStore(
                    resourceIdentity: candidate.resourceIdentity,
                    protectedCheckpointDirectory: protectedDirectory,
                    checkpointStore: POSIXWorkspaceCheckpointStore(
                        roots: roots,
                        checkpointDirectory: protectedDirectory
                    )
                )
            },
            effectApplierFactory: { candidate in
                guard candidate == workspaceBinding else {
                    throw AgentPolicySystemError.invalidWorkspaceComposition
                }
                return AgentPolicyBoundPOSIXEffectBackend(
                    resourceIdentity: candidate.resourceIdentity,
                    effectBackend: POSIXWorkspaceEffectBackend(roots: roots)
                )
            },
            advisory: advisory,
            clock: clock,
            synchronousClock: synchronousClock,
            approvalLifetimeMilliseconds: approvalLifetimeMilliseconds,
            storeFileSystem: storeFileSystem,
            signingKeyStore: signingKeyStore
        )
    }
}

private final class AgentPolicySharedWorkspaceRootProvider:
    AgentWorkspaceRootProviding,
    Sendable
{
    private let bound: BoundAgentWorkspaceRootProvider

    init(bound: BoundAgentWorkspaceRootProvider) {
        self.bound = bound
    }

    func workspaceRootLocation(
        for workspaceID: WorkspaceID
    ) throws -> AgentWorkspaceRootLocation {
        try bound.workspaceRootLocation(for: workspaceID)
    }
}

private struct AgentPolicyBoundPOSIXTargetBackend:
    AgentPolicyWorkspaceBoundTargetResolutionBackend
{
    let agentPolicyWorkspaceResourceIdentity: WorkspaceResourceIdentity
    let backend: POSIXWorkspaceTargetResolutionBackend

    init(
        resourceIdentity: WorkspaceResourceIdentity,
        backend: POSIXWorkspaceTargetResolutionBackend
    ) {
        agentPolicyWorkspaceResourceIdentity = resourceIdentity
        self.backend = backend
    }

    func resolveTargets(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        workspaceID: WorkspaceID
    ) async throws -> WorkspaceResolutionCandidate {
        try await backend.resolveTargets(
            descriptor: descriptor,
            invocation: invocation,
            workspaceID: workspaceID
        )
    }
}

private struct AgentPolicyBoundPOSIXCheckpointStore:
    AgentPolicyWorkspaceBoundCheckpointing
{
    let agentPolicyWorkspaceResourceIdentity: WorkspaceResourceIdentity
    let agentPolicyCheckpointDirectory: URL
    let checkpointStore: POSIXWorkspaceCheckpointStore

    init(
        resourceIdentity: WorkspaceResourceIdentity,
        protectedCheckpointDirectory: URL,
        checkpointStore: POSIXWorkspaceCheckpointStore
    ) {
        agentPolicyWorkspaceResourceIdentity = resourceIdentity
        agentPolicyCheckpointDirectory = protectedCheckpointDirectory
        self.checkpointStore = checkpointStore
    }

    func checkpoint(
        _ request: MutationEffectCheckpointRequest
    ) throws -> MutationEffectCheckpointResult {
        try checkpointStore.checkpoint(request)
    }
}

private struct AgentPolicyBoundPOSIXEffectBackend:
    AgentPolicyWorkspaceBoundApplying
{
    let agentPolicyWorkspaceResourceIdentity: WorkspaceResourceIdentity
    let effectBackend: POSIXWorkspaceEffectBackend

    init(
        resourceIdentity: WorkspaceResourceIdentity,
        effectBackend: POSIXWorkspaceEffectBackend
    ) {
        agentPolicyWorkspaceResourceIdentity = resourceIdentity
        self.effectBackend = effectBackend
    }

    func apply(
        _ operation: MutationEffectOperation,
        authorization: borrowing MutationEffectApplicationAuthorization
    ) throws -> MutationEffectApplicationResult {
        try effectBackend.apply(
            operation,
            authorization: authorization
        )
    }
}

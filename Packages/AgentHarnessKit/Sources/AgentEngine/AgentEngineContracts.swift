import AgentDomain
import AgentPolicy
import AgentProviders
import AgentStore
import AgentTools
import Foundation

/// Stable ownership mode for one live event-writer lease.
public enum AgentEngineRunClaimMode: String, Codable, Sendable {
    case newRun
    /// This mode may replace an abandoned nonterminal owner. A durable host
    /// must expose it only after its process/lease election proves the prior
    /// writer cannot still commit.
    case recovery
}

public struct AgentEngineOwnerFence: Codable, Equatable, Hashable, Sendable {
    public let runID: RunID
    public let ownerID: UUID
    public let generation: UInt64

    public init(runID: RunID, ownerID: UUID, generation: UInt64) {
        self.runID = runID
        self.ownerID = ownerID
        self.generation = generation
    }
}

public struct AgentEngineTerminalRecord: Codable, Equatable, Sendable {
    public let runID: RunID
    public let fence: AgentEngineOwnerFence
    public let phase: AgentRunPhase
    public let terminalEventID: EventID

    public init(
        runID: RunID,
        fence: AgentEngineOwnerFence,
        phase: AgentRunPhase,
        terminalEventID: EventID
    ) {
        self.runID = runID
        self.fence = fence
        self.phase = phase
        self.terminalEventID = terminalEventID
    }
}

/// Durable run ownership/terminal index. Implementations are expected to join
/// claim election to their process lease. Engine callbacks validate this fence
/// before every append and again after every external await.
public protocol AgentEngineRunIndexing: Sendable {
    func claim(
        runID: RunID,
        ownerID: UUID,
        mode: AgentEngineRunClaimMode
    ) async throws -> AgentEngineOwnerFence

    func validate(_ fence: AgentEngineOwnerFence) async throws
    func abandon(_ fence: AgentEngineOwnerFence) async
    func settle(_ record: AgentEngineTerminalRecord) async throws
}

public enum AgentEngineRunIndexError: Error, Equatable, Sendable {
    case ownerAlreadyActive(RunID)
    case staleOwner(AgentEngineOwnerFence)
    case runAlreadyTerminal(RunID)
    case generationExhausted(RunID)
    case invalidTerminalPhase(AgentRunPhase)
}

/// Deterministic reference index used by package tests and single-process
/// hosts. Persistent apps should provide a process-safe durable adapter.
public actor InMemoryAgentEngineRunIndex: AgentEngineRunIndexing {
    private struct Entry: Sendable {
        var fence: AgentEngineOwnerFence
        var terminal: AgentEngineTerminalRecord?
    }

    private var entries: [RunID: Entry] = [:]

    public init() {}

    public func claim(
        runID: RunID,
        ownerID: UUID,
        mode: AgentEngineRunClaimMode
    ) throws -> AgentEngineOwnerFence {
        if let existing = entries[runID] {
            guard existing.terminal == nil else {
                throw AgentEngineRunIndexError.runAlreadyTerminal(runID)
            }
            guard mode == .recovery else {
                throw AgentEngineRunIndexError.ownerAlreadyActive(runID)
            }
            guard existing.fence.generation < UInt64.max else {
                throw AgentEngineRunIndexError.generationExhausted(runID)
            }
            let replacement = AgentEngineOwnerFence(
                runID: runID,
                ownerID: ownerID,
                generation: existing.fence.generation + 1
            )
            entries[runID] = Entry(fence: replacement, terminal: nil)
            return replacement
        }
        let fence = AgentEngineOwnerFence(
            runID: runID,
            ownerID: ownerID,
            generation: 1
        )
        entries[runID] = Entry(fence: fence, terminal: nil)
        return fence
    }

    public func validate(_ fence: AgentEngineOwnerFence) throws {
        guard let entry = entries[fence.runID],
              entry.fence == fence,
              entry.terminal == nil
        else { throw AgentEngineRunIndexError.staleOwner(fence) }
    }

    public func abandon(_ fence: AgentEngineOwnerFence) {
        guard entries[fence.runID]?.fence == fence,
              entries[fence.runID]?.terminal == nil
        else { return }
        entries.removeValue(forKey: fence.runID)
    }

    public func settle(_ record: AgentEngineTerminalRecord) throws {
        guard record.phase.isTerminal else {
            throw AgentEngineRunIndexError.invalidTerminalPhase(record.phase)
        }
        guard var entry = entries[record.runID], entry.fence == record.fence else {
            throw AgentEngineRunIndexError.staleOwner(record.fence)
        }
        if let terminal = entry.terminal {
            guard terminal == record else {
                throw AgentEngineRunIndexError.runAlreadyTerminal(record.runID)
            }
            return
        }
        entry.terminal = record
        entries[record.runID] = entry
    }

    public func terminalRecord(for runID: RunID) -> AgentEngineTerminalRecord? {
        entries[runID]?.terminal
    }
}

public protocol AgentEngineClock: Sendable {
    func now() async throws -> AgentInstant
    func sleep(milliseconds: UInt64) async throws
}

public struct SystemAgentEngineClock: AgentEngineClock, Sendable {
    public init() {}

    public func now() async throws -> AgentInstant { AgentInstant(Date()) }

    public func sleep(milliseconds: UInt64) async throws {
        let bounded = min(milliseconds, UInt64.max / 1_000_000)
        try await Task.sleep(nanoseconds: bounded * 1_000_000)
    }
}

public protocol AgentEngineIdentitySource: Sendable {
    func nextUUID() async throws -> UUID
    func recoverySeed(runID: RunID, attemptOrdinal: UInt32) async throws -> UInt64
}

public struct SystemAgentEngineIdentitySource: AgentEngineIdentitySource, Sendable {
    public init() {}
    public func nextUUID() async throws -> UUID { UUID() }
    public func recoverySeed(runID: RunID, attemptOrdinal: UInt32) async throws -> UInt64 {
        // Stable, credential/content-free FNV-1a material. The domain string
        // prevents this seed from being reused as another identity/digest.
        let material = "novaforge-agent-provider-recovery-seed-v1|"
            + runID.description + "|" + String(attemptOrdinal)
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in material.utf8 {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01b3
        }
        return value
    }
}

/// Complete provider turn prepared from the replayable state. The authority
/// may compact/context-select, but cannot dispatch provider or tool work.
public struct AgentPreparedProviderTurn: Sendable {
    public let request: CanonicalProviderRequest
    public let preferredAdapterIDs: [ProviderAdapterID]
    public let itemIDs: [ModelItemID]
    public let estimatedTokens: UInt64
    public let contextDigest: AgentCanonicalSHA256Digest
    public let toolLocalities: [String: ToolExecutionLocality]

    public init(
        request: CanonicalProviderRequest,
        preferredAdapterIDs: [ProviderAdapterID],
        itemIDs: [ModelItemID],
        estimatedTokens: UInt64,
        contextDigest: AgentCanonicalSHA256Digest,
        toolLocalities: [String: ToolExecutionLocality] = [:]
    ) {
        self.request = request
        self.preferredAdapterIDs = preferredAdapterIDs
        self.itemIDs = itemIDs
        self.estimatedTokens = estimatedTokens
        self.contextDigest = contextDigest
        self.toolLocalities = toolLocalities
    }
}

public protocol AgentContextPreparing: Sendable {
    func prepareProviderTurn(
        state: AgentRunState,
        tools: [ToolDescriptor]
    ) async throws -> AgentPreparedProviderTurn
}

public struct AgentReadOnlyToolRequest: Sendable {
    public let context: AgentRunContext
    public let invocation: ToolInvocation
    public let descriptor: ToolDescriptor
    public let decodedArguments: DecodedToolArguments

    public init(
        context: AgentRunContext,
        invocation: ToolInvocation,
        descriptor: ToolDescriptor,
        decodedArguments: DecodedToolArguments
    ) {
        self.context = context
        self.invocation = invocation
        self.descriptor = descriptor
        self.decodedArguments = decodedArguments
    }
}

/// Provider-visible read result. App adapters remain responsible for their
/// existing output classification/redaction boundary before constructing it.
public struct AgentReadOnlyToolOutput: Equatable, Sendable {
    public let output: JSONValue
    public let artifacts: [ArtifactReference]
    public let evidence: [ToolEvidence]
    public let warnings: [String]

    public init(
        output: JSONValue,
        artifacts: [ArtifactReference] = [],
        evidence: [ToolEvidence] = [],
        warnings: [String] = []
    ) {
        self.output = output
        self.artifacts = artifacts
        self.evidence = evidence
        self.warnings = warnings
    }
}

public protocol AgentReadOnlyToolExecuting: Sendable {
    func executeReadOnly(
        _ request: AgentReadOnlyToolRequest
    ) async throws -> AgentReadOnlyToolOutput
}

/// Durable, idempotent policy preparation. `authorityToken` is an opaque
/// non-secret lookup key; callers cannot convert it into effect authority.
public struct AgentMutationPreparation: Equatable, Sendable {
    public let runID: RunID
    public let workspaceID: WorkspaceID
    public let callID: ToolCallID
    public let canonicalArgumentDigest: String
    public let authorityToken: String
    public let effectKeySHA256: SHA256Digest
    public let approvalRequest: ApprovalRequest?

    let engineSeal: UUID

    init(
        runID: RunID,
        workspaceID: WorkspaceID,
        callID: ToolCallID,
        canonicalArgumentDigest: String,
        authorityToken: String,
        effectKeySHA256: SHA256Digest,
        approvalRequest: ApprovalRequest? = nil,
        engineSeal: UUID
    ) {
        self.runID = runID
        self.workspaceID = workspaceID
        self.callID = callID
        self.canonicalArgumentDigest = canonicalArgumentDigest
        self.authorityToken = authorityToken
        self.effectKeySHA256 = effectKeySHA256
        self.approvalRequest = approvalRequest
        self.engineSeal = engineSeal
    }
}

/// Engine-minted construction capability supplied only during policy
/// preparation. It prevents callers from fabricating a preparation and then
/// presenting its token to the apply seam. The policy adapter must still bind
/// and validate its own opaque `authorityToken` durably.
public struct AgentMutationPreparationSealer: Sendable {
    let seal: UUID

    init(seal: UUID) { self.seal = seal }

    public func seal(
        runID: RunID,
        workspaceID: WorkspaceID,
        callID: ToolCallID,
        canonicalArgumentDigest: String,
        authorityToken: String,
        effectKeySHA256: SHA256Digest,
        approvalRequest: ApprovalRequest? = nil
    ) -> AgentMutationPreparation {
        AgentMutationPreparation(
            runID: runID,
            workspaceID: workspaceID,
            callID: callID,
            canonicalArgumentDigest: canonicalArgumentDigest,
            authorityToken: authorityToken,
            effectKeySHA256: effectKeySHA256,
            approvalRequest: approvalRequest,
            engineSeal: seal
        )
    }
}

/// Copyable content-addressed projection of the consuming M6 receipt.
public struct AgentMutationReceipt: Equatable, Sendable {
    public let effectKeySHA256: SHA256Digest
    public let applicationSHA256: SHA256Digest
    public let evidenceSHA256: SHA256Digest
    public let finalRecordSHA256: SHA256Digest
    public let receiptSHA256: SHA256Digest

    public init(_ receipt: MutationEffectExecutionReceipt) {
        effectKeySHA256 = receipt.effectKeySHA256
        applicationSHA256 = receipt.applicationSHA256
        evidenceSHA256 = receipt.evidenceSHA256
        finalRecordSHA256 = receipt.finalRecordSHA256
        receiptSHA256 = receipt.receiptSHA256
    }

    public init(
        effectKeySHA256: SHA256Digest,
        applicationSHA256: SHA256Digest,
        evidenceSHA256: SHA256Digest,
        finalRecordSHA256: SHA256Digest,
        receiptSHA256: SHA256Digest
    ) {
        self.effectKeySHA256 = effectKeySHA256
        self.applicationSHA256 = applicationSHA256
        self.evidenceSHA256 = evidenceSHA256
        self.finalRecordSHA256 = finalRecordSHA256
        self.receiptSHA256 = receiptSHA256
    }
}

/// Classified provider result plus the exact M6 settlement references.
public struct AgentMutationToolOutput: Equatable, Sendable {
    public let receipt: AgentMutationReceipt
    public let output: JSONValue
    public let artifacts: [ArtifactReference]
    public let evidence: [ToolEvidence]
    public let warnings: [String]

    public init(
        receipt: AgentMutationReceipt,
        output: JSONValue,
        artifacts: [ArtifactReference] = [],
        evidence: [ToolEvidence] = [],
        warnings: [String] = []
    ) {
        self.receipt = receipt
        self.output = output
        self.artifacts = artifacts
        self.evidence = evidence
        self.warnings = warnings
    }
}

public enum AgentMutationRecoveryDisposition: Equatable, Sendable {
    /// M6 proves the effect and evidence are settled; completing the semantic
    /// tool result is safe and does not apply the effect again.
    case settled(AgentMutationToolOutput)
    /// Pending/ambiguous M6 work is never replayed by the engine.
    case reconciliationRequired(SHA256Digest)
    /// No durable M6 record exists, but a semantic `toolStarted` makes the
    /// boundary ambiguous. The engine still interrupts rather than applying.
    case noDurableRecord
}

public protocol AgentMutationPolicyExecuting: Sendable {
    func prepareMutation(
        context: AgentRunContext,
        invocation: ToolInvocation,
        descriptor: ToolDescriptor,
        sealer: AgentMutationPreparationSealer
    ) async throws -> AgentMutationPreparation

    func applyMutation(
        preparation: AgentMutationPreparation,
        approval: ApprovalResolution?
    ) async throws -> AgentMutationToolOutput

    func recoverMutation(
        context: AgentRunContext,
        invocation: ToolInvocation,
        effectKeySHA256: SHA256Digest
    ) async throws -> AgentMutationRecoveryDisposition
}

/// Approval decisions cross as full request-bound resolutions, never as a
/// boolean/scalar grant.
public protocol AgentApprovalResolving: Sendable {
    func resolveApproval(_ request: ApprovalRequest) async throws -> ApprovalResolution

    /// Concurrent broker handoff used while `resolveApproval` is suspended.
    /// Implementations bind the command to the exact request and return only
    /// after their trusted durable approval authority accepts the decision.
    func deliverApprovalDecision(
        _ command: ApprovalDecisionCommand,
        for request: ApprovalRequest
    ) async throws
}

public protocol AgentCancellationPropagating: Sendable {
    func propagateCancellation(
        runID: RunID,
        lineage: CancellationLineage,
        reason: AgentCancellationReason,
        toDescendants: Bool
    ) async
}

/// The only provisional provider output allowed to leave `AgentEngine` for
/// live presentation. The type intentionally cannot carry reasoning, tool
/// names or arguments, provider frames, usage, credentials, or raw errors.
/// Every value is emitted only after the attempt scope and event sequence have
/// passed the provider contract checks.
public struct AgentLiveTextDelta: Equatable, Sendable {
    public let runID: RunID
    public let attemptID: AttemptID
    public let eventSequence: UInt64
    public let outputIndex: Int
    public let text: String

    public init(
        runID: RunID,
        attemptID: AttemptID,
        eventSequence: UInt64,
        outputIndex: Int,
        text: String
    ) {
        self.runID = runID
        self.attemptID = attemptID
        self.eventSequence = eventSequence
        self.outputIndex = outputIndex
        self.text = text
    }
}

/// Presentation is observational and cannot fail or authorize the run. An
/// awaited sink preserves provider order and applies bounded backpressure
/// instead of creating an unbounded task for every token fragment.
public protocol AgentLiveOutputSink: Sendable {
    func receive(_ delta: AgentLiveTextDelta) async
}

public struct NoopAgentLiveOutputSink: AgentLiveOutputSink, Sendable {
    public init() {}
    public func receive(_ delta: AgentLiveTextDelta) async {}
}

public struct NoopAgentCancellationPropagator:
    AgentCancellationPropagating,
    Sendable
{
    public init() {}
    public func propagateCancellation(
        runID: RunID,
        lineage: CancellationLineage,
        reason: AgentCancellationReason,
        toDescendants: Bool
    ) async {}
}

public struct AgentEngineConfiguration: Sendable {
    public let recoveryPolicy: ProviderRecoveryPolicy
    public let maximumModelRounds: UInt32

    public init(
        recoveryPolicy: ProviderRecoveryPolicy = .hermesBaseline,
        maximumModelRounds: UInt32 = 128
    ) {
        self.recoveryPolicy = recoveryPolicy
        self.maximumModelRounds = max(1, maximumModelRounds)
    }
}

public struct AgentEngineRunHandle: Equatable, Sendable {
    public let runID: RunID
    public let ownerFence: AgentEngineOwnerFence

    public init(runID: RunID, ownerFence: AgentEngineOwnerFence) {
        self.runID = runID
        self.ownerFence = ownerFence
    }
}

public enum AgentEngineError: Error, Equatable, Sendable {
    case engineAlreadyOwnsRun(RunID)
    case noOwnedRun
    case runMismatch(expected: RunID, actual: RunID)
    case invalidCommand
    case unsupportedSchema(AgentSchemaVersion)
    case invalidPreparedContext
    case noProviderRoute
    case providerContract(String)
    case providerFailed(AgentErrorInfo)
    case toolContract(String)
    case mutationBindingMismatch(ToolCallID)
    case mutationReceiptMismatch(ToolCallID)
    case approvalBindingMismatch(ApprovalRequestID)
    case unsafeRecovery(String)
    case reducerRejected(AgentInvariantFailure)
    case persistence(String)
    case staleOwner
    case cancelled
}

import AgentDomain
import AgentTools
import Foundation

func mutationEffectVisibleText(_ value: String) -> String {
    var result = ""
    for scalar in value.unicodeScalars {
        let category = scalar.properties.generalCategory
        if category == .format
            || category == .control
            || category == .lineSeparator
            || category == .paragraphSeparator {
            result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
        } else if scalar == "\\" {
            result += "\\\\"
        } else {
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}

public enum MutationEffectOperationBody: Codable, Equatable, Sendable {
    case writeFile(WriteFileArguments)
    case appendFile(AppendFileArguments)
    case replaceText(ReplaceTextArguments)
    case deletePath(PathArguments)
    case movePath(MovePathArguments)
    case copyPath(MovePathArguments)
    case makeDirectory(PathArguments)
    case runCommand(RunCommandArguments)
    case createFile(CreateFileMutationArguments)
    case touchFile(TouchFileMutationArguments)
    case resetWorkspace(ResetWorkspaceMutationArguments)
    case seedWorkspace(SeedWorkspaceMutationArguments)
}

/// Canonical, ephemeral approval material derived from the same trusted
/// descriptor and sealed invocation that later produce the executable typed
/// operation. The exact arguments/change text are available to UI; the digest
/// prevents approval of one payload followed by dispatch of another. Persist
/// only `previewSHA256`; the exact plaintext may contain private file content.
public struct MutationEffectApprovalPreview:
    CustomDebugStringConvertible,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    public let origin: MutationOrigin
    public let tool: ToolIdentity
    public let effectClass: ToolEffectClass
    public let body: MutationEffectOperationBody
    public let exactArguments: JSONValue
    public let exactArgumentsJSON: String
    public let operationPayloadSHA256: SHA256Digest
    public let title: String
    public let previewSHA256: SHA256Digest

    public var description: String {
        "MutationEffectApprovalPreview(tool: \(tool.name)@\(tool.version), previewSHA256: \(previewSHA256), exactArguments: <redacted>)"
    }

    public var debugDescription: String { description }

    public var humanReadableChanges: [String] {
        switch body {
        case let .writeFile(arguments):
            [
                "Write \(arguments.contents.utf8.count) UTF-8 bytes to \(mutationEffectVisibleText(arguments.path)).",
                "Exact contents: \(mutationEffectVisibleText(arguments.contents))",
            ]
        case let .appendFile(arguments):
            [
                "Append \(arguments.contents.utf8.count) UTF-8 bytes to \(mutationEffectVisibleText(arguments.path)).",
                "Exact appended contents: \(mutationEffectVisibleText(arguments.contents))",
            ]
        case let .replaceText(arguments):
            [
                "Replace text in \(mutationEffectVisibleText(arguments.path))\(arguments.replaceAll == true ? " at every match" : " at one unambiguous match").",
                "Exact old text: \(mutationEffectVisibleText(arguments.old))",
                "Exact new text: \(mutationEffectVisibleText(arguments.new))",
            ]
        case let .deletePath(arguments):
            ["Delete the exact workspace path \(mutationEffectVisibleText(arguments.path))."]
        case let .movePath(arguments):
            ["Move \(mutationEffectVisibleText(arguments.from)) to \(mutationEffectVisibleText(arguments.to))."]
        case let .copyPath(arguments):
            ["Copy \(mutationEffectVisibleText(arguments.from)) to \(mutationEffectVisibleText(arguments.to))."]
        case let .makeDirectory(arguments):
            ["Create the exact workspace directory \(mutationEffectVisibleText(arguments.path))."]
        case let .runCommand(arguments):
            ["Run the exact sandbox command: \(mutationEffectVisibleText(arguments.command))"]
        case let .createFile(arguments):
            ["Create the exact workspace file \(mutationEffectVisibleText(arguments.path))."]
        case let .touchFile(arguments):
            ["Touch the exact workspace file \(mutationEffectVisibleText(arguments.path))."]
        case .resetWorkspace:
            ["Delete every child of the exact workspace root."]
        case let .seedWorkspace(arguments):
            [
                "Seed \(arguments.entries.count) exact workspace file(s).",
                "Exact paths: \(arguments.entries.map { mutationEffectVisibleText($0.path) }.joined(separator: ", "))",
            ]
        }
    }

    private struct DigestMaterial: Codable {
        let origin: MutationOrigin
        let tool: ToolIdentity
        let effectClass: ToolEffectClass
        let body: MutationEffectOperationBody
        let exactArguments: JSONValue
        let exactArgumentsJSON: String
        let operationPayloadSHA256: SHA256Digest
        let title: String
    }

    /// Package-internal trusted derivation seam used by approval creation.
    /// Callers never provide display strings or a payload digest independently.
    static func derive(
        origin: MutationOrigin,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) throws -> Self {
        guard let canonicalDescriptor = MutationEffectContractCatalog
            .canonicalDescriptor(for: descriptor.identity),
              canonicalDescriptor == descriptor,
              descriptor.identity == invocation.tool,
              descriptor.effectClass == invocation.effectClass,
              descriptor.effectClass != .readOnlyLocal,
              descriptor.effectClass != .unrecoverableDenied
        else { throw MutationEffectGatewayError.invalidOperationBinding }
        return try make(
            origin: origin,
            descriptor: descriptor,
            exactArguments: invocation.arguments,
            claimedCanonicalArgumentDigest:
                invocation.canonicalArgumentDigest
        )
    }

    private static func make(
        origin: MutationOrigin,
        descriptor: ToolDescriptor,
        exactArguments: JSONValue,
        claimedCanonicalArgumentDigest: String
    ) throws -> Self {
        let canonicalArgumentDigest = try descriptor.canonicalArgumentDigest(
            for: exactArguments
        )
        guard canonicalArgumentDigest == claimedCanonicalArgumentDigest,
              let operationPayloadSHA256 = try? SHA256Digest(
                  canonicalArgumentDigest
              )
        else { throw MutationEffectGatewayError.invalidOperationBinding }
        let body = try typedBody(
            descriptor: descriptor,
            arguments: exactArguments
        )
        let exactArgumentsJSON = try AgentToolJSON.string(
            for: exactArguments
        )
        let material = DigestMaterial(
            origin: origin,
            tool: descriptor.identity,
            effectClass: descriptor.effectClass,
            body: body,
            exactArguments: exactArguments,
            exactArgumentsJSON: exactArgumentsJSON,
            operationPayloadSHA256: operationPayloadSHA256,
            title: descriptor.ui.title
        )
        return Self(
            origin: material.origin,
            tool: material.tool,
            effectClass: material.effectClass,
            body: material.body,
            exactArguments: material.exactArguments,
            exactArgumentsJSON: material.exactArgumentsJSON,
            operationPayloadSHA256: material.operationPayloadSHA256,
            title: material.title,
            previewSHA256: try PolicyCanonicalDigest.sha256(
                domain: .mutationApprovalPreview,
                material
            )
        )
    }

    private static func typedBody(
        descriptor: ToolDescriptor,
        arguments: JSONValue
    ) throws -> MutationEffectOperationBody {
        return try MutationEffectContractCatalog.body(
            descriptor: descriptor,
            arguments: arguments
        )
    }

    private init(
        origin: MutationOrigin,
        tool: ToolIdentity,
        effectClass: ToolEffectClass,
        body: MutationEffectOperationBody,
        exactArguments: JSONValue,
        exactArgumentsJSON: String,
        operationPayloadSHA256: SHA256Digest,
        title: String,
        previewSHA256: SHA256Digest
    ) {
        self.origin = origin
        self.tool = tool
        self.effectClass = effectClass
        self.body = body
        self.exactArguments = exactArguments
        self.exactArgumentsJSON = exactArgumentsJSON
        self.operationPayloadSHA256 = operationPayloadSHA256
        self.title = title
        self.previewSHA256 = previewSHA256
    }
}

/// Exact typed mutation derived only from the package-sealed invocation carried
/// by `ClaimedToolEffectPermit`. There is deliberately no public initializer.
public struct MutationEffectOperation:
    CustomDebugStringConvertible,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    public let origin: MutationOrigin
    public let tool: ToolIdentity
    public let effectClass: ToolEffectClass
    public let body: MutationEffectOperationBody
    public let exactArguments: JSONValue
    public let exactArgumentsJSON: String
    public let operationPayloadSHA256: SHA256Digest
    public let title: String
    public let approvalPreview: MutationEffectApprovalPreview

    public var description: String {
        "MutationEffectOperation(tool: \(tool.name)@\(tool.version), operationPayloadSHA256: \(operationPayloadSHA256), exactArguments: <redacted>)"
    }

    public var debugDescription: String { description }

    /// Human-readable, exact change material for approval/receipt surfaces.
    /// Content and command text are present here, not represented by hashes
    /// alone. A UI may add visual diffing without changing the bound payload.
    public var humanReadableChanges: [String] {
        approvalPreview.humanReadableChanges
    }

    static func derive(
        borrowing permit: borrowing ClaimedToolEffectPermit
    ) throws -> Self {
        let sealedPermit = permit.effectPermit
        let descriptor = sealedPermit.descriptor
        let invocation = sealedPermit.invocation
        let claim = permit.claim
        let approvalPreview = try MutationEffectApprovalPreview.derive(
            origin: permit.origin,
            descriptor: descriptor,
            invocation: invocation
        )

        guard permit.origin == claim.origin,
              descriptor.identity == permit.tool,
              descriptor.effectClass == permit.effectClass,
              descriptor.effectClass != .readOnlyLocal,
              descriptor.effectClass != .unrecoverableDenied,
              invocation.tool == permit.tool,
              invocation.effectClass == permit.effectClass,
              invocation.callID == permit.callID,
              invocation.idempotencyKey == permit.idempotencyKey,
              claim.tool == permit.tool,
              claim.effectClass == permit.effectClass,
              claim.operationPayloadSHA256
                == permit.operationPayloadSHA256,
              approvalPreview.tool == permit.tool,
              approvalPreview.effectClass == permit.effectClass,
              approvalPreview.operationPayloadSHA256
                == permit.operationPayloadSHA256
        else { throw MutationEffectGatewayError.invalidOperationBinding }

        guard let canonicalDescriptor = MutationEffectContractCatalog
            .canonicalDescriptor(for: descriptor.identity),
              canonicalDescriptor == descriptor,
              canonicalDescriptor.identity == invocation.tool
        else { throw MutationEffectGatewayError.invalidOperationBinding }

        let canonicalArgumentDigest = try descriptor.canonicalArgumentDigest(
            for: invocation.arguments
        )
        guard canonicalArgumentDigest == invocation.canonicalArgumentDigest,
              canonicalArgumentDigest == permit.canonicalArgumentDigest,
              canonicalArgumentDigest == claim.canonicalArgumentDigest,
              let operationPayloadSHA256 = try? SHA256Digest(
                  canonicalArgumentDigest
              ),
              operationPayloadSHA256 == permit.operationPayloadSHA256
        else { throw MutationEffectGatewayError.invalidOperationBinding }

        let body = try MutationEffectContractCatalog.body(
            descriptor: descriptor,
            arguments: invocation.arguments
        )

        return Self(
            origin: permit.origin,
            tool: descriptor.identity,
            effectClass: descriptor.effectClass,
            body: body,
            exactArguments: invocation.arguments,
            exactArgumentsJSON: try AgentToolJSON.string(
                for: invocation.arguments
            ),
            operationPayloadSHA256: operationPayloadSHA256,
            title: descriptor.ui.title,
            approvalPreview: approvalPreview
        )
    }

    private init(
        origin: MutationOrigin,
        tool: ToolIdentity,
        effectClass: ToolEffectClass,
        body: MutationEffectOperationBody,
        exactArguments: JSONValue,
        exactArgumentsJSON: String,
        operationPayloadSHA256: SHA256Digest,
        title: String,
        approvalPreview: MutationEffectApprovalPreview
    ) {
        self.origin = origin
        self.tool = tool
        self.effectClass = effectClass
        self.body = body
        self.exactArguments = exactArguments
        self.exactArgumentsJSON = exactArgumentsJSON
        self.operationPayloadSHA256 = operationPayloadSHA256
        self.title = title
        self.approvalPreview = approvalPreview
    }
}

public struct MutationEffectCheckpointRequest: Sendable {
    public let origin: MutationOrigin
    public let effectKeySHA256: SHA256Digest
    public let operation: MutationEffectOperation
    public let workspaceID: WorkspaceID
    public let resolvedTargets: [NormalizedToolTarget]
    public let preconditions: [ApprovalPrecondition]
    public let workspaceRevision: String

    init(
        origin: MutationOrigin,
        effectKeySHA256: SHA256Digest,
        operation: MutationEffectOperation,
        workspaceID: WorkspaceID,
        resolvedTargets: [NormalizedToolTarget],
        preconditions: [ApprovalPrecondition],
        workspaceRevision: String
    ) {
        self.origin = origin
        self.effectKeySHA256 = effectKeySHA256
        self.operation = operation
        self.workspaceID = workspaceID
        self.resolvedTargets = resolvedTargets
        self.preconditions = preconditions
        self.workspaceRevision = workspaceRevision
    }
}

/// Production implementations must capture the before-state through an
/// fd-anchored workspace root (`openat`, `O_NOFOLLOW`, and identity checks).
/// It is synchronous so no authority or filesystem identity can escape into an
/// unstructured child task.
public protocol MutationEffectCheckpointing: Sendable {
    func checkpoint(
        _ request: MutationEffectCheckpointRequest
    ) throws -> MutationEffectCheckpointResult
}

/// Unforgeable, non-Sendable authority borrowed only during the synchronous
/// dispatch call. Its package-minted claimed permit cannot be copied or moved
/// into an asynchronous closure by an executor.
public struct MutationEffectApplicationAuthorization: ~Copyable {
    public let origin: MutationOrigin
    public let effectKeySHA256: SHA256Digest
    public let workspaceID: WorkspaceID
    public let resolvedTargets: [NormalizedToolTarget]
    public let preconditions: [ApprovalPrecondition]
    public let workspaceRevision: String
    public let checkpoint: MutationEffectCheckpointResult

    private let claimedPermit: ClaimedToolEffectPermit
    private let freshWorkspaceLease: WorkspaceExecutionLease

    init(
        claimedPermit: consuming ClaimedToolEffectPermit,
        freshWorkspaceLease: WorkspaceExecutionLease,
        preconditions: [ApprovalPrecondition],
        checkpoint: MutationEffectCheckpointResult
    ) {
        origin = claimedPermit.origin
        effectKeySHA256 = claimedPermit.effectKeySHA256
        workspaceID = freshWorkspaceLease.workspaceID
        resolvedTargets = freshWorkspaceLease.resolvedTargets
        self.preconditions = preconditions
        workspaceRevision = freshWorkspaceLease.workspaceRevision
        self.checkpoint = checkpoint
        self.claimedPermit = claimedPermit
        self.freshWorkspaceLease = freshWorkspaceLease
    }
}

/// Trusted production implementations must execute the supplied typed
/// operation inline through fd-relative workspace APIs and compare opened file
/// identities to `authorization.preconditions` immediately before mutation.
/// The borrowed move-only authorization must not escape this synchronous call.
public protocol MutationEffectApplying: Sendable {
    func apply(
        _ operation: MutationEffectOperation,
        authorization: borrowing MutationEffectApplicationAuthorization
    ) throws -> MutationEffectApplicationResult
}

public protocol MutationEffectSynchronousClock: Sendable {
    func currentInstant() throws -> AgentInstant
}

public struct SystemMutationEffectSynchronousClock:
    MutationEffectSynchronousClock
{
    public init() {}
    public func currentInstant() -> AgentInstant { AgentInstant(Date()) }
}

public struct MutationEffectExecutionReceipt: Codable, Equatable, Sendable {
    public let origin: MutationOrigin
    public let effectKeySHA256: SHA256Digest
    public let applicationSHA256: SHA256Digest
    public let evidenceSHA256: SHA256Digest
    public let finalRecordSHA256: SHA256Digest
    public let output: MutationEffectOutput
    public let evidence: [MutationEffectEvidenceFact]
    public let receiptSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let origin: MutationOrigin
        let effectKeySHA256: SHA256Digest
        let applicationSHA256: SHA256Digest
        let evidenceSHA256: SHA256Digest
        let finalRecordSHA256: SHA256Digest
        let output: MutationEffectOutput
        let evidence: [MutationEffectEvidenceFact]
    }

    static func make(
        origin: MutationOrigin,
        effectKeySHA256: SHA256Digest,
        applicationSHA256: SHA256Digest,
        evidenceSHA256: SHA256Digest,
        finalRecordSHA256: SHA256Digest,
        output: MutationEffectOutput,
        evidence: [MutationEffectEvidenceFact]
    ) throws -> Self {
        let canonicalEvidence = try MutationEffectApplicationResult
            .canonicalEvidence(evidence)
        let material = DigestMaterial(
            origin: origin,
            effectKeySHA256: effectKeySHA256,
            applicationSHA256: applicationSHA256,
            evidenceSHA256: evidenceSHA256,
            finalRecordSHA256: finalRecordSHA256,
            output: output,
            evidence: canonicalEvidence
        )
        return Self(
            material: material,
            receiptSHA256: try PolicyCanonicalDigest.sha256(
                domain: .mutationReceipt,
                material
            )
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rebuilt = try Self.make(
            origin: container.decode(MutationOrigin.self, forKey: .origin),
            effectKeySHA256: container.decode(
                SHA256Digest.self,
                forKey: .effectKeySHA256
            ),
            applicationSHA256: container.decode(
                SHA256Digest.self,
                forKey: .applicationSHA256
            ),
            evidenceSHA256: container.decode(
                SHA256Digest.self,
                forKey: .evidenceSHA256
            ),
            finalRecordSHA256: container.decode(
                SHA256Digest.self,
                forKey: .finalRecordSHA256
            ),
            output: container.decode(
                MutationEffectOutput.self,
                forKey: .output
            ),
            evidence: container.decode(
                [MutationEffectEvidenceFact].self,
                forKey: .evidence
            )
        )
        guard rebuilt.receiptSHA256 == (try container.decode(
            SHA256Digest.self,
            forKey: .receiptSHA256
        )) else { throw MutationEffectLifecycleError.corruptEvidence }
        self = rebuilt
    }

    private init(material: DigestMaterial, receiptSHA256: SHA256Digest) {
        origin = material.origin
        effectKeySHA256 = material.effectKeySHA256
        applicationSHA256 = material.applicationSHA256
        evidenceSHA256 = material.evidenceSHA256
        finalRecordSHA256 = material.finalRecordSHA256
        output = material.output
        evidence = material.evidence
        self.receiptSHA256 = receiptSHA256
    }
}

public enum MutationEffectRecoveryDisposition: Equatable, Sendable {
    case evidenceSettled(MutationEffectExecutionReceipt)
    case alreadySettled(MutationEffectExecutionReceipt)
    case reconciliationRequired(SHA256Digest)
}

public enum MutationEffectGatewayError: Error, Equatable, Sendable {
    case invalidOperationBinding
    case unsupportedMutationTool(ToolIdentity)
    case policyChanged
    case expired
    case cancelledBeforePending
    case cancelledAfterPending
    case checkpointFailed
    case pendingCommitFailed
    case targetRevalidationFailed
    case duplicateApplication
    case effectFailed
    case invalidEffectEvidence
    case durableSettlementFailed
    case reconciliationRequired
    case coordinationFailed
    case crossProcessArbiterUnavailable
}

/// Sole consuming mutation entry point. A durable pending record precedes the
/// synchronous effect boundary, and successful return requires both applied
/// and evidence records to be durably observable under the same effect key.
public struct MutationEffectGateway: Sendable {
    private static let inProcessFIFO = WorkspaceMutationFIFOCoordinator()

    private let store: any DurableMutationEffectLifecycleStore
    private let processArbiter: WorkspaceMutationProcessArbiter?
    private let resolver: WorkspaceTargetResolverAuthority
    private let policyRevisionAuthority: PolicyRevisionAuthority
    private let clock: any MutationEffectSynchronousClock
    private let checkpointer: any MutationEffectCheckpointing
    private let applier: any MutationEffectApplying

    public init(
        store: any DurableMutationEffectLifecycleStore,
        resolver: WorkspaceTargetResolverAuthority,
        policyRevisionAuthority: PolicyRevisionAuthority,
        clock: any MutationEffectSynchronousClock =
            SystemMutationEffectSynchronousClock(),
        checkpointer: any MutationEffectCheckpointing,
        applier: any MutationEffectApplying
    ) throws {
        self.store = store
        if let fileStore = store as? FileMutationEffectLifecycleStore {
            processArbiter = fileStore.workspaceProcessArbiter
        } else if store is InMemoryMutationEffectLifecycleStore {
            // Explicitly process-local test/development storage. The static
            // FIFO still serializes every gateway instance in this process.
            processArbiter = nil
        } else {
            // A durable store without an OS-backed workspace lane could let
            // another process recover or apply while an effect is live.
            throw MutationEffectGatewayError
                .crossProcessArbiterUnavailable
        }
        self.resolver = resolver
        self.policyRevisionAuthority = policyRevisionAuthority
        self.clock = clock
        self.checkpointer = checkpointer
        self.applier = applier
    }

    public func apply(
        _ claimedPermit: consuming ClaimedToolEffectPermit
    ) async throws -> MutationEffectExecutionReceipt {
        let operation = try MutationEffectOperation.derive(
            borrowing: claimedPermit
        )
        let binding = try MutationEffectBinding.make(
            borrowing: claimedPermit
        )
        guard operation.origin == binding.origin,
              operation.tool == binding.tool,
              operation.effectClass == binding.effectClass,
              operation.operationPayloadSHA256
                == binding.operationPayloadSHA256,
              operation.approvalPreview.previewSHA256
                == binding.operationPreviewSHA256
        else { throw MutationEffectGatewayError.invalidOperationBinding }

        let queueLease: WorkspaceMutationQueueLease
        do {
            queueLease = try await Self.inProcessFIFO.acquire(
                workspaceID: binding.workspaceID
            )
        } catch {
            throw MutationEffectGatewayError.coordinationFailed
        }
        let processLease: WorkspaceMutationProcessLease?
        do {
            processLease = try await processArbiter?.acquire(
                workspaceID: binding.workspaceID
            )
        } catch {
            try? await Self.inProcessFIFO.release(queueLease)
            throw MutationEffectGatewayError.coordinationFailed
        }

        let outcome: Result<MutationEffectExecutionReceipt, any Error>
        do {
            outcome = .success(try await applyWhileHoldingLane(
                claimedPermit,
                binding: binding,
                operation: operation
            ))
        } catch {
            outcome = .failure(error)
        }
        processLease?.release()
        do {
            try await Self.inProcessFIFO.release(queueLease)
        } catch {
            throw MutationEffectGatewayError.coordinationFailed
        }
        switch outcome {
        case let .success(receipt): return receipt
        case let .failure(error): throw error
        }
    }

    public func recover(
        effectKeySHA256: SHA256Digest
    ) async throws -> MutationEffectRecoveryDisposition {
        guard let initial = try await store.record(
            effectKeySHA256: effectKeySHA256
        ) else {
            throw MutationEffectLifecycleError.recordNotFound(
                effectKeySHA256
            )
        }
        let queueLease: WorkspaceMutationQueueLease
        do {
            queueLease = try await Self.inProcessFIFO.acquire(
                workspaceID: initial.binding.workspaceID
            )
        } catch {
            throw MutationEffectGatewayError.coordinationFailed
        }
        let processLease: WorkspaceMutationProcessLease?
        do {
            processLease = try await processArbiter?.acquire(
                workspaceID: initial.binding.workspaceID
            )
        } catch {
            try? await Self.inProcessFIFO.release(queueLease)
            throw MutationEffectGatewayError.coordinationFailed
        }
        let outcome: Result<MutationEffectRecoveryDisposition, any Error>
        do {
            outcome = .success(try await recoverWhileHoldingLane(
                effectKeySHA256: effectKeySHA256
            ))
        } catch {
            outcome = .failure(error)
        }
        processLease?.release()
        do {
            try await Self.inProcessFIFO.release(queueLease)
        } catch {
            throw MutationEffectGatewayError.coordinationFailed
        }
        switch outcome {
        case let .success(disposition): return disposition
        case let .failure(error): throw error
        }
    }

    private func applyWhileHoldingLane(
        _ claimedPermit: consuming ClaimedToolEffectPermit,
        binding: MutationEffectBinding,
        operation: MutationEffectOperation
    ) async throws -> MutationEffectExecutionReceipt {
        if let existing = try await store.record(
            effectKeySHA256: binding.effectKeySHA256
        ) {
            _ = try await settleExistingWithoutApplying(existing)
            throw MutationEffectGatewayError.duplicateApplication
        }
        guard !Task.isCancelled else {
            throw MutationEffectGatewayError.cancelledBeforePending
        }
        try requireCurrentPolicy(claimedPermit)

        let originalWorkspaceLease = claimedPermit.workspaceLease
        let targetAttestation = claimedPermit.effectPermit.targetAttestation
        let preflightLease: WorkspaceExecutionLease
        do {
            preflightLease = try await resolver.revalidateForExecution(
                originalWorkspaceLease,
                against: targetAttestation
            )
        } catch {
            throw MutationEffectGatewayError.targetRevalidationFailed
        }
        try requireCurrentPolicy(claimedPermit)
        let preflightInstant = try freshInstant(for: binding)

        let checkpoint: MutationEffectCheckpointResult
        do {
            checkpoint = try checkpointer.checkpoint(
                MutationEffectCheckpointRequest(
                    origin: binding.origin,
                    effectKeySHA256: binding.effectKeySHA256,
                    operation: operation,
                    workspaceID: preflightLease.workspaceID,
                    resolvedTargets: preflightLease.resolvedTargets,
                    preconditions: targetAttestation.preconditions,
                    workspaceRevision: preflightLease.workspaceRevision
                )
            )
        } catch {
            throw MutationEffectGatewayError.checkpointFailed
        }
        guard !Task.isCancelled else {
            throw MutationEffectGatewayError.cancelledBeforePending
        }
        let preparedAt = try freshInstant(
            for: binding,
            noEarlierThan: preflightInstant
        )
        let pending = try MutationEffectRecord.pending(
            binding: binding,
            checkpoint: checkpoint,
            preparedAt: preparedAt
        )

        let inserted: MutationEffectRecord
        do {
            switch try await store.insertPendingIfAbsent(pending) {
            case let .inserted(record):
                inserted = record
            case let .alreadyPresent(existing):
                _ = try await settleExistingWithoutApplying(existing)
                throw MutationEffectGatewayError.duplicateApplication
            }
        } catch let error as MutationEffectGatewayError {
            throw error
        } catch {
            if let durable = try? await store.record(
                effectKeySHA256: binding.effectKeySHA256
            ) {
                _ = try? await markReconciliation(
                    durable,
                    reason: .corruptOrConflictingState
                )
            }
            throw MutationEffectGatewayError.pendingCommitFailed
        }

        if Task.isCancelled {
            _ = try? await markReconciliation(
                inserted,
                reason: .effectCancelledAfterPending
            )
            throw MutationEffectGatewayError.cancelledAfterPending
        }
        do {
            try requireCurrentPolicy(claimedPermit)
        } catch {
            _ = try? await markReconciliation(
                inserted,
                reason: .targetRevalidationFailedAfterPending
            )
            throw error
        }

        let finalWorkspaceLease: WorkspaceExecutionLease
        do {
            finalWorkspaceLease = try await resolver.revalidateForExecution(
                originalWorkspaceLease,
                against: targetAttestation
            )
        } catch {
            _ = try? await markReconciliation(
                inserted,
                reason: .targetRevalidationFailedAfterPending
            )
            throw MutationEffectGatewayError.targetRevalidationFailed
        }

        // No asynchronous operation is permitted after this point until the
        // synchronous effect returns. Policy, cancellation, and expiry are
        // checked immediately against the fresh target lease.
        do {
            try requireCurrentPolicy(claimedPermit)
        } catch {
            _ = try? await markReconciliation(
                inserted,
                reason: .targetRevalidationFailedAfterPending
            )
            throw error
        }
        if Task.isCancelled {
            _ = try? await markReconciliation(
                inserted,
                reason: .effectCancelledAfterPending
            )
            throw MutationEffectGatewayError.cancelledAfterPending
        }
        let dispatchAt: AgentInstant
        do {
            dispatchAt = try freshInstant(
                for: binding,
                noEarlierThan: preparedAt
            )
        } catch {
            _ = try? await markReconciliation(
                inserted,
                reason: .clockUnavailableAfterPending
            )
            throw error
        }

        let result: MutationEffectApplicationResult
        do {
            let authorization = MutationEffectApplicationAuthorization(
                claimedPermit: claimedPermit,
                freshWorkspaceLease: finalWorkspaceLease,
                preconditions: targetAttestation.preconditions,
                checkpoint: checkpoint
            )
            result = try applier.apply(
                operation,
                authorization: authorization
            )
        } catch {
            _ = try? await markReconciliation(
                inserted,
                reason: .effectThrewAfterPending,
                noEarlierThan: dispatchAt
            )
            throw MutationEffectGatewayError.effectFailed
        }
        do {
            try Self.validateEvidence(
                result,
                for: operation,
                resolvedTargets: finalWorkspaceLease.resolvedTargets
            )
        } catch {
            _ = try? await markReconciliation(
                inserted,
                reason: .corruptOrConflictingState,
                noEarlierThan: dispatchAt
            )
            throw MutationEffectGatewayError.invalidEffectEvidence
        }

        let appliedAt = max(
            (try? clock.currentInstant()) ?? dispatchAt,
            dispatchAt
        )
        let applied = try inserted.applying(result, at: appliedAt)
        let durableApplied: MutationEffectRecord
        do {
            durableApplied = try await commitApplication(
                current: inserted,
                next: applied
            )
        } catch {
            throw MutationEffectGatewayError.durableSettlementFailed
        }

        guard case let .applied(_, application) = durableApplied.state else {
            throw MutationEffectGatewayError.durableSettlementFailed
        }
        let evidenceAt = max(
            (try? clock.currentInstant()) ?? application.appliedAt,
            application.appliedAt
        )
        let evidence = try durableApplied.settlingEvidence(at: evidenceAt)
        let durableEvidence: MutationEffectRecord
        do {
            durableEvidence = try await commitEvidence(
                current: durableApplied,
                next: evidence
            )
        } catch {
            throw MutationEffectGatewayError.durableSettlementFailed
        }
        return try receipt(for: durableEvidence)
    }

    private func commitApplication(
        current: MutationEffectRecord,
        next: MutationEffectRecord
    ) async throws -> MutationEffectRecord {
        do {
            return try transitionedRecord(
                await store.compareAndTransition(
                    expectedRecordSHA256: current.recordSHA256,
                    to: next
                )
            )
        } catch {
            guard let durable = try? await store.record(
                effectKeySHA256: current.effectKeySHA256
            ) else { throw error }
            if durable == next { return durable }
            if durable == current {
                _ = try? await markReconciliation(
                    current,
                    reason: .applicationCommitFailed
                )
            }
            throw error
        }
    }

    private func commitEvidence(
        current: MutationEffectRecord,
        next: MutationEffectRecord
    ) async throws -> MutationEffectRecord {
        do {
            return try transitionedRecord(
                await store.compareAndTransition(
                    expectedRecordSHA256: current.recordSHA256,
                    to: next
                )
            )
        } catch {
            guard let durable = try? await store.record(
                effectKeySHA256: current.effectKeySHA256
            ) else { throw error }
            if durable == next { return durable }
            // `applied` remains recoverable without dispatching the effect.
            throw error
        }
    }

    private func settleExistingWithoutApplying(
        _ record: MutationEffectRecord
    ) async throws -> MutationEffectRecoveryDisposition {
        switch record.state {
        case .pending:
            let reconciled = try await markReconciliation(
                record,
                reason: .ambiguousPendingAfterRecovery
            )
            return .reconciliationRequired(reconciled.recordSHA256)
        case .applied:
            let next = try record.settlingEvidence(
                at: applicationTime(in: record)
            )
            let settled = try await commitEvidence(current: record, next: next)
            return .evidenceSettled(try receipt(for: settled))
        case .evidence:
            return .alreadySettled(try receipt(for: record))
        case .needsReconciliation:
            return .reconciliationRequired(record.recordSHA256)
        }
    }

    private func recoverWhileHoldingLane(
        effectKeySHA256: SHA256Digest
    ) async throws -> MutationEffectRecoveryDisposition {
        for _ in 0..<4 {
            guard let current = try await store.record(
                effectKeySHA256: effectKeySHA256
            ) else {
                throw MutationEffectLifecycleError.recordNotFound(
                    effectKeySHA256
                )
            }
            do {
                return try await settleExistingWithoutApplying(current)
            } catch MutationEffectLifecycleError.staleRecord {
                continue
            }
        }
        throw MutationEffectGatewayError.durableSettlementFailed
    }

    private func markReconciliation(
        _ record: MutationEffectRecord,
        reason: MutationEffectReconciliationReason,
        noEarlierThan lowerBound: AgentInstant? = nil
    ) async throws -> MutationEffectRecord {
        if record.phase == .needsReconciliation { return record }
        guard record.phase == .pending || record.phase == .applied else {
            throw MutationEffectLifecycleError.invalidTransition(
                from: record.phase,
                to: .needsReconciliation
            )
        }
        let storedTime = applicationTime(in: record)
        let markedAt = max(
            (try? clock.currentInstant()) ?? storedTime,
            max(storedTime, lowerBound ?? storedTime)
        )
        let next = try record.requiringReconciliation(
            reason,
            at: markedAt
        )
        do {
            return try transitionedRecord(
                await store.compareAndTransition(
                    expectedRecordSHA256: record.recordSHA256,
                    to: next
                )
            )
        } catch {
            if let durable = try? await store.record(
                effectKeySHA256: record.effectKeySHA256
            ), durable == next || durable.phase == .needsReconciliation {
                return durable
            }
            throw error
        }
    }

    private func requireCurrentPolicy(
        _ permit: borrowing ClaimedToolEffectPermit
    ) throws {
        guard permit.effectPermit.policyRevision
            == policyRevisionAuthority.currentRevision()
        else { throw MutationEffectGatewayError.policyChanged }
    }

    private func freshInstant(
        for binding: MutationEffectBinding,
        noEarlierThan lowerBound: AgentInstant? = nil
    ) throws -> AgentInstant {
        let now: AgentInstant
        do {
            now = try clock.currentInstant()
        } catch {
            throw MutationEffectGatewayError.durableSettlementFailed
        }
        guard now >= binding.claimedAt,
              now >= (lowerBound ?? binding.claimedAt),
              now < binding.expiresAt
        else { throw MutationEffectGatewayError.expired }
        return now
    }

    private func applicationTime(
        in record: MutationEffectRecord
    ) -> AgentInstant {
        switch record.state {
        case let .pending(pending):
            pending.preparedAt
        case let .applied(_, application),
             let .evidence(_, application, _),
             let .needsReconciliation(_, .some(application), _):
            application.appliedAt
        case let .needsReconciliation(pending, .none, _):
            pending.preparedAt
        }
    }

    private func transitionedRecord(
        _ disposition: MutationEffectTransitionDisposition
    ) -> MutationEffectRecord {
        switch disposition {
        case let .committed(record), let .alreadyCommitted(record): record
        }
    }

    private func receipt(
        for record: MutationEffectRecord
    ) throws -> MutationEffectExecutionReceipt {
        guard case let .evidence(_, application, evidence) = record.state else {
            throw MutationEffectGatewayError.durableSettlementFailed
        }
        return try MutationEffectExecutionReceipt.make(
            origin: record.binding.origin,
            effectKeySHA256: record.effectKeySHA256,
            applicationSHA256: application.applicationSHA256,
            evidenceSHA256: evidence.evidenceSHA256,
            finalRecordSHA256: record.recordSHA256,
            output: application.output,
            evidence: evidence.facts
        )
    }

    static func validateEvidence(
        _ result: MutationEffectApplicationResult,
        for operation: MutationEffectOperation,
        resolvedTargets: [NormalizedToolTarget]
    ) throws {
        let requiredKinds: Set<MutationEffectEvidenceKind>
        let targetBoundKind: MutationEffectEvidenceKind?
        let outputKind: MutationEffectOutputKind
        switch operation.body {
        case .writeFile:
            requiredKinds = [.changedPath, .workspaceAfter]
            targetBoundKind = .changedPath
            outputKind = .writeFile
        case .appendFile:
            requiredKinds = [.changedPath, .workspaceAfter]
            targetBoundKind = .changedPath
            outputKind = .appendFile
        case .replaceText:
            requiredKinds = [.changedPath, .workspaceAfter]
            targetBoundKind = .changedPath
            outputKind = .replaceText
        case .deletePath:
            requiredKinds = [.deletedPath, .workspaceAfter]
            targetBoundKind = .deletedPath
            outputKind = .deletePath
        case .movePath:
            requiredKinds = [.movedPath, .workspaceAfter]
            targetBoundKind = .movedPath
            outputKind = .movePath
        case .copyPath:
            requiredKinds = [.copiedPath, .workspaceAfter]
            targetBoundKind = .copiedPath
            outputKind = .copyPath
        case .makeDirectory:
            requiredKinds = [.createdDirectory, .workspaceAfter]
            targetBoundKind = .createdDirectory
            outputKind = .makeDirectory
        case .runCommand:
            requiredKinds = [
                .commandTranscript,
                .commandExit,
                .workspaceAfter,
            ]
            targetBoundKind = nil
            outputKind = .runCommand
        case .createFile:
            requiredKinds = [.changedPath, .workspaceAfter]
            targetBoundKind = .changedPath
            outputKind = .createFile
        case .touchFile:
            requiredKinds = [.changedPath, .workspaceAfter]
            targetBoundKind = .changedPath
            outputKind = .touchFile
        case .resetWorkspace:
            requiredKinds = [.deletedPath, .workspaceAfter]
            targetBoundKind = .deletedPath
            outputKind = .resetWorkspace
        case .seedWorkspace:
            requiredKinds = [.changedPath, .workspaceAfter]
            targetBoundKind = .changedPath
            outputKind = .seedWorkspace
        }
        let factsByKind = Dictionary(
            uniqueKeysWithValues: result.evidence.map { ($0.kind, $0) }
        )
        guard result.output.kind == outputKind,
              result.output.targets == resolvedTargets,
              Set(factsByKind.keys) == requiredKinds,
              factsByKind[.workspaceAfter]?.targets.isEmpty == true
        else { throw MutationEffectLifecycleError.invalidEvidenceSchema }
        if let targetBoundKind {
            guard !resolvedTargets.isEmpty,
                  factsByKind[targetBoundKind]?.targets == resolvedTargets
            else { throw MutationEffectLifecycleError.invalidEvidenceSchema }
        } else {
            guard factsByKind[.commandTranscript]?.targets.isEmpty == true,
                  factsByKind[.commandExit]?.targets.isEmpty == true
            else { throw MutationEffectLifecycleError.invalidEvidenceSchema }
        }
    }
}

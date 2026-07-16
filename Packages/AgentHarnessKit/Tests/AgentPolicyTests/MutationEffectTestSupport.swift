import AgentDomain
@testable import AgentPolicy
import AgentTools
import Foundation

struct MutationEffectTestContext: Sendable {
    let backend: MutableResolutionBackend
    let resolver: WorkspaceTargetResolverAuthority
    let policyRevisionAuthority: PolicyRevisionAuthority
    let request: RiskPolicyRequest

    static func make(
        tool: String = "write_file",
        arguments: JSONValue = .object([
            "path": .string("notes.txt"),
            "contents": .string("hello"),
        ]),
        workspaceID: WorkspaceID = WorkspaceID(),
        idempotencyKey: String = "mutation-1"
    ) async throws -> Self {
        let backend = MutableResolutionBackend()
        if tool == "run_command" {
            await backend.configure(commandTargets: [
                try NormalizedToolTarget(path: "notes.txt", access: .write),
            ])
        }
        let resolver = WorkspaceTargetResolverAuthority(
            trustedBackend: backend
        )
        let request = try await AgentPolicyTestFixture.request(
            tool,
            arguments: arguments,
            resolver: resolver,
            workspaceID: workspaceID,
            idempotencyKey: idempotencyKey
        )
        return try Self(
            backend: backend,
            resolver: resolver,
            policyRevisionAuthority: PolicyRevisionAuthority(
                configuration: RiskPolicyConfiguration()
            ),
            request: request
        )
    }

    func claimedPermit(
        authorizedAt: Int64 = 10,
        claimedAt: Int64 = 20,
        expiresAt: Int64 = 10_000
    ) async throws -> ClaimedToolEffectPermit {
        let lease = try await resolver.revalidate(request.targetAttestation)
        let preview = try MutationEffectApprovalPreview.derive(
            origin: request.origin,
            descriptor: request.descriptor,
            invocation: request.invocation
        )
        let permit = try ToolEffectPermit(
            origin: request.origin,
            requestSHA256: request.requestSHA256,
            policyRevision: policyRevisionAuthority.currentRevision(),
            tool: request.invocation.tool,
            effectClass: request.invocation.effectClass,
            canonicalArgumentDigest:
                request.invocation.canonicalArgumentDigest,
            operationPayloadSHA256: request.argumentSHA256,
            operationPreviewSHA256: preview.previewSHA256,
            callID: request.invocation.callID,
            idempotencyKey: request.invocation.idempotencyKey,
            authorizedAt: AgentInstant(rawValue: authorizedAt),
            expiresAt: AgentInstant(rawValue: expiresAt),
            source: .policy(.baseline),
            descriptor: request.descriptor,
            invocation: request.invocation,
            workspaceLease: lease,
            targetAttestation: request.targetAttestation
        )
        let claim = try ToolEffectClaimRecord.make(
            permit: permit,
            claimedAt: AgentInstant(rawValue: claimedAt)
        )
        return ClaimedToolEffectPermit(
            effectPermit: permit,
            claim: claim,
            workspaceLease: lease,
            isRecovery: false
        )
    }

    func pendingRecord(
        checkpointSeed: String = "checkpoint",
        preparedAt: Int64 = 30
    ) async throws -> MutationEffectRecord {
        let permit = try await claimedPermit()
        let binding = try MutationEffectBinding.make(borrowing: permit)
        return try MutationEffectRecord.pending(
            binding: binding,
            checkpoint: MutationEffectCheckpointResult(
                beforeStateSHA256: try AgentPolicyTestFixture.digest(
                    "before-\(checkpointSeed)"
                ),
                rollbackOrReconciliationPlanSHA256:
                    try AgentPolicyTestFixture.digest(
                        "rollback-\(checkpointSeed)"
                    )
            ),
            preparedAt: AgentInstant(rawValue: preparedAt)
        )
    }
}

final class LockedMutationEffectClock:
    @unchecked Sendable,
    MutationEffectSynchronousClock
{
    enum ClockFailure: Error { case unavailable }

    private let lock = NSLock()
    private var values: [AgentInstant]
    private var index = 0
    private var shouldFail = false

    init(_ values: [Int64] = Array(30...80)) {
        self.values = values.map(AgentInstant.init(rawValue:))
    }

    func fail() {
        lock.lock()
        shouldFail = true
        lock.unlock()
    }

    func currentInstant() throws -> AgentInstant {
        lock.lock()
        defer { lock.unlock() }
        if shouldFail { throw ClockFailure.unavailable }
        guard !values.isEmpty else { throw ClockFailure.unavailable }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

final class RecordingMutationCheckpointer:
    @unchecked Sendable,
    MutationEffectCheckpointing
{
    enum CheckpointFailure: Error { case injected }

    private let lock = NSLock()
    private var requestsStorage: [MutationEffectCheckpointRequest] = []
    private let result: MutationEffectCheckpointResult
    private let shouldFail: Bool
    private let callback: (@Sendable (MutationEffectCheckpointRequest) -> Void)?

    init(
        seed: String = "default",
        shouldFail: Bool = false,
        callback: (@Sendable (MutationEffectCheckpointRequest) -> Void)? = nil
    ) throws {
        result = MutationEffectCheckpointResult(
            beforeStateSHA256: try AgentPolicyTestFixture.digest(
                "before-\(seed)"
            ),
            rollbackOrReconciliationPlanSHA256:
                try AgentPolicyTestFixture.digest("rollback-\(seed)")
        )
        self.shouldFail = shouldFail
        self.callback = callback
    }

    func checkpoint(
        _ request: MutationEffectCheckpointRequest
    ) throws -> MutationEffectCheckpointResult {
        lock.lock()
        requestsStorage.append(request)
        lock.unlock()
        callback?(request)
        if shouldFail { throw CheckpointFailure.injected }
        return result
    }

    var requests: [MutationEffectCheckpointRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStorage
    }
}

final class RecordingMutationApplier:
    @unchecked Sendable,
    MutationEffectApplying
{
    enum ApplyFailure: Error { case injected }

    private let lock = NSLock()
    private var operationsStorage: [MutationEffectOperation] = []
    private var effectKeysStorage: [SHA256Digest] = []
    private let shouldFail: Bool
    private let callback: (@Sendable (MutationEffectOperation) -> Void)?

    init(
        shouldFail: Bool = false,
        callback: (@Sendable (MutationEffectOperation) -> Void)? = nil
    ) {
        self.shouldFail = shouldFail
        self.callback = callback
    }

    func apply(
        _ operation: MutationEffectOperation,
        authorization: borrowing MutationEffectApplicationAuthorization
    ) throws -> MutationEffectApplicationResult {
        lock.lock()
        operationsStorage.append(operation)
        effectKeysStorage.append(authorization.effectKeySHA256)
        lock.unlock()
        callback?(operation)
        if shouldFail { throw ApplyFailure.injected }
        var evidence = [
            try MutationEffectEvidenceFact(
                kind: .workspaceAfter,
                digest: AgentPolicyTestFixture.digest("workspace-after")
            ),
        ]
        let targetKind: MutationEffectEvidenceKind?
        let outputKind: MutationEffectOutputKind
        switch operation.body {
        case .writeFile:
            targetKind = .changedPath
            outputKind = .writeFile
        case .appendFile:
            targetKind = .changedPath
            outputKind = .appendFile
        case .replaceText:
            targetKind = .changedPath
            outputKind = .replaceText
        case .deletePath:
            targetKind = .deletedPath
            outputKind = .deletePath
        case .movePath:
            targetKind = .movedPath
            outputKind = .movePath
        case .copyPath:
            targetKind = .copiedPath
            outputKind = .copyPath
        case .makeDirectory:
            targetKind = .createdDirectory
            outputKind = .makeDirectory
        case .runCommand:
            targetKind = nil
            outputKind = .runCommand
            evidence.append(try MutationEffectEvidenceFact(
                kind: .commandTranscript,
                digest: AgentPolicyTestFixture.digest("command-transcript")
            ))
            evidence.append(try MutationEffectEvidenceFact(
                kind: .commandExit,
                digest: AgentPolicyTestFixture.digest("command-exit")
            ))
        case .createFile:
            targetKind = .changedPath
            outputKind = .createFile
        case .touchFile:
            targetKind = .changedPath
            outputKind = .touchFile
        case .resetWorkspace:
            targetKind = .deletedPath
            outputKind = .resetWorkspace
        case .seedWorkspace:
            targetKind = .changedPath
            outputKind = .seedWorkspace
        }
        if let targetKind {
            evidence.append(try MutationEffectEvidenceFact(
                kind: targetKind,
                targets: authorization.resolvedTargets,
                digest: AgentPolicyTestFixture.digest("target-after")
            ))
        }
        return try MutationEffectApplicationResult(
            resultSHA256: AgentPolicyTestFixture.digest("result"),
            output: MutationEffectOutput(
                kind: outputKind,
                summary: "Mutation completed",
                targets: authorization.resolvedTargets,
                text: outputKind == .runCommand ? "command output" : nil,
                commandExitCode: outputKind == .runCommand ? 0 : nil
            ),
            evidence: evidence
        )
    }

    var operations: [MutationEffectOperation] {
        lock.lock()
        defer { lock.unlock() }
        return operationsStorage
    }

    var effectKeys: [SHA256Digest] {
        lock.lock()
        defer { lock.unlock() }
        return effectKeysStorage
    }
}

func mutationEffectTestOutput(
    kind: MutationEffectOutputKind = .writeFile,
    targets: [NormalizedToolTarget] = []
) throws -> MutationEffectOutput {
    try MutationEffectOutput(
        kind: kind,
        summary: "Mutation completed",
        targets: targets,
        text: kind == .runCommand ? "command output" : nil,
        commandExitCode: kind == .runCommand ? 0 : nil
    )
}

final class OneShotMutationStoreFault: @unchecked Sendable {
    private let lock = NSLock()
    private let target: MutationEffectStoreFaultPoint
    private var fired = false

    init(_ target: MutationEffectStoreFaultPoint) {
        self.target = target
    }

    func inject(_ point: MutationEffectStoreFaultPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard point == target, !fired else { return }
        fired = true
        throw InjectedMutationEffectFault()
    }
}

struct InjectedMutationEffectFault: Error {}

final class OneShotFileMutationStoreFault: @unchecked Sendable {
    private let lock = NSLock()
    private let target: FileMutationEffectLifecycleStoreFaultPoint
    private var fired = false

    init(_ target: FileMutationEffectLifecycleStoreFaultPoint) {
        self.target = target
    }

    func inject(_ point: FileMutationEffectLifecycleStoreFaultPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard point == target, !fired else { return }
        fired = true
        throw InjectedMutationEffectFault()
    }
}

final class BlockingAfterPendingMutationStoreFault: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var entered = false

    func inject(_ point: MutationEffectStoreFaultPoint) {
        guard point == .afterPendingCommit else { return }
        lock.lock()
        guard !entered else {
            lock.unlock()
            return
        }
        entered = true
        lock.unlock()
        releaseSemaphore.wait()
    }

    var hasEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func release() {
        releaseSemaphore.signal()
    }
}

import Foundation
import SwiftData

/// Process-wide construction point for every workspace mutation surface.
/// Runtimes may keep independent presentation state, while the shared
/// coordinator still serializes effects that resolve to the same root hash.
struct WorkspaceMutationGatewayFactory: Sendable {
    static let shared = WorkspaceMutationGatewayFactory(
        coordinator: AgentExecutionCoordinator()
    )

    let coordinator: AgentExecutionCoordinator

    init(coordinator: AgentExecutionCoordinator) {
        self.coordinator = coordinator
    }

    func makeGateway(container: ModelContainer) -> WorkspaceMutationGateway {
        WorkspaceMutationGateway(
            coordinator: coordinator,
            journal: SwiftDataWorkspaceMutationJournal(container: container)
        )
    }
}

/// Identifies the product surface that requested a workspace mutation without
/// coupling the execution layer to SwiftUI or SwiftData model objects.
enum WorkspaceMutationSource: String, Codable, CaseIterable, Sendable {
    case agentTool
    case editor
    case files
    case terminal
    case settings
    case codeBlock
    case systemSeed
    case debugFixture
}

/// Shared request policy for human-facing workspace mutations. Keeping it at
/// the gateway boundary lets app and focused-test targets use the same typed
/// request construction without importing a SwiftUI surface.
enum WorkspaceMutationUIRequest {
    static func make(
        workspace: SandboxWorkspace,
        operation: WorkspaceMutationOperation,
        projectID: UUID?,
        conversationID: UUID?,
        source: WorkspaceMutationSource,
        ownerDescription: String
    ) throws -> WorkspaceMutationRequest {
        try WorkspaceMutationRequest(
            workspace: workspace,
            operation: operation,
            journalArgumentsJSON: "{}",
            context: WorkspaceMutationContext(
                projectID: projectID,
                conversationID: conversationID,
                source: source,
                authorization: .userInitiated,
                ownerDescription: ownerDescription
            )
        )
    }

    static func failureMessage(action: String, error: Error) -> String? {
        if error is CancellationError {
            return nil
        }
        if let gatewayError = error as? WorkspaceMutationGatewayError,
           case .cancelledBeforeExecution = gatewayError {
            return nil
        }
        return "\(action): \(error.localizedDescription)"
    }
}

/// Authorization is scalar so the journal can bind the exact user or policy
/// decision to the operation without retaining UI or SwiftData objects.
enum WorkspaceMutationAuthorization: Equatable, Sendable {
    case userInitiated
    case agentApproved(toolCallID: String)
    case agentPolicyApproved(toolCallID: String)
    case trustedSystem(reason: String)
    case debugFixture

    var journalKind: String {
        switch self {
        case .userInitiated: "user_initiated"
        case .agentApproved: "agent_approved"
        case .agentPolicyApproved: "agent_policy_approved"
        case .trustedSystem: "trusted_system"
        case .debugFixture: "debug_fixture"
        }
    }

    var journalDetail: String? {
        switch self {
        case .agentApproved(let toolCallID), .agentPolicyApproved(let toolCallID):
            toolCallID
        case .trustedSystem(let reason):
            reason
        case .userInitiated, .debugFixture:
            nil
        }
    }
}

enum WorkspaceMutationRisk: String, Codable, Sendable {
    case scopedWrite
    case destructiveWrite
    case workspaceReset
}

/// Typed mutation identity shared by agents and human-facing workspace tools.
/// File contents deliberately do not live here; callers provide them only to
/// the effect closure so the journal can hash/redact payloads before storage.
enum WorkspaceMutationOperation: Equatable, Sendable {
    case writeFile(path: String)
    case appendFile(path: String)
    case createFile(path: String)
    case touchFile(path: String)
    case createDirectory(path: String)
    case deletePath(path: String)
    case movePath(from: String, to: String)
    case copyPath(from: String, to: String)
    case terminalCommand(command: String, targetPaths: [String])
    case resetWorkspace
    case seedWorkspace(paths: [String])
    case agentTool(name: String, targetPaths: [String])

    var journalName: String {
        switch self {
        case .writeFile: "write_file"
        case .appendFile: "append_file"
        case .createFile: "create_file"
        case .touchFile: "touch_file"
        case .createDirectory: "make_directory"
        case .deletePath: "delete_path"
        case .movePath: "move_path"
        case .copyPath: "copy_path"
        case .terminalCommand: "run_command"
        case .resetWorkspace: "reset_workspace"
        case .seedWorkspace: "seed_workspace"
        case .agentTool(let name, _): name
        }
    }

    var targetPaths: [String] {
        let rawPaths: [String]
        switch self {
        case .writeFile(let path),
             .appendFile(let path),
             .createFile(let path),
             .touchFile(let path),
             .createDirectory(let path),
             .deletePath(let path):
            rawPaths = [path]
        case .movePath(let source, let destination),
             .copyPath(let source, let destination):
            rawPaths = [source, destination]
        case .terminalCommand(let command, let declaredTargetPaths):
            let derivedTargetPaths = Self.terminalTargetPaths(for: command)
            rawPaths = derivedTargetPaths.isEmpty ? declaredTargetPaths : derivedTargetPaths
        case .seedWorkspace(let targetPaths),
             .agentTool(_, let targetPaths):
            rawPaths = targetPaths
        case .resetWorkspace:
            rawPaths = ["."]
        }

        var seen = Set<String>()
        return rawPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Terminal targets are derived from the parsed command rather than trusted
    /// from UI metadata. This keeps agent-issued `run_command` requests path-
    /// bound even when their legacy caller did not populate `targetPaths`.
    static func terminalTargetPaths(for command: String) -> [String] {
        let draft = TerminalCommandDraft(command)
        guard draft.isMutating, draft.argumentIssue == nil else { return [] }
        let arguments = Array(draft.tokens.dropFirst())
        switch draft.commandName {
        case "mkdir", "touch", "rm":
            return Array(arguments.prefix(1))
        case "mv", "cp":
            return Array(arguments.prefix(2))
        default:
            return []
        }
    }

    var risk: WorkspaceMutationRisk {
        switch self {
        case .deletePath, .movePath:
            .destructiveWrite
        case .resetWorkspace:
            .workspaceReset
        case .terminalCommand:
            // Until CommandRunner exposes typed effects, treat a terminal write
            // as destructive rather than guessing from a command string.
            .destructiveWrite
        case .agentTool(let name, _):
            ["delete_path", "move_path", "reset_workspace"].contains(name)
                ? (name == "reset_workspace" ? .workspaceReset : .destructiveWrite)
                : .scopedWrite
        case .writeFile, .appendFile, .createFile, .touchFile, .createDirectory,
             .copyPath, .seedWorkspace:
            .scopedWrite
        }
    }
}

/// Scalar execution lineage. SwiftData models must be resolved by ID at the
/// persistence boundary instead of crossing an actor or detached-task hop.
struct WorkspaceMutationContext: Equatable, Sendable {
    let runID: UUID?
    let projectID: UUID?
    let conversationID: UUID?
    let toolCallID: String?
    let source: WorkspaceMutationSource
    let authorization: WorkspaceMutationAuthorization
    let ownerDescription: String

    init(
        runID: UUID? = nil,
        projectID: UUID? = nil,
        conversationID: UUID? = nil,
        toolCallID: String? = nil,
        source: WorkspaceMutationSource,
        authorization: WorkspaceMutationAuthorization,
        ownerDescription: String
    ) {
        self.runID = runID
        self.projectID = projectID
        self.conversationID = conversationID
        self.toolCallID = toolCallID
        self.source = source
        self.authorization = authorization
        let trimmedOwner = ownerDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ownerDescription = trimmedOwner.isEmpty ? source.rawValue : trimmedOwner
    }
}

struct WorkspaceMutationRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let workspaceName: String
    let workspaceIdentity: WorkspaceResourceIdentity
    let operation: WorkspaceMutationOperation
    let journalArgumentsJSON: String
    let context: WorkspaceMutationContext
    let requestedAt: Date

    init(
        id: UUID = UUID(),
        workspace: SandboxWorkspace,
        workspaceDisplayName: String? = nil,
        operation: WorkspaceMutationOperation,
        journalArgumentsJSON: String = "{}",
        context: WorkspaceMutationContext,
        requestedAt: Date = Date()
    ) throws {
        self.id = id
        let requestedName = workspaceDisplayName ?? workspace.workspaceName
        let trimmedWorkspace = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workspaceName = trimmedWorkspace.isEmpty ? "Default" : trimmedWorkspace
        self.workspaceIdentity = try WorkspaceResourceIdentity(workspace: workspace)
        self.operation = operation
        self.journalArgumentsJSON = journalArgumentsJSON
        self.context = context
        self.requestedAt = requestedAt
    }
}

struct WorkspaceMutationEffect: Equatable, Sendable {
    let summary: String
    let changedPaths: [String]

    init(summary: String, changedPaths: [String] = []) {
        self.summary = summary
        self.changedPaths = changedPaths
    }
}

struct WorkspaceMutationResult: Equatable, Sendable {
    let operationID: UUID
    let workspaceName: String
    let workspaceResourceKey: String
    let operation: WorkspaceMutationOperation
    let effect: WorkspaceMutationEffect
    let requestedAt: Date
    let leaseAcquiredAt: Date
    let completedAt: Date

    var leaseWaitDuration: TimeInterval {
        max(0, leaseAcquiredAt.timeIntervalSince(requestedAt))
    }
}

/// The concrete raw operation a backend is about to perform. Backends validate
/// this immediately before touching bytes; it is deliberately separate from
/// the higher-level journal operation so composite seeds and terminal commands
/// can grant only the exact primitives they require.
enum WorkspaceMutationCapabilityOperation: Equatable, Sendable {
    case writeFile(path: String)
    case appendFile(path: String)
    case createFile(path: String)
    case touchFile(path: String)
    case createDirectory(path: String)
    case deletePath(path: String)
    case movePath(from: String, to: String)
    case copyPath(from: String, to: String)
    case replaceText(path: String)
    case terminalCommand(command: String, targetPaths: [String])
    case resetWorkspace
}

enum WorkspaceMutationPermitError: LocalizedError, Equatable, Sendable {
    case revoked(operationID: UUID)
    case workspaceMismatch(operationID: UUID)
    case operationMismatch(operationID: UUID)

    var errorDescription: String? {
        switch self {
        case .revoked:
            "The workspace mutation capability is no longer active."
        case .workspaceMismatch:
            "The workspace mutation capability belongs to a different workspace."
        case .operationMismatch:
            "The workspace mutation capability does not authorize that operation or path."
        }
    }
}

/// A sealed, request-bound capability. Every copy shares one lock-protected
/// lifetime, so a permit captured by a child task becomes unusable as soon as
/// the gateway's effect closure returns or throws.
struct WorkspaceMutationPermit: Sendable {
    private let state: WorkspaceMutationCapabilityState

    fileprivate init(request: WorkspaceMutationRequest) {
        state = WorkspaceMutationCapabilityState(request: request)
    }

    func validate(
        workspace: SandboxWorkspace,
        operation: WorkspaceMutationCapabilityOperation
    ) throws {
        let identity = try WorkspaceResourceIdentity(workspace: workspace)
        try state.validate(
            workspace: workspace,
            workspaceResourceKey: identity.resourceKey,
            operation: operation
        )
    }

    fileprivate func revoke() {
        state.revoke()
    }
}

private final class WorkspaceMutationCapabilityState: @unchecked Sendable {
    private let lock = NSLock()
    private let operationID: UUID
    private let workspaceResourceKey: String
    private let grant: WorkspaceMutationOperation
    private var isActive = true

    init(request: WorkspaceMutationRequest) {
        operationID = request.id
        workspaceResourceKey = request.workspaceIdentity.resourceKey
        grant = request.operation
    }

    func validate(
        workspace: SandboxWorkspace,
        workspaceResourceKey candidateResourceKey: String,
        operation: WorkspaceMutationCapabilityOperation
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        guard isActive else {
            throw WorkspaceMutationPermitError.revoked(operationID: operationID)
        }
        guard candidateResourceKey == workspaceResourceKey else {
            throw WorkspaceMutationPermitError.workspaceMismatch(operationID: operationID)
        }
        guard try authorizes(operation, in: workspace) else {
            throw WorkspaceMutationPermitError.operationMismatch(operationID: operationID)
        }
    }

    func revoke() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    private func authorizes(
        _ attempted: WorkspaceMutationCapabilityOperation,
        in workspace: SandboxWorkspace
    ) throws -> Bool {
        switch grant {
        case .writeFile(let path):
            return try matchesSinglePath(attempted, expected: .writeFile(path: path), workspace: workspace)
        case .appendFile(let path):
            return try matchesSinglePath(attempted, expected: .appendFile(path: path), workspace: workspace)
        case .createFile(let path):
            return try matchesSinglePath(attempted, expected: .createFile(path: path), workspace: workspace)
        case .touchFile(let path):
            return try matchesSinglePath(attempted, expected: .touchFile(path: path), workspace: workspace)
        case .createDirectory(let path):
            return try matchesSinglePath(attempted, expected: .createDirectory(path: path), workspace: workspace)
        case .deletePath(let path):
            return try matchesSinglePath(attempted, expected: .deletePath(path: path), workspace: workspace)
        case .movePath(let source, let destination):
            guard case .movePath(let attemptedSource, let attemptedDestination) = attempted else { return false }
            return try canonicalPath(source, workspace: workspace) == canonicalPath(attemptedSource, workspace: workspace) &&
                canonicalPath(destination, workspace: workspace) == canonicalPath(attemptedDestination, workspace: workspace)
        case .copyPath(let source, let destination):
            guard case .copyPath(let attemptedSource, let attemptedDestination) = attempted else { return false }
            return try canonicalPath(source, workspace: workspace) == canonicalPath(attemptedSource, workspace: workspace) &&
                canonicalPath(destination, workspace: workspace) == canonicalPath(attemptedDestination, workspace: workspace)
        case .terminalCommand(let command, _):
            return try terminalCommand(command, authorizes: attempted, workspace: workspace)
        case .resetWorkspace:
            if case .resetWorkspace = attempted { return true }
            return false
        case .seedWorkspace(let paths):
            return try seedPaths(paths, authorize: attempted, workspace: workspace)
        case .agentTool(let name, let paths):
            return try agentTool(name, paths: paths, authorizes: attempted, workspace: workspace)
        }
    }

    private func matchesSinglePath(
        _ attempted: WorkspaceMutationCapabilityOperation,
        expected: WorkspaceMutationCapabilityOperation,
        workspace: SandboxWorkspace
    ) throws -> Bool {
        let expectedPair = singlePathAndKind(expected)
        let attemptedPair = singlePathAndKind(attempted)
        guard let expectedPair, let attemptedPair,
              expectedPair.kind == attemptedPair.kind else { return false }
        return try canonicalPath(expectedPair.path, workspace: workspace) ==
            canonicalPath(attemptedPair.path, workspace: workspace)
    }

    private func singlePathAndKind(
        _ operation: WorkspaceMutationCapabilityOperation
    ) -> (path: String, kind: String)? {
        switch operation {
        case .writeFile(let path): (path, "write")
        case .appendFile(let path): (path, "append")
        case .createFile(let path): (path, "create_file")
        case .touchFile(let path): (path, "touch")
        case .createDirectory(let path): (path, "create_directory")
        case .deletePath(let path): (path, "delete")
        case .replaceText(let path): (path, "replace_text")
        case .movePath, .copyPath, .terminalCommand, .resetWorkspace: nil
        }
    }

    private func seedPaths(
        _ grantedPaths: [String],
        authorize attempted: WorkspaceMutationCapabilityOperation,
        workspace: SandboxWorkspace
    ) throws -> Bool {
        guard let attemptedPair = singlePathAndKind(attempted),
              ["write", "create_file", "create_directory"].contains(attemptedPair.kind) else {
            return false
        }
        let allowed = try Set(grantedPaths.map { try canonicalPath($0, workspace: workspace) })
        return try allowed.contains(canonicalPath(attemptedPair.path, workspace: workspace))
    }

    private func agentTool(
        _ name: String,
        paths: [String],
        authorizes attempted: WorkspaceMutationCapabilityOperation,
        workspace: SandboxWorkspace
    ) throws -> Bool {
        switch (name, attempted) {
        case ("write_file", .writeFile(let path)),
             ("append_file", .appendFile(let path)),
             ("make_directory", .createDirectory(let path)),
             ("delete_path", .deletePath(let path)),
             ("replace_text", .replaceText(let path)):
            guard paths.count == 1, let expected = paths.first else { return false }
            return try canonicalPath(expected, workspace: workspace) == canonicalPath(path, workspace: workspace)
        case ("move_path", .movePath(let source, let destination)),
             ("copy_path", .copyPath(let source, let destination)):
            guard paths.count == 2 else { return false }
            return try canonicalPath(paths[0], workspace: workspace) == canonicalPath(source, workspace: workspace) &&
                canonicalPath(paths[1], workspace: workspace) == canonicalPath(destination, workspace: workspace)
        default:
            return false
        }
    }

    private func terminalCommand(
        _ command: String,
        authorizes attempted: WorkspaceMutationCapabilityOperation,
        workspace: SandboxWorkspace
    ) throws -> Bool {
        let draft = TerminalCommandDraft(command)
        guard draft.isMutating, draft.argumentIssue == nil else { return false }
        let targets = WorkspaceMutationOperation.terminalTargetPaths(for: command)

        if case .terminalCommand(let attemptedCommand, let attemptedTargets) = attempted {
            guard TerminalCommandDraft(attemptedCommand).commandLine == draft.commandLine else { return false }
            return try canonicalPaths(attemptedTargets, workspace: workspace) ==
                canonicalPaths(targets, workspace: workspace)
        }

        guard let commandName = draft.commandName else { return false }
        switch (commandName, attempted) {
        case ("mkdir", .createDirectory(let path)):
            return try matchesTerminalTarget(path, index: 0, targets: targets, workspace: workspace)
        case ("touch", .touchFile(let path)):
            return try matchesTerminalTarget(path, index: 0, targets: targets, workspace: workspace)
        case ("rm", .deletePath(let path)):
            return try matchesTerminalTarget(path, index: 0, targets: targets, workspace: workspace)
        case ("mv", .movePath(let source, let destination)),
             ("cp", .copyPath(let source, let destination)):
            guard targets.count == 2 else { return false }
            return try canonicalPath(targets[0], workspace: workspace) == canonicalPath(source, workspace: workspace) &&
                canonicalPath(targets[1], workspace: workspace) == canonicalPath(destination, workspace: workspace)
        default:
            return false
        }
    }

    private func matchesTerminalTarget(
        _ path: String,
        index: Int,
        targets: [String],
        workspace: SandboxWorkspace
    ) throws -> Bool {
        guard targets.indices.contains(index) else { return false }
        return try canonicalPath(targets[index], workspace: workspace) == canonicalPath(path, workspace: workspace)
    }

    private func canonicalPaths(
        _ paths: [String],
        workspace: SandboxWorkspace
    ) throws -> [String] {
        try paths.map { try canonicalPath($0, workspace: workspace) }
    }

    private func canonicalPath(
        _ path: String,
        workspace: SandboxWorkspace
    ) throws -> String {
        try workspace.resolve(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .precomposedStringWithCanonicalMapping
    }
}

enum WorkspaceMutationGatewayError: LocalizedError, Equatable, Sendable {
    case journalPersistenceFailed(
        operationID: UUID,
        attemptedPhase: ToolOperationPhase,
        effectDispatched: Bool,
        message: String
    )
    case cancelledBeforeExecution(operationID: UUID)
    case coordinationFailed(operationID: UUID, message: String)
    case effectMayHaveApplied(operationID: UUID, message: String)
    case replayRequiresInspection(operationID: UUID, phase: ToolOperationPhase)
    case durableSettlementFailed(
        operationID: UUID,
        lastDurablePhase: ToolOperationPhase,
        message: String
    )

    var errorDescription: String? {
        switch self {
        case .journalPersistenceFailed(_, let attemptedPhase, let effectDispatched, let message):
            let effectState = effectDispatched ? "after the effect started" : "before any effect started"
            return "NovaForge could not persist the \(attemptedPhase.rawValue) workspace receipt \(effectState): \(message)"
        case .cancelledBeforeExecution:
            return "The workspace mutation was cancelled before it started."
        case .coordinationFailed(_, let message):
            return "NovaForge could not coordinate exclusive workspace access: \(message)"
        case .effectMayHaveApplied(_, let message):
            return "The workspace mutation may have applied and must be inspected before retrying: \(message)"
        case .replayRequiresInspection(_, let phase):
            return "The existing workspace receipt is \(phase.rawValue) and must be inspected before any retry."
        case .durableSettlementFailed(_, let lastDurablePhase, let message):
            return "The workspace effect finished ambiguously after the durable \(lastDurablePhase.rawValue) phase: \(message)"
        }
    }
}

/// The mandatory shared entry point for workspace effects. A scheduled receipt
/// commits before FIFO arbitration, executing commits before dispatch, and the
/// lease is retained until the concrete effect and durable settlement finish.
struct WorkspaceMutationGateway: Sendable {
    /// Operation IDs are globally idempotent, not merely root-local. Keeping
    /// this serializer process-wide prevents two gateway/journal actor instances
    /// from concurrently deciding that the same durable receipt may dispatch.
    private static let operationCoordinator = AgentExecutionCoordinator()

    private let coordinator: AgentExecutionCoordinator
    private let journal: any WorkspaceMutationJournaling

    fileprivate init(
        coordinator: AgentExecutionCoordinator,
        journal: any WorkspaceMutationJournaling
    ) {
        self.coordinator = coordinator
        self.journal = journal
    }

    #if AGENTPAD_TESTING
    /// The injected construction seam exists only in the test target. App code
    /// receives gateways from `WorkspaceMutationGatewayFactory`, which always
    /// supplies the shared production coordinator and durable SwiftData journal.
    static func testing(
        coordinator: AgentExecutionCoordinator,
        journal: any WorkspaceMutationJournaling
    ) -> WorkspaceMutationGateway {
        WorkspaceMutationGateway(coordinator: coordinator, journal: journal)
    }
    #endif

    func perform(
        _ request: WorkspaceMutationRequest,
        effect: @Sendable (WorkspaceMutationPermit) async throws -> WorkspaceMutationEffect
    ) async throws -> WorkspaceMutationResult {
        let operationLease: AgentExecutionCoordinator.Lease
        do {
            operationLease = try await Self.operationCoordinator.acquireMutation(
                workspaceName: "operation:\(request.id.uuidString.lowercased())",
                runID: request.id,
                ownerDescription: request.context.ownerDescription
            )
        } catch is CancellationError {
            // Another invocation may own and be actively settling this same
            // receipt. A cancelled waiter must never mark that shared receipt.
            throw WorkspaceMutationGatewayError.cancelledBeforeExecution(operationID: request.id)
        } catch {
            throw WorkspaceMutationGatewayError.coordinationFailed(
                operationID: request.id,
                message: error.localizedDescription
            )
        }

        let outcome = await performWhileHoldingOperationLease(request, effect: effect)
        await Self.operationCoordinator.release(operationLease)
        return try outcome.get()
    }

    private func performWhileHoldingOperationLease(
        _ request: WorkspaceMutationRequest,
        effect: @Sendable (WorkspaceMutationPermit) async throws -> WorkspaceMutationEffect
    ) async -> Result<WorkspaceMutationResult, WorkspaceMutationGatewayError> {
        do {
            try await journal.schedule(WorkspaceMutationJournalEntry(request: request))
        } catch {
            return .failure(.journalPersistenceFailed(
                operationID: request.id,
                attemptedPhase: .scheduled,
                effectDispatched: false,
                message: error.localizedDescription
            ))
        }

        let durableSnapshot: WorkspaceMutationJournalSnapshot
        do {
            guard let snapshot = try await journal.snapshot(operationID: request.id) else {
                return .failure(.journalPersistenceFailed(
                    operationID: request.id,
                    attemptedPhase: .scheduled,
                    effectDispatched: false,
                    message: "The scheduled workspace receipt could not be read back."
                ))
            }
            durableSnapshot = snapshot
        } catch {
            return .failure(.journalPersistenceFailed(
                operationID: request.id,
                attemptedPhase: .scheduled,
                effectDispatched: false,
                message: error.localizedDescription
            ))
        }

        switch durableSnapshot.phase {
        case .completed:
            return replayResult(request, snapshot: durableSnapshot)
        case .applied:
            do {
                try await journal.transition(
                    operationID: request.id,
                    to: .completed,
                    resultSummary: durableSnapshot.resultSummary
                )
            } catch {
                return .failure(.durableSettlementFailed(
                    operationID: request.id,
                    lastDurablePhase: .applied,
                    message: error.localizedDescription
                ))
            }
            return replayResult(request, snapshot: durableSnapshot, completedAt: Date())
        case .executing, .interrupted, .failed:
            return .failure(.replayRequiresInspection(
                operationID: request.id,
                phase: durableSnapshot.phase
            ))
        case .scheduled:
            break
        }

        let lease: AgentExecutionCoordinator.Lease
        do {
            lease = try await coordinator.acquireMutation(
                workspaceName: request.workspaceIdentity.resourceKey,
                runID: request.context.runID ?? request.id,
                ownerDescription: request.context.ownerDescription
            )
        } catch is CancellationError {
            do {
                try await journal.transition(
                    operationID: request.id,
                    to: .interrupted,
                    errorMessage: "Cancelled while waiting for exclusive workspace access. No effect was dispatched."
                )
            } catch {
                return .failure(.journalPersistenceFailed(
                    operationID: request.id,
                    attemptedPhase: .interrupted,
                    effectDispatched: false,
                    message: error.localizedDescription
                ))
            }
            return .failure(.cancelledBeforeExecution(operationID: request.id))
        } catch {
            let coordinationMessage = error.localizedDescription
            do {
                try await journal.transition(
                    operationID: request.id,
                    to: .interrupted,
                    errorMessage: "Exclusive workspace access failed before effect dispatch: \(coordinationMessage)"
                )
            } catch {
                return .failure(.journalPersistenceFailed(
                    operationID: request.id,
                    attemptedPhase: .interrupted,
                    effectDispatched: false,
                    message: error.localizedDescription
                ))
            }
            return .failure(.coordinationFailed(
                operationID: request.id,
                message: coordinationMessage
            ))
        }

        let outcome = await performWhileHoldingLease(request, lease: lease, effect: effect)
        await coordinator.release(lease)
        return outcome
    }

    private func replayResult(
        _ request: WorkspaceMutationRequest,
        snapshot: WorkspaceMutationJournalSnapshot,
        completedAt: Date? = nil
    ) -> Result<WorkspaceMutationResult, WorkspaceMutationGatewayError> {
        guard let resultSummary = snapshot.resultSummary else {
            return .failure(.journalPersistenceFailed(
                operationID: request.id,
                attemptedPhase: snapshot.phase,
                effectDispatched: false,
                message: "The durable workspace receipt is missing its result summary."
            ))
        }
        return .success(WorkspaceMutationResult(
            operationID: request.id,
            workspaceName: request.workspaceName,
            workspaceResourceKey: request.workspaceIdentity.resourceKey,
            operation: request.operation,
            effect: WorkspaceMutationEffect(
                summary: resultSummary,
                changedPaths: snapshot.targetPaths
            ),
            requestedAt: snapshot.scheduledAt,
            leaseAcquiredAt: snapshot.startedAt ?? snapshot.scheduledAt,
            completedAt: completedAt ?? snapshot.completedAt ?? Date()
        ))
    }

    private func performWhileHoldingLease(
        _ request: WorkspaceMutationRequest,
        lease: AgentExecutionCoordinator.Lease,
        effect: @Sendable (WorkspaceMutationPermit) async throws -> WorkspaceMutationEffect
    ) async -> Result<WorkspaceMutationResult, WorkspaceMutationGatewayError> {
        do {
            try Task.checkCancellation()
        } catch {
            return await settleSafeCancellation(request)
        }

        do {
            try await journal.transition(operationID: request.id, to: .executing)
        } catch {
            let persistenceMessage = error.localizedDescription
            // Best effort leaves a truthful terminal marker if the injected or
            // transient failure was specific to the executing transition.
            try? await journal.transition(
                operationID: request.id,
                to: .interrupted,
                errorMessage: "Execution receipt could not advance. No effect was dispatched."
            )
            return .failure(.journalPersistenceFailed(
                operationID: request.id,
                attemptedPhase: .executing,
                effectDispatched: false,
                message: persistenceMessage
            ))
        }

        do {
            try Task.checkCancellation()
        } catch {
            return await settleSafeCancellation(request)
        }

        // This is the irreversible dispatch boundary. Execute inline so this
        // task owns the effect, journal settlement, and lease in one lifetime.
        let mutationEffect: WorkspaceMutationEffect
        let permit = WorkspaceMutationPermit(request: request)
        do {
            defer { permit.revoke() }
            mutationEffect = try await effect(permit)
        } catch {
            let effectMessage = error.localizedDescription
            do {
                try await journal.transition(
                    operationID: request.id,
                    to: .interrupted,
                    errorMessage: "Effect was dispatched and may have applied: \(effectMessage)"
                )
                return .failure(.effectMayHaveApplied(
                    operationID: request.id,
                    message: effectMessage
                ))
            } catch {
                return .failure(.durableSettlementFailed(
                    operationID: request.id,
                    lastDurablePhase: .executing,
                    message: "Effect error: \(effectMessage). Receipt error: \(error.localizedDescription)"
                ))
            }
        }

        do {
            try await journal.transition(
                operationID: request.id,
                to: .applied,
                resultSummary: mutationEffect.summary
            )
        } catch {
            let appliedReceiptMessage = error.localizedDescription
            do {
                try await journal.transition(
                    operationID: request.id,
                    to: .interrupted,
                    resultSummary: mutationEffect.summary,
                    errorMessage: "Effect returned success, but the applied receipt failed. Inspect before retrying."
                )
                return .failure(.durableSettlementFailed(
                    operationID: request.id,
                    lastDurablePhase: .interrupted,
                    message: appliedReceiptMessage
                ))
            } catch {
                return .failure(.durableSettlementFailed(
                    operationID: request.id,
                    lastDurablePhase: .executing,
                    message: "Applied receipt error: \(appliedReceiptMessage). Ambiguity receipt error: \(error.localizedDescription)"
                ))
            }
        }

        do {
            try await journal.transition(
                operationID: request.id,
                to: .completed,
                resultSummary: mutationEffect.summary
            )
        } catch {
            return .failure(.durableSettlementFailed(
                operationID: request.id,
                lastDurablePhase: .applied,
                message: error.localizedDescription
            ))
        }

        return .success(WorkspaceMutationResult(
            operationID: request.id,
            workspaceName: request.workspaceName,
            workspaceResourceKey: request.workspaceIdentity.resourceKey,
            operation: request.operation,
            effect: mutationEffect,
            requestedAt: request.requestedAt,
            leaseAcquiredAt: lease.acquiredAt,
            completedAt: Date()
        ))
    }

    private func settleSafeCancellation(
        _ request: WorkspaceMutationRequest
    ) async -> Result<WorkspaceMutationResult, WorkspaceMutationGatewayError> {
        do {
            try await journal.transition(
                operationID: request.id,
                to: .interrupted,
                errorMessage: "Cancelled before effect dispatch. No workspace bytes changed."
            )
            return .failure(.cancelledBeforeExecution(operationID: request.id))
        } catch {
            return .failure(.journalPersistenceFailed(
                operationID: request.id,
                attemptedPhase: .interrupted,
                effectDispatched: false,
                message: error.localizedDescription
            ))
        }
    }
}

import AgentDomain
import Foundation
import SwiftData

/// Finite, presentation-safe failures for activity-originated commands.
/// Dependency errors are deliberately collapsed so provider, journal, path,
/// and engine details cannot escape through the UI boundary.
enum AgentSystemActivityCommandRouterError: Error, Equatable, Sendable {
    case projectionUnavailable
    case projectionCardinalityMismatch
    case projectionIdentityMismatch
    case staleActivityCommand
    case registryUnavailable
    case registeredHandleCardinalityMismatch
    case registeredHandleIdentityMismatch
    case conflictingRetainedOperation
    case operationCapacityExceeded
    case dispatchUnavailable
}

enum AgentSystemActivityExecutionKind: String, Equatable, Sendable {
    case cancellation
    case approvalDecision
}

/// Navigation is an explicit handoff to the owning UI surface. These values
/// never enter AgentSystem, AgentRuntime, or an engine from this router.
enum AgentSystemActivityNavigation: Equatable, Sendable {
    case retry(AgentActivityRetryCommand)
    case receipt(AgentActivityRunCommand)
    case artifact(AgentActivityArtifactCommand)
}

enum AgentSystemActivityCommandResult: Equatable, Sendable {
    case executed(
        kind: AgentSystemActivityExecutionKind,
        commandID: CommandID
    )
    case navigation(AgentSystemActivityNavigation)
}

/// Canonical command boundary for controls rendered from AgentActivityGroup.
///
/// Executing controls are reloaded from the exact journal scope and checked
/// against the live AgentSystem registry before a newly minted typed command
/// can be dispatched. Navigation controls receive the same stale-projection
/// check but are returned to the caller without executing any runtime work.
actor AgentSystemActivityCommandRouter {
    typealias GroupLoader = @MainActor @Sendable (
        AgentActivityProjectionScope
    ) async throws -> [AgentActivityGroup]
    typealias RegisteredHandles = @Sendable () async throws -> [
        AgentSystemRunHandle
    ]
    typealias CancellationDispatcher = @Sendable (
        AgentCommand,
        AgentSystemRunHandle
    ) async throws -> Void
    typealias ApprovalDispatcher = @Sendable (
        AgentCommand,
        AgentSystemRunHandle
    ) async throws -> Void

    private struct Dependencies: Sendable {
        let loadGroups: GroupLoader
        let registeredHandles: RegisteredHandles
        let dispatchCancellation: CancellationDispatcher
        let dispatchApproval: ApprovalDispatcher
        let now: @Sendable () -> AgentInstant
        let makeCommandID: @Sendable () -> CommandID
        let makeCorrelationID: @Sendable () -> CorrelationID
    }

    private enum SemanticExecutionKey: Hashable, Sendable {
        case cancellation(AgentActivityRunIdentity)
        case approval(
            run: AgentActivityRunIdentity,
            requestID: ApprovalRequestID,
            callID: ToolCallID
        )

        init?(_ command: AgentActivityCommand) {
            switch command {
            case let .cancel(value):
                self = .cancellation(value.run)
            case let .resolveApproval(value):
                self = .approval(
                    run: value.run,
                    requestID: value.requestID,
                    callID: value.callID
                )
            case .retry, .openReceipt, .openArtifact:
                return nil
            }
        }
    }

    private struct RetainedOperation: Sendable {
        let activityCommand: AgentActivityCommand
        let task: Task<AgentSystemActivityCommandResult, any Error>
        var isComplete: Bool
    }

    /// An upper bound prevents an accidentally unbounded caller-selected
    /// retention window even before the configured limit is applied.
    static let maximumRetainedOperationLimit = 256

    private let dependencies: Dependencies
    private let retainedOperationLimit: Int
    private var retainedOperations: [
        SemanticExecutionKey: RetainedOperation
    ] = [:]
    private var retentionOrder: [SemanticExecutionKey] = []

    init(
        maximumRetainedOperations: Int = 64,
        loadGroups: @escaping GroupLoader,
        registeredHandles: @escaping RegisteredHandles,
        dispatchCancellation: @escaping CancellationDispatcher,
        dispatchApproval: @escaping ApprovalDispatcher,
        now: @escaping @Sendable () -> AgentInstant = {
            AgentInstant(Date())
        },
        makeCommandID: @escaping @Sendable () -> CommandID = {
            CommandID(rawValue: UUID())
        },
        makeCorrelationID: @escaping @Sendable () -> CorrelationID = {
            CorrelationID(rawValue: UUID())
        }
    ) {
        retainedOperationLimit = min(
            max(1, maximumRetainedOperations),
            Self.maximumRetainedOperationLimit
        )
        dependencies = Dependencies(
            loadGroups: loadGroups,
            registeredHandles: registeredHandles,
            dispatchCancellation: dispatchCancellation,
            dispatchApproval: dispatchApproval,
            now: now,
            makeCommandID: makeCommandID,
            makeCorrelationID: makeCorrelationID
        )
    }

    /// Production construction keeps SwiftData reads on MainActor and makes
    /// AgentSystem.shared the only execution authority.
    @MainActor
    static func production(
        container: ModelContainer,
        maximumRetainedOperations: Int = 64
    ) -> AgentSystemActivityCommandRouter {
        AgentSystemActivityCommandRouter(
            maximumRetainedOperations: maximumRetainedOperations,
            loadGroups: { scope in
                try await AgentCanonicalActivityRepository(
                    container: container
                ).groups(in: scope)
            },
            registeredHandles: {
                await AgentSystem.shared.registeredHandles()
            },
            dispatchCancellation: { command, handle in
                _ = try await AgentSystem.shared.cancel(command, for: handle)
            },
            dispatchApproval: { command, handle in
                try await AgentSystem.shared.deliverApprovalDecision(
                    command,
                    for: handle
                )
            }
        )
    }

    func route(
        _ command: AgentActivityCommand
    ) async throws -> AgentSystemActivityCommandResult {
        guard let key = SemanticExecutionKey(command) else {
            return try await Self.navigationResult(
                for: command,
                loadGroups: dependencies.loadGroups
            )
        }

        if let retained = retainedOperations[key] {
            guard retained.activityCommand == command else {
                throw AgentSystemActivityCommandRouterError
                    .conflictingRetainedOperation
            }
            return try await finish(retained.task, for: key)
        }

        discardCompletedOperationsUntilCapacityIsAvailable()
        guard retainedOperations.count < retainedOperationLimit else {
            throw AgentSystemActivityCommandRouterError
                .operationCapacityExceeded
        }

        let commandID = dependencies.makeCommandID()
        let correlationID = dependencies.makeCorrelationID()
        let issuedAt = dependencies.now()
        let dependencies = dependencies
        let task: Task<AgentSystemActivityCommandResult, any Error> = Task.detached {
            try await Self.execute(
                command,
                commandID: commandID,
                correlationID: correlationID,
                issuedAt: issuedAt,
                dependencies: dependencies
            )
        }
        retainedOperations[key] = RetainedOperation(
            activityCommand: command,
            task: task,
            isComplete: false
        )
        retentionOrder.append(key)
        return try await finish(task, for: key)
    }

    private func finish(
        _ task: Task<AgentSystemActivityCommandResult, any Error>,
        for key: SemanticExecutionKey
    ) async throws -> AgentSystemActivityCommandResult {
        do {
            let result = try await task.value
            markComplete(key)
            return result
        } catch {
            markComplete(key)
            if let finiteError = error as? AgentSystemActivityCommandRouterError {
                throw finiteError
            }
            throw AgentSystemActivityCommandRouterError.dispatchUnavailable
        }
    }

    private func markComplete(_ key: SemanticExecutionKey) {
        guard var retained = retainedOperations[key] else { return }
        retained.isComplete = true
        retainedOperations[key] = retained
    }

    private func discardCompletedOperationsUntilCapacityIsAvailable() {
        while retainedOperations.count >= retainedOperationLimit,
              let index = retentionOrder.firstIndex(where: {
                  retainedOperations[$0]?.isComplete == true
              })
        {
            let key = retentionOrder.remove(at: index)
            retainedOperations.removeValue(forKey: key)
        }
    }

    private static func execute(
        _ activityCommand: AgentActivityCommand,
        commandID: CommandID,
        correlationID: CorrelationID,
        issuedAt: AgentInstant,
        dependencies: Dependencies
    ) async throws -> AgentSystemActivityCommandResult {
        let group = try await validatedGroup(
            accepting: activityCommand,
            loadGroups: dependencies.loadGroups
        )
        let handle = try await validatedRegisteredHandle(
            for: group.identity,
            registeredHandles: dependencies.registeredHandles
        )

        switch activityCommand {
        case .cancel:
            let command = AgentSystemCommandFactory.cancel(
                commandID: commandID,
                runID: group.identity.runID,
                issuedAt: issuedAt,
                correlationID: correlationID
            )
            do {
                try await dependencies.dispatchCancellation(command, handle)
            } catch {
                throw AgentSystemActivityCommandRouterError.dispatchUnavailable
            }
            return .executed(kind: .cancellation, commandID: commandID)

        case let .resolveApproval(value):
            let command = AgentSystemCommandFactory.approvalDecision(
                commandID: commandID,
                runID: group.identity.runID,
                correlationID: correlationID,
                causationID: nil,
                requestID: value.requestID,
                callID: value.callID,
                decision: value.decision,
                decidedAt: issuedAt
            )
            do {
                try await dependencies.dispatchApproval(command, handle)
            } catch {
                throw AgentSystemActivityCommandRouterError.dispatchUnavailable
            }
            return .executed(kind: .approvalDecision, commandID: commandID)

        case .retry, .openReceipt, .openArtifact:
            // SemanticExecutionKey prevents navigation from reaching here.
            throw AgentSystemActivityCommandRouterError.staleActivityCommand
        }
    }

    private static func navigationResult(
        for command: AgentActivityCommand,
        loadGroups: GroupLoader
    ) async throws -> AgentSystemActivityCommandResult {
        _ = try await validatedGroup(
            accepting: command,
            loadGroups: loadGroups
        )
        switch command {
        case let .retry(value):
            return .navigation(.retry(value))
        case let .openReceipt(value):
            return .navigation(.receipt(value))
        case let .openArtifact(value):
            return .navigation(.artifact(value))
        case .cancel, .resolveApproval:
            throw AgentSystemActivityCommandRouterError.staleActivityCommand
        }
    }

    private static func validatedGroup(
        accepting command: AgentActivityCommand,
        loadGroups: GroupLoader
    ) async throws -> AgentActivityGroup {
        let run = command.run
        let groups: [AgentActivityGroup]
        do {
            groups = try await loadGroups(AgentActivityProjectionScope(
                projectID: run.projectID,
                conversationID: run.conversationID,
                runID: run.runID
            ))
        } catch {
            throw AgentSystemActivityCommandRouterError.projectionUnavailable
        }
        guard groups.count == 1, let group = groups.first else {
            throw AgentSystemActivityCommandRouterError
                .projectionCardinalityMismatch
        }
        guard group.identity == run else {
            throw AgentSystemActivityCommandRouterError
                .projectionIdentityMismatch
        }
        guard group.accepts(command) else {
            throw AgentSystemActivityCommandRouterError.staleActivityCommand
        }
        return group
    }

    private static func validatedRegisteredHandle(
        for run: AgentActivityRunIdentity,
        registeredHandles: RegisteredHandles
    ) async throws -> AgentSystemRunHandle {
        let handles: [AgentSystemRunHandle]
        do {
            handles = try await registeredHandles()
        } catch {
            throw AgentSystemActivityCommandRouterError.registryUnavailable
        }

        let runMatches = handles.filter { $0.identity.runID == run.runID }
        guard runMatches.count == 1, let handle = runMatches.first else {
            throw AgentSystemActivityCommandRouterError
                .registeredHandleCardinalityMismatch
        }
        guard handle.identity.conversationID == run.conversationID,
              handle.identity.projectID == run.projectID,
              handle.identity.workspaceID == run.workspaceID,
              handle.identity.rootRunID == run.rootRunID,
              handle.ownerFence.runID == run.runID
        else {
            throw AgentSystemActivityCommandRouterError
                .registeredHandleIdentityMismatch
        }

        return handle
    }
}

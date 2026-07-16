import AgentDomain
import AgentEngine
import AgentProviders
import AgentTools
import CryptoKit
import Foundation

enum AgentSystemError: Error, Equatable, Sendable {
    case productionCompositionUnavailable
    case startupUnconfigured
    case startupReconciliationInProgress(UUID)
    case startupReconciliationFailed(UUID)
    case startupCompositionConflict(active: UUID, requested: UUID)
    case startupAlreadyConfigured
    case startupInstallationTooLate
    case recoveryUnavailable
    case recoveryAlreadyInProgress
    case invalidCommand
    case commandIDCollision(CommandID)
    case freshRunPlanCollision(CommandID)
    case commandCapacityExceeded
    case registryCapacityExceeded
    case runAwaitingRecovery(RunID)
    case runAlreadyRegistered(RunID)
    case runStartInProgress(RunID)
    case runNotRegistered(RunID)
    case staleHandle(RunID)
    case engineIdentityMismatch(RunID)
    case engineStateConflict(RunID)
    case invalidRecoveryQueue(RunID)
}

struct AgentSystemRunIdentity: Equatable, Hashable, Sendable {
    let runID: RunID
    let rootRunID: RunID
    let parentRunID: RunID?
    let conversationID: ConversationID
    let projectID: ProjectID?
    let workspaceID: WorkspaceID
    let executionNodeID: ExecutionNodeID
    let cancellationScopeID: CancellationScopeID

    init(context: AgentRunContext) {
        runID = context.lineage.runID
        rootRunID = context.lineage.rootRunID
        parentRunID = context.lineage.parentRunID
        conversationID = context.conversationID
        projectID = context.projectID
        workspaceID = context.workspaceID
        executionNodeID = context.executionNodeID
        cancellationScopeID = context.cancellation.scopeID
    }
}

/// Copyable authority reference for one engine owned by `AgentSystem`.
/// Every operation verifies both the complete run identity and the durable
/// engine-owner fence before it can reach the engine.
struct AgentSystemRunHandle: Equatable, Hashable, Sendable {
    let identity: AgentSystemRunIdentity
    let ownerFence: AgentEngineOwnerFence

    var runID: RunID { identity.runID }

    fileprivate var engineHandle: AgentEngineRunHandle {
        AgentEngineRunHandle(runID: runID, ownerFence: ownerFence)
    }
}

/// Credential-free immutable inputs required to build one fresh engine. The
/// eventual durable composition binds these values atomically with acceptance;
/// credentials and raw workspace paths are resolved only inside production
/// adapters and never enter this plan.
struct AgentSystemFreshRunPlan: Codable, Equatable, Sendable {
    let providerRoute: ProviderRoute
    let providerOptions: ProviderGenerationOptions
    let systemInstruction: String?
    let developerInstruction: String?
    let publicRequestSummary: String?
    let toolLocalities: [String: ToolExecutionLocality]
    let policyVersion: String
    let contextPreparationVersion: String
    let origin: AgentRunRecordOrigin

    init(
        providerRoute: ProviderRoute,
        providerOptions: ProviderGenerationOptions,
        systemInstruction: String?,
        developerInstruction: String?,
        publicRequestSummary: String? = nil,
        toolLocalities: [String: ToolExecutionLocality],
        policyVersion: String,
        contextPreparationVersion: String,
        origin: AgentRunRecordOrigin = .user
    ) {
        self.providerRoute = providerRoute
        self.providerOptions = providerOptions
        self.systemInstruction = systemInstruction
        self.developerInstruction = developerInstruction
        self.publicRequestSummary = publicRequestSummary
        self.toolLocalities = toolLocalities
        self.policyVersion = policyVersion
        self.contextPreparationVersion = contextPreparationVersion
        self.origin = origin
    }

    fileprivate func canonicalDigest() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(self)
        var input = Data("NovaForge.AgentSystemFreshRunPlan.v1".utf8)
        input.append(0)
        input.append(payload)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }
            .joined()
    }
}

enum AgentSystemEngineBuildRequest: Equatable, Sendable {
    case fresh(
        context: AgentRunContext,
        command: AgentCommand,
        plan: AgentSystemFreshRunPlan?
    )
    case recovery(runID: RunID)

    var runID: RunID {
        switch self {
        case let .fresh(context, _, _): context.lineage.runID
        case let .recovery(runID): runID
        }
    }
}

/// Narrow lifecycle seam around one real package engine. Provider routing,
/// tools, policy, storage, and model work remain exclusively in `AgentEngine`
/// and its injected package adapters.
protocol AgentSystemEngineControlling: Sendable {
    func agentSystemStart(
        _ command: AgentCommand
    ) async throws -> AgentEngineRunHandle

    func agentSystemRecover(
        runID: RunID
    ) async throws -> AgentEngineRunHandle

    func agentSystemWait(
        for handle: AgentEngineRunHandle
    ) async throws -> AgentDomain.AgentRunState

    func agentSystemSnapshot(
        for handle: AgentEngineRunHandle
    ) async throws -> AgentDomain.AgentRunState

    func agentSystemCancel(
        _ command: CancelCommand,
        runID: RunID
    ) async throws -> AgentDomain.AgentRunState

    func agentSystemDeliverApprovalDecision(
        _ command: ApprovalDecisionCommand,
        runID: RunID
    ) async throws
}

extension AgentEngine: AgentSystemEngineControlling {
    func agentSystemStart(
        _ command: AgentCommand
    ) async throws -> AgentEngineRunHandle {
        try await start(command)
    }

    func agentSystemRecover(
        runID: RunID
    ) async throws -> AgentEngineRunHandle {
        try await recover(runID: runID)
    }

    func agentSystemWait(
        for handle: AgentEngineRunHandle
    ) async throws -> AgentDomain.AgentRunState {
        try await wait(for: handle)
    }

    func agentSystemSnapshot(
        for handle: AgentEngineRunHandle
    ) async throws -> AgentDomain.AgentRunState {
        try snapshot(for: handle)
    }

    func agentSystemCancel(
        _ command: CancelCommand,
        runID: RunID
    ) async throws -> AgentDomain.AgentRunState {
        try await cancel(command, runID: runID)
    }

    func agentSystemDeliverApprovalDecision(
        _ command: ApprovalDecisionCommand,
        runID: RunID
    ) async throws {
        try await deliverApprovalDecision(command, runID: runID)
    }
}

/// Sendable factory used by the process host to build exactly one package
/// engine per registered run. The controller initializer is an internal test
/// seam; production composition uses the `AgentEngine` initializer.
struct AgentSystemEngineFactory: Sendable {
    private let builder: @Sendable (
        AgentSystemEngineBuildRequest
    ) async throws -> any AgentSystemEngineControlling

    init(
        buildAgentEngine: @escaping @Sendable (
            AgentSystemEngineBuildRequest
        ) async throws -> AgentEngine
    ) {
        builder = { request in
            try await buildAgentEngine(request)
        }
    }

    init(
        buildController: @escaping @Sendable (
            AgentSystemEngineBuildRequest
        ) async throws -> any AgentSystemEngineControlling
    ) {
        builder = buildController
    }

    fileprivate func makeEngine(
        for request: AgentSystemEngineBuildRequest
    ) async throws -> any AgentSystemEngineControlling {
        try await builder(request)
    }

    static let unavailable = AgentSystemEngineFactory(
        buildController: { _ in
            throw AgentSystemError.productionCompositionUnavailable
        }
    )
}

/// One process-owned composition for the shared V2 system. The opaque ID is
/// the idempotency identity for installation; a second value with the same ID
/// can observe the first installation but can never replace its authorities.
struct AgentSystemProductionComposition: Sendable {
    let id: UUID
    let engineFactory: AgentSystemEngineFactory
    let recoveryQueuePreparer: any AgentRecoveryQueuePreparing

    init(
        id: UUID,
        engineFactory: AgentSystemEngineFactory,
        recoveryQueuePreparer: any AgentRecoveryQueuePreparing
    ) {
        self.id = id
        self.engineFactory = engineFactory
        self.recoveryQueuePreparer = recoveryQueuePreparer
    }
}

/// Stable result of the pre-engine startup election and reconciliation pass.
/// `recoveryFIFO` contains only accepted nonterminal runs and remains in exact
/// journal-acceptance order.
struct AgentSystemStartupReport: Equatable, Sendable {
    let compositionID: UUID
    let recoveryFIFO: [RunID]
}

enum AgentSystemRunOrigin: String, Equatable, Sendable {
    case fresh
    case recovery
}

struct AgentSystemRunProjection: Equatable, Sendable {
    let revision: UInt64
    let handle: AgentSystemRunHandle
    let origin: AgentSystemRunOrigin
    let state: AgentDomain.AgentRunState
}

enum AgentSystemObservationKind: String, Equatable, Sendable {
    case accepted
    case recovered
    case stateChanged
    case approvalDelivered
    case cancellationSettled
}

struct AgentSystemObservation: Equatable, Sendable {
    let kind: AgentSystemObservationKind
    let commandID: CommandID?
    let projection: AgentSystemRunProjection
}

typealias AgentSystemObserver = @Sendable (AgentSystemObservation) -> Void

/// Process-wide owner and registry for V2 run engines.
///
/// This actor does not schedule provider/model work and does not implement a
/// second run loop. Each operation delegates once to the run's package engine.
/// The shared instance intentionally fails closed until the production journal,
/// provider, tool, policy, approval, and durable-index adapters are composed.
actor AgentSystem {
    static let shared = AgentSystem()

    private struct ReadyRuntime: Sendable {
        let composition: AgentSystemProductionComposition?
        let engineFactory: AgentSystemEngineFactory
        let recoveryScanner: (any AgentAcceptedNonterminalRunScanning)?
        let preparedRecoveryFIFO: [RunID]?
        let preparedRecoveryRunIDs: Set<RunID>?
        let startupReport: AgentSystemStartupReport?

        var compositionID: UUID? { composition?.id }
    }

    private enum StartupState {
        case unconfigured
        case reconciling(
            composition: AgentSystemProductionComposition,
            preparation: Task<[RunID], any Error>
        )
        case ready(ReadyRuntime)
        case failed(
            id: UUID,
            composition: AgentSystemProductionComposition
        )
    }

    private struct Entry: Sendable {
        let engine: any AgentSystemEngineControlling
        let handle: AgentSystemRunHandle
        let context: AgentRunContext
        let origin: AgentSystemRunOrigin
        var state: AgentDomain.AgentRunState
    }

    private enum OperationOutcome: Sendable {
        case started(
            engine: any AgentSystemEngineControlling,
            handle: AgentEngineRunHandle,
            state: AgentDomain.AgentRunState
        )
        case cancelled(AgentDomain.AgentRunState)
        case approvalDelivered(AgentDomain.AgentRunState)
    }

    private struct CommandRecord: Sendable {
        let command: AgentCommand
        let freshRunPlanDigest: String?
        let task: Task<OperationOutcome, any Error>
    }

    private let observer: AgentSystemObserver?
    private let maximumRunCount: Int
    private let maximumCommandCount: Int

    private var entries: [RunID: Entry] = [:]
    private var registrationOrder: [RunID] = []
    private var startingRuns: [RunID: CommandID] = [:]
    private var recoveringRuns: Set<RunID> = []
    private var commandRecords: [CommandID: CommandRecord] = [:]
    private var publishedCommandIDs: Set<CommandID> = []
    private var recoveryInProgress = false
    private var revision: UInt64 = 0
    private var startupState: StartupState

    /// Unconfigured construction is the shared production bootstrap state and
    /// an internal hostile-concurrency test seam. No engine operation is
    /// reachable until `installAndReconcile` succeeds.
    init() {
        observer = nil
        maximumRunCount = 65_536
        maximumCommandCount = 250_000
        startupState = .unconfigured
    }

    init(
        engineFactory: AgentSystemEngineFactory,
        recoveryScanner: (any AgentAcceptedNonterminalRunScanning)? = nil,
        maximumRunCount: Int = 65_536,
        maximumCommandCount: Int = 250_000,
        observer: AgentSystemObserver? = nil
    ) {
        self.maximumRunCount = max(1, maximumRunCount)
        self.maximumCommandCount = max(1, maximumCommandCount)
        self.observer = observer
        startupState = .ready(ReadyRuntime(
            composition: nil,
            engineFactory: engineFactory,
            recoveryScanner: recoveryScanner,
            preparedRecoveryFIFO: nil,
            preparedRecoveryRunIDs: nil,
            startupReport: nil
        ))
    }

    /// Installs the shared process composition exactly once and runs only the
    /// durable pre-engine reconciliation pass. Concurrent delivery of the same
    /// composition ID joins the one preparation task; no engine factory is
    /// reachable until the resulting FIFO has been validated and published as
    /// ready state.
    func installAndReconcile(
        _ composition: AgentSystemProductionComposition
    ) async throws -> AgentSystemStartupReport {
        switch startupState {
        case .unconfigured:
            guard !hasStartedRuntimeWork else {
                throw AgentSystemError.startupInstallationTooLate
            }
            let preparer = composition.recoveryQueuePreparer
            let preparation = Task<[RunID], any Error> {
                try await preparer.prepareRecoveryQueue()
            }
            startupState = .reconciling(
                composition: composition,
                preparation: preparation
            )
            return try await finishInstallation(
                composition: composition,
                preparation: preparation
            )

        case let .reconciling(active, preparation):
            guard active.id == composition.id else {
                throw AgentSystemError.startupCompositionConflict(
                    active: active.id,
                    requested: composition.id
                )
            }
            return try await finishInstallation(
                composition: active,
                preparation: preparation
            )

        case let .ready(runtime):
            guard !hasStartedRuntimeWork else {
                throw AgentSystemError.startupInstallationTooLate
            }
            if let activeID = runtime.compositionID {
                guard activeID == composition.id else {
                    throw AgentSystemError.startupCompositionConflict(
                        active: activeID,
                        requested: composition.id
                    )
                }
                guard let report = runtime.startupReport else {
                    throw AgentSystemError.startupReconciliationFailed(activeID)
                }
                return report
            }
            throw AgentSystemError.startupAlreadyConfigured

        case let .failed(activeID, _):
            guard activeID == composition.id else {
                throw AgentSystemError.startupCompositionConflict(
                    active: activeID,
                    requested: composition.id
                )
            }
            throw AgentSystemError.startupReconciliationFailed(activeID)
        }
    }

    /// Accepts one exact send command. Concurrent or later delivery of the
    /// identical command ID reuses its single in-flight/completed operation;
    /// conflicting reuse of that ID fails closed.
    func start(_ command: AgentCommand) async throws -> AgentSystemRunHandle {
        try await start(command, plan: nil)
    }

    /// Production start surface. The plan is command-idempotent: replaying an
    /// identical command with different route/context authority fails closed.
    func start(
        _ command: AgentCommand,
        plan: AgentSystemFreshRunPlan
    ) async throws -> AgentSystemRunHandle {
        try await start(command, plan: Optional(plan))
    }

    private func start(
        _ command: AgentCommand,
        plan: AgentSystemFreshRunPlan?
    ) async throws -> AgentSystemRunHandle {
        let runtime = try requireReadyRuntime()
        let planDigest: String?
        do {
            planDigest = try plan.map { try $0.canonicalDigest() }
        } catch {
            throw AgentSystemError.invalidCommand
        }
        if let existing = commandRecords[command.header.commandID] {
            guard existing.command == command else {
                throw AgentSystemError.commandIDCollision(command.header.commandID)
            }
            guard existing.freshRunPlanDigest == planDigest else {
                throw AgentSystemError.freshRunPlanCollision(
                    command.header.commandID
                )
            }
            return try await startedHandle(from: existing.task, command: command)
        }

        let context = try Self.validatedSendContext(command)
        let runID = context.lineage.runID
        if runtime.preparedRecoveryRunIDs?.contains(runID) == true,
           entries[runID] == nil
        {
            throw AgentSystemError.runAwaitingRecovery(runID)
        }
        if entries[runID] != nil {
            throw AgentSystemError.runAlreadyRegistered(runID)
        }
        if startingRuns[runID] != nil || recoveringRuns.contains(runID) {
            throw AgentSystemError.runStartInProgress(runID)
        }
        try reserveCapacityForCommandAndRun()

        let factory = runtime.engineFactory
        let request = AgentSystemEngineBuildRequest.fresh(
            context: context,
            command: command,
            plan: plan
        )
        let task = Task.detached {
            let engine = try await factory.makeEngine(for: request)
            let handle = try await engine.agentSystemStart(command)
            let state = try await engine.agentSystemSnapshot(for: handle)
            return OperationOutcome.started(
                engine: engine,
                handle: handle,
                state: state
            )
        }
        startingRuns[runID] = command.header.commandID
        commandRecords[command.header.commandID] = CommandRecord(
            command: command,
            freshRunPlanDigest: planDigest,
            task: task
        )
        return try await startedHandle(from: task, command: command)
    }

    /// Waits on the package engine's own driver. A late waiter can never
    /// regress a projection already advanced by cancellation or another wait.
    func wait(
        for handle: AgentSystemRunHandle
    ) async throws -> AgentDomain.AgentRunState {
        _ = try requireReadyRuntime()
        let entry = try requireEntry(for: handle)
        let state = try await entry.engine.agentSystemWait(
            for: handle.engineHandle
        )
        return try record(
            state,
            for: handle,
            kind: .stateChanged,
            commandID: nil,
            forceObservation: false
        )
    }

    func snapshot(
        for handle: AgentSystemRunHandle
    ) async throws -> AgentDomain.AgentRunState {
        _ = try requireReadyRuntime()
        let entry = try requireEntry(for: handle)
        let state = try await entry.engine.agentSystemSnapshot(
            for: handle.engineHandle
        )
        return try record(
            state,
            for: handle,
            kind: .stateChanged,
            commandID: nil,
            forceObservation: false
        )
    }

    /// Delivers an exact typed cancellation command and does not return until
    /// the package engine has drained cancellation and returned its settlement.
    func cancel(
        _ command: AgentCommand,
        for handle: AgentSystemRunHandle
    ) async throws -> AgentDomain.AgentRunState {
        _ = try requireReadyRuntime()
        if let existing = commandRecords[command.header.commandID] {
            guard existing.command == command else {
                throw AgentSystemError.commandIDCollision(command.header.commandID)
            }
            return try await cancelledState(
                from: existing.task,
                command: command,
                handle: handle
            )
        }

        let cancellation = try Self.validatedCancellation(
            command,
            runID: handle.runID
        )
        let entry = try requireEntry(for: handle)
        try reserveCommandCapacity()
        let task = Task.detached {
            let state = try await entry.engine.agentSystemCancel(
                cancellation,
                runID: handle.runID
            )
            return OperationOutcome.cancelled(state)
        }
        commandRecords[command.header.commandID] = CommandRecord(
            command: command,
            freshRunPlanDigest: nil,
            task: task
        )
        return try await cancelledState(
            from: task,
            command: command,
            handle: handle
        )
    }

    /// Hands one exact request/call-bound decision to the engine's approval
    /// broker. Duplicate delivery of the same command executes only once.
    func deliverApprovalDecision(
        _ command: AgentCommand,
        for handle: AgentSystemRunHandle
    ) async throws {
        _ = try requireReadyRuntime()
        if let existing = commandRecords[command.header.commandID] {
            guard existing.command == command else {
                throw AgentSystemError.commandIDCollision(command.header.commandID)
            }
            try await finishApproval(
                from: existing.task,
                command: command,
                handle: handle
            )
            return
        }

        let decision = try Self.validatedApprovalDecision(
            command,
            runID: handle.runID
        )
        let entry = try requireEntry(for: handle)
        try reserveCommandCapacity()
        let task = Task.detached {
            try await entry.engine.agentSystemDeliverApprovalDecision(
                decision,
                runID: handle.runID
            )
            let state = try await entry.engine.agentSystemSnapshot(
                for: handle.engineHandle
            )
            return OperationOutcome.approvalDelivered(state)
        }
        commandRecords[command.header.commandID] = CommandRecord(
            command: command,
            freshRunPlanDigest: nil,
            task: task
        )
        try await finishApproval(
            from: task,
            command: command,
            handle: handle
        )
    }

    /// Recovers only the scanner's accepted nonterminal snapshot, in its exact
    /// FIFO order. Recovery is fail-stop: earlier successfully fenced engines
    /// remain registered if a later recovery fails, and a retry reuses them.
    func recoverAcceptedRuns() async throws -> [AgentSystemRunHandle] {
        let runtime = try requireReadyRuntime()
        guard !recoveryInProgress else {
            throw AgentSystemError.recoveryAlreadyInProgress
        }
        recoveryInProgress = true
        defer { recoveryInProgress = false }

        let runIDs: [RunID]
        if let prepared = runtime.preparedRecoveryFIFO {
            runIDs = prepared
        } else if let recoveryScanner = runtime.recoveryScanner {
            runIDs = try await recoveryScanner.acceptedNonterminalRunIDs()
        } else {
            throw AgentSystemError.recoveryUnavailable
        }
        var seen: Set<RunID> = []
        var recovered: [AgentSystemRunHandle] = []
        recovered.reserveCapacity(runIDs.count)

        for runID in runIDs {
            guard seen.insert(runID).inserted else {
                throw AgentSystemError.invalidRecoveryQueue(runID)
            }
            if let entry = entries[runID] {
                recovered.append(entry.handle)
                continue
            }
            guard startingRuns[runID] == nil, !recoveringRuns.contains(runID) else {
                throw AgentSystemError.runStartInProgress(runID)
            }
            guard entries.count + startingRuns.count + recoveringRuns.count
                    < maximumRunCount
            else {
                throw AgentSystemError.registryCapacityExceeded
            }
            recoveringRuns.insert(runID)
            do {
                let engine = try await runtime.engineFactory.makeEngine(
                    for: .recovery(runID: runID)
                )
                let engineHandle = try await engine.agentSystemRecover(runID: runID)
                let state = try await engine.agentSystemSnapshot(for: engineHandle)
                let context = try Self.validatedEngineState(
                    state,
                    expectedRunID: runID,
                    expectedContext: nil,
                    engineHandle: engineHandle
                )
                let handle = AgentSystemRunHandle(
                    identity: AgentSystemRunIdentity(context: context),
                    ownerFence: engineHandle.ownerFence
                )
                guard entries[runID] == nil, startingRuns[runID] == nil else {
                    throw AgentSystemError.runAlreadyRegistered(runID)
                }
                recoveringRuns.remove(runID)
                entries[runID] = Entry(
                    engine: engine,
                    handle: handle,
                    context: context,
                    origin: .recovery,
                    state: state
                )
                registrationOrder.append(runID)
                publish(
                    kind: .recovered,
                    commandID: nil,
                    entry: entries[runID]!
                )
                recovered.append(handle)
            } catch {
                recoveringRuns.remove(runID)
                throw error
            }
        }
        return recovered
    }

    func registeredHandles() -> [AgentSystemRunHandle] {
        registrationOrder.compactMap { entries[$0]?.handle }
    }

    func activeHandles() -> [AgentSystemRunHandle] {
        registrationOrder.compactMap { runID in
            guard let entry = entries[runID], !entry.state.phase.isTerminal else {
                return nil
            }
            return entry.handle
        }
    }

    // MARK: Startup composition

    private func finishInstallation(
        composition: AgentSystemProductionComposition,
        preparation: Task<[RunID], any Error>
    ) async throws -> AgentSystemStartupReport {
        do {
            let recoveryFIFO = try await preparation.value
            try validatePreparedRecoveryFIFO(recoveryFIFO)
            let report = AgentSystemStartupReport(
                compositionID: composition.id,
                recoveryFIFO: recoveryFIFO
            )

            switch startupState {
            case let .ready(runtime):
                guard runtime.compositionID == composition.id,
                      let existing = runtime.startupReport
                else {
                    throw AgentSystemError.startupReconciliationFailed(
                        composition.id
                    )
                }
                return existing
            case let .reconciling(active, _):
                guard active.id == composition.id else {
                    throw AgentSystemError.startupCompositionConflict(
                        active: active.id,
                        requested: composition.id
                    )
                }
            case let .failed(activeID, _):
                guard activeID == composition.id else {
                    throw AgentSystemError.startupCompositionConflict(
                        active: activeID,
                        requested: composition.id
                    )
                }
                throw AgentSystemError.startupReconciliationFailed(activeID)
            case .unconfigured:
                throw AgentSystemError.startupReconciliationFailed(
                    composition.id
                )
            }

            startupState = .ready(ReadyRuntime(
                composition: composition,
                engineFactory: composition.engineFactory,
                recoveryScanner: nil,
                preparedRecoveryFIFO: recoveryFIFO,
                preparedRecoveryRunIDs: Set(recoveryFIFO),
                startupReport: report
            ))
            return report
        } catch let error as AgentSystemError {
            failInstallationIfCurrent(composition)
            throw error
        } catch {
            failInstallationIfCurrent(composition)
            throw AgentSystemError.startupReconciliationFailed(composition.id)
        }
    }

    private func validatePreparedRecoveryFIFO(_ runIDs: [RunID]) throws {
        guard runIDs.count <= maximumRunCount else {
            throw AgentSystemError.registryCapacityExceeded
        }
        var seen: Set<RunID> = []
        seen.reserveCapacity(runIDs.count)
        for runID in runIDs where !seen.insert(runID).inserted {
            throw AgentSystemError.invalidRecoveryQueue(runID)
        }
    }

    private func failInstallationIfCurrent(
        _ composition: AgentSystemProductionComposition
    ) {
        guard case let .reconciling(active, _) = startupState,
              active.id == composition.id
        else { return }
        // Retaining the composition also retains any process-lifetime
        // leadership lease owned by its queue preparer.
        startupState = .failed(
            id: composition.id,
            composition: active
        )
    }

    private var hasStartedRuntimeWork: Bool {
        !entries.isEmpty
            || !registrationOrder.isEmpty
            || !startingRuns.isEmpty
            || !recoveringRuns.isEmpty
            || !commandRecords.isEmpty
            || recoveryInProgress
    }

    private func requireReadyRuntime() throws -> ReadyRuntime {
        switch startupState {
        case let .ready(runtime):
            return runtime
        case .unconfigured:
            throw AgentSystemError.startupUnconfigured
        case let .reconciling(composition, _):
            throw AgentSystemError.startupReconciliationInProgress(
                composition.id
            )
        case let .failed(id, _):
            throw AgentSystemError.startupReconciliationFailed(id)
        }
    }

    // MARK: Command finalization

    private func startedHandle(
        from task: Task<OperationOutcome, any Error>,
        command: AgentCommand
    ) async throws -> AgentSystemRunHandle {
        let context = try Self.validatedSendContext(command)
        let runID = context.lineage.runID
        do {
            guard case let .started(engine, engineHandle, state) = try await task.value
            else { throw AgentSystemError.invalidCommand }
            let stateContext = try Self.validatedEngineState(
                state,
                expectedRunID: runID,
                expectedContext: context,
                engineHandle: engineHandle
            )
            let handle = AgentSystemRunHandle(
                identity: AgentSystemRunIdentity(context: stateContext),
                ownerFence: engineHandle.ownerFence
            )
            if let existing = entries[runID] {
                guard existing.handle == handle, existing.context == stateContext else {
                    throw AgentSystemError.runAlreadyRegistered(runID)
                }
                startingRuns.removeValue(forKey: runID)
                return existing.handle
            }
            guard startingRuns[runID] == command.header.commandID else {
                throw AgentSystemError.runAlreadyRegistered(runID)
            }
            startingRuns.removeValue(forKey: runID)
            let entry = Entry(
                engine: engine,
                handle: handle,
                context: stateContext,
                origin: .fresh,
                state: state
            )
            entries[runID] = entry
            registrationOrder.append(runID)
            publish(
                kind: .accepted,
                commandID: command.header.commandID,
                entry: entry
            )
            publishedCommandIDs.insert(command.header.commandID)
            return handle
        } catch {
            if startingRuns[runID] == command.header.commandID {
                startingRuns.removeValue(forKey: runID)
            }
            throw error
        }
    }

    private func cancelledState(
        from task: Task<OperationOutcome, any Error>,
        command: AgentCommand,
        handle: AgentSystemRunHandle
    ) async throws -> AgentDomain.AgentRunState {
        guard case let .cancelled(state) = try await task.value else {
            throw AgentSystemError.invalidCommand
        }
        let shouldPublish = publishedCommandIDs.insert(
            command.header.commandID
        ).inserted
        return try record(
            state,
            for: handle,
            kind: .cancellationSettled,
            commandID: command.header.commandID,
            forceObservation: shouldPublish
        )
    }

    private func finishApproval(
        from task: Task<OperationOutcome, any Error>,
        command: AgentCommand,
        handle: AgentSystemRunHandle
    ) async throws {
        guard case let .approvalDelivered(state) = try await task.value else {
            throw AgentSystemError.invalidCommand
        }
        let shouldPublish = publishedCommandIDs.insert(
            command.header.commandID
        ).inserted
        _ = try record(
            state,
            for: handle,
            kind: .approvalDelivered,
            commandID: command.header.commandID,
            forceObservation: shouldPublish
        )
    }

    // MARK: Registry and projection

    private func requireEntry(for handle: AgentSystemRunHandle) throws -> Entry {
        guard let entry = entries[handle.runID] else {
            throw AgentSystemError.runNotRegistered(handle.runID)
        }
        guard entry.handle == handle else {
            throw AgentSystemError.staleHandle(handle.runID)
        }
        return entry
    }

    private func record(
        _ candidate: AgentDomain.AgentRunState,
        for handle: AgentSystemRunHandle,
        kind: AgentSystemObservationKind,
        commandID: CommandID?,
        forceObservation: Bool
    ) throws -> AgentDomain.AgentRunState {
        var entry = try requireEntry(for: handle)
        _ = try Self.validatedEngineState(
            candidate,
            expectedRunID: handle.runID,
            expectedContext: entry.context,
            engineHandle: handle.engineHandle
        )

        let currentSequence = entry.state.lastSequence?.rawValue ?? 0
        let candidateSequence = candidate.lastSequence?.rawValue ?? 0
        if candidateSequence == currentSequence, candidate != entry.state {
            throw AgentSystemError.engineStateConflict(handle.runID)
        }
        let isRegression = candidateSequence < currentSequence
            || (entry.state.phase.isTerminal && !candidate.phase.isTerminal)
        let changed = !isRegression && candidate != entry.state
        if changed {
            entry.state = candidate
            entries[handle.runID] = entry
        }
        if changed || forceObservation {
            publish(kind: kind, commandID: commandID, entry: entry)
        }
        return entry.state
    }

    private func publish(
        kind: AgentSystemObservationKind,
        commandID: CommandID?,
        entry: Entry
    ) {
        guard let observer else { return }
        if revision < UInt64.max { revision += 1 }
        observer(AgentSystemObservation(
            kind: kind,
            commandID: commandID,
            projection: AgentSystemRunProjection(
                revision: revision,
                handle: entry.handle,
                origin: entry.origin,
                state: entry.state
            )
        ))
    }

    private func reserveCapacityForCommandAndRun() throws {
        try reserveCommandCapacity()
        guard entries.count + startingRuns.count + recoveringRuns.count
                < maximumRunCount
        else {
            throw AgentSystemError.registryCapacityExceeded
        }
    }

    private func reserveCommandCapacity() throws {
        guard commandRecords.count < maximumCommandCount else {
            throw AgentSystemError.commandCapacityExceeded
        }
    }

    // MARK: Exact validation

    private static func validatedSendContext(
        _ command: AgentCommand
    ) throws -> AgentRunContext {
        guard case let .send(send) = command.payload,
              command.header.schemaVersion == .current,
              command.header.schemaVersion == send.context.schemaVersion,
              command.header.runID == send.context.lineage.runID,
              send.context.schemaVersion == .current,
              send.context.lineage.validationError == nil
        else { throw AgentSystemError.invalidCommand }
        return send.context
    }

    private static func validatedCancellation(
        _ command: AgentCommand,
        runID: RunID
    ) throws -> CancelCommand {
        guard case let .cancel(cancellation) = command.payload,
              command.header.schemaVersion == .current,
              command.header.runID == runID
        else { throw AgentSystemError.invalidCommand }
        return cancellation
    }

    private static func validatedApprovalDecision(
        _ command: AgentCommand,
        runID: RunID
    ) throws -> ApprovalDecisionCommand {
        guard case let .approvalDecision(decision) = command.payload,
              command.header.schemaVersion == .current,
              command.header.runID == runID
        else { throw AgentSystemError.invalidCommand }
        return decision
    }

    private static func validatedEngineState(
        _ state: AgentDomain.AgentRunState,
        expectedRunID: RunID,
        expectedContext: AgentRunContext?,
        engineHandle: AgentEngineRunHandle
    ) throws -> AgentRunContext {
        guard engineHandle.runID == expectedRunID,
              engineHandle.ownerFence.runID == expectedRunID,
              let context = state.context,
              context.lineage.runID == expectedRunID,
              context.lineage.validationError == nil,
              state.schemaVersion == context.schemaVersion,
              context.schemaVersion == .current,
              expectedContext == nil || expectedContext == context
        else { throw AgentSystemError.engineIdentityMismatch(expectedRunID) }
        return context
    }
}

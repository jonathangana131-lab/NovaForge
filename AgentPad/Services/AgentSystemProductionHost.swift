import AgentDomain
import Foundation
import Observation
import SwiftData

enum AgentSystemProductionHostPhase: String, Equatable, Sendable {
    case idle
    case bootstrapping
    case ready
    case failed
}

/// Deliberately finite startup failures. No underlying error, credential,
/// workspace path, provider response, or persistence location crosses this
/// process boundary into observable UI state.
enum AgentSystemProductionHostFailure: LocalizedError, Equatable, Sendable {
    case containerIdentityConflict
    case compositionUnavailable
    case startupReconciliationFailed
    case acceptedRunRecoveryFailed

    var userFacingMessage: String {
        switch self {
        case .containerIdentityConflict:
            "NovaForge is already connected to a different app data store. Restart NovaForge to continue safely."
        case .compositionUnavailable:
            "NovaForge could not prepare the agent runtime. Restart the app and try again."
        case .startupReconciliationFailed:
            "NovaForge could not safely reconcile unfinished work. Restart the app and try again."
        case .acceptedRunRecoveryFailed:
            "NovaForge could not safely restore unfinished work. Restart the app and try again."
        }
    }

    var errorDescription: String? { userFacingMessage }
}

/// Small, stable observation surface for AppRoot. Counts are bounded to the
/// same process registry limit enforced by `AgentSystem`; exact run IDs and
/// composition IDs remain inside the host.
struct AgentSystemProductionHostStatus: Equatable, Sendable {
    static let maximumReportedRunCount = 65_536

    let phase: AgentSystemProductionHostPhase
    let preparedRunCount: Int
    let recoveredRunCount: Int
    let failure: AgentSystemProductionHostFailure?

    static let idle = AgentSystemProductionHostStatus(
        phase: .idle,
        preparedRunCount: 0,
        recoveredRunCount: 0,
        failure: nil
    )

    fileprivate init(
        phase: AgentSystemProductionHostPhase,
        preparedRunCount: Int,
        recoveredRunCount: Int,
        failure: AgentSystemProductionHostFailure?
    ) {
        self.phase = phase
        self.preparedRunCount = min(
            max(0, preparedRunCount),
            Self.maximumReportedRunCount
        )
        self.recoveredRunCount = min(
            max(0, recoveredRunCount),
            Self.maximumReportedRunCount
        )
        self.failure = failure
    }
}

struct AgentSystemProductionHostReadyReport: Equatable, Sendable {
    let preparedRunCount: Int
    let recoveredRunCount: Int
}

/// MainActor-only seams keep hostile startup tests deterministic without ever
/// making the process singleton resettable. Production closures are the only
/// route from this host to `AgentSystem.shared`.
@MainActor
struct AgentSystemProductionHostDependencies {
    let makeComposition: @MainActor (
        ModelContainer
    ) async throws -> AgentSystemProductionComposition
    let installAndReconcile: @MainActor (
        AgentSystemProductionComposition
    ) async throws -> AgentSystemStartupReport
    let recoverPreparedAcceptedRunIDs: @MainActor () async throws -> [RunID]

    static let production = AgentSystemProductionHostDependencies(
        makeComposition: { container in
            try await AgentSystemProductionCompositionFactory.make(
                container: container
            )
        },
        installAndReconcile: { composition in
            try await AgentSystem.shared.installAndReconcile(composition)
        },
        recoverPreparedAcceptedRunIDs: {
            let handles = try await AgentSystem.shared.recoverAcceptedRuns()
            return handles.map(\.runID)
        }
    )
}

/// Process-owned lifecycle for the canonical agent runtime.
///
/// The first container identity permanently binds the host. All concurrent
/// callers for that exact object join one task. A terminal success or failure
/// is replayed without recreating composition, reconciliation, or recovery.
/// The retained composition keeps its process leadership lease and runtime
/// authorities alive even when installation or recovery fails.
@MainActor
@Observable
final class AgentSystemProductionHost {
    static let shared = AgentSystemProductionHost()

    private(set) var status: AgentSystemProductionHostStatus = .idle
    private(set) var revision: UInt64

    var userFacingFailure: String? {
        status.failure?.userFacingMessage
    }

    @ObservationIgnored private let dependencies:
        AgentSystemProductionHostDependencies
    @ObservationIgnored private var boundContainer: ModelContainer?
    @ObservationIgnored private var boundContainerIdentity: ObjectIdentifier?
    @ObservationIgnored private var retainedComposition:
        AgentSystemProductionComposition?
    @ObservationIgnored private var operationToken: UUID?
    @ObservationIgnored private var bootstrapTask:
        Task<BootstrapResult, Never>?
    @ObservationIgnored private var terminalResult:
        Result<AgentSystemProductionHostReadyReport,
            AgentSystemProductionHostFailure>?

    init(
        dependencies: AgentSystemProductionHostDependencies = .production,
        initialRevision: UInt64 = 0
    ) {
        self.dependencies = dependencies
        revision = initialRevision
    }

    /// Installs, reconciles, and then recovers the prepared accepted-run FIFO.
    /// Cancellation of an individual caller cannot cancel the process-owned
    /// bootstrap task or permit a second authority to be installed.
    @discardableResult
    func bootstrap(
        container: ModelContainer
    ) async throws -> AgentSystemProductionHostReadyReport {
        try bind(to: container)

        if let terminalResult {
            return try terminalResult.get()
        }

        let token: UUID
        let task: Task<BootstrapResult, Never>
        if let activeTask = bootstrapTask, let activeToken = operationToken {
            token = activeToken
            task = activeTask
        } else {
            let newToken = UUID()
            token = newToken
            operationToken = newToken
            transition(to: AgentSystemProductionHostStatus(
                phase: .bootstrapping,
                preparedRunCount: 0,
                recoveredRunCount: 0,
                failure: nil
            ))
            let dependencies = self.dependencies
            let newTask = Task { @MainActor [self] in
                await performBootstrap(
                    container: container,
                    dependencies: dependencies
                )
            }
            bootstrapTask = newTask
            task = newTask
        }

        let result = await task.value
        return try finish(result, token: token)
    }

    private func bind(to container: ModelContainer) throws {
        let requestedIdentity = ObjectIdentifier(container)
        if let activeIdentity = boundContainerIdentity {
            guard activeIdentity == requestedIdentity,
                  boundContainer === container
            else {
                throw AgentSystemProductionHostFailure
                    .containerIdentityConflict
            }
            return
        }
        boundContainer = container
        boundContainerIdentity = requestedIdentity
    }

    private func performBootstrap(
        container: ModelContainer,
        dependencies: AgentSystemProductionHostDependencies
    ) async -> BootstrapResult {
        let composition: AgentSystemProductionComposition
        do {
            composition = try await dependencies.makeComposition(container)
        } catch {
            return .failure(.compositionUnavailable)
        }

        // Retain before reconciliation. Its preparer owns the process-lifetime
        // leadership lease and must outlive every terminal bootstrap outcome.
        retainedComposition = composition

        let startup: AgentSystemStartupReport
        do {
            startup = try await dependencies.installAndReconcile(composition)
        } catch {
            return .failure(.startupReconciliationFailed)
        }
        guard startup.compositionID == composition.id,
              startup.recoveryFIFO.count <=
                AgentSystemProductionHostStatus.maximumReportedRunCount,
              Set(startup.recoveryFIFO).count == startup.recoveryFIFO.count
        else {
            return .failure(.startupReconciliationFailed)
        }

        let recoveredRunIDs: [RunID]
        do {
            recoveredRunIDs = try await
                dependencies.recoverPreparedAcceptedRunIDs()
        } catch {
            return .failure(.acceptedRunRecoveryFailed)
        }
        guard recoveredRunIDs == startup.recoveryFIFO else {
            return .failure(.acceptedRunRecoveryFailed)
        }

        return .success(AgentSystemProductionHostReadyReport(
            preparedRunCount: startup.recoveryFIFO.count,
            recoveredRunCount: recoveredRunIDs.count
        ))
    }

    private func finish(
        _ result: BootstrapResult,
        token: UUID
    ) throws -> AgentSystemProductionHostReadyReport {
        if let terminalResult {
            return try terminalResult.get()
        }
        guard operationToken == token else {
            throw AgentSystemProductionHostFailure
                .startupReconciliationFailed
        }

        bootstrapTask = nil
        operationToken = nil
        switch result {
        case let .success(report):
            let terminal: Result<AgentSystemProductionHostReadyReport,
                AgentSystemProductionHostFailure> = .success(report)
            terminalResult = terminal
            transition(to: AgentSystemProductionHostStatus(
                phase: .ready,
                preparedRunCount: report.preparedRunCount,
                recoveredRunCount: report.recoveredRunCount,
                failure: nil
            ))
            return report
        case let .failure(failure):
            terminalResult = .failure(failure)
            transition(to: AgentSystemProductionHostStatus(
                phase: .failed,
                preparedRunCount: 0,
                recoveredRunCount: 0,
                failure: failure
            ))
            throw failure
        }
    }

    private func transition(to next: AgentSystemProductionHostStatus) {
        guard status != next else { return }
        status = next
        if revision < UInt64.max { revision += 1 }
    }

    private enum BootstrapResult {
        case success(AgentSystemProductionHostReadyReport)
        case failure(AgentSystemProductionHostFailure)
    }
}

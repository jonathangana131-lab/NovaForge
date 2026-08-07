import Foundation

/// Opaque worker-route identity. ProviderRuntime remains the authority that maps these IDs to a
/// concrete, supported provider/model/dialect contract.
public struct MissionWorkerRoute: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String
    public let routeID: String

    public init(providerID: String, modelID: String, routeID: String) {
        self.providerID = providerID
        self.modelID = modelID
        self.routeID = routeID
    }
}

public struct MissionWorkToken: Codable, Hashable, Sendable {
    public struct StageBinding: Codable, Hashable, Sendable {
        public let stageID: MissionStageID
        public let stageGeneration: UInt64
        public let attemptID: AttemptID

        public init(
            stageID: MissionStageID,
            stageGeneration: UInt64,
            attemptID: AttemptID
        ) {
            self.stageID = stageID
            self.stageGeneration = stageGeneration
            self.attemptID = attemptID
        }
    }

    public let missionID: MissionID
    public let missionRevisionAtDispatch: UInt64
    public let workerRoute: MissionWorkerRoute?
    public let binding: StageBinding

    public init(
        missionID: MissionID,
        missionRevisionAtDispatch: UInt64,
        workerRoute: MissionWorkerRoute?,
        binding: StageBinding
    ) {
        self.missionID = missionID
        self.missionRevisionAtDispatch = missionRevisionAtDispatch
        self.workerRoute = workerRoute
        self.binding = binding
    }
}

public enum MissionSnapshotError: Error, Equatable, Sendable {
    case illegalLifecycleTransition(from: MissionLifecycleState, to: MissionLifecycleState)
    case terminalMissionRequiresSatisfiedRequiredStages
    case staleWorkResult(MissionStageID)
    case revisionOverflow
}

/// Durable mission authority suitable for persistence above the provider/model transcript layer.
public struct MissionSnapshot: Codable, Hashable, Sendable {
    public let missionID: MissionID
    public let projectID: ProjectID
    public private(set) var lifecycle: MissionLifecycleState
    public let constitution: MissionConstitution
    public private(set) var stageGraph: MissionStageGraph
    public private(set) var workerRoute: MissionWorkerRoute?
    public private(set) var revision: UInt64

    public init(
        missionID: MissionID = MissionID(),
        projectID: ProjectID,
        lifecycle: MissionLifecycleState = .draftIntent,
        constitution: MissionConstitution,
        stageGraph: MissionStageGraph,
        workerRoute: MissionWorkerRoute? = nil,
        revision: UInt64 = 0
    ) throws {
        self.missionID = missionID
        self.projectID = projectID
        self.lifecycle = lifecycle
        self.constitution = constitution
        self.stageGraph = stageGraph
        self.workerRoute = workerRoute
        self.revision = revision
        try validateCompletionTruth()
    }

    private enum CodingKeys: String, CodingKey {
        case missionID
        case projectID
        case lifecycle
        case constitution
        case stageGraph
        case workerRoute
        case revision
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        missionID = try container.decode(MissionID.self, forKey: .missionID)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        lifecycle = try container.decode(MissionLifecycleState.self, forKey: .lifecycle)
        constitution = try container.decode(MissionConstitution.self, forKey: .constitution)
        stageGraph = try container.decode(MissionStageGraph.self, forKey: .stageGraph)
        workerRoute = try container.decodeIfPresent(MissionWorkerRoute.self, forKey: .workerRoute)
        revision = try container.decode(UInt64.self, forKey: .revision)
        try validateCompletionTruth()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(missionID, forKey: .missionID)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encode(constitution, forKey: .constitution)
        try container.encode(stageGraph, forKey: .stageGraph)
        try container.encodeIfPresent(workerRoute, forKey: .workerRoute)
        try container.encode(revision, forKey: .revision)
    }

    public mutating func transitionLifecycle(to next: MissionLifecycleState) throws {
        guard next != lifecycle else { return }
        guard lifecycle.canTransition(to: next) else {
            throw MissionSnapshotError.illegalLifecycleTransition(from: lifecycle, to: next)
        }
        if next.isCompletion, !stageGraph.allRequiredStagesSatisfied {
            throw MissionSnapshotError.terminalMissionRequiresSatisfiedRequiredStages
        }

        if [.pausedByUser, .pausedByPolicy].contains(next) {
            try stageGraph.pauseRunningStages()
        } else if [.pausedByUser, .pausedByPolicy].contains(lifecycle),
                  [.ready, .executing].contains(next) {
            try stageGraph.resumePausedStages()
        }

        lifecycle = next
        try advanceRevision()
    }

    /// Hot-swaps the worker without changing mission/project/constitution identity. Any active
    /// attempt is superseded and returned to Ready so a late response from the old route is stale.
    public mutating func switchWorker(to route: MissionWorkerRoute?) throws {
        guard route != workerRoute else { return }
        try stageGraph.supersedeRunningAttempts()
        workerRoute = route
        try advanceRevision()
    }

    public mutating func beginWork(
        on stageID: MissionStageID,
        attemptID: AttemptID = AttemptID()
    ) throws -> MissionWorkToken {
        let binding = try stageGraph.start(stageID, attemptID: attemptID)
        try advanceRevision()
        return MissionWorkToken(
            missionID: missionID,
            missionRevisionAtDispatch: revision,
            workerRoute: workerRoute,
            binding: binding
        )
    }

    /// Revision is deliberately not compared here: independent steering can advance the mission
    /// revision without invalidating unrelated work. Exact stage generation + attempt + worker
    /// route are the acceptance boundary for this first serial-stage domain.
    public func accepts(_ token: MissionWorkToken) -> Bool {
        token.missionID == missionID
            && token.workerRoute == workerRoute
            && stageGraph.accepts(token.binding)
    }

    public mutating func finishWork(
        _ token: MissionWorkToken,
        as status: MissionStageStatus
    ) throws {
        guard accepts(token) else {
            throw MissionSnapshotError.staleWorkResult(token.binding.stageID)
        }
        try stageGraph.finish(token.binding, as: status)
        try advanceRevision()
    }

    @discardableResult
    public mutating func requeueRecoverableStageWithRepair(
        failedStageID: MissionStageID,
        repairStageID: MissionStageID = MissionStageID(),
        repairTitle: String,
        priority: Int = 0
    ) throws -> MissionStageID {
        let result = try stageGraph.requeueRecoverableStageWithRepair(
            failedStageID: failedStageID,
            repairStageID: repairStageID,
            repairTitle: repairTitle,
            priority: priority
        )
        try advanceRevision()
        return result
    }

    public mutating func deferOptionalStage(_ stageID: MissionStageID) throws {
        try stageGraph.deferOptionalStage(stageID)
        try advanceRevision()
    }

    public mutating func reprioritize(stageID: MissionStageID, priority: Int) throws {
        try stageGraph.reprioritize(stageID: stageID, priority: priority)
        try advanceRevision()
    }

    private func validateCompletionTruth() throws {
        if lifecycle.isCompletion, !stageGraph.allRequiredStagesSatisfied {
            throw MissionSnapshotError.terminalMissionRequiresSatisfiedRequiredStages
        }
    }

    private mutating func advanceRevision() throws {
        guard revision < UInt64.max else {
            throw MissionSnapshotError.revisionOverflow
        }
        revision += 1
    }
}

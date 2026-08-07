import Foundation

public enum MissionStageKind: String, Codable, CaseIterable, Hashable, Sendable {
    case understand
    case decision
    case design
    case implement
    case run
    case observe
    case diagnose
    case repair
    case test
    case visualCritique
    case accessibility
    case performance
    case polish
    case checkpoint
    case custom
}

public enum MissionStageStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case ready
    case running
    case paused
    case blocked
    case succeeded
    case skipped
    case failedRecoverable
    case failedTerminal

    public var satisfiesDependency: Bool {
        self == .succeeded || self == .skipped
    }

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .skipped, .failedTerminal:
            true
        default:
            false
        }
    }
}

public enum MissionStageOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case constitution
    case agentPlan
    case userSteering
    case validationFinding
    case recovery
}

public struct MissionStage: Codable, Hashable, Sendable, Identifiable {
    public let id: MissionStageID
    public let kind: MissionStageKind
    public var title: String
    public var status: MissionStageStatus
    public var isRequired: Bool
    public var dependencies: Set<MissionStageID>
    public let origin: MissionStageOrigin
    public var priority: Int
    public private(set) var generation: UInt64
    public private(set) var activeAttemptID: AttemptID?

    public init(
        id: MissionStageID = MissionStageID(),
        kind: MissionStageKind,
        title: String,
        status: MissionStageStatus = .pending,
        isRequired: Bool = true,
        dependencies: Set<MissionStageID> = [],
        origin: MissionStageOrigin = .agentPlan,
        priority: Int = 0,
        generation: UInt64 = 0,
        activeAttemptID: AttemptID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.isRequired = isRequired
        self.dependencies = dependencies
        self.origin = origin
        self.priority = priority
        self.generation = generation
        self.activeAttemptID = activeAttemptID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case status
        case isRequired
        case dependencies
        case origin
        case priority
        case generation
        case activeAttemptID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(MissionStageID.self, forKey: .id)
        kind = try container.decode(MissionStageKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        status = try container.decode(MissionStageStatus.self, forKey: .status)
        isRequired = try container.decode(Bool.self, forKey: .isRequired)
        dependencies = Set(try container.decode([MissionStageID].self, forKey: .dependencies))
        origin = try container.decode(MissionStageOrigin.self, forKey: .origin)
        priority = try container.decode(Int.self, forKey: .priority)
        generation = try container.decode(UInt64.self, forKey: .generation)
        activeAttemptID = try container.decodeIfPresent(AttemptID.self, forKey: .activeAttemptID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(status, forKey: .status)
        try container.encode(isRequired, forKey: .isRequired)
        try container.encode(dependencies.sorted { $0.description < $1.description }, forKey: .dependencies)
        try container.encode(origin, forKey: .origin)
        try container.encode(priority, forKey: .priority)
        try container.encode(generation, forKey: .generation)
        try container.encodeIfPresent(activeAttemptID, forKey: .activeAttemptID)
    }

    fileprivate mutating func setExecutionState(
        status: MissionStageStatus,
        activeAttemptID: AttemptID?
    ) throws {
        guard generation < UInt64.max else {
            throw MissionStageGraphError.generationOverflow(id)
        }
        generation += 1
        self.status = status
        self.activeAttemptID = activeAttemptID
    }
}

public enum MissionStageGraphError: Error, Equatable, Sendable {
    case duplicateStageID(MissionStageID)
    case missingDependency(stageID: MissionStageID, dependencyID: MissionStageID)
    case selfDependency(MissionStageID)
    case dependencyCycle
    case stageNotFound(MissionStageID)
    case illegalTransition(stageID: MissionStageID, from: MissionStageStatus, to: MissionStageStatus)
    case dependenciesUnsatisfied(MissionStageID)
    case requiredStageCannotBeDeferred(MissionStageID)
    case repairRequiresRecoverableFailure(MissionStageID)
    case runningStageMissingAttempt(MissionStageID)
    case inactiveStageHasAttempt(MissionStageID)
    case readyStageHasUnsatisfiedDependencies(MissionStageID)
    case generationOverflow(MissionStageID)
}

/// A validated dependency graph for one mission.
///
/// The graph owns stage-attempt generations. Results are accepted only when they still bind to
/// the exact running generation + attempt, preventing a delayed worker from completing a retried
/// stage after recovery or user steering has already superseded it.
public struct MissionStageGraph: Codable, Hashable, Sendable {
    public private(set) var stages: [MissionStage]

    public init(stages: [MissionStage]) throws {
        self.stages = stages
        try validateStructure()
        refreshReadiness()
        try validateExecutionState()
    }

    private enum CodingKeys: String, CodingKey {
        case stages
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stages = try container.decode([MissionStage].self, forKey: .stages)
        try validateStructure()
        try validateExecutionState()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stages, forKey: .stages)
    }

    public func stage(id: MissionStageID) -> MissionStage? {
        stages.first { $0.id == id }
    }

    public var readyStageIDs: [MissionStageID] {
        stages
            .filter { $0.status == .ready }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.id.description < rhs.id.description
            }
            .map(\.id)
    }

    public var allRequiredStagesSatisfied: Bool {
        stages.filter(\.isRequired).allSatisfy { $0.status == .succeeded }
    }

    public mutating func reprioritize(stageID: MissionStageID, priority: Int) throws {
        let index = try index(for: stageID)
        stages[index].priority = priority
    }

    public mutating func deferOptionalStage(_ stageID: MissionStageID) throws {
        let index = try index(for: stageID)
        guard !stages[index].isRequired else {
            throw MissionStageGraphError.requiredStageCannotBeDeferred(stageID)
        }
        let current = stages[index].status
        guard [.pending, .ready, .paused, .blocked, .failedRecoverable].contains(current) else {
            throw MissionStageGraphError.illegalTransition(stageID: stageID, from: current, to: .skipped)
        }
        try stages[index].setExecutionState(status: .skipped, activeAttemptID: nil)
        refreshReadiness()
    }

    public mutating func start(
        _ stageID: MissionStageID,
        attemptID: AttemptID = AttemptID()
    ) throws -> MissionWorkToken.StageBinding {
        let index = try index(for: stageID)
        let current = stages[index].status
        guard current == .ready else {
            throw MissionStageGraphError.illegalTransition(stageID: stageID, from: current, to: .running)
        }
        guard dependenciesSatisfied(for: stages[index]) else {
            throw MissionStageGraphError.dependenciesUnsatisfied(stageID)
        }
        try stages[index].setExecutionState(status: .running, activeAttemptID: attemptID)
        return MissionWorkToken.StageBinding(
            stageID: stageID,
            stageGeneration: stages[index].generation,
            attemptID: attemptID
        )
    }

    public mutating func finish(
        _ binding: MissionWorkToken.StageBinding,
        as status: MissionStageStatus
    ) throws {
        let index = try index(for: binding.stageID)
        let current = stages[index]
        guard current.status == .running,
              current.generation == binding.stageGeneration,
              current.activeAttemptID == binding.attemptID else {
            throw MissionStageGraphError.illegalTransition(
                stageID: binding.stageID,
                from: current.status,
                to: status
            )
        }
        guard [.succeeded, .failedRecoverable, .failedTerminal, .paused, .blocked].contains(status) else {
            throw MissionStageGraphError.illegalTransition(
                stageID: binding.stageID,
                from: current.status,
                to: status
            )
        }
        try stages[index].setExecutionState(status: status, activeAttemptID: nil)
        refreshReadiness()
    }

    /// Inserts a repair stage before the failed stage and makes the original stage its deterministic
    /// retry. This adds no cycle: the repair inherits the failed stage's old dependencies, while the
    /// failed stage gains the repair as a new prerequisite.
    @discardableResult
    public mutating func requeueRecoverableStageWithRepair(
        failedStageID: MissionStageID,
        repairStageID: MissionStageID = MissionStageID(),
        repairTitle: String,
        priority: Int = 0
    ) throws -> MissionStageID {
        let failedIndex = try index(for: failedStageID)
        let failed = stages[failedIndex]
        guard failed.status == .failedRecoverable else {
            throw MissionStageGraphError.repairRequiresRecoverableFailure(failedStageID)
        }
        guard stage(id: repairStageID) == nil else {
            throw MissionStageGraphError.duplicateStageID(repairStageID)
        }

        let repair = MissionStage(
            id: repairStageID,
            kind: .repair,
            title: repairTitle,
            status: .pending,
            isRequired: true,
            dependencies: failed.dependencies,
            origin: .validationFinding,
            priority: priority
        )
        stages.insert(repair, at: failedIndex)

        let shiftedFailedIndex = failedIndex + 1
        stages[shiftedFailedIndex].dependencies.insert(repairStageID)
        try stages[shiftedFailedIndex].setExecutionState(status: .pending, activeAttemptID: nil)

        try validateStructure()
        refreshReadiness()
        try validateExecutionState()
        return repairStageID
    }

    /// Invalidates every in-flight attempt and returns those stages to the ready queue. Used when
    /// a mission hot-swaps its worker/model so results from the old route cannot land afterward.
    @discardableResult
    public mutating func supersedeRunningAttempts() throws -> [MissionStageID] {
        var superseded: [MissionStageID] = []
        for index in stages.indices where stages[index].status == .running {
            let stageID = stages[index].id
            try stages[index].setExecutionState(status: .ready, activeAttemptID: nil)
            superseded.append(stageID)
        }
        return superseded
    }

    @discardableResult
    public mutating func pauseRunningStages() throws -> [MissionStageID] {
        var paused: [MissionStageID] = []
        for index in stages.indices where stages[index].status == .running {
            let stageID = stages[index].id
            try stages[index].setExecutionState(status: .paused, activeAttemptID: nil)
            paused.append(stageID)
        }
        return paused
    }

    @discardableResult
    public mutating func resumePausedStages() throws -> [MissionStageID] {
        var resumed: [MissionStageID] = []
        for index in stages.indices where stages[index].status == .paused {
            let stageID = stages[index].id
            let next: MissionStageStatus = dependenciesSatisfied(for: stages[index]) ? .ready : .pending
            try stages[index].setExecutionState(status: next, activeAttemptID: nil)
            resumed.append(stageID)
        }
        return resumed
    }

    public func accepts(_ binding: MissionWorkToken.StageBinding) -> Bool {
        guard let stage = stage(id: binding.stageID) else { return false }
        return stage.status == .running
            && stage.generation == binding.stageGeneration
            && stage.activeAttemptID == binding.attemptID
    }

    private mutating func refreshReadiness() {
        for index in stages.indices where stages[index].status == .pending {
            if dependenciesSatisfied(for: stages[index]) {
                stages[index].status = .ready
            }
        }
    }

    private func dependenciesSatisfied(for stage: MissionStage) -> Bool {
        stage.dependencies.allSatisfy { dependencyID in
            self.stage(id: dependencyID)?.status.satisfiesDependency == true
        }
    }

    private func index(for stageID: MissionStageID) throws -> Int {
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else {
            throw MissionStageGraphError.stageNotFound(stageID)
        }
        return index
    }

    private func validateStructure() throws {
        var ids = Set<MissionStageID>()
        for stage in stages {
            guard ids.insert(stage.id).inserted else {
                throw MissionStageGraphError.duplicateStageID(stage.id)
            }
        }

        for stage in stages {
            for dependency in stage.dependencies {
                guard dependency != stage.id else {
                    throw MissionStageGraphError.selfDependency(stage.id)
                }
                guard ids.contains(dependency) else {
                    throw MissionStageGraphError.missingDependency(
                        stageID: stage.id,
                        dependencyID: dependency
                    )
                }
            }
        }

        enum Visit {
            case visiting
            case visited
        }
        var visits: [MissionStageID: Visit] = [:]

        func visit(_ stageID: MissionStageID) throws {
            if visits[stageID] == .visiting {
                throw MissionStageGraphError.dependencyCycle
            }
            if visits[stageID] == .visited { return }

            visits[stageID] = .visiting
            if let stage = stage(id: stageID) {
                for dependency in stage.dependencies {
                    try visit(dependency)
                }
            }
            visits[stageID] = .visited
        }

        for stage in stages {
            try visit(stage.id)
        }
    }

    private func validateExecutionState() throws {
        for stage in stages {
            if stage.status == .running {
                guard stage.activeAttemptID != nil else {
                    throw MissionStageGraphError.runningStageMissingAttempt(stage.id)
                }
            } else if stage.activeAttemptID != nil {
                throw MissionStageGraphError.inactiveStageHasAttempt(stage.id)
            }

            if [.ready, .running].contains(stage.status), !dependenciesSatisfied(for: stage) {
                throw MissionStageGraphError.readyStageHasUnsatisfiedDependencies(stage.id)
            }
        }
    }
}

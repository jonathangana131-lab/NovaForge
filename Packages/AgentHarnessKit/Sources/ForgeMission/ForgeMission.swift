import Foundation

public struct MissionID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
    public var description: String { rawValue.uuidString }
}

public struct MissionStageID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
    public var description: String { rawValue.uuidString }
}

public struct MissionCheckpointID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
    public var description: String { rawValue.uuidString }
}

public enum MissionLifecycle: String, Codable, CaseIterable, Sendable {
    case planning
    case running
    case paused
    case waitingForDecision
    case completed
    case failed
    case cancelled
}

public enum MissionStageKind: String, Codable, CaseIterable, Sendable {
    case understand
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

public enum MissionStageStatus: String, Codable, CaseIterable, Sendable {
    case planned
    case ready
    case active
    case completed
    case blocked
    case skipped
}

public enum MissionExecutionEnvironment: String, Codable, CaseIterable, Sendable {
    case onDevice
    case simulator
    case cloud
    case pairedMac
    case external
}

public struct MissionRoute: Codable, Equatable, Hashable, Sendable {
    public var providerID: String
    public var modelID: String
    public var adapterID: String
    public var executionEnvironment: MissionExecutionEnvironment

    public init(
        providerID: String,
        modelID: String,
        adapterID: String,
        executionEnvironment: MissionExecutionEnvironment
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.adapterID = adapterID
        self.executionEnvironment = executionEnvironment
    }
}

public struct MissionConstitution: Codable, Equatable, Sendable {
    public var functionality: [String]
    public var runnability: String
    public var designTarget: String
    public var orientationTarget: String
    public var capabilities: [String]
    public var performanceTarget: String
    public var accessibilityTarget: String
    public var persistenceTarget: String
    public var nonGoals: [String]
    public var constraints: [String]

    public init(
        functionality: [String],
        runnability: String,
        designTarget: String,
        orientationTarget: String,
        capabilities: [String],
        performanceTarget: String,
        accessibilityTarget: String,
        persistenceTarget: String,
        nonGoals: [String] = [],
        constraints: [String] = []
    ) {
        self.functionality = functionality
        self.runnability = runnability
        self.designTarget = designTarget
        self.orientationTarget = orientationTarget
        self.capabilities = capabilities
        self.performanceTarget = performanceTarget
        self.accessibilityTarget = accessibilityTarget
        self.persistenceTarget = persistenceTarget
        self.nonGoals = nonGoals
        self.constraints = constraints
    }
}

public struct MissionStage: Codable, Equatable, Sendable, Identifiable {
    public let id: MissionStageID
    public var kind: MissionStageKind
    public var title: String
    public var dependencies: [MissionStageID]
    public var isOptional: Bool
    public var status: MissionStageStatus
    public var evidenceSummary: String?
    public var updatedAt: Date

    public init(
        id: MissionStageID = MissionStageID(),
        kind: MissionStageKind,
        title: String,
        dependencies: [MissionStageID] = [],
        isOptional: Bool = false,
        status: MissionStageStatus = .planned,
        evidenceSummary: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.dependencies = dependencies
        self.isOptional = isOptional
        self.status = status
        self.evidenceSummary = evidenceSummary
        self.updatedAt = updatedAt
    }
}

public struct MissionSteeringNote: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let instruction: String
    public let createdAt: Date

    public init(id: UUID = UUID(), instruction: String, createdAt: Date = .now) {
        self.id = id
        self.instruction = instruction
        self.createdAt = createdAt
    }
}

public struct MissionRouteTransition: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let from: MissionRoute
    public let to: MissionRoute
    public let reason: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        from: MissionRoute,
        to: MissionRoute,
        reason: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.reason = reason
        self.createdAt = createdAt
    }
}

public struct MissionCheckpoint: Codable, Equatable, Sendable, Identifiable {
    public let id: MissionCheckpointID
    public let parentID: MissionCheckpointID?
    public let missionID: MissionID
    public let revision: UInt64
    public let acceptedAt: Date
    public let summary: String
    public let lifecycle: MissionLifecycle
    public let stages: [MissionStage]
    public let route: MissionRoute
    public let steeringCount: Int

    public init(
        id: MissionCheckpointID = MissionCheckpointID(),
        parentID: MissionCheckpointID?,
        missionID: MissionID,
        revision: UInt64,
        acceptedAt: Date,
        summary: String,
        lifecycle: MissionLifecycle,
        stages: [MissionStage],
        route: MissionRoute,
        steeringCount: Int
    ) {
        self.id = id
        self.parentID = parentID
        self.missionID = missionID
        self.revision = revision
        self.acceptedAt = acceptedAt
        self.summary = summary
        self.lifecycle = lifecycle
        self.stages = stages
        self.route = route
        self.steeringCount = steeringCount
    }
}

public struct MissionWorkLease: Codable, Equatable, Sendable {
    public let missionID: MissionID
    public let stageID: MissionStageID
    public let revision: UInt64
    public let checkpointID: MissionCheckpointID?
    public let route: MissionRoute

    public init(
        missionID: MissionID,
        stageID: MissionStageID,
        revision: UInt64,
        checkpointID: MissionCheckpointID?,
        route: MissionRoute
    ) {
        self.missionID = missionID
        self.stageID = stageID
        self.revision = revision
        self.checkpointID = checkpointID
        self.route = route
    }
}

public enum MissionWorkerOutcome: String, Codable, Sendable {
    case completed
    case blocked
    case needsDecision
}

public struct MissionWorkerResult: Codable, Equatable, Sendable {
    public let lease: MissionWorkLease
    public let outcome: MissionWorkerOutcome
    public let evidenceSummary: String

    public init(lease: MissionWorkLease, outcome: MissionWorkerOutcome, evidenceSummary: String) {
        self.lease = lease
        self.outcome = outcome
        self.evidenceSummary = evidenceSummary
    }
}

public enum MissionStateError: Error, Equatable, LocalizedError, Sendable {
    case duplicateStage(MissionStageID)
    case missingDependency(stage: MissionStageID, dependency: MissionStageID)
    case dependencyCycle
    case invalidLifecycle(expected: [MissionLifecycle], actual: MissionLifecycle)
    case stageNotFound(MissionStageID)
    case stageNotActive(MissionStageID)
    case stageNotBlocked(MissionStageID)
    case stageNotSkippable(MissionStageID)
    case staleWorkerResult(expectedRevision: UInt64, receivedRevision: UInt64)
    case wrongMission
    case staleCheckpoint(expected: MissionCheckpointID?, received: MissionCheckpointID?)
    case staleRoute
    case checkpointNotFound(MissionCheckpointID)
    case emptySteeringInstruction

    public var errorDescription: String? {
        switch self {
        case let .duplicateStage(id):
            "Duplicate mission stage: \(id)."
        case let .missingDependency(stage, dependency):
            "Stage \(stage) depends on missing stage \(dependency)."
        case .dependencyCycle:
            "Mission stage graph contains a dependency cycle."
        case let .invalidLifecycle(expected, actual):
            "Mission lifecycle \(actual.rawValue) is invalid here; expected \(expected.map(\.rawValue).joined(separator: ", "))."
        case let .stageNotFound(id):
            "Mission stage not found: \(id)."
        case let .stageNotActive(id):
            "Mission stage is not active: \(id)."
        case let .stageNotBlocked(id):
            "Mission stage is not blocked: \(id)."
        case let .stageNotSkippable(id):
            "Required mission stage cannot be skipped: \(id)."
        case let .staleWorkerResult(expected, received):
            "Worker result is stale: expected revision \(expected), received \(received)."
        case .wrongMission:
            "Worker result belongs to a different mission."
        case let .staleCheckpoint(expected, received):
            "Worker result checkpoint is stale: expected \(String(describing: expected)), received \(String(describing: received))."
        case .staleRoute:
            "Worker result was produced for a superseded model or execution route."
        case let .checkpointNotFound(id):
            "Mission checkpoint not found: \(id)."
        case .emptySteeringInstruction:
            "Mission steering instruction cannot be empty."
        }
    }
}

public struct ForgeMissionState: Codable, Equatable, Sendable {
    public let id: MissionID
    public let createdAt: Date
    public var intent: String
    public var constitution: MissionConstitution
    public private(set) var lifecycle: MissionLifecycle
    public private(set) var stages: [MissionStage]
    public private(set) var route: MissionRoute
    public private(set) var routeTransitions: [MissionRouteTransition]
    public private(set) var steeringNotes: [MissionSteeringNote]
    public private(set) var checkpoints: [MissionCheckpoint]
    public private(set) var revision: UInt64

    public var latestCheckpointID: MissionCheckpointID? { checkpoints.last?.id }
    public var activeStage: MissionStage? { stages.first(where: { $0.status == .active }) }
    public var isTerminal: Bool { [.completed, .failed, .cancelled].contains(lifecycle) }

    public init(
        id: MissionID = MissionID(),
        createdAt: Date = .now,
        intent: String,
        constitution: MissionConstitution,
        stages: [MissionStage],
        route: MissionRoute
    ) throws {
        try Self.validateGraph(stages)
        self.id = id
        self.createdAt = createdAt
        self.intent = intent
        self.constitution = constitution
        self.lifecycle = .planning
        self.stages = stages.map { stage in
            var copy = stage
            copy.status = .planned
            return copy
        }
        self.route = route
        self.routeTransitions = []
        self.steeringNotes = []
        self.checkpoints = []
        self.revision = 0
        refreshReadiness(now: createdAt, activateIfRunning: false)
    }

    public mutating func start(at now: Date = .now) throws {
        try requireLifecycle([.planning])
        lifecycle = .running
        bumpRevision()
        refreshReadiness(now: now, activateIfRunning: true)
        settleTerminalLifecycle()
    }

    public mutating func pause(at now: Date = .now) throws {
        try requireLifecycle([.running, .waitingForDecision])
        lifecycle = .paused
        bumpRevision()
        touchActiveStage(at: now)
    }

    public mutating func resume(at now: Date = .now) throws {
        try requireLifecycle([.paused, .waitingForDecision])
        lifecycle = .running
        bumpRevision()
        refreshReadiness(now: now, activateIfRunning: true)
        settleTerminalLifecycle()
    }

    public mutating func steer(_ instruction: String, at now: Date = .now) throws {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MissionStateError.emptySteeringInstruction }
        steeringNotes.append(MissionSteeringNote(instruction: trimmed, createdAt: now))
        bumpRevision()
    }

    public mutating func switchRoute(to newRoute: MissionRoute, reason: String, at now: Date = .now) {
        guard newRoute != route else { return }
        routeTransitions.append(
            MissionRouteTransition(from: route, to: newRoute, reason: reason, createdAt: now)
        )
        route = newRoute
        bumpRevision()
    }

    public mutating func replaceConstitution(with newValue: MissionConstitution) {
        guard newValue != constitution else { return }
        constitution = newValue
        bumpRevision()
    }

    public mutating func insertStages(_ newStages: [MissionStage], at index: Int? = nil, now: Date = .now) throws {
        guard !newStages.isEmpty else { return }
        var candidates = stages
        let insertionIndex = min(max(index ?? candidates.endIndex, 0), candidates.endIndex)
        candidates.insert(contentsOf: newStages.map { stage in
            var copy = stage
            copy.status = .planned
            copy.updatedAt = now
            return copy
        }, at: insertionIndex)
        try Self.validateGraph(candidates)
        stages = candidates
        bumpRevision()
        refreshReadiness(now: now, activateIfRunning: lifecycle == .running)
        settleTerminalLifecycle()
    }

    public mutating func retryBlockedStage(
        _ stageID: MissionStageID,
        steeringInstruction: String? = nil,
        at now: Date = .now
    ) throws {
        try requireLifecycle([.paused, .waitingForDecision])
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else {
            throw MissionStateError.stageNotFound(stageID)
        }
        guard stages[index].status == .blocked else {
            throw MissionStateError.stageNotBlocked(stageID)
        }
        if let steeringInstruction {
            let trimmed = steeringInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MissionStateError.emptySteeringInstruction }
            steeringNotes.append(MissionSteeringNote(instruction: trimmed, createdAt: now))
        }
        stages[index].status = .ready
        stages[index].updatedAt = now
        lifecycle = .running
        bumpRevision()
        refreshReadiness(now: now, activateIfRunning: true)
    }

    public mutating func skipOptionalStage(_ stageID: MissionStageID, at now: Date = .now) throws {
        guard let index = stages.firstIndex(where: { $0.id == stageID }) else {
            throw MissionStateError.stageNotFound(stageID)
        }
        guard stages[index].isOptional else { throw MissionStateError.stageNotSkippable(stageID) }
        stages[index].status = .skipped
        stages[index].updatedAt = now
        bumpRevision()
        refreshReadiness(now: now, activateIfRunning: lifecycle == .running)
        settleTerminalLifecycle()
    }

    public func makeWorkLease(for stageID: MissionStageID) throws -> MissionWorkLease {
        try requireLifecycle([.running])
        guard let stage = stages.first(where: { $0.id == stageID }) else {
            throw MissionStateError.stageNotFound(stageID)
        }
        guard stage.status == .active else { throw MissionStateError.stageNotActive(stageID) }
        return MissionWorkLease(
            missionID: id,
            stageID: stageID,
            revision: revision,
            checkpointID: latestCheckpointID,
            route: route
        )
    }

    public mutating func acceptWorkerResult(_ result: MissionWorkerResult, at now: Date = .now) throws {
        guard result.lease.missionID == id else { throw MissionStateError.wrongMission }
        guard result.lease.revision == revision else {
            throw MissionStateError.staleWorkerResult(expectedRevision: revision, receivedRevision: result.lease.revision)
        }
        guard result.lease.checkpointID == latestCheckpointID else {
            throw MissionStateError.staleCheckpoint(expected: latestCheckpointID, received: result.lease.checkpointID)
        }
        guard result.lease.route == route else { throw MissionStateError.staleRoute }
        guard let index = stages.firstIndex(where: { $0.id == result.lease.stageID }) else {
            throw MissionStateError.stageNotFound(result.lease.stageID)
        }
        guard stages[index].status == .active else { throw MissionStateError.stageNotActive(result.lease.stageID) }

        stages[index].evidenceSummary = result.evidenceSummary
        stages[index].updatedAt = now
        switch result.outcome {
        case .completed:
            stages[index].status = .completed
            lifecycle = .running
        case .blocked:
            stages[index].status = .blocked
            lifecycle = .waitingForDecision
        case .needsDecision:
            stages[index].status = .blocked
            lifecycle = .waitingForDecision
        }
        bumpRevision()
        refreshReadiness(now: now, activateIfRunning: lifecycle == .running)
        settleTerminalLifecycle()
    }

    @discardableResult
    public mutating func checkpoint(summary: String, at now: Date = .now) -> MissionCheckpoint {
        bumpRevision()
        let checkpoint = MissionCheckpoint(
            parentID: latestCheckpointID,
            missionID: id,
            revision: revision,
            acceptedAt: now,
            summary: summary,
            lifecycle: lifecycle,
            stages: stages,
            route: route,
            steeringCount: steeringNotes.count
        )
        checkpoints.append(checkpoint)
        return checkpoint
    }

    @discardableResult
    public mutating func restore(to checkpointID: MissionCheckpointID, at now: Date = .now) throws -> MissionCheckpoint {
        guard let source = checkpoints.first(where: { $0.id == checkpointID }) else {
            throw MissionStateError.checkpointNotFound(checkpointID)
        }
        stages = source.stages
        route = source.route
        lifecycle = .paused
        bumpRevision()
        let restored = MissionCheckpoint(
            parentID: source.id,
            missionID: id,
            revision: revision,
            acceptedAt: now,
            summary: "Restored: \(source.summary)",
            lifecycle: lifecycle,
            stages: stages,
            route: route,
            steeringCount: steeringNotes.count
        )
        checkpoints.append(restored)
        return restored
    }

    private mutating func bumpRevision() {
        revision &+= 1
    }

    private func requireLifecycle(_ expected: [MissionLifecycle]) throws {
        guard expected.contains(lifecycle) else {
            throw MissionStateError.invalidLifecycle(expected: expected, actual: lifecycle)
        }
    }

    private mutating func touchActiveStage(at now: Date) {
        guard let index = stages.firstIndex(where: { $0.status == .active }) else { return }
        stages[index].updatedAt = now
    }

    private mutating func refreshReadiness(now: Date, activateIfRunning: Bool) {
        let terminalIDs = Set(
            stages
                .filter { $0.status == .completed || $0.status == .skipped }
                .map(\.id)
        )

        for index in stages.indices where stages[index].status == .planned || stages[index].status == .ready {
            if stages[index].dependencies.allSatisfy({ terminalIDs.contains($0) }) {
                stages[index].status = .ready
                stages[index].updatedAt = now
            } else {
                stages[index].status = .planned
            }
        }

        guard activateIfRunning, !stages.contains(where: { $0.status == .active }) else { return }
        if let readyIndex = stages.firstIndex(where: { $0.status == .ready }) {
            stages[readyIndex].status = .active
            stages[readyIndex].updatedAt = now
        }
    }

    private mutating func settleTerminalLifecycle() {
        guard lifecycle == .running else { return }
        let unfinished = stages.contains { stage in
            stage.status != .completed && stage.status != .skipped
        }
        if !unfinished {
            lifecycle = .completed
        }
    }

    private static func validateGraph(_ stages: [MissionStage]) throws {
        var known = Set<MissionStageID>()
        for stage in stages {
            guard known.insert(stage.id).inserted else { throw MissionStateError.duplicateStage(stage.id) }
        }
        for stage in stages {
            for dependency in stage.dependencies where !known.contains(dependency) {
                throw MissionStateError.missingDependency(stage: stage.id, dependency: dependency)
            }
        }

        let dependencies = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0.dependencies) })
        enum Mark { case visiting, visited }
        var marks: [MissionStageID: Mark] = [:]

        func visit(_ id: MissionStageID) throws {
            if let mark = marks[id] {
                if mark == .visiting { throw MissionStateError.dependencyCycle }
                return
            }
            marks[id] = .visiting
            for dependency in dependencies[id, default: []] {
                try visit(dependency)
            }
            marks[id] = .visited
        }

        for stage in stages {
            try visit(stage.id)
        }
    }
}

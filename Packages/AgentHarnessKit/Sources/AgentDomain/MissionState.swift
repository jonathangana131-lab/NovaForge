import Foundation

public enum MissionStageIDTag: AgentIdentifierTag {}
public typealias MissionStageID = AgentIdentifier<MissionStageIDTag>

/// Durable mission state is broader than any one AgentRun lifecycle.
/// Provider failures and run interruption can leave a mission recoverable.
public enum MissionPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case draftIntent
    case planning
    case needsDecision
    case ready
    case executing
    case pausedByUser
    case pausedByPolicy
    case blockedExternal
    case interruptedRecoverable
    case validating
    case polishing
    case completedWithEvidence
    case completedWithKnownLimitations
    case cancelled
    case failedIrrecoverably

    public var isTerminal: Bool {
        switch self {
        case .completedWithEvidence,
             .completedWithKnownLimitations,
             .cancelled,
             .failedIrrecoverably:
            true
        default:
            false
        }
    }

    public var canResumeWithoutChangingMissionIdentity: Bool {
        switch self {
        case .pausedByUser,
             .pausedByPolicy,
             .blockedExternal,
             .interruptedRecoverable,
             .needsDecision:
            true
        default:
            false
        }
    }
}

/// Product-level stages remain provider/model agnostic. New evidence may insert
/// or reorder stages without replacing the mission itself.
public enum MissionStageKind: String, Codable, CaseIterable, Hashable, Sendable {
    case understand
    case plan
    case implement
    case run
    case inspect
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
    case active
    case waitingForDecision
    case blocked
    case deferred
    case completed
    case failedRecoverably
    case failedIrrecoverably
    case cancelled

    public var isSettled: Bool {
        switch self {
        case .deferred, .completed, .failedIrrecoverably, .cancelled:
            true
        case .pending, .active, .waitingForDecision, .blocked, .failedRecoverably:
            false
        }
    }
}

public struct MissionStage: Codable, Equatable, Sendable {
    public let stageID: MissionStageID
    public let kind: MissionStageKind
    public let title: String
    public let order: UInt32
    public let required: Bool
    public let dependencies: [MissionStageID]
    public let status: MissionStageStatus

    public init(
        stageID: MissionStageID,
        kind: MissionStageKind,
        title: String,
        order: UInt32,
        required: Bool = true,
        dependencies: [MissionStageID] = [],
        status: MissionStageStatus = .pending
    ) {
        self.stageID = stageID
        self.kind = kind
        self.title = title
        self.order = order
        self.required = required
        self.dependencies = Array(Set(dependencies)).sorted {
            $0.description < $1.description
        }
        self.status = status
    }

    public var validationError: MissionStageGraphValidationError? {
        guard title.hasMissionStageContent else { return .blankStageTitle }
        guard !dependencies.contains(stageID) else { return .selfDependency }
        guard !(required && status == .deferred) else { return .requiredStageDeferred }
        return nil
    }
}

/// A revisioned dependency graph for the living mission plan.
/// Multiple stages may be active simultaneously when their dependencies permit it.
public struct MissionStageGraph: Codable, Equatable, Sendable {
    public let missionID: MissionID
    public let revision: UInt64
    public let stages: [MissionStage]

    public init(
        missionID: MissionID,
        revision: UInt64 = 1,
        stages: [MissionStage]
    ) {
        self.missionID = missionID
        self.revision = revision
        self.stages = stages.sorted {
            if $0.order == $1.order {
                return $0.stageID.description < $1.stageID.description
            }
            return $0.order < $1.order
        }
    }

    public var validationError: MissionStageGraphValidationError? {
        guard revision > 0 else { return .invalidGraphRevision }
        guard !stages.isEmpty else { return .emptyStageGraph }

        var knownIDs = Set<MissionStageID>()
        var knownOrders = Set<UInt32>()
        for stage in stages {
            if let stageError = stage.validationError { return stageError }
            guard knownIDs.insert(stage.stageID).inserted else {
                return .duplicateStageID
            }
            guard knownOrders.insert(stage.order).inserted else {
                return .duplicateStageOrder
            }
        }

        let stagesByID = Dictionary(uniqueKeysWithValues: stages.map { ($0.stageID, $0) })
        for stage in stages {
            for dependency in stage.dependencies {
                guard let dependencyStage = stagesByID[dependency] else {
                    return .missingDependency
                }
                // Dependencies are hard prerequisites. Optional stages are
                // deferrable, so they cannot be used as hard dependency roots.
                // A future soft/ordering edge must be modeled separately.
                if !dependencyStage.required {
                    return .deferrableDependency
                }
            }
        }

        if containsDependencyCycle { return .dependencyCycle }
        return nil
    }

    public var activeStages: [MissionStage] {
        stages.filter { $0.status == .active }
    }

    /// This is deliberately stricter than `MissionStageStatus.isSettled`.
    /// A failed, cancelled, deferred, or structurally empty graph cannot count
    /// as completion evidence.
    public var requiredWorkIsSatisfied: Bool {
        !stages.isEmpty && stages.lazy.filter(\.required).allSatisfy { $0.status == .completed }
    }

    private var containsDependencyCycle: Bool {
        let dependenciesByID = Dictionary(
            uniqueKeysWithValues: stages.map { ($0.stageID, $0.dependencies) }
        )
        var states: [MissionStageID: MissionStageVisitState] = [:]

        func visit(_ stageID: MissionStageID) -> Bool {
            if let state = states[stageID] {
                return state == .visiting
            }
            states[stageID] = .visiting
            for dependency in dependenciesByID[stageID] ?? [] {
                if visit(dependency) { return true }
            }
            states[stageID] = .visited
            return false
        }

        return stages.contains { visit($0.stageID) }
    }
}

public enum MissionStageGraphValidationError: String, Error, Codable, Equatable, Sendable {
    case invalidGraphRevision
    case emptyStageGraph
    case blankStageTitle
    case duplicateStageID
    case duplicateStageOrder
    case selfDependency
    case requiredStageDeferred
    case missingDependency
    case deferrableDependency
    case dependencyCycle
}

private enum MissionStageVisitState {
    case visiting
    case visited
}

private extension String {
    var hasMissionStageContent: Bool {
        !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

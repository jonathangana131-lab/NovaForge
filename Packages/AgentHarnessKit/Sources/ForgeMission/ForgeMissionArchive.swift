import Foundation

/// Versioned, fail-closed persistence boundary for durable NovaForge missions.
/// Persist this archive rather than decoding ForgeMissionState directly.
public struct ForgeMissionArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let state: ForgeMissionState

    public init(state: ForgeMissionState) throws {
        try Self.validate(state)
        self.schemaVersion = Self.currentSchemaVersion
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported Forge mission archive schema version \(version)."
            )
        }
        let state = try container.decode(ForgeMissionState.self, forKey: .state)
        do {
            try Self.validate(state)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid persisted Forge mission archive: \(error.localizedDescription)",
                    underlyingError: error
                )
            )
        }
        self.schemaVersion = version
        self.state = state
    }

    public func encode(to encoder: Encoder) throws {
        try Self.validate(state)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(state, forKey: .state)
    }

    public static func validate(_ state: ForgeMissionState) throws {
        try validateGraph(state.stages)
        guard state.stages.count(where: { $0.status == .active }) <= 1 else {
            throw ForgeMissionArchiveError.multipleActiveStages
        }
        if state.lifecycle == .waitingForDecision,
           state.stages.contains(where: { $0.status == .active }) {
            throw ForgeMissionArchiveError.waitingMissionHasActiveStage
        }
        if state.lifecycle == .completed,
           state.stages.contains(where: { $0.status != .completed && $0.status != .skipped }) {
            throw ForgeMissionArchiveError.completedMissionHasUnfinishedStage
        }

        var knownCheckpoints = Set<MissionCheckpointID>()
        var previousRevision: UInt64 = 0
        for checkpoint in state.checkpoints {
            try validateGraph(checkpoint.stages)
            guard checkpoint.missionID == state.id else {
                throw ForgeMissionArchiveError.checkpointBelongsToAnotherMission
            }
            guard knownCheckpoints.insert(checkpoint.id).inserted else {
                throw ForgeMissionArchiveError.duplicateCheckpoint
            }
            guard checkpoint.revision > previousRevision,
                  checkpoint.revision <= state.revision else {
                throw ForgeMissionArchiveError.invalidCheckpointRevision
            }
            if let parent = checkpoint.parentID,
               !knownCheckpoints.contains(parent) {
                throw ForgeMissionArchiveError.invalidCheckpointParent
            }
            guard checkpoint.steeringCount <= state.steeringNotes.count else {
                throw ForgeMissionArchiveError.invalidCheckpointSteeringCount
            }
            previousRevision = checkpoint.revision
        }
    }

    private static func validateGraph(_ stages: [MissionStage]) throws {
        var ids = Set<MissionStageID>()
        for stage in stages {
            guard ids.insert(stage.id).inserted else {
                throw ForgeMissionArchiveError.duplicateStage
            }
        }
        for stage in stages {
            guard stage.dependencies.allSatisfy(ids.contains) else {
                throw ForgeMissionArchiveError.missingDependency
            }
        }

        let deps = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0.dependencies) })
        var visiting = Set<MissionStageID>()
        var visited = Set<MissionStageID>()
        func visit(_ id: MissionStageID) throws {
            if visiting.contains(id) { throw ForgeMissionArchiveError.dependencyCycle }
            if visited.contains(id) { return }
            visiting.insert(id)
            for dependency in deps[id, default: []] { try visit(dependency) }
            visiting.remove(id)
            visited.insert(id)
        }
        for stage in stages { try visit(stage.id) }
    }
}

public enum ForgeMissionArchiveError: Error, Equatable, Sendable {
    case duplicateStage
    case missingDependency
    case dependencyCycle
    case multipleActiveStages
    case waitingMissionHasActiveStage
    case completedMissionHasUnfinishedStage
    case checkpointBelongsToAnotherMission
    case duplicateCheckpoint
    case invalidCheckpointRevision
    case invalidCheckpointParent
    case invalidCheckpointSteeringCount
}

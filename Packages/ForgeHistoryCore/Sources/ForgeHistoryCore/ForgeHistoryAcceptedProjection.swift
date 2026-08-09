import Foundation

/// Exact opaque identity of a project state already accepted by an upstream Mission/ProjectStore
/// checkpoint. Upstream canonicalizes the stored checkpoint identity before History sees it, so
/// History preserves that value byte-for-byte and rejects non-canonical aliases rather than
/// normalizing them again. The value is never reinterpreted as a path, hash, receipt, or grant.
public struct ForgeHistoryAcceptedProjectStateID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isCanonicalUpstreamIdentity(rawValue) else {
            throw ForgeHistoryAcceptedProjectionError.invalidAcceptedProjectStateID
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    private static func isCanonicalUpstreamIdentity(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ForgeHistoryAcceptedProjectionError: Error, Equatable, Sendable {
    case invalidAcceptedProjectStateID
    case invalidMissionAuthority
    case projectMismatch(checkpointID: String, expectedProjectID: String, actualProjectID: String)
    case checkpointMissionMismatch(checkpointID: String, expectedMissionID: String, actualMissionID: String?)
    case duplicateCheckpointBinding(String)
    case acceptedProjectStateBindingLost(String)
    case acceptedMissionBindingLost(String)
    case unknownAcceptedCheckpoint(String)
}

/// Display-level binding reconstructed from currently accepted upstream project state. This type is
/// intentionally non-Codable: durable bytes must not mint accepted authority on relaunch.
public struct ForgeHistoryAcceptedCheckpointBinding: Hashable, Sendable {
    public let projectID: ForgeHistoryProjectID
    public let acceptedProjectStateID: ForgeHistoryAcceptedProjectStateID
    public let checkpoint: ForgeHistoryCheckpoint

    public init(
        projectID: ForgeHistoryProjectID,
        acceptedProjectStateID: ForgeHistoryAcceptedProjectStateID,
        checkpoint: ForgeHistoryCheckpoint
    ) {
        self.projectID = projectID
        self.acceptedProjectStateID = acceptedProjectStateID
        self.checkpoint = checkpoint
    }
}

/// Minimal accepted-state identity retained beside a canonical History checkpoint.
public struct ForgeHistoryCheckpointProjectStateBinding: Hashable, Sendable {
    public let checkpointID: ForgeHistoryCheckpointID
    public let acceptedProjectStateID: ForgeHistoryAcceptedProjectStateID

    fileprivate init(
        checkpointID: ForgeHistoryCheckpointID,
        acceptedProjectStateID: ForgeHistoryAcceptedProjectStateID
    ) {
        self.checkpointID = checkpointID
        self.acceptedProjectStateID = acceptedProjectStateID
    }
}

/// Ephemeral accepted-state projection for Time Machine presentation. Canonical
/// `ForgeHistoryTimeline` remains the chronology, lineage, mission-scope, and comparison authority.
public struct ForgeHistoryAcceptedTimelineProjection: Hashable, Sendable {
    public let timeline: ForgeHistoryTimeline
    public let acceptedProjectStates: [ForgeHistoryCheckpointProjectStateBinding]

    fileprivate init(
        timeline: ForgeHistoryTimeline,
        acceptedProjectStates: [ForgeHistoryCheckpointProjectStateBinding]
    ) {
        self.timeline = timeline
        self.acceptedProjectStates = acceptedProjectStates
    }

    public func acceptedProjectStateID(
        for checkpointID: ForgeHistoryCheckpointID
    ) -> ForgeHistoryAcceptedProjectStateID? {
        acceptedProjectStates.first(where: { $0.checkpointID == checkpointID })?.acceptedProjectStateID
    }
}

public enum ForgeHistoryAcceptedTimelineProjector {
    public static func project(
        projectID: ForgeHistoryProjectID,
        missionID: ForgeHistoryMissionID? = nil,
        acceptedCheckpoints: [ForgeHistoryAcceptedCheckpointBinding]
    ) throws -> ForgeHistoryAcceptedTimelineProjection {
        var seenCheckpointIDs = Set<ForgeHistoryCheckpointID>()
        var projectStateByCheckpoint = [ForgeHistoryCheckpointID: ForgeHistoryAcceptedProjectStateID]()

        for binding in acceptedCheckpoints {
            let checkpointID = binding.checkpoint.id
            guard seenCheckpointIDs.insert(checkpointID).inserted else {
                throw ForgeHistoryAcceptedProjectionError.duplicateCheckpointBinding(checkpointID.rawValue)
            }
            guard binding.projectID == projectID else {
                throw ForgeHistoryAcceptedProjectionError.projectMismatch(
                    checkpointID: checkpointID.rawValue,
                    expectedProjectID: projectID.rawValue,
                    actualProjectID: binding.projectID.rawValue
                )
            }
            projectStateByCheckpoint[checkpointID] = binding.acceptedProjectStateID
        }

        let timeline = try ForgeHistoryTimeline(
            projectID: projectID,
            missionID: missionID,
            checkpoints: acceptedCheckpoints.map(\.checkpoint)
        )

        var orderedProjectStates: [ForgeHistoryCheckpointProjectStateBinding] = []
        orderedProjectStates.reserveCapacity(timeline.checkpoints.count)
        for checkpoint in timeline.checkpoints {
            guard let acceptedProjectStateID = projectStateByCheckpoint[checkpoint.id] else {
                throw ForgeHistoryAcceptedProjectionError.acceptedProjectStateBindingLost(
                    checkpoint.id.rawValue
                )
            }
            orderedProjectStates.append(
                ForgeHistoryCheckpointProjectStateBinding(
                    checkpointID: checkpoint.id,
                    acceptedProjectStateID: acceptedProjectStateID
                )
            )
        }

        return ForgeHistoryAcceptedTimelineProjection(
            timeline: timeline,
            acceptedProjectStates: orderedProjectStates
        )
    }
}

/// Exact Mission authority coordinates observed on an accepted upstream checkpoint. Constructing
/// this value does not authenticate those coordinates; downstream Mission/ProjectStore execution
/// must revalidate every precondition before mutating project state.
public struct ForgeHistoryMissionAuthority: Hashable, Sendable {
    public let missionRevision: UInt64
    public let authorityEpoch: UInt64
    public let constitutionRevision: UInt64

    public init(
        missionRevision: UInt64,
        authorityEpoch: UInt64,
        constitutionRevision: UInt64
    ) throws {
        guard missionRevision > 0, authorityEpoch > 0, constitutionRevision > 0 else {
            throw ForgeHistoryAcceptedProjectionError.invalidMissionAuthority
        }
        self.missionRevision = missionRevision
        self.authorityEpoch = authorityEpoch
        self.constitutionRevision = constitutionRevision
    }
}

/// Stronger non-Codable binding used only when a checkpoint also carries accepted Mission authority
/// coordinates suitable as Restore/Fork/Compare preconditions.
public struct ForgeHistoryAcceptedMissionCheckpointBinding: Hashable, Sendable {
    public let projectID: ForgeHistoryProjectID
    public let missionID: ForgeHistoryMissionID
    public let acceptedProjectStateID: ForgeHistoryAcceptedProjectStateID
    public let missionAuthority: ForgeHistoryMissionAuthority
    public let checkpoint: ForgeHistoryCheckpoint

    public init(
        projectID: ForgeHistoryProjectID,
        missionID: ForgeHistoryMissionID,
        acceptedProjectStateID: ForgeHistoryAcceptedProjectStateID,
        missionAuthority: ForgeHistoryMissionAuthority,
        checkpoint: ForgeHistoryCheckpoint
    ) {
        self.projectID = projectID
        self.missionID = missionID
        self.acceptedProjectStateID = acceptedProjectStateID
        self.missionAuthority = missionAuthority
        self.checkpoint = checkpoint
    }

    fileprivate var projectStateBinding: ForgeHistoryAcceptedCheckpointBinding {
        ForgeHistoryAcceptedCheckpointBinding(
            projectID: projectID,
            acceptedProjectStateID: acceptedProjectStateID,
            checkpoint: checkpoint
        )
    }
}

/// Exact accepted Mission preconditions retained beside one canonical History checkpoint.
public struct ForgeHistoryAcceptedMissionCheckpointState: Hashable, Sendable {
    public let checkpointID: ForgeHistoryCheckpointID
    public let missionID: ForgeHistoryMissionID
    public let acceptedProjectStateID: ForgeHistoryAcceptedProjectStateID
    public let missionAuthority: ForgeHistoryMissionAuthority

    fileprivate init(
        checkpointID: ForgeHistoryCheckpointID,
        missionID: ForgeHistoryMissionID,
        acceptedProjectStateID: ForgeHistoryAcceptedProjectStateID,
        missionAuthority: ForgeHistoryMissionAuthority
    ) {
        self.checkpointID = checkpointID
        self.missionID = missionID
        self.acceptedProjectStateID = acceptedProjectStateID
        self.missionAuthority = missionAuthority
    }
}

/// Mutation target carrying exactly what Time Machine presentation observed. This is not execution
/// permission; downstream Mission/ProjectStore must reject it if any precondition is stale.
public struct ForgeHistoryAcceptedActionTarget: Hashable, Sendable {
    public let projectID: ForgeHistoryProjectID
    public let checkpointID: ForgeHistoryCheckpointID
    public let missionID: ForgeHistoryMissionID
    public let acceptedProjectStateID: ForgeHistoryAcceptedProjectStateID
    public let missionAuthority: ForgeHistoryMissionAuthority
}

public enum ForgeHistoryAcceptedActionIntent: Hashable, Sendable {
    case restore(ForgeHistoryAcceptedActionTarget)
    case fork(ForgeHistoryAcceptedActionTarget)
    case compare(from: ForgeHistoryAcceptedActionTarget, to: ForgeHistoryAcceptedActionTarget)
}

/// Accepted project-state projection plus exact Mission preconditions required for action intents.
/// Both layers are ephemeral; neither can be decoded into fresh authority on relaunch.
public struct ForgeHistoryAcceptedMissionTimelineProjection: Hashable, Sendable {
    public let acceptedTimeline: ForgeHistoryAcceptedTimelineProjection
    public let acceptedMissionStates: [ForgeHistoryAcceptedMissionCheckpointState]

    public var timeline: ForgeHistoryTimeline { acceptedTimeline.timeline }

    fileprivate init(
        acceptedTimeline: ForgeHistoryAcceptedTimelineProjection,
        acceptedMissionStates: [ForgeHistoryAcceptedMissionCheckpointState]
    ) {
        self.acceptedTimeline = acceptedTimeline
        self.acceptedMissionStates = acceptedMissionStates
    }

    public func acceptedMissionState(
        for checkpointID: ForgeHistoryCheckpointID
    ) -> ForgeHistoryAcceptedMissionCheckpointState? {
        acceptedMissionStates.first(where: { $0.checkpointID == checkpointID })
    }

    public func restoreIntent(
        to checkpointID: ForgeHistoryCheckpointID
    ) throws -> ForgeHistoryAcceptedActionIntent {
        .restore(try actionTarget(for: checkpointID))
    }

    public func forkIntent(
        from checkpointID: ForgeHistoryCheckpointID
    ) throws -> ForgeHistoryAcceptedActionIntent {
        .fork(try actionTarget(for: checkpointID))
    }

    public func compareIntent(
        from fromID: ForgeHistoryCheckpointID,
        to toID: ForgeHistoryCheckpointID
    ) throws -> ForgeHistoryAcceptedActionIntent {
        _ = try timeline.comparison(from: fromID, to: toID)
        return .compare(
            from: try actionTarget(for: fromID),
            to: try actionTarget(for: toID)
        )
    }

    private func actionTarget(
        for checkpointID: ForgeHistoryCheckpointID
    ) throws -> ForgeHistoryAcceptedActionTarget {
        guard let state = acceptedMissionState(for: checkpointID) else {
            throw ForgeHistoryAcceptedProjectionError.unknownAcceptedCheckpoint(checkpointID.rawValue)
        }
        return ForgeHistoryAcceptedActionTarget(
            projectID: timeline.projectID,
            checkpointID: checkpointID,
            missionID: state.missionID,
            acceptedProjectStateID: state.acceptedProjectStateID,
            missionAuthority: state.missionAuthority
        )
    }
}

public enum ForgeHistoryAcceptedMissionTimelineProjector {
    public static func project(
        projectID: ForgeHistoryProjectID,
        missionID: ForgeHistoryMissionID? = nil,
        acceptedCheckpoints: [ForgeHistoryAcceptedMissionCheckpointBinding]
    ) throws -> ForgeHistoryAcceptedMissionTimelineProjection {
        for binding in acceptedCheckpoints {
            guard binding.checkpoint.originatingMissionID == binding.missionID else {
                throw ForgeHistoryAcceptedProjectionError.checkpointMissionMismatch(
                    checkpointID: binding.checkpoint.id.rawValue,
                    expectedMissionID: binding.missionID.rawValue,
                    actualMissionID: binding.checkpoint.originatingMissionID?.rawValue
                )
            }
        }

        let acceptedTimeline = try ForgeHistoryAcceptedTimelineProjector.project(
            projectID: projectID,
            missionID: missionID,
            acceptedCheckpoints: acceptedCheckpoints.map(\.projectStateBinding)
        )

        let missionStateByCheckpoint = Dictionary(
            uniqueKeysWithValues: acceptedCheckpoints.map { binding in
                (
                    binding.checkpoint.id,
                    ForgeHistoryAcceptedMissionCheckpointState(
                        checkpointID: binding.checkpoint.id,
                        missionID: binding.missionID,
                        acceptedProjectStateID: binding.acceptedProjectStateID,
                        missionAuthority: binding.missionAuthority
                    )
                )
            }
        )

        var orderedStates: [ForgeHistoryAcceptedMissionCheckpointState] = []
        orderedStates.reserveCapacity(acceptedTimeline.timeline.checkpoints.count)
        for checkpoint in acceptedTimeline.timeline.checkpoints {
            guard let state = missionStateByCheckpoint[checkpoint.id] else {
                throw ForgeHistoryAcceptedProjectionError.acceptedMissionBindingLost(
                    checkpoint.id.rawValue
                )
            }
            orderedStates.append(state)
        }

        return ForgeHistoryAcceptedMissionTimelineProjection(
            acceptedTimeline: acceptedTimeline,
            acceptedMissionStates: orderedStates
        )
    }
}

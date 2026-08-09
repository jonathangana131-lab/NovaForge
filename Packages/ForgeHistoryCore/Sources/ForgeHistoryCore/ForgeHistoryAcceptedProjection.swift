import Foundation

/// Canonical opaque identity of a project state that an upstream Mission/ProjectStore checkpoint
/// has already accepted. This deliberately mirrors the Mission boundary's whitespace
/// canonicalization and does not reinterpret the value as a path, hash, provider receipt, or
/// permission token.
public struct ForgeHistoryAcceptedProjectStateID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ForgeHistoryAcceptedProjectionError.invalidAcceptedProjectStateID
        }
        self.rawValue = normalized
    }

    public var description: String { rawValue }
}

/// Exact durable Mission authority coordinates copied from the accepted upstream checkpoint.
/// History preserves them but does not decide whether a Mission transition was authorized.
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

public enum ForgeHistoryAcceptedProjectionError: Error, Equatable, Sendable {
    case invalidAcceptedProjectStateID
    case invalidMissionAuthority
    case projectMismatch(checkpointID: String, expectedProjectID: String, actualProjectID: String)
    case checkpointMissionMismatch(checkpointID: String, expectedMissionID: String, actualMissionID: String?)
    case duplicateCheckpointBinding(String)
    case acceptedBindingLost(String)
    case unknownAcceptedCheckpoint(String)
}

/// Boundary input created only after an upstream Mission/ProjectStore checkpoint has been accepted.
/// Project identity, Mission identity, accepted project-state identity, and Mission authority are
/// carried together so a future History adapter cannot flatten two different accepted authorities
/// into one checkpoint-looking presentation record.
public struct ForgeHistoryAcceptedCheckpointBinding: Hashable, Sendable {
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
}

/// Exact accepted-state identity retained beside one canonical History checkpoint.
/// This intentionally remains non-Codable: durable authority stays in Mission/ProjectStore and
/// History must rebuild this projection from currently accepted upstream checkpoint truth.
public struct ForgeHistoryAcceptedCheckpointState: Hashable, Sendable {
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

/// A mutation target with the exact accepted state and Mission authority that presentation code saw.
/// Execution remains under ProjectStore/Mission policy and must verify these preconditions again.
public struct ForgeHistoryAcceptedActionTarget: Hashable, Sendable {
    public let projectID: ForgeHistoryProjectID
    public let checkpointID: ForgeHistoryCheckpointID
    public let missionID: ForgeHistoryMissionID
    public let acceptedProjectStateID: ForgeHistoryAcceptedProjectStateID
    public let missionAuthority: ForgeHistoryMissionAuthority
}

/// Authority-bound user intent. This is still not execution permission; it is a precise request for
/// the downstream Mission/ProjectStore adapter to verify and execute (or reject as stale).
public enum ForgeHistoryAcceptedActionIntent: Hashable, Sendable {
    case restore(ForgeHistoryAcceptedActionTarget)
    case fork(ForgeHistoryAcceptedActionTarget)
    case compare(from: ForgeHistoryAcceptedActionTarget, to: ForgeHistoryAcceptedActionTarget)
}

/// Ephemeral validated projection for app presentation. The canonical timeline supplies lineage,
/// chronology, visual/evidence comparison, and mission scoping; acceptedCheckpointStates supplies
/// exact upstream authority coordinates for restore/fork/compare preconditions.
public struct ForgeHistoryAcceptedTimelineProjection: Hashable, Sendable {
    public let timeline: ForgeHistoryTimeline
    public let acceptedCheckpointStates: [ForgeHistoryAcceptedCheckpointState]

    fileprivate init(
        timeline: ForgeHistoryTimeline,
        acceptedCheckpointStates: [ForgeHistoryAcceptedCheckpointState]
    ) {
        self.timeline = timeline
        self.acceptedCheckpointStates = acceptedCheckpointStates
    }

    public func acceptedState(
        for checkpointID: ForgeHistoryCheckpointID
    ) -> ForgeHistoryAcceptedCheckpointState? {
        acceptedCheckpointStates.first(where: { $0.checkpointID == checkpointID })
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
        guard let state = acceptedState(for: checkpointID) else {
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

public enum ForgeHistoryAcceptedTimelineProjector {
    public static func project(
        projectID: ForgeHistoryProjectID,
        missionID: ForgeHistoryMissionID? = nil,
        acceptedCheckpoints: [ForgeHistoryAcceptedCheckpointBinding]
    ) throws -> ForgeHistoryAcceptedTimelineProjection {
        var seenCheckpointIDs = Set<ForgeHistoryCheckpointID>()
        var acceptedStateByCheckpoint = [ForgeHistoryCheckpointID: ForgeHistoryAcceptedCheckpointState]()

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
            guard binding.checkpoint.originatingMissionID == binding.missionID else {
                throw ForgeHistoryAcceptedProjectionError.checkpointMissionMismatch(
                    checkpointID: checkpointID.rawValue,
                    expectedMissionID: binding.missionID.rawValue,
                    actualMissionID: binding.checkpoint.originatingMissionID?.rawValue
                )
            }

            acceptedStateByCheckpoint[checkpointID] = ForgeHistoryAcceptedCheckpointState(
                checkpointID: checkpointID,
                missionID: binding.missionID,
                acceptedProjectStateID: binding.acceptedProjectStateID,
                missionAuthority: binding.missionAuthority
            )
        }

        let timeline = try ForgeHistoryTimeline(
            projectID: projectID,
            missionID: missionID,
            checkpoints: acceptedCheckpoints.map(\.checkpoint)
        )

        var orderedStates: [ForgeHistoryAcceptedCheckpointState] = []
        orderedStates.reserveCapacity(timeline.checkpoints.count)
        for checkpoint in timeline.checkpoints {
            guard let state = acceptedStateByCheckpoint[checkpoint.id] else {
                throw ForgeHistoryAcceptedProjectionError.acceptedBindingLost(checkpoint.id.rawValue)
            }
            orderedStates.append(state)
        }

        return ForgeHistoryAcceptedTimelineProjection(
            timeline: timeline,
            acceptedCheckpointStates: orderedStates
        )
    }
}

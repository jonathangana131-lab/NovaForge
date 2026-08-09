import Foundation

/// Exact opaque identity of the accepted project state proven by an upstream Mission/ProjectStore
/// checkpoint. History preserves this identity byte-for-byte rather than normalizing it: two
/// upstream states must never collapse to the same History identity because presentation code
/// trimmed or rewrote their identifiers.
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
    case projectMismatch(checkpointID: String, expectedProjectID: String, actualProjectID: String)
    case duplicateCheckpointBinding(String)
    case acceptedProjectStateBindingLost(String)
}

/// Boundary input created only after an upstream checkpoint has been accepted. Carrying project
/// identity per checkpoint prevents a presentation adapter from accidentally mixing two projects
/// into one otherwise-valid History timeline.
///
/// This type is intentionally non-Codable. Decoding a structurally plausible object must not mint
/// accepted Mission/ProjectStore authority on relaunch; the host adapter has to reconstruct this
/// binding from its currently validated authoritative store.
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

/// Minimal accepted-state identity retained beside the canonical timeline. It intentionally does
/// not duplicate provider/model/route evidence; those remain opaque receipt references owned by
/// their existing authorities.
public struct ForgeHistoryCheckpointProjectStateBinding: Hashable, Sendable {
    public let checkpointID: ForgeHistoryCheckpointID
    public let acceptedProjectStateID: ForgeHistoryAcceptedProjectStateID

    init(
        checkpointID: ForgeHistoryCheckpointID,
        acceptedProjectStateID: ForgeHistoryAcceptedProjectStateID
    ) {
        self.checkpointID = checkpointID
        self.acceptedProjectStateID = acceptedProjectStateID
    }
}

/// Ephemeral, validated projection for app presentation. Durable truth remains in the upstream
/// checkpoint/project stores plus ForgeHistoryCheckpoint; this wrapper deliberately is not Codable
/// so persistence cannot create a second History authority.
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

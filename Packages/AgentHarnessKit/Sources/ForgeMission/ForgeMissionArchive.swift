import AgentDomain
import Foundation

public struct ForgeMissionArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let state: ForgeMissionState

    public init(state: ForgeMissionState) throws {
        try Self.validate(state)
        schemaVersion = Self.currentSchemaVersion
        self.state = state
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, state }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "Unsupported Forge mission archive schema version \(version).")
        }
        let state = try container.decode(ForgeMissionState.self, forKey: .state)
        do { try Self.validate(state) }
        catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid persisted Forge mission archive.", underlyingError: error))
        }
        schemaVersion = version
        self.state = state
    }

    public func encode(to encoder: any Encoder) throws {
        try Self.validate(state)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(state, forKey: .state)
    }

    public static func validate(_ state: ForgeMissionState) throws {
        guard state.constitution.validationError == nil else { throw ForgeMissionArchiveError.invalidConstitution }
        guard state.constitution.missionID == state.missionID, state.constitution.projectID == state.projectID else { throw ForgeMissionArchiveError.identityMismatch }
        guard state.graph.missionID == state.missionID, state.graph.validationError == nil else { throw ForgeMissionArchiveError.invalidGraph }
        guard state.route.isValid else { throw ForgeMissionArchiveError.invalidRoute }

        let activeStageIDs = Set(state.graph.stages.filter { $0.status == .active }.map(\.stageID))
        let leaseStageIDs = Set(state.activeLeases.map(\.stageID))
        guard activeStageIDs == leaseStageIDs, state.activeLeases.count == leaseStageIDs.count else { throw ForgeMissionArchiveError.activeLeaseMismatch }
        for lease in state.activeLeases {
            guard lease.missionID == state.missionID,
                  lease.projectID == state.projectID,
                  lease.authorityEpoch == state.authorityEpoch,
                  lease.graphRevision == state.graph.revision,
                  lease.checkpointID == state.latestCheckpointID,
                  lease.routeReceiptID == state.route.routeReceiptID else { throw ForgeMissionArchiveError.staleActiveLease }
        }

        switch state.phase {
        case .executing:
            guard !state.activeLeases.isEmpty else { throw ForgeMissionArchiveError.executingWithoutLease }
        case .needsDecision:
            guard state.activeLeases.isEmpty, state.graph.stages.contains(where: { $0.status == .waitingForDecision }) else { throw ForgeMissionArchiveError.invalidDecisionGate }
        case .blockedExternal:
            guard state.activeLeases.isEmpty, state.graph.stages.contains(where: { $0.status == .blocked }) else { throw ForgeMissionArchiveError.invalidBlockedState }
        case .interruptedRecoverable:
            guard state.activeLeases.isEmpty, state.graph.stages.contains(where: { $0.status == .failedRecoverably }) else { throw ForgeMissionArchiveError.invalidRecoverableState }
        case .failedIrrecoverably:
            guard state.activeLeases.isEmpty, state.graph.stages.contains(where: { $0.status == .failedIrrecoverably }) else { throw ForgeMissionArchiveError.invalidFailedState }
        case .completedWithEvidence, .completedWithKnownLimitations:
            guard state.activeLeases.isEmpty, state.graph.requiredWorkIsSatisfied, state.completionEvidence != nil else { throw ForgeMissionArchiveError.invalidCompletion }
        case .draftIntent, .planning, .ready, .pausedByUser, .pausedByPolicy, .validating, .polishing, .cancelled:
            guard state.activeLeases.isEmpty else { throw ForgeMissionArchiveError.nonExecutingStateHasLease }
        }

        var checkpointIDs = Set<MissionCheckpointID>()
        var priorMissionRevision: UInt64 = 0
        for checkpoint in state.checkpoints {
            guard checkpoint.missionID == state.missionID, checkpoint.projectID == state.projectID else { throw ForgeMissionArchiveError.checkpointIdentityMismatch }
            guard checkpoint.graph.missionID == state.missionID, checkpoint.graph.validationError == nil else { throw ForgeMissionArchiveError.invalidCheckpointGraph }
            guard checkpoint.constitutionRevision > 0, checkpoint.constitutionRevision <= state.constitution.revision else { throw ForgeMissionArchiveError.invalidCheckpointConstitutionRevision }
            guard checkpoint.missionRevision > priorMissionRevision, checkpoint.missionRevision <= state.revision else { throw ForgeMissionArchiveError.invalidCheckpointRevision }
            guard checkpoint.authorityEpoch > 0, checkpoint.authorityEpoch <= state.authorityEpoch else { throw ForgeMissionArchiveError.invalidCheckpointAuthorityEpoch }
            guard checkpointIDs.insert(checkpoint.id).inserted else { throw ForgeMissionArchiveError.duplicateCheckpoint }
            if let parentID = checkpoint.parentID, !checkpointIDs.contains(parentID) { throw ForgeMissionArchiveError.invalidCheckpointParent }
            guard !checkpoint.routeReceiptID.trimmed.isEmpty,
                  !checkpoint.acceptedProjectStateID.trimmed.isEmpty,
                  !checkpoint.summary.trimmed.isEmpty,
                  !checkpoint.evidenceReceiptIDs.values.isEmpty,
                  checkpoint.evidenceReceiptIDs.values.allSatisfy({ !$0.trimmed.isEmpty }) else { throw ForgeMissionArchiveError.invalidCheckpointEvidence }
            priorMissionRevision = checkpoint.missionRevision
        }

        if let completion = state.completionEvidence {
            guard let checkpoint = state.checkpoints.last else { throw ForgeMissionArchiveError.invalidCompletion }
            guard checkpoint.acceptedProjectStateID == completion.acceptedProjectStateID.trimmed,
                  !completion.receiptIDs.values.isEmpty,
                  state.constitution.expectedEvidence.values.allSatisfy(completion.evidenceClasses.contains) else { throw ForgeMissionArchiveError.invalidCompletion }
            if state.phase == .completedWithEvidence, !completion.knownLimitations.values.isEmpty { throw ForgeMissionArchiveError.invalidCompletion }
            if state.phase == .completedWithKnownLimitations, completion.knownLimitations.values.isEmpty { throw ForgeMissionArchiveError.invalidCompletion }
        } else if [.completedWithEvidence, .completedWithKnownLimitations].contains(state.phase) {
            throw ForgeMissionArchiveError.invalidCompletion
        }
    }
}

public enum ForgeMissionArchiveError: Error, Equatable, Sendable {
    case invalidConstitution
    case identityMismatch
    case invalidGraph
    case invalidRoute
    case activeLeaseMismatch
    case staleActiveLease
    case executingWithoutLease
    case nonExecutingStateHasLease
    case invalidDecisionGate
    case invalidBlockedState
    case invalidRecoverableState
    case invalidFailedState
    case invalidCompletion
    case checkpointIdentityMismatch
    case invalidCheckpointGraph
    case invalidCheckpointConstitutionRevision
    case invalidCheckpointRevision
    case invalidCheckpointAuthorityEpoch
    case duplicateCheckpoint
    case invalidCheckpointParent
    case invalidCheckpointEvidence
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

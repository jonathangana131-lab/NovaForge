import AgentDomain
import Foundation

public struct ForgeMissionArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
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
        try validateDurableRecords(
            stageEvidence: state.stageEvidence,
            workerReceipts: state.workerReceipts,
            decisions: state.decisions,
            recoveryRecords: state.recoveryRecords,
            missionID: state.missionID,
            projectID: state.projectID,
            knownStageIDs: Set(state.graph.stages.map(\.stageID))
        )
        try validateCompletedStageEvidence(
            stages: state.graph.stages,
            stageEvidence: state.stageEvidence,
            workerReceipts: state.workerReceipts
        )
        try validatePhaseStageCoherence(phase: state.phase, stages: state.graph.stages)

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
            guard state.activeLeases.isEmpty,
                  let pending = state.pendingDecision,
                  !pending.prompt.trimmed.isEmpty,
                  state.graph.stages.contains(where: {
                      $0.stageID == pending.stageID && $0.status == .waitingForDecision
                  }),
                  state.workerReceipts.contains(where: {
                      $0.stageID == pending.stageID &&
                      $0.kind == .needsDecision &&
                      $0.summary == pending.prompt &&
                      $0.acceptedAt == pending.acceptedAt
                  }) else { throw ForgeMissionArchiveError.invalidDecisionGate }
        case .blockedExternal:
            let blocked = state.graph.stages.filter { $0.status == .blocked }
            guard state.activeLeases.isEmpty,
                  blocked.count == 1,
                  state.workerReceipts.contains(where: { $0.stageID == blocked[0].stageID && $0.kind == .blockedExternal }) else {
                throw ForgeMissionArchiveError.invalidBlockedState
            }
        case .interruptedRecoverable:
            let failed = state.graph.stages.filter { $0.status == .failedRecoverably }
            guard state.activeLeases.isEmpty,
                  failed.count == 1,
                  state.workerReceipts.contains(where: { $0.stageID == failed[0].stageID && $0.kind == .failedRecoverably }) else {
                throw ForgeMissionArchiveError.invalidRecoverableState
            }
        case .failedIrrecoverably:
            let failed = state.graph.stages.filter { $0.status == .failedIrrecoverably }
            guard state.activeLeases.isEmpty,
                  failed.count == 1,
                  state.workerReceipts.contains(where: { $0.stageID == failed[0].stageID && $0.kind == .failedIrrecoverably }) else {
                throw ForgeMissionArchiveError.invalidFailedState
            }
        case .completedWithEvidence, .completedWithKnownLimitations:
            guard state.activeLeases.isEmpty,
                  state.graph.requiredWorkIsSatisfied,
                  state.graph.stages.allSatisfy({ [.completed, .deferred].contains($0.status) }),
                  state.completionEvidence != nil else { throw ForgeMissionArchiveError.invalidCompletion }
        case .draftIntent, .planning, .ready, .pausedByUser, .pausedByPolicy, .validating, .polishing, .cancelled:
            guard state.activeLeases.isEmpty else { throw ForgeMissionArchiveError.nonExecutingStateHasLease }
        }
        if state.phase != .needsDecision, state.pendingDecision != nil {
            throw ForgeMissionArchiveError.invalidDecisionGate
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
            try validateDurableRecords(
                stageEvidence: checkpoint.stageEvidence,
                workerReceipts: checkpoint.workerReceipts,
                decisions: checkpoint.decisions,
                recoveryRecords: checkpoint.recoveryRecords,
                missionID: checkpoint.missionID,
                projectID: checkpoint.projectID,
                knownStageIDs: Set(checkpoint.graph.stages.map(\.stageID))
            )
            try validateCompletedStageEvidence(
                stages: checkpoint.graph.stages,
                stageEvidence: checkpoint.stageEvidence,
                workerReceipts: checkpoint.workerReceipts
            )
            try validatePhaseStageCoherence(phase: checkpoint.phase, stages: checkpoint.graph.stages)
            switch checkpoint.phase {
            case .needsDecision:
                guard let pending = checkpoint.pendingDecision,
                      !pending.prompt.trimmed.isEmpty,
                      checkpoint.graph.stages.contains(where: {
                          $0.stageID == pending.stageID && $0.status == .waitingForDecision
                      }),
                      checkpoint.workerReceipts.contains(where: {
                          $0.stageID == pending.stageID &&
                          $0.kind == .needsDecision &&
                          $0.summary == pending.prompt &&
                          $0.acceptedAt == pending.acceptedAt
                      }) else { throw ForgeMissionArchiveError.invalidDecisionGate }
            case .blockedExternal:
                let blocked = checkpoint.graph.stages.filter { $0.status == .blocked }
                guard checkpoint.pendingDecision == nil,
                      blocked.count == 1,
                      checkpoint.workerReceipts.contains(where: { $0.stageID == blocked[0].stageID && $0.kind == .blockedExternal }) else {
                    throw ForgeMissionArchiveError.invalidBlockedState
                }
            case .interruptedRecoverable:
                let failed = checkpoint.graph.stages.filter { $0.status == .failedRecoverably }
                guard checkpoint.pendingDecision == nil,
                      failed.count == 1,
                      checkpoint.workerReceipts.contains(where: { $0.stageID == failed[0].stageID && $0.kind == .failedRecoverably }) else {
                    throw ForgeMissionArchiveError.invalidRecoverableState
                }
            case .executing, .failedIrrecoverably, .completedWithEvidence, .completedWithKnownLimitations, .cancelled:
                throw ForgeMissionArchiveError.invalidCheckpointPhase
            case .draftIntent, .planning, .ready, .pausedByUser, .pausedByPolicy, .validating, .polishing:
                guard checkpoint.pendingDecision == nil else { throw ForgeMissionArchiveError.invalidDecisionGate }
            }
            priorMissionRevision = checkpoint.missionRevision
        }

        if let completion = state.completionEvidence {
            guard [.completedWithEvidence, .completedWithKnownLimitations].contains(state.phase),
                  let checkpoint = state.checkpoints.last else { throw ForgeMissionArchiveError.invalidCompletion }
            guard checkpoint.acceptedProjectStateID == completion.acceptedProjectStateID.trimmed,
                  checkpoint.graph == state.graph,
                  checkpoint.constitutionRevision == state.constitution.revision,
                  checkpoint.routeReceiptID == state.route.routeReceiptID,
                  checkpoint.missionRevision < UInt64.max,
                  checkpoint.authorityEpoch < UInt64.max,
                  checkpoint.missionRevision + 1 == state.revision,
                  checkpoint.authorityEpoch + 1 == state.authorityEpoch,
                  !completion.receiptIDs.values.isEmpty,
                  state.constitution.expectedEvidence.values.allSatisfy(completion.evidenceClasses.contains) else { throw ForgeMissionArchiveError.invalidCompletion }
            if state.phase == .completedWithEvidence, !completion.knownLimitations.values.isEmpty { throw ForgeMissionArchiveError.invalidCompletion }
            if state.phase == .completedWithKnownLimitations, completion.knownLimitations.values.isEmpty { throw ForgeMissionArchiveError.invalidCompletion }
        } else if [.completedWithEvidence, .completedWithKnownLimitations].contains(state.phase) {
            throw ForgeMissionArchiveError.invalidCompletion
        }
    }

    private static func validatePhaseStageCoherence(
        phase: MissionPhase,
        stages: [MissionStage]
    ) throws {
        let ordinary: Set<MissionStageStatus> = [.pending, .deferred, .completed]
        let executing: Set<MissionStageStatus> = [.pending, .active, .deferred, .completed]

        switch phase {
        case .executing:
            guard stages.allSatisfy({ executing.contains($0.status) }),
                  stages.contains(where: { $0.status == .active }) else {
                throw ForgeMissionArchiveError.invalidPhaseStageState
            }
        case .needsDecision:
            guard stages.filter({ $0.status == .waitingForDecision }).count == 1,
                  stages.allSatisfy({ ordinary.contains($0.status) || $0.status == .waitingForDecision }) else {
                throw ForgeMissionArchiveError.invalidPhaseStageState
            }
        case .blockedExternal:
            guard stages.filter({ $0.status == .blocked }).count == 1,
                  stages.allSatisfy({ ordinary.contains($0.status) || $0.status == .blocked }) else {
                throw ForgeMissionArchiveError.invalidPhaseStageState
            }
        case .interruptedRecoverable:
            guard stages.filter({ $0.status == .failedRecoverably }).count == 1,
                  stages.allSatisfy({ ordinary.contains($0.status) || $0.status == .failedRecoverably }) else {
                throw ForgeMissionArchiveError.invalidPhaseStageState
            }
        case .failedIrrecoverably:
            guard stages.filter({ $0.status == .failedIrrecoverably }).count == 1,
                  stages.allSatisfy({ ordinary.contains($0.status) || $0.status == .failedIrrecoverably }) else {
                throw ForgeMissionArchiveError.invalidPhaseStageState
            }
        case .completedWithEvidence, .completedWithKnownLimitations:
            guard stages.allSatisfy({ [.completed, .deferred].contains($0.status) }) else {
                throw ForgeMissionArchiveError.invalidPhaseStageState
            }
        case .draftIntent, .planning, .ready, .pausedByUser, .pausedByPolicy, .validating, .polishing:
            guard stages.allSatisfy({ ordinary.contains($0.status) }) else {
                throw ForgeMissionArchiveError.invalidPhaseStageState
            }
        case .cancelled:
            // Cancellation preserves the truthful pre-cancel gate when there was
            // no active lease, or marks one or more active stages cancelled. The
            // active-lease consistency check above still rejects any live active state.
            break
        }
    }

    private static func validateDurableRecords(
        stageEvidence: [MissionStageEvidence],
        workerReceipts: [MissionAcceptedWorkerReceipt],
        decisions: [MissionDecisionRecord],
        recoveryRecords: [MissionRecoveryRecord],
        missionID: MissionID,
        projectID: ProjectID,
        knownStageIDs: Set<MissionStageID>
    ) throws {
        guard stageEvidence.allSatisfy({
            knownStageIDs.contains($0.stageID) &&
            !$0.summary.trimmed.isEmpty &&
            !$0.receiptIDs.values.isEmpty &&
            $0.receiptIDs.values.allSatisfy({ !$0.trimmed.isEmpty })
        }) else { throw ForgeMissionArchiveError.invalidStageEvidence }
        guard workerReceipts.allSatisfy({
            $0.missionID == missionID &&
            $0.projectID == projectID &&
            knownStageIDs.contains($0.stageID) &&
            !$0.summary.trimmed.isEmpty &&
            $0.evidenceReceiptIDs.values.allSatisfy({ !$0.trimmed.isEmpty })
        }) else { throw ForgeMissionArchiveError.invalidWorkerReceipt }
        guard decisions.allSatisfy({ record in
            knownStageIDs.contains(record.stageID) &&
            !record.acceptedAnswer.trimmed.isEmpty &&
            !record.decisionReceiptID.trimmed.isEmpty &&
            workerReceipts.contains(where: { $0.stageID == record.stageID && $0.kind == .needsDecision })
        }) else { throw ForgeMissionArchiveError.invalidDecisionRecord }
        guard recoveryRecords.allSatisfy({ record in
            knownStageIDs.contains(record.stageID) &&
            !record.resolutionReceiptID.trimmed.isEmpty &&
            workerReceipts.contains(where: { receipt in
                receipt.stageID == record.stageID &&
                ((record.kind == .externalBlockResolved && receipt.kind == .blockedExternal) ||
                 (record.kind == .recoverableFailureRetried && receipt.kind == .failedRecoverably))
            })
        }) else {
            throw ForgeMissionArchiveError.invalidRecoveryRecord
        }
    }

    private static func validateCompletedStageEvidence(
        stages: [MissionStage],
        stageEvidence: [MissionStageEvidence],
        workerReceipts: [MissionAcceptedWorkerReceipt]
    ) throws {
        let completedStageIDs = Set(stages.lazy.filter { $0.status == .completed }.map(\.stageID))
        let evidencedStageIDs = Set(stageEvidence.map(\.stageID))
        guard evidencedStageIDs == completedStageIDs,
              stageEvidence.count == completedStageIDs.count else {
            throw ForgeMissionArchiveError.invalidStageEvidence
        }
        let completedReceipts = workerReceipts.filter { $0.kind == .completed }
        guard Set(completedReceipts.map(\.stageID)) == completedStageIDs,
              completedReceipts.count == completedStageIDs.count else {
            throw ForgeMissionArchiveError.invalidWorkerReceipt
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
    case invalidPhaseStageState
    case checkpointIdentityMismatch
    case invalidCheckpointGraph
    case invalidCheckpointConstitutionRevision
    case invalidCheckpointRevision
    case invalidCheckpointAuthorityEpoch
    case duplicateCheckpoint
    case invalidCheckpointParent
    case invalidCheckpointEvidence
    case invalidCheckpointPhase
    case invalidStageEvidence
    case invalidWorkerReceipt
    case invalidDecisionRecord
    case invalidRecoveryRecord
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

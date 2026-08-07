import AgentDomain
import Foundation
import ProjectBrain

public enum MissionMutationError: Error, Equatable, Sendable {
    case staleRevision(expected: MissionRevision, actual: MissionRevision)
    case invalidStatusTransition(from: MissionStatus, to: MissionStatus)
    case revisionOverflow
    case duplicateStage(MissionStageID)
    case missingDependency(stageID: MissionStageID, dependencyID: MissionStageID)
    case cyclicStageGraph
    case stageNotFound(MissionStageID)
    case stageNotRunnable(MissionStageID)
    case activeStageMismatch(expected: MissionStageID?, actual: MissionStageID?)
    case invalidMissionIdentity
    case projectMismatch
    case staleWorkerResult
    case missionNotResumable(MissionStatus)
    case attemptOverflow(MissionStageID)
    case requiredStageCannotBeSkipped(MissionStageID)
}

public enum MissionReducer {
    public static func create(
        missionID: MissionID = MissionID(),
        projectID: ProjectID,
        constitution: MissionConstitution,
        stages: [MissionStage],
        brain: ProjectBrainSnapshot,
        at instant: AgentInstant
    ) throws -> MissionSnapshot {
        guard brain.projectID == projectID else {
            throw MissionMutationError.projectMismatch
        }
        try validateStageGraph(stages)
        return MissionSnapshot(
            missionID: missionID,
            projectID: projectID,
            constitution: constitution,
            status: .draftIntent,
            stages: stages,
            activeStageID: nil,
            workerSelection: nil,
            brain: brain,
            latestCheckpointID: nil,
            revision: .initial,
            createdAt: instant,
            updatedAt: instant
        )
    }

    public static func transition(
        to status: MissionStatus,
        expectedRevision: MissionRevision,
        at instant: AgentInstant,
        in snapshot: MissionSnapshot
    ) throws -> MissionSnapshot {
        try requireRevision(expectedRevision, in: snapshot)
        guard canTransition(from: snapshot.status, to: status) else {
            throw MissionMutationError.invalidStatusTransition(from: snapshot.status, to: status)
        }
        return try copy(snapshot, status: status, at: instant)
    }

    public static func insertStage(
        _ stage: MissionStage,
        expectedRevision: MissionRevision,
        at instant: AgentInstant,
        into snapshot: MissionSnapshot
    ) throws -> MissionSnapshot {
        try requireRevision(expectedRevision, in: snapshot)
        guard !snapshot.stages.contains(where: { $0.id == stage.id }) else {
            throw MissionMutationError.duplicateStage(stage.id)
        }
        var stages = snapshot.stages
        stages.append(stage)
        try validateStageGraph(stages)
        return try copy(snapshot, stages: stages, at: instant)
    }

    public static func startStage(
        _ stageID: MissionStageID,
        workerSelection: MissionWorkerSelection,
        workerLeaseID: MissionWorkerLeaseID = MissionWorkerLeaseID(),
        expectedRevision: MissionRevision,
        at instant: AgentInstant,
        in snapshot: MissionSnapshot
    ) throws -> (MissionSnapshot, MissionWorkToken) {
        try requireRevision(expectedRevision, in: snapshot)
        guard snapshot.status == .ready else {
            throw MissionMutationError.invalidStatusTransition(from: snapshot.status, to: .executing)
        }
        guard snapshot.activeStageID == nil else {
            throw MissionMutationError.activeStageMismatch(expected: nil, actual: snapshot.activeStageID)
        }
        guard let index = snapshot.stages.firstIndex(where: { $0.id == stageID }) else {
            throw MissionMutationError.stageNotFound(stageID)
        }
        let stage = snapshot.stages[index]
        guard stage.state == .queued || stage.state == .failedRecoverable else {
            throw MissionMutationError.stageNotRunnable(stageID)
        }
        let states = Dictionary(uniqueKeysWithValues: snapshot.stages.map { ($0.id, $0.state) })
        let dependenciesSatisfied = stage.dependencyIDs.allSatisfy { id in
            guard let state = states[id] else { return false }
            return state == .completed || state == .skipped
        }
        guard dependenciesSatisfied else {
            throw MissionMutationError.stageNotRunnable(stageID)
        }
        guard stage.attempt < UInt32.max else {
            throw MissionMutationError.attemptOverflow(stageID)
        }
        let attempt = stage.attempt + 1
        var stages = snapshot.stages
        stages[index] = stage.replacing(
            state: .running,
            attempt: attempt,
            workerLeaseID: .some(workerLeaseID)
        )
        let next = try copy(
            snapshot,
            status: .executing,
            stages: stages,
            activeStageID: .some(stageID),
            workerSelection: .some(workerSelection),
            at: instant
        )
        return (
            next,
            MissionWorkToken(
                missionID: next.missionID,
                projectID: next.projectID,
                stageID: stageID,
                attempt: attempt,
                workerLeaseID: workerLeaseID
            )
        )
    }

    public static func rerouteActiveStage(
        to workerSelection: MissionWorkerSelection,
        workerLeaseID: MissionWorkerLeaseID = MissionWorkerLeaseID(),
        expectedRevision: MissionRevision,
        at instant: AgentInstant,
        in snapshot: MissionSnapshot
    ) throws -> (MissionSnapshot, MissionWorkToken) {
        try requireRevision(expectedRevision, in: snapshot)
        guard snapshot.status == .executing else {
            throw MissionMutationError.invalidStatusTransition(from: snapshot.status, to: .executing)
        }
        guard let stageID = snapshot.activeStageID,
              let index = snapshot.stages.firstIndex(where: { $0.id == stageID }) else {
            throw MissionMutationError.activeStageMismatch(expected: snapshot.activeStageID, actual: nil)
        }
        let stage = snapshot.stages[index]
        guard stage.state == .running else {
            throw MissionMutationError.stageNotRunnable(stageID)
        }
        guard stage.attempt < UInt32.max else {
            throw MissionMutationError.attemptOverflow(stageID)
        }
        let attempt = stage.attempt + 1
        var stages = snapshot.stages
        stages[index] = stage.replacing(attempt: attempt, workerLeaseID: .some(workerLeaseID))
        let next = try copy(
            snapshot,
            stages: stages,
            workerSelection: .some(workerSelection),
            at: instant
        )
        return (
            next,
            MissionWorkToken(
                missionID: next.missionID,
                projectID: next.projectID,
                stageID: stageID,
                attempt: attempt,
                workerLeaseID: workerLeaseID
            )
        )
    }

    public static func acceptWorkerResult(
        _ result: MissionWorkerResult,
        token: MissionWorkToken,
        at instant: AgentInstant,
        in snapshot: MissionSnapshot
    ) throws -> MissionSnapshot {
        guard token.missionID == snapshot.missionID,
              token.projectID == snapshot.projectID,
              snapshot.activeStageID == token.stageID,
              let index = snapshot.stages.firstIndex(where: { $0.id == token.stageID }) else {
            throw MissionMutationError.staleWorkerResult
        }
        let stage = snapshot.stages[index]
        guard snapshot.status == .executing,
              stage.state == .running,
              stage.attempt == token.attempt,
              stage.workerLeaseID == token.workerLeaseID else {
            throw MissionMutationError.staleWorkerResult
        }
        var stages = snapshot.stages
        stages[index] = stage.replacing(
            state: .completed,
            workerLeaseID: .some(nil),
            acceptedSummary: .some(result.summary),
            acceptedEvidenceIDs: result.evidenceIDs
        )
        return try copy(
            snapshot,
            status: .ready,
            stages: stages,
            activeStageID: .some(nil),
            at: instant
        )
    }

    public static func pauseByUser(
        expectedRevision: MissionRevision,
        at instant: AgentInstant,
        in snapshot: MissionSnapshot
    ) throws -> MissionSnapshot {
        try requireRevision(expectedRevision, in: snapshot)
        guard snapshot.status == .executing else {
            throw MissionMutationError.invalidStatusTransition(from: snapshot.status, to: .pausedByUser)
        }
        guard snapshot.activeStageID != nil else {
            throw MissionMutationError.activeStageMismatch(expected: nil, actual: snapshot.activeStageID)
        }
        let stages = invalidateActiveLease(in: snapshot.stages, activeStageID: snapshot.activeStageID)
        return try copy(snapshot, status: .pausedByUser, stages: stages, at: instant)
    }

    public static func interruptForRecovery(
        expectedRevision: MissionRevision,
        at instant: AgentInstant,
        in snapshot: MissionSnapshot
    ) throws -> MissionSnapshot {
        try requireRevision(expectedRevision, in: snapshot)
        guard !isTerminal(snapshot.status) else {
            throw MissionMutationError.invalidStatusTransition(from: snapshot.status, to: .interruptedRecoverable)
        }
        let stages = invalidateActiveLease(in: snapshot.stages, activeStageID: snapshot.activeStageID)
        return try copy(snapshot, status: .interruptedRecoverable, stages: stages, at: instant)
    }

    public static func resumeActiveStage(
        workerSelection: MissionWorkerSelection,
        workerLeaseID: MissionWorkerLeaseID = MissionWorkerLeaseID(),
        expectedRevision: MissionRevision,
        at instant: AgentInstant,
        in snapshot: MissionSnapshot
    ) throws -> (MissionSnapshot, MissionWorkToken) {
        try requireRevision(expectedRevision, in: snapshot)
        guard snapshot.status == .pausedByUser || snapshot.status == .interruptedRecoverable else {
            throw MissionMutationError.missionNotResumable(snapshot.status)
        }
        guard let stageID = snapshot.activeStageID,
              let index = snapshot.stages.firstIndex(where: { $0.id == stageID }) else {
            throw MissionMutationError.activeStageMismatch(expected: snapshot.activeStageID, actual: nil)
        }
        let stage = snapshot.stages[index]
        guard stage.state == .running || stage.state == .failedRecoverable else {
            throw MissionMutationError.stageNotRunnable(stageID)
        }
        guard stage.attempt < UInt32.max else {
            throw MissionMutationError.attemptOverflow(stageID)
        }
        let attempt = stage.attempt + 1
        var stages = snapshot.stages
        stages[index] = stage.replacing(
            state: .running,
            attempt: attempt,
            workerLeaseID: .some(workerLeaseID)
        )
        let next = try copy(
            snapshot,
            status: .executing,
            stages: stages,
            workerSelection: .some(workerSelection),
            at: instant
        )
        return (
            next,
            MissionWorkToken(
                missionID: next.missionID,
                projectID: next.projectID,
                stageID: stageID,
                attempt: attempt,
                workerLeaseID: workerLeaseID
            )
        )
    }

    public static func skipOptionalStage(
        _ stageID: MissionStageID,
        expectedRevision: MissionRevision,
        at instant: AgentInstant,
        in snapshot: MissionSnapshot
    ) throws -> MissionSnapshot {
        try requireRevision(expectedRevision, in: snapshot)
        guard let index = snapshot.stages.firstIndex(where: { $0.id == stageID }) else {
            throw MissionMutationError.stageNotFound(stageID)
        }
        let stage = snapshot.stages[index]
        guard stage.isOptional else {
            throw MissionMutationError.requiredStageCannotBeSkipped(stageID)
        }
        guard stage.state == .queued || stage.state == .blocked else {
            throw MissionMutationError.stageNotRunnable(stageID)
        }
        var stages = snapshot.stages
        stages[index] = stage.replacing(state: .skipped, workerLeaseID: .some(nil))
        return try copy(snapshot, stages: stages, at: instant)
    }

    public static func replaceBrain(
        _ brain: ProjectBrainSnapshot,
        expectedRevision: MissionRevision,
        at instant: AgentInstant,
        in snapshot: MissionSnapshot
    ) throws -> MissionSnapshot {
        try requireRevision(expectedRevision, in: snapshot)
        guard brain.projectID == snapshot.projectID else {
            throw MissionMutationError.projectMismatch
        }
        return try copy(snapshot, brain: brain, at: instant)
    }

    public static func checkpoint(
        checkpointID: MissionCheckpointID = MissionCheckpointID(),
        acceptedProjectStateID: String,
        evidenceIDs: [String],
        expectedRevision: MissionRevision,
        at instant: AgentInstant,
        in snapshot: MissionSnapshot
    ) throws -> (MissionSnapshot, MissionCheckpoint) {
        try requireRevision(expectedRevision, in: snapshot)
        let parentID = snapshot.latestCheckpointID
        let next = try copy(snapshot, latestCheckpointID: .some(checkpointID), at: instant)
        let checkpoint = MissionCheckpoint(
            id: checkpointID,
            parentID: parentID,
            snapshot: next,
            acceptedProjectStateID: acceptedProjectStateID,
            evidenceIDs: evidenceIDs,
            createdAt: instant
        )
        return (next, checkpoint)
    }

    public static func recover(
        from checkpoint: MissionCheckpoint,
        expectedMissionID: MissionID,
        expectedProjectID: ProjectID,
        at instant: AgentInstant
    ) throws -> MissionSnapshot {
        let snapshot = checkpoint.snapshot
        guard checkpoint.id == snapshot.latestCheckpointID,
              snapshot.missionID == expectedMissionID,
              snapshot.projectID == expectedProjectID else {
            throw MissionMutationError.invalidMissionIdentity
        }
        let stages = invalidateActiveLease(in: snapshot.stages, activeStageID: snapshot.activeStageID)
        return try copy(
            snapshot,
            status: .interruptedRecoverable,
            stages: stages,
            at: instant
        )
    }

    public static func validateStageGraph(_ stages: [MissionStage]) throws {
        var stageByID: [MissionStageID: MissionStage] = [:]
        for stage in stages {
            guard stageByID[stage.id] == nil else {
                throw MissionMutationError.duplicateStage(stage.id)
            }
            stageByID[stage.id] = stage
        }
        for stage in stages {
            for dependencyID in stage.dependencyIDs where stageByID[dependencyID] == nil {
                throw MissionMutationError.missingDependency(stageID: stage.id, dependencyID: dependencyID)
            }
        }

        enum VisitState { case visiting, visited }
        var visits: [MissionStageID: VisitState] = [:]
        func visit(_ id: MissionStageID) throws {
            if visits[id] == .visiting { throw MissionMutationError.cyclicStageGraph }
            if visits[id] == .visited { return }
            visits[id] = .visiting
            guard let stage = stageByID[id] else { return }
            for dependencyID in stage.dependencyIDs {
                try visit(dependencyID)
            }
            visits[id] = .visited
        }
        for stage in stages {
            try visit(stage.id)
        }
    }

    private static func isTerminal(_ status: MissionStatus) -> Bool {
        switch status {
        case .completedWithEvidence, .completedWithKnownLimitations, .cancelled, .failedIrrecoverably:
            return true
        default:
            return false
        }
    }

    private static func canTransition(from: MissionStatus, to: MissionStatus) -> Bool {
        switch (from, to) {
        case (.draftIntent, .planning),
             (.draftIntent, .needsDecision),
             (.draftIntent, .cancelled),
             (.planning, .needsDecision),
             (.planning, .ready),
             (.planning, .cancelled),
             (.needsDecision, .planning),
             (.needsDecision, .ready),
             (.needsDecision, .cancelled),
             (.ready, .planning),
             (.ready, .cancelled),
             (.pausedByPolicy, .cancelled),
             (.blockedExternal, .cancelled),
             (.interruptedRecoverable, .cancelled),
             (.failedIrrecoverably, .cancelled):
            return true
        default:
            return false
        }
    }

    private static func requireRevision(
        _ expected: MissionRevision,
        in snapshot: MissionSnapshot
    ) throws {
        guard expected == snapshot.revision else {
            throw MissionMutationError.staleRevision(expected: expected, actual: snapshot.revision)
        }
    }

    private static func invalidateActiveLease(
        in stages: [MissionStage],
        activeStageID: MissionStageID?
    ) -> [MissionStage] {
        guard let activeStageID,
              let index = stages.firstIndex(where: { $0.id == activeStageID }) else {
            return stages
        }
        var copy = stages
        copy[index] = copy[index].replacing(workerLeaseID: .some(nil))
        return copy
    }

    private static func copy(
        _ snapshot: MissionSnapshot,
        status: MissionStatus? = nil,
        stages: [MissionStage]? = nil,
        activeStageID: MissionStageID?? = nil,
        workerSelection: MissionWorkerSelection?? = nil,
        brain: ProjectBrainSnapshot? = nil,
        latestCheckpointID: MissionCheckpointID?? = nil,
        at instant: AgentInstant
    ) throws -> MissionSnapshot {
        guard let nextRevision = snapshot.revision.successor else {
            throw MissionMutationError.revisionOverflow
        }
        return MissionSnapshot(
            missionID: snapshot.missionID,
            projectID: snapshot.projectID,
            constitution: snapshot.constitution,
            status: status ?? snapshot.status,
            stages: stages ?? snapshot.stages,
            activeStageID: activeStageID ?? snapshot.activeStageID,
            workerSelection: workerSelection ?? snapshot.workerSelection,
            brain: brain ?? snapshot.brain,
            latestCheckpointID: latestCheckpointID ?? snapshot.latestCheckpointID,
            revision: nextRevision,
            createdAt: snapshot.createdAt,
            updatedAt: instant
        )
    }
}

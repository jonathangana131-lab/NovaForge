import AgentDomain
import Foundation

public enum MissionCheckpointIDTag: AgentIdentifierTag {}
public enum MissionWorkLeaseIDTag: AgentIdentifierTag {}
public enum MissionDecisionIDTag: AgentIdentifierTag {}
public enum MissionDecisionRequestIDTag: AgentIdentifierTag {}

public typealias MissionCheckpointID = AgentIdentifier<MissionCheckpointIDTag>
public typealias MissionWorkLeaseID = AgentIdentifier<MissionWorkLeaseIDTag>
public typealias MissionDecisionID = AgentIdentifier<MissionDecisionIDTag>
public typealias MissionDecisionRequestID = AgentIdentifier<MissionDecisionRequestIDTag>

public struct MissionRouteBinding: Codable, Equatable, Sendable {
    public let routeReceiptID: String
    public init(routeReceiptID: String) { self.routeReceiptID = routeReceiptID }
    public var isValid: Bool { !routeReceiptID.trimmed.isEmpty }
}

public struct MissionWorkLease: Codable, Equatable, Sendable {
    public let leaseID: MissionWorkLeaseID
    public let missionID: MissionID
    public let projectID: ProjectID
    public let stageID: MissionStageID
    public let authorityEpoch: UInt64
    public let graphRevision: UInt64
    public let checkpointID: MissionCheckpointID?
    public let routeReceiptID: String

    public init(
        leaseID: MissionWorkLeaseID = MissionWorkLeaseID(),
        missionID: MissionID,
        projectID: ProjectID,
        stageID: MissionStageID,
        authorityEpoch: UInt64,
        graphRevision: UInt64,
        checkpointID: MissionCheckpointID?,
        routeReceiptID: String
    ) {
        self.leaseID = leaseID
        self.missionID = missionID
        self.projectID = projectID
        self.stageID = stageID
        self.authorityEpoch = authorityEpoch
        self.graphRevision = graphRevision
        self.checkpointID = checkpointID
        self.routeReceiptID = routeReceiptID
    }
}

public enum MissionWorkerOutcome: String, Codable, Equatable, Sendable {
    case completed
    case blockedExternal
    case needsDecision
    case failedRecoverably
    case failedIrrecoverably
}

public struct MissionWorkerResult: Codable, Equatable, Sendable {
    public let lease: MissionWorkLease
    public let outcome: MissionWorkerOutcome
    public let summary: String
    public let evidenceReceiptIDs: MissionStringSet
    public let allowsDecisionDelegation: Bool

    public init(
        lease: MissionWorkLease,
        outcome: MissionWorkerOutcome,
        summary: String,
        evidenceReceiptIDs: MissionStringSet = MissionStringSet([]),
        allowsDecisionDelegation: Bool = false
    ) {
        self.lease = lease
        self.outcome = outcome
        self.summary = summary
        self.evidenceReceiptIDs = evidenceReceiptIDs
        self.allowsDecisionDelegation = allowsDecisionDelegation
    }
}

public enum MissionAcceptedWorkerReceiptKind: String, Codable, Equatable, Sendable {
    case completed
    case needsDecision
    case blockedExternal
    case failedRecoverably
    case failedIrrecoverably
}

public struct MissionAcceptedWorkerReceipt: Codable, Equatable, Sendable {
    public let leaseID: MissionWorkLeaseID
    public let missionID: MissionID
    public let projectID: ProjectID
    public let stageID: MissionStageID
    public let kind: MissionAcceptedWorkerReceiptKind
    public let summary: String
    public let evidenceReceiptIDs: MissionStringSet
    public let acceptedAt: AgentInstant
}

public struct MissionDecisionRequest: Codable, Equatable, Sendable {
    public let requestID: MissionDecisionRequestID
    public let stageID: MissionStageID
    public let prompt: String
    public let allowsDelegation: Bool
    public let acceptedAt: AgentInstant

    public init(
        requestID: MissionDecisionRequestID = MissionDecisionRequestID(),
        stageID: MissionStageID,
        prompt: String,
        allowsDelegation: Bool,
        acceptedAt: AgentInstant
    ) {
        self.requestID = requestID
        self.stageID = stageID
        self.prompt = prompt
        self.allowsDelegation = allowsDelegation
        self.acceptedAt = acceptedAt
    }
}

public struct MissionStageEvidence: Codable, Equatable, Sendable {
    public let stageID: MissionStageID
    public let summary: String
    public let receiptIDs: MissionStringSet
    public let acceptedAt: AgentInstant
}

public struct MissionDecisionRecord: Codable, Equatable, Sendable {
    public let decisionID: MissionDecisionID
    public let stageID: MissionStageID
    public let acceptedAnswer: String
    public let decisionReceiptID: String
    public let acceptedAt: AgentInstant
}

public struct MissionRecoveryRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case externalBlockResolved
        case recoverableFailureRetried
    }

    public let kind: Kind
    public let stageID: MissionStageID
    public let resolutionReceiptID: String
    public let acceptedAt: AgentInstant
}

public struct MissionCheckpoint: Codable, Equatable, Sendable, Identifiable {
    public let id: MissionCheckpointID
    public let parentID: MissionCheckpointID?
    public let missionID: MissionID
    public let projectID: ProjectID
    public let missionRevision: UInt64
    public let authorityEpoch: UInt64
    public let constitutionRevision: UInt64
    public let graph: MissionStageGraph
    public let phase: MissionPhase
    public let routeReceiptID: String
    public let acceptedProjectStateID: String
    public let evidenceReceiptIDs: MissionStringSet
    public let projectBrainFactIDs: [ProjectBrainFactID]
    public let stageEvidence: [MissionStageEvidence]
    public let workerReceipts: [MissionAcceptedWorkerReceipt]
    public let decisions: [MissionDecisionRecord]
    public let recoveryRecords: [MissionRecoveryRecord]
    public let pendingDecision: MissionDecisionRequest?
    public let summary: String
    public let acceptedAt: AgentInstant

    public init(
        id: MissionCheckpointID = MissionCheckpointID(),
        parentID: MissionCheckpointID?,
        missionID: MissionID,
        projectID: ProjectID,
        missionRevision: UInt64,
        authorityEpoch: UInt64,
        constitutionRevision: UInt64,
        graph: MissionStageGraph,
        phase: MissionPhase,
        routeReceiptID: String,
        acceptedProjectStateID: String,
        evidenceReceiptIDs: MissionStringSet,
        projectBrainFactIDs: [ProjectBrainFactID],
        stageEvidence: [MissionStageEvidence],
        workerReceipts: [MissionAcceptedWorkerReceipt],
        decisions: [MissionDecisionRecord],
        recoveryRecords: [MissionRecoveryRecord],
        pendingDecision: MissionDecisionRequest?,
        summary: String,
        acceptedAt: AgentInstant
    ) {
        self.id = id
        self.parentID = parentID
        self.missionID = missionID
        self.projectID = projectID
        self.missionRevision = missionRevision
        self.authorityEpoch = authorityEpoch
        self.constitutionRevision = constitutionRevision
        self.graph = graph
        self.phase = phase
        self.routeReceiptID = routeReceiptID
        self.acceptedProjectStateID = acceptedProjectStateID
        self.evidenceReceiptIDs = evidenceReceiptIDs
        self.projectBrainFactIDs = projectBrainFactIDs.sorted { $0.description < $1.description }
        self.stageEvidence = stageEvidence
        self.workerReceipts = workerReceipts
        self.decisions = decisions
        self.recoveryRecords = recoveryRecords
        self.pendingDecision = pendingDecision
        self.summary = summary
        self.acceptedAt = acceptedAt
    }
}

public struct MissionRestoreRequest: Codable, Equatable, Sendable {
    public let checkpointID: MissionCheckpointID
    public let missionID: MissionID
    public let projectID: ProjectID
    public let acceptedProjectStateID: String

    public init(
        checkpointID: MissionCheckpointID,
        missionID: MissionID,
        projectID: ProjectID,
        acceptedProjectStateID: String
    ) {
        self.checkpointID = checkpointID
        self.missionID = missionID
        self.projectID = projectID
        self.acceptedProjectStateID = acceptedProjectStateID
    }
}

public struct MissionCompletionEvidence: Codable, Equatable, Sendable {
    public let acceptedProjectStateID: String
    public let evidenceClasses: MissionEvidenceSet
    public let receiptIDs: MissionStringSet
    public let knownLimitations: MissionStringSet
    public let acceptedAt: AgentInstant

    public init(
        acceptedProjectStateID: String,
        evidenceClasses: MissionEvidenceSet,
        receiptIDs: MissionStringSet,
        knownLimitations: MissionStringSet = MissionStringSet([]),
        acceptedAt: AgentInstant
    ) {
        self.acceptedProjectStateID = acceptedProjectStateID
        self.evidenceClasses = evidenceClasses
        self.receiptIDs = receiptIDs
        self.knownLimitations = knownLimitations
        self.acceptedAt = acceptedAt
    }
}

public enum ForgeMissionError: Error, Equatable, Sendable {
    case invalidConstitution
    case constitutionIdentityMismatch
    case constitutionRevisionNotAdvanced
    case invalidGraph
    case graphMissionMismatch
    case graphRevisionNotAdvanced
    case acceptedCompletedStageWouldBeLost(MissionStageID)
    case invalidRouteReceipt
    case invalidPhase(MissionPhase)
    case missionTerminal
    case stageNotFound(MissionStageID)
    case stageNotRunnable(MissionStageID)
    case stageNotActive(MissionStageID)
    case stageNotWaitingForDecision(MissionStageID)
    case stageNotBlocked(MissionStageID)
    case stageNotRecoverable(MissionStageID)
    case requiredStageCannotBeDeferred(MissionStageID)
    case stageNotDeferrable(MissionStageID)
    case duplicateStageRequest(MissionStageID)
    case noStagesRequested
    case activeWorkExists
    case staleWorkerResult
    case invalidWorkerSummary
    case missingEvidenceReceipt
    case invalidDecision
    case staleDecisionRequest
    case invalidResolutionReceipt
    case invalidCheckpoint
    case checkpointNotFound(MissionCheckpointID)
    case checkpointIdentityMismatch
    case checkpointRevisionRegression
    case restoreVerificationMismatch
    case continuationRequiresCompletedMission
    case completionRequiresSatisfiedRequiredWork
    case completionRequiresSettledStageGraph
    case completionRequiresCheckpoint
    case completionProjectStateMismatch
    case completionCheckpointAuthorityMismatch
    case completionMissingExpectedEvidence
    case completionMissingReceipt
    case revisionOverflow
    case authorityEpochOverflow
}

public struct ForgeMissionState: Codable, Equatable, Sendable {
    public let missionID: MissionID
    public let projectID: ProjectID
    public private(set) var constitution: MissionConstitution
    public private(set) var phase: MissionPhase
    public private(set) var graph: MissionStageGraph
    public private(set) var route: MissionRouteBinding
    public private(set) var activeLeases: [MissionWorkLease]
    public private(set) var stageEvidence: [MissionStageEvidence]
    public private(set) var workerReceipts: [MissionAcceptedWorkerReceipt]
    public private(set) var decisions: [MissionDecisionRecord]
    public private(set) var recoveryRecords: [MissionRecoveryRecord]
    public private(set) var pendingDecision: MissionDecisionRequest?
    public private(set) var checkpoints: [MissionCheckpoint]
    public private(set) var completionEvidence: MissionCompletionEvidence?
    public private(set) var revision: UInt64
    public private(set) var authorityEpoch: UInt64

    public var latestCheckpointID: MissionCheckpointID? { checkpoints.last?.id }

    public init(
        constitution: MissionConstitution,
        graph: MissionStageGraph,
        route: MissionRouteBinding
    ) throws {
        guard constitution.validationError == nil else { throw ForgeMissionError.invalidConstitution }
        guard graph.validationError == nil else { throw ForgeMissionError.invalidGraph }
        guard graph.missionID == constitution.missionID else { throw ForgeMissionError.graphMissionMismatch }
        guard route.isValid else { throw ForgeMissionError.invalidRouteReceipt }
        guard !graph.stages.contains(where: { $0.status == .active }) else { throw ForgeMissionError.invalidGraph }

        missionID = constitution.missionID
        projectID = constitution.projectID
        self.constitution = constitution
        phase = .ready
        self.graph = graph
        self.route = route
        activeLeases = []
        stageEvidence = []
        workerReceipts = []
        decisions = []
        recoveryRecords = []
        pendingDecision = nil
        checkpoints = []
        completionEvidence = nil
        revision = 1
        authorityEpoch = 1
    }

    public var runnableStageIDs: [MissionStageID] {
        let satisfied = Set(graph.stages.lazy.filter { [.completed, .deferred].contains($0.status) }.map(\.stageID))
        return graph.stages
            .filter { stage in
                stage.status == .pending && stage.dependencies.allSatisfy(satisfied.contains)
            }
            .sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.stageID.description < rhs.stageID.description
            }
            .map(\.stageID)
    }

    @discardableResult
    public mutating func beginWork(on requestedStageIDs: [MissionStageID]) throws -> [MissionWorkLease] {
        try requireNonTerminal()
        guard [.ready, .executing, .validating, .polishing].contains(phase) else { throw ForgeMissionError.invalidPhase(phase) }
        guard !requestedStageIDs.isEmpty else { throw ForgeMissionError.noStagesRequested }

        var requested = Set<MissionStageID>()
        for id in requestedStageIDs where !requested.insert(id).inserted {
            throw ForgeMissionError.duplicateStageRequest(id)
        }
        let runnable = Set(runnableStageIDs)
        for id in requestedStageIDs where !runnable.contains(id) {
            guard graph.stages.contains(where: { $0.stageID == id }) else { throw ForgeMissionError.stageNotFound(id) }
            throw ForgeMissionError.stageNotRunnable(id)
        }

        var stages = graph.stages
        for index in stages.indices where requested.contains(stages[index].stageID) {
            stages[index] = stages[index].withStatus(.active)
        }
        graph = graph.withStagesPreservingRevision(stages)
        phase = .executing
        try bumpRevision()

        let leases = requestedStageIDs.map { stageID in
            MissionWorkLease(
                missionID: missionID,
                projectID: projectID,
                stageID: stageID,
                authorityEpoch: authorityEpoch,
                graphRevision: graph.revision,
                checkpointID: latestCheckpointID,
                routeReceiptID: route.routeReceiptID
            )
        }
        activeLeases.append(contentsOf: leases)
        activeLeases.sort { $0.stageID.description < $1.stageID.description }
        return leases
    }

    public mutating func acceptWorkerResult(_ result: MissionWorkerResult, at now: AgentInstant) throws {
        try requireNonTerminal()
        guard !result.summary.trimmed.isEmpty else { throw ForgeMissionError.invalidWorkerSummary }
        guard let leaseIndex = activeLeases.firstIndex(where: { $0 == result.lease }) else {
            throw ForgeMissionError.staleWorkerResult
        }
        guard result.lease.missionID == missionID,
              result.lease.projectID == projectID,
              result.lease.authorityEpoch == authorityEpoch,
              result.lease.graphRevision == graph.revision,
              result.lease.checkpointID == latestCheckpointID,
              result.lease.routeReceiptID == route.routeReceiptID else {
            throw ForgeMissionError.staleWorkerResult
        }
        guard let stageIndex = graph.stages.firstIndex(where: { $0.stageID == result.lease.stageID }) else {
            throw ForgeMissionError.stageNotFound(result.lease.stageID)
        }
        guard graph.stages[stageIndex].status == .active else { throw ForgeMissionError.stageNotActive(result.lease.stageID) }
        guard result.evidenceReceiptIDs.values.allSatisfy({ !$0.trimmed.isEmpty }) else {
            throw ForgeMissionError.missingEvidenceReceipt
        }

        var stages = graph.stages
        switch result.outcome {
        case .completed:
            guard !result.evidenceReceiptIDs.values.isEmpty else { throw ForgeMissionError.missingEvidenceReceipt }
            recordAcceptedWorkerReceipt(result, kind: .completed, at: now)
            pendingDecision = nil
            stages[stageIndex] = stages[stageIndex].withStatus(.completed)
            stageEvidence.append(MissionStageEvidence(
                stageID: result.lease.stageID,
                summary: result.summary,
                receiptIDs: result.evidenceReceiptIDs,
                acceptedAt: now
            ))
            activeLeases.remove(at: leaseIndex)
            graph = graph.withStagesPreservingRevision(stages)
            try bumpRevision()
            if activeLeases.isEmpty {
                phase = graph.requiredWorkIsSatisfied ? .validating : .ready
            }

        case .needsDecision:
            recordAcceptedWorkerReceipt(result, kind: .needsDecision, at: now)
            pendingDecision = MissionDecisionRequest(
                stageID: result.lease.stageID,
                prompt: result.summary.trimmed,
                allowsDelegation: result.allowsDecisionDelegation,
                acceptedAt: now
            )
            stages[stageIndex] = stages[stageIndex].withStatus(.waitingForDecision)
            try revokeAllWork(replacing: stages, phase: .needsDecision)

        case .blockedExternal:
            recordAcceptedWorkerReceipt(result, kind: .blockedExternal, at: now)
            pendingDecision = nil
            stages[stageIndex] = stages[stageIndex].withStatus(.blocked)
            try revokeAllWork(replacing: stages, phase: .blockedExternal)

        case .failedRecoverably:
            recordAcceptedWorkerReceipt(result, kind: .failedRecoverably, at: now)
            pendingDecision = nil
            stages[stageIndex] = stages[stageIndex].withStatus(.failedRecoverably)
            try revokeAllWork(replacing: stages, phase: .interruptedRecoverable)

        case .failedIrrecoverably:
            recordAcceptedWorkerReceipt(result, kind: .failedIrrecoverably, at: now)
            pendingDecision = nil
            stages[stageIndex] = stages[stageIndex].withStatus(.failedIrrecoverably)
            try revokeAllWork(replacing: stages, phase: .failedIrrecoverably)
        }
    }

    public mutating func pauseByUser() throws {
        try pause(as: .pausedByUser)
    }

    public mutating func pauseByPolicy() throws {
        try pause(as: .pausedByPolicy)
    }

    public mutating func resume() throws {
        try requireNonTerminal()
        guard [.pausedByUser, .pausedByPolicy].contains(phase) else { throw ForgeMissionError.invalidPhase(phase) }
        phase = .ready
        try bumpRevision()
    }

    public mutating func acceptDecision(
        stageID: MissionStageID,
        decisionRequestID: MissionDecisionRequestID,
        acceptedAnswer: String,
        decisionReceiptID: String,
        at now: AgentInstant
    ) throws {
        try requireNonTerminal()
        guard phase == .needsDecision else { throw ForgeMissionError.invalidPhase(phase) }
        let normalizedAnswer = acceptedAnswer.trimmed
        guard !normalizedAnswer.isEmpty,
              !normalizedAnswer.isUnresolvedDecisionDelegation,
              !decisionReceiptID.trimmed.isEmpty else { throw ForgeMissionError.invalidDecision }
        guard let request = pendingDecision,
              request.requestID == decisionRequestID,
              request.stageID == stageID else { throw ForgeMissionError.staleDecisionRequest }
        guard let index = graph.stages.firstIndex(where: { $0.stageID == stageID }) else { throw ForgeMissionError.stageNotFound(stageID) }
        guard graph.stages[index].status == .waitingForDecision else { throw ForgeMissionError.stageNotWaitingForDecision(stageID) }

        var stages = graph.stages
        stages[index] = stages[index].withStatus(.pending)
        graph = graph.withStagesPreservingRevision(stages)
        decisions.append(MissionDecisionRecord(
            decisionID: MissionDecisionID(),
            stageID: stageID,
            acceptedAnswer: normalizedAnswer,
            decisionReceiptID: decisionReceiptID.trimmed,
            acceptedAt: now
        ))
        pendingDecision = nil
        phase = .ready
        try bumpRevision()
    }

    public mutating func resolveExternalBlock(
        stageID: MissionStageID,
        resolutionReceiptID: String,
        at now: AgentInstant
    ) throws {
        try requireNonTerminal()
        guard phase == .blockedExternal else { throw ForgeMissionError.invalidPhase(phase) }
        guard !resolutionReceiptID.trimmed.isEmpty else { throw ForgeMissionError.invalidResolutionReceipt }
        guard let index = graph.stages.firstIndex(where: { $0.stageID == stageID }) else { throw ForgeMissionError.stageNotFound(stageID) }
        guard graph.stages[index].status == .blocked else { throw ForgeMissionError.stageNotBlocked(stageID) }
        var stages = graph.stages
        stages[index] = stages[index].withStatus(.pending)
        graph = graph.withStagesPreservingRevision(stages)
        recoveryRecords.append(MissionRecoveryRecord(kind: .externalBlockResolved, stageID: stageID, resolutionReceiptID: resolutionReceiptID.trimmed, acceptedAt: now))
        phase = .ready
        try bumpRevision()
    }

    public mutating func retryRecoverableStage(
        stageID: MissionStageID,
        resolutionReceiptID: String,
        at now: AgentInstant
    ) throws {
        try requireNonTerminal()
        guard phase == .interruptedRecoverable else { throw ForgeMissionError.invalidPhase(phase) }
        guard !resolutionReceiptID.trimmed.isEmpty else { throw ForgeMissionError.invalidResolutionReceipt }
        guard let index = graph.stages.firstIndex(where: { $0.stageID == stageID }) else { throw ForgeMissionError.stageNotFound(stageID) }
        guard graph.stages[index].status == .failedRecoverably else { throw ForgeMissionError.stageNotRecoverable(stageID) }
        var stages = graph.stages
        stages[index] = stages[index].withStatus(.pending)
        graph = graph.withStagesPreservingRevision(stages)
        recoveryRecords.append(MissionRecoveryRecord(kind: .recoverableFailureRetried, stageID: stageID, resolutionReceiptID: resolutionReceiptID.trimmed, acceptedAt: now))
        phase = .ready
        try bumpRevision()
    }

    public mutating func deferOptionalStage(_ stageID: MissionStageID) throws {
        try requireNonTerminal()
        guard activeLeases.isEmpty else { throw ForgeMissionError.activeWorkExists }
        guard let index = graph.stages.firstIndex(where: { $0.stageID == stageID }) else { throw ForgeMissionError.stageNotFound(stageID) }
        guard !graph.stages[index].required else { throw ForgeMissionError.requiredStageCannotBeDeferred(stageID) }
        guard graph.stages[index].status == .pending else { throw ForgeMissionError.stageNotDeferrable(stageID) }
        var stages = graph.stages
        stages[index] = stages[index].withStatus(.deferred)
        graph = graph.withStagesPreservingRevision(stages)
        try bumpRevision()
    }

    public mutating func switchRoute(to newRoute: MissionRouteBinding) throws {
        try requireNonTerminal()
        guard newRoute.isValid else { throw ForgeMissionError.invalidRouteReceipt }
        guard newRoute != route else { return }
        let hadActiveWork = !activeLeases.isEmpty
        if hadActiveWork {
            graph = graph.withStagesPreservingRevision(graph.stages.map { $0.status == .active ? $0.withStatus(.pending) : $0 })
            activeLeases.removeAll()
            try bumpAuthorityEpoch()
            if phase == .executing { phase = .ready }
        }
        route = newRoute
        if !hadActiveWork { try bumpAuthorityEpoch() }
        try bumpRevision()
    }

    public mutating func acceptConstitutionRevision(_ newValue: MissionConstitution) throws {
        try requireNonTerminal()
        guard activeLeases.isEmpty else { throw ForgeMissionError.activeWorkExists }
        guard newValue.validationError == nil else { throw ForgeMissionError.invalidConstitution }
        guard newValue.missionID == missionID, newValue.projectID == projectID else { throw ForgeMissionError.constitutionIdentityMismatch }
        guard newValue.revision > constitution.revision else { throw ForgeMissionError.constitutionRevisionNotAdvanced }
        constitution = newValue
        try bumpAuthorityEpoch()
        try bumpRevision()
    }

    public mutating func replaceStageGraph(_ newGraph: MissionStageGraph) throws {
        try requireNonTerminal()
        guard activeLeases.isEmpty else { throw ForgeMissionError.activeWorkExists }
        guard newGraph.missionID == missionID else { throw ForgeMissionError.graphMissionMismatch }
        guard newGraph.validationError == nil else { throw ForgeMissionError.invalidGraph }
        guard newGraph.revision > graph.revision else { throw ForgeMissionError.graphRevisionNotAdvanced }

        let newByID = Dictionary(uniqueKeysWithValues: newGraph.stages.map { ($0.stageID, $0) })
        for accepted in graph.stages where accepted.status == .completed {
            guard newByID[accepted.stageID]?.status == .completed else {
                throw ForgeMissionError.acceptedCompletedStageWouldBeLost(accepted.stageID)
            }
        }
        for gated in graph.stages where [.waitingForDecision, .blocked, .failedRecoverably].contains(gated.status) {
            guard newByID[gated.stageID]?.status == gated.status else {
                throw ForgeMissionError.invalidGraph
            }
        }
        if let pendingDecision {
            guard newGraph.stages.contains(where: {
                $0.stageID == pendingDecision.stageID && $0.status == .waitingForDecision
            }) else { throw ForgeMissionError.invalidDecision }
        }
        graph = newGraph
        if [.validating, .polishing].contains(phase), !graph.requiredWorkIsSatisfied { phase = .ready }
        try bumpAuthorityEpoch()
        try bumpRevision()
    }

    @discardableResult
    public mutating func checkpoint(
        acceptedProjectStateID: String,
        evidenceReceiptIDs: MissionStringSet,
        projectBrainFactIDs: [ProjectBrainFactID] = [],
        summary: String,
        at now: AgentInstant
    ) throws -> MissionCheckpoint {
        try requireNonTerminal()
        guard activeLeases.isEmpty else { throw ForgeMissionError.activeWorkExists }
        guard !acceptedProjectStateID.trimmed.isEmpty,
              !summary.trimmed.isEmpty,
              !evidenceReceiptIDs.values.isEmpty,
              evidenceReceiptIDs.values.allSatisfy({ !$0.trimmed.isEmpty }) else {
            throw ForgeMissionError.invalidCheckpoint
        }
        try bumpAuthorityEpoch()
        try bumpRevision()
        let value = MissionCheckpoint(
            parentID: latestCheckpointID,
            missionID: missionID,
            projectID: projectID,
            missionRevision: revision,
            authorityEpoch: authorityEpoch,
            constitutionRevision: constitution.revision,
            graph: graph,
            phase: phase,
            routeReceiptID: route.routeReceiptID,
            acceptedProjectStateID: acceptedProjectStateID.trimmed,
            evidenceReceiptIDs: evidenceReceiptIDs,
            projectBrainFactIDs: projectBrainFactIDs,
            stageEvidence: stageEvidence,
            workerReceipts: workerReceipts,
            decisions: decisions,
            recoveryRecords: recoveryRecords,
            pendingDecision: pendingDecision,
            summary: summary.trimmed,
            acceptedAt: now
        )
        checkpoints.append(value)
        return value
    }

    public func prepareRestore(to checkpointID: MissionCheckpointID) throws -> MissionRestoreRequest {
        guard activeLeases.isEmpty else { throw ForgeMissionError.activeWorkExists }
        guard phase != .cancelled, phase != .failedIrrecoverably else { throw ForgeMissionError.missionTerminal }
        guard let source = checkpoints.first(where: { $0.id == checkpointID }) else {
            throw ForgeMissionError.checkpointNotFound(checkpointID)
        }
        guard source.missionID == missionID, source.projectID == projectID else {
            throw ForgeMissionError.checkpointIdentityMismatch
        }
        return MissionRestoreRequest(
            checkpointID: source.id,
            missionID: missionID,
            projectID: projectID,
            acceptedProjectStateID: source.acceptedProjectStateID
        )
    }

    @discardableResult
    public mutating func acceptVerifiedRestore(
        _ request: MissionRestoreRequest,
        verifiedProjectStateID: String,
        restoreReceiptID: String,
        at now: AgentInstant
    ) throws -> MissionCheckpoint {
        guard activeLeases.isEmpty else { throw ForgeMissionError.activeWorkExists }
        guard phase != .cancelled, phase != .failedIrrecoverably else { throw ForgeMissionError.missionTerminal }
        guard request.missionID == missionID, request.projectID == projectID else {
            throw ForgeMissionError.checkpointIdentityMismatch
        }
        guard !restoreReceiptID.trimmed.isEmpty else { throw ForgeMissionError.invalidResolutionReceipt }
        guard let source = checkpoints.first(where: { $0.id == request.checkpointID }) else {
            throw ForgeMissionError.checkpointNotFound(request.checkpointID)
        }
        guard source.missionID == missionID, source.projectID == projectID else {
            throw ForgeMissionError.checkpointIdentityMismatch
        }
        let verified = verifiedProjectStateID.trimmed
        guard !verified.isEmpty,
              request.acceptedProjectStateID == source.acceptedProjectStateID,
              verified == source.acceptedProjectStateID else {
            throw ForgeMissionError.restoreVerificationMismatch
        }

        graph = source.graph
        route = MissionRouteBinding(routeReceiptID: source.routeReceiptID)
        stageEvidence = source.stageEvidence
        workerReceipts = source.workerReceipts
        decisions = source.decisions
        recoveryRecords = source.recoveryRecords
        pendingDecision = source.pendingDecision
        switch source.phase {
        case .needsDecision, .blockedExternal, .interruptedRecoverable:
            phase = source.phase
        default:
            phase = .pausedByUser
            pendingDecision = nil
        }
        completionEvidence = nil
        try bumpAuthorityEpoch()
        try bumpRevision()
        let restored = MissionCheckpoint(
            parentID: source.id,
            missionID: missionID,
            projectID: projectID,
            missionRevision: revision,
            authorityEpoch: authorityEpoch,
            constitutionRevision: constitution.revision,
            graph: graph,
            phase: phase,
            routeReceiptID: route.routeReceiptID,
            acceptedProjectStateID: source.acceptedProjectStateID,
            evidenceReceiptIDs: MissionStringSet(source.evidenceReceiptIDs.values + [restoreReceiptID.trimmed]),
            projectBrainFactIDs: source.projectBrainFactIDs,
            stageEvidence: stageEvidence,
            workerReceipts: workerReceipts,
            decisions: decisions,
            recoveryRecords: recoveryRecords,
            pendingDecision: pendingDecision,
            summary: "Verified restore: \(source.summary)",
            acceptedAt: now
        )
        checkpoints.append(restored)
        return restored
    }

    public mutating func beginContinuation(with newStages: [MissionStage]) throws {
        guard [.completedWithEvidence, .completedWithKnownLimitations].contains(phase) else {
            throw ForgeMissionError.continuationRequiresCompletedMission
        }
        guard activeLeases.isEmpty else { throw ForgeMissionError.activeWorkExists }
        guard !newStages.isEmpty else { throw ForgeMissionError.noStagesRequested }
        guard graph.revision < UInt64.max else { throw ForgeMissionError.revisionOverflow }

        let normalized = newStages.map { stage in
            MissionStage(
                stageID: stage.stageID,
                kind: stage.kind,
                title: stage.title,
                order: stage.order,
                required: stage.required,
                dependencies: stage.dependencies,
                status: .pending
            )
        }
        let candidate = MissionStageGraph(
            missionID: missionID,
            revision: graph.revision + 1,
            stages: graph.stages + normalized
        )
        guard candidate.validationError == nil else { throw ForgeMissionError.invalidGraph }
        graph = candidate
        completionEvidence = nil
        phase = .ready
        try bumpAuthorityEpoch()
        try bumpRevision()
    }

    public mutating func complete(with evidence: MissionCompletionEvidence) throws {
        try requireNonTerminal()
        guard activeLeases.isEmpty else { throw ForgeMissionError.activeWorkExists }
        guard graph.requiredWorkIsSatisfied else { throw ForgeMissionError.completionRequiresSatisfiedRequiredWork }
        guard pendingDecision == nil,
              graph.stages.allSatisfy({ [.completed, .deferred].contains($0.status) }) else {
            throw ForgeMissionError.completionRequiresSettledStageGraph
        }
        guard let checkpoint = checkpoints.last else { throw ForgeMissionError.completionRequiresCheckpoint }
        guard checkpoint.acceptedProjectStateID == evidence.acceptedProjectStateID.trimmed else { throw ForgeMissionError.completionProjectStateMismatch }
        guard checkpoint.missionRevision == revision,
              checkpoint.authorityEpoch == authorityEpoch,
              checkpoint.constitutionRevision == constitution.revision,
              checkpoint.graph == graph,
              checkpoint.routeReceiptID == route.routeReceiptID else {
            throw ForgeMissionError.completionCheckpointAuthorityMismatch
        }
        guard !evidence.receiptIDs.values.isEmpty,
              evidence.receiptIDs.values.allSatisfy({ !$0.trimmed.isEmpty }) else { throw ForgeMissionError.completionMissingReceipt }
        guard constitution.expectedEvidence.values.allSatisfy(evidence.evidenceClasses.contains) else {
            throw ForgeMissionError.completionMissingExpectedEvidence
        }
        completionEvidence = evidence
        phase = evidence.knownLimitations.values.isEmpty ? .completedWithEvidence : .completedWithKnownLimitations
        try bumpAuthorityEpoch()
        try bumpRevision()
    }

    public mutating func cancel() throws {
        try requireNonTerminal()
        let stages = graph.stages.map { stage -> MissionStage in
            stage.status == .active ? stage.withStatus(.cancelled) : stage
        }
        graph = graph.withStagesPreservingRevision(stages)
        activeLeases.removeAll()
        pendingDecision = nil
        phase = .cancelled
        try bumpAuthorityEpoch()
        try bumpRevision()
    }

    private mutating func pause(as pausedPhase: MissionPhase) throws {
        try requireNonTerminal()
        guard phase == .executing else { throw ForgeMissionError.invalidPhase(phase) }
        graph = graph.withStagesPreservingRevision(graph.stages.map { $0.status == .active ? $0.withStatus(.pending) : $0 })
        activeLeases.removeAll()
        phase = pausedPhase
        try bumpAuthorityEpoch()
        try bumpRevision()
    }

    private mutating func revokeAllWork(replacing proposedStages: [MissionStage], phase nextPhase: MissionPhase) throws {
        let failedOrWaiting = Set(proposedStages.filter { [.waitingForDecision, .blocked, .failedRecoverably, .failedIrrecoverably].contains($0.status) }.map(\.stageID))
        graph = graph.withStagesPreservingRevision(proposedStages.map { stage in
            if stage.status == .active && !failedOrWaiting.contains(stage.stageID) { return stage.withStatus(.pending) }
            return stage
        })
        activeLeases.removeAll()
        phase = nextPhase
        try bumpAuthorityEpoch()
        try bumpRevision()
    }

    private mutating func recordAcceptedWorkerReceipt(
        _ result: MissionWorkerResult,
        kind: MissionAcceptedWorkerReceiptKind,
        at now: AgentInstant
    ) {
        workerReceipts.append(MissionAcceptedWorkerReceipt(
            leaseID: result.lease.leaseID,
            missionID: missionID,
            projectID: projectID,
            stageID: result.lease.stageID,
            kind: kind,
            summary: result.summary.trimmed,
            evidenceReceiptIDs: result.evidenceReceiptIDs,
            acceptedAt: now
        ))
    }

    private func requireNonTerminal() throws {
        guard !phase.isTerminal else { throw ForgeMissionError.missionTerminal }
    }

    private mutating func bumpRevision() throws {
        guard revision < UInt64.max else { throw ForgeMissionError.revisionOverflow }
        revision += 1
    }

    private mutating func bumpAuthorityEpoch() throws {
        guard authorityEpoch < UInt64.max else { throw ForgeMissionError.authorityEpochOverflow }
        authorityEpoch += 1
    }
}

private extension MissionStage {
    func withStatus(_ status: MissionStageStatus) -> MissionStage {
        MissionStage(
            stageID: stageID,
            kind: kind,
            title: title,
            order: order,
            required: required,
            dependencies: dependencies,
            status: status
        )
    }
}

private extension MissionStageGraph {
    func withStagesPreservingRevision(_ stages: [MissionStage]) -> MissionStageGraph {
        MissionStageGraph(missionID: missionID, revision: revision, stages: stages)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var isUnresolvedDecisionDelegation: Bool {
        let token = trimmed
            .uppercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        return token == "DECIDE_FOR_ME"
    }
}

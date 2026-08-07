from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


source_path = Path("Packages/AgentHarnessKit/Sources/ForgeMission/ForgeMission.swift")
archive_path = Path("Packages/AgentHarnessKit/Sources/ForgeMission/ForgeMissionArchive.swift")
tests_path = Path("Packages/AgentHarnessKit/Tests/ForgeMissionTests/ForgeMissionTests.swift")

s = source_path.read_text()
s = replace_once(s, '''public enum MissionDecisionIDTag: AgentIdentifierTag {}

public typealias MissionCheckpointID = AgentIdentifier<MissionCheckpointIDTag>
public typealias MissionWorkLeaseID = AgentIdentifier<MissionWorkLeaseIDTag>
public typealias MissionDecisionID = AgentIdentifier<MissionDecisionIDTag>
''', '''public enum MissionDecisionIDTag: AgentIdentifierTag {}
public enum MissionDecisionRequestIDTag: AgentIdentifierTag {}

public typealias MissionCheckpointID = AgentIdentifier<MissionCheckpointIDTag>
public typealias MissionWorkLeaseID = AgentIdentifier<MissionWorkLeaseIDTag>
public typealias MissionDecisionID = AgentIdentifier<MissionDecisionIDTag>
public typealias MissionDecisionRequestID = AgentIdentifier<MissionDecisionRequestIDTag>
''', 'decision request identity')

s = replace_once(s, '''    public let summary: String
    public let evidenceReceiptIDs: MissionStringSet

    public init(
        lease: MissionWorkLease,
        outcome: MissionWorkerOutcome,
        summary: String,
        evidenceReceiptIDs: MissionStringSet = MissionStringSet([])
    ) {
        self.lease = lease
        self.outcome = outcome
        self.summary = summary
        self.evidenceReceiptIDs = evidenceReceiptIDs
    }
}

public struct MissionStageEvidence''', '''    public let summary: String
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

public struct MissionStageEvidence''', 'durable worker and decision records')

s = replace_once(s, '''    public let evidenceReceiptIDs: MissionStringSet
    public let projectBrainFactIDs: [ProjectBrainFactID]
    public let summary: String
''', '''    public let evidenceReceiptIDs: MissionStringSet
    public let projectBrainFactIDs: [ProjectBrainFactID]
    public let stageEvidence: [MissionStageEvidence]
    public let workerReceipts: [MissionAcceptedWorkerReceipt]
    public let decisions: [MissionDecisionRecord]
    public let recoveryRecords: [MissionRecoveryRecord]
    public let pendingDecision: MissionDecisionRequest?
    public let summary: String
''', 'checkpoint durable fields')
s = replace_once(s, '''        evidenceReceiptIDs: MissionStringSet,
        projectBrainFactIDs: [ProjectBrainFactID],
        summary: String,
''', '''        evidenceReceiptIDs: MissionStringSet,
        projectBrainFactIDs: [ProjectBrainFactID],
        stageEvidence: [MissionStageEvidence],
        workerReceipts: [MissionAcceptedWorkerReceipt],
        decisions: [MissionDecisionRecord],
        recoveryRecords: [MissionRecoveryRecord],
        pendingDecision: MissionDecisionRequest?,
        summary: String,
''', 'checkpoint initializer parameters')
s = replace_once(s, '''        self.evidenceReceiptIDs = evidenceReceiptIDs
        self.projectBrainFactIDs = projectBrainFactIDs.sorted { $0.description < $1.description }
        self.summary = summary
''', '''        self.evidenceReceiptIDs = evidenceReceiptIDs
        self.projectBrainFactIDs = projectBrainFactIDs.sorted { $0.description < $1.description }
        self.stageEvidence = stageEvidence
        self.workerReceipts = workerReceipts
        self.decisions = decisions
        self.recoveryRecords = recoveryRecords
        self.pendingDecision = pendingDecision
        self.summary = summary
''', 'checkpoint initializer assignments')

s = replace_once(s, '''    case invalidDecision
    case invalidResolutionReceipt
''', '''    case invalidDecision
    case staleDecisionRequest
    case invalidResolutionReceipt
''', 'stale decision error')

s = replace_once(s, '''    public private(set) var activeLeases: [MissionWorkLease]
    public private(set) var stageEvidence: [MissionStageEvidence]
    public private(set) var decisions: [MissionDecisionRecord]
    public private(set) var recoveryRecords: [MissionRecoveryRecord]
''', '''    public private(set) var activeLeases: [MissionWorkLease]
    public private(set) var stageEvidence: [MissionStageEvidence]
    public private(set) var workerReceipts: [MissionAcceptedWorkerReceipt]
    public private(set) var decisions: [MissionDecisionRecord]
    public private(set) var recoveryRecords: [MissionRecoveryRecord]
    public private(set) var pendingDecision: MissionDecisionRequest?
''', 'state durable fields')
s = replace_once(s, '''        activeLeases = []
        stageEvidence = []
        decisions = []
        recoveryRecords = []
        checkpoints = []
''', '''        activeLeases = []
        stageEvidence = []
        workerReceipts = []
        decisions = []
        recoveryRecords = []
        pendingDecision = nil
        checkpoints = []
''', 'state durable initialization')

s = replace_once(s, '''        guard graph.stages[stageIndex].status == .active else { throw ForgeMissionError.stageNotActive(result.lease.stageID) }

        var stages = graph.stages
''', '''        guard graph.stages[stageIndex].status == .active else { throw ForgeMissionError.stageNotActive(result.lease.stageID) }
        guard result.evidenceReceiptIDs.values.allSatisfy({ !$0.trimmed.isEmpty }) else {
            throw ForgeMissionError.missingEvidenceReceipt
        }

        var stages = graph.stages
''', 'worker evidence validation')
s = replace_once(s, '''        case .completed:
            guard !result.evidenceReceiptIDs.values.isEmpty else { throw ForgeMissionError.missingEvidenceReceipt }
            stages[stageIndex] = stages[stageIndex].withStatus(.completed)
''', '''        case .completed:
            guard !result.evidenceReceiptIDs.values.isEmpty else { throw ForgeMissionError.missingEvidenceReceipt }
            recordAcceptedWorkerReceipt(result, kind: .completed, at: now)
            pendingDecision = nil
            stages[stageIndex] = stages[stageIndex].withStatus(.completed)
''', 'completed worker receipt')
s = replace_once(s, '''        case .needsDecision:
            stages[stageIndex] = stages[stageIndex].withStatus(.waitingForDecision)
            try revokeAllWork(replacing: stages, phase: .needsDecision)

        case .blockedExternal:
            stages[stageIndex] = stages[stageIndex].withStatus(.blocked)
            try revokeAllWork(replacing: stages, phase: .blockedExternal)

        case .failedRecoverably:
            stages[stageIndex] = stages[stageIndex].withStatus(.failedRecoverably)
            try revokeAllWork(replacing: stages, phase: .interruptedRecoverable)

        case .failedIrrecoverably:
            stages[stageIndex] = stages[stageIndex].withStatus(.failedIrrecoverably)
            try revokeAllWork(replacing: stages, phase: .failedIrrecoverably)
''', '''        case .needsDecision:
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
''', 'non-completed durable transitions')

old_accept = '''    public mutating func acceptDecision(
        stageID: MissionStageID,
        acceptedAnswer: String,
        decisionReceiptID: String,
        at now: AgentInstant
    ) throws {
        try requireNonTerminal()
        guard phase == .needsDecision else { throw ForgeMissionError.invalidPhase(phase) }
        guard !acceptedAnswer.trimmed.isEmpty, !decisionReceiptID.trimmed.isEmpty else { throw ForgeMissionError.invalidDecision }
        guard let index = graph.stages.firstIndex(where: { $0.stageID == stageID }) else { throw ForgeMissionError.stageNotFound(stageID) }
        guard graph.stages[index].status == .waitingForDecision else { throw ForgeMissionError.stageNotWaitingForDecision(stageID) }

        var stages = graph.stages
        stages[index] = stages[index].withStatus(.pending)
        graph = graph.withStagesPreservingRevision(stages)
        decisions.append(MissionDecisionRecord(
            decisionID: MissionDecisionID(),
            stageID: stageID,
            acceptedAnswer: acceptedAnswer.trimmed,
            decisionReceiptID: decisionReceiptID.trimmed,
            acceptedAt: now
        ))
        phase = .ready
        try bumpRevision()
    }
'''
new_accept = '''    public mutating func acceptDecision(
        stageID: MissionStageID,
        decisionRequestID: MissionDecisionRequestID,
        acceptedAnswer: String,
        decisionReceiptID: String,
        at now: AgentInstant
    ) throws {
        try requireNonTerminal()
        guard phase == .needsDecision else { throw ForgeMissionError.invalidPhase(phase) }
        guard !acceptedAnswer.trimmed.isEmpty, !decisionReceiptID.trimmed.isEmpty else { throw ForgeMissionError.invalidDecision }
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
            acceptedAnswer: acceptedAnswer.trimmed,
            decisionReceiptID: decisionReceiptID.trimmed,
            acceptedAt: now
        ))
        pendingDecision = nil
        phase = .ready
        try bumpRevision()
    }
'''
s = replace_once(s, old_accept, new_accept, 'decision acceptance binding')

s = replace_once(s, '''        graph = newGraph
        if [.validating, .polishing].contains(phase), !graph.requiredWorkIsSatisfied { phase = .ready }
''', '''        if let pendingDecision {
            guard newGraph.stages.contains(where: {
                $0.stageID == pendingDecision.stageID && $0.status == .waitingForDecision
            }) else { throw ForgeMissionError.invalidDecision }
        }
        graph = newGraph
        if [.validating, .polishing].contains(phase), !graph.requiredWorkIsSatisfied { phase = .ready }
''', 'graph replacement decision gate')

s = replace_once(s, '''            evidenceReceiptIDs: evidenceReceiptIDs,
            projectBrainFactIDs: projectBrainFactIDs,
            summary: summary.trimmed,
''', '''            evidenceReceiptIDs: evidenceReceiptIDs,
            projectBrainFactIDs: projectBrainFactIDs,
            stageEvidence: stageEvidence,
            workerReceipts: workerReceipts,
            decisions: decisions,
            recoveryRecords: recoveryRecords,
            pendingDecision: pendingDecision,
            summary: summary.trimmed,
''', 'checkpoint snapshots')

s = replace_once(s, '''        graph = source.graph
        route = MissionRouteBinding(routeReceiptID: source.routeReceiptID)
        phase = .pausedByUser
        completionEvidence = nil
''', '''        graph = source.graph
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
''', 'restore current authority snapshots')

s = replace_once(s, '''            evidenceReceiptIDs: MissionStringSet(source.evidenceReceiptIDs.values + [restoreReceiptID.trimmed]),
            projectBrainFactIDs: source.projectBrainFactIDs,
            summary: "Verified restore: \\(source.summary)",
''', '''            evidenceReceiptIDs: MissionStringSet(source.evidenceReceiptIDs.values + [restoreReceiptID.trimmed]),
            projectBrainFactIDs: source.projectBrainFactIDs,
            stageEvidence: stageEvidence,
            workerReceipts: workerReceipts,
            decisions: decisions,
            recoveryRecords: recoveryRecords,
            pendingDecision: pendingDecision,
            summary: "Verified restore: \\(source.summary)",
''', 'restore checkpoint snapshots')

s = replace_once(s, '''        graph = graph.withStagesPreservingRevision(stages)
        activeLeases.removeAll()
        phase = .cancelled
''', '''        graph = graph.withStagesPreservingRevision(stages)
        activeLeases.removeAll()
        pendingDecision = nil
        phase = .cancelled
''', 'cancel clears decision')

s = replace_once(s, '''    private func requireNonTerminal() throws {
''', '''    private mutating func recordAcceptedWorkerReceipt(
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
''', 'worker receipt helper')
source_path.write_text(s)

a = archive_path.read_text()
a = replace_once(a, '''        guard state.graph.missionID == state.missionID, state.graph.validationError == nil else { throw ForgeMissionArchiveError.invalidGraph }
        guard state.route.isValid else { throw ForgeMissionArchiveError.invalidRoute }

        let activeStageIDs''', '''        guard state.graph.missionID == state.missionID, state.graph.validationError == nil else { throw ForgeMissionArchiveError.invalidGraph }
        guard state.route.isValid else { throw ForgeMissionArchiveError.invalidRoute }
        try validateDurableRecords(
            stageEvidence: state.stageEvidence,
            workerReceipts: state.workerReceipts,
            decisions: state.decisions,
            recoveryRecords: state.recoveryRecords,
            missionID: state.missionID,
            projectID: state.projectID
        )

        let activeStageIDs''', 'archive current records')
a = replace_once(a, '''        case .needsDecision:
            guard state.activeLeases.isEmpty, state.graph.stages.contains(where: { $0.status == .waitingForDecision }) else { throw ForgeMissionArchiveError.invalidDecisionGate }
''', '''        case .needsDecision:
            guard state.activeLeases.isEmpty,
                  let pending = state.pendingDecision,
                  !pending.prompt.trimmed.isEmpty,
                  state.graph.stages.contains(where: {
                      $0.stageID == pending.stageID && $0.status == .waitingForDecision
                  }) else { throw ForgeMissionArchiveError.invalidDecisionGate }
''', 'archive actionable decision gate')
a = replace_once(a, '''        case .draftIntent, .planning, .ready, .pausedByUser, .pausedByPolicy, .validating, .polishing, .cancelled:
            guard state.activeLeases.isEmpty else { throw ForgeMissionArchiveError.nonExecutingStateHasLease }
        }

        var checkpointIDs''', '''        case .draftIntent, .planning, .ready, .pausedByUser, .pausedByPolicy, .validating, .polishing, .cancelled:
            guard state.activeLeases.isEmpty else { throw ForgeMissionArchiveError.nonExecutingStateHasLease }
        }
        if state.phase != .needsDecision, state.pendingDecision != nil {
            throw ForgeMissionArchiveError.invalidDecisionGate
        }

        var checkpointIDs''', 'archive stale pending decision rejection')
a = replace_once(a, '''            guard !checkpoint.routeReceiptID.trimmed.isEmpty,
                  !checkpoint.acceptedProjectStateID.trimmed.isEmpty,
                  !checkpoint.summary.trimmed.isEmpty,
                  !checkpoint.evidenceReceiptIDs.values.isEmpty,
                  checkpoint.evidenceReceiptIDs.values.allSatisfy({ !$0.trimmed.isEmpty }) else { throw ForgeMissionArchiveError.invalidCheckpointEvidence }
            priorMissionRevision = checkpoint.missionRevision
''', '''            guard !checkpoint.routeReceiptID.trimmed.isEmpty,
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
                projectID: checkpoint.projectID
            )
            if checkpoint.phase == .needsDecision {
                guard let pending = checkpoint.pendingDecision,
                      !pending.prompt.trimmed.isEmpty,
                      checkpoint.graph.stages.contains(where: {
                          $0.stageID == pending.stageID && $0.status == .waitingForDecision
                      }) else { throw ForgeMissionArchiveError.invalidDecisionGate }
            } else if checkpoint.pendingDecision != nil {
                throw ForgeMissionArchiveError.invalidDecisionGate
            }
            priorMissionRevision = checkpoint.missionRevision
''', 'archive checkpoint record validation')
a = replace_once(a, '''    }
}

public enum ForgeMissionArchiveError''', '''    }

    private static func validateDurableRecords(
        stageEvidence: [MissionStageEvidence],
        workerReceipts: [MissionAcceptedWorkerReceipt],
        decisions: [MissionDecisionRecord],
        recoveryRecords: [MissionRecoveryRecord],
        missionID: MissionID,
        projectID: ProjectID
    ) throws {
        guard stageEvidence.allSatisfy({
            !$0.summary.trimmed.isEmpty &&
            !$0.receiptIDs.values.isEmpty &&
            $0.receiptIDs.values.allSatisfy({ !$0.trimmed.isEmpty })
        }) else { throw ForgeMissionArchiveError.invalidStageEvidence }
        guard workerReceipts.allSatisfy({
            $0.missionID == missionID &&
            $0.projectID == projectID &&
            !$0.summary.trimmed.isEmpty &&
            $0.evidenceReceiptIDs.values.allSatisfy({ !$0.trimmed.isEmpty })
        }) else { throw ForgeMissionArchiveError.invalidWorkerReceipt }
        guard decisions.allSatisfy({
            !$0.acceptedAnswer.trimmed.isEmpty && !$0.decisionReceiptID.trimmed.isEmpty
        }) else { throw ForgeMissionArchiveError.invalidDecisionRecord }
        guard recoveryRecords.allSatisfy({ !$0.resolutionReceiptID.trimmed.isEmpty }) else {
            throw ForgeMissionArchiveError.invalidRecoveryRecord
        }
    }
}

public enum ForgeMissionArchiveError''', 'archive durable record helper')
a = replace_once(a, '''    case invalidCheckpointEvidence
}
''', '''    case invalidCheckpointEvidence
    case invalidStageEvidence
    case invalidWorkerReceipt
    case invalidDecisionRecord
    case invalidRecoveryRecord
}
''', 'archive durable record errors')
archive_path.write_text(a)

t = tests_path.read_text()
t = replace_once(t, '''        XCTAssertThrowsError(try mission.acceptDecision(stageID: stageID, acceptedAnswer: "First person", decisionReceiptID: "", at: instant(4)))
        try mission.acceptDecision(stageID: stageID, acceptedAnswer: "First person", decisionReceiptID: "decision:camera:1", at: instant(4))
''', '''        let requestID = try XCTUnwrap(mission.pendingDecision?.requestID)
        XCTAssertThrowsError(try mission.acceptDecision(stageID: stageID, decisionRequestID: requestID, acceptedAnswer: "First person", decisionReceiptID: "", at: instant(4)))
        try mission.acceptDecision(stageID: stageID, decisionRequestID: requestID, acceptedAnswer: "First person", decisionReceiptID: "decision:camera:1", at: instant(4))
''', 'existing decision test')

insertion = '''
    func testDecisionRequestAndWorkerReceiptSurviveArchiveRoundTrip() throws {
        var mission = try makeMission()
        let stageID = try XCTUnwrap(mission.runnableStageIDs.first)
        let lease = try XCTUnwrap(try mission.beginWork(on: [stageID]).first)
        try mission.acceptWorkerResult(
            .init(
                lease: lease,
                outcome: .needsDecision,
                summary: "Choose camera",
                allowsDecisionDelegation: true
            ),
            at: instant(40)
        )

        let pending = try XCTUnwrap(mission.pendingDecision)
        XCTAssertEqual(pending.stageID, stageID)
        XCTAssertEqual(pending.prompt, "Choose camera")
        XCTAssertTrue(pending.allowsDelegation)
        XCTAssertEqual(mission.workerReceipts.last?.kind, .needsDecision)
        XCTAssertEqual(mission.workerReceipts.last?.summary, "Choose camera")

        let data = try JSONEncoder().encode(ForgeMissionArchive(state: mission))
        var restored = try JSONDecoder().decode(ForgeMissionArchive.self, from: data).state
        XCTAssertEqual(restored.pendingDecision, pending)
        XCTAssertEqual(restored.workerReceipts, mission.workerReceipts)
        XCTAssertThrowsError(try restored.resume())
        XCTAssertThrowsError(try restored.acceptDecision(
            stageID: stageID,
            decisionRequestID: MissionDecisionRequestID(),
            acceptedAnswer: "First person",
            decisionReceiptID: "decision:stale",
            at: instant(41)
        )) { error in
            XCTAssertEqual(error as? ForgeMissionError, .staleDecisionRequest)
        }
        try restored.acceptDecision(
            stageID: stageID,
            decisionRequestID: pending.requestID,
            acceptedAnswer: "First person",
            decisionReceiptID: "decision:camera:1",
            at: instant(41)
        )
        XCTAssertNil(restored.pendingDecision)
    }

    func testRestoreRewindsCurrentAuthorityRecordsToCheckpointBranch() throws {
        var mission = try makeMission()
        let first = try mission.checkpoint(
            acceptedProjectStateID: "state:a",
            evidenceReceiptIDs: .init(["checkpoint:a"]),
            summary: "A",
            at: instant(50)
        )
        let stageID = try XCTUnwrap(mission.runnableStageIDs.first)
        var lease = try XCTUnwrap(try mission.beginWork(on: [stageID]).first)
        try mission.acceptWorkerResult(
            .init(lease: lease, outcome: .needsDecision, summary: "Choose camera"),
            at: instant(51)
        )
        let requestID = try XCTUnwrap(mission.pendingDecision?.requestID)
        try mission.acceptDecision(
            stageID: stageID,
            decisionRequestID: requestID,
            acceptedAnswer: "Third person",
            decisionReceiptID: "decision:camera",
            at: instant(52)
        )
        lease = try XCTUnwrap(try mission.beginWork(on: [stageID]).first)
        try mission.acceptWorkerResult(
            .init(lease: lease, outcome: .blockedExternal, summary: "Mac unavailable"),
            at: instant(53)
        )
        try mission.resolveExternalBlock(
            stageID: stageID,
            resolutionReceiptID: "mac:reverified",
            at: instant(54)
        )
        lease = try XCTUnwrap(try mission.beginWork(on: [stageID]).first)
        try mission.acceptWorkerResult(
            .init(
                lease: lease,
                outcome: .completed,
                summary: "Built",
                evidenceReceiptIDs: .init(["build:receipt"])
            ),
            at: instant(55)
        )
        _ = try mission.checkpoint(
            acceptedProjectStateID: "state:b",
            evidenceReceiptIDs: .init(["checkpoint:b"]),
            summary: "B",
            at: instant(56)
        )
        XCTAssertFalse(mission.stageEvidence.isEmpty)
        XCTAssertFalse(mission.workerReceipts.isEmpty)
        XCTAssertFalse(mission.decisions.isEmpty)
        XCTAssertFalse(mission.recoveryRecords.isEmpty)

        let request = try mission.prepareRestore(to: first.id)
        let branched = try mission.acceptVerifiedRestore(
            request,
            verifiedProjectStateID: "state:a",
            restoreReceiptID: "restore:a",
            at: instant(57)
        )
        XCTAssertEqual(branched.parentID, first.id)
        XCTAssertTrue(mission.stageEvidence.isEmpty)
        XCTAssertTrue(mission.workerReceipts.isEmpty)
        XCTAssertTrue(mission.decisions.isEmpty)
        XCTAssertTrue(mission.recoveryRecords.isEmpty)
        XCTAssertNil(mission.pendingDecision)
        XCTAssertEqual(mission.phase, .pausedByUser)
        XCTAssertNoThrow(try ForgeMissionArchive(state: mission))
    }

    func testRestoreToDecisionCheckpointRestoresActionablePrompt() throws {
        var mission = try makeMission()
        let stageID = try XCTUnwrap(mission.runnableStageIDs.first)
        let lease = try XCTUnwrap(try mission.beginWork(on: [stageID]).first)
        try mission.acceptWorkerResult(
            .init(lease: lease, outcome: .needsDecision, summary: "Pick orientation"),
            at: instant(60)
        )
        let pending = try XCTUnwrap(mission.pendingDecision)
        let decisionCheckpoint = try mission.checkpoint(
            acceptedProjectStateID: "state:decision",
            evidenceReceiptIDs: .init(["checkpoint:decision"]),
            summary: "Waiting for orientation",
            at: instant(61)
        )
        try mission.acceptDecision(
            stageID: stageID,
            decisionRequestID: pending.requestID,
            acceptedAnswer: "Landscape",
            decisionReceiptID: "decision:orientation",
            at: instant(62)
        )

        let request = try mission.prepareRestore(to: decisionCheckpoint.id)
        _ = try mission.acceptVerifiedRestore(
            request,
            verifiedProjectStateID: "state:decision",
            restoreReceiptID: "restore:decision",
            at: instant(63)
        )
        XCTAssertEqual(mission.phase, .needsDecision)
        XCTAssertEqual(mission.pendingDecision, pending)
        XCTAssertNoThrow(try ForgeMissionArchive(state: mission))
    }

'''
t = replace_once(t, '''    func testArchiveRoundTripIsDeterministicAndFailClosedOnSchema() throws {
''', insertion + '''    func testArchiveRoundTripIsDeterministicAndFailClosedOnSchema() throws {
''', 'durable-state regression tests')
tests_path.write_text(t)

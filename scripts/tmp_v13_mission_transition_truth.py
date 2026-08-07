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
s = replace_once(s, '''    case requiredStageCannotBeDeferred(MissionStageID)
    case duplicateStageRequest(MissionStageID)
''', '''    case requiredStageCannotBeDeferred(MissionStageID)
    case stageNotDeferrable(MissionStageID)
    case duplicateStageRequest(MissionStageID)
''', 'deferral error')
s = replace_once(s, '''    case completionRequiresSatisfiedRequiredWork
    case completionRequiresCheckpoint
''', '''    case completionRequiresSatisfiedRequiredWork
    case completionRequiresSettledStageGraph
    case completionRequiresCheckpoint
''', 'completion settlement error')

s = replace_once(s, '''        guard let index = graph.stages.firstIndex(where: { $0.stageID == stageID }) else { throw ForgeMissionError.stageNotFound(stageID) }
        guard !graph.stages[index].required else { throw ForgeMissionError.requiredStageCannotBeDeferred(stageID) }
        var stages = graph.stages
''', '''        guard let index = graph.stages.firstIndex(where: { $0.stageID == stageID }) else { throw ForgeMissionError.stageNotFound(stageID) }
        guard !graph.stages[index].required else { throw ForgeMissionError.requiredStageCannotBeDeferred(stageID) }
        guard graph.stages[index].status == .pending else { throw ForgeMissionError.stageNotDeferrable(stageID) }
        var stages = graph.stages
''', 'deferral status gate')

s = replace_once(s, '''        for accepted in graph.stages where accepted.status == .completed {
            guard newByID[accepted.stageID]?.status == .completed else {
                throw ForgeMissionError.acceptedCompletedStageWouldBeLost(accepted.stageID)
            }
        }
        if let pendingDecision {
''', '''        for accepted in graph.stages where accepted.status == .completed {
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
''', 'graph gate preservation')

s = replace_once(s, '''        guard activeLeases.isEmpty else { throw ForgeMissionError.activeWorkExists }
        guard graph.requiredWorkIsSatisfied else { throw ForgeMissionError.completionRequiresSatisfiedRequiredWork }
        guard let checkpoint = checkpoints.last else { throw ForgeMissionError.completionRequiresCheckpoint }
''', '''        guard activeLeases.isEmpty else { throw ForgeMissionError.activeWorkExists }
        guard graph.requiredWorkIsSatisfied else { throw ForgeMissionError.completionRequiresSatisfiedRequiredWork }
        guard pendingDecision == nil,
              graph.stages.allSatisfy({ [.completed, .deferred].contains($0.status) }) else {
            throw ForgeMissionError.completionRequiresSettledStageGraph
        }
        guard let checkpoint = checkpoints.last else { throw ForgeMissionError.completionRequiresCheckpoint }
''', 'completion settled graph gate')
source_path.write_text(s)

a = archive_path.read_text()
a = replace_once(a, '''        case .needsDecision:
            guard state.activeLeases.isEmpty,
                  let pending = state.pendingDecision,
                  !pending.prompt.trimmed.isEmpty,
                  state.graph.stages.contains(where: {
                      $0.stageID == pending.stageID && $0.status == .waitingForDecision
                  }) else { throw ForgeMissionArchiveError.invalidDecisionGate }
        case .blockedExternal:
            guard state.activeLeases.isEmpty, state.graph.stages.contains(where: { $0.status == .blocked }) else { throw ForgeMissionArchiveError.invalidBlockedState }
        case .interruptedRecoverable:
            guard state.activeLeases.isEmpty, state.graph.stages.contains(where: { $0.status == .failedRecoverably }) else { throw ForgeMissionArchiveError.invalidRecoverableState }
        case .failedIrrecoverably:
            guard state.activeLeases.isEmpty, state.graph.stages.contains(where: { $0.status == .failedIrrecoverably }) else { throw ForgeMissionArchiveError.invalidFailedState }
        case .completedWithEvidence, .completedWithKnownLimitations:
            guard state.activeLeases.isEmpty, state.graph.requiredWorkIsSatisfied, state.completionEvidence != nil else { throw ForgeMissionArchiveError.invalidCompletion }
''', '''        case .needsDecision:
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
''', 'current phase receipt and completion truth')

a = replace_once(a, '''            if checkpoint.phase == .needsDecision {
                guard let pending = checkpoint.pendingDecision,
                      !pending.prompt.trimmed.isEmpty,
                      checkpoint.graph.stages.contains(where: {
                          $0.stageID == pending.stageID && $0.status == .waitingForDecision
                      }) else { throw ForgeMissionArchiveError.invalidDecisionGate }
            } else if checkpoint.pendingDecision != nil {
                throw ForgeMissionArchiveError.invalidDecisionGate
            }
            priorMissionRevision = checkpoint.missionRevision
''', '''            switch checkpoint.phase {
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
''', 'checkpoint phase truth')

a = replace_once(a, '''        if let completion = state.completionEvidence {
            guard let checkpoint = state.checkpoints.last else { throw ForgeMissionArchiveError.invalidCompletion }
''', '''        if let completion = state.completionEvidence {
            guard [.completedWithEvidence, .completedWithKnownLimitations].contains(state.phase),
                  let checkpoint = state.checkpoints.last else { throw ForgeMissionArchiveError.invalidCompletion }
''', 'completion evidence phase binding')

a = replace_once(a, '''    case invalidCheckpointEvidence
    case invalidStageEvidence
''', '''    case invalidCheckpointEvidence
    case invalidCheckpointPhase
    case invalidStageEvidence
''', 'checkpoint phase error')
archive_path.write_text(a)

t = tests_path.read_text()
insertion = '''
    func testDecisionGatedOptionalStageCannotBypassReceiptViaDeferral() throws {
        let missionID = MissionID(); let projectID = ProjectID(); let optionalID = MissionStageID()
        var mission = try ForgeMissionState(
            constitution: constitution(missionID: missionID, projectID: projectID, revision: 1),
            graph: MissionStageGraph(missionID: missionID, stages: [
                MissionStage(stageID: optionalID, kind: .design, title: "Optional choice", order: 1, required: false),
            ]),
            route: .init(routeReceiptID: "route:balanced:1")
        )
        let lease = try mission.beginWork(on: [optionalID])[0]
        try mission.acceptWorkerResult(.init(lease: lease, outcome: .needsDecision, summary: "Choose style"), at: instant(70))

        XCTAssertThrowsError(try mission.deferOptionalStage(optionalID)) { error in
            XCTAssertEqual(error as? ForgeMissionError, .stageNotDeferrable(optionalID))
        }
        XCTAssertEqual(mission.phase, .needsDecision)
        XCTAssertNotNil(mission.pendingDecision)
        XCTAssertNoThrow(try ForgeMissionArchive(state: mission))
    }

    func testCompletionRequiresOptionalStagesToBeExplicitlySettled() throws {
        let missionID = MissionID(); let projectID = ProjectID()
        let requiredID = MissionStageID(); let optionalID = MissionStageID()
        var mission = try ForgeMissionState(
            constitution: constitution(missionID: missionID, projectID: projectID, revision: 1),
            graph: MissionStageGraph(missionID: missionID, stages: [
                MissionStage(stageID: requiredID, kind: .implement, title: "Required", order: 1),
                MissionStage(stageID: optionalID, kind: .polish, title: "Optional", order: 2, required: false, dependencies: [requiredID]),
            ]),
            route: .init(routeReceiptID: "route:balanced:1")
        )
        let lease = try mission.beginWork(on: [requiredID])[0]
        try mission.acceptWorkerResult(.init(lease: lease, outcome: .completed, summary: "Required done", evidenceReceiptIDs: .init(["required:r"])), at: instant(71))
        _ = try mission.checkpoint(acceptedProjectStateID: "state:settled", evidenceReceiptIDs: .init(["checkpoint:settled"]), summary: "Required accepted", at: instant(72))

        XCTAssertThrowsError(try mission.complete(with: completion(state: "state:settled", classes: [.runtimeTested]))) { error in
            XCTAssertEqual(error as? ForgeMissionError, .completionRequiresSettledStageGraph)
        }
        try mission.deferOptionalStage(optionalID)
        try mission.complete(with: completion(state: "state:settled", classes: [.runtimeTested]))
        XCTAssertEqual(mission.phase, .completedWithEvidence)
    }

    func testGraphReplacementCannotEraseOutstandingBlockGate() throws {
        var mission = try makeMission()
        let stageID = try XCTUnwrap(mission.runnableStageIDs.first)
        let lease = try mission.beginWork(on: [stageID])[0]
        try mission.acceptWorkerResult(.init(lease: lease, outcome: .blockedExternal, summary: "Mac unavailable"), at: instant(73))
        let replacement = MissionStageGraph(missionID: mission.missionID, revision: mission.graph.revision + 1, stages: [])

        XCTAssertThrowsError(try mission.replaceStageGraph(replacement)) { error in
            XCTAssertEqual(error as? ForgeMissionError, .invalidGraph)
        }
        XCTAssertEqual(mission.phase, .blockedExternal)
        XCTAssertNoThrow(try ForgeMissionArchive(state: mission))
    }

'''
t = replace_once(t, '''    func testArchiveRoundTripIsDeterministicAndFailClosedOnSchema() throws {
''', insertion + '''    func testArchiveRoundTripIsDeterministicAndFailClosedOnSchema() throws {
''', 'transition truth regression tests')
tests_path.write_text(t)

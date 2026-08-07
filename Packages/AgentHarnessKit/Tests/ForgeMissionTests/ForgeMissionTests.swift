import AgentDomain
import ForgeMission
import Foundation
import XCTest

final class ForgeMissionTests: XCTestCase {
    func testParallelCompletionDoesNotInvalidateSiblingLease() throws {
        var mission = try makeMission(twoIndependentStages: true)
        let ids = mission.runnableStageIDs
        XCTAssertEqual(ids.count, 2)
        let leases = try mission.beginWork(on: ids)
        try mission.acceptWorkerResult(.init(lease: leases[0], outcome: .completed, summary: "first", evidenceReceiptIDs: .init(["r1"])), at: instant(10))
        XCTAssertEqual(mission.activeLeases, [leases[1]])
        try mission.acceptWorkerResult(.init(lease: leases[1], outcome: .completed, summary: "second", evidenceReceiptIDs: .init(["r2"])), at: instant(11))
        XCTAssertEqual(mission.phase, .validating)
    }

    func testDependencyNotRunnableUntilAcceptedEvidenceCompletion() throws {
        var mission = try makeMission(withDependency: true)
        let first = try XCTUnwrap(mission.runnableStageIDs.first)
        let lease = try XCTUnwrap(try mission.beginWork(on: [first]).first)
        XCTAssertEqual(mission.runnableStageIDs.count, 0)
        try mission.acceptWorkerResult(.init(lease: lease, outcome: .completed, summary: "done", evidenceReceiptIDs: .init(["build:r1"])), at: instant(2))
        XCTAssertEqual(mission.runnableStageIDs.count, 1)
    }

    func testDecisionGateCannotResumeWithoutAcceptedDecisionReceipt() throws {
        var mission = try makeMission()
        let stageID = try XCTUnwrap(mission.runnableStageIDs.first)
        let lease = try XCTUnwrap(try mission.beginWork(on: [stageID]).first)
        try mission.acceptWorkerResult(.init(lease: lease, outcome: .needsDecision, summary: "Choose camera"), at: instant(3))
        XCTAssertEqual(mission.phase, .needsDecision)
        XCTAssertThrowsError(try mission.resume()) { XCTAssertEqual($0 as? ForgeMissionError, .invalidPhase(.needsDecision)) }
        let requestID = try XCTUnwrap(mission.pendingDecision?.requestID)
        XCTAssertThrowsError(try mission.acceptDecision(stageID: stageID, decisionRequestID: requestID, acceptedAnswer: "First person", decisionReceiptID: "", at: instant(4)))
        try mission.acceptDecision(stageID: stageID, decisionRequestID: requestID, acceptedAnswer: "First person", decisionReceiptID: "decision:camera:1", at: instant(4))
        XCTAssertEqual(mission.phase, .ready)
        XCTAssertEqual(mission.decisions.count, 1)
    }


    func testDecideForMePlaceholderCannotBecomeAcceptedSemanticDecision() throws {
        var mission = try makeMission()
        let stageID = try XCTUnwrap(mission.runnableStageIDs.first)
        let lease = try mission.beginWork(on: [stageID])[0]
        try mission.acceptWorkerResult(
            .init(
                lease: lease,
                outcome: .needsDecision,
                summary: "Choose camera",
                allowsDecisionDelegation: true
            ),
            at: instant(75)
        )
        let requestID = try XCTUnwrap(mission.pendingDecision?.requestID)

        XCTAssertThrowsError(try mission.acceptDecision(
            stageID: stageID,
            decisionRequestID: requestID,
            acceptedAnswer: "DECIDE_FOR_ME",
            decisionReceiptID: "decision:delegated",
            at: instant(76)
        )) { error in
            XCTAssertEqual(error as? ForgeMissionError, .invalidDecision)
        }
        XCTAssertThrowsError(try mission.acceptDecision(
            stageID: stageID,
            decisionRequestID: requestID,
            acceptedAnswer: "Decide for me",
            decisionReceiptID: "decision:delegated",
            at: instant(76)
        ))
        XCTAssertEqual(mission.phase, .needsDecision)
        XCTAssertNotNil(mission.pendingDecision)

        try mission.acceptDecision(
            stageID: stageID,
            decisionRequestID: requestID,
            acceptedAnswer: "Third person",
            decisionReceiptID: "decision:delegated:resolved",
            at: instant(77)
        )
        XCTAssertEqual(mission.decisions.last?.acceptedAnswer, "Third person")
        XCTAssertEqual(mission.phase, .ready)
    }

    func testExternalBlockRequiresResolutionReceipt() throws {
        var mission = try makeMission()
        let id = try XCTUnwrap(mission.runnableStageIDs.first)
        let lease = try XCTUnwrap(try mission.beginWork(on: [id]).first)
        try mission.acceptWorkerResult(.init(lease: lease, outcome: .blockedExternal, summary: "Mac offline"), at: instant(5))
        XCTAssertEqual(mission.phase, .blockedExternal)
        XCTAssertThrowsError(try mission.resolveExternalBlock(stageID: id, resolutionReceiptID: "", at: instant(6)))
        try mission.resolveExternalBlock(stageID: id, resolutionReceiptID: "mac:reverified", at: instant(6))
        XCTAssertEqual(mission.phase, .ready)
    }

    func testRecoverableFailureRevokesOtherParallelWorkAndRequiresRetryReceipt() throws {
        var mission = try makeMission(twoIndependentStages: true)
        let leases = try mission.beginWork(on: mission.runnableStageIDs)
        try mission.acceptWorkerResult(.init(lease: leases[0], outcome: .failedRecoverably, summary: "runtime crash"), at: instant(7))
        XCTAssertEqual(mission.phase, .interruptedRecoverable)
        XCTAssertTrue(mission.activeLeases.isEmpty)
        XCTAssertThrowsError(try mission.acceptWorkerResult(.init(lease: leases[1], outcome: .completed, summary: "late", evidenceReceiptIDs: .init(["late"])), at: instant(8))) {
            XCTAssertEqual($0 as? ForgeMissionError, .staleWorkerResult)
        }
        try mission.retryRecoverableStage(stageID: leases[0].stageID, resolutionReceiptID: "crash:diagnosed", at: instant(9))
        XCTAssertEqual(mission.phase, .ready)
    }

    func testPauseAndRouteSwitchRevokeOldAuthority() throws {
        var mission = try makeMission()
        let id = try XCTUnwrap(mission.runnableStageIDs.first)
        let old = try XCTUnwrap(try mission.beginWork(on: [id]).first)
        try mission.pauseByUser()
        XCTAssertTrue(mission.activeLeases.isEmpty)
        XCTAssertThrowsError(try mission.acceptWorkerResult(.init(lease: old, outcome: .completed, summary: "late", evidenceReceiptIDs: .init(["late"])), at: instant(8)))
        try mission.resume()
        let next = try XCTUnwrap(try mission.beginWork(on: [id]).first)
        try mission.switchRoute(to: .init(routeReceiptID: "route:deep:2"))
        XCTAssertTrue(mission.activeLeases.isEmpty)
        XCTAssertThrowsError(try mission.acceptWorkerResult(.init(lease: next, outcome: .completed, summary: "late route", evidenceReceiptIDs: .init(["late"])), at: instant(9)))
    }

    func testCrossProjectLeaseIsRejectedEvenWithMatchingMissionStageAndAuthority() throws {
        var mission = try makeMission()
        let id = try XCTUnwrap(mission.runnableStageIDs.first)
        let lease = try XCTUnwrap(try mission.beginWork(on: [id]).first)
        let forged = MissionWorkLease(
            leaseID: lease.leaseID,
            missionID: lease.missionID,
            projectID: ProjectID(),
            stageID: lease.stageID,
            authorityEpoch: lease.authorityEpoch,
            graphRevision: lease.graphRevision,
            checkpointID: lease.checkpointID,
            routeReceiptID: lease.routeReceiptID
        )
        XCTAssertThrowsError(try mission.acceptWorkerResult(.init(lease: forged, outcome: .completed, summary: "wrong project", evidenceReceiptIDs: .init(["r"])), at: instant(9))) {
            XCTAssertEqual($0 as? ForgeMissionError, .staleWorkerResult)
        }
    }

    func testCancellationRevokesLeaseAndTerminalStateRejectsMutation() throws {
        var mission = try makeMission()
        let lease = try XCTUnwrap(try mission.beginWork(on: [mission.runnableStageIDs[0]]).first)
        try mission.cancel()
        XCTAssertEqual(mission.phase, .cancelled)
        XCTAssertTrue(mission.activeLeases.isEmpty)
        XCTAssertThrowsError(try mission.acceptWorkerResult(.init(lease: lease, outcome: .completed, summary: "late", evidenceReceiptIDs: .init(["r"])), at: instant(10))) {
            XCTAssertEqual($0 as? ForgeMissionError, .missionTerminal)
        }
        XCTAssertThrowsError(try mission.switchRoute(to: .init(routeReceiptID: "route:new"))) {
            XCTAssertEqual($0 as? ForgeMissionError, .missionTerminal)
        }
    }

    func testCheckpointBindsProjectStateEvidenceRouteAndProjectBrainFacts() throws {
        var mission = try makeMission()
        let fact = ProjectBrainFactID()
        let checkpoint = try mission.checkpoint(
            acceptedProjectStateID: "state:sha256:abc",
            evidenceReceiptIDs: .init(["receipt:plan"]),
            projectBrainFactIDs: [fact],
            summary: "Accepted plan",
            at: instant(20)
        )
        XCTAssertEqual(checkpoint.missionID, mission.missionID)
        XCTAssertEqual(checkpoint.projectID, mission.projectID)
        XCTAssertEqual(checkpoint.acceptedProjectStateID, "state:sha256:abc")
        XCTAssertEqual(checkpoint.routeReceiptID, "route:balanced:1")
        XCTAssertEqual(checkpoint.projectBrainFactIDs, [fact])
    }

    func testOptionalPolishCanContinueAfterRequiredWorkMovesMissionToValidating() throws {
        let missionID = MissionID(); let projectID = ProjectID()
        let implementID = MissionStageID(); let polishID = MissionStageID()
        var mission = try ForgeMissionState(
            constitution: constitution(missionID: missionID, projectID: projectID, revision: 1),
            graph: MissionStageGraph(missionID: missionID, stages: [
                MissionStage(stageID: implementID, kind: .implement, title: "Implement", order: 1),
                MissionStage(stageID: polishID, kind: .polish, title: "Optional polish", order: 2, required: false, dependencies: [implementID]),
            ]),
            route: .init(routeReceiptID: "route:balanced:1")
        )

        let implementationLease = try mission.beginWork(on: [implementID])[0]
        try mission.acceptWorkerResult(
            .init(lease: implementationLease, outcome: .completed, summary: "Required work accepted", evidenceReceiptIDs: .init(["required:r"])),
            at: instant(12)
        )

        XCTAssertEqual(mission.phase, .validating)
        XCTAssertEqual(mission.runnableStageIDs, [polishID])
        let polishLease = try mission.beginWork(on: [polishID])[0]
        XCTAssertEqual(polishLease.stageID, polishID)
        XCTAssertEqual(mission.phase, .executing)
    }

    func testCompletionRequiresRequiredWorkCheckpointAndExpectedEvidence() throws {
        var mission = try makeMission(expectedEvidence: [.runtimeTested, .visuallyInspected])
        XCTAssertThrowsError(try mission.complete(with: completion(state: "s1", classes: [.runtimeTested, .visuallyInspected]))) {
            XCTAssertEqual($0 as? ForgeMissionError, .completionRequiresSatisfiedRequiredWork)
        }
        let id = mission.runnableStageIDs[0]
        let lease = try mission.beginWork(on: [id])[0]
        try mission.acceptWorkerResult(.init(lease: lease, outcome: .completed, summary: "done", evidenceReceiptIDs: .init(["stage:done"])), at: instant(2))
        XCTAssertThrowsError(try mission.complete(with: completion(state: "s1", classes: [.runtimeTested, .visuallyInspected]))) {
            XCTAssertEqual($0 as? ForgeMissionError, .completionRequiresCheckpoint)
        }
        _ = try mission.checkpoint(acceptedProjectStateID: "s1", evidenceReceiptIDs: .init(["checkpoint:r"]), summary: "accepted", at: instant(3))
        XCTAssertThrowsError(try mission.complete(with: completion(state: "s1", classes: [.runtimeTested]))) {
            XCTAssertEqual($0 as? ForgeMissionError, .completionMissingExpectedEvidence)
        }
        try mission.complete(with: completion(state: "s1", classes: [.runtimeTested, .visuallyInspected]))
        XCTAssertEqual(mission.phase, .completedWithEvidence)
    }

    func testKnownLimitationsProduceDistinctTerminalTruth() throws {
        var mission = try completedReadyMission()
        try mission.complete(with: MissionCompletionEvidence(
            acceptedProjectStateID: "state:1",
            evidenceClasses: .init([.runtimeTested]),
            receiptIDs: .init(["completion:r"]),
            knownLimitations: .init(["No physical-device proof"]),
            acceptedAt: instant(30)
        ))
        XCTAssertEqual(mission.phase, .completedWithKnownLimitations)
    }

    func testGraphRevisionCannotDropAcceptedCompletedStage() throws {
        var mission = try makeMission()
        let id = mission.runnableStageIDs[0]
        let lease = try mission.beginWork(on: [id])[0]
        try mission.acceptWorkerResult(.init(lease: lease, outcome: .completed, summary: "done", evidenceReceiptIDs: .init(["r"])), at: instant(2))
        let replacement = MissionStageGraph(missionID: mission.missionID, revision: mission.graph.revision + 1, stages: [])
        XCTAssertThrowsError(try mission.replaceStageGraph(replacement)) {
            XCTAssertEqual($0 as? ForgeMissionError, .acceptedCompletedStageWouldBeLost(id))
        }
    }

    func testConstitutionRevisionMustKeepMissionAndProjectIdentityAndAdvance() throws {
        var mission = try makeMission()
        let sameRevision = constitution(missionID: mission.missionID, projectID: mission.projectID, revision: mission.constitution.revision)
        XCTAssertThrowsError(try mission.acceptConstitutionRevision(sameRevision)) {
            XCTAssertEqual($0 as? ForgeMissionError, .constitutionRevisionNotAdvanced)
        }
        let wrongProject = constitution(missionID: mission.missionID, projectID: ProjectID(), revision: 2)
        XCTAssertThrowsError(try mission.acceptConstitutionRevision(wrongProject)) {
            XCTAssertEqual($0 as? ForgeMissionError, .constitutionIdentityMismatch)
        }
        try mission.acceptConstitutionRevision(constitution(missionID: mission.missionID, projectID: mission.projectID, revision: 2))
        XCTAssertEqual(mission.constitution.revision, 2)
    }

    func testRestoreRequiresVerifiedProjectStateBeforeMissionMetadataMoves() throws {
        var mission = try makeMission()
        let first = try mission.checkpoint(acceptedProjectStateID: "state:a", evidenceReceiptIDs: .init(["r:a"]), summary: "A", at: instant(1))
        try mission.switchRoute(to: .init(routeReceiptID: "route:other"))
        _ = try mission.checkpoint(acceptedProjectStateID: "state:b", evidenceReceiptIDs: .init(["r:b"]), summary: "B", at: instant(2))
        let routeBeforeVerification = mission.route
        let graphBeforeVerification = mission.graph
        let request = try mission.prepareRestore(to: first.id)

        XCTAssertThrowsError(try mission.acceptVerifiedRestore(
            request,
            verifiedProjectStateID: "state:wrong",
            restoreReceiptID: "restore:r",
            at: instant(3)
        )) { error in
            XCTAssertEqual(error as? ForgeMissionError, .restoreVerificationMismatch)
        }
        XCTAssertEqual(mission.route, routeBeforeVerification)
        XCTAssertEqual(mission.graph, graphBeforeVerification)

        let restored = try mission.acceptVerifiedRestore(
            request,
            verifiedProjectStateID: "state:a",
            restoreReceiptID: "restore:r",
            at: instant(3)
        )
        XCTAssertEqual(restored.parentID, first.id)
        XCTAssertEqual(restored.projectID, mission.projectID)
        XCTAssertEqual(mission.phase, .pausedByUser)
        XCTAssertEqual(mission.route.routeReceiptID, first.routeReceiptID)
        XCTAssertTrue(restored.evidenceReceiptIDs.contains("restore:r"))
    }

    func testCompletedMissionCanReopenAsContinuationWithoutLosingCheckpointLineage() throws {
        var mission = try completedReadyMission()
        try mission.complete(with: completion(state: "state:1", classes: [.runtimeTested]))
        let checkpointBeforeContinuation = mission.latestCheckpointID
        let newStage = MissionStage(
            stageID: MissionStageID(),
            kind: .polish,
            title: "Improve the accepted build",
            order: 2,
            required: false,
            dependencies: mission.graph.stages.map(\.stageID),
            status: .completed
        )

        try mission.beginContinuation(with: [newStage])

        XCTAssertEqual(mission.phase, .ready)
        XCTAssertNil(mission.completionEvidence)
        XCTAssertEqual(mission.latestCheckpointID, checkpointBeforeContinuation)
        XCTAssertEqual(mission.graph.stages.last?.status, .pending)
        XCTAssertEqual(mission.runnableStageIDs, [newStage.stageID])
        _ = try mission.beginWork(on: [newStage.stageID])
        XCTAssertEqual(mission.phase, .executing)
    }


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


    func testDecisionGatedOptionalStageCannotBypassReceiptViaDeferral() throws {
        let missionID = MissionID(); let projectID = ProjectID(); let optionalID = MissionStageID()
        var mission = try ForgeMissionState(
            constitution: constitution(missionID: missionID, projectID: projectID, revision: 1),
            graph: MissionStageGraph(missionID: missionID, stages: [
                MissionStage(stageID: optionalID, kind: .plan, title: "Optional choice", order: 1, required: false),
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
        XCTAssertThrowsError(try mission.complete(with: completion(state: "state:settled", classes: [.runtimeTested]))) { error in
            XCTAssertEqual(error as? ForgeMissionError, .completionCheckpointAuthorityMismatch)
        }
        _ = try mission.checkpoint(
            acceptedProjectStateID: "state:settled",
            evidenceReceiptIDs: .init(["checkpoint:deferred"]),
            summary: "Optional work explicitly deferred",
            at: instant(73)
        )
        try mission.complete(with: completion(state: "state:settled", classes: [.runtimeTested]))
        XCTAssertEqual(mission.phase, .completedWithEvidence)
    }

    func testNewMissionCannotBeginWithManufacturedExecutionStatus() throws {
        let missionID = MissionID(); let projectID = ProjectID(); let stageID = MissionStageID()
        let completedGraph = MissionStageGraph(missionID: missionID, stages: [
            MissionStage(stageID: stageID, kind: .implement, title: "Pretend done", order: 1, status: .completed),
        ])

        XCTAssertThrowsError(try ForgeMissionState(
            constitution: constitution(missionID: missionID, projectID: projectID, revision: 1),
            graph: completedGraph,
            route: .init(routeReceiptID: "route:fresh")
        )) { error in
            XCTAssertEqual(error as? ForgeMissionError, .invalidGraph)
        }
    }

    func testGraphReplacementCannotManufactureExecutionStatus() throws {
        var mission = try makeMission()
        let stageID = try XCTUnwrap(mission.graph.stages.first?.stageID)
        let forged = MissionStageGraph(missionID: mission.missionID, revision: mission.graph.revision + 1, stages: [
            MissionStage(stageID: stageID, kind: .implement, title: "Implementation", order: 1, status: .completed),
        ])

        XCTAssertThrowsError(try mission.replaceStageGraph(forged)) { error in
            XCTAssertEqual(error as? ForgeMissionError, .invalidGraph)
        }

        let insertedID = MissionStageID()
        let insertedAsBlocked = MissionStageGraph(missionID: mission.missionID, revision: mission.graph.revision + 1, stages: [
            mission.graph.stages[0],
            MissionStage(stageID: insertedID, kind: .test, title: "New test", order: 2, required: false, status: .blocked),
        ])
        XCTAssertThrowsError(try mission.replaceStageGraph(insertedAsBlocked)) { error in
            XCTAssertEqual(error as? ForgeMissionError, .invalidGraph)
        }
    }

    func testGraphReplacementCanStillEvolveUntouchedPendingTopology() throws {
        var mission = try makeMission()
        let originalID = try XCTUnwrap(mission.graph.stages.first?.stageID)
        let replacementID = MissionStageID()
        let evolved = MissionStageGraph(missionID: mission.missionID, revision: mission.graph.revision + 1, stages: [
            MissionStage(stageID: replacementID, kind: .test, title: "Replanned verification", order: 1),
        ])

        XCTAssertNoThrow(try mission.replaceStageGraph(evolved))
        XCTAssertNil(mission.graph.stages.first(where: { $0.stageID == originalID }))
        XCTAssertEqual(mission.graph.stages.first?.stageID, replacementID)
        XCTAssertEqual(mission.graph.stages.first?.status, .pending)
    }

    func testArchiveRejectsDuplicateAcceptedCompletionEvidence() throws {
        var mission = try makeMission()
        let stageID = try XCTUnwrap(mission.runnableStageIDs.first)
        let lease = try mission.beginWork(on: [stageID])[0]
        try mission.acceptWorkerResult(
            .init(lease: lease, outcome: .completed, summary: "Built", evidenceReceiptIDs: .init(["build:one"])),
            at: instant(81)
        )
        let archive = try ForgeMissionArchive(state: mission)
        let data = try JSONEncoder().encode(archive)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var state = try XCTUnwrap(root["state"] as? [String: Any])
        var evidence = try XCTUnwrap(state["stageEvidence"] as? [[String: Any]])
        evidence.append(try XCTUnwrap(evidence.first))
        state["stageEvidence"] = evidence
        root["state"] = state

        XCTAssertThrowsError(try JSONDecoder().decode(
            ForgeMissionArchive.self,
            from: JSONSerialization.data(withJSONObject: root)
        ))
    }

    func testGraphReplacementCannotDropStageWithAcceptedDecisionHistory() throws {
        var mission = try makeMission()
        let stageID = try XCTUnwrap(mission.runnableStageIDs.first)
        let lease = try mission.beginWork(on: [stageID])[0]
        try mission.acceptWorkerResult(.init(lease: lease, outcome: .needsDecision, summary: "Choose camera"), at: instant(78))
        let requestID = try XCTUnwrap(mission.pendingDecision?.requestID)
        try mission.acceptDecision(
            stageID: stageID,
            decisionRequestID: requestID,
            acceptedAnswer: "First person",
            decisionReceiptID: "decision:camera:history",
            at: instant(79)
        )
        let replacement = MissionStageGraph(missionID: mission.missionID, revision: mission.graph.revision + 1, stages: [])

        XCTAssertThrowsError(try mission.replaceStageGraph(replacement)) { error in
            XCTAssertEqual(error as? ForgeMissionError, .acceptedRecordedStageWouldBeLost(stageID))
        }
        XCTAssertNoThrow(try ForgeMissionArchive(state: mission))
    }

    func testArchiveRejectsCompletedStageWhenAcceptedEvidenceRecordIsRemoved() throws {
        var mission = try makeMission()
        let stageID = try XCTUnwrap(mission.runnableStageIDs.first)
        let lease = try mission.beginWork(on: [stageID])[0]
        try mission.acceptWorkerResult(
            .init(lease: lease, outcome: .completed, summary: "Built", evidenceReceiptIDs: .init(["build:accepted"])),
            at: instant(80)
        )
        let archive = try ForgeMissionArchive(state: mission)
        let data = try JSONEncoder().encode(archive)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var state = try XCTUnwrap(root["state"] as? [String: Any])
        state["stageEvidence"] = []
        root["state"] = state

        XCTAssertThrowsError(try JSONDecoder().decode(
            ForgeMissionArchive.self,
            from: JSONSerialization.data(withJSONObject: root)
        ))
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


    func testCompletionRejectsCheckpointFromStaleMissionAuthority() throws {
        var mission = try completedReadyMission()
        try mission.switchRoute(to: .init(routeReceiptID: "route:deep:2"))

        XCTAssertThrowsError(try mission.complete(with: completion(state: "state:1", classes: [.runtimeTested]))) { error in
            XCTAssertEqual(error as? ForgeMissionError, .completionCheckpointAuthorityMismatch)
        }
        _ = try mission.checkpoint(
            acceptedProjectStateID: "state:1",
            evidenceReceiptIDs: .init(["checkpoint:route:deep"]),
            summary: "Accepted current route authority",
            at: instant(74)
        )
        try mission.complete(with: completion(state: "state:1", classes: [.runtimeTested]))
        XCTAssertEqual(mission.phase, .completedWithEvidence)
        XCTAssertNoThrow(try ForgeMissionArchive(state: mission))
    }

    func testArchiveRoundTripIsDeterministicAndFailClosedOnSchema() throws {
        let mission = try completedReadyMission()
        let archive = try ForgeMissionArchive(state: mission)
        XCTAssertEqual(ForgeMissionArchive.currentSchemaVersion, 2)
        XCTAssertEqual(archive.schemaVersion, 2)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        XCTAssertEqual(try JSONDecoder().decode(ForgeMissionArchive.self, from: data), archive)
        XCTAssertEqual(try encoder.encode(JSONDecoder().decode(ForgeMissionArchive.self, from: data)), data)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = 1
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeMissionArchive.self, from: JSONSerialization.data(withJSONObject: json)))
        json["schemaVersion"] = 99
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeMissionArchive.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testArchiveRejectsCorruptedExecutingStateWithoutLease() throws {
        var mission = try makeMission()
        _ = try mission.beginWork(on: [mission.runnableStageIDs[0]])
        let archive = try ForgeMissionArchive(state: mission)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var state = try XCTUnwrap(root["state"] as? [String: Any])
        state["activeLeases"] = []
        root["state"] = state
        let corrupted = try JSONSerialization.data(withJSONObject: root)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeMissionArchive.self, from: corrupted))
    }

    private func makeMission(
        twoIndependentStages: Bool = false,
        withDependency: Bool = false,
        expectedEvidence: [MissionEvidenceClass] = [.runtimeTested]
    ) throws -> ForgeMissionState {
        let missionID = MissionID(); let projectID = ProjectID()
        let first = MissionStageID(); let second = MissionStageID()
        var stages = [MissionStage(stageID: first, kind: .implement, title: "Implement", order: 1)]
        if twoIndependentStages {
            stages.append(MissionStage(stageID: second, kind: .test, title: "Review", order: 2))
        } else if withDependency {
            stages.append(MissionStage(stageID: second, kind: .test, title: "Test", order: 2, dependencies: [first]))
        }
        return try ForgeMissionState(
            constitution: constitution(missionID: missionID, projectID: projectID, revision: 1, expectedEvidence: expectedEvidence),
            graph: MissionStageGraph(missionID: missionID, stages: stages),
            route: .init(routeReceiptID: "route:balanced:1")
        )
    }

    private func completedReadyMission() throws -> ForgeMissionState {
        var mission = try makeMission(expectedEvidence: [.runtimeTested])
        let lease = try mission.beginWork(on: [mission.runnableStageIDs[0]])[0]
        try mission.acceptWorkerResult(.init(lease: lease, outcome: .completed, summary: "runtime passed", evidenceReceiptIDs: .init(["stage:runtime"])), at: instant(1))
        _ = try mission.checkpoint(acceptedProjectStateID: "state:1", evidenceReceiptIDs: .init(["checkpoint:1"]), summary: "Accepted state", at: instant(2))
        return mission
    }

    private func constitution(
        missionID: MissionID,
        projectID: ProjectID,
        revision: UInt64,
        expectedEvidence: [MissionEvidenceClass] = [.runtimeTested]
    ) -> MissionConstitution {
        MissionConstitution(
            missionID: missionID,
            projectID: projectID,
            revision: revision,
            acceptedAt: instant(Int64(revision)),
            productGoal: "Build a runnable app",
            projectType: "app",
            expectedEvidence: .init(expectedEvidence)
        )
    }

    private func completion(state: String, classes: [MissionEvidenceClass]) -> MissionCompletionEvidence {
        MissionCompletionEvidence(
            acceptedProjectStateID: state,
            evidenceClasses: .init(classes),
            receiptIDs: .init(["completion:r"]),
            acceptedAt: instant(99)
        )
    }

    private func instant(_ value: Int64) -> AgentInstant { AgentInstant(rawValue: value) }
}

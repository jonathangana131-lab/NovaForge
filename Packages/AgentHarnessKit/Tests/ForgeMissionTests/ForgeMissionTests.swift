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
        XCTAssertThrowsError(try mission.acceptDecision(stageID: stageID, acceptedAnswer: "First person", decisionReceiptID: "", at: instant(4)))
        try mission.acceptDecision(stageID: stageID, acceptedAnswer: "First person", decisionReceiptID: "decision:camera:1", at: instant(4))
        XCTAssertEqual(mission.phase, .ready)
        XCTAssertEqual(mission.decisions.count, 1)
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

    func testRestoreCreatesNewLineageAndKeepsProjectIdentity() throws {
        var mission = try makeMission()
        let first = try mission.checkpoint(acceptedProjectStateID: "state:a", evidenceReceiptIDs: .init(["r:a"]), summary: "A", at: instant(1))
        try mission.switchRoute(to: .init(routeReceiptID: "route:other"))
        _ = try mission.checkpoint(acceptedProjectStateID: "state:b", evidenceReceiptIDs: .init(["r:b"]), summary: "B", at: instant(2))
        let restored = try mission.restore(to: first.id, restoreReceiptID: "restore:r", at: instant(3))
        XCTAssertEqual(restored.parentID, first.id)
        XCTAssertEqual(restored.projectID, mission.projectID)
        XCTAssertEqual(mission.phase, .pausedByUser)
        XCTAssertTrue(restored.evidenceReceiptIDs.contains("restore:r"))
    }

    func testArchiveRoundTripIsDeterministicAndFailClosedOnSchema() throws {
        let mission = try completedReadyMission()
        let archive = try ForgeMissionArchive(state: mission)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        XCTAssertEqual(try JSONDecoder().decode(ForgeMissionArchive.self, from: data), archive)
        XCTAssertEqual(try encoder.encode(JSONDecoder().decode(ForgeMissionArchive.self, from: data)), data)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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

import AgentDomain
import ForgeMission
import Foundation
import ProjectBrain
import XCTest

final class ForgeMissionTests: XCTestCase {
    func testModelHotSwapPreservesMissionStateAndRejectsOldWorker() throws {
        let fixture = try makeFixture()
        let routeA = MissionWorkerSelection(providerID: "local", modelID: "model-a", acceptedRouteDescriptorID: "route-a", executionEnvironment: "iphone")
        let routeB = MissionWorkerSelection(providerID: "hosted", modelID: "model-b", acceptedRouteDescriptorID: "route-b", executionEnvironment: "cloud")
        let leaseA = MissionWorkerLeaseID(rawValue: uuid(10))
        let leaseB = MissionWorkerLeaseID(rawValue: uuid(11))

        let (runningA, tokenA) = try MissionReducer.startStage(
            fixture.implementID,
            workerSelection: routeA,
            workerLeaseID: leaseA,
            expectedRevision: fixture.snapshot.revision,
            at: instant(2),
            in: fixture.snapshot
        )
        let (runningB, tokenB) = try MissionReducer.rerouteActiveStage(
            to: routeB,
            workerLeaseID: leaseB,
            expectedRevision: runningA.revision,
            at: instant(3),
            in: runningA
        )

        XCTAssertEqual(runningB.missionID, fixture.snapshot.missionID)
        XCTAssertEqual(runningB.projectID, fixture.snapshot.projectID)
        XCTAssertEqual(runningB.constitution, fixture.snapshot.constitution)
        XCTAssertEqual(runningB.brain, fixture.snapshot.brain)
        XCTAssertEqual(runningB.workerSelection, routeB)

        XCTAssertThrowsError(try MissionReducer.acceptWorkerResult(
            MissionWorkerResult(summary: "stale", evidenceIDs: ["old"]),
            token: tokenA,
            at: instant(4),
            in: runningB
        )) { error in
            XCTAssertEqual(error as? MissionMutationError, .staleWorkerResult)
        }

        let accepted = try MissionReducer.acceptWorkerResult(
            MissionWorkerResult(summary: "accepted", evidenceIDs: ["test:green"]),
            token: tokenB,
            at: instant(5),
            in: runningB
        )
        XCTAssertEqual(accepted.status, .ready)
        XCTAssertNil(accepted.activeStageID)
        XCTAssertEqual(accepted.stages.first(where: { $0.id == fixture.implementID })?.acceptedEvidenceIDs, ["test:green"])
    }

    func testCheckpointRoundTripRecoveryInvalidatesPreInterruptionLease() throws {
        let fixture = try makeFixture()
        let route = MissionWorkerSelection(providerID: "local", modelID: "model-a", acceptedRouteDescriptorID: "route-a", executionEnvironment: "iphone")
        let (running, tokenBefore) = try MissionReducer.startStage(
            fixture.implementID,
            workerSelection: route,
            workerLeaseID: MissionWorkerLeaseID(rawValue: uuid(12)),
            expectedRevision: fixture.snapshot.revision,
            at: instant(2),
            in: fixture.snapshot
        )
        let (checkpointed, checkpoint) = try MissionReducer.checkpoint(
            checkpointID: MissionCheckpointID(rawValue: uuid(13)),
            acceptedProjectStateID: "project-state-1",
            evidenceIDs: ["source:sha256"],
            expectedRevision: running.revision,
            at: instant(3),
            in: running
        )

        let data = try JSONEncoder().encode(checkpoint)
        let decoded = try JSONDecoder().decode(MissionCheckpoint.self, from: data)
        XCTAssertEqual(decoded, checkpoint)
        XCTAssertEqual(checkpointed.latestCheckpointID, checkpoint.id)

        let recovered = try MissionReducer.recover(from: decoded, at: instant(4))
        XCTAssertEqual(recovered.status, .interruptedRecoverable)
        XCTAssertNil(recovered.stages.first(where: { $0.id == fixture.implementID })?.workerLeaseID)

        XCTAssertThrowsError(try MissionReducer.acceptWorkerResult(
            MissionWorkerResult(summary: "late", evidenceIDs: []),
            token: tokenBefore,
            at: instant(5),
            in: recovered
        )) { error in
            XCTAssertEqual(error as? MissionMutationError, .staleWorkerResult)
        }

        let (resumed, tokenAfter) = try MissionReducer.resumeActiveStage(
            workerSelection: route,
            workerLeaseID: MissionWorkerLeaseID(rawValue: uuid(14)),
            expectedRevision: recovered.revision,
            at: instant(6),
            in: recovered
        )
        XCTAssertGreaterThan(tokenAfter.attempt, tokenBefore.attempt)
        XCTAssertEqual(resumed.missionID, fixture.snapshot.missionID)
    }

    func testDynamicRepairStageCanBeInsertedAndCycleIsRejected() throws {
        let fixture = try makeFixture()
        let repairID = MissionStageID(rawValue: uuid(20))
        let repair = MissionStage(
            id: repairID,
            title: "Repair runtime crash",
            kind: .repair,
            dependencyIDs: [fixture.implementID]
        )
        let withRepair = try MissionReducer.insertStage(
            repair,
            expectedRevision: fixture.snapshot.revision,
            at: instant(2),
            into: fixture.snapshot
        )
        XCTAssertEqual(withRepair.stages.last?.id, repairID)

        let cyclicID = MissionStageID(rawValue: uuid(21))
        let cyclic = MissionStage(
            id: cyclicID,
            title: "Impossible cycle",
            kind: .test,
            dependencyIDs: [cyclicID]
        )
        XCTAssertThrowsError(try MissionReducer.insertStage(
            cyclic,
            expectedRevision: fixture.snapshot.revision,
            at: instant(3),
            into: fixture.snapshot
        )) { error in
            XCTAssertEqual(error as? MissionMutationError, .cyclicStageGraph)
        }
    }

    func testStaleMissionMutationCannotReplaceNewerState() throws {
        let fixture = try makeFixture()
        let planning = try MissionReducer.setStatus(
            .planning,
            expectedRevision: fixture.snapshot.revision,
            at: instant(2),
            in: fixture.snapshot
        )
        XCTAssertThrowsError(try MissionReducer.setStatus(
            .ready,
            expectedRevision: fixture.snapshot.revision,
            at: instant(3),
            in: planning
        )) { error in
            XCTAssertEqual(
                error as? MissionMutationError,
                .staleRevision(expected: fixture.snapshot.revision, actual: planning.revision)
            )
        }
    }

    private func makeFixture() throws -> (snapshot: MissionSnapshot, implementID: MissionStageID) {
        let projectID = ProjectID(rawValue: uuid(1))
        let missionID = MissionID(rawValue: uuid(2))
        let implementID = MissionStageID(rawValue: uuid(3))
        let brain = ProjectBrainSnapshot(projectID: projectID)
        let constitution = MissionConstitution(
            productGoal: "Build a runnable app",
            projectType: "Forge Runtime app",
            designIntent: "Fast, dark, touch-first",
            targetDevices: ["iPhone 12"],
            orientationPolicy: "portrait",
            requiredCapabilities: ["local-save"],
            explicitNonGoals: ["native unsigned execution"],
            buildDepth: .polished,
            privacyMode: .localOnly,
            performanceTarget: "responsive on iPhone 12",
            accessibilityTarget: "VoiceOver + Dynamic Type",
            persistenceExpectations: "durable mission checkpoints",
            acceptanceJourneys: ["launch -> interact -> relaunch"],
            expectedEvidenceClasses: ["runtime", "tests"]
        )
        let snapshot = try MissionReducer.create(
            missionID: missionID,
            projectID: projectID,
            constitution: constitution,
            stages: [MissionStage(id: implementID, title: "Implement", kind: .implement)],
            brain: brain,
            at: instant(1)
        )
        return (snapshot, implementID)
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private func instant(_ value: Int64) -> AgentInstant {
        AgentInstant(rawValue: value)
    }
}

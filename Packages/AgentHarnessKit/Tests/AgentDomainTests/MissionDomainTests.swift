import AgentDomain
import Foundation
import XCTest

final class MissionDomainTests: XCTestCase {
    func testGraphRejectsMissingDependencyAndCycle() throws {
        let a = MissionStageID()
        let b = MissionStageID()

        XCTAssertThrowsError(try MissionStageGraph(stages: [
            MissionStage(id: a, kind: .implement, title: "Implement", dependencies: [b]),
        ])) { error in
            XCTAssertEqual(
                error as? MissionStageGraphError,
                .missingDependency(stageID: a, dependencyID: b)
            )
        }

        XCTAssertThrowsError(try MissionStageGraph(stages: [
            MissionStage(id: a, kind: .implement, title: "Implement", dependencies: [b]),
            MissionStage(id: b, kind: .test, title: "Test", dependencies: [a]),
        ])) { error in
            XCTAssertEqual(error as? MissionStageGraphError, .dependencyCycle)
        }
    }

    func testGraphDecodeRevalidatesUntrustedPersistedStructure() throws {
        struct UnvalidatedGraph: Encodable {
            let stages: [MissionStage]
        }

        let a = MissionStageID()
        let b = MissionStageID()
        let encoded = try JSONEncoder().encode(UnvalidatedGraph(stages: [
            MissionStage(id: a, kind: .implement, title: "Implement", dependencies: [b]),
            MissionStage(id: b, kind: .test, title: "Test", dependencies: [a]),
        ]))

        XCTAssertThrowsError(try JSONDecoder().decode(MissionStageGraph.self, from: encoded)) { error in
            XCTAssertEqual(error as? MissionStageGraphError, .dependencyCycle)
        }
    }

    func testDependenciesBecomeReadyOnlyAfterAcceptedCompletion() throws {
        let implementID = MissionStageID()
        let testID = MissionStageID()
        var graph = try MissionStageGraph(stages: [
            MissionStage(id: implementID, kind: .implement, title: "Implement"),
            MissionStage(id: testID, kind: .test, title: "Test", dependencies: [implementID]),
        ])
        XCTAssertEqual(graph.readyStageIDs, [implementID])

        let binding = try graph.start(implementID, attemptID: AttemptID())
        XCTAssertNotEqual(graph.stage(id: testID)?.status, .ready)
        try graph.finish(binding, as: .succeeded)
        XCTAssertEqual(graph.stage(id: testID)?.status, .ready)
    }

    func testDeferringOptionalStageUnblocksDependentWork() throws {
        let optionalID = MissionStageID()
        let downstreamID = MissionStageID()
        var graph = try MissionStageGraph(stages: [
            MissionStage(id: optionalID, kind: .visualCritique, title: "Optional visual pass", isRequired: false),
            MissionStage(id: downstreamID, kind: .checkpoint, title: "Checkpoint", dependencies: [optionalID]),
        ])

        XCTAssertEqual(graph.readyStageIDs, [optionalID])
        try graph.deferOptionalStage(optionalID)
        XCTAssertEqual(graph.stage(id: optionalID)?.status, .skipped)
        XCTAssertEqual(graph.stage(id: downstreamID)?.status, .ready)
    }

    func testRecoverableFailureInsertsRepairThenRetestWithoutCycle() throws {
        let implementID = MissionStageID()
        let testID = MissionStageID()
        let repairID = MissionStageID()
        var graph = try MissionStageGraph(stages: [
            MissionStage(id: implementID, kind: .implement, title: "Implement", status: .succeeded),
            MissionStage(id: testID, kind: .test, title: "Test", status: .ready, dependencies: [implementID]),
        ])
        let testBinding = try graph.start(testID, attemptID: AttemptID())
        try graph.finish(testBinding, as: .failedRecoverable)

        _ = try graph.requeueRecoverableStageWithRepair(
            failedStageID: testID,
            repairStageID: repairID,
            repairTitle: "Repair test failure"
        )
        XCTAssertEqual(graph.stage(id: repairID)?.status, .ready)
        XCTAssertEqual(graph.stage(id: testID)?.status, .pending)
        XCTAssertTrue(graph.stage(id: testID)?.dependencies.contains(repairID) == true)

        let repairBinding = try graph.start(repairID, attemptID: AttemptID())
        try graph.finish(repairBinding, as: .succeeded)
        XCTAssertEqual(graph.stage(id: testID)?.status, .ready)
    }

    func testStaleWorkerResultRejectedAfterStageRestart() throws {
        let stageID = MissionStageID()
        let constitution = MissionConstitution(productGoal: "Build a calculator", projectKind: .app)
        let graph = try MissionStageGraph(stages: [
            MissionStage(id: stageID, kind: .implement, title: "Implement"),
        ])
        var mission = try MissionSnapshot(
            projectID: ProjectID(),
            lifecycle: .ready,
            constitution: constitution,
            stageGraph: graph
        )
        let stale = try mission.beginWork(on: stageID, attemptID: AttemptID())
        try mission.finishWork(stale, as: .failedRecoverable)
        _ = try mission.requeueRecoverableStageWithRepair(
            failedStageID: stageID,
            repairTitle: "Repair"
        )

        XCTAssertFalse(mission.accepts(stale))
        XCTAssertThrowsError(try mission.finishWork(stale, as: .succeeded)) { error in
            XCTAssertEqual(error as? MissionSnapshotError, .staleWorkResult(stageID))
        }
    }

    func testWorkerHotSwapSupersedesInFlightAttemptWithoutLosingMissionAuthority() throws {
        let stageID = MissionStageID()
        let constitution = MissionConstitution(
            productGoal: "Build a driving game",
            projectKind: .game3D,
            buildDepth: .obsessive
        )
        let graph = try MissionStageGraph(stages: [
            MissionStage(id: stageID, kind: .design, title: "Design"),
        ])
        let local = MissionWorkerRoute(providerID: "local", modelID: "model-a", routeID: "local-v1")
        let cloud = MissionWorkerRoute(providerID: "cloud", modelID: "model-b", routeID: "hosted-v2")
        var mission = try MissionSnapshot(
            projectID: ProjectID(),
            lifecycle: .ready,
            constitution: constitution,
            stageGraph: graph,
            workerRoute: local
        )
        let originalMissionID = mission.missionID
        let originalProjectID = mission.projectID
        let stale = try mission.beginWork(on: stageID, attemptID: AttemptID())

        try mission.switchWorker(to: cloud)

        XCTAssertEqual(mission.missionID, originalMissionID)
        XCTAssertEqual(mission.projectID, originalProjectID)
        XCTAssertEqual(mission.constitution, constitution)
        XCTAssertEqual(mission.workerRoute, cloud)
        XCTAssertEqual(mission.stageGraph.stage(id: stageID)?.status, .ready)
        XCTAssertFalse(mission.accepts(stale))
        XCTAssertThrowsError(try mission.finishWork(stale, as: .succeeded)) { error in
            XCTAssertEqual(error as? MissionSnapshotError, .staleWorkResult(stageID))
        }
    }

    func testUserPauseInvalidatesActiveAttemptAndResumeMakesStageReady() throws {
        let stageID = MissionStageID()
        let graph = try MissionStageGraph(stages: [
            MissionStage(id: stageID, kind: .implement, title: "Implement"),
        ])
        var mission = try MissionSnapshot(
            projectID: ProjectID(),
            lifecycle: .executing,
            constitution: MissionConstitution(productGoal: "Build app", projectKind: .app),
            stageGraph: graph
        )
        let stale = try mission.beginWork(on: stageID)

        try mission.transitionLifecycle(to: .pausedByUser)
        XCTAssertEqual(mission.stageGraph.stage(id: stageID)?.status, .paused)
        XCTAssertFalse(mission.accepts(stale))

        try mission.transitionLifecycle(to: .ready)
        XCTAssertEqual(mission.stageGraph.stage(id: stageID)?.status, .ready)
    }

    func testCompletionCannotSilentlyIgnoreRequiredStage() throws {
        let stageID = MissionStageID()
        let graph = try MissionStageGraph(stages: [
            MissionStage(id: stageID, kind: .test, title: "Acceptance tests"),
        ])
        var mission = try MissionSnapshot(
            projectID: ProjectID(),
            lifecycle: .executing,
            constitution: MissionConstitution(productGoal: "Build app", projectKind: .app),
            stageGraph: graph
        )

        XCTAssertThrowsError(try mission.transitionLifecycle(to: .completedWithEvidence)) { error in
            XCTAssertEqual(
                error as? MissionSnapshotError,
                .terminalMissionRequiresSatisfiedRequiredStages
            )
        }
    }

    func testMissionSnapshotRoundTripsDeterministically() throws {
        let implementID = MissionStageID()
        let testID = MissionStageID()
        let constitution = MissionConstitution(
            productGoal: "Build a polished offline utility",
            projectKind: .app,
            requiredCapabilities: [
                MissionCapability(identifier: "haptics", displayName: "Haptics"),
                MissionCapability(identifier: "local-save", displayName: "Local Save"),
            ],
            localityPolicy: .localOnly,
            expectedEvidence: [.tests, .runtime, .visual, .accessibility]
        )
        let graph = try MissionStageGraph(stages: [
            MissionStage(id: implementID, kind: .implement, title: "Implement"),
            MissionStage(id: testID, kind: .test, title: "Test", dependencies: [implementID]),
        ])
        let mission = try MissionSnapshot(
            projectID: ProjectID(),
            lifecycle: .ready,
            constitution: constitution,
            stageGraph: graph
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(mission)
        let decoded = try JSONDecoder().decode(MissionSnapshot.self, from: data)

        XCTAssertEqual(decoded, mission)
        XCTAssertEqual(try encoder.encode(decoded), data)
    }

    func testTerminalLifecycleCannotSilentlyResume() throws {
        let constitution = MissionConstitution(productGoal: "Build app", projectKind: .app)
        let graph = try MissionStageGraph(stages: [])
        var mission = try MissionSnapshot(
            projectID: ProjectID(),
            lifecycle: .completedWithEvidence,
            constitution: constitution,
            stageGraph: graph
        )

        XCTAssertThrowsError(try mission.transitionLifecycle(to: .executing)) { error in
            XCTAssertEqual(
                error as? MissionSnapshotError,
                .illegalLifecycleTransition(from: .completedWithEvidence, to: .executing)
            )
        }
    }
}

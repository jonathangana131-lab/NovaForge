import XCTest
@testable import ForgeMission

final class ForgeMissionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testStartAndCompletionAdvancesThroughDependencyGraph() throws {
        let understand = MissionStageID()
        let build = MissionStageID()
        let test = MissionStageID()
        var mission = try makeMission(stages: [
            MissionStage(id: understand, kind: .understand, title: "Understand", updatedAt: t0),
            MissionStage(id: build, kind: .implement, title: "Build", dependencies: [understand], updatedAt: t0),
            MissionStage(id: test, kind: .test, title: "Test", dependencies: [build], updatedAt: t0),
        ])

        try mission.start(at: t0)
        XCTAssertEqual(mission.activeStage?.id, understand)

        try completeActive(&mission, at: t0.addingTimeInterval(1))
        XCTAssertEqual(mission.activeStage?.id, build)

        try completeActive(&mission, at: t0.addingTimeInterval(2))
        XCTAssertEqual(mission.activeStage?.id, test)

        try completeActive(&mission, at: t0.addingTimeInterval(3))
        XCTAssertEqual(mission.lifecycle, .completed)
        XCTAssertNil(mission.activeStage)
    }

    func testSteeringInvalidatesOutstandingWorkerLease() throws {
        var mission = try makeMission()
        try mission.start(at: t0)
        let activeID = try XCTUnwrap(mission.activeStage?.id)
        let issued = try mission.makeWorkLease(for: activeID)

        try mission.steer("Make the runtime landscape-first", at: t0.addingTimeInterval(1))

        XCTAssertThrowsError(
            try mission.acceptWorkerResult(
                MissionWorkerResult(lease: issued, outcome: .completed, evidenceSummary: "Old worker finished"),
                at: t0.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(
                error as? MissionStateError,
                .staleWorkerResult(expectedRevision: mission.revision, receivedRevision: issued.revision)
            )
        }
    }

    func testRouteHotSwapPreservesMissionAndStagesButInvalidatesOldLease() throws {
        var mission = try makeMission()
        try mission.start(at: t0)
        let activeID = try XCTUnwrap(mission.activeStage?.id)
        let lease = try mission.makeWorkLease(for: activeID)
        let originalMissionID = mission.id
        let originalStageIDs = mission.stages.map(\.id)

        let deepRoute = MissionRoute(
            providerID: "openai",
            modelID: "gpt-deep",
            adapterID: "responses-v1",
            executionEnvironment: .cloud
        )
        mission.switchRoute(to: deepRoute, reason: "Escalate blocked architecture step", at: t0.addingTimeInterval(1))

        XCTAssertEqual(mission.id, originalMissionID)
        XCTAssertEqual(mission.stages.map(\.id), originalStageIDs)
        XCTAssertEqual(mission.route, deepRoute)
        XCTAssertEqual(mission.routeTransitions.count, 1)
        XCTAssertThrowsError(
            try mission.acceptWorkerResult(
                MissionWorkerResult(lease: lease, outcome: .completed, evidenceSummary: "Stale model result")
            )
        )
    }

    func testCheckpointRestoreCreatesExplicitForkLineage() throws {
        var mission = try makeMission()
        try mission.start(at: t0)
        let first = mission.checkpoint(summary: "Started mission", at: t0.addingTimeInterval(1))
        try mission.steer("Prefer touch-first controls", at: t0.addingTimeInterval(2))
        let second = mission.checkpoint(summary: "Accepted touch direction", at: t0.addingTimeInterval(3))

        let restored = try mission.restore(to: first.id, at: t0.addingTimeInterval(4))

        XCTAssertEqual(restored.parentID, first.id)
        XCTAssertNotEqual(restored.parentID, second.id)
        XCTAssertEqual(mission.lifecycle, .paused)
        XCTAssertEqual(mission.checkpoints.count, 3)
        XCTAssertEqual(mission.checkpoints[0], first)
        XCTAssertEqual(mission.checkpoints[1], second)
    }

    func testDynamicStageInsertionRejectsDependencyCycleWithoutMutation() throws {
        var mission = try makeMission()
        let before = mission
        let firstID = MissionStageID()
        let secondID = MissionStageID()
        let first = MissionStage(
            id: firstID,
            kind: .design,
            title: "Design",
            dependencies: [secondID],
            updatedAt: t0
        )
        let second = MissionStage(
            id: secondID,
            kind: .implement,
            title: "Build",
            dependencies: [firstID],
            updatedAt: t0
        )

        XCTAssertThrowsError(try mission.insertStages([first, second], now: t0)) { error in
            XCTAssertEqual(error as? MissionStateError, .dependencyCycle)
        }
        XCTAssertEqual(mission, before)
    }

    func testMissingDependencyIsRejectedAtConstruction() {
        XCTAssertThrowsError(
            try makeMission(stages: [
                MissionStage(
                    kind: .implement,
                    title: "Build",
                    dependencies: [MissionStageID()],
                    updatedAt: t0
                ),
            ])
        ) { error in
            guard case MissionStateError.missingDependency = error else {
                return XCTFail("Expected missingDependency, got \(error)")
            }
        }
    }

    func testCodableRoundTripPreservesMissionIndependentOfTranscript() throws {
        var mission = try makeMission()
        try mission.start(at: t0)
        try mission.steer("Keep the accepted product intent concise", at: t0.addingTimeInterval(1))
        _ = mission.checkpoint(summary: "Durable accepted state", at: t0.addingTimeInterval(2))

        let encoded = try JSONEncoder().encode(mission)
        let decoded = try JSONDecoder().decode(ForgeMissionState.self, from: encoded)

        XCTAssertEqual(decoded, mission)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("chain-of-thought"))
    }

    func testPauseResumeInvalidatesLeaseAndContinuesSameMission() throws {
        var mission = try makeMission()
        try mission.start(at: t0)
        let activeID = try XCTUnwrap(mission.activeStage?.id)
        let lease = try mission.makeWorkLease(for: activeID)
        let missionID = mission.id

        try mission.pause(at: t0.addingTimeInterval(1))
        XCTAssertEqual(mission.lifecycle, .paused)
        try mission.resume(at: t0.addingTimeInterval(2))
        XCTAssertEqual(mission.lifecycle, .running)
        XCTAssertEqual(mission.id, missionID)
        XCTAssertEqual(mission.activeStage?.id, activeID)

        XCTAssertThrowsError(
            try mission.acceptWorkerResult(
                MissionWorkerResult(lease: lease, outcome: .completed, evidenceSummary: "Result from before pause")
            )
        )
    }

    func testNeedsDecisionRequiresExplicitSteeringBeforeRetry() throws {
        var mission = try makeMission()
        try mission.start(at: t0)
        let active = try XCTUnwrap(mission.activeStage)
        let lease = try mission.makeWorkLease(for: active.id)

        try mission.acceptWorkerResult(
            MissionWorkerResult(lease: lease, outcome: .needsDecision, evidenceSummary: "Choose A or B"),
            at: t0.addingTimeInterval(1)
        )

        XCTAssertEqual(mission.lifecycle, .waitingForDecision)
        XCTAssertEqual(mission.stages.first?.status, .blocked)
        XCTAssertNil(mission.activeStage)

        try mission.retryBlockedStage(
            active.id,
            steeringInstruction: "Choose the simpler safe implementation",
            at: t0.addingTimeInterval(2)
        )
        XCTAssertEqual(mission.lifecycle, .running)
        XCTAssertEqual(mission.activeStage?.id, active.id)
        XCTAssertEqual(mission.steeringNotes.last?.instruction, "Choose the simpler safe implementation")
    }

    private func completeActive(_ mission: inout ForgeMissionState, at date: Date) throws {
        let stage = try XCTUnwrap(mission.activeStage)
        let lease = try mission.makeWorkLease(for: stage.id)
        try mission.acceptWorkerResult(
            MissionWorkerResult(lease: lease, outcome: .completed, evidenceSummary: "Verified \(stage.title)"),
            at: date
        )
    }

    private func makeMission(stages: [MissionStage]? = nil) throws -> ForgeMissionState {
        let defaultStages: [MissionStage]
        if let stages {
            defaultStages = stages
        } else {
            defaultStages = [MissionStage(kind: .implement, title: "Build", updatedAt: t0)]
        }
        return try ForgeMissionState(
            createdAt: t0,
            intent: "Build a polished runnable project",
            constitution: MissionConstitution(
                functionality: ["Build", "Run", "Improve"],
                runnability: "Runs in Forge Runtime",
                designTarget: "Touch-first",
                orientationTarget: "Adaptive",
                capabilities: ["local save"],
                performanceTarget: "Responsive on iPhone 12",
                accessibilityTarget: "VoiceOver and Reduce Motion",
                persistenceTarget: "Durable checkpoints"
            ),
            stages: defaultStages,
            route: MissionRoute(
                providerID: "local",
                modelID: "coder-default",
                adapterID: "local-single-call-tools",
                executionEnvironment: .onDevice
            )
        )
    }
}

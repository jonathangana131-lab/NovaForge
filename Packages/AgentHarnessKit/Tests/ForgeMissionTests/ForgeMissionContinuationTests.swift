import XCTest
@testable import ForgeMission

final class ForgeMissionContinuationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAddingWorkToCompletedMissionReopensItAndActivatesNewStage() throws {
        var mission = try makeMission()
        try mission.start(at: t0)
        let active = try XCTUnwrap(mission.activeStage)
        let lease = try mission.makeWorkLease(for: active.id)
        try mission.acceptWorkerResult(
            MissionWorkerResult(lease: lease, outcome: .completed, evidenceSummary: "Initial work verified"),
            at: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(mission.lifecycle, .completed)

        let improveID = MissionStageID()
        try mission.insertStages([
            MissionStage(id: improveID, kind: .polish, title: "Improve", updatedAt: t0.addingTimeInterval(2)),
        ], now: t0.addingTimeInterval(2))

        XCTAssertEqual(mission.lifecycle, .running)
        XCTAssertEqual(mission.activeStage?.id, improveID)
        XCTAssertNoThrow(try ForgeMissionArchive(state: mission))
    }

    func testCancelledMissionRejectsNewStageInsertion() throws {
        var mission = try makeMission()
        try mission.start(at: t0)
        try mission.cancel(at: t0.addingTimeInterval(1))
        let before = mission

        XCTAssertThrowsError(
            try mission.insertStages([
                MissionStage(kind: .polish, title: "Unexpected continuation", updatedAt: t0.addingTimeInterval(2)),
            ], now: t0.addingTimeInterval(2))
        )
        XCTAssertEqual(mission, before)
    }

    private func makeMission() throws -> ForgeMissionState {
        try ForgeMissionState(
            createdAt: t0,
            intent: "Build then improve a durable app",
            constitution: MissionConstitution(
                functionality: ["Build", "Improve"],
                runnability: "Forge Runtime",
                designTarget: "Touch-first",
                orientationTarget: "Adaptive",
                capabilities: ["local save"],
                performanceTarget: "iPhone 12 responsive",
                accessibilityTarget: "VoiceOver",
                persistenceTarget: "Durable checkpoints"
            ),
            stages: [MissionStage(kind: .implement, title: "Build", updatedAt: t0)],
            route: MissionRoute(
                providerID: "local",
                modelID: "coder-default",
                adapterID: "local-single-call-tools",
                executionEnvironment: .onDevice
            )
        )
    }
}

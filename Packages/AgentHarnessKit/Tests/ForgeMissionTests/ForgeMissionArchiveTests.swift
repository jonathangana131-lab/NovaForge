import XCTest
@testable import ForgeMission

final class ForgeMissionArchiveTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testArchiveRoundTripPreservesAcceptedMissionState() throws {
        var mission = try makeMission()
        try mission.start(at: t0)
        try mission.steer("Keep the design touch-first", at: t0.addingTimeInterval(1))
        _ = mission.checkpoint(summary: "Accepted first checkpoint", at: t0.addingTimeInterval(2))

        let archive = try ForgeMissionArchive(state: mission)
        let data = try JSONEncoder().encode(archive)
        let decoded = try JSONDecoder().decode(ForgeMissionArchive.self, from: data)

        XCTAssertEqual(decoded, archive)
        XCTAssertEqual(decoded.schemaVersion, ForgeMissionArchive.currentSchemaVersion)
        XCTAssertEqual(decoded.state.id, mission.id)
    }

    func testArchiveRejectsUnsupportedSchemaVersion() throws {
        let archive = try ForgeMissionArchive(state: makeMission())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        object["schemaVersion"] = ForgeMissionArchive.currentSchemaVersion + 1
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeMissionArchive.self, from: tampered)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    func testArchiveRejectsDuplicateStageIDsAfterPersistenceTamper() throws {
        let firstID = MissionStageID()
        let secondID = MissionStageID()
        let mission = try makeMission(stages: [
            MissionStage(id: firstID, kind: .design, title: "Design", updatedAt: t0),
            MissionStage(id: secondID, kind: .implement, title: "Build", dependencies: [firstID], updatedAt: t0),
        ])
        let archive = try ForgeMissionArchive(state: mission)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        var state = try XCTUnwrap(object["state"] as? [String: Any])
        var stages = try XCTUnwrap(state["stages"] as? [[String: Any]])
        stages[1]["id"] = stages[0]["id"]
        state["stages"] = stages
        object["state"] = state
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeMissionArchive.self, from: tampered)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    func testArchiveRejectsCheckpointFromAnotherMission() throws {
        var mission = try makeMission()
        try mission.start(at: t0)
        _ = mission.checkpoint(summary: "Accepted", at: t0.addingTimeInterval(1))
        let archive = try ForgeMissionArchive(state: mission)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        var state = try XCTUnwrap(object["state"] as? [String: Any])
        var checkpoints = try XCTUnwrap(state["checkpoints"] as? [[String: Any]])
        checkpoints[0]["missionID"] = ["rawValue": UUID().uuidString]
        state["checkpoints"] = checkpoints
        object["state"] = state
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeMissionArchive.self, from: tampered)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    private func makeMission(stages: [MissionStage]? = nil) throws -> ForgeMissionState {
        try ForgeMissionState(
            createdAt: t0,
            intent: "Build a durable app",
            constitution: MissionConstitution(
                functionality: ["Build", "Run"],
                runnability: "Forge Runtime",
                designTarget: "Touch-first",
                orientationTarget: "Adaptive",
                capabilities: ["local save"],
                performanceTarget: "iPhone 12 responsive",
                accessibilityTarget: "VoiceOver",
                persistenceTarget: "Durable checkpoints"
            ),
            stages: stages ?? [MissionStage(kind: .implement, title: "Build", updatedAt: t0)],
            route: MissionRoute(
                providerID: "local",
                modelID: "coder-default",
                adapterID: "local-single-call-tools",
                executionEnvironment: .onDevice
            )
        )
    }
}

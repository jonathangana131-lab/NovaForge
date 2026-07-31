import XCTest
@testable import VoltlineGame

@MainActor
final class MissionSystemTests: XCTestCase {
    func testMissionCatalogHasUniqueStableIDs() {
        let ids = VoltlineMission.catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(VoltlineMission.catalog.count, 7)
    }

    func testRouteProgressAdvancesReachedCheckpointOnly() {
        let checkpoints = [
            MissionCheckpoint(id: "one", x: 0, z: 10, radiusMeters: 3, title: "One"),
            MissionCheckpoint(id: "two", x: 0, z: 20, radiusMeters: 3, title: "Two")
        ]

        XCTAssertEqual(
            MissionDirector.routeProgress(
                positionX: 0,
                positionZ: 10,
                checkpoints: checkpoints,
                startingIndex: 0
            ),
            1
        )
        XCTAssertEqual(
            MissionDirector.routeProgress(
                positionX: 0,
                positionZ: 16,
                checkpoints: checkpoints,
                startingIndex: 1
            ),
            1
        )
        XCTAssertEqual(
            MissionDirector.routeProgress(
                positionX: 0,
                positionZ: 20,
                checkpoints: checkpoints,
                startingIndex: 1
            ),
            2
        )
    }

    func testRouteProgressCanConsumeOverlappingCheckpoints() {
        let checkpoints = [
            MissionCheckpoint(id: "one", x: 0, z: 10, radiusMeters: 5, title: "One"),
            MissionCheckpoint(id: "two", x: 0, z: 12, radiusMeters: 5, title: "Two")
        ]

        XCTAssertEqual(
            MissionDirector.routeProgress(
                positionX: 0,
                positionZ: 11,
                checkpoints: checkpoints,
                startingIndex: 0
            ),
            2
        )
    }

    func testMissionRewardsArePositive() {
        XCTAssertTrue(VoltlineMission.catalog.allSatisfy { $0.reward > 0 })
        XCTAssertTrue(VoltlineMission.catalog.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
    }
}

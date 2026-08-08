import AgentDomain
import XCTest

final class MissionStageGraphAdversarialTests: XCTestCase {
    func testEmptyGraphCanRepresentPlanningButNeverSatisfiedWork() {
        let graph = MissionStageGraph(missionID: MissionID(), stages: [])

        XCTAssertNil(graph.validationError)
        XCTAssertFalse(graph.requiredWorkIsSatisfied)
    }

    func testHardDependencyCannotPointAtDeferrableOptionalStage() {
        let missionID = MissionID()
        let optionalID = MissionStageID()
        let requiredID = MissionStageID()
        let graph = MissionStageGraph(
            missionID: missionID,
            stages: [
                MissionStage(
                    stageID: optionalID,
                    kind: .custom,
                    title: "Optional experiment",
                    order: 1,
                    required: false
                ),
                MissionStage(
                    stageID: requiredID,
                    kind: .test,
                    title: "Required acceptance",
                    order: 2,
                    required: true,
                    dependencies: [optionalID]
                ),
            ]
        )

        XCTAssertEqual(graph.validationError, .deferrableDependency)
    }
}

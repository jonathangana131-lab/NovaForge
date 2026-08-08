import AgentDomain
import XCTest

final class MissionStageGraphAdversarialTests: XCTestCase {
    func testEmptyMissionGraphFailsClosed() {
        let graph = MissionStageGraph(
            missionID: MissionID(),
            stages: []
        )

        XCTAssertEqual(graph.validationError, .emptyGraph)
    }

    func testAllOptionalGraphCannotVacuouslySatisfyRequiredWork() {
        let graph = MissionStageGraph(
            missionID: MissionID(),
            stages: [
                MissionStage(
                    stageID: MissionStageID(),
                    kind: .polish,
                    title: "Optional polish",
                    order: 1,
                    required: false,
                    status: .deferred
                ),
            ]
        )

        XCTAssertNil(graph.validationError)
        XCTAssertFalse(graph.requiredWorkIsSatisfied)
    }

    func testRequiredStageCannotHardDependOnDeferrableOptionalStage() {
        let missionID = MissionID()
        let optionalID = MissionStageID()
        let requiredID = MissionStageID()
        let graph = MissionStageGraph(
            missionID: missionID,
            stages: [
                MissionStage(
                    stageID: optionalID,
                    kind: .polish,
                    title: "Optional polish",
                    order: 1,
                    required: false
                ),
                MissionStage(
                    stageID: requiredID,
                    kind: .run,
                    title: "Required run",
                    order: 2,
                    dependencies: [optionalID]
                ),
            ]
        )

        XCTAssertEqual(graph.validationError, .requiredStageDependsOnOptionalStage)
    }

    func testOptionalStageMayDependOnAnotherOptionalStage() {
        let missionID = MissionID()
        let firstID = MissionStageID()
        let secondID = MissionStageID()
        let graph = MissionStageGraph(
            missionID: missionID,
            stages: [
                MissionStage(
                    stageID: firstID,
                    kind: .inspect,
                    title: "Optional inspection",
                    order: 1,
                    required: false
                ),
                MissionStage(
                    stageID: secondID,
                    kind: .polish,
                    title: "Optional polish",
                    order: 2,
                    required: false,
                    dependencies: [firstID]
                ),
            ]
        )

        XCTAssertNil(graph.validationError)
    }
}

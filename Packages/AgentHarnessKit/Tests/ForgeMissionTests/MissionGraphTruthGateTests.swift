import AgentDomain
import ForgeMission
import XCTest

final class MissionGraphTruthGateTests: XCTestCase {
    func testMissionConstructorRejectsEmptyStageGraph() {
        let missionID = MissionID()
        let projectID = ProjectID()
        let constitution = MissionConstitution(
            missionID: missionID,
            projectID: projectID,
            acceptedAt: AgentInstant(rawValue: 1),
            productGoal: "Build a runnable app",
            projectType: "app"
        )

        XCTAssertThrowsError(try ForgeMissionState(
            constitution: constitution,
            graph: MissionStageGraph(missionID: missionID, stages: []),
            route: MissionRouteBinding(routeReceiptID: "route:local:1")
        )) { error in
            XCTAssertEqual(error as? ForgeMissionError, .invalidGraph)
        }
    }

    func testMissionConstructorRejectsRequiredStageDependingOnDeferrableStage() {
        let missionID = MissionID()
        let projectID = ProjectID()
        let optionalID = MissionStageID()
        let requiredID = MissionStageID()
        let constitution = MissionConstitution(
            missionID: missionID,
            projectID: projectID,
            acceptedAt: AgentInstant(rawValue: 1),
            productGoal: "Build a runnable app",
            projectType: "app"
        )
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

        XCTAssertThrowsError(try ForgeMissionState(
            constitution: constitution,
            graph: graph,
            route: MissionRouteBinding(routeReceiptID: "route:local:1")
        )) { error in
            XCTAssertEqual(error as? ForgeMissionError, .invalidGraph)
        }
    }
}

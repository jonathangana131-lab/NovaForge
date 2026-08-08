import AgentDomain
import ForgeMission
import XCTest

final class MissionRequiredWorkTruthTests: XCTestCase {
    func testAllOptionalMissionCannotCompleteAfterDeferringEverything() throws {
        let missionID = MissionID()
        let projectID = ProjectID()
        let optionalID = MissionStageID()
        var mission = try ForgeMissionState(
            constitution: MissionConstitution(
                missionID: missionID,
                projectID: projectID,
                acceptedAt: AgentInstant(rawValue: 1),
                productGoal: "Build a runnable app",
                projectType: "app"
            ),
            graph: MissionStageGraph(
                missionID: missionID,
                stages: [
                    MissionStage(
                        stageID: optionalID,
                        kind: .polish,
                        title: "Optional polish",
                        order: 1,
                        required: false
                    ),
                ]
            ),
            route: MissionRouteBinding(routeReceiptID: "route:local:1")
        )

        try mission.deferOptionalStage(optionalID)
        _ = try mission.checkpoint(
            acceptedProjectStateID: "state:no-required-work",
            evidenceReceiptIDs: MissionStringSet(["checkpoint:no-required-work"]),
            summary: "All optional work deferred",
            at: AgentInstant(rawValue: 2)
        )

        let evidence = MissionCompletionEvidence(
            acceptedProjectStateID: "state:no-required-work",
            evidenceClasses: MissionEvidenceSet([]),
            receiptIDs: MissionStringSet(["completion:no-required-work"]),
            acceptedAt: AgentInstant(rawValue: 3)
        )

        XCTAssertFalse(mission.graph.requiredWorkIsSatisfied)
        XCTAssertThrowsError(try mission.complete(with: evidence)) { error in
            XCTAssertEqual(
                error as? ForgeMissionError,
                .completionRequiresSatisfiedRequiredWork
            )
        }
    }
}

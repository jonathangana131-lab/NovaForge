import AgentDomain
import ForgeMission
import XCTest

/// Review-only regression for PR #110.
///
/// Accepted evidence is keyed by MissionStageID, so a graph revision must not be able to
/// redefine the semantic work behind an already-accepted ID while retaining its status.
final class MissionStageSemanticIdentityReviewTests: XCTestCase {
    func testCompletedStageCannotBeRelabeledWhileKeepingAcceptedEvidence() throws {
        let missionID = MissionID()
        let projectID = ProjectID()
        let stageID = MissionStageID()
        var mission = try ForgeMissionState(
            constitution: MissionConstitution(
                missionID: missionID,
                projectID: projectID,
                revision: 1,
                acceptedAt: AgentInstant(rawValue: 1),
                productGoal: "Build a runnable app",
                projectType: "app",
                expectedEvidence: .init([.runtimeTested])
            ),
            graph: MissionStageGraph(
                missionID: missionID,
                stages: [
                    MissionStage(
                        stageID: stageID,
                        kind: .implement,
                        title: "Implement",
                        order: 1
                    )
                ]
            ),
            route: .init(routeReceiptID: "route:review")
        )

        let lease = try XCTUnwrap(try mission.beginWork(on: [stageID]).first)
        try mission.acceptWorkerResult(
            .init(
                lease: lease,
                outcome: .completed,
                summary: "Implementation accepted",
                evidenceReceiptIDs: .init(["receipt:implementation"])
            ),
            at: AgentInstant(rawValue: 2)
        )
        XCTAssertEqual(mission.stageEvidence.count, 1)
        XCTAssertEqual(mission.stageEvidence[0].stageID, stageID)

        let relabeled = MissionStageGraph(
            missionID: missionID,
            revision: mission.graph.revision + 1,
            stages: [
                MissionStage(
                    stageID: stageID,
                    kind: .accessibility,
                    title: "Accessibility acceptance",
                    order: 1,
                    required: true,
                    status: .completed
                )
            ]
        )

        XCTAssertThrowsError(try mission.replaceStageGraph(relabeled))
        XCTAssertEqual(mission.graph.stages[0].kind, .implement)
        XCTAssertEqual(mission.graph.stages[0].title, "Implement")
        XCTAssertEqual(mission.stageEvidence[0].receiptIDs.values, ["receipt:implementation"])
    }
}

import AgentDomain
import ForgeMission
import XCTest

/// Review-only reproducer for PR #110. This file intentionally demonstrates the
/// current unsafe behavior; it is not a merge-candidate regression until the reducer
/// is hardened and these assertions are inverted to require rejection.
final class MissionStageSemanticIdentityReviewTests: XCTestCase {
    func testCurrentHeadRelabelsCompletedStageWhileKeepingAcceptedEvidence() throws {
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

        XCTAssertNoThrow(try mission.replaceStageGraph(relabeled))
        XCTAssertEqual(mission.graph.stages[0].kind, .accessibility)
        XCTAssertEqual(mission.graph.stages[0].title, "Accessibility acceptance")
        XCTAssertEqual(mission.graph.stages[0].status, .completed)

        // The receipt was accepted for implementation work but remains attached only by
        // stage ID after that ID has been redefined as accessibility acceptance.
        XCTAssertEqual(mission.stageEvidence[0].stageID, stageID)
        XCTAssertEqual(mission.stageEvidence[0].receiptIDs.values, ["receipt:implementation"])
        XCTAssertEqual(mission.workerReceipts.last?.stageID, stageID)
        XCTAssertEqual(mission.workerReceipts.last?.evidenceReceiptIDs.values, ["receipt:implementation"])
    }
}

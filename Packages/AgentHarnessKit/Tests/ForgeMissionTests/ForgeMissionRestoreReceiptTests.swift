import AgentDomain
import XCTest

@testable import ForgeMission

final class ForgeMissionRestoreReceiptTests: XCTestCase {
  func testVerifiedRestoreRejectsTamperedEvidenceReceiptListWithoutMovingCheckpoint() throws {
    let now = AgentInstant(rawValue: 1_800_000_000_000)
    let missionID = MissionID()
    let projectID = ProjectID()
    let constitution = MissionConstitution(
      missionID: missionID,
      projectID: projectID,
      acceptedAt: now,
      productGoal: "Build a polished app",
      projectType: "Forge Runtime app"
    )
    let graph = MissionStageGraph(
      missionID: missionID,
      stages: [
        MissionStage(stageID: MissionStageID(), kind: .implement, title: "Build", order: 1)
      ]
    )
    var state = try ForgeMissionState(
      constitution: constitution,
      graph: graph,
      acceptedRouteDescriptorID: AcceptedRouteDescriptorID(rawValue: "route-1")!
    )
    let projectState = AcceptedProjectStateID(rawValue: "project-state-42")!
    let checkpoint = state.checkpoint(
      acceptedProjectStateID: projectState,
      evidenceReceiptIDs: [MissionEvidenceReceiptID(rawValue: "evidence-7")!],
      summary: "Accepted build",
      at: now
    )
    let request = try state.prepareRestore(to: checkpoint.id)
    let tampered = MissionRestoreRequest(
      checkpointID: request.checkpointID,
      missionID: request.missionID,
      projectID: request.projectID,
      acceptedProjectStateID: request.acceptedProjectStateID,
      evidenceReceiptIDs: [MissionEvidenceReceiptID(rawValue: "substituted-evidence")!]
    )

    XCTAssertThrowsError(
      try state.acceptVerifiedRestore(tampered, verifiedProjectStateID: projectState)
    ) { error in
      XCTAssertEqual(error as? ForgeMissionError, .restoreReceiptMismatch)
    }
    XCTAssertEqual(state.activeCheckpointID, checkpoint.id)
  }
}

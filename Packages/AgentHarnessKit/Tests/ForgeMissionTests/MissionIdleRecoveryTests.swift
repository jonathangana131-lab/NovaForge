import AgentDomain
import ForgeMission
import Foundation
import ProjectBrain
import XCTest

final class MissionIdleRecoveryTests: XCTestCase {
    func testCheckpointRecoveryWithoutActiveWorkPreservesReadyState() throws {
        let projectID = ProjectID(rawValue: uuid(40))
        let missionID = MissionID(rawValue: uuid(41))
        let stageID = MissionStageID(rawValue: uuid(42))
        let constitution = MissionConstitution(
            productGoal: "Build a runnable app",
            projectType: "Forge Runtime app",
            designIntent: "Touch-first",
            targetDevices: ["iPhone 12"],
            orientationPolicy: "portrait",
            requiredCapabilities: [],
            explicitNonGoals: [],
            buildDepth: .polished,
            privacyMode: .localOnly,
            performanceTarget: "responsive",
            accessibilityTarget: "VoiceOver",
            persistenceExpectations: "durable checkpoints",
            acceptanceJourneys: [],
            expectedEvidenceClasses: []
        )
        let draft = try MissionReducer.create(
            missionID: missionID,
            projectID: projectID,
            constitution: constitution,
            stages: [MissionStage(id: stageID, title: "Implement", kind: .implement)],
            brain: ProjectBrainSnapshot(projectID: projectID),
            at: instant(1)
        )
        let planning = try MissionReducer.transition(
            to: .planning,
            expectedRevision: draft.revision,
            at: instant(1),
            in: draft
        )
        let ready = try MissionReducer.transition(
            to: .ready,
            expectedRevision: planning.revision,
            at: instant(1),
            in: planning
        )
        let (_, checkpoint) = try MissionReducer.checkpoint(
            checkpointID: MissionCheckpointID(rawValue: uuid(43)),
            acceptedProjectStateID: "ready-state",
            evidenceIDs: [],
            expectedRevision: ready.revision,
            at: instant(2),
            in: ready
        )

        let recovered = try MissionReducer.recover(
            from: checkpoint,
            expectedMissionID: missionID,
            expectedProjectID: projectID,
            at: instant(3)
        )

        XCTAssertEqual(recovered.status, .ready)
        XCTAssertNil(recovered.activeStageID)
        XCTAssertGreaterThan(recovered.revision, checkpoint.snapshot.revision)
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private func instant(_ value: Int64) -> AgentInstant {
        AgentInstant(rawValue: value)
    }
}

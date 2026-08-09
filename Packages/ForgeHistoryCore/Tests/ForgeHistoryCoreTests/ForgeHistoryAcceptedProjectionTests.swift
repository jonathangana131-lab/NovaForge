import ForgeHistoryCore
import XCTest

final class ForgeHistoryAcceptedProjectionTests: XCTestCase {
    func testAcceptedProjectStateIdentityRequiresAlreadyCanonicalOpaqueValue() throws {
        let canonical = "/tmp/project state#1\nsegment"
        XCTAssertEqual(try ForgeHistoryAcceptedProjectStateID(canonical).rawValue, canonical)
        for alias in [" state", "state ", "\nstate", "state\t", "   \n"] {
            XCTAssertThrowsError(try ForgeHistoryAcceptedProjectStateID(alias)) { error in
                XCTAssertEqual(error as? ForgeHistoryAcceptedProjectionError, .invalidAcceptedProjectStateID)
            }
        }
    }

    func testProjectorRejectsCrossProjectCheckpointBinding() throws {
        let expectedProject = try ForgeHistoryProjectID("project-a")
        let otherProject = try ForgeHistoryProjectID("project-b")
        let checkpoint = try makeCheckpoint("c1", sequence: 1)
        let binding = ForgeHistoryAcceptedCheckpointBinding(
            projectID: otherProject,
            acceptedProjectStateID: try ForgeHistoryAcceptedProjectStateID("state-1"),
            checkpoint: checkpoint
        )
        XCTAssertThrowsError(
            try ForgeHistoryAcceptedTimelineProjector.project(
                projectID: expectedProject,
                acceptedCheckpoints: [binding]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryAcceptedProjectionError,
                .projectMismatch(checkpointID: "c1", expectedProjectID: "project-a", actualProjectID: "project-b")
            )
        }
    }

    func testProjectorRetainsAcceptedProjectStateIdentityInCanonicalTimelineOrder() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let first = try makeCheckpoint("c1", sequence: 1)
        let second = try makeCheckpoint("c2", parent: first.id, sequence: 2)
        let projection = try ForgeHistoryAcceptedTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                .init(projectID: project, acceptedProjectStateID: try .init("state-2"), checkpoint: second),
                .init(projectID: project, acceptedProjectStateID: try .init("state-1"), checkpoint: first),
            ]
        )
        XCTAssertEqual(projection.timeline.checkpoints.map(\.id.rawValue), ["c1", "c2"])
        XCTAssertEqual(projection.acceptedProjectStates.map(\.checkpointID.rawValue), ["c1", "c2"])
        XCTAssertEqual(projection.acceptedProjectStates.map(\.acceptedProjectStateID.rawValue), ["state-1", "state-2"])
        XCTAssertEqual(projection.acceptedProjectStateID(for: second.id)?.rawValue, "state-2")
    }

    func testProjectWideProjectionAllowsAcceptedCheckpointsAcrossMissions() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let missionA = try ForgeHistoryMissionID("mission-a")
        let missionB = try ForgeHistoryMissionID("mission-b")
        let first = try makeCheckpoint("c1", missionID: missionA, sequence: 1)
        let second = try makeCheckpoint("c2", parent: first.id, missionID: missionB, sequence: 2)
        let projection = try ForgeHistoryAcceptedTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                .init(projectID: project, acceptedProjectStateID: try .init("state-2"), checkpoint: second),
                .init(projectID: project, acceptedProjectStateID: try .init("state-1"), checkpoint: first),
            ]
        )
        XCTAssertNil(projection.timeline.missionID)
        XCTAssertEqual(projection.timeline.checkpoints.map(\.originatingMissionID?.rawValue), ["mission-a", "mission-b"])
    }

    func testProjectorRejectsDuplicateBindingBeforeTimelineProjection() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let checkpoint = try makeCheckpoint("c1", sequence: 1)
        let first = ForgeHistoryAcceptedCheckpointBinding(projectID: project, acceptedProjectStateID: try .init("state-1"), checkpoint: checkpoint)
        let second = ForgeHistoryAcceptedCheckpointBinding(projectID: project, acceptedProjectStateID: try .init("state-2"), checkpoint: checkpoint)
        XCTAssertThrowsError(
            try ForgeHistoryAcceptedTimelineProjector.project(projectID: project, acceptedCheckpoints: [first, second])
        ) { error in
            XCTAssertEqual(error as? ForgeHistoryAcceptedProjectionError, .duplicateCheckpointBinding("c1"))
        }
    }

    func testCanonicalMissionScopeAndDuplicateSequenceValidationRemainFailClosed() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let expectedMission = try ForgeHistoryMissionID("mission-a")
        let otherMission = try ForgeHistoryMissionID("mission-b")
        let otherCheckpoint = try makeCheckpoint("c1", missionID: otherMission, sequence: 1)
        XCTAssertThrowsError(
            try ForgeHistoryAcceptedTimelineProjector.project(
                projectID: project,
                missionID: expectedMission,
                acceptedCheckpoints: [.init(projectID: project, acceptedProjectStateID: try .init("state-1"), checkpoint: otherCheckpoint)]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryError,
                .missionScopeMismatch(checkpointID: "c1", expectedMissionID: "mission-a", actualMissionID: "mission-b")
            )
        }

        let first = try makeCheckpoint("c2", sequence: 2)
        let second = try makeCheckpoint("c3", sequence: 2)
        XCTAssertThrowsError(
            try ForgeHistoryAcceptedTimelineProjector.project(
                projectID: project,
                acceptedCheckpoints: [
                    .init(projectID: project, acceptedProjectStateID: try .init("state-2"), checkpoint: first),
                    .init(projectID: project, acceptedProjectStateID: try .init("state-3"), checkpoint: second),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeHistoryError, .duplicateSequence(2))
        }
    }

    func testUnknownCheckpointLookupDoesNotInventBinding() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let checkpoint = try makeCheckpoint("c1", sequence: 1)
        let projection = try ForgeHistoryAcceptedTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [.init(projectID: project, acceptedProjectStateID: try .init("state-1"), checkpoint: checkpoint)]
        )
        XCTAssertNil(projection.acceptedProjectStateID(for: try ForgeHistoryCheckpointID("ghost")))
    }

    private func makeCheckpoint(
        _ rawID: String,
        parent: ForgeHistoryCheckpointID? = nil,
        missionID: ForgeHistoryMissionID? = nil,
        sequence: UInt64
    ) throws -> ForgeHistoryCheckpoint {
        try ForgeHistoryCheckpoint(
            id: ForgeHistoryCheckpointID(rawID),
            parentID: parent,
            originatingMissionID: missionID,
            sequence: sequence,
            acceptedAtMilliseconds: Int64(sequence * 100),
            title: "Checkpoint \(rawID)"
        )
    }
}

import ForgeHistoryCore
import Foundation
import XCTest

final class ForgeHistoryAcceptedProjectionTests: XCTestCase {
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
                .projectMismatch(
                    checkpointID: "c1",
                    expectedProjectID: "project-a",
                    actualProjectID: "project-b"
                )
            )
        }
    }

    func testProjectorRetainsAcceptedProjectStateIdentityInTimelineOrder() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let first = try makeCheckpoint("c1", sequence: 1)
        let second = try makeCheckpoint("c2", parent: first.id, sequence: 2)
        let projection = try ForgeHistoryAcceptedTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                .init(
                    projectID: project,
                    acceptedProjectStateID: try .init("state-2"),
                    checkpoint: second
                ),
                .init(
                    projectID: project,
                    acceptedProjectStateID: try .init("state-1"),
                    checkpoint: first
                ),
            ]
        )

        XCTAssertEqual(projection.timeline.checkpoints.map(\.id.rawValue), ["c1", "c2"])
        XCTAssertEqual(
            projection.acceptedProjectStates.map(\.acceptedProjectStateID.rawValue),
            ["state-1", "state-2"]
        )
        XCTAssertEqual(
            projection.acceptedProjectStateID(for: second.id)?.rawValue,
            "state-2"
        )
    }

    func testProjectorRejectsDuplicateBindingBeforeTimelineProjection() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let checkpoint = try makeCheckpoint("c1", sequence: 1)
        let first = ForgeHistoryAcceptedCheckpointBinding(
            projectID: project,
            acceptedProjectStateID: try .init("state-1"),
            checkpoint: checkpoint
        )
        let second = ForgeHistoryAcceptedCheckpointBinding(
            projectID: project,
            acceptedProjectStateID: try .init("state-2"),
            checkpoint: checkpoint
        )

        XCTAssertThrowsError(
            try ForgeHistoryAcceptedTimelineProjector.project(
                projectID: project,
                acceptedCheckpoints: [first, second]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryAcceptedProjectionError,
                .duplicateCheckpointBinding("c1")
            )
        }
    }

    func testProjectorPreservesMissionScopeValidationFromCanonicalTimeline() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let expectedMission = try ForgeHistoryMissionID("mission-a")
        let actualMission = try ForgeHistoryMissionID("mission-b")
        let checkpoint = try makeCheckpoint(
            "c1",
            missionID: actualMission,
            sequence: 1
        )

        XCTAssertThrowsError(
            try ForgeHistoryAcceptedTimelineProjector.project(
                projectID: project,
                missionID: expectedMission,
                acceptedCheckpoints: [
                    .init(
                        projectID: project,
                        acceptedProjectStateID: try .init("state-1"),
                        checkpoint: checkpoint
                    ),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryError,
                .missionScopeMismatch(
                    checkpointID: "c1",
                    expectedMissionID: "mission-a",
                    actualMissionID: "mission-b"
                )
            )
        }
    }

    func testProjectorPreservesCanonicalDuplicateSequenceValidation() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let first = try makeCheckpoint("c1", sequence: 1)
        let second = try makeCheckpoint("c2", sequence: 1)

        XCTAssertThrowsError(
            try ForgeHistoryAcceptedTimelineProjector.project(
                projectID: project,
                acceptedCheckpoints: [
                    .init(
                        projectID: project,
                        acceptedProjectStateID: try .init("state-1"),
                        checkpoint: first
                    ),
                    .init(
                        projectID: project,
                        acceptedProjectStateID: try .init("state-2"),
                        checkpoint: second
                    ),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeHistoryError, .duplicateSequence(1))
        }
    }

    func testAcceptedProjectStateIdentityPreservesOpaqueInternalCharactersExactly() throws {
        let rawValue = "/tmp/project state#1"
        XCTAssertEqual(
            try ForgeHistoryAcceptedProjectStateID(rawValue).rawValue,
            rawValue
        )
    }

    func testAcceptedProjectStateIdentityRejectsWhitespaceAliasesInsteadOfNormalizing() throws {
        for candidate in [" state-1", "state-1 ", "\nstate-1", "state-1\t"] {
            XCTAssertThrowsError(try ForgeHistoryAcceptedProjectStateID(candidate)) { error in
                XCTAssertEqual(
                    error as? ForgeHistoryAcceptedProjectionError,
                    .invalidAcceptedProjectStateID
                )
            }
        }
    }

    func testAcceptedProjectStateIdentityRejectsControlCharactersAndOversizedValues() throws {
        for candidate in ["state\u{0000}1", "state\u{001F}1", String(repeating: "x", count: 513)] {
            XCTAssertThrowsError(try ForgeHistoryAcceptedProjectStateID(candidate)) { error in
                XCTAssertEqual(
                    error as? ForgeHistoryAcceptedProjectionError,
                    .invalidAcceptedProjectStateID
                )
            }
        }
    }

    func testAcceptedProjectStateIdentityRejectsEmptyValue() throws {
        XCTAssertThrowsError(try ForgeHistoryAcceptedProjectStateID("")) { error in
            XCTAssertEqual(
                error as? ForgeHistoryAcceptedProjectionError,
                .invalidAcceptedProjectStateID
            )
        }
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

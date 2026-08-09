import ForgeHistoryCore
import XCTest

final class ForgeHistoryAcceptedProjectionTests: XCTestCase {
    func testProjectorRejectsCrossProjectBinding() throws {
        let expectedProject = try ForgeHistoryProjectID("project-a")
        let otherProject = try ForgeHistoryProjectID("project-b")
        let mission = try ForgeHistoryMissionID("mission-a")
        let checkpoint = try makeCheckpoint("c1", missionID: mission, sequence: 1)
        let binding = try makeBinding(
            projectID: otherProject,
            missionID: mission,
            stateID: "state-1",
            missionRevision: 2,
            authorityEpoch: 3,
            constitutionRevision: 1,
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

    func testProjectorRejectsMissionAuthorityAttachedToDifferentCheckpointMission() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let missionA = try ForgeHistoryMissionID("mission-a")
        let missionB = try ForgeHistoryMissionID("mission-b")
        let checkpoint = try makeCheckpoint("c1", missionID: missionA, sequence: 1)
        let binding = try makeBinding(
            projectID: project,
            missionID: missionB,
            stateID: "state-1",
            missionRevision: 2,
            authorityEpoch: 3,
            constitutionRevision: 1,
            checkpoint: checkpoint
        )

        XCTAssertThrowsError(
            try ForgeHistoryAcceptedTimelineProjector.project(
                projectID: project,
                acceptedCheckpoints: [binding]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryAcceptedProjectionError,
                .checkpointMissionMismatch(
                    checkpointID: "c1",
                    expectedMissionID: "mission-b",
                    actualMissionID: "mission-a"
                )
            )
        }
    }

    func testMissionAuthorityRejectsZeroCoordinates() throws {
        XCTAssertThrowsError(
            try ForgeHistoryMissionAuthority(
                missionRevision: 0,
                authorityEpoch: 1,
                constitutionRevision: 1
            )
        ) { error in
            XCTAssertEqual(error as? ForgeHistoryAcceptedProjectionError, .invalidMissionAuthority)
        }
        XCTAssertThrowsError(
            try ForgeHistoryMissionAuthority(
                missionRevision: 1,
                authorityEpoch: 0,
                constitutionRevision: 1
            )
        )
        XCTAssertThrowsError(
            try ForgeHistoryMissionAuthority(
                missionRevision: 1,
                authorityEpoch: 1,
                constitutionRevision: 0
            )
        )
    }

    func testProjectorRetainsAcceptedStateAndAuthorityInCanonicalTimelineOrder() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let mission = try ForgeHistoryMissionID("mission-a")
        let first = try makeCheckpoint("c1", missionID: mission, sequence: 1)
        let second = try makeCheckpoint("c2", parent: first.id, missionID: mission, sequence: 2)
        let projection = try ForgeHistoryAcceptedTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                try makeBinding(
                    projectID: project,
                    missionID: mission,
                    stateID: "state-2",
                    missionRevision: 20,
                    authorityEpoch: 8,
                    constitutionRevision: 3,
                    checkpoint: second
                ),
                try makeBinding(
                    projectID: project,
                    missionID: mission,
                    stateID: "state-1",
                    missionRevision: 10,
                    authorityEpoch: 4,
                    constitutionRevision: 2,
                    checkpoint: first
                ),
            ]
        )

        XCTAssertEqual(projection.timeline.checkpoints.map(\.id.rawValue), ["c1", "c2"])
        XCTAssertEqual(
            projection.acceptedCheckpointStates.map(\.acceptedProjectStateID.rawValue),
            ["state-1", "state-2"]
        )
        XCTAssertEqual(
            projection.acceptedCheckpointStates.map(\.missionAuthority.missionRevision),
            [10, 20]
        )
        XCTAssertEqual(
            projection.acceptedCheckpointStates.map(\.missionAuthority.authorityEpoch),
            [4, 8]
        )
        XCTAssertEqual(
            projection.acceptedCheckpointStates.map(\.missionAuthority.constitutionRevision),
            [2, 3]
        )
    }

    func testSameAcceptedProjectStateCanRemainDistinctAcrossAuthorityCoordinates() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let mission = try ForgeHistoryMissionID("mission-a")
        let first = try makeCheckpoint("before-restore", missionID: mission, sequence: 1)
        let second = try makeCheckpoint("after-restore", parent: first.id, missionID: mission, sequence: 2)
        let projection = try ForgeHistoryAcceptedTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                try makeBinding(
                    projectID: project,
                    missionID: mission,
                    stateID: "same-project-state",
                    missionRevision: 4,
                    authorityEpoch: 2,
                    constitutionRevision: 1,
                    checkpoint: first
                ),
                try makeBinding(
                    projectID: project,
                    missionID: mission,
                    stateID: "same-project-state",
                    missionRevision: 9,
                    authorityEpoch: 5,
                    constitutionRevision: 1,
                    checkpoint: second
                ),
            ]
        )

        let before = try XCTUnwrap(projection.acceptedState(for: first.id))
        let after = try XCTUnwrap(projection.acceptedState(for: second.id))
        XCTAssertEqual(before.acceptedProjectStateID, after.acceptedProjectStateID)
        XCTAssertNotEqual(before.missionAuthority, after.missionAuthority)
    }

    func testProjectorRejectsDuplicateCheckpointBindingBeforeTimelineProjection() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let mission = try ForgeHistoryMissionID("mission-a")
        let checkpoint = try makeCheckpoint("c1", missionID: mission, sequence: 1)
        let first = try makeBinding(
            projectID: project,
            missionID: mission,
            stateID: "state-1",
            missionRevision: 1,
            authorityEpoch: 1,
            constitutionRevision: 1,
            checkpoint: checkpoint
        )
        let second = try makeBinding(
            projectID: project,
            missionID: mission,
            stateID: "state-2",
            missionRevision: 2,
            authorityEpoch: 2,
            constitutionRevision: 1,
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

    func testCanonicalMissionScopeAndLineageValidationStillFailClosed() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let expectedMission = try ForgeHistoryMissionID("mission-a")
        let otherMission = try ForgeHistoryMissionID("mission-b")
        let otherCheckpoint = try makeCheckpoint("c1", missionID: otherMission, sequence: 1)
        let scopedBinding = try makeBinding(
            projectID: project,
            missionID: otherMission,
            stateID: "state-1",
            missionRevision: 1,
            authorityEpoch: 1,
            constitutionRevision: 1,
            checkpoint: otherCheckpoint
        )

        XCTAssertThrowsError(
            try ForgeHistoryAcceptedTimelineProjector.project(
                projectID: project,
                missionID: expectedMission,
                acceptedCheckpoints: [scopedBinding]
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

        let checkpoint = try makeCheckpoint(
            "c2",
            parent: ForgeHistoryCheckpointID("ghost"),
            missionID: expectedMission,
            sequence: 2
        )
        let binding = try makeBinding(
            projectID: project,
            missionID: expectedMission,
            stateID: "state-2",
            missionRevision: 2,
            authorityEpoch: 2,
            constitutionRevision: 1,
            checkpoint: checkpoint
        )
        XCTAssertThrowsError(
            try ForgeHistoryAcceptedTimelineProjector.project(
                projectID: project,
                acceptedCheckpoints: [binding]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryError,
                .missingParent(checkpointID: "c2", parentID: "ghost")
            )
        }
    }

    func testAcceptedProjectStateIDUsesUpstreamCanonicalizationAndRejectsBlank() throws {
        XCTAssertEqual(
            try ForgeHistoryAcceptedProjectStateID("  state with spaces  ").rawValue,
            "state with spaces"
        )
        XCTAssertThrowsError(try ForgeHistoryAcceptedProjectStateID("   \n")) { error in
            XCTAssertEqual(
                error as? ForgeHistoryAcceptedProjectionError,
                .invalidAcceptedProjectStateID
            )
        }
    }

    func testRestoreAndForkIntentsCarryExactAcceptedAuthorityPreconditions() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let mission = try ForgeHistoryMissionID("mission-a")
        let checkpoint = try makeCheckpoint("c1", missionID: mission, sequence: 1)
        let authority = try ForgeHistoryMissionAuthority(
            missionRevision: 7,
            authorityEpoch: 4,
            constitutionRevision: 2
        )
        let projection = try ForgeHistoryAcceptedTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                ForgeHistoryAcceptedCheckpointBinding(
                    projectID: project,
                    missionID: mission,
                    acceptedProjectStateID: try .init("state-1"),
                    missionAuthority: authority,
                    checkpoint: checkpoint
                ),
            ]
        )

        guard case .restore(let restoreTarget) = try projection.restoreIntent(to: checkpoint.id) else {
            return XCTFail("Expected restore intent")
        }
        assertTarget(
            restoreTarget,
            projectID: project,
            checkpointID: checkpoint.id,
            missionID: mission,
            stateID: "state-1",
            authority: authority
        )

        guard case .fork(let forkTarget) = try projection.forkIntent(from: checkpoint.id) else {
            return XCTFail("Expected fork intent")
        }
        assertTarget(
            forkTarget,
            projectID: project,
            checkpointID: checkpoint.id,
            missionID: mission,
            stateID: "state-1",
            authority: authority
        )
    }

    func testCompareIntentBindsBothExactEndpointAuthorities() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let mission = try ForgeHistoryMissionID("mission-a")
        let first = try makeCheckpoint("c1", missionID: mission, sequence: 1)
        let second = try makeCheckpoint("c2", parent: first.id, missionID: mission, sequence: 2)
        let firstAuthority = try ForgeHistoryMissionAuthority(
            missionRevision: 3,
            authorityEpoch: 2,
            constitutionRevision: 1
        )
        let secondAuthority = try ForgeHistoryMissionAuthority(
            missionRevision: 8,
            authorityEpoch: 5,
            constitutionRevision: 2
        )
        let projection = try ForgeHistoryAcceptedTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                ForgeHistoryAcceptedCheckpointBinding(
                    projectID: project,
                    missionID: mission,
                    acceptedProjectStateID: try .init("state-1"),
                    missionAuthority: firstAuthority,
                    checkpoint: first
                ),
                ForgeHistoryAcceptedCheckpointBinding(
                    projectID: project,
                    missionID: mission,
                    acceptedProjectStateID: try .init("state-2"),
                    missionAuthority: secondAuthority,
                    checkpoint: second
                ),
            ]
        )

        guard case .compare(let fromTarget, let toTarget) = try projection.compareIntent(
            from: first.id,
            to: second.id
        ) else {
            return XCTFail("Expected compare intent")
        }
        assertTarget(
            fromTarget,
            projectID: project,
            checkpointID: first.id,
            missionID: mission,
            stateID: "state-1",
            authority: firstAuthority
        )
        assertTarget(
            toTarget,
            projectID: project,
            checkpointID: second.id,
            missionID: mission,
            stateID: "state-2",
            authority: secondAuthority
        )
    }

    func testCompareStillRejectsIdenticalEndpointsAndUnknownAcceptedTargetFailsClosed() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let mission = try ForgeHistoryMissionID("mission-a")
        let checkpoint = try makeCheckpoint("c1", missionID: mission, sequence: 1)
        let projection = try ForgeHistoryAcceptedTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                try makeBinding(
                    projectID: project,
                    missionID: mission,
                    stateID: "state-1",
                    missionRevision: 1,
                    authorityEpoch: 1,
                    constitutionRevision: 1,
                    checkpoint: checkpoint
                ),
            ]
        )

        XCTAssertThrowsError(try projection.compareIntent(from: checkpoint.id, to: checkpoint.id)) { error in
            XCTAssertEqual(error as? ForgeHistoryError, .identicalComparisonEndpoints("c1"))
        }
        let ghost = try ForgeHistoryCheckpointID("ghost")
        XCTAssertThrowsError(try projection.restoreIntent(to: ghost)) { error in
            XCTAssertEqual(
                error as? ForgeHistoryAcceptedProjectionError,
                .unknownAcceptedCheckpoint("ghost")
            )
        }
    }

    private func assertTarget(
        _ target: ForgeHistoryAcceptedActionTarget,
        projectID: ForgeHistoryProjectID,
        checkpointID: ForgeHistoryCheckpointID,
        missionID: ForgeHistoryMissionID,
        stateID: String,
        authority: ForgeHistoryMissionAuthority,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(target.projectID, projectID, file: file, line: line)
        XCTAssertEqual(target.checkpointID, checkpointID, file: file, line: line)
        XCTAssertEqual(target.missionID, missionID, file: file, line: line)
        XCTAssertEqual(target.acceptedProjectStateID.rawValue, stateID, file: file, line: line)
        XCTAssertEqual(target.missionAuthority, authority, file: file, line: line)
    }

    private func makeBinding(
        projectID: ForgeHistoryProjectID,
        missionID: ForgeHistoryMissionID,
        stateID: String,
        missionRevision: UInt64,
        authorityEpoch: UInt64,
        constitutionRevision: UInt64,
        checkpoint: ForgeHistoryCheckpoint
    ) throws -> ForgeHistoryAcceptedCheckpointBinding {
        ForgeHistoryAcceptedCheckpointBinding(
            projectID: projectID,
            missionID: missionID,
            acceptedProjectStateID: try ForgeHistoryAcceptedProjectStateID(stateID),
            missionAuthority: try ForgeHistoryMissionAuthority(
                missionRevision: missionRevision,
                authorityEpoch: authorityEpoch,
                constitutionRevision: constitutionRevision
            ),
            checkpoint: checkpoint
        )
    }

    private func makeCheckpoint(
        _ rawID: String,
        parent: ForgeHistoryCheckpointID? = nil,
        missionID: ForgeHistoryMissionID,
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

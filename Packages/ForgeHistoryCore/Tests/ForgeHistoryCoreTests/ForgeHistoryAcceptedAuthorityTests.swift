import ForgeHistoryCore
import XCTest

final class ForgeHistoryAcceptedAuthorityTests: XCTestCase {
    func testMissionAuthorityRejectsZeroCoordinates() throws {
        for coordinates: (UInt64, UInt64, UInt64) in [(0, 1, 1), (1, 0, 1), (1, 1, 0)] {
            XCTAssertThrowsError(
                try ForgeHistoryMissionAuthority(
                    missionRevision: coordinates.0,
                    authorityEpoch: coordinates.1,
                    constitutionRevision: coordinates.2
                )
            ) { error in
                XCTAssertEqual(error as? ForgeHistoryAcceptedProjectionError, .invalidMissionAuthority)
            }
        }
    }

    func testMissionProjectorRejectsCheckpointMissionMismatch() throws {
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
            try ForgeHistoryAcceptedMissionTimelineProjector.project(projectID: project, acceptedCheckpoints: [binding])
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryAcceptedProjectionError,
                .checkpointMissionMismatch(checkpointID: "c1", expectedMissionID: "mission-b", actualMissionID: "mission-a")
            )
        }
    }

    func testMissionProjectionRetainsStateAuthorityAndBaseProjectionOrder() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let mission = try ForgeHistoryMissionID("mission-a")
        let first = try makeCheckpoint("c1", missionID: mission, sequence: 1)
        let second = try makeCheckpoint("c2", parent: first.id, missionID: mission, sequence: 2)
        let projection = try ForgeHistoryAcceptedMissionTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                try makeBinding(projectID: project, missionID: mission, stateID: "state-2", missionRevision: 20, authorityEpoch: 8, constitutionRevision: 3, checkpoint: second),
                try makeBinding(projectID: project, missionID: mission, stateID: "state-1", missionRevision: 10, authorityEpoch: 4, constitutionRevision: 2, checkpoint: first),
            ]
        )
        XCTAssertEqual(projection.timeline.checkpoints.map(\.id.rawValue), ["c1", "c2"])
        XCTAssertEqual(projection.acceptedTimeline.acceptedProjectStates.map(\.acceptedProjectStateID.rawValue), ["state-1", "state-2"])
        XCTAssertEqual(projection.acceptedMissionStates.map(\.missionAuthority.missionRevision), [10, 20])
        XCTAssertEqual(projection.acceptedMissionStates.map(\.missionAuthority.authorityEpoch), [4, 8])
        XCTAssertEqual(projection.acceptedMissionStates.map(\.missionAuthority.constitutionRevision), [2, 3])
    }

    func testProjectWideMissionProjectionCanSpanAcceptedMissions() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let missionA = try ForgeHistoryMissionID("mission-a")
        let missionB = try ForgeHistoryMissionID("mission-b")
        let first = try makeCheckpoint("c1", missionID: missionA, sequence: 1)
        let second = try makeCheckpoint("c2", parent: first.id, missionID: missionB, sequence: 2)
        let projection = try ForgeHistoryAcceptedMissionTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                try makeBinding(projectID: project, missionID: missionB, stateID: "state-2", missionRevision: 4, authorityEpoch: 2, constitutionRevision: 1, checkpoint: second),
                try makeBinding(projectID: project, missionID: missionA, stateID: "state-1", missionRevision: 2, authorityEpoch: 1, constitutionRevision: 1, checkpoint: first),
            ]
        )
        XCTAssertNil(projection.timeline.missionID)
        XCTAssertEqual(projection.acceptedMissionStates.map(\.missionID.rawValue), ["mission-a", "mission-b"])
    }

    func testSameAcceptedProjectStateRemainsDistinctAcrossAuthorityCoordinates() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let mission = try ForgeHistoryMissionID("mission-a")
        let first = try makeCheckpoint("before", missionID: mission, sequence: 1)
        let second = try makeCheckpoint("after", parent: first.id, missionID: mission, sequence: 2)
        let projection = try ForgeHistoryAcceptedMissionTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                try makeBinding(projectID: project, missionID: mission, stateID: "same-state", missionRevision: 4, authorityEpoch: 2, constitutionRevision: 1, checkpoint: first),
                try makeBinding(projectID: project, missionID: mission, stateID: "same-state", missionRevision: 9, authorityEpoch: 5, constitutionRevision: 1, checkpoint: second),
            ]
        )
        let before = try XCTUnwrap(projection.acceptedMissionState(for: first.id))
        let after = try XCTUnwrap(projection.acceptedMissionState(for: second.id))
        XCTAssertEqual(before.acceptedProjectStateID, after.acceptedProjectStateID)
        XCTAssertNotEqual(before.missionAuthority, after.missionAuthority)
    }

    func testRestoreAndForkIntentsCarryExactAcceptedAuthorityPreconditions() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let mission = try ForgeHistoryMissionID("mission-a")
        let checkpoint = try makeCheckpoint("c1", missionID: mission, sequence: 1)
        let authority = try ForgeHistoryMissionAuthority(missionRevision: 7, authorityEpoch: 4, constitutionRevision: 2)
        let projection = try ForgeHistoryAcceptedMissionTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                ForgeHistoryAcceptedMissionCheckpointBinding(
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
        assertTarget(restoreTarget, projectID: project, checkpointID: checkpoint.id, missionID: mission, stateID: "state-1", authority: authority)
        guard case .fork(let forkTarget) = try projection.forkIntent(from: checkpoint.id) else {
            return XCTFail("Expected fork intent")
        }
        assertTarget(forkTarget, projectID: project, checkpointID: checkpoint.id, missionID: mission, stateID: "state-1", authority: authority)
    }

    func testCompareIntentBindsBothExactEndpointAuthorities() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let mission = try ForgeHistoryMissionID("mission-a")
        let first = try makeCheckpoint("c1", missionID: mission, sequence: 1)
        let second = try makeCheckpoint("c2", parent: first.id, missionID: mission, sequence: 2)
        let firstAuthority = try ForgeHistoryMissionAuthority(missionRevision: 3, authorityEpoch: 2, constitutionRevision: 1)
        let secondAuthority = try ForgeHistoryMissionAuthority(missionRevision: 8, authorityEpoch: 5, constitutionRevision: 2)
        let projection = try ForgeHistoryAcceptedMissionTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                .init(projectID: project, missionID: mission, acceptedProjectStateID: try .init("state-1"), missionAuthority: firstAuthority, checkpoint: first),
                .init(projectID: project, missionID: mission, acceptedProjectStateID: try .init("state-2"), missionAuthority: secondAuthority, checkpoint: second),
            ]
        )
        guard case .compare(let fromTarget, let toTarget) = try projection.compareIntent(from: first.id, to: second.id) else {
            return XCTFail("Expected compare intent")
        }
        assertTarget(fromTarget, projectID: project, checkpointID: first.id, missionID: mission, stateID: "state-1", authority: firstAuthority)
        assertTarget(toTarget, projectID: project, checkpointID: second.id, missionID: mission, stateID: "state-2", authority: secondAuthority)
    }

    func testCompareAndUnknownAcceptedTargetsRemainFailClosed() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let mission = try ForgeHistoryMissionID("mission-a")
        let checkpoint = try makeCheckpoint("c1", missionID: mission, sequence: 1)
        let projection = try ForgeHistoryAcceptedMissionTimelineProjector.project(
            projectID: project,
            acceptedCheckpoints: [
                try makeBinding(projectID: project, missionID: mission, stateID: "state-1", missionRevision: 1, authorityEpoch: 1, constitutionRevision: 1, checkpoint: checkpoint),
            ]
        )
        XCTAssertThrowsError(try projection.compareIntent(from: checkpoint.id, to: checkpoint.id)) { error in
            XCTAssertEqual(error as? ForgeHistoryError, .identicalComparisonEndpoints("c1"))
        }
        let ghost = try ForgeHistoryCheckpointID("ghost")
        XCTAssertThrowsError(try projection.restoreIntent(to: ghost)) { error in
            XCTAssertEqual(error as? ForgeHistoryAcceptedProjectionError, .unknownAcceptedCheckpoint("ghost"))
        }
        XCTAssertNil(projection.acceptedMissionState(for: ghost))
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
    ) throws -> ForgeHistoryAcceptedMissionCheckpointBinding {
        ForgeHistoryAcceptedMissionCheckpointBinding(
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

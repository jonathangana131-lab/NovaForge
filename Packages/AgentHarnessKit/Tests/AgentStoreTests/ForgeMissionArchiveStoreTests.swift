import AgentDomain
import AgentStore
import ForgeMission
import Foundation
import XCTest

final class ForgeMissionArchiveStoreTests: XCTestCase {
    func testFirstSaveAndLoadRoundTripExactIdentityAndRevision() async throws {
        let store = InMemoryForgeMissionArchiveStore()
        let mission = try makeMission()
        let archive = try ForgeMissionArchive(state: mission)

        let commit = try await store.save(archive, expectedPreviousRevision: nil)
        XCTAssertEqual(commit.disposition, .committed)
        XCTAssertEqual(commit.missionID, mission.missionID)
        XCTAssertEqual(commit.projectID, mission.projectID)
        XCTAssertEqual(commit.revision, mission.revision)
        XCTAssertEqual(commit.authorityEpoch, mission.authorityEpoch)

        let loaded = try await store.load(
            missionID: mission.missionID,
            projectID: mission.projectID
        )
        XCTAssertEqual(loaded, archive)
    }

    func testExactSameSnapshotIsIdempotentReplay() async throws {
        let store = InMemoryForgeMissionArchiveStore()
        let archive = try ForgeMissionArchive(state: makeMission())
        _ = try await store.save(archive, expectedPreviousRevision: nil)

        let retry = try await store.save(archive, expectedPreviousRevision: nil)
        XCTAssertEqual(retry.disposition, .idempotentReplay)
        XCTAssertEqual(retry.revision, archive.state.revision)
    }

    func testResponseLossRetryRemainsIdempotentAfterRevisionAdvanced() async throws {
        let store = InMemoryForgeMissionArchiveStore()
        var mission = try makeMission()
        let firstRevision = mission.revision
        _ = try await store.save(try ForgeMissionArchive(state: mission), expectedPreviousRevision: nil)

        try mission.switchRoute(to: .init(routeReceiptID: "route:deep"))
        let second = try ForgeMissionArchive(state: mission)
        let committed = try await store.save(second, expectedPreviousRevision: firstRevision)
        XCTAssertEqual(committed.disposition, .committed)

        let lostResponseRetry = try await store.save(second, expectedPreviousRevision: firstRevision)
        XCTAssertEqual(lostResponseRetry.disposition, .idempotentReplay)
    }

    func testDivergentSameRevisionWritersCannotBothCommit() async throws {
        let store = InMemoryForgeMissionArchiveStore()
        let base = try makeMission()
        let baseRevision = base.revision
        _ = try await store.save(try ForgeMissionArchive(state: base), expectedPreviousRevision: nil)

        var firstWriter = base
        var secondWriter = base
        try firstWriter.switchRoute(to: .init(routeReceiptID: "route:first"))
        try secondWriter.switchRoute(to: .init(routeReceiptID: "route:second"))
        XCTAssertEqual(firstWriter.revision, secondWriter.revision)

        _ = try await store.save(
            try ForgeMissionArchive(state: firstWriter),
            expectedPreviousRevision: baseRevision
        )
        do {
            _ = try await store.save(
                try ForgeMissionArchive(state: secondWriter),
                expectedPreviousRevision: baseRevision
            )
            XCTFail("Divergent same-revision writer must not commit")
        } catch {
            XCTAssertEqual(
                error as? ForgeMissionArchiveStoreError,
                .conflictingRevision(secondWriter.revision)
            )
        }
    }

    func testStaleHigherRevisionWriterIsRejectedByCompareAndSet() async throws {
        let store = InMemoryForgeMissionArchiveStore()
        var mission = try makeMission()
        let firstRevision = mission.revision
        _ = try await store.save(try ForgeMissionArchive(state: mission), expectedPreviousRevision: nil)
        try mission.switchRoute(to: .init(routeReceiptID: "route:two"))
        _ = try await store.save(
            try ForgeMissionArchive(state: mission),
            expectedPreviousRevision: firstRevision
        )

        let currentRevision = mission.revision
        try mission.switchRoute(to: .init(routeReceiptID: "route:three"))
        do {
            _ = try await store.save(
                try ForgeMissionArchive(state: mission),
                expectedPreviousRevision: firstRevision
            )
            XCTFail("Stale compare-and-set must not commit")
        } catch {
            XCTAssertEqual(
                error as? ForgeMissionArchiveStoreError,
                .staleWrite(
                    expectedPreviousRevision: firstRevision,
                    actualRevision: currentRevision
                )
            )
        }
    }

    func testMissionIDCannotBeReadUnderDifferentProjectIdentity() async throws {
        let store = InMemoryForgeMissionArchiveStore()
        let mission = try makeMission()
        _ = try await store.save(try ForgeMissionArchive(state: mission), expectedPreviousRevision: nil)
        let wrongProject = ProjectID()

        do {
            _ = try await store.load(missionID: mission.missionID, projectID: wrongProject)
            XCTFail("Cross-project mission lookup must fail closed")
        } catch {
            XCTAssertEqual(
                error as? ForgeMissionArchiveStoreError,
                .identityMismatch(
                    missionID: mission.missionID,
                    expectedProjectID: mission.projectID,
                    actualProjectID: wrongProject
                )
            )
        }
    }

    func testRevisionRegressionIsRejected() async throws {
        let store = InMemoryForgeMissionArchiveStore()
        let original = try makeMission()
        var advanced = original
        _ = try await store.save(try ForgeMissionArchive(state: original), expectedPreviousRevision: nil)
        try advanced.switchRoute(to: .init(routeReceiptID: "route:advanced"))
        _ = try await store.save(
            try ForgeMissionArchive(state: advanced),
            expectedPreviousRevision: original.revision
        )

        do {
            _ = try await store.save(
                try ForgeMissionArchive(state: original),
                expectedPreviousRevision: advanced.revision
            )
            XCTFail("Revision regression must fail")
        } catch {
            XCTAssertEqual(
                error as? ForgeMissionArchiveStoreError,
                .revisionRegression(current: advanced.revision, proposed: original.revision)
            )
        }
    }

    func testAuthorityEpochRegressionIsRejectedEvenAtHigherRevision() async throws {
        let store = InMemoryForgeMissionArchiveStore()
        let missionID = MissionID()
        let projectID = ProjectID()
        let firstStageID = MissionStageID()
        let secondStageID = MissionStageID()
        let base = try ForgeMissionState(
            constitution: MissionConstitution(
                missionID: missionID,
                projectID: projectID,
                acceptedAt: instant(1),
                productGoal: "Build a durable app",
                projectType: "app"
            ),
            graph: MissionStageGraph(
                missionID: missionID,
                stages: [
                    MissionStage(stageID: firstStageID, kind: .implement, title: "First", order: 1),
                    MissionStage(stageID: secondStageID, kind: .test, title: "Second", order: 2),
                ]
            ),
            route: .init(routeReceiptID: "route:balanced")
        )

        var authoritative = base
        try authoritative.switchRoute(to: .init(routeReceiptID: "route:authority"))
        _ = try await store.save(try ForgeMissionArchive(state: authoritative), expectedPreviousRevision: nil)

        var lowerEpoch = base
        let leases = try lowerEpoch.beginWork(on: lowerEpoch.runnableStageIDs)
        for (index, lease) in leases.enumerated() {
            try lowerEpoch.acceptWorkerResult(
                .init(
                    lease: lease,
                    outcome: .completed,
                    summary: "Completed stage \(index)",
                    evidenceReceiptIDs: .init(["stage:\(index):receipt"])
                ),
                at: instant(Int64(index + 10))
            )
        }
        XCTAssertLessThan(lowerEpoch.authorityEpoch, authoritative.authorityEpoch)
        XCTAssertGreaterThan(lowerEpoch.revision, authoritative.revision)

        do {
            _ = try await store.save(
                try ForgeMissionArchive(state: lowerEpoch),
                expectedPreviousRevision: authoritative.revision
            )
            XCTFail("Authority epoch regression must fail")
        } catch {
            XCTAssertEqual(
                error as? ForgeMissionArchiveStoreError,
                .authorityEpochRegression(
                    current: authoritative.authorityEpoch,
                    proposed: lowerEpoch.authorityEpoch
                )
            )
        }
    }

    func testCodecIsDeterministicAndRejectsOldSchema() throws {
        let codec = ForgeMissionArchiveCodec()
        let archive = try ForgeMissionArchive(state: makeMission())
        let first = try codec.encode(archive)
        let second = try codec.encode(archive)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try codec.encode(codec.decode(first)), first)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        json["schemaVersion"] = 1
        let oldSchema = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try codec.decode(oldSchema)) { error in
            XCTAssertEqual(error as? ForgeMissionArchiveStoreError, .invalidArchive)
        }
    }

    func testCodecRejectsPersistedEmptyMissionGraph() throws {
        let codec = ForgeMissionArchiveCodec()
        let archive = try ForgeMissionArchive(state: makeMission())
        let data = try codec.encode(archive)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var state = try XCTUnwrap(root["state"] as? [String: Any])
        var graph = try XCTUnwrap(state["graph"] as? [String: Any])
        graph["stages"] = []
        state["graph"] = graph
        root["state"] = state

        let corrupted = try JSONSerialization.data(withJSONObject: root)
        XCTAssertThrowsError(try codec.decode(corrupted)) { error in
            XCTAssertEqual(error as? ForgeMissionArchiveStoreError, .invalidArchive)
        }
    }

    func testCodecRejectsPersistedRequiredStageDependingOnOptionalStage() throws {
        let codec = ForgeMissionArchiveCodec()
        let missionID = MissionID()
        let projectID = ProjectID()
        let prerequisiteID = MissionStageID()
        let dependentID = MissionStageID()
        let mission = try ForgeMissionState(
            constitution: MissionConstitution(
                missionID: missionID,
                projectID: projectID,
                acceptedAt: instant(1),
                productGoal: "Build a durable app",
                projectType: "app"
            ),
            graph: MissionStageGraph(
                missionID: missionID,
                stages: [
                    MissionStage(
                        stageID: prerequisiteID,
                        kind: .implement,
                        title: "Required prerequisite",
                        order: 1
                    ),
                    MissionStage(
                        stageID: dependentID,
                        kind: .test,
                        title: "Required dependent",
                        order: 2,
                        dependencies: [prerequisiteID]
                    ),
                ]
            ),
            route: .init(routeReceiptID: "route:balanced")
        )
        let data = try codec.encode(ForgeMissionArchive(state: mission))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var state = try XCTUnwrap(root["state"] as? [String: Any])
        var graph = try XCTUnwrap(state["graph"] as? [String: Any])
        var stages = try XCTUnwrap(graph["stages"] as? [[String: Any]])
        stages[0]["required"] = false
        graph["stages"] = stages
        state["graph"] = graph
        root["state"] = state

        let corrupted = try JSONSerialization.data(withJSONObject: root)
        XCTAssertThrowsError(try codec.decode(corrupted)) { error in
            XCTAssertEqual(error as? ForgeMissionArchiveStoreError, .invalidArchive)
        }
    }

    private func makeMission() throws -> ForgeMissionState {
        let missionID = MissionID()
        let projectID = ProjectID()
        let stageID = MissionStageID()
        return try ForgeMissionState(
            constitution: MissionConstitution(
                missionID: missionID,
                projectID: projectID,
                acceptedAt: instant(1),
                productGoal: "Build a durable app",
                projectType: "app",
                persistenceExpectations: "Resume after relaunch"
            ),
            graph: MissionStageGraph(
                missionID: missionID,
                stages: [
                    MissionStage(
                        stageID: stageID,
                        kind: .implement,
                        title: "Implement",
                        order: 1
                    ),
                ]
            ),
            route: .init(routeReceiptID: "route:balanced")
        )
    }

    private func instant(_ value: Int64) -> AgentInstant {
        AgentInstant(rawValue: value)
    }
}

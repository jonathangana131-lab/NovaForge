@testable import ContinuityCore
import Foundation
import XCTest

final class ContinuityCoreTests: XCTestCase {
    func testExecutionNeedsFreshExactHostGrant() throws {
        let s = ready()
        let good = executionGrant(.foregroundOnDevice, identity: s.identity)
        let (running, lease) = try ContinuityReducer.startForeground(from: s, grant: good)
        XCTAssertTrue(ContinuityReducer.accepts(lease, in: running))

        let wrong = executionGrant(.verifiedCloud, identity: s.identity)
        XCTAssertThrowsError(try ContinuityReducer.startForeground(from: s, grant: wrong)) { XCTAssertEqual($0 as? ContinuityMutationError, .executionGrantMissing) }
    }

    func testBackgroundWithoutFreshSystemGrantSuspendsAndRevokesForegroundLease() throws {
        let (running, old) = try ContinuityReducer.startForeground(from: ready(), grant: executionGrant(.foregroundOnDevice))
        let (backgrounded, lease) = try ContinuityReducer.enterBackground(from: running, systemGrant: nil)
        XCTAssertNil(lease)
        XCTAssertEqual(backgrounded.state, .suspended(.backgroundExecutionUnavailable))
        XCTAssertFalse(ContinuityReducer.accepts(old, in: backgrounded))
    }

    func testSystemGrantMustBindWholeCurrentIdentity() throws {
        let (running, _) = try ContinuityReducer.startForeground(from: ready(), grant: executionGrant(.foregroundOnDevice))
        let other = ContinuityIdentity(missionID: "mission-1", projectID: "project-1", checkpointID: "checkpoint-2", missionRevision: 2)
        XCTAssertThrowsError(try ContinuityReducer.enterBackground(from: running, systemGrant: executionGrant(.systemManagedOnDevice, identity: other))) {
            XCTAssertEqual($0 as? ContinuityMutationError, .executionGrantMissing)
        }
    }

    func testCloudAndMacHandoffRequireModeSpecificGrantAndCannotBypassDecision() throws {
        let s = ready()
        XCTAssertThrowsError(try ContinuityReducer.handoffToCloud(from: s, grant: executionGrant(.verifiedPairedMac))) {
            XCTAssertEqual($0 as? ContinuityMutationError, .executionGrantMissing)
        }
        let (cloud, _) = try ContinuityReducer.handoffToCloud(from: s, grant: executionGrant(.verifiedCloud))
        XCTAssertEqual(cloud.state, .executing(.verifiedCloud))

        let decision = ContinuitySnapshot(identity: s.identity, state: .needsDecision, epoch: 4)
        XCTAssertThrowsError(try ContinuityReducer.handoffToPairedMac(from: decision, grant: executionGrant(.verifiedPairedMac))) {
            XCTAssertEqual($0 as? ContinuityMutationError, .unsupportedTransition)
        }
    }

    func testMissionAuthorityBindsCheckpointAdvanceAndCompletion() throws {
        let s = ready()
        let newer = ContinuityIdentity(missionID: s.identity.missionID, projectID: s.identity.projectID, checkpointID: "checkpoint-2", missionRevision: 2)
        let advanced = try ContinuityReducer.advanceCheckpoint(authority: missionAuthority(newer), in: s)
        XCTAssertEqual(advanced.identity, newer)

        XCTAssertThrowsError(try ContinuityReducer.reflectMissionCompletion(authority: missionAuthority(s.identity), in: advanced)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .missionCompletionIdentityMismatch)
        }
        XCTAssertEqual(try ContinuityReducer.reflectMissionCompletion(authority: missionAuthority(newer), in: advanced).state, .completed)
    }

    func testCanonicalIdentityRejectsWhitespaceAliasesAndControls() {
        for bad in [
            ContinuityIdentity(missionID: " mission-1", projectID: "project-1", checkpointID: "checkpoint-1", missionRevision: 1),
            ContinuityIdentity(missionID: "mission-1", projectID: "project-1\n", checkpointID: "checkpoint-1", missionRevision: 1),
            ContinuityIdentity(missionID: "mission-1", projectID: "project-1", checkpointID: "checkpoint\u{0000}1", missionRevision: 1),
        ] {
            XCTAssertThrowsError(try ContinuityReducer.validate(ContinuitySnapshot(identity: bad))) { XCTAssertEqual($0 as? ContinuityMutationError, .invalidIdentity) }
        }
    }

    func testAcceptedResultRejectsDuplicateOrNonCanonicalEvidence() throws {
        let (running, lease) = try ContinuityReducer.startForeground(from: ready(), grant: executionGrant(.foregroundOnDevice))
        XCTAssertThrowsError(try ContinuityReducer.accept(.init(lease: lease, outcome: .succeeded, summary: "ok", evidenceIDs: ["e1", "e1"]), in: running)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .invalidWorkResult)
        }
        XCTAssertThrowsError(try ContinuityReducer.accept(.init(lease: lease, outcome: .succeeded, summary: "ok", evidenceIDs: [" e1"]), in: running)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .invalidWorkResult)
        }
    }

    func testEnvironmentLossAndExpirationCannotKeepWorkingPresentationAlive() throws {
        let (running, _) = try ContinuityReducer.startForeground(from: ready(), grant: executionGrant(.foregroundOnDevice))
        let (background, _) = try ContinuityReducer.enterBackground(from: running, systemGrant: executionGrant(.systemManagedOnDevice))
        XCTAssertTrue(try ContinuityPresentation.activity(for: background).isActivelyExecuting)
        let expired = try ContinuityReducer.systemContinuationExpired(in: background)
        XCTAssertFalse(try ContinuityPresentation.activity(for: expired).isActivelyExecuting)
        XCTAssertEqual(expired.state, .suspended(.systemExpired))
    }

    func testArchiveNeverRestoresActiveExecutionAuthority() throws {
        let (running, _) = try ContinuityReducer.startForeground(from: ready(), grant: executionGrant(.foregroundOnDevice))
        let archive = try ContinuityArchive(snapshot: running)
        XCTAssertEqual(archive.snapshot.state, .suspended(.executionEnvironmentLost))
        let restored = try archive.restore()
        XCTAssertEqual(restored.state, .suspended(.executionEnvironmentLost))
        XCTAssertNil(restored.activeLease)
        XCTAssertFalse(try ContinuityPresentation.activity(for: restored).isActivelyExecuting)
    }

    func testArchiveDecodeRejectsPersistedExecutingState() throws {
        let archive = try ContinuityArchive(snapshot: ready())
        let data = try JSONEncoder().encode(archive)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
        snapshot["state"] = ["executing": ["_0": "foregroundOnDevice"]]
        object["snapshot"] = snapshot
        let forged = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ContinuityArchive.self, from: forged))
    }

    func testArchiveRejectsDuplicateAndOversizedTransferCollections() throws {
        let a = BackgroundTransferSnapshot(transferID: "same", assetID: "a")
        let b = BackgroundTransferSnapshot(transferID: "same", assetID: "b")
        XCTAssertThrowsError(try ContinuityArchive(snapshot: ready(), transfers: [a, b])) { XCTAssertEqual($0 as? ContinuityArchiveError, .duplicateTransferID("same")) }
        let many = (0...ContinuityArchive.maximumTransfers).map { BackgroundTransferSnapshot(transferID: "t-\($0)", assetID: "a-\($0)") }
        XCTAssertThrowsError(try ContinuityArchive(snapshot: ready(), transfers: many)) { XCTAssertEqual($0 as? ContinuityArchiveError, .tooManyTransfers) }
    }

    func testBackgroundTransferRoundTripRevalidatesNestedState() throws {
        let suspended = try BackgroundTransferReducer.suspend(
            resumeOpaqueToken: "resume-ref-1",
            in: BackgroundTransferReducer.recordProgress(receivedBytes: 400, expectedBytes: 1000, in: BackgroundTransferReducer.start(.init(transferID: "download-1", assetID: "model.gguf", expectedBytes: 1000)))
        )
        let decoded = try JSONDecoder().decode(BackgroundTransferSnapshot.self, from: JSONEncoder().encode(suspended))
        XCTAssertEqual(decoded, suspended)

        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(suspended)) as? [String: Any])
        obj["resumeOpaqueToken"] = nil
        XCTAssertThrowsError(try JSONDecoder().decode(BackgroundTransferSnapshot.self, from: JSONSerialization.data(withJSONObject: obj)))
    }

    func testTransferProgressCannotRegressOrChangeKnownExpectedSize() throws {
        let running = try BackgroundTransferReducer.start(.init(transferID: "asset-1", assetID: "pack.zip", expectedBytes: 1000))
        let progressed = try BackgroundTransferReducer.recordProgress(receivedBytes: 500, expectedBytes: 1000, in: running)
        XCTAssertThrowsError(try BackgroundTransferReducer.recordProgress(receivedBytes: 499, expectedBytes: 1000, in: progressed)) { XCTAssertEqual($0 as? BackgroundTransferError, .byteCountRegression) }
        XCTAssertThrowsError(try BackgroundTransferReducer.recordProgress(receivedBytes: 600, expectedBytes: 900, in: progressed)) { XCTAssertEqual($0 as? BackgroundTransferError, .invalidByteCount) }
    }

    func testNotificationPolicySuppressesRoutineChatter() {
        XCTAssertEqual(ContinuityNotificationPolicy.disposition(for: .progressTick), .suppress)
        XCTAssertEqual(ContinuityNotificationPolicy.disposition(for: .routineStageChange), .suppress)
        XCTAssertEqual(ContinuityNotificationPolicy.disposition(for: .decisionNeeded), .deliver)
        XCTAssertEqual(ContinuityNotificationPolicy.disposition(for: .completed), .deliver)
    }

    private func identity() -> ContinuityIdentity { .init(missionID: "mission-1", projectID: "project-1", checkpointID: "checkpoint-1", missionRevision: 1) }
    private func ready() -> ContinuitySnapshot { .init(identity: identity()) }
    private func executionGrant(_ mode: ContinuityExecutionMode, identity: ContinuityIdentity? = nil) -> ContinuityExecutionGrant {
        .init(identity: identity ?? self.identity(), mode: mode, authorityReceiptID: "host-receipt-\(mode)")
    }
    private func missionAuthority(_ identity: ContinuityIdentity) -> ContinuityMissionAuthority { .init(identity: identity, authorityReceiptID: "mission-authority") }
}

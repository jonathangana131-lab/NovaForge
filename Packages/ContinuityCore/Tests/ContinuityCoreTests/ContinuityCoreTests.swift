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

        let decision = ContinuitySnapshot(identity: s.identity, state: .needsDecision, activeLease: nil, epoch: 4)
        XCTAssertThrowsError(try ContinuityReducer.handoffToPairedMac(from: decision, grant: executionGrant(.verifiedPairedMac, issuedForEpoch: decision.epoch))) {
            XCTAssertEqual($0 as? ContinuityMutationError, .unsupportedTransition)
        }
    }

    func testMissionAuthorityBindsCheckpointAdvanceAndCompletion() throws {
        let s = ready()
        let newer = ContinuityIdentity(missionID: s.identity.missionID, projectID: s.identity.projectID, checkpointID: "checkpoint-2", missionRevision: 2)
        let advanced = try ContinuityReducer.advanceCheckpoint(authority: checkpointAuthority(newer), in: s)
        XCTAssertEqual(advanced.identity, newer)

        XCTAssertThrowsError(try ContinuityReducer.reflectMissionCompletion(authority: projectionAuthority(.completed, identity: s.identity, issuedForEpoch: advanced.epoch), in: advanced)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .missionCompletionIdentityMismatch)
        }
        XCTAssertEqual(try ContinuityReducer.reflectMissionCompletion(authority: projectionAuthority(.completed, identity: newer, issuedForEpoch: advanced.epoch), in: advanced).state, .completed)
    }

    func testMissionAuthorityPurposeCannotBeReplayedAcrossOperations() throws {
        let s = ready()
        let newer = ContinuityIdentity(missionID: s.identity.missionID, projectID: s.identity.projectID, checkpointID: "checkpoint-2", missionRevision: 2)

        XCTAssertThrowsError(try ContinuityReducer.advanceCheckpoint(authority: projectionAuthority(.completed, identity: newer), in: s)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .invalidAuthority)
        }
        XCTAssertThrowsError(try ContinuityReducer.reflectMissionCompletion(authority: checkpointAuthority(s.identity), in: s)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .invalidAuthority)
        }
    }

    func testCheckpointAdvanceCannotCarryOldMissionProjectionAcrossRevision() throws {
        let s = ready()
        let completed = try ContinuityReducer.reflectMissionCompletion(authority: projectionAuthority(.completed, identity: s.identity), in: s)
        let newer = ContinuityIdentity(missionID: s.identity.missionID, projectID: s.identity.projectID, checkpointID: "checkpoint-2", missionRevision: 2)
        let advanced = try ContinuityReducer.advanceCheckpoint(authority: checkpointAuthority(newer, issuedForEpoch: completed.epoch), in: completed)

        XCTAssertEqual(advanced.identity, newer)
        XCTAssertEqual(advanced.state, .suspended(.missionStateRevalidationRequired))
    }

    func testMissionRevalidationSuspensionCannotResumeOnExecutionAuthorityAlone() throws {
        let s = ready()
        let completed = try ContinuityReducer.reflectMissionCompletion(authority: projectionAuthority(.completed, identity: s.identity), in: s)
        let restored = try ContinuityArchive(snapshot: completed).restore()
        XCTAssertEqual(restored.state, .suspended(.missionStateRevalidationRequired))

        XCTAssertThrowsError(try ContinuityReducer.startForeground(from: restored, grant: executionGrant(.foregroundOnDevice, issuedForEpoch: restored.epoch))) {
            XCTAssertEqual($0 as? ContinuityMutationError, .unsupportedTransition)
        }
        XCTAssertThrowsError(try ContinuityReducer.handoffToCloud(from: restored, grant: executionGrant(.verifiedCloud, issuedForEpoch: restored.epoch))) {
            XCTAssertEqual($0 as? ContinuityMutationError, .unsupportedTransition)
        }

        let revalidated = try ContinuityReducer.reflectMissionState(
            authority: projectionAuthority(.ready, identity: restored.identity, issuedForEpoch: restored.epoch),
            in: restored
        )
        XCTAssertEqual(revalidated.state, .ready)
        XCTAssertNoThrow(try ContinuityReducer.startForeground(from: revalidated, grant: executionGrant(.foregroundOnDevice, issuedForEpoch: revalidated.epoch)))
    }


    func testUserPauseCannotResumeOnExecutionAuthorityAlone() throws {
        let (running, _) = try ContinuityReducer.startForeground(from: ready(), grant: executionGrant(.foregroundOnDevice))
        let paused = try ContinuityReducer.pauseByUser(running)
        XCTAssertEqual(paused.state, .suspended(.userPaused))

        XCTAssertThrowsError(try ContinuityReducer.startForeground(from: paused, grant: executionGrant(.foregroundOnDevice, issuedForEpoch: paused.epoch))) {
            XCTAssertEqual($0 as? ContinuityMutationError, .unsupportedTransition)
        }
        XCTAssertThrowsError(try ContinuityReducer.handoffToCloud(from: paused, grant: executionGrant(.verifiedCloud, issuedForEpoch: paused.epoch))) {
            XCTAssertEqual($0 as? ContinuityMutationError, .unsupportedTransition)
        }

        let resumed = try ContinuityReducer.resumeAfterUserPause(authority: userResumeAuthority(paused.identity, issuedForEpoch: paused.epoch), in: paused)
        XCTAssertEqual(resumed.state, .ready)
        XCTAssertNoThrow(try ContinuityReducer.startForeground(from: resumed, grant: executionGrant(.foregroundOnDevice, issuedForEpoch: resumed.epoch)))
    }


    func testExecutionGrantCannotReplayAfterSystemExpiration() throws {
        let seed = ready()
        let (foreground, _) = try ContinuityReducer.startForeground(from: seed, grant: executionGrant(.foregroundOnDevice))
        let oldSystemGrant = executionGrant(.systemManagedOnDevice, issuedForEpoch: foreground.epoch)
        let (background, _) = try ContinuityReducer.enterBackground(from: foreground, systemGrant: oldSystemGrant)
        let expired = try ContinuityReducer.systemContinuationExpired(in: background)
        let (newForeground, _) = try ContinuityReducer.startForeground(
            from: expired,
            grant: executionGrant(.foregroundOnDevice, issuedForEpoch: expired.epoch)
        )

        XCTAssertThrowsError(try ContinuityReducer.enterBackground(from: newForeground, systemGrant: oldSystemGrant)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .executionGrantMissing)
        }
    }

    func testExecutionGrantCannotReplayAfterPauseEnvironmentLossAcceptedResultOrMissionProjection() throws {
        let seed = ready()
        let oldForegroundGrant = executionGrant(.foregroundOnDevice)
        let (runningForPause, _) = try ContinuityReducer.startForeground(from: seed, grant: oldForegroundGrant)
        let paused = try ContinuityReducer.pauseByUser(runningForPause)
        XCTAssertThrowsError(try ContinuityReducer.startForeground(from: paused, grant: oldForegroundGrant)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .executionGrantMissing)
        }

        let (runningForLoss, _) = try ContinuityReducer.startForeground(from: seed, grant: oldForegroundGrant)
        let lost = try ContinuityReducer.executionEnvironmentLost(in: runningForLoss)
        XCTAssertThrowsError(try ContinuityReducer.startForeground(from: lost, grant: oldForegroundGrant)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .executionGrantMissing)
        }

        let (runningForResult, lease) = try ContinuityReducer.startForeground(from: seed, grant: oldForegroundGrant)
        let oldCloudGrant = executionGrant(.verifiedCloud, issuedForEpoch: runningForResult.epoch)
        let (afterResult, _) = try ContinuityReducer.accept(
            .init(lease: lease, outcome: .succeeded, summary: "done"),
            in: runningForResult
        )
        XCTAssertThrowsError(try ContinuityReducer.handoffToCloud(from: afterResult, grant: oldCloudGrant)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .executionGrantMissing)
        }

        let projectionCloudGrant = executionGrant(.verifiedCloud)
        let projected = try ContinuityReducer.reflectMissionState(
            authority: projectionAuthority(.ready, identity: seed.identity),
            in: seed
        )
        XCTAssertThrowsError(try ContinuityReducer.handoffToCloud(from: projected, grant: projectionCloudGrant)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .executionGrantMissing)
        }
    }

    func testExecutionGrantCannotReplayAcrossCheckpointAdvance() throws {
        let seed = ready()
        let oldCloudGrant = executionGrant(.verifiedCloud)
        let newer = ContinuityIdentity(
            missionID: seed.identity.missionID,
            projectID: seed.identity.projectID,
            checkpointID: "checkpoint-2",
            missionRevision: 2
        )
        let advanced = try ContinuityReducer.advanceCheckpoint(authority: checkpointAuthority(newer), in: seed)

        XCTAssertThrowsError(try ContinuityReducer.handoffToCloud(from: advanced, grant: oldCloudGrant)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .executionGrantMissing)
        }
    }

    func testMissionAndUserAuthoritiesCannotReplayAcrossEpochChanges() throws {
        let seed = ready()
        let completionAuthority = projectionAuthority(.completed, identity: seed.identity)
        let completed = try ContinuityReducer.reflectMissionCompletion(authority: completionAuthority, in: seed)
        XCTAssertThrowsError(try ContinuityReducer.reflectMissionCompletion(authority: completionAuthority, in: completed)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .invalidAuthority)
        }

        let (running, _) = try ContinuityReducer.startForeground(from: seed, grant: executionGrant(.foregroundOnDevice))
        let firstPause = try ContinuityReducer.pauseByUser(running)
        let resumeAuthority = userResumeAuthority(firstPause.identity, issuedForEpoch: firstPause.epoch)
        let resumed = try ContinuityReducer.resumeAfterUserPause(authority: resumeAuthority, in: firstPause)
        let (runningAgain, _) = try ContinuityReducer.startForeground(
            from: resumed,
            grant: executionGrant(.foregroundOnDevice, issuedForEpoch: resumed.epoch)
        )
        let secondPause = try ContinuityReducer.pauseByUser(runningAgain)
        XCTAssertThrowsError(try ContinuityReducer.resumeAfterUserPause(authority: resumeAuthority, in: secondPause)) {
            XCTAssertEqual($0 as? ContinuityMutationError, .invalidAuthority)
        }
    }

    func testMissionProjectionCannotEraseExplicitUserPause() throws {
        let seed = ready()
        let (running, _) = try ContinuityReducer.startForeground(from: seed, grant: executionGrant(.foregroundOnDevice))
        let paused = try ContinuityReducer.pauseByUser(running)

        XCTAssertThrowsError(try ContinuityReducer.reflectMissionState(
            authority: projectionAuthority(.ready, identity: paused.identity, issuedForEpoch: paused.epoch),
            in: paused
        )) {
            XCTAssertEqual($0 as? ContinuityMutationError, .unsupportedTransition)
        }
        XCTAssertThrowsError(try ContinuityReducer.reflectMissionCompletion(
            authority: projectionAuthority(.completed, identity: paused.identity, issuedForEpoch: paused.epoch),
            in: paused
        )) {
            XCTAssertEqual($0 as? ContinuityMutationError, .unsupportedTransition)
        }
    }

    func testCanonicalIdentityRejectsWhitespaceAliasesAndControls() {
        for bad in [
            ContinuityIdentity(missionID: " mission-1", projectID: "project-1", checkpointID: "checkpoint-1", missionRevision: 1),
            ContinuityIdentity(missionID: "mission-1", projectID: "project-1\n", checkpointID: "checkpoint-1", missionRevision: 1),
            ContinuityIdentity(missionID: "mission-1", projectID: "project-1", checkpointID: "checkpoint\u{0000}1", missionRevision: 1),
            ContinuityIdentity(missionID: "mission-1", projectID: "project-1", checkpointID: "checkpoint-1", missionRevision: 0),
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
        let (background, _) = try ContinuityReducer.enterBackground(from: running, systemGrant: executionGrant(.systemManagedOnDevice, issuedForEpoch: running.epoch))
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

    func testArchiveNeverRestoresMissionOwnedCompletionProjection() throws {
        let base = ready()
        let completed = try ContinuityReducer.reflectMissionCompletion(authority: projectionAuthority(.completed, identity: base.identity), in: base)
        let archive = try ContinuityArchive(snapshot: completed)
        XCTAssertEqual(archive.snapshot.state, .suspended(.missionStateRevalidationRequired))
        XCTAssertEqual(try archive.restore().state, .suspended(.missionStateRevalidationRequired))

        let data = try JSONEncoder().encode(try ContinuityArchive(snapshot: ready()))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
        snapshot["state"] = ["completed": [:]]
        object["snapshot"] = snapshot
        XCTAssertThrowsError(try JSONDecoder().decode(ContinuityArchive.self, from: JSONSerialization.data(withJSONObject: object)))
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
    private func executionGrant(_ mode: ContinuityExecutionMode, identity: ContinuityIdentity? = nil, issuedForEpoch: UInt64 = 0) -> ContinuityExecutionGrant {
        .init(identity: identity ?? self.identity(), mode: mode, issuedForEpoch: issuedForEpoch, authorityReceiptID: "host-receipt-\(mode)-e\(issuedForEpoch)")
    }
    private func userResumeAuthority(_ identity: ContinuityIdentity, issuedForEpoch: UInt64) -> ContinuityUserResumeAuthority {
        .init(identity: identity, issuedForEpoch: issuedForEpoch, authorityReceiptID: "user-resume-authority-e\(issuedForEpoch)")
    }
    private func checkpointAuthority(_ identity: ContinuityIdentity, issuedForEpoch: UInt64 = 0) -> ContinuityMissionAuthority {
        .init(identity: identity, purpose: .checkpointAdvance, issuedForEpoch: issuedForEpoch, authorityReceiptID: "mission-checkpoint-authority-e\(issuedForEpoch)")
    }
    private func projectionAuthority(_ projection: ContinuityMissionProjection, identity: ContinuityIdentity, issuedForEpoch: UInt64 = 0) -> ContinuityMissionAuthority {
        .init(identity: identity, purpose: .stateProjection(projection), issuedForEpoch: issuedForEpoch, authorityReceiptID: "mission-projection-authority-\(projection.rawValue)-e\(issuedForEpoch)")
    }
}

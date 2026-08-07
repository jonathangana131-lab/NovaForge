import ContinuityCore
import Foundation
import XCTest

final class ContinuityCoreTests: XCTestCase {
    func testBackgroundWithoutEligibleContinuationSuspendsAndRejectsOldLease() throws {
        let initial = ready()
        let (running, foregroundLease) = try ContinuityReducer.startForeground(from: initial)

        let (backgrounded, backgroundLease) = try ContinuityReducer.enterBackground(
            from: running,
            capabilities: ContinuityCapabilities(onDeviceContinuation: .unavailable)
        )

        XCTAssertNil(backgroundLease)
        XCTAssertEqual(backgrounded.state, .suspended(.backgroundExecutionUnavailable))
        XCTAssertFalse(ContinuityReducer.accepts(foregroundLease, in: backgrounded))
        XCTAssertEqual(try ContinuityPresentation.activity(for: backgrounded).state, .paused)
        XCTAssertFalse(try ContinuityPresentation.activity(for: backgrounded).isActivelyExecuting)
    }

    func testEligibleSystemManagedContinuationMintsFreshLeaseWithoutForeverClaim() throws {
        let (running, foregroundLease) = try ContinuityReducer.startForeground(from: ready())
        let (backgrounded, backgroundLease) = try ContinuityReducer.enterBackground(
            from: running,
            capabilities: ContinuityCapabilities(onDeviceContinuation: .eligibleSystemManaged)
        )

        let lease = try XCTUnwrap(backgroundLease)
        XCTAssertEqual(lease.mode, .systemManagedOnDevice)
        XCTAssertNotEqual(lease, foregroundLease)
        XCTAssertFalse(ContinuityReducer.accepts(foregroundLease, in: backgrounded))
        XCTAssertTrue(ContinuityReducer.accepts(lease, in: backgrounded))
        let activity = try ContinuityPresentation.activity(for: backgrounded)
        XCTAssertEqual(activity.state, .working)
        XCTAssertEqual(activity.executionMode, .systemManagedOnDevice)
        XCTAssertTrue(activity.isActivelyExecuting)
    }

    func testSystemExpirationStopsWorkAndMakesLeaseStale() throws {
        let (running, _) = try ContinuityReducer.startForeground(from: ready())
        let (backgrounded, lease) = try ContinuityReducer.enterBackground(
            from: running,
            capabilities: ContinuityCapabilities(onDeviceContinuation: .eligibleSystemManaged)
        )
        let active = try XCTUnwrap(lease)

        let expired = try ContinuityReducer.systemContinuationExpired(in: backgrounded)
        XCTAssertEqual(expired.state, .suspended(.systemExpired))
        XCTAssertNil(expired.activeLease)
        XCTAssertFalse(ContinuityReducer.accepts(active, in: expired))
    }

    func testForegroundResumeMintsFreshLeaseAfterSuspension() throws {
        let (running, oldLease) = try ContinuityReducer.startForeground(from: ready())
        let paused = try ContinuityReducer.pauseByUser(running)
        let (resumed, newLease) = try ContinuityReducer.startForeground(from: paused)

        XCTAssertFalse(ContinuityReducer.accepts(oldLease, in: resumed))
        XCTAssertTrue(ContinuityReducer.accepts(newLease, in: resumed))
        XCTAssertGreaterThan(newLease.epoch, oldLease.epoch)
    }

    func testCloudHandoffRequiresVerifiedAuthorizationAndPreservesCheckpointIdentity() throws {
        let (running, oldLease) = try ContinuityReducer.startForeground(from: ready())

        XCTAssertThrowsError(try ContinuityReducer.handoffToCloud(
            from: running,
            capabilities: ContinuityCapabilities(cloud: .discoveredUnverified)
        )) { error in
            XCTAssertEqual(error as? ContinuityMutationError, .cloudUnavailableOrUnauthorized)
        }

        let capabilities = ContinuityCapabilities(cloud: .verifiedAuthorized)
        let (cloud, cloudLease) = try ContinuityReducer.handoffToCloud(
            from: running,
            capabilities: capabilities
        )
        XCTAssertEqual(cloud.identity, running.identity)
        XCTAssertEqual(cloudLease.identity, running.identity)
        XCTAssertEqual(cloudLease.mode, .verifiedCloud)
        XCTAssertFalse(ContinuityReducer.accepts(oldLease, in: cloud))
        XCTAssertTrue(ContinuityReducer.accepts(cloudLease, in: cloud))
    }

    func testHandoffCannotBypassDecisionOrBlockedMissionState() throws {
        let base = ready()
        let decision = ContinuitySnapshot(
            identity: base.identity,
            state: .needsDecision,
            activeLease: nil,
            epoch: 4
        )
        XCTAssertThrowsError(try ContinuityReducer.handoffToCloud(
            from: decision,
            capabilities: ContinuityCapabilities(cloud: .verifiedAuthorized)
        )) { error in
            XCTAssertEqual(error as? ContinuityMutationError, .unsupportedTransition)
        }

        let blocked = ContinuitySnapshot(
            identity: base.identity,
            state: .blocked,
            activeLease: nil,
            epoch: 5
        )
        XCTAssertThrowsError(try ContinuityReducer.handoffToPairedMac(
            from: blocked,
            capabilities: ContinuityCapabilities(pairedMac: .verifiedAuthorized)
        )) { error in
            XCTAssertEqual(error as? ContinuityMutationError, .unsupportedTransition)
        }
    }

    func testPairedMacHandoffRequiresCapabilityVerifiedPairingAndAuthorization() throws {
        let running = try ContinuityReducer.startForeground(from: ready()).0
        XCTAssertThrowsError(try ContinuityReducer.handoffToPairedMac(
            from: running,
            capabilities: ContinuityCapabilities(pairedMac: .verifiedNotAuthorized)
        )) { error in
            XCTAssertEqual(error as? ContinuityMutationError, .pairedMacUnavailableOrUnauthorized)
        }

        let (mac, lease) = try ContinuityReducer.handoffToPairedMac(
            from: running,
            capabilities: ContinuityCapabilities(pairedMac: .verifiedAuthorized)
        )
        XCTAssertEqual(mac.state, .executing(.verifiedPairedMac))
        XCTAssertEqual(lease.mode, .verifiedPairedMac)
    }

    func testCheckpointAdvanceRevokesInFlightWorkerAndRejectsRegression() throws {
        let (running, oldLease) = try ContinuityReducer.startForeground(from: ready())
        let newer = ContinuityIdentity(
            missionID: running.identity.missionID,
            projectID: running.identity.projectID,
            checkpointID: "checkpoint-2",
            missionRevision: running.identity.missionRevision + 1
        )
        let advanced = try ContinuityReducer.advanceCheckpoint(to: newer, in: running)
        XCTAssertEqual(advanced.identity, newer)
        XCTAssertEqual(advanced.state, .ready)
        XCTAssertFalse(ContinuityReducer.accepts(oldLease, in: advanced))

        XCTAssertThrowsError(try ContinuityReducer.advanceCheckpoint(to: newer, in: advanced)) { error in
            XCTAssertEqual(error as? ContinuityMutationError, .checkpointRegression)
        }
    }

    func testCheckpointAdvancePreservesDecisionProjection() throws {
        let base = ready()
        let decision = ContinuitySnapshot(
            identity: base.identity,
            state: .needsDecision,
            activeLease: nil,
            epoch: 9
        )
        let newer = ContinuityIdentity(
            missionID: decision.identity.missionID,
            projectID: decision.identity.projectID,
            checkpointID: "checkpoint-decision-2",
            missionRevision: decision.identity.missionRevision + 1
        )

        let advanced = try ContinuityReducer.advanceCheckpoint(to: newer, in: decision)
        XCTAssertEqual(advanced.identity, newer)
        XCTAssertEqual(advanced.state, .needsDecision)
        XCTAssertNil(advanced.activeLease)
    }

    func testCompletionIsOnlyReflectedFromExactAuthoritativeMissionIdentity() throws {
        let snapshot = ready()
        let completed = try ContinuityReducer.reflectMissionCompletion(
            authoritativeIdentity: snapshot.identity,
            in: snapshot
        )
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(try ContinuityPresentation.activity(for: completed).state, .complete)

        let wrongIdentity = ContinuityIdentity(
            missionID: snapshot.identity.missionID,
            projectID: snapshot.identity.projectID,
            checkpointID: "other-checkpoint",
            missionRevision: snapshot.identity.missionRevision
        )
        XCTAssertThrowsError(try ContinuityReducer.reflectMissionCompletion(
            authoritativeIdentity: wrongIdentity,
            in: snapshot
        )) { error in
            XCTAssertEqual(error as? ContinuityMutationError, .missionCompletionIdentityMismatch)
        }
    }

    func testAcceptedOutcomeClearsLeaseAndProjectsDecisionTruthfully() throws {
        let (running, lease) = try ContinuityReducer.startForeground(from: ready())
        let (decision, receipt) = try ContinuityReducer.accept(
            ContinuityWorkResult(
                lease: lease,
                outcome: .needsDecision,
                summary: "Camera mode needs user choice.",
                evidenceIDs: ["decision:camera"]
            ),
            in: running
        )
        XCTAssertEqual(decision.state, .needsDecision)
        XCTAssertNil(decision.activeLease)
        XCTAssertEqual(receipt.executionMode, .foregroundOnDevice)
        XCTAssertEqual(receipt.evidenceIDs, ["decision:camera"])
        XCTAssertEqual(try ContinuityPresentation.activity(for: decision).state, .needsDecision)
    }

    func testRecoverableFailureCannotKeepWorkingIndicatorAlive() throws {
        let (running, lease) = try ContinuityReducer.startForeground(from: ready())
        let (failed, _) = try ContinuityReducer.accept(
            ContinuityWorkResult(
                lease: lease,
                outcome: .failedRecoverably,
                summary: "Runtime stopped before checkpoint mutation."
            ),
            in: running
        )
        XCTAssertEqual(failed.state, .suspended(.recoverableFailure))
        XCTAssertFalse(try ContinuityPresentation.activity(for: failed).isActivelyExecuting)
        XCTAssertEqual(try ContinuityPresentation.activity(for: failed).state, .paused)
    }

    func testStaleWorkerResultRejectedAfterHandoff() throws {
        let (running, oldLease) = try ContinuityReducer.startForeground(from: ready())
        let (cloud, _) = try ContinuityReducer.handoffToCloud(
            from: running,
            capabilities: ContinuityCapabilities(cloud: .verifiedAuthorized)
        )
        XCTAssertThrowsError(try ContinuityReducer.accept(
            ContinuityWorkResult(lease: oldLease, outcome: .succeeded, summary: "late"),
            in: cloud
        )) { error in
            XCTAssertEqual(error as? ContinuityMutationError, .staleWorkerResult)
        }
    }

    func testNotificationPolicySuppressesChatterButDeliversActionableSignals() {
        XCTAssertEqual(ContinuityNotificationPolicy.disposition(for: .progressTick), .suppress)
        XCTAssertEqual(ContinuityNotificationPolicy.disposition(for: .routineStageChange), .suppress)
        XCTAssertEqual(ContinuityNotificationPolicy.disposition(for: .decisionNeeded), .deliver)
        XCTAssertEqual(ContinuityNotificationPolicy.disposition(for: .blocked), .deliver)
        XCTAssertEqual(ContinuityNotificationPolicy.disposition(for: .requestedMilestone), .deliver)
        XCTAssertEqual(ContinuityNotificationPolicy.disposition(for: .completed), .deliver)
        XCTAssertEqual(ContinuityNotificationPolicy.disposition(for: .requestedDownloadReady), .deliver)
    }

    func testInvalidExecutingSnapshotCannotProjectFalseLiveActivity() throws {
        let invalid = ContinuitySnapshot(
            identity: identity(),
            state: .executing(.systemManagedOnDevice),
            activeLease: nil,
            epoch: 3
        )
        XCTAssertThrowsError(try ContinuityPresentation.activity(for: invalid)) { error in
            XCTAssertEqual(error as? ContinuityMutationError, .invalidSnapshot)
        }
    }

    func testArchiveRoundTripIsDeterministicAndRejectsBadSchema() throws {
        let archive = try ContinuityArchive(snapshot: ready(), transfers: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        let decoded = try JSONDecoder().decode(ContinuityArchive.self, from: data)
        XCTAssertEqual(decoded, archive)
        XCTAssertEqual(try encoder.encode(decoded), data)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 999
        let bad = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ContinuityArchive.self, from: bad))
    }

    func testArchiveRejectsImpossibleExecutingSnapshot() throws {
        let invalid = ContinuitySnapshot(
            identity: identity(),
            state: .executing(.verifiedCloud),
            activeLease: nil,
            epoch: 2
        )
        XCTAssertThrowsError(try ContinuityArchive(snapshot: invalid)) { error in
            XCTAssertEqual(error as? ContinuityArchiveError, .invalidSnapshot)
        }
    }

    func testBackgroundTransferSuspendsAndResumesWithoutLosingProgress() throws {
        let queued = BackgroundTransferSnapshot(
            transferID: "model-download-1",
            assetID: "model.gguf",
            expectedBytes: 1_000
        )
        let running = try BackgroundTransferReducer.start(queued)
        let progressed = try BackgroundTransferReducer.recordProgress(
            receivedBytes: 400,
            expectedBytes: 1_000,
            in: running
        )
        let suspended = try BackgroundTransferReducer.suspend(
            resumeOpaqueToken: "resume-ref-1",
            in: progressed
        )
        XCTAssertTrue(suspended.canResume)

        let resumed = try BackgroundTransferReducer.resume(suspended)
        XCTAssertEqual(resumed.receivedBytes, 400)
        XCTAssertEqual(resumed.expectedBytes, 1_000)
        XCTAssertEqual(resumed.state, .running)
        XCTAssertNil(resumed.resumeOpaqueToken)
    }

    func testBackgroundTransferDoesNotSilentlyChangeKnownExpectedSize() throws {
        let running = try BackgroundTransferReducer.start(
            BackgroundTransferSnapshot(
                transferID: "asset-size",
                assetID: "pack.zip",
                expectedBytes: 1_000
            )
        )
        XCTAssertThrowsError(try BackgroundTransferReducer.recordProgress(
            receivedBytes: 100,
            expectedBytes: 900,
            in: running
        )) { error in
            XCTAssertEqual(error as? BackgroundTransferError, .invalidByteCount)
        }
    }

    func testNonResumableFailedTransferRestartsFromZero() throws {
        let running = try BackgroundTransferReducer.start(
            BackgroundTransferSnapshot(
                transferID: "asset-restart",
                assetID: "model.gguf",
                expectedBytes: 1_000
            )
        )
        let progressed = try BackgroundTransferReducer.recordProgress(
            receivedBytes: 450,
            expectedBytes: 1_000,
            in: running
        )
        let failed = try BackgroundTransferReducer.fail(progressed)
        XCTAssertEqual(failed.receivedBytes, 450)
        let restarted = try BackgroundTransferReducer.restartFromBeginning(failed)
        XCTAssertEqual(restarted.receivedBytes, 0)
        XCTAssertEqual(restarted.state, .running)
    }

    func testBackgroundTransferRejectsProgressRegressionAndPrematureCompletion() throws {
        let running = try BackgroundTransferReducer.start(
            BackgroundTransferSnapshot(
                transferID: "asset-1",
                assetID: "pack.zip",
                expectedBytes: 1_000
            )
        )
        let progressed = try BackgroundTransferReducer.recordProgress(
            receivedBytes: 500,
            expectedBytes: 1_000,
            in: running
        )
        XCTAssertThrowsError(try BackgroundTransferReducer.recordProgress(
            receivedBytes: 499,
            expectedBytes: 1_000,
            in: progressed
        )) { error in
            XCTAssertEqual(error as? BackgroundTransferError, .byteCountRegression)
        }
        XCTAssertThrowsError(try BackgroundTransferReducer.complete(progressed)) { error in
            XCTAssertEqual(error as? BackgroundTransferError, .invalidByteCount)
        }
    }

    func testArchiveRejectsDuplicateTransferIdentity() throws {
        let a = BackgroundTransferSnapshot(transferID: "same", assetID: "a")
        let b = BackgroundTransferSnapshot(transferID: "same", assetID: "b")
        XCTAssertThrowsError(try ContinuityArchive(snapshot: ready(), transfers: [a, b])) { error in
            XCTAssertEqual(error as? ContinuityArchiveError, .duplicateTransferID("same"))
        }
    }

    private func identity() -> ContinuityIdentity {
        ContinuityIdentity(
            missionID: "mission-1",
            projectID: "project-1",
            checkpointID: "checkpoint-1",
            missionRevision: 7
        )
    }

    private func ready() -> ContinuitySnapshot {
        ContinuitySnapshot(identity: identity())
    }
}

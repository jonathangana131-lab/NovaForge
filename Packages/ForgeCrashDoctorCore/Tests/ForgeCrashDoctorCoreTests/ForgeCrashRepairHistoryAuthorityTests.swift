import Foundation
import XCTest
@testable import ForgeCrashDoctorCore

final class ForgeCrashRepairHistoryAuthorityTests: XCTestCase {
    func testTrustedHistoryRejectsRewrittenRepeatKeyCandidate() throws {
        let incident = try makeIncident()
        let trustedIncident = try ForgeCrashTrustedIncident(
            authenticatedIncident: incident,
            artifactIdentity: String(repeating: "a", count: 64)
        )
        let authenticKey = ForgeCrashRepeatKey.derive(from: incident)
        let authenticHistory = try ForgeCrashRepairHistory(attempts: [
            try ForgeCrashRepairAttempt(
                sequence: 1,
                incidentID: incident.incidentID,
                repeatKey: authenticKey,
                failureKind: .sameCrashReturned
            ),
            try ForgeCrashRepairAttempt(
                sequence: 2,
                incidentID: incident.incidentID,
                repeatKey: authenticKey,
                failureKind: .focusedVerificationFailed
            ),
        ])
        let trustedHistory = try ForgeCrashTrustedRepairHistory(
            authenticatedHistory: authenticHistory,
            failureArtifactIdentities: [
                String(repeating: "b", count: 64),
                String(repeating: "c", count: 64),
            ]
        )

        let unrelatedIncident = try makeIncident(
            incidentID: "incident-other",
            source: try ForgeCrashSourceLocation(file: "other.js", line: 7, symbol: "other")
        )
        let rewrittenHistory = try ForgeCrashRepairHistory(attempts: [
            try ForgeCrashRepairAttempt(
                sequence: 1,
                incidentID: incident.incidentID,
                repeatKey: ForgeCrashRepeatKey.derive(from: unrelatedIncident),
                failureKind: .sameCrashReturned
            ),
            try ForgeCrashRepairAttempt(
                sequence: 2,
                incidentID: incident.incidentID,
                repeatKey: ForgeCrashRepeatKey.derive(from: unrelatedIncident),
                failureKind: .focusedVerificationFailed
            ),
        ])

        XCTAssertFalse(trustedHistory.matches(rewrittenHistory))

        let trustedPolicy = try ForgeCrashTrustedRetryPolicy(
            authenticatedPolicy: try ForgeCrashRetryPolicy(),
            artifactIdentity: String(repeating: "f", count: 64)
        )
        let submission = ForgeCrashTriage.makeSubmission(
            for: trustedIncident,
            failedHistory: trustedHistory,
            policy: trustedPolicy
        )
        XCTAssertEqual(submission.nextAction, .rootCauseAnalysis(repeatedFailures: 2))
    }

    func testTrustedHistoryRejectsMissingOrReusedFailureEvidence() throws {
        let incident = try makeIncident()
        let key = ForgeCrashRepeatKey.derive(from: incident)
        let history = try ForgeCrashRepairHistory(attempts: [
            try ForgeCrashRepairAttempt(
                sequence: 1,
                incidentID: incident.incidentID,
                repeatKey: key,
                failureKind: .sameCrashReturned
            ),
            try ForgeCrashRepairAttempt(
                sequence: 2,
                incidentID: incident.incidentID,
                repeatKey: key,
                failureKind: .verificationInterrupted
            ),
        ])

        XCTAssertThrowsError(
            try ForgeCrashTrustedRepairHistory(
                authenticatedHistory: history,
                failureArtifactIdentities: [String(repeating: "d", count: 64)]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .repairHistoryEvidenceMismatch)
        }

        let replayedIdentity = String(repeating: "e", count: 64)
        XCTAssertThrowsError(
            try ForgeCrashTrustedRepairHistory(
                authenticatedHistory: history,
                failureArtifactIdentities: [replayedIdentity, replayedIdentity]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .repairHistoryEvidenceMismatch)
        }
    }

    func testTrustedHistoryRejectsNonCanonicalFailureArtifactIdentity() throws {
        let incident = try makeIncident()
        let history = try ForgeCrashRepairHistory(attempts: [
            try ForgeCrashRepairAttempt(
                sequence: 1,
                incidentID: incident.incidentID,
                repeatKey: ForgeCrashRepeatKey.derive(from: incident),
                failureKind: .sameCrashReturned
            ),
        ])

        XCTAssertThrowsError(
            try ForgeCrashTrustedRepairHistory(
                authenticatedHistory: history,
                failureArtifactIdentities: [String(repeating: "F", count: 64)]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidArtifactIdentity)
        }
    }

    func testTrustedPolicyPreventsCallerFromRelaxingEscalationBudget() throws {
        let strictPolicy = try ForgeCrashRetryPolicy(
            maximumFocusedFailuresPerRepeatKey: 2,
            maximumTotalFailuresBeforeBlocker: 6
        )
        let relaxedCandidate = try ForgeCrashRetryPolicy(
            maximumFocusedFailuresPerRepeatKey: 99,
            maximumTotalFailuresBeforeBlocker: 99
        )
        let trustedPolicy = try ForgeCrashTrustedRetryPolicy(
            authenticatedPolicy: strictPolicy,
            artifactIdentity: String(repeating: "1", count: 64)
        )

        XCTAssertTrue(trustedPolicy.matches(strictPolicy))
        XCTAssertFalse(trustedPolicy.matches(relaxedCandidate))
    }

    func testTrustedPolicyRejectsNonCanonicalArtifactIdentity() throws {
        XCTAssertThrowsError(
            try ForgeCrashTrustedRetryPolicy(
                authenticatedPolicy: try ForgeCrashRetryPolicy(),
                artifactIdentity: String(repeating: "A", count: 64)
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidArtifactIdentity)
        }
    }

    private func makeIncident(
        incidentID: String = "incident-1",
        source: ForgeCrashSourceLocation? = try? ForgeCrashSourceLocation(
            file: "game.js",
            line: 42,
            column: 3,
            symbol: "updatePlayer"
        )
    ) throws -> ForgeCrashIncident {
        try ForgeCrashIncident(
            incidentID: incidentID,
            projectID: "project-1",
            checkpointID: "checkpoint-9",
            projectRevision: "revision-abc",
            runtimeVersion: "runtime-1",
            runtimeSessionID: "session-5",
            occurredAt: Date(timeIntervalSince1970: 1_786_250_000),
            kind: .runtimeException,
            message: "TypeError: player is undefined",
            sourceLocation: source,
            stackFrames: [
                try ForgeCrashStackFrame(
                    symbol: source?.symbol ?? "updatePlayer",
                    file: source?.file ?? "game.js",
                    line: source?.line ?? 42,
                    column: source?.column ?? 3
                ),
            ]
        )
    }
}

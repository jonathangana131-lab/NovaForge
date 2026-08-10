import Foundation
import XCTest
@testable import ForgeCrashDoctorCore

final class ForgeCrashDoctorCoreTests: XCTestCase {
    func testValidatedIncidentRoundTripsWithoutGainingTrust() throws {
        let incident = try makeIncident()
        XCTAssertEqual(try JSONDecoder().decode(ForgeCrashIncident.self, from: JSONEncoder().encode(incident)), incident)
    }

    func testDecodeReentersStackFrameLimitValidation() throws {
        let incident = try makeIncident()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(incident)) as? [String: Any])
        let frame: [String: Any] = ["symbol": "tick", "file": "game.js", "line": 42, "column": 3]
        object["stackFrames"] = Array(repeating: frame, count: 65)
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashIncident.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .tooManyStackFrames(65))
        }
    }

    func testIdentityRejectsWhitespaceAliases() throws {
        XCTAssertThrowsError(try makeIncident(incidentID: "incident 1")) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidIdentity(field: "incident.id"))
        }
    }

    func testTrustedIncidentMatchesWholeAuthenticatedSubject() throws {
        let incident = try makeIncident(message: "TypeError: player is undefined")
        let trusted = try trust(incident, artifact: "a")
        XCTAssertTrue(trusted.matches(incident))
        XCTAssertFalse(trusted.matches(try makeIncident(message: "TypeError: player is null")))
    }

    func testRepeatKeyUsesStructuralLocationInsteadOfMutableMessage() throws {
        let first = try makeIncident(message: "TypeError: player 17 is undefined")
        let second = try makeIncident(message: "TypeError: player 88 is undefined")
        XCTAssertEqual(ForgeCrashRepeatKey.derive(from: first), ForgeCrashRepeatKey.derive(from: second))
    }

    func testRepeatKeyPreservesCaseSensitiveSourceIdentity() throws {
        let upper = try makeIncident(source: try ForgeCrashSourceLocation(file: "Player.js", line: 42, symbol: "UpdatePlayer"))
        let lower = try makeIncident(source: try ForgeCrashSourceLocation(file: "player.js", line: 42, symbol: "updatePlayer"))
        XCTAssertNotEqual(ForgeCrashRepeatKey.derive(from: upper), ForgeCrashRepeatKey.derive(from: lower))
    }

    func testDecodedRepeatKeyCannotBypassBounds() throws {
        let attempt = try ForgeCrashRepairAttempt(
            sequence: 1,
            incidentID: "incident-1",
            repeatKey: ForgeCrashRepeatKey.derive(from: try makeIncident()),
            failureKind: .sameCrashReturned
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt)) as? [String: Any])
        var repeatKey = try XCTUnwrap(object["repeatKey"] as? [String: Any])
        repeatKey["sourceFile"] = String(repeating: "x", count: 1_025)
        object["repeatKey"] = repeatKey
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashRepairAttempt.self, from: data)) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .fieldTooLong(field: "repeat.sourceFile", maximum: 1_024))
        }
    }

    func testRetryPolicyCannotExceedDurableHistoryCapacity() throws {
        XCTAssertThrowsError(
            try ForgeCrashRetryPolicy(maximumFocusedFailuresPerRepeatKey: 2, maximumTotalFailuresBeforeBlocker: 129)
        ) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidPositiveInteger(field: "policy.totalFailures"))
        }
    }

    func testTriageStartsWithFocusedRepairFromTrustedControl() throws {
        let current = try trust(makeIncident(), artifact: "b")
        let control = try trustedControl(current: current, attempts: [])
        let submission = try ForgeCrashTriage.makeSubmission(for: current, trustedControl: control)
        XCTAssertEqual(submission.nextAction, .focusedRepair(attemptNumber: 1))
    }

    func testAuthenticatedRepeatedCrashPromotesToRootCauseAnalysis() throws {
        let current = try trust(makeIncident(), artifact: "b")
        let prior1 = try ForgeCrashTrustedFailedAttempt(sequence: 1, trustedIncident: trust(makeIncident(incidentID: "incident-2"), artifact: "c"), failureKind: .sameCrashReturned)
        let prior2 = try ForgeCrashTrustedFailedAttempt(sequence: 2, trustedIncident: trust(makeIncident(incidentID: "incident-3", message: "different text"), artifact: "d"), failureKind: .focusedVerificationFailed)
        let control = try trustedControl(current: current, attempts: [prior1, prior2])
        let submission = try ForgeCrashTriage.makeSubmission(for: current, trustedControl: control)
        XCTAssertEqual(submission.nextAction, .rootCauseAnalysis(repeatedFailures: 2))
    }

    func testAuthenticatedDifferentCrashDoesNotConsumeRepeatBudget() throws {
        let current = try trust(makeIncident(), artifact: "b")
        let unrelated = try makeIncident(
            incidentID: "incident-other",
            source: try ForgeCrashSourceLocation(file: "assets.js", line: 9, symbol: "loadAsset"),
            stackFrames: [try ForgeCrashStackFrame(symbol: "loadAsset", file: "assets.js", line: 9)]
        )
        let prior = try ForgeCrashTrustedFailedAttempt(sequence: 1, trustedIncident: trust(unrelated, artifact: "e"), failureKind: .sameCrashReturned)
        let control = try trustedControl(current: current, attempts: [prior])
        let submission = try ForgeCrashTriage.makeSubmission(for: current, trustedControl: control)
        XCTAssertEqual(submission.nextAction, .focusedRepair(attemptNumber: 1))
    }

    func testForeignRevisionCannotPoisonTrustedRepairControl() throws {
        let current = try trust(makeIncident(), artifact: "b")
        let foreign = try trust(makeIncident(incidentID: "foreign", projectRevision: "revision-other"), artifact: "f")
        let attempt = try ForgeCrashTrustedFailedAttempt(sequence: 1, trustedIncident: foreign, failureKind: .sameCrashReturned)
        let policy = try ForgeCrashTrustedRetryPolicy(authenticatedPolicy: ForgeCrashRetryPolicy(), policyRevision: "policy-v1")
        XCTAssertThrowsError(
            try ForgeCrashTrustedRepairControl(currentIncident: current, failedAttempts: [attempt], trustedPolicy: policy)
        ) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .repairScopeMismatch)
        }
    }

    func testRuntimeSessionRelaunchKeepsSameRepairBudgetScope() throws {
        let current = try trust(makeIncident(runtimeSessionID: "session-9"), artifact: "b")
        let priorIncident = try trust(makeIncident(incidentID: "prior", runtimeSessionID: "session-5"), artifact: "c")
        let prior = try ForgeCrashTrustedFailedAttempt(sequence: 1, trustedIncident: priorIncident, failureKind: .sameCrashReturned)
        XCTAssertNoThrow(try trustedControl(current: current, attempts: [prior]))
    }

    func testTrustedPolicyControlsTotalFailureBlocker() throws {
        let current = try trust(makeIncident(), artifact: "b")
        let attempts = try (1...6).map { sequence in
            try ForgeCrashTrustedFailedAttempt(
                sequence: sequence,
                trustedIncident: trust(makeIncident(incidentID: "incident-\(sequence)"), artifact: String(format: "%x", (sequence % 6) + 10)),
                failureKind: .verificationInterrupted
            )
        }
        let control = try trustedControl(
            current: current,
            attempts: attempts,
            policy: try ForgeCrashRetryPolicy(maximumFocusedFailuresPerRepeatKey: 4, maximumTotalFailuresBeforeBlocker: 6)
        )
        let submission = try ForgeCrashTriage.makeSubmission(for: current, trustedControl: control)
        XCTAssertEqual(submission.nextAction, .surfaceBlocker(totalFailures: 6))
    }

    private func trustedControl(
        current: ForgeCrashTrustedIncident,
        attempts: [ForgeCrashTrustedFailedAttempt],
        policy: ForgeCrashRetryPolicy = try! ForgeCrashRetryPolicy()
    ) throws -> ForgeCrashTrustedRepairControl {
        let trustedPolicy = try ForgeCrashTrustedRetryPolicy(authenticatedPolicy: policy, policyRevision: "policy-v1")
        return try ForgeCrashTrustedRepairControl(currentIncident: current, failedAttempts: attempts, trustedPolicy: trustedPolicy)
    }

    private func trust(_ incident: ForgeCrashIncident, artifact: String) throws -> ForgeCrashTrustedIncident {
        try ForgeCrashTrustedIncident(authenticatedIncident: incident, artifactIdentity: String(repeating: artifact, count: 64))
    }

    private func makeIncident(
        incidentID: String = "incident-1",
        projectID: String = "project-1",
        checkpointID: String = "checkpoint-9",
        projectRevision: String = "revision-abc",
        runtimeVersion: String = "runtime-1",
        runtimeSessionID: String = "session-5",
        message: String = "TypeError: player is undefined",
        source: ForgeCrashSourceLocation? = try? ForgeCrashSourceLocation(file: "game.js", line: 42, column: 3, symbol: "updatePlayer"),
        stackFrames: [ForgeCrashStackFrame] = [try! ForgeCrashStackFrame(symbol: "updatePlayer", file: "game.js", line: 42, column: 3)]
    ) throws -> ForgeCrashIncident {
        try ForgeCrashIncident(
            incidentID: incidentID,
            projectID: projectID,
            checkpointID: checkpointID,
            projectRevision: projectRevision,
            runtimeVersion: runtimeVersion,
            runtimeSessionID: runtimeSessionID,
            occurredAt: Date(timeIntervalSince1970: 1_786_250_000),
            kind: .runtimeException,
            message: message,
            sourceLocation: source,
            stackFrames: stackFrames,
            consoleEntries: [try ForgeCrashConsoleEntry(sequence: 10, level: .error, message: message, source: "game.js")]
        )
    }
}

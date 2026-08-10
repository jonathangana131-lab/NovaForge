import Foundation
import XCTest
@testable import ForgeCrashDoctorCore

final class ForgeCrashDoctorCoreTests: XCTestCase {
    func testValidatedIncidentRoundTripsWithoutGainingTrust() throws {
        let incident = try makeIncident()
        let data = try JSONEncoder().encode(incident)
        let decoded = try JSONDecoder().decode(ForgeCrashIncident.self, from: data)
        XCTAssertEqual(decoded, incident)
    }

    func testDecodeReentersStackFrameLimitValidation() throws {
        let incident = try makeIncident()
        let data = try JSONEncoder().encode(incident)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let frame: [String: Any] = ["symbol": "tick", "file": "game.js", "line": 42, "column": 3]
        object["stackFrames"] = Array(repeating: frame, count: 65)
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashIncident.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .tooManyStackFrames(65))
        }
    }

    func testDecodeReentersMonotonicActionValidation() throws {
        let incident = try makeIncident(actions: [
            try ForgeCrashSemanticAction(sequence: 1, actionID: "a1", intent: "move"),
            try ForgeCrashSemanticAction(sequence: 2, actionID: "a2", intent: "jump"),
        ])
        let data = try JSONEncoder().encode(incident)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var actions = try XCTUnwrap(object["recentActions"] as? [[String: Any]])
        actions[1]["sequence"] = 1
        object["recentActions"] = actions
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashIncident.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .nonMonotonicSequence(field: "action.sequence"))
        }
    }

    func testIncidentIdentityRejectsEmbeddedControlCharacters() {
        XCTAssertThrowsError(try makeIncident(incidentID: "incident\u{0}forged")) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidControlCharacter(field: "incident.id"))
        }
    }

    func testTrustedIncidentMatchesWholeAuthenticatedSubject() throws {
        let incident = try makeIncident(message: "TypeError: player is undefined")
        let trusted = try ForgeCrashTrustedIncident(
            authenticatedIncident: incident,
            artifactIdentity: String(repeating: "a", count: 64)
        )
        let altered = try makeIncident(message: "TypeError: player is null")
        XCTAssertTrue(trusted.matches(incident))
        XCTAssertFalse(trusted.matches(altered))
    }

    func testTrustedIncidentRejectsNonCanonicalArtifactIdentity() throws {
        let incident = try makeIncident()
        XCTAssertThrowsError(
            try ForgeCrashTrustedIncident(
                authenticatedIncident: incident,
                artifactIdentity: String(repeating: "A", count: 64)
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidArtifactIdentity)
        }
    }

    func testRepeatKeyUsesStructuralLocationInsteadOfMutableMessage() throws {
        let first = try makeIncident(message: "TypeError: player 17 is undefined")
        let second = try makeIncident(message: "TypeError: player 88 is undefined")
        XCTAssertEqual(ForgeCrashRepeatKey.derive(from: first), ForgeCrashRepeatKey.derive(from: second))
    }

    func testRepeatKeyPreservesCaseSensitiveSourceIdentity() throws {
        let upper = try makeIncident(
            source: try ForgeCrashSourceLocation(file: "Player.js", line: 42, symbol: "UpdatePlayer"),
            stackFrames: [try ForgeCrashStackFrame(symbol: "UpdatePlayer", file: "Player.js", line: 42)]
        )
        let lower = try makeIncident(
            source: try ForgeCrashSourceLocation(file: "player.js", line: 42, symbol: "updatePlayer"),
            stackFrames: [try ForgeCrashStackFrame(symbol: "updatePlayer", file: "player.js", line: 42)]
        )
        XCTAssertNotEqual(ForgeCrashRepeatKey.derive(from: upper), ForgeCrashRepeatKey.derive(from: lower))
    }

    func testRepeatKeyFallsBackToNormalizedMessageWhenNoLocationExists() throws {
        let first = try makeIncident(message: "  Network   bootstrap failed  ", source: nil, stackFrames: [])
        let second = try makeIncident(message: "network bootstrap failed", source: nil, stackFrames: [])
        XCTAssertEqual(ForgeCrashRepeatKey.derive(from: first), ForgeCrashRepeatKey.derive(from: second))
    }

    func testDecodedRepeatKeyCannotBypassStructuralBounds() throws {
        let incident = try makeIncident()
        let key = ForgeCrashRepeatKey.derive(from: incident)
        let data = try JSONEncoder().encode(key)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["sourceFile"] = String(repeating: "x", count: 1_025)
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashRepeatKey.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .fieldTooLong(field: "repeat.sourceFile", maximum: 1_024))
        }
    }

    func testDecodedRepeatKeyRejectsControlCharacters() throws {
        let incident = try makeIncident()
        let key = ForgeCrashRepeatKey.derive(from: incident)
        let data = try JSONEncoder().encode(key)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["topStackSymbol"] = "update\u{0}Player"
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashRepeatKey.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidControlCharacter(field: "repeat.topStackSymbol"))
        }
    }

    func testDecodedRepairAttemptCannotBypassSequenceValidation() throws {
        let incident = try makeIncident()
        let attempt = try makeAttempt(sequence: 1, incident: incident)
        let data = try JSONEncoder().encode(attempt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["sequence"] = 0
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashRepairAttempt.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidPositiveInteger(field: "repair.sequence"))
        }
    }

    func testRepairHistoryRejectsForeignRuntimeSubject() throws {
        let incident = try makeIncident()
        let subject = try ForgeCrashRepairSubject(incident: incident)
        let foreign = try makeIncident(runtimeSessionID: "session-other")
        let attempt = try makeAttempt(sequence: 1, incident: foreign)

        XCTAssertThrowsError(try ForgeCrashRepairHistory(subject: subject, attempts: [attempt])) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .repairSubjectMismatch)
        }
    }

    func testRepairHistoryRejectsDuplicateOrReorderedSequences() throws {
        let incident = try makeIncident()
        let subject = try ForgeCrashRepairSubject(incident: incident)
        let first = try makeAttempt(sequence: 2, incident: incident)
        let duplicate = try makeAttempt(sequence: 2, incident: incident, failureKind: .focusedVerificationFailed)

        XCTAssertThrowsError(try ForgeCrashRepairHistory(subject: subject, attempts: [first, duplicate])) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .nonMonotonicSequence(field: "repair.sequence"))
        }
    }

    func testDecodedRepairHistoryRevalidatesSubjectScope() throws {
        let incident = try makeIncident()
        let history = try makeHistory(for: incident, attempts: [try makeAttempt(sequence: 1, incident: incident)])
        let data = try JSONEncoder().encode(history)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var attempts = try XCTUnwrap(object["attempts"] as? [[String: Any]])
        var subject = try XCTUnwrap(attempts[0]["subject"] as? [String: Any])
        subject["runtimeSessionID"] = "session-forged"
        attempts[0]["subject"] = subject
        object["attempts"] = attempts
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashRepairHistory.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .repairSubjectMismatch)
        }
    }

    func testDecodedRetryPolicyCannotBypassBudgetValidation() throws {
        let policy = try ForgeCrashRetryPolicy()
        let data = try JSONEncoder().encode(policy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["maximumFocusedFailuresPerRepeatKey"] = 4
        object["maximumTotalFailuresBeforeBlocker"] = 3
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashRetryPolicy.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidPositiveInteger(field: "policy.totalFailures"))
        }
    }

    func testPolicyCannotExceedDurableHistoryCapacity() {
        XCTAssertThrowsError(
            try ForgeCrashRetryPolicy(
                maximumFocusedFailuresPerRepeatKey: 2,
                maximumTotalFailuresBeforeBlocker: ForgeCrashRetryPolicy.maximumDurableFailures + 1
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidPositiveInteger(field: "policy.totalFailures"))
        }
    }

    func testTrustedRepairControlRejectsForeignHistorySubject() throws {
        let trusted = try makeTrustedIncident()
        let foreign = try makeIncident(runtimeSessionID: "session-other")
        let foreignHistory = try makeHistory(for: foreign)

        XCTAssertThrowsError(
            try ForgeCrashTrustedRepairControl(
                trustedIncident: trusted,
                authenticatedHistory: foreignHistory,
                authenticatedPolicy: ForgeCrashRetryPolicy(),
                controlIdentity: String(repeating: "c", count: 64)
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .repairSubjectMismatch)
        }
    }

    func testTriageStartsWithFocusedRepairOnlyFromTrustedControl() throws {
        let trusted = try makeTrustedIncident()
        let control = try makeControl(for: trusted)

        let submission = try ForgeCrashTriage.makeSubmission(for: trusted, control: control)

        XCTAssertEqual(submission.nextAction, .focusedRepair(attemptNumber: 1))
        XCTAssertEqual(submission.trustedIncident, trusted)
        XCTAssertEqual(submission.controlIdentity, String(repeating: "c", count: 64))
    }

    func testRepeatedCrashPromotesToRootCauseAnalysis() throws {
        let trusted = try makeTrustedIncident()
        let incident = trusted.incident
        let attempts = [
            try makeAttempt(sequence: 1, incident: incident),
            try makeAttempt(sequence: 2, incident: incident, failureKind: .focusedVerificationFailed),
        ]
        let control = try makeControl(for: trusted, attempts: attempts)

        let submission = try ForgeCrashTriage.makeSubmission(for: trusted, control: control)
        XCTAssertEqual(submission.nextAction, .rootCauseAnalysis(repeatedFailures: 2))
    }

    func testDifferentCrashOnSameRuntimeSubjectDoesNotConsumeFocusedRetryBudget() throws {
        let trusted = try makeTrustedIncident()
        let unrelated = try makeIncident(
            incidentID: "incident-other",
            message: "asset failed",
            source: try ForgeCrashSourceLocation(file: "assets.js", line: 9, symbol: "loadAsset"),
            stackFrames: [try ForgeCrashStackFrame(symbol: "loadAsset", file: "assets.js", line: 9)]
        )
        let control = try makeControl(for: trusted, attempts: [try makeAttempt(sequence: 1, incident: unrelated)])

        let submission = try ForgeCrashTriage.makeSubmission(for: trusted, control: control)
        XCTAssertEqual(submission.nextAction, .focusedRepair(attemptNumber: 1))
    }

    func testTotalFailureCapSurfacesBlockerBeforeHistoryCapacityIsExceeded() throws {
        let trusted = try makeTrustedIncident()
        let incident = trusted.incident
        let unrelated = try makeIncident(
            incidentID: "incident-unrelated",
            source: try ForgeCrashSourceLocation(file: "other.js", line: 7, symbol: "other"),
            stackFrames: [try ForgeCrashStackFrame(symbol: "other", file: "other.js", line: 7)]
        )
        let attempts = try (1...6).map { sequence in
            try makeAttempt(
                sequence: sequence,
                incident: sequence.isMultiple(of: 2) ? incident : unrelated,
                failureKind: .verificationInterrupted
            )
        }
        let control = try makeControl(
            for: trusted,
            attempts: attempts,
            policy: ForgeCrashRetryPolicy(maximumFocusedFailuresPerRepeatKey: 4, maximumTotalFailuresBeforeBlocker: 6)
        )

        let submission = try ForgeCrashTriage.makeSubmission(for: trusted, control: control)
        XCTAssertEqual(submission.nextAction, .surfaceBlocker(totalFailures: 6))
    }

    func testExactDurableFailureCeilingCanStillSurfaceBlocker() throws {
        let trusted = try makeTrustedIncident()
        let incident = trusted.incident
        let attempts = try (1...ForgeCrashRetryPolicy.maximumDurableFailures).map { sequence in
            try makeAttempt(sequence: sequence, incident: incident, failureKind: .verificationInterrupted)
        }
        let control = try makeControl(
            for: trusted,
            attempts: attempts,
            policy: ForgeCrashRetryPolicy(
                maximumFocusedFailuresPerRepeatKey: 2,
                maximumTotalFailuresBeforeBlocker: ForgeCrashRetryPolicy.maximumDurableFailures
            )
        )

        let submission = try ForgeCrashTriage.makeSubmission(for: trusted, control: control)
        XCTAssertEqual(
            submission.nextAction,
            .surfaceBlocker(totalFailures: ForgeCrashRetryPolicy.maximumDurableFailures)
        )
    }

    func testPolicyRejectsTotalBudgetBelowFocusedBudget() {
        XCTAssertThrowsError(
            try ForgeCrashRetryPolicy(maximumFocusedFailuresPerRepeatKey: 4, maximumTotalFailuresBeforeBlocker: 3)
        ) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidPositiveInteger(field: "policy.totalFailures"))
        }
    }

    private func makeTrustedIncident() throws -> ForgeCrashTrustedIncident {
        try ForgeCrashTrustedIncident(
            authenticatedIncident: makeIncident(),
            artifactIdentity: String(repeating: "b", count: 64)
        )
    }

    private func makeControl(
        for trusted: ForgeCrashTrustedIncident,
        attempts: [ForgeCrashRepairAttempt] = [],
        policy: ForgeCrashRetryPolicy = try! ForgeCrashRetryPolicy()
    ) throws -> ForgeCrashTrustedRepairControl {
        try ForgeCrashTrustedRepairControl(
            trustedIncident: trusted,
            authenticatedHistory: makeHistory(for: trusted.incident, attempts: attempts),
            authenticatedPolicy: policy,
            controlIdentity: String(repeating: "c", count: 64)
        )
    }

    private func makeHistory(
        for incident: ForgeCrashIncident,
        attempts: [ForgeCrashRepairAttempt] = []
    ) throws -> ForgeCrashRepairHistory {
        try ForgeCrashRepairHistory(subject: ForgeCrashRepairSubject(incident: incident), attempts: attempts)
    }

    private func makeAttempt(
        sequence: Int,
        incident: ForgeCrashIncident,
        failureKind: ForgeCrashRepairFailureKind = .sameCrashReturned
    ) throws -> ForgeCrashRepairAttempt {
        try ForgeCrashRepairAttempt(
            sequence: sequence,
            subject: ForgeCrashRepairSubject(incident: incident),
            incidentID: incident.incidentID,
            repeatKey: ForgeCrashRepeatKey.derive(from: incident),
            failureKind: failureKind
        )
    }

    private func makeIncident(
        incidentID: String = "incident-1",
        message: String = "TypeError: player is undefined",
        runtimeSessionID: String = "session-5",
        source: ForgeCrashSourceLocation? = try? ForgeCrashSourceLocation(
            file: "game.js",
            line: 42,
            column: 3,
            symbol: "updatePlayer"
        ),
        stackFrames: [ForgeCrashStackFrame] = [
            try! ForgeCrashStackFrame(symbol: "updatePlayer", file: "game.js", line: 42, column: 3),
            try! ForgeCrashStackFrame(symbol: "tick", file: "loop.js", line: 10, column: 1),
        ],
        actions: [ForgeCrashSemanticAction] = []
    ) throws -> ForgeCrashIncident {
        try ForgeCrashIncident(
            incidentID: incidentID,
            projectID: "project-1",
            checkpointID: "checkpoint-9",
            projectRevision: "revision-abc",
            runtimeVersion: "runtime-1",
            runtimeSessionID: runtimeSessionID,
            occurredAt: Date(timeIntervalSince1970: 1_786_250_000),
            kind: .runtimeException,
            message: message,
            sourceLocation: source,
            stackFrames: stackFrames,
            consoleEntries: [
                try ForgeCrashConsoleEntry(sequence: 10, level: .warning, message: "frame delayed"),
                try ForgeCrashConsoleEntry(sequence: 11, level: .error, message: message, source: "game.js"),
            ],
            recentActions: actions
        )
    }
}

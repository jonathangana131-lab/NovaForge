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
        let incident = try makeIncident(
            actions: [
                try ForgeCrashSemanticAction(sequence: 1, actionID: "a1", intent: "move"),
                try ForgeCrashSemanticAction(sequence: 2, actionID: "a2", intent: "jump"),
            ]
        )
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

    func testRepeatKeySeparatesProjectAndCheckpointSubjects() throws {
        let baseline = try makeIncident(projectID: "project-1", checkpointID: "checkpoint-9")
        let otherProject = try makeIncident(projectID: "project-2", checkpointID: "checkpoint-9")
        let otherCheckpoint = try makeIncident(projectID: "project-1", checkpointID: "checkpoint-10")

        let baselineKey = ForgeCrashRepeatKey.derive(from: baseline)
        XCTAssertNotEqual(baselineKey, ForgeCrashRepeatKey.derive(from: otherProject))
        XCTAssertNotEqual(baselineKey, ForgeCrashRepeatKey.derive(from: otherCheckpoint))
    }

    func testRepeatKeyFallsBackToNormalizedMessageWhenNoLocationExists() throws {
        let first = try makeIncident(
            message: "  Network   bootstrap failed  ",
            source: nil,
            stackFrames: []
        )
        let second = try makeIncident(
            message: "network bootstrap failed",
            source: nil,
            stackFrames: []
        )

        XCTAssertEqual(ForgeCrashRepeatKey.derive(from: first), ForgeCrashRepeatKey.derive(from: second))
    }

    func testDecodedRepairAttemptCannotBypassSequenceValidation() throws {
        let incident = try makeIncident()
        let attempt = try ForgeCrashRepairAttempt(
            sequence: 1,
            incidentID: incident.incidentID,
            repeatKey: ForgeCrashRepeatKey.derive(from: incident),
            failureKind: .sameCrashReturned
        )
        let data = try JSONEncoder().encode(attempt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["sequence"] = 0
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashRepairAttempt.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidPositiveInteger(field: "repair.sequence"))
        }
    }

    func testDecodedRepeatKeyCannotReplaceMissionSubjectWithBlankIdentity() throws {
        let incident = try makeIncident()
        let attempt = try ForgeCrashRepairAttempt(
            sequence: 1,
            incidentID: incident.incidentID,
            repeatKey: ForgeCrashRepeatKey.derive(from: incident),
            failureKind: .sameCrashReturned
        )
        let data = try JSONEncoder().encode(attempt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var repeatKey = try XCTUnwrap(object["repeatKey"] as? [String: Any])
        repeatKey["projectID"] = "   "
        object["repeatKey"] = repeatKey
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashRepairAttempt.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .blankField("repeat.project"))
        }
    }

    func testDecodedRepeatKeyRejectsContradictoryStructuralAndFallbackIdentity() throws {
        let incident = try makeIncident()
        let attempt = try ForgeCrashRepairAttempt(
            sequence: 1,
            incidentID: incident.incidentID,
            repeatKey: ForgeCrashRepeatKey.derive(from: incident),
            failureKind: .sameCrashReturned
        )
        let data = try JSONEncoder().encode(attempt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var repeatKey = try XCTUnwrap(object["repeatKey"] as? [String: Any])
        repeatKey["fallbackMessage"] = "forged fallback"
        object["repeatKey"] = repeatKey
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashRepairAttempt.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidRepeatKey)
        }
    }

    func testDecodedFallbackRepeatKeyMustRemainCanonical() throws {
        let incident = try makeIncident(
            message: "network bootstrap failed",
            source: nil,
            stackFrames: []
        )
        let attempt = try ForgeCrashRepairAttempt(
            sequence: 1,
            incidentID: incident.incidentID,
            repeatKey: ForgeCrashRepeatKey.derive(from: incident),
            failureKind: .sameCrashReturned
        )
        let data = try JSONEncoder().encode(attempt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var repeatKey = try XCTUnwrap(object["repeatKey"] as? [String: Any])
        repeatKey["fallbackMessage"] = "NETWORK   bootstrap failed"
        object["repeatKey"] = repeatKey
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashRepairAttempt.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .invalidRepeatKey)
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

    func testRepairHistoryRejectsDuplicateOrReorderedSequences() throws {
        let incident = try makeIncident()
        let key = ForgeCrashRepeatKey.derive(from: incident)
        let first = try ForgeCrashRepairAttempt(
            sequence: 2,
            incidentID: incident.incidentID,
            repeatKey: key,
            failureKind: .sameCrashReturned
        )
        let duplicate = try ForgeCrashRepairAttempt(
            sequence: 2,
            incidentID: incident.incidentID,
            repeatKey: key,
            failureKind: .focusedVerificationFailed
        )

        XCTAssertThrowsError(try ForgeCrashRepairHistory(attempts: [first, duplicate])) { error in
            XCTAssertEqual(error as? ForgeCrashValidationError, .nonMonotonicSequence(field: "repair.sequence"))
        }
    }

    func testTriageStartsWithFocusedRepair() throws {
        let trusted = try makeTrustedIncident()
        let policy = try ForgeCrashRetryPolicy()

        let submission = ForgeCrashTriage.makeSubmission(
            for: trusted,
            failedHistory: try ForgeCrashRepairHistory(),
            policy: policy
        )

        XCTAssertEqual(submission.nextAction, .focusedRepair(attemptNumber: 1))
        XCTAssertEqual(submission.trustedIncident, trusted)
    }

    func testRepeatedCrashPromotesToRootCauseAnalysis() throws {
        let trusted = try makeTrustedIncident()
        let key = ForgeCrashRepeatKey.derive(from: trusted.incident)
        let attempts = [
            try ForgeCrashRepairAttempt(
                sequence: 1,
                incidentID: trusted.incident.incidentID,
                repeatKey: key,
                failureKind: .sameCrashReturned
            ),
            try ForgeCrashRepairAttempt(
                sequence: 2,
                incidentID: trusted.incident.incidentID,
                repeatKey: key,
                failureKind: .focusedVerificationFailed
            ),
        ]

        let submission = ForgeCrashTriage.makeSubmission(
            for: trusted,
            failedHistory: try ForgeCrashRepairHistory(attempts: attempts),
            policy: try ForgeCrashRetryPolicy()
        )

        XCTAssertEqual(submission.nextAction, .rootCauseAnalysis(repeatedFailures: 2))
    }

    func testDifferentCrashDoesNotConsumeFocusedRetryBudgetForCurrentRepeatKey() throws {
        let trusted = try makeTrustedIncident()
        let unrelated = try makeIncident(
            incidentID: "incident-other",
            message: "asset failed",
            source: try ForgeCrashSourceLocation(file: "assets.js", line: 9, symbol: "loadAsset"),
            stackFrames: [try ForgeCrashStackFrame(symbol: "loadAsset", file: "assets.js", line: 9)]
        )
        let attempts = [
            try ForgeCrashRepairAttempt(
                sequence: 1,
                incidentID: unrelated.incidentID,
                repeatKey: ForgeCrashRepeatKey.derive(from: unrelated),
                failureKind: .sameCrashReturned
            ),
        ]

        let submission = ForgeCrashTriage.makeSubmission(
            for: trusted,
            failedHistory: try ForgeCrashRepairHistory(attempts: attempts),
            policy: try ForgeCrashRetryPolicy()
        )

        XCTAssertEqual(submission.nextAction, .focusedRepair(attemptNumber: 1))
    }

    func testOtherMissionFailuresDoNotConsumeCurrentBlockerBudget() throws {
        let trusted = try makeTrustedIncident()
        let otherProject = try makeIncident(
            incidentID: "incident-other-project",
            projectID: "project-2",
            checkpointID: trusted.incident.checkpointID
        )
        let otherCheckpoint = try makeIncident(
            incidentID: "incident-other-checkpoint",
            projectID: trusted.incident.projectID,
            checkpointID: "checkpoint-10"
        )
        let otherProjectKey = ForgeCrashRepeatKey.derive(from: otherProject)
        let otherCheckpointKey = ForgeCrashRepeatKey.derive(from: otherCheckpoint)
        let attempts = try (1...6).map { sequence in
            let useOtherProject = sequence.isMultiple(of: 2)
            let incident = useOtherProject ? otherProject : otherCheckpoint
            return try ForgeCrashRepairAttempt(
                sequence: sequence,
                incidentID: incident.incidentID,
                repeatKey: useOtherProject ? otherProjectKey : otherCheckpointKey,
                failureKind: .verificationInterrupted
            )
        }

        let submission = ForgeCrashTriage.makeSubmission(
            for: trusted,
            failedHistory: try ForgeCrashRepairHistory(attempts: attempts),
            policy: try ForgeCrashRetryPolicy(maximumFocusedFailuresPerRepeatKey: 2, maximumTotalFailuresBeforeBlocker: 6)
        )

        XCTAssertEqual(submission.nextAction, .focusedRepair(attemptNumber: 1))
    }

    func testTotalFailureCapSurfacesBlockerBeforeMoreAutonomousRepair() throws {
        let trusted = try makeTrustedIncident()
        let currentKey = ForgeCrashRepeatKey.derive(from: trusted.incident)
        let unrelated = try makeIncident(
            incidentID: "incident-unrelated",
            source: try ForgeCrashSourceLocation(file: "other.js", line: 7, symbol: "other"),
            stackFrames: [try ForgeCrashStackFrame(symbol: "other", file: "other.js", line: 7)]
        )
        let unrelatedKey = ForgeCrashRepeatKey.derive(from: unrelated)
        let attempts = try (1...6).map { sequence in
            try ForgeCrashRepairAttempt(
                sequence: sequence,
                incidentID: sequence.isMultiple(of: 2) ? trusted.incident.incidentID : unrelated.incidentID,
                repeatKey: sequence.isMultiple(of: 2) ? currentKey : unrelatedKey,
                failureKind: .verificationInterrupted
            )
        }

        let submission = ForgeCrashTriage.makeSubmission(
            for: trusted,
            failedHistory: try ForgeCrashRepairHistory(attempts: attempts),
            policy: try ForgeCrashRetryPolicy(maximumFocusedFailuresPerRepeatKey: 4, maximumTotalFailuresBeforeBlocker: 6)
        )

        XCTAssertEqual(submission.nextAction, .surfaceBlocker(totalFailures: 6))
    }

    func testPolicyRejectsTotalBudgetBelowFocusedBudget() {
        XCTAssertThrowsError(
            try ForgeCrashRetryPolicy(
                maximumFocusedFailuresPerRepeatKey: 4,
                maximumTotalFailuresBeforeBlocker: 3
            )
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

    private func makeIncident(
        incidentID: String = "incident-1",
        projectID: String = "project-1",
        checkpointID: String = "checkpoint-9",
        message: String = "TypeError: player is undefined",
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
            projectID: projectID,
            checkpointID: checkpointID,
            projectRevision: "revision-abc",
            runtimeVersion: "runtime-1",
            runtimeSessionID: "session-5",
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

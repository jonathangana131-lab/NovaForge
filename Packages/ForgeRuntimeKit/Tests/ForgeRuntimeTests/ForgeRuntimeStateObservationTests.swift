import ForgeRuntime
import Foundation
import XCTest

private struct ExactSnapshotAuthenticator: ForgeRuntimeStateEvidenceAuthenticating {
    let accepted: Set<SnapshotIdentity>

    init(_ snapshots: [ForgeRuntimeStateSnapshot]) throws {
        self.accepted = try Set(snapshots.map(SnapshotIdentity.init))
    }

    func authenticates(_ snapshot: ForgeRuntimeStateSnapshot) -> Bool {
        (try? SnapshotIdentity(snapshot)).map(accepted.contains) ?? false
    }
}

private struct SnapshotIdentity: Hashable {
    let encoded: Data
    init(_ snapshot: ForgeRuntimeStateSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoded = try encoder.encode(snapshot)
    }
}

final class ForgeRuntimeStateObservationTests: XCTestCase {
    private func target(source: String = "rev-1", checkpoint: String = "cp-1") throws -> ForgeRuntimeStateTarget {
        try ForgeRuntimeStateTarget(
            projectID: "project-1",
            sourceRevision: source,
            sessionID: "session-1",
            checkpointID: checkpoint,
            runtimeVersion: .init(major: 1, minor: 0)
        )
    }

    private func expectation(
        id: String = "goal",
        key: String = "game.goalReached",
        predicate: ForgeRuntimeStatePredicate = .equals(.boolean(true))
    ) throws -> ForgeRuntimeStateExpectation {
        try ForgeRuntimeStateExpectation(id: id, fieldKey: key, predicate: predicate)
    }

    private func request(
        target: ForgeRuntimeStateTarget? = nil,
        expectations: [ForgeRuntimeStateExpectation]? = nil
    ) throws -> ForgeRuntimeStateRequest {
        try ForgeRuntimeStateRequest(
            requestID: "request-1",
            target: target ?? self.target(),
            expectedSnapshotSequence: 7,
            expectations: expectations ?? [expectation()]
        )
    }

    private func snapshot(
        target: ForgeRuntimeStateTarget? = nil,
        requestID: String = "request-1",
        receipt: String = "receipt-1",
        sequence: UInt64 = 7,
        causalReceipt: String? = nil,
        fields: [ForgeRuntimeStateField]? = nil
    ) throws -> ForgeRuntimeStateSnapshot {
        try ForgeRuntimeStateSnapshot(
            snapshotID: "snapshot-1",
            requestID: requestID,
            target: target ?? self.target(),
            sequence: sequence,
            producer: .runtimeBridge,
            producerReceiptID: receipt,
            causalDeliveryReceiptID: causalReceipt,
            fields: fields ?? [ForgeRuntimeStateField(key: "game.goalReached", value: .boolean(true))]
        )
    }

    func testAuthenticatedExactSnapshotCanSatisfyExpectation() throws {
        let request = try request()
        let snapshot = try snapshot()
        let result = ForgeRuntimeStateEvaluator.evaluate(
            request: request,
            snapshot: snapshot,
            authenticator: try ExactSnapshotAuthenticator([snapshot])
        )
        XCTAssertTrue(result.isAccepted)
        XCTAssertEqual(result.contributingProducerReceiptID, "receipt-1")
        XCTAssertTrue(result.blockers.isEmpty)
    }

    func testUnauthenticatedSnapshotCannotContributeEvenWhenValuesPass() throws {
        let request = try request()
        let snapshot = try snapshot()
        let result = ForgeRuntimeStateEvaluator.evaluate(
            request: request,
            snapshot: snapshot,
            authenticator: try ExactSnapshotAuthenticator([])
        )
        XCTAssertEqual(result.blockers, [.unauthenticatedSnapshot])
        XCTAssertNil(result.contributingProducerReceiptID)
    }

    func testSameReceiptWithChangedValueIsRejectedByCompleteSubjectAuthenticator() throws {
        let original = try snapshot()
        let changed = try snapshot(fields: [
            ForgeRuntimeStateField(key: "game.goalReached", value: .boolean(false))
        ])
        let result = ForgeRuntimeStateEvaluator.evaluate(
            request: try request(),
            snapshot: changed,
            authenticator: try ExactSnapshotAuthenticator([original])
        )
        XCTAssertEqual(result.blockers, [.unauthenticatedSnapshot])
    }

    func testCrossRevisionSnapshotFailsBeforeFieldEvaluation() throws {
        let trusted = try snapshot(target: target(source: "rev-2"))
        let result = ForgeRuntimeStateEvaluator.evaluate(
            request: try request(),
            snapshot: trusted,
            authenticator: try ExactSnapshotAuthenticator([trusted])
        )
        XCTAssertEqual(result.blockers, [.targetMismatch])
    }

    func testCrossCheckpointSnapshotFailsClosed() throws {
        let trusted = try snapshot(target: target(checkpoint: "cp-2"))
        let result = ForgeRuntimeStateEvaluator.evaluate(
            request: try request(),
            snapshot: trusted,
            authenticator: try ExactSnapshotAuthenticator([trusted])
        )
        XCTAssertEqual(result.blockers, [.targetMismatch])
    }

    func testRequestReplayMismatchFailsClosed() throws {
        let trusted = try snapshot(requestID: "request-old")
        let result = ForgeRuntimeStateEvaluator.evaluate(
            request: try request(),
            snapshot: trusted,
            authenticator: try ExactSnapshotAuthenticator([trusted])
        )
        XCTAssertEqual(result.blockers, [.requestMismatch])
    }

    func testStaleSnapshotSequenceFailsBeforeAuthentication() throws {
        let trusted = try snapshot(sequence: 6)
        let result = ForgeRuntimeStateEvaluator.evaluate(
            request: try request(),
            snapshot: trusted,
            authenticator: try ExactSnapshotAuthenticator([trusted])
        )
        XCTAssertEqual(result.blockers, [.sequenceMismatch])
    }

    func testCausalDeliveryReceiptMustMatchRequestedActionBoundary() throws {
        let expectation = try expectation()
        let request = try ForgeRuntimeStateRequest(
            requestID: "request-1",
            target: target(),
            expectedSnapshotSequence: 7,
            afterDeliveryReceiptID: "delivery-7",
            expectations: [expectation]
        )
        let stale = try snapshot(causalReceipt: "delivery-6")
        let result = ForgeRuntimeStateEvaluator.evaluate(
            request: request,
            snapshot: stale,
            authenticator: try ExactSnapshotAuthenticator([stale])
        )
        XCTAssertEqual(result.blockers, [.causalReceiptMismatch])
    }

    func testUnexpectedFieldIsRejectedRatherThanSmuggledIntoEvidence() throws {
        let fields = [
            try ForgeRuntimeStateField(key: "game.goalReached", value: .boolean(true)),
            try ForgeRuntimeStateField(key: "secret.debugState", value: .text("internal")),
        ]
        let trusted = try snapshot(fields: fields)
        let result = ForgeRuntimeStateEvaluator.evaluate(
            request: try request(),
            snapshot: trusted,
            authenticator: try ExactSnapshotAuthenticator([trusted])
        )
        XCTAssertEqual(result.blockers, [.unexpectedField("secret.debugState")])
    }

    func testMissingFieldBlocksAcceptance() throws {
        let trusted = try snapshot(fields: [])
        let result = ForgeRuntimeStateEvaluator.evaluate(
            request: try request(),
            snapshot: trusted,
            authenticator: try ExactSnapshotAuthenticator([trusted])
        )
        XCTAssertEqual(
            result.blockers,
            [.missingField(expectationID: "goal", fieldKey: "game.goalReached")]
        )
    }

    func testNumericPredicatesAreTypedAndBounded() throws {
        let expectation = try expectation(
            id: "health",
            key: "player.health",
            predicate: .numberAtLeast(1)
        )
        let request = try request(expectations: [expectation])
        let passing = try snapshot(fields: [ForgeRuntimeStateField(key: "player.health", value: .number(12))])
        XCTAssertTrue(ForgeRuntimeStateEvaluator.evaluate(
            request: request,
            snapshot: passing,
            authenticator: try ExactSnapshotAuthenticator([passing])
        ).isAccepted)

        let wrongType = try snapshot(fields: [ForgeRuntimeStateField(key: "player.health", value: .text("12"))])
        XCTAssertEqual(
            ForgeRuntimeStateEvaluator.evaluate(
                request: request,
                snapshot: wrongType,
                authenticator: try ExactSnapshotAuthenticator([wrongType])
            ).blockers,
            [.typeMismatch(expectationID: "health", fieldKey: "player.health")]
        )

        let failing = try snapshot(fields: [ForgeRuntimeStateField(key: "player.health", value: .number(0))])
        XCTAssertEqual(
            ForgeRuntimeStateEvaluator.evaluate(
                request: request,
                snapshot: failing,
                authenticator: try ExactSnapshotAuthenticator([failing])
            ).blockers,
            [.predicateNotSatisfied(expectationID: "health", fieldKey: "player.health")]
        )
    }

    func testDuplicateExpectationIdentityFailsClosed() throws {
        let e = try expectation()
        XCTAssertThrowsError(
            try ForgeRuntimeStateRequest(
                requestID: "request-1",
                target: target(),
                expectedSnapshotSequence: 7,
                expectations: [e, e]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeStateObservationError, .duplicateExpectationID("goal"))
        }
    }

    func testDuplicateSnapshotFieldFailsClosed() throws {
        let f = try ForgeRuntimeStateField(key: "game.goalReached", value: .boolean(true))
        XCTAssertThrowsError(
            try snapshot(fields: [f, f])
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeStateObservationError, .duplicateFieldKey("game.goalReached"))
        }
    }

    func testNonFiniteNumbersCannotEnterObservationOrPredicate() throws {
        XCTAssertThrowsError(
            try ForgeRuntimeStateField(key: "physics.speed", value: .number(.infinity))
        )
        XCTAssertThrowsError(
            try expectation(id: "speed", key: "physics.speed", predicate: .numberAtMost(.nan))
        )
    }

    func testInvalidIdentifierAndStateKeysFailClosed() throws {
        XCTAssertThrowsError(try target(source: " rev-1"))
        XCTAssertThrowsError(try ForgeRuntimeStateField(key: "../secret", value: .boolean(true)))
        XCTAssertThrowsError(
            try ForgeRuntimeStateRequest(
                requestID: "request id",
                target: target(),
                expectedSnapshotSequence: 7,
                expectations: [expectation()]
            )
        )
        XCTAssertThrowsError(
            try ForgeRuntimeStateRequest(
                requestID: "../../receipt",
                target: target(),
                expectedSnapshotSequence: 7,
                expectations: [expectation()]
            )
        )
        XCTAssertThrowsError(
            try ForgeRuntimeStateSnapshot(
                snapshotID: "snapshot-1",
                requestID: "request-1",
                target: target(),
                sequence: 7,
                producer: .runtimeBridge,
                producerReceiptID: "receipt/path",
                fields: []
            )
        )
    }

    func testCodableRoundTripRevalidatesInputs() throws {
        let request = try request()
        let snapshot = try snapshot()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(ForgeRuntimeStateRequest.self, from: JSONEncoder().encode(request)), request)
        XCTAssertEqual(try decoder.decode(ForgeRuntimeStateSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testPersistedTargetTamperFailsClosedOnDecode() throws {
        let encoded = try JSONEncoder().encode(snapshot())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var target = try XCTUnwrap(json["target"] as? [String: Any])
        target["sourceRevision"] = " bad revision"
        json["target"] = target
        let tampered = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeRuntimeStateSnapshot.self, from: tampered))
    }

    func testUnknownSchemaFailsClosed() throws {
        XCTAssertThrowsError(
            try ForgeRuntimeStateSnapshot(
                schemaVersion: 99,
                snapshotID: "snapshot-1",
                requestID: "request-1",
                target: target(),
                sequence: 0,
                producer: .hostTestHarness,
                producerReceiptID: "receipt-1",
                fields: []
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeStateObservationError, .unsupportedSchema(99))
        }
    }
}

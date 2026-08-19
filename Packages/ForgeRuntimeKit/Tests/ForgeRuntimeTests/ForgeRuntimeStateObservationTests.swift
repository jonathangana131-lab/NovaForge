import ForgeRuntime
import Foundation
import XCTest

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
        expectations: [ForgeRuntimeStateExpectation]? = nil,
        causalReceipt: String? = nil
    ) throws -> ForgeRuntimeStateRequest {
        try ForgeRuntimeStateRequest(
            requestID: "request-1",
            target: target ?? self.target(),
            expectedSnapshotSequence: 7,
            afterDeliveryReceiptID: causalReceipt,
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
            reportedProducer: .runtimeBridge,
            reportedProducerReceiptID: receipt,
            causalDeliveryReceiptID: causalReceipt,
            fields: fields ?? [ForgeRuntimeStateField(key: "game.goalReached", value: .boolean(true))]
        )
    }

    func testStructurallyMatchingSnapshotIsOnlyCandidateSatisfied() throws {
        let result = ForgeRuntimeStateCandidateEvaluator.evaluate(
            request: try request(),
            snapshot: try snapshot()
        )
        XCTAssertEqual(result.verdict, .satisfied)
        XCTAssertTrue(result.isSatisfied)
        XCTAssertTrue(result.blockers.isEmpty)
    }

    func testReportedProducerMetadataDoesNotAffectStructuralCandidateEvaluation() throws {
        let runtimeSnapshot = try snapshot(receipt: "runtime-receipt")
        let testSnapshot = try ForgeRuntimeStateSnapshot(
            snapshotID: runtimeSnapshot.snapshotID,
            requestID: runtimeSnapshot.requestID,
            target: runtimeSnapshot.target,
            sequence: runtimeSnapshot.sequence,
            reportedProducer: .hostTestHarness,
            reportedProducerReceiptID: "caller-chosen-receipt",
            causalDeliveryReceiptID: runtimeSnapshot.causalDeliveryReceiptID,
            fields: runtimeSnapshot.fields
        )
        XCTAssertTrue(ForgeRuntimeStateCandidateEvaluator.evaluate(
            request: try request(),
            snapshot: runtimeSnapshot
        ).isSatisfied)
        XCTAssertTrue(ForgeRuntimeStateCandidateEvaluator.evaluate(
            request: try request(),
            snapshot: testSnapshot
        ).isSatisfied)
    }

    func testCrossRevisionSnapshotFailsBeforeFieldEvaluation() throws {
        let result = ForgeRuntimeStateCandidateEvaluator.evaluate(
            request: try request(),
            snapshot: try snapshot(target: target(source: "rev-2"))
        )
        XCTAssertEqual(result.blockers, [.targetMismatch])
    }

    func testCrossCheckpointSnapshotFailsClosed() throws {
        let result = ForgeRuntimeStateCandidateEvaluator.evaluate(
            request: try request(),
            snapshot: try snapshot(target: target(checkpoint: "cp-2"))
        )
        XCTAssertEqual(result.blockers, [.targetMismatch])
    }

    func testRequestReplayMismatchFailsClosed() throws {
        let result = ForgeRuntimeStateCandidateEvaluator.evaluate(
            request: try request(),
            snapshot: try snapshot(requestID: "request-old")
        )
        XCTAssertEqual(result.blockers, [.requestMismatch])
    }

    func testStaleSnapshotSequenceFailsClosed() throws {
        let result = ForgeRuntimeStateCandidateEvaluator.evaluate(
            request: try request(),
            snapshot: try snapshot(sequence: 6)
        )
        XCTAssertEqual(result.blockers, [.sequenceMismatch])
    }

    func testCausalDeliveryReceiptMustMatchRequestedActionBoundary() throws {
        let result = ForgeRuntimeStateCandidateEvaluator.evaluate(
            request: try request(causalReceipt: "delivery-7"),
            snapshot: try snapshot(causalReceipt: "delivery-6")
        )
        XCTAssertEqual(result.blockers, [.causalReceiptMismatch])
    }

    func testUnexpectedFieldIsRejectedRatherThanSmuggledIntoCandidate() throws {
        let fields = [
            try ForgeRuntimeStateField(key: "game.goalReached", value: .boolean(true)),
            try ForgeRuntimeStateField(key: "secret.debugState", value: .text("internal")),
        ]
        let result = ForgeRuntimeStateCandidateEvaluator.evaluate(
            request: try request(),
            snapshot: try snapshot(fields: fields)
        )
        XCTAssertEqual(result.blockers, [.unexpectedField("secret.debugState")])
    }

    func testMissingFieldBlocksCandidateSatisfaction() throws {
        let result = ForgeRuntimeStateCandidateEvaluator.evaluate(
            request: try request(),
            snapshot: try snapshot(fields: [])
        )
        XCTAssertEqual(
            result.blockers,
            [.missingField(expectationID: "goal", fieldKey: "game.goalReached")]
        )
    }

    func testNumericPredicatesAreTypedAndBounded() throws {
        let health = try expectation(id: "health", key: "player.health", predicate: .numberAtLeast(1))
        let req = try request(expectations: [health])
        let passing = try snapshot(fields: [ForgeRuntimeStateField(key: "player.health", value: .number(12))])
        XCTAssertTrue(ForgeRuntimeStateCandidateEvaluator.evaluate(request: req, snapshot: passing).isSatisfied)

        let wrongType = try snapshot(fields: [ForgeRuntimeStateField(key: "player.health", value: .text("12"))])
        XCTAssertEqual(
            ForgeRuntimeStateCandidateEvaluator.evaluate(request: req, snapshot: wrongType).blockers,
            [.typeMismatch(expectationID: "health", fieldKey: "player.health")]
        )

        let failing = try snapshot(fields: [ForgeRuntimeStateField(key: "player.health", value: .number(0))])
        XCTAssertEqual(
            ForgeRuntimeStateCandidateEvaluator.evaluate(request: req, snapshot: failing).blockers,
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
        XCTAssertThrowsError(try snapshot(fields: [f, f])) { error in
            XCTAssertEqual(error as? ForgeRuntimeStateObservationError, .duplicateFieldKey("game.goalReached"))
        }
    }

    func testNonFiniteNumbersCannotEnterObservationOrPredicate() throws {
        XCTAssertThrowsError(try ForgeRuntimeStateField(key: "physics.speed", value: .number(.infinity)))
        XCTAssertThrowsError(try expectation(id: "speed", key: "physics.speed", predicate: .numberAtMost(.nan)))
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
                reportedProducer: .runtimeBridge,
                reportedProducerReceiptID: "receipt/path",
                fields: []
            )
        )
    }

    func testCodableRoundTripRevalidatesCandidateInputs() throws {
        let req = try request()
        let snap = try snapshot()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(ForgeRuntimeStateRequest.self, from: JSONEncoder().encode(req)), req)
        XCTAssertEqual(try decoder.decode(ForgeRuntimeStateSnapshot.self, from: JSONEncoder().encode(snap)), snap)
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
                reportedProducer: .hostTestHarness,
                reportedProducerReceiptID: "receipt-1",
                fields: []
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeStateObservationError, .unsupportedSchema(99))
        }
    }
}

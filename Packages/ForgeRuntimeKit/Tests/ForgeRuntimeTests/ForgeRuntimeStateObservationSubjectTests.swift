import ForgeRuntime
import Foundation
import XCTest

final class ForgeRuntimeStateObservationSubjectTests: XCTestCase {
    private func target(source: String = "rev-1") throws -> ForgeRuntimeStateTarget {
        try ForgeRuntimeStateTarget(
            projectID: "project-1",
            sourceRevision: source,
            sessionID: "session-1",
            checkpointID: "checkpoint-1",
            runtimeVersion: .init(major: 1, minor: 0)
        )
    }

    private func healthExpectation(minimum: Double) throws -> ForgeRuntimeStateExpectation {
        try ForgeRuntimeStateExpectation(
            id: "health",
            fieldKey: "player.health",
            predicate: .numberAtLeast(minimum)
        )
    }

    private func request(
        minimumHealth: Double,
        target: ForgeRuntimeStateTarget? = nil,
        sequence: UInt64 = 7,
        causalReceipt: String? = "delivery-7"
    ) throws -> ForgeRuntimeStateRequest {
        try ForgeRuntimeStateRequest(
            requestID: "request-1",
            target: target ?? self.target(),
            expectedSnapshotSequence: sequence,
            afterDeliveryReceiptID: causalReceipt,
            expectations: [healthExpectation(minimum: minimumHealth)]
        )
    }

    private func snapshot(
        requestID: String = "request-1",
        target: ForgeRuntimeStateTarget? = nil,
        sequence: UInt64 = 7,
        causalReceipt: String? = "delivery-7",
        health: Double = 50
    ) throws -> ForgeRuntimeStateSnapshot {
        try ForgeRuntimeStateSnapshot(
            snapshotID: "snapshot-1",
            requestID: requestID,
            target: target ?? self.target(),
            sequence: sequence,
            reportedProducer: .runtimeBridge,
            reportedProducerReceiptID: "producer-receipt-1",
            causalDeliveryReceiptID: causalReceipt,
            fields: [try ForgeRuntimeStateField(key: "player.health", value: .number(health))]
        )
    }

    func testWholeSubjectPreservesExactRequestAgainstSameIDPredicateWeakening() throws {
        let issuedRequest = try request(minimumHealth: 100)
        let reportedSnapshot = try snapshot(health: 50)
        let issuedSubject = try ForgeRuntimeStateObservationSubject(
            request: issuedRequest,
            snapshot: reportedSnapshot
        )

        XCTAssertEqual(
            issuedSubject.candidateEvaluation.blockers,
            [.predicateNotSatisfied(expectationID: "health", fieldKey: "player.health")]
        )

        // This is the exact replay shape found by independent review: the public candidate API can
        // build a weaker request with the same request ID. It can satisfy the raw snapshot, but it is
        // a *different whole subject* and therefore cannot substitute for an authenticated issued one.
        let weakenedRequest = try request(minimumHealth: 0)
        XCTAssertTrue(
            ForgeRuntimeStateCandidateEvaluator.evaluate(
                request: weakenedRequest,
                snapshot: reportedSnapshot
            ).isSatisfied
        )

        let weakenedSubject = try ForgeRuntimeStateObservationSubject(
            request: weakenedRequest,
            snapshot: reportedSnapshot
        )
        XCTAssertNotEqual(weakenedSubject, issuedSubject)
        XCTAssertEqual(issuedSubject.request, issuedRequest)
        XCTAssertEqual(issuedSubject.snapshot, reportedSnapshot)
        XCTAssertFalse(issuedSubject.candidateEvaluation.isSatisfied)
    }

    func testSubjectRejectsRequestIdentityMismatch() throws {
        XCTAssertThrowsError(
            try ForgeRuntimeStateObservationSubject(
                request: request(minimumHealth: 100),
                snapshot: snapshot(requestID: "request-other")
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeStateObservationSubjectError, .requestMismatch)
        }
    }

    func testSubjectRejectsTargetSequenceAndCausalBoundaryMismatch() throws {
        let issuedRequest = try request(minimumHealth: 100)

        XCTAssertThrowsError(
            try ForgeRuntimeStateObservationSubject(
                request: issuedRequest,
                snapshot: snapshot(target: target(source: "rev-2"))
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeStateObservationSubjectError, .targetMismatch)
        }

        XCTAssertThrowsError(
            try ForgeRuntimeStateObservationSubject(
                request: issuedRequest,
                snapshot: snapshot(sequence: 8)
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeStateObservationSubjectError, .sequenceMismatch)
        }

        XCTAssertThrowsError(
            try ForgeRuntimeStateObservationSubject(
                request: issuedRequest,
                snapshot: snapshot(causalReceipt: "delivery-8")
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeStateObservationSubjectError, .causalReceiptMismatch)
        }
    }

    func testSubjectCodableRoundTripRetainsExactRequestAndSnapshot() throws {
        let subject = try ForgeRuntimeStateObservationSubject(
            request: request(minimumHealth: 100),
            snapshot: snapshot(health: 100)
        )
        let data = try JSONEncoder().encode(subject)
        let decoded = try JSONDecoder().decode(ForgeRuntimeStateObservationSubject.self, from: data)

        XCTAssertEqual(decoded, subject)
        XCTAssertTrue(decoded.candidateEvaluation.isSatisfied)
    }

    func testUnknownSubjectSchemaFailsClosed() throws {
        XCTAssertThrowsError(
            try ForgeRuntimeStateObservationSubject(
                schemaVersion: 99,
                request: request(minimumHealth: 100),
                snapshot: snapshot(health: 100)
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeStateObservationSubjectError, .unsupportedSchema(99))
        }
    }
}

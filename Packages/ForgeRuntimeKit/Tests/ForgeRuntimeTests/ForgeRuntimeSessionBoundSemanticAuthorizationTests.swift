import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeSessionBoundSemanticAuthorizationTests: XCTestCase {
    private func session(runtimeVersion: ForgeRuntimeVersion) -> ForgeRuntimeAutomationSession {
        ForgeRuntimeAutomationSession(
            sessionID: "shared-session",
            projectID: "project-a",
            sourceRevision: "rev-123",
            runtimeVersion: runtimeVersion,
            grantedCapabilities: [.activateControl],
            maximumTextUTF8Bytes: 4 * 1024,
            maximumGestureDurationMilliseconds: 10_000,
            maximumInteractions: 8
        )
    }

    private func requestData(sequence: Int = 0) throws -> Data {
        try JSONEncoder().encode(
            ForgeRuntimeSemanticInteractionEnvelope(
                requestID: "request-\(sequence)",
                sessionID: "shared-session",
                projectID: "project-a",
                sourceRevision: "rev-123",
                sequence: sequence,
                kind: "control.activate",
                targetID: "play"
            )
        )
    }

    func testSessionBoundAuthorizationDistinguishesSameRequestAcrossRuntimeVersions() throws {
        let runtimeV1 = ForgeRuntimeVersion(major: 1, minor: 0)
        let runtimeV2 = ForgeRuntimeVersion(major: 2, minor: 0)
        var gateV1 = try ForgeRuntimeSemanticInteractionGate(session: session(runtimeVersion: runtimeV1))
        var gateV2 = try ForgeRuntimeSemanticInteractionGate(session: session(runtimeVersion: runtimeV2))
        let data = try requestData()

        let authorizedV1 = try gateV1.authorizeSessionBound(data)
        let authorizedV2 = try gateV2.authorizeSessionBound(data)

        // The untrusted wire request is intentionally identical; runtime identity must come from
        // the package-owned session rather than a caller-supplied envelope field.
        XCTAssertEqual(authorizedV1.request, authorizedV2.request)
        XCTAssertEqual(authorizedV1.runtimeVersion, runtimeV1)
        XCTAssertEqual(authorizedV2.runtimeVersion, runtimeV2)
        XCTAssertNotEqual(authorizedV1, authorizedV2)

        let receiptV1 = authorizedV1.authorizationReceipt()
        let receiptV2 = authorizedV2.authorizationReceipt()

        // This reproduces the old collision while proving the canonical session-bound receipt closes it.
        XCTAssertEqual(receiptV1.authorization, receiptV2.authorization)
        XCTAssertNotEqual(receiptV1, receiptV2)
        XCTAssertEqual(receiptV1.runtimeVersion, runtimeV1)
        XCTAssertEqual(receiptV2.runtimeVersion, runtimeV2)
    }

    func testSessionBoundReceiptEncodesRuntimeVersionWithoutClaimingDelivery() throws {
        let runtimeVersion = ForgeRuntimeVersion(major: 3, minor: 7)
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session(runtimeVersion: runtimeVersion))
        let receipt = try gate.authorizeSessionBound(requestData()).authorizationReceipt()
        let encoded = try JSONEncoder().encode(receipt)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedRuntime = try XCTUnwrap(json["runtimeVersion"] as? [String: Any])

        XCTAssertEqual(encodedRuntime["major"] as? Int, 3)
        XCTAssertEqual(encodedRuntime["minor"] as? Int, 7)
        XCTAssertNotNil(json["authorization"])
        XCTAssertNil(json["disposition"])
        XCTAssertNil(json["delivered"])
    }

    func testSessionBoundAuthorizationPreservesGateSequenceAndBudgetSemantics() throws {
        let runtimeVersion = ForgeRuntimeVersion(major: 1, minor: 0)
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session(runtimeVersion: runtimeVersion))

        _ = try gate.authorizeSessionBound(requestData(sequence: 0))

        XCTAssertEqual(gate.authorizedInteractionCount, 1)
        XCTAssertEqual(gate.nextExpectedSequence, 1)
        XCTAssertThrowsError(try gate.authorizeSessionBound(requestData(sequence: 0))) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeSemanticInteractionError,
                .sequenceMismatch(expected: 1, actual: 0)
            )
        }
        XCTAssertEqual(gate.authorizedInteractionCount, 1)
        XCTAssertEqual(gate.nextExpectedSequence, 1)
    }

    func testSessionBoundAuthorizationFeedsCanonicalWebAdapterWithoutUnwrapping() throws {
        let runtimeVersion = ForgeRuntimeVersion(major: 4, minor: 2)
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session(runtimeVersion: runtimeVersion))
        let authorized = try gate.authorizeSessionBound(requestData())
        let adapter = ForgeRuntimeWebSemanticAutomationAdapter()

        let plan = try adapter.makeDispatchPlan(for: authorized)
        XCTAssertEqual(plan.requestID, authorized.request.requestID)
        XCTAssertEqual(plan.sessionID, authorized.request.sessionID)
        XCTAssertEqual(plan.projectID, authorized.request.projectID)
        XCTAssertEqual(plan.sourceRevision, authorized.request.sourceRevision)
        XCTAssertEqual(plan.sequence, authorized.request.sequence)
        XCTAssertEqual(authorized.runtimeVersion, runtimeVersion)

        let bridgeResultData = try JSONSerialization.data(withJSONObject: [
            "protocolVersion": authorized.request.protocolVersion,
            "requestID": authorized.request.requestID,
            "sessionID": authorized.request.sessionID,
            "projectID": authorized.request.projectID,
            "sourceRevision": authorized.request.sourceRevision,
            "sequence": authorized.request.sequence,
            "kind": authorized.request.interaction.kind.rawValue,
            "disposition": "delivered",
        ], options: [.sortedKeys])
        let bridgeResultJSON = try XCTUnwrap(String(data: bridgeResultData, encoding: .utf8))

        let observation = try adapter.observeDispatchResult(
            for: authorized,
            bridgeResultJSON: bridgeResultJSON
        )
        XCTAssertEqual(observation.requestID, authorized.request.requestID)
        XCTAssertEqual(observation.sequence, authorized.request.sequence)
        XCTAssertEqual(observation.candidateDisposition, .delivered)
        XCTAssertEqual(authorized.runtimeVersion, runtimeVersion)
    }
}

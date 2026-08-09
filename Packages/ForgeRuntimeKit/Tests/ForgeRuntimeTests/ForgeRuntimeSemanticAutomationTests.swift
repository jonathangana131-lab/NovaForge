import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeSemanticAutomationTests: XCTestCase {
    private func launch(version: String = "rev-123") throws -> ForgeRuntimeLaunchAuthorization {
        let manifest = ForgeProjectManifest(
            projectID: "project-a",
            projectVersion: version,
            display: .init(name: "Project A"),
            storage: .init(namespace: "project-a", quotaBytes: 1_048_576)
        )
        return try ForgeRuntimeManifestValidator().authorize(
            manifest,
            expectedProjectID: "project-a",
            host: .init()
        )
    }

    private func policy(maximum: Int = 2) throws -> ForgeRuntimeAutomationPolicy {
        try .init(
            allowedCapabilities: [.activateControl, .restartRuntime],
            maximumInteractions: maximum
        )
    }

    private func session(maximum: Int = 2) throws -> ForgeRuntimeAutomationSession {
        try ForgeRuntimeAutomationSessionAuthorizer().authorize(
            launchAuthorization: launch(),
            sessionID: "session-1",
            expectedSourceRevision: "rev-123",
            requestedCapabilities: [.activateControl, .restartRuntime],
            policy: policy(maximum: maximum)
        )
    }

    private func requestData(
        sequence: Int,
        sourceRevision: String = "rev-123",
        kind: String = "control.activate"
    ) throws -> Data {
        let envelope = ForgeRuntimeSemanticInteractionEnvelope(
            requestID: "request-\(sequence)",
            sessionID: "session-1",
            projectID: "project-a",
            sourceRevision: sourceRevision,
            sequence: sequence,
            kind: kind,
            targetID: kind == "control.activate" ? "play" : nil
        )
        return try JSONEncoder().encode(envelope)
    }

    func testLaunchAuthorizationRetainsValidatedProjectVersion() throws {
        XCTAssertEqual(try launch().projectVersion, "rev-123")
    }

    func testPolicyHardBoundsTotalInteractions() throws {
        XCTAssertThrowsError(try policy(maximum: 0)) { error in
            XCTAssertEqual(error as? ForgeRuntimeAutomationPolicyError, .invalidMaximumInteractions)
        }
        XCTAssertThrowsError(
            try policy(maximum: ForgeRuntimeAutomationPolicy.hardMaximumInteractions + 1)
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeAutomationPolicyError, .invalidMaximumInteractions)
        }
    }

    func testSessionRejectsHostSelectedSourceRevisionMismatch() throws {
        XCTAssertThrowsError(
            try ForgeRuntimeAutomationSessionAuthorizer().authorize(
                launchAuthorization: launch(version: "rev-generated"),
                sessionID: "session-1",
                expectedSourceRevision: "rev-accepted",
                requestedCapabilities: [.activateControl],
                policy: policy()
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeAutomationSessionAuthorizationError,
                .sourceRevisionMismatch(expected: "rev-accepted", actual: "rev-generated")
            )
        }
    }

    func testSessionRejectsWhitespaceAliasForExpectedRevision() throws {
        XCTAssertThrowsError(
            try ForgeRuntimeAutomationSessionAuthorizer().authorize(
                launchAuthorization: launch(),
                sessionID: "session-1",
                expectedSourceRevision: " rev-123",
                requestedCapabilities: [.activateControl],
                policy: policy()
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeAutomationSessionAuthorizationError,
                .invalidExpectedSourceRevision
            )
        }
    }

    func testDecoderRejectsCrossRevisionReplay() throws {
        XCTAssertThrowsError(
            try ForgeRuntimeSemanticInteractionDecoder().decode(
                requestData(sequence: 0, sourceRevision: "rev-old"),
                session: session()
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .sourceRevisionMismatch)
        }
    }

    func testGateRejectsNegativeStartingSequence() throws {
        XCTAssertThrowsError(
            try ForgeRuntimeSemanticInteractionGate(session: session(), startingSequence: -1)
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .invalidStartingSequence)
        }
    }

    func testInteractionBudgetFailsBeforeStateMutation() throws {
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session(maximum: 1))
        _ = try gate.authorize(requestData(sequence: 0))
        XCTAssertEqual(gate.authorizedInteractionCount, 1)
        XCTAssertEqual(gate.nextExpectedSequence, 1)

        XCTAssertThrowsError(try gate.authorize(requestData(sequence: 1))) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeSemanticInteractionError,
                .interactionBudgetExhausted(maximum: 1)
            )
        }
        XCTAssertEqual(gate.authorizedInteractionCount, 1)
        XCTAssertEqual(gate.nextExpectedSequence, 1)
    }

    func testSequenceExhaustionFailsBeforeOverflowOrBudgetMutation() throws {
        var gate = try ForgeRuntimeSemanticInteractionGate(
            session: session(),
            startingSequence: Int.max
        )

        XCTAssertThrowsError(try gate.authorize(requestData(sequence: Int.max))) { error in
            XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .sequenceExhausted)
        }
        XCTAssertEqual(gate.nextExpectedSequence, Int.max)
        XCTAssertEqual(gate.authorizedInteractionCount, 0)
    }

    func testAuthorizationReceiptDoesNotClaimDeliveryDisposition() throws {
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session())
        let authorized = try gate.authorize(requestData(sequence: 0))
        let encoded = try JSONEncoder().encode(authorized.authorizationReceipt())
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(json["sourceRevision"] as? String, "rev-123")
        XCTAssertNil(json["disposition"])
        XCTAssertNil(json["delivered"])
    }

    func testWebObservationIsCandidateOnlyAndRoundTrips() throws {
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session())
        let authorized = try gate.authorize(requestData(sequence: 0))
        let json = """
        {"protocolVersion":1,"requestID":"request-0","sessionID":"session-1","projectID":"project-a","sourceRevision":"rev-123","sequence":0,"kind":"control.activate","disposition":"delivered"}
        """

        let observation = try ForgeRuntimeWebSemanticAutomationAdapter().observeDispatchResult(
            for: authorized,
            bridgeResultJSON: json
        )
        XCTAssertEqual(observation.candidateDisposition, .delivered)
        let roundTrip = try JSONDecoder().decode(
            ForgeRuntimeWebSemanticDispatchObservation.self,
            from: JSONEncoder().encode(observation)
        )
        XCTAssertEqual(roundTrip, observation)
    }

    func testWebObservationRejectsIdentityRetargeting() throws {
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session())
        let authorized = try gate.authorize(requestData(sequence: 0))
        let json = """
        {"protocolVersion":1,"requestID":"request-0","sessionID":"session-1","projectID":"project-a","sourceRevision":"rev-other","sequence":0,"kind":"control.activate","disposition":"delivered"}
        """

        XCTAssertThrowsError(
            try ForgeRuntimeWebSemanticAutomationAdapter().observeDispatchResult(
                for: authorized,
                bridgeResultJSON: json
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeWebSemanticAutomationError,
                .resultIdentityMismatch
            )
        }
    }

    func testPageCannotAssertHostRuntimeUnavailableDisposition() throws {
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session())
        let authorized = try gate.authorize(requestData(sequence: 0))
        let json = """
        {"protocolVersion":1,"requestID":"request-0","sessionID":"session-1","projectID":"project-a","sourceRevision":"rev-123","sequence":0,"kind":"control.activate","disposition":"runtimeUnavailable"}
        """

        XCTAssertThrowsError(
            try ForgeRuntimeWebSemanticAutomationAdapter().observeDispatchResult(
                for: authorized,
                bridgeResultJSON: json
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeWebSemanticAutomationError,
                .unsupportedDisposition("runtimeUnavailable")
            )
        }
    }

    func testRestartRemainsHostLifecycleOnly() throws {
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session())
        let authorized = try gate.authorize(
            requestData(sequence: 0, kind: "runtime.restart")
        )

        XCTAssertThrowsError(
            try ForgeRuntimeWebSemanticAutomationAdapter().makeDispatchPlan(for: authorized)
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeWebSemanticAutomationError,
                .hostLifecycleInteractionRequired
            )
        }
    }
}

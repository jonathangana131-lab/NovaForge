import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeSemanticAutomationTests: XCTestCase {
    func testSessionBindsExactLaunchAndRequestedHostPolicy() throws {
        let session = try makeSession(
            capabilities: [.activateControl, .setActionValue],
            policyCapabilities: [.activateControl, .setActionValue, .performGesture],
            maximumInteractions: 17
        )

        XCTAssertEqual(session.sessionID, "session-1")
        XCTAssertEqual(session.projectID, "neon-racer")
        XCTAssertEqual(session.runtimeVersion, .init(major: 1, minor: 0))
        XCTAssertEqual(session.grantedCapabilities, [.activateControl, .setActionValue])
        XCTAssertEqual(session.maximumInteractions, 17)
    }

    func testPolicyRejectsInvalidInteractionBudgets() throws {
        for maximum in [0, ForgeRuntimeAutomationPolicy.hardMaximumInteractions + 1] {
            XCTAssertThrowsError(
                try ForgeRuntimeAutomationPolicy(
                    allowedCapabilities: [.activateControl],
                    maximumInteractions: maximum
                )
            ) { error in
                XCTAssertEqual(
                    error as? ForgeRuntimeAutomationPolicyError,
                    .invalidMaximumInteractions
                )
            }
        }
    }

    func testSessionFailsClosedWhenRequestedCapabilityExceedsHostPolicy() throws {
        let policy = try ForgeRuntimeAutomationPolicy(allowedCapabilities: [.activateControl])

        XCTAssertThrowsError(
            try ForgeRuntimeAutomationSessionAuthorizer().authorize(
                launchAuthorization: launchAuthorization(),
                sessionID: "session-1",
                requestedCapabilities: [.restartRuntime, .enterText],
                policy: policy
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeAutomationSessionAuthorizationError,
                .capabilitiesNotAllowed([.restartRuntime, .enterText])
            )
        }
    }

    func testGateAuthorizesSemanticControlAndProducesDeterministicAuthorizationReceipt() throws {
        let session = try makeSession(capabilities: [.activateControl])
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session)
        let data = try encode(
            .init(
                requestID: "req-1",
                sessionID: session.sessionID,
                projectID: session.projectID,
                sequence: 0,
                kind: "control.activate",
                targetID: "hud/start-button"
            )
        )

        let authorized = try gate.authorize(data)
        let first = authorized.authorizationReceipt()
        let second = authorized.authorizationReceipt()

        XCTAssertEqual(gate.nextExpectedSequence, 1)
        XCTAssertEqual(gate.authorizedInteractionCount, 1)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.interaction.kind, .activateControl)
        XCTAssertEqual(first.interaction.targetID, "hud/start-button")
        XCTAssertNoThrow(try JSONEncoder().encode(first))
    }

    func testGateRejectsReplayAndOutOfOrderSequence() throws {
        let session = try makeSession(capabilities: [.activateControl])
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session)
        let first = try controlData(session: session, requestID: "req-1", sequence: 0)
        _ = try gate.authorize(first)

        for sequence in [0, 2] {
            XCTAssertThrowsError(
                try gate.authorize(
                    controlData(session: session, requestID: "req-\(sequence)", sequence: sequence)
                )
            ) { error in
                XCTAssertEqual(
                    error as? ForgeRuntimeSemanticInteractionError,
                    .sequenceMismatch(expected: 1, actual: sequence)
                )
            }
        }
        XCTAssertEqual(gate.nextExpectedSequence, 1)
        XCTAssertEqual(gate.authorizedInteractionCount, 1)
    }

    func testCapabilityDenialDoesNotConsumeSequenceOrInteractionBudget() throws {
        let session = try makeSession(
            capabilities: [.activateControl],
            policyCapabilities: [.activateControl, .enterText],
            maximumInteractions: 1
        )
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session)
        let denied = try encode(
            .init(
                requestID: "req-text",
                sessionID: session.sessionID,
                projectID: session.projectID,
                sequence: 0,
                kind: "text.enter",
                targetID: "profile/name",
                text: "Nova"
            )
        )

        XCTAssertThrowsError(try gate.authorize(denied)) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeSemanticInteractionError,
                .capabilityNotAuthorized(.enterText)
            )
        }
        XCTAssertEqual(gate.nextExpectedSequence, 0)
        XCTAssertEqual(gate.authorizedInteractionCount, 0)
        XCTAssertNoThrow(try gate.authorize(controlData(session: session, requestID: "req-control", sequence: 0)))
        XCTAssertEqual(gate.nextExpectedSequence, 1)
        XCTAssertEqual(gate.authorizedInteractionCount, 1)
    }

    func testInvalidRequestDoesNotConsumeInteractionBudget() throws {
        let session = try makeSession(capabilities: [.activateControl], maximumInteractions: 1)
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session)
        let invalid = try encode(
            .init(
                requestID: "req-invalid",
                sessionID: "other-session",
                projectID: session.projectID,
                sequence: 0,
                kind: "control.activate",
                targetID: "menu/play"
            )
        )

        XCTAssertThrowsError(try gate.authorize(invalid)) { error in
            XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .sessionMismatch)
        }
        XCTAssertEqual(gate.nextExpectedSequence, 0)
        XCTAssertEqual(gate.authorizedInteractionCount, 0)
        XCTAssertNoThrow(try gate.authorize(controlData(session: session, requestID: "req-valid", sequence: 0)))
    }

    func testExactFinalAllowedInteractionSucceedsThenBudgetFailsClosed() throws {
        let session = try makeSession(capabilities: [.activateControl], maximumInteractions: 2)
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session)

        XCTAssertNoThrow(try gate.authorize(controlData(session: session, requestID: "req-0", sequence: 0)))
        XCTAssertNoThrow(try gate.authorize(controlData(session: session, requestID: "req-1", sequence: 1)))
        XCTAssertEqual(gate.nextExpectedSequence, 2)
        XCTAssertEqual(gate.authorizedInteractionCount, 2)

        XCTAssertThrowsError(
            try gate.authorize(controlData(session: session, requestID: "req-2", sequence: 2))
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeSemanticInteractionError,
                .interactionBudgetExhausted(maximum: 2)
            )
        }
        XCTAssertEqual(gate.nextExpectedSequence, 2)
        XCTAssertEqual(gate.authorizedInteractionCount, 2)
    }

    func testRestoredGateCannotResetConsumedBudgetOrEnterOverflowState() throws {
        let session = try makeSession(capabilities: [.activateControl], maximumInteractions: 2)
        var restored = try ForgeRuntimeSemanticInteractionGate(
            session: session,
            startingSequence: 9,
            authorizedInteractionCount: 1
        )

        XCTAssertNoThrow(
            try restored.authorize(controlData(session: session, requestID: "req-9", sequence: 9))
        )
        XCTAssertEqual(restored.authorizedInteractionCount, 2)

        XCTAssertThrowsError(
            try ForgeRuntimeSemanticInteractionGate(
                session: session,
                startingSequence: 0,
                authorizedInteractionCount: 3
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .invalidGateState)
        }

        XCTAssertThrowsError(
            try ForgeRuntimeSemanticInteractionGate(
                session: session,
                startingSequence: Int.max,
                authorizedInteractionCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .invalidGateState)
        }
    }

    func testIdentityMismatchesFailBeforeDispatchAndDoNotAdvanceSequence() throws {
        let session = try makeSession(capabilities: [.activateControl])

        let cases: [(ForgeRuntimeSemanticInteractionEnvelope, ForgeRuntimeSemanticInteractionError)] = [
            (
                envelope(session: session, sessionID: "other-session"),
                .sessionMismatch
            ),
            (
                envelope(session: session, projectID: "other-project"),
                .projectMismatch
            ),
        ]

        for (input, expectedError) in cases {
            var gate = try ForgeRuntimeSemanticInteractionGate(session: session)
            XCTAssertThrowsError(try gate.authorize(encode(input))) { error in
                XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, expectedError)
            }
            XCTAssertEqual(gate.nextExpectedSequence, 0)
            XCTAssertEqual(gate.authorizedInteractionCount, 0)
        }
    }

    func testActionValueIsStrictlyBoundedInsteadOfSilentlyClamped() throws {
        let session = try makeSession(capabilities: [.setActionValue])
        let decoder = ForgeRuntimeSemanticInteractionDecoder()

        for value in [-1.01, 1.01] {
            let data = try encode(
                .init(
                    requestID: "req-action",
                    sessionID: session.sessionID,
                    projectID: session.projectID,
                    sequence: 0,
                    kind: "action.set-value",
                    targetID: "drive/steer",
                    value: value
                )
            )
            XCTAssertThrowsError(try decoder.decode(data, session: session)) { error in
                XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .invalidActionValue)
            }
        }
    }

    func testTextAndGestureRespectSessionResourceBounds() throws {
        let policy = try ForgeRuntimeAutomationPolicy(
            allowedCapabilities: [.enterText, .performGesture],
            maximumTextUTF8Bytes: 4,
            maximumGestureDurationMilliseconds: 250,
            maximumInteractions: 2
        )
        let session = try ForgeRuntimeAutomationSessionAuthorizer().authorize(
            launchAuthorization: launchAuthorization(),
            sessionID: "session-1",
            requestedCapabilities: [.enterText, .performGesture],
            policy: policy
        )
        let decoder = ForgeRuntimeSemanticInteractionDecoder()

        let oversizedText = try encode(
            .init(
                requestID: "req-text",
                sessionID: session.sessionID,
                projectID: session.projectID,
                sequence: 0,
                kind: "text.enter",
                targetID: "form/name",
                text: "12345"
            )
        )
        XCTAssertThrowsError(try decoder.decode(oversizedText, session: session)) { error in
            XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .invalidText)
        }

        let longGesture = try encode(
            .init(
                requestID: "req-gesture",
                sessionID: session.sessionID,
                projectID: session.projectID,
                sequence: 0,
                kind: "gesture.perform",
                targetID: "world/camera",
                gestureID: "swipe.left",
                durationMilliseconds: 251
            )
        )
        XCTAssertThrowsError(try decoder.decode(longGesture, session: session)) { error in
            XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .invalidGestureDuration)
        }
    }

    func testUnexpectedPayloadAndUnknownKindsFailClosed() throws {
        let session = try makeSession(capabilities: [.activateControl])
        let decoder = ForgeRuntimeSemanticInteractionDecoder()
        let extraPayload = try encode(
            .init(
                requestID: "req-extra",
                sessionID: session.sessionID,
                projectID: session.projectID,
                sequence: 0,
                kind: "control.activate",
                targetID: "menu/play",
                value: 1
            )
        )
        XCTAssertThrowsError(try decoder.decode(extraPayload, session: session)) { error in
            XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .unexpectedPayload)
        }

        let unknown = try encode(
            .init(
                requestID: "req-unknown",
                sessionID: session.sessionID,
                projectID: session.projectID,
                sequence: 0,
                kind: "system.shell"
            )
        )
        XCTAssertThrowsError(try decoder.decode(unknown, session: session)) { error in
            XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .unknownKind("system.shell"))
        }
    }

    func testInvalidRequestIDCannotBorrowSemanticTargetPathCharacters() throws {
        let session = try makeSession(capabilities: [.activateControl])
        let decoder = ForgeRuntimeSemanticInteractionDecoder()
        let data = try encode(
            .init(
                requestID: "../../receipt",
                sessionID: session.sessionID,
                projectID: session.projectID,
                sequence: 0,
                kind: "control.activate",
                targetID: "menu/play"
            )
        )

        XCTAssertThrowsError(try decoder.decode(data, session: session)) { error in
            XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .invalidRequestID)
        }
    }

    func testAuthorizationReceiptPreservesAuthorizedProtocolVersion() throws {
        let session = try makeSession(capabilities: [.activateControl])
        var gate = try ForgeRuntimeSemanticInteractionGate(
            session: session,
            decoder: ForgeRuntimeSemanticInteractionDecoder(supportedProtocolVersion: 2)
        )
        let data = try encode(
            .init(
                protocolVersion: 2,
                requestID: "req-v2",
                sessionID: session.sessionID,
                projectID: session.projectID,
                sequence: 0,
                kind: "control.activate",
                targetID: "menu/play"
            )
        )

        let receipt = try gate.authorize(data).authorizationReceipt()
        XCTAssertEqual(receipt.protocolVersion, 2)
        XCTAssertEqual(receipt.projectID, session.projectID)
    }

    func testOversizedEnvelopeFailsBeforeJSONDecode() throws {
        let session = try makeSession(capabilities: [.activateControl])
        let decoder = ForgeRuntimeSemanticInteractionDecoder(maximumRequestBytes: 8)
        let data = Data(repeating: 0x20, count: 9)

        XCTAssertThrowsError(try decoder.decode(data, session: session)) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeSemanticInteractionError,
                .requestTooLarge(actualBytes: 9, maximumBytes: 8)
            )
        }
    }

    func testRestartRequiresExplicitLifecycleCapabilityAndCarriesNoDeliveryClaim() throws {
        let session = try makeSession(capabilities: [.restartRuntime])
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session)
        let data = try encode(
            .init(
                requestID: "req-restart",
                sessionID: session.sessionID,
                projectID: session.projectID,
                sequence: 0,
                kind: "runtime.restart"
            )
        )

        let authorized = try gate.authorize(data)
        XCTAssertEqual(authorized.request.interaction.kind, .restartRuntime)
        XCTAssertEqual(authorized.authorizationReceipt().requestID, "req-restart")
    }

    private func makeSession(
        capabilities: Set<ForgeRuntimeAutomationCapability>,
        policyCapabilities: Set<ForgeRuntimeAutomationCapability>? = nil,
        maximumInteractions: Int = 512
    ) throws -> ForgeRuntimeAutomationSession {
        let policy = try ForgeRuntimeAutomationPolicy(
            allowedCapabilities: policyCapabilities ?? capabilities,
            maximumInteractions: maximumInteractions
        )
        return try ForgeRuntimeAutomationSessionAuthorizer().authorize(
            launchAuthorization: launchAuthorization(),
            sessionID: "session-1",
            requestedCapabilities: capabilities,
            policy: policy
        )
    }

    private func launchAuthorization() -> ForgeRuntimeLaunchAuthorization {
        ForgeRuntimeLaunchAuthorization(
            projectID: "neon-racer",
            runtimeVersion: .init(major: 1, minor: 0),
            entryPoint: "index.html",
            presentation: .init(),
            storage: .init(namespace: "neon-racer", schemaVersion: 1, quotaBytes: 1_048_576),
            grantedCapabilityIDs: [],
            network: .init(mode: .denied, allowedHosts: []),
            modules: []
        )
    }

    private func controlData(
        session: ForgeRuntimeAutomationSession,
        requestID: String,
        sequence: Int
    ) throws -> Data {
        try encode(
            .init(
                requestID: requestID,
                sessionID: session.sessionID,
                projectID: session.projectID,
                sequence: sequence,
                kind: "control.activate",
                targetID: "menu/play"
            )
        )
    }

    private func envelope(
        session: ForgeRuntimeAutomationSession,
        sessionID: String? = nil,
        projectID: String? = nil
    ) -> ForgeRuntimeSemanticInteractionEnvelope {
        .init(
            requestID: "req-identity",
            sessionID: sessionID ?? session.sessionID,
            projectID: projectID ?? session.projectID,
            sequence: 0,
            kind: "control.activate",
            targetID: "menu/play"
        )
    }

    private func encode(_ envelope: ForgeRuntimeSemanticInteractionEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }
}

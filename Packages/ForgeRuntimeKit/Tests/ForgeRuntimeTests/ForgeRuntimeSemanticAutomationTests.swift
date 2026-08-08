import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeSemanticAutomationTests: XCTestCase {
    func testSessionBindsExactLaunchCheckpointAndRequestedHostPolicy() throws {
        let session = try makeSession(
            capabilities: [.activateControl, .setActionValue],
            policyCapabilities: [.activateControl, .setActionValue, .performGesture]
        )

        XCTAssertEqual(session.sessionID, "session-1")
        XCTAssertEqual(session.projectID, "neon-racer")
        XCTAssertEqual(session.checkpointID, "checkpoint:abc123")
        XCTAssertEqual(session.runtimeVersion, .init(major: 1, minor: 0))
        XCTAssertEqual(session.grantedCapabilities, [.activateControl, .setActionValue])
    }

    func testSessionFailsClosedWhenRequestedCapabilityExceedsHostPolicy() throws {
        let policy = try ForgeRuntimeAutomationPolicy(allowedCapabilities: [.activateControl])

        XCTAssertThrowsError(
            try ForgeRuntimeAutomationSessionAuthorizer().authorize(
                launchAuthorization: launchAuthorization(),
                sessionID: "session-1",
                checkpointID: "checkpoint:abc123",
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

    func testGateAuthorizesSemanticControlAndProducesDeterministicReceipt() throws {
        let session = try makeSession(capabilities: [.activateControl])
        var gate = ForgeRuntimeSemanticInteractionGate(session: session)
        let data = try encode(
            .init(
                requestID: "req-1",
                sessionID: session.sessionID,
                projectID: session.projectID,
                checkpointID: session.checkpointID,
                sequence: 0,
                kind: "control.activate",
                targetID: "hud/start-button"
            )
        )

        let authorized = try gate.authorize(data)
        let first = authorized.receipt(disposition: .delivered)
        let second = authorized.receipt(disposition: .delivered)

        XCTAssertEqual(gate.nextExpectedSequence, 1)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.interaction.kind, .activateControl)
        XCTAssertEqual(first.interaction.targetID, "hud/start-button")
        XCTAssertEqual(first.disposition, .delivered)
        XCTAssertNoThrow(try JSONEncoder().encode(first))
    }

    func testGateRejectsReplayAndOutOfOrderSequence() throws {
        let session = try makeSession(capabilities: [.activateControl])
        var gate = ForgeRuntimeSemanticInteractionGate(session: session)
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
    }

    func testCapabilityDenialDoesNotConsumeSequenceSlot() throws {
        let session = try makeSession(
            capabilities: [.activateControl],
            policyCapabilities: [.activateControl, .enterText]
        )
        var gate = ForgeRuntimeSemanticInteractionGate(session: session)
        let denied = try encode(
            .init(
                requestID: "req-text",
                sessionID: session.sessionID,
                projectID: session.projectID,
                checkpointID: session.checkpointID,
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
        XCTAssertNoThrow(try gate.authorize(controlData(session: session, requestID: "req-control", sequence: 0)))
        XCTAssertEqual(gate.nextExpectedSequence, 1)
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
            (
                envelope(session: session, checkpointID: "checkpoint:stale"),
                .checkpointMismatch
            ),
        ]

        for (input, expectedError) in cases {
            var gate = ForgeRuntimeSemanticInteractionGate(session: session)
            XCTAssertThrowsError(try gate.authorize(encode(input))) { error in
                XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, expectedError)
            }
            XCTAssertEqual(gate.nextExpectedSequence, 0)
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
                    checkpointID: session.checkpointID,
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
            maximumGestureDurationMilliseconds: 250
        )
        let session = try ForgeRuntimeAutomationSessionAuthorizer().authorize(
            launchAuthorization: launchAuthorization(),
            sessionID: "session-1",
            checkpointID: "checkpoint:abc123",
            requestedCapabilities: [.enterText, .performGesture],
            policy: policy
        )
        let decoder = ForgeRuntimeSemanticInteractionDecoder()

        let oversizedText = try encode(
            .init(
                requestID: "req-text",
                sessionID: session.sessionID,
                projectID: session.projectID,
                checkpointID: session.checkpointID,
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
                checkpointID: session.checkpointID,
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
                checkpointID: session.checkpointID,
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
                checkpointID: session.checkpointID,
                sequence: 0,
                kind: "system.shell"
            )
        )
        XCTAssertThrowsError(try decoder.decode(unknown, session: session)) { error in
            XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .unknownKind("system.shell"))
        }
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

    func testRestartRequiresExplicitLifecycleCapabilityAndNoPayload() throws {
        let session = try makeSession(capabilities: [.restartRuntime])
        var gate = ForgeRuntimeSemanticInteractionGate(session: session)
        let data = try encode(
            .init(
                requestID: "req-restart",
                sessionID: session.sessionID,
                projectID: session.projectID,
                checkpointID: session.checkpointID,
                sequence: 0,
                kind: "runtime.restart"
            )
        )

        let authorized = try gate.authorize(data)
        XCTAssertEqual(authorized.request.interaction.kind, .restartRuntime)
        XCTAssertEqual(authorized.receipt(disposition: .runtimeUnavailable).disposition, .runtimeUnavailable)
    }

    private func makeSession(
        capabilities: Set<ForgeRuntimeAutomationCapability>,
        policyCapabilities: Set<ForgeRuntimeAutomationCapability>? = nil
    ) throws -> ForgeRuntimeAutomationSession {
        let policy = try ForgeRuntimeAutomationPolicy(
            allowedCapabilities: policyCapabilities ?? capabilities
        )
        return try ForgeRuntimeAutomationSessionAuthorizer().authorize(
            launchAuthorization: launchAuthorization(),
            sessionID: "session-1",
            checkpointID: "checkpoint:abc123",
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
                checkpointID: session.checkpointID,
                sequence: sequence,
                kind: "control.activate",
                targetID: "menu/play"
            )
        )
    }

    private func envelope(
        session: ForgeRuntimeAutomationSession,
        sessionID: String? = nil,
        projectID: String? = nil,
        checkpointID: String? = nil
    ) -> ForgeRuntimeSemanticInteractionEnvelope {
        .init(
            requestID: "req-identity",
            sessionID: sessionID ?? session.sessionID,
            projectID: projectID ?? session.projectID,
            checkpointID: checkpointID ?? session.checkpointID,
            sequence: 0,
            kind: "control.activate",
            targetID: "menu/play"
        )
    }

    private func encode(_ envelope: ForgeRuntimeSemanticInteractionEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }
}

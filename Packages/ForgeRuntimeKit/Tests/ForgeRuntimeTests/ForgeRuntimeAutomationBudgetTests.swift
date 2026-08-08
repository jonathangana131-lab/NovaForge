import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeAutomationBudgetTests: XCTestCase {
    func testPolicyRejectsInvalidInteractionCeilings() throws {
        XCTAssertThrowsError(
            try ForgeRuntimeAutomationPolicy(
                allowedCapabilities: [.activateControl],
                maximumInteractions: 0
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeAutomationPolicyError, .invalidMaximumInteractions)
        }

        XCTAssertThrowsError(
            try ForgeRuntimeAutomationPolicy(
                allowedCapabilities: [.activateControl],
                maximumInteractions: ForgeRuntimeAutomationPolicy.hardMaximumInteractions + 1
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeAutomationPolicyError, .invalidMaximumInteractions)
        }
    }

    func testSessionCarriesExactHostInteractionCeiling() throws {
        let session = try makeSession(
            granted: [.activateControl],
            allowed: [.activateControl],
            maximumInteractions: 7
        )
        XCTAssertEqual(session.maximumInteractions, 7)
    }

    func testExactFinalAllowedInteractionSucceedsAndNextValidRequestFailsClosed() throws {
        let session = try makeSession(
            granted: [.activateControl],
            allowed: [.activateControl],
            maximumInteractions: 2
        )
        var gate = ForgeRuntimeSemanticInteractionGate(session: session)

        XCTAssertNoThrow(try gate.authorize(controlData(session: session, requestID: "req-0", sequence: 0)))
        XCTAssertEqual(gate.nextExpectedSequence, 1)
        XCTAssertNoThrow(try gate.authorize(controlData(session: session, requestID: "req-1", sequence: 1)))
        XCTAssertEqual(gate.nextExpectedSequence, 2)

        XCTAssertThrowsError(
            try gate.authorize(controlData(session: session, requestID: "req-2", sequence: 2))
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeSemanticInteractionError,
                .interactionBudgetExceeded(maximum: 2)
            )
        }
        XCTAssertEqual(gate.nextExpectedSequence, 2)
    }

    func testInvalidAndDeniedRequestsDoNotConsumeInteractionBudget() throws {
        let session = try makeSession(
            granted: [.activateControl],
            allowed: [.activateControl, .enterText],
            maximumInteractions: 1
        )
        var gate = ForgeRuntimeSemanticInteractionGate(session: session)

        let malformed = Data("not-json".utf8)
        XCTAssertThrowsError(try gate.authorize(malformed)) { error in
            XCTAssertEqual(error as? ForgeRuntimeSemanticInteractionError, .invalidJSON)
        }
        XCTAssertEqual(gate.nextExpectedSequence, 0)

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

        XCTAssertNoThrow(
            try gate.authorize(controlData(session: session, requestID: "req-control", sequence: 0))
        )
        XCTAssertEqual(gate.nextExpectedSequence, 1)
    }


    func testGateCopiesShareSequenceAndBudgetState() throws {
        let session = try makeSession(
            granted: [.activateControl],
            allowed: [.activateControl],
            maximumInteractions: 2
        )
        var firstGate = ForgeRuntimeSemanticInteractionGate(session: session)
        var copiedGate = firstGate

        XCTAssertNoThrow(
            try firstGate.authorize(controlData(session: session, requestID: "req-0", sequence: 0))
        )
        XCTAssertEqual(copiedGate.nextExpectedSequence, 1)

        XCTAssertThrowsError(
            try copiedGate.authorize(controlData(session: session, requestID: "req-replay", sequence: 0))
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeSemanticInteractionError,
                .sequenceMismatch(expected: 1, actual: 0)
            )
        }

        XCTAssertNoThrow(
            try copiedGate.authorize(controlData(session: session, requestID: "req-1", sequence: 1))
        )
        XCTAssertEqual(firstGate.nextExpectedSequence, 2)

        XCTAssertThrowsError(
            try firstGate.authorize(controlData(session: session, requestID: "req-2", sequence: 2))
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeSemanticInteractionError,
                .interactionBudgetExceeded(maximum: 2)
            )
        }
    }

    func testSeparatelyInitializedGatesForSameSessionCannotForkOrRewind() throws {
        let session = try makeSession(
            granted: [.activateControl],
            allowed: [.activateControl],
            maximumInteractions: 10
        )
        var firstGate = ForgeRuntimeSemanticInteractionGate(session: session, startingSequence: 5)
        XCTAssertNoThrow(
            try firstGate.authorize(controlData(session: session, requestID: "req-5", sequence: 5))
        )

        var secondGate = ForgeRuntimeSemanticInteractionGate(session: session, startingSequence: 0)
        XCTAssertEqual(secondGate.nextExpectedSequence, 6)
        XCTAssertThrowsError(
            try secondGate.authorize(controlData(session: session, requestID: "req-rewind", sequence: 5))
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeSemanticInteractionError,
                .sequenceMismatch(expected: 6, actual: 5)
            )
        }
        XCTAssertNoThrow(
            try secondGate.authorize(controlData(session: session, requestID: "req-6", sequence: 6))
        )
        XCTAssertEqual(firstGate.nextExpectedSequence, 7)
    }

    func testExhaustedGateChecksBudgetBeforeSequenceIncrementCanOverflow() throws {
        let session = try makeSession(
            granted: [.activateControl],
            allowed: [.activateControl],
            maximumInteractions: 1
        )
        var gate = ForgeRuntimeSemanticInteractionGate(session: session, startingSequence: Int.max)

        XCTAssertThrowsError(
            try gate.authorize(controlData(session: session, requestID: "req-max", sequence: Int.max))
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeSemanticInteractionError,
                .interactionBudgetExceeded(maximum: 1)
            )
        }
        XCTAssertEqual(gate.nextExpectedSequence, Int.max)
    }

    private func makeSession(
        granted: Set<ForgeRuntimeAutomationCapability>,
        allowed: Set<ForgeRuntimeAutomationCapability>,
        maximumInteractions: Int
    ) throws -> ForgeRuntimeAutomationSession {
        let policy = try ForgeRuntimeAutomationPolicy(
            allowedCapabilities: allowed,
            maximumInteractions: maximumInteractions
        )
        return try ForgeRuntimeAutomationSessionAuthorizer().authorize(
            launchAuthorization: ForgeRuntimeLaunchAuthorization(
                projectID: "neon-racer",
                runtimeVersion: .init(major: 1, minor: 0),
                entryPoint: "index.html",
                presentation: .init(),
                storage: .init(namespace: "neon-racer", schemaVersion: 1, quotaBytes: 1_048_576),
                grantedCapabilityIDs: [],
                network: .init(mode: .denied, allowedHosts: []),
                modules: []
            ),
            sessionID: "session-1",
            checkpointID: "checkpoint:abc123",
            requestedCapabilities: granted,
            policy: policy
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

    private func encode(_ envelope: ForgeRuntimeSemanticInteractionEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }
}

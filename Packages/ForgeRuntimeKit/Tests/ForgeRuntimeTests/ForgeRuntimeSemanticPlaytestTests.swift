import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeSemanticPlaytestTests: XCTestCase {
    func testVectorRejectsNonFiniteAndOutOfRangeValues() {
        XCTAssertThrowsError(try ForgeRuntimeSemanticVector2(x: .nan, y: 0))
        XCTAssertThrowsError(try ForgeRuntimeSemanticVector2(x: 1.01, y: 0))
        XCTAssertNoThrow(try ForgeRuntimeSemanticVector2(x: -1, y: 1))
    }

    func testControlPayloadShapesFailClosed() throws {
        let vector = try ForgeRuntimeSemanticVector2(x: 0.5, y: -0.25)
        XCTAssertNoThrow(try frame(sequence: 0, control: .move, vector: vector))
        XCTAssertThrowsError(try frame(sequence: 0, control: .move, isPressed: true))
        XCTAssertThrowsError(try frame(sequence: 0, control: .jump))
        XCTAssertThrowsError(try frame(sequence: 0, control: .menu, isPressed: true))
        XCTAssertThrowsError(try frame(sequence: 0, control: .brake, amount: 1.1)) { error in
            XCTAssertEqual(error as? ForgeRuntimePlaytestValidationError, .invalidAmount)
        }
    }

    func testDecodedFrameRevalidatesPersistedPayload() throws {
        let invalid = Data(#"{"protocolVersion":1,"sequence":0,"virtualTimeMilliseconds":0,"control":"brake","amount":2}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeRuntimeSemanticInputFrame.self, from: invalid)) { error in
            XCTAssertEqual(error as? ForgeRuntimePlaytestValidationError, .invalidAmount)
        }
    }

    func testTraceRequiresContiguousSequenceStartingAtZero() throws {
        let header = try makeHeader()
        XCTAssertThrowsError(try ForgeRuntimePlaytestTrace(header: header, frames: [try frame(sequence: 1, control: .jump, isPressed: true)])) { error in
            XCTAssertEqual(error as? ForgeRuntimePlaytestValidationError, .invalidSequence(expected: 0, actual: 1))
        }

        let frames = [
            try frame(sequence: 0, control: .jump, isPressed: true),
            try frame(sequence: 2, control: .jump, isPressed: false),
        ]
        XCTAssertThrowsError(try ForgeRuntimePlaytestTrace(header: header, frames: frames)) { error in
            XCTAssertEqual(error as? ForgeRuntimePlaytestValidationError, .invalidSequence(expected: 1, actual: 2))
        }
    }

    func testTraceRejectsVirtualTimeMovingBackward() throws {
        let header = try makeHeader()
        let frames = [
            try frame(sequence: 0, time: 100, control: .jump, isPressed: true),
            try frame(sequence: 1, time: 99, control: .jump, isPressed: false),
        ]
        XCTAssertThrowsError(try ForgeRuntimePlaytestTrace(header: header, frames: frames)) { error in
            XCTAssertEqual(
                error as? ForgeRuntimePlaytestValidationError,
                .virtualTimeMovedBackward(previous: 100, actual: 99)
            )
        }
    }

    func testTraceRejectsInvalidFrameLimit() throws {
        XCTAssertThrowsError(try ForgeRuntimePlaytestTrace(header: makeHeader(), frames: [], maximumFrames: -1)) { error in
            XCTAssertEqual(error as? ForgeRuntimePlaytestValidationError, .invalidFrameLimit(-1))
        }
    }

    func testTraceRoundTripsWithDeterministicIdentity() throws {
        let header = try makeHeader(persona: .chaosTester, seed: 42)
        let trace = try ForgeRuntimePlaytestTrace(
            header: header,
            frames: [
                try frame(sequence: 0, control: .move, vector: .init(x: 0.75, y: -0.5)),
                try frame(sequence: 1, time: 16, control: .primaryAction, isPressed: true),
                try frame(sequence: 2, time: 32, control: .primaryAction, isPressed: false),
                try frame(sequence: 3, time: 48, control: .menu, menuAction: .confirm),
            ]
        )

        let encoded = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(ForgeRuntimePlaytestTrace.self, from: encoded)
        XCTAssertEqual(decoded, trace)
        XCTAssertEqual(decoded.header.persona, .chaosTester)
        XCTAssertEqual(decoded.header.deterministicSeed, 42)
    }

    func testHeaderRejectsUnsafeOrUnboundedIdentity() {
        XCTAssertThrowsError(try makeHeader(traceID: "../escape"))
        XCTAssertThrowsError(try makeHeader(projectRevisionID: String(repeating: "a", count: 129)))
    }

    func testGrantBindsExactProjectRevisionAndRuntimeSession() throws {
        let trace = try ForgeRuntimePlaytestTrace(
            header: makeHeader(),
            frames: [try frame(sequence: 0, control: .jump, isPressed: true)]
        )
        let goodGrant = try grant(allowedControls: [.jump])
        XCTAssertNoThrow(try goodGrant.authorize(trace))

        let staleGrant = try ForgeRuntimePlaytestInputGrant(
            projectID: "neon-racer",
            projectRevisionID: "checkpoint-old",
            runtimeSessionID: "session-1",
            allowedControls: [.jump]
        )
        XCTAssertThrowsError(try staleGrant.authorize(trace)) { error in
            XCTAssertEqual(error as? ForgeRuntimePlaytestValidationError, .contextMismatch(field: "projectRevisionID"))
        }
    }

    func testGrantRejectsSemanticControlOutsideHostCeiling() throws {
        let trace = try ForgeRuntimePlaytestTrace(
            header: makeHeader(),
            frames: [try frame(sequence: 0, control: .restart, isPressed: true)]
        )
        let grant = try grant(allowedControls: [.move, .look, .jump])
        XCTAssertThrowsError(try grant.authorize(trace)) { error in
            XCTAssertEqual(error as? ForgeRuntimePlaytestValidationError, .controlNotGranted(.restart))
        }
    }

    func testDecodedGrantRevalidatesHostOwnedLimits() {
        let invalid = Data(#"{"projectID":"neon-racer","projectRevisionID":"checkpoint-7","runtimeSessionID":"session-1","allowedControls":["jump"],"maximumFrames":-1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeRuntimePlaytestInputGrant.self, from: invalid)) { error in
            XCTAssertEqual(error as? ForgeRuntimePlaytestValidationError, .invalidFrameLimit(-1))
        }
    }

    func testGrantEnforcesHostOwnedFrameBudget() throws {
        let trace = try ForgeRuntimePlaytestTrace(
            header: makeHeader(),
            frames: [
                try frame(sequence: 0, control: .jump, isPressed: true),
                try frame(sequence: 1, time: 1, control: .jump, isPressed: false),
            ]
        )
        let grant = try grant(allowedControls: [.jump], maximumFrames: 1)
        XCTAssertThrowsError(try grant.authorize(trace)) { error in
            XCTAssertEqual(error as? ForgeRuntimePlaytestValidationError, .tooManyFrames(actual: 2, maximum: 1))
        }
    }

    func testPassedReceiptRequiresConcreteEvidenceReference() throws {
        let header = try makeHeader()
        XCTAssertThrowsError(try ForgeRuntimePlaytestReceipt(traceHeader: header, outcome: .passed, evidence: [])) { error in
            XCTAssertEqual(error as? ForgeRuntimePlaytestValidationError, .missingEvidenceForPass)
        }

        let evidence = try ForgeRuntimePlaytestEvidenceReference(kind: .stateMilestone, evidenceID: "milestone-win")
        let receipt = try ForgeRuntimePlaytestReceipt(traceHeader: header, outcome: .passed, evidence: [evidence])
        XCTAssertEqual(receipt.outcome, .passed)
        XCTAssertEqual(receipt.projectRevisionID, "checkpoint-7")
        XCTAssertEqual(receipt.evidence, [evidence])
    }

    func testDecodedPassedReceiptCannotBypassEvidenceRequirement() {
        let invalid = Data(#"{"traceID":"trace-1","projectID":"neon-racer","projectRevisionID":"checkpoint-7","runtimeSessionID":"session-1","journeyID":"goal-path","outcome":"passed","evidence":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeRuntimePlaytestReceipt.self, from: invalid)) { error in
            XCTAssertEqual(error as? ForgeRuntimePlaytestValidationError, .missingEvidenceForPass)
        }
    }

    func testEvidenceIdentifierFailsClosed() {
        XCTAssertThrowsError(try ForgeRuntimePlaytestEvidenceReference(kind: .screenshot, evidenceID: "../shot")) { error in
            XCTAssertEqual(error as? ForgeRuntimePlaytestValidationError, .invalidEvidenceIdentifier)
        }
    }

    private func frame(
        sequence: UInt64,
        time: UInt64 = 0,
        control: ForgeRuntimeSemanticControl,
        vector: ForgeRuntimeSemanticVector2? = nil,
        amount: Double? = nil,
        isPressed: Bool? = nil,
        menuAction: ForgeRuntimeMenuAction? = nil
    ) throws -> ForgeRuntimeSemanticInputFrame {
        try ForgeRuntimeSemanticInputFrame(
            sequence: sequence,
            virtualTimeMilliseconds: time,
            control: control,
            vector: vector,
            amount: amount,
            isPressed: isPressed,
            menuAction: menuAction
        )
    }

    private func makeHeader(
        traceID: String = "trace-1",
        projectRevisionID: String = "checkpoint-7",
        persona: ForgeRuntimePlaytestPersona = .goalRunner,
        seed: UInt64 = 7
    ) throws -> ForgeRuntimePlaytestTraceHeader {
        try ForgeRuntimePlaytestTraceHeader(
            traceID: traceID,
            projectID: "neon-racer",
            projectRevisionID: projectRevisionID,
            runtimeSessionID: "session-1",
            journeyID: "goal-path",
            persona: persona,
            deterministicSeed: seed
        )
    }

    private func grant(
        allowedControls: Set<ForgeRuntimeSemanticControl>,
        maximumFrames: Int = ForgeRuntimePlaytestTrace.defaultMaximumFrames
    ) throws -> ForgeRuntimePlaytestInputGrant {
        try ForgeRuntimePlaytestInputGrant(
            projectID: "neon-racer",
            projectRevisionID: "checkpoint-7",
            runtimeSessionID: "session-1",
            allowedControls: allowedControls,
            maximumFrames: maximumFrames
        )
    }
}

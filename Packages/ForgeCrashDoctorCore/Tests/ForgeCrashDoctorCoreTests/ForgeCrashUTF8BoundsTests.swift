import Foundation
import XCTest
@testable import ForgeCrashDoctorCore

final class ForgeCrashUTF8BoundsTests: XCTestCase {
    func testIncidentMessageLimitUsesRetainedUTF8BytesNotGraphemeCount() throws {
        let oversizedMessage = "a" + String(repeating: "\u{0301}", count: 1_001)
        XCTAssertEqual(oversizedMessage.count, 1)
        XCTAssertGreaterThan(oversizedMessage.utf8.count, 2_000)

        XCTAssertThrowsError(try incident(message: oversizedMessage)) { error in
            XCTAssertEqual(
                error as? ForgeCrashValidationError,
                .fieldTooLong(field: "incident.message", maximum: 2_000)
            )
        }
    }

    func testPersistedIncidentDecodeRejectsOversizedDecomposedUnicodeMessage() throws {
        let valid = try incident(message: "valid")
        let encoded = try JSONEncoder().encode(valid)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let oversizedMessage = "a" + String(repeating: "\u{0301}", count: 1_001)
        object["message"] = oversizedMessage
        let forged = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCrashIncident.self, from: forged)) { error in
            XCTAssertEqual(
                error as? ForgeCrashValidationError,
                .fieldTooLong(field: "incident.message", maximum: 2_000)
            )
        }
    }

    func testDerivedFallbackRepeatKeyRemainsWithinUTF8ByteBudgetAfterLowercasing() throws {
        let expansionProne = String(repeating: "İ", count: 100)
        XCTAssertLessThanOrEqual(expansionProne.utf8.count, 2_000)
        XCTAssertGreaterThan(expansionProne.lowercased().utf8.count, 240)

        let repeatKey = ForgeCrashRepeatKey.derive(from: try incident(message: expansionProne))
        let fallback = try XCTUnwrap(repeatKey.fallbackMessage)

        XCTAssertFalse(fallback.isEmpty)
        XCTAssertLessThanOrEqual(fallback.utf8.count, 240)
    }

    private func incident(message: String) throws -> ForgeCrashIncident {
        try ForgeCrashIncident(
            incidentID: "incident-1",
            projectID: "project-1",
            checkpointID: "checkpoint-1",
            projectRevision: "revision-1",
            runtimeVersion: "runtime-1",
            runtimeSessionID: "session-1",
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .runtimeException,
            message: message
        )
    }
}

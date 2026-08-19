import Foundation
import XCTest
@testable import ForgeCompletionCore

final class ForgeCompletionUTF8BoundsTests: XCTestCase {
    func testIdentifierLimitUsesRetainedUTF8BytesNotGraphemeCount() throws {
        let oversizedIdentifier = String(repeating: "👨‍👩‍👧‍👦", count: 40)
        XCTAssertLessThan(oversizedIdentifier.count, 256)
        XCTAssertGreaterThan(oversizedIdentifier.utf8.count, 256)

        XCTAssertThrowsError(
            try ForgeCompletionCriterion(
                id: oversizedIdentifier,
                kind: .build,
                title: "Build",
                requiredEvidenceClasses: [.buildReceipt]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .invalidIdentifier("criterion.id"))
        }
    }

    func testTextLimitUsesRetainedUTF8BytesNotGraphemeCount() throws {
        let oversizedTitle = String(repeating: "👨‍👩‍👧‍👦", count: 50)
        XCTAssertLessThan(oversizedTitle.count, 1_024)
        XCTAssertGreaterThan(oversizedTitle.utf8.count, 1_024)

        XCTAssertThrowsError(
            try ForgeCompletionCriterion(
                id: "build",
                kind: .build,
                title: oversizedTitle,
                requiredEvidenceClasses: [.buildReceipt]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .invalidText("criterion.title"))
        }
    }

    func testPersistedTargetDecodeRejectsDecomposedUnicodeIdentifierAboveUTF8Limit() throws {
        let oversizedSourceRevision = "a" + String(repeating: "\u{0301}", count: 300)
        XCTAssertEqual(oversizedSourceRevision.count, 1)
        XCTAssertGreaterThan(oversizedSourceRevision.utf8.count, 512)

        let data = try JSONSerialization.data(withJSONObject: [
            "missionID": "mission",
            "projectID": "project",
            "sourceRevision": oversizedSourceRevision,
            "constitutionRevision": 1,
            "constitutionReceiptID": "constitution-receipt",
        ])

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCompletionTarget.self, from: data)) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .invalidIdentifier("target.sourceRevision"))
        }
    }

    func testPersistedDefectDecodeRejectsDecomposedUnicodeTextAboveUTF8Limit() throws {
        let oversizedSummary = "a" + String(repeating: "\u{0301}", count: 2_100)
        XCTAssertEqual(oversizedSummary.count, 1)
        XCTAssertGreaterThan(oversizedSummary.utf8.count, 4_096)

        let data = try JSONSerialization.data(withJSONObject: [
            "id": "defect-1",
            "severity": "low",
            "status": "open",
            "summary": oversizedSummary,
        ])

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCompletionDefect.self, from: data)) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .invalidText("defect.summary"))
        }
    }
}

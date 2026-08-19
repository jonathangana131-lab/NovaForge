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
}

import XCTest
@testable import ForgeVisualQA

final class ForgeAcceptanceEvidenceSemanticSourceTests: XCTestCase {
    func testAccessibilityCheckRejectsSemanticallyWrongEvidenceSource() throws {
        XCTAssertThrowsError(
            try VisualAccessibilityObservation(
                check: .voiceOverTraversal,
                passed: true,
                source: .screenshotMeasurement
            )
        )
        XCTAssertThrowsError(
            try VisualAccessibilityObservation(
                check: .minimumTouchTarget,
                passed: true,
                source: .runtimeInteraction
            )
        )
    }
}

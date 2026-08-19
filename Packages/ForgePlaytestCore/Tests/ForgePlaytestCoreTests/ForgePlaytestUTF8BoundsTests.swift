import XCTest
@testable import ForgePlaytestCore

final class ForgePlaytestUTF8BoundsTests: XCTestCase {
    func testSemanticControlIDLimitUsesRetainedUTF8BytesNotGraphemeCount() throws {
        let oversizedControlID = "a" + String(repeating: "\u{0301}", count: 60)
        XCTAssertEqual(oversizedControlID.count, 1)
        XCTAssertGreaterThan(oversizedControlID.utf8.count, 120)

        XCTAssertThrowsError(
            try ForgePlaytestAction.validatedButton(
                controlID: oversizedControlID,
                phase: .press
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgePlaytestError,
                .valueTooLong(field: "controlID", maximum: 120)
            )
        }
    }

    func testProjectAndResultIdentifiersUseRetainedUTF8ByteLimits() throws {
        let oversizedProjectID = "p" + String(repeating: "\u{0301}", count: 80)
        XCTAssertEqual(oversizedProjectID.count, 1)
        XCTAssertGreaterThan(oversizedProjectID.utf8.count, 160)

        XCTAssertThrowsError(
            try ForgePlaytestProjectRevision(
                projectID: oversizedProjectID,
                sourceRevision: "revision-1"
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgePlaytestError,
                .valueTooLong(field: "projectID", maximum: 160)
            )
        }

        let project = try ForgePlaytestProjectRevision(
            projectID: "project-1",
            sourceRevision: "revision-1"
        )
        let oversizedJourneyID = "j" + String(repeating: "\u{0301}", count: 80)
        XCTAssertEqual(oversizedJourneyID.count, 1)
        XCTAssertGreaterThan(oversizedJourneyID.utf8.count, 160)

        XCTAssertThrowsError(
            try ForgePlaytestJourneyResult(
                project: project,
                journeyID: oversizedJourneyID,
                persona: .goalRunner,
                traceID: "trace-1",
                status: .failed,
                evidence: []
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgePlaytestError,
                .valueTooLong(field: "journeyID", maximum: 160)
            )
        }
    }

    func testDefectSummaryLimitUsesRetainedUTF8BytesNotGraphemeCount() throws {
        let oversizedSummary = "a" + String(repeating: "\u{0301}", count: 300)
        XCTAssertEqual(oversizedSummary.count, 1)
        XCTAssertGreaterThan(oversizedSummary.utf8.count, 600)

        XCTAssertThrowsError(
            try ForgePlaytestDefect(
                defectID: "defect-1",
                severity: .high,
                category: .runtime,
                summary: oversizedSummary,
                evidenceReceiptIDs: ["runtime-receipt-1"]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgePlaytestError,
                .valueTooLong(field: "defect.summary", maximum: 600)
            )
        }
    }

    func testReceiptIDSetEnforcesUTF8ByteLimit() throws {
        let oversizedReceiptID = "r" + String(repeating: "\u{0301}", count: 100)
        XCTAssertEqual(oversizedReceiptID.count, 1)
        XCTAssertGreaterThan(oversizedReceiptID.utf8.count, 200)

        XCTAssertThrowsError(
            try ForgePlaytestMilestoneObservation(
                milestoneID: "milestone-1",
                evidenceReceiptIDs: [oversizedReceiptID]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgePlaytestError,
                .valueTooLong(field: "receiptID", maximum: 200)
            )
        }
    }
}
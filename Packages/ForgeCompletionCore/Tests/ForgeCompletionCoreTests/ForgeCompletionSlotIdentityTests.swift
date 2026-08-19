import XCTest
@testable import ForgeCompletionCore

final class ForgeCompletionSlotIdentityTests: XCTestCase {
    func testDelimiterShapedIDsCannotCollapseDistinctEvidenceSlots() throws {
        let target = try ForgeCompletionTarget(
            missionID: "mission-slot-collision",
            projectID: "project-slot-collision",
            sourceRevision: "source-1",
            constitutionRevision: 1,
            constitutionReceiptID: "constitution-1"
        )
        let first = try ForgeCompletionCriterion(
            id: "x",
            kind: .build,
            title: "First distinct slot",
            requiredEvidenceClasses: [.buildReceipt],
            journeyIDs: ["a|launchReceipt|b"]
        )
        let second = try ForgeCompletionCriterion(
            id: "x|buildReceipt|a",
            kind: .launch,
            title: "Second distinct slot",
            requiredEvidenceClasses: [.launchReceipt],
            journeyIDs: ["b"]
        )
        let constitution = try ForgeCompletionConstitution(
            target: target,
            criteria: [first, second]
        )
        let onlyFirst = try ForgeCompletionEvidence(
            id: "first-only",
            target: target,
            criterionID: first.id,
            evidenceClass: .buildReceipt,
            journeyID: "a|launchReceipt|b",
            authority: .buildSystem,
            authorityReceiptID: "build-receipt-1",
            outcome: .passed
        )
        let inventory = try ForgeCompletionDefectInventory(
            target: target,
            authorityReceiptID: "defect-scan-1",
            defects: []
        )

        let evaluation = try ForgeCompletionEvaluator.evaluate(
            constitution: constitution,
            evidence: [onlyFirst],
            defectInventory: inventory
        )

        XCTAssertEqual(evaluation.status, .blocked)
        XCTAssertEqual(evaluation.acceptedEvidenceIDs, ["first-only"])
        XCTAssertTrue(
            evaluation.blockers.contains(
                .missingEvidence(
                    criterionID: second.id,
                    evidenceClass: .launchReceipt,
                    journeyID: "b"
                )
            )
        )
    }

    func testDelimiterShapedDistinctSlotsCanBothBeSatisfiedIndependently() throws {
        let target = try ForgeCompletionTarget(
            missionID: "mission-slot-collision",
            projectID: "project-slot-collision",
            sourceRevision: "source-1",
            constitutionRevision: 1,
            constitutionReceiptID: "constitution-1"
        )
        let first = try ForgeCompletionCriterion(
            id: "x",
            kind: .build,
            title: "First distinct slot",
            requiredEvidenceClasses: [.buildReceipt],
            journeyIDs: ["a|launchReceipt|b"]
        )
        let second = try ForgeCompletionCriterion(
            id: "x|buildReceipt|a",
            kind: .launch,
            title: "Second distinct slot",
            requiredEvidenceClasses: [.launchReceipt],
            journeyIDs: ["b"]
        )
        let constitution = try ForgeCompletionConstitution(
            target: target,
            criteria: [first, second]
        )
        let firstEvidence = try ForgeCompletionEvidence(
            id: "first",
            target: target,
            criterionID: first.id,
            evidenceClass: .buildReceipt,
            journeyID: "a|launchReceipt|b",
            authority: .buildSystem,
            authorityReceiptID: "build-receipt-1",
            outcome: .passed
        )
        let secondEvidence = try ForgeCompletionEvidence(
            id: "second",
            target: target,
            criterionID: second.id,
            evidenceClass: .launchReceipt,
            journeyID: "b",
            authority: .runtimeHarness,
            authorityReceiptID: "launch-receipt-1",
            outcome: .passed
        )
        let inventory = try ForgeCompletionDefectInventory(
            target: target,
            authorityReceiptID: "defect-scan-1",
            defects: []
        )

        let evaluation = try ForgeCompletionEvaluator.evaluate(
            constitution: constitution,
            evidence: [firstEvidence, secondEvidence],
            defectInventory: inventory
        )

        XCTAssertEqual(evaluation.status, .satisfied)
        XCTAssertEqual(Set(evaluation.acceptedEvidenceIDs), ["first", "second"])
        XCTAssertTrue(evaluation.blockers.isEmpty)
    }
}

import XCTest
@testable import ForgeCompletionCore

final class ForgeCompletionSatisfiabilityTests: XCTestCase {
    private let slotLimitError = ForgeCompletionError.collectionTooLarge(
        field: "constitution.requiredEvidenceSlots",
        maximum: ForgeCompletionConstitution.maximumRequiredEvidenceSlots
    )

    private func target() throws -> ForgeCompletionTarget {
        try ForgeCompletionTarget(
            missionID: "mission-slot-budget",
            projectID: "project-slot-budget",
            sourceRevision: "source-slot-budget",
            constitutionRevision: 1,
            constitutionReceiptID: "constitution-slot-budget"
        )
    }

    private func journeys() -> [String] {
        (0..<ForgeCompletionCriterion.maximumJourneyIDs).map { "journey-\($0)" }
    }

    private func requiredCriterion(id: String, journeys: [String]) throws -> ForgeCompletionCriterion {
        try ForgeCompletionCriterion(
            id: id,
            kind: .custom,
            title: "Required \(id)",
            requiredEvidenceClasses: [.testReceipt],
            journeyIDs: journeys
        )
    }

    func testConstitutionAcceptsRequiredEvidenceDemandExactlyAtEvaluatorCap() throws {
        XCTAssertEqual(
            ForgeCompletionEvaluator.maximumEvidence,
            ForgeCompletionConstitution.maximumRequiredEvidenceSlots
        )

        let journeyIDs = journeys()
        let criterionCount = ForgeCompletionConstitution.maximumRequiredEvidenceSlots / journeyIDs.count
        XCTAssertEqual(criterionCount * journeyIDs.count, ForgeCompletionConstitution.maximumRequiredEvidenceSlots)
        XCTAssertLessThanOrEqual(criterionCount, ForgeCompletionConstitution.maximumCriteria)

        let criteria = try (0..<criterionCount).map {
            try requiredCriterion(id: "required-\($0)", journeys: journeyIDs)
        }

        XCTAssertNoThrow(try ForgeCompletionConstitution(target: target(), criteria: criteria))
    }

    func testConstitutionRejectsRequiredEvidenceDemandOnePastEvaluatorCap() throws {
        let journeyIDs = journeys()
        let criterionCount = ForgeCompletionConstitution.maximumRequiredEvidenceSlots / journeyIDs.count
        var criteria = try (0..<criterionCount).map {
            try requiredCriterion(id: "required-\($0)", journeys: journeyIDs)
        }
        criteria.append(try requiredCriterion(id: "one-more-slot", journeys: []))

        XCTAssertThrowsError(try ForgeCompletionConstitution(target: target(), criteria: criteria)) { error in
            XCTAssertEqual(error as? ForgeCompletionError, self.slotLimitError)
        }
    }

    func testRequiredEvidenceSlotMultiplicationOverflowFailsClosed() throws {
        XCTAssertThrowsError(
            try ForgeCompletionConstitution.checkedRequiredEvidenceSlotCount(
                evidenceClassCount: Int.max,
                journeyCount: 2,
                currentCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompletionError, self.slotLimitError)
        }
    }

    func testRequiredEvidenceSlotAdditionOverflowFailsClosed() throws {
        XCTAssertThrowsError(
            try ForgeCompletionConstitution.checkedRequiredEvidenceSlotCount(
                evidenceClassCount: 1,
                journeyCount: 1,
                currentCount: Int.max
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompletionError, self.slotLimitError)
        }
    }

    func testWaivedCriteriaDoNotConsumeRequiredEvidenceBudget() throws {
        let journeyIDs = journeys()
        let criterionCount = ForgeCompletionConstitution.maximumRequiredEvidenceSlots / journeyIDs.count
        var criteria = try (0..<criterionCount).map {
            try requiredCriterion(id: "required-\($0)", journeys: journeyIDs)
        }
        let waiver = try ForgeCompletionWaiver(
            explanation: "Explicitly waived work does not require fake completion evidence.",
            authorityReceiptID: "waiver-slot-budget"
        )
        criteria.append(try ForgeCompletionCriterion(
            id: "waived-extra",
            kind: .custom,
            title: "Waived extra",
            requirement: .waived(waiver),
            requiredEvidenceClasses: [.testReceipt],
            journeyIDs: journeyIDs
        ))

        XCTAssertNoThrow(try ForgeCompletionConstitution(target: target(), criteria: criteria))
    }
}

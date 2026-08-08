import XCTest
@testable import ForgeCompactCore

final class ForgeCompactPostMergeHardeningTests: XCTestCase {
    func testAcceptedDecisionIsMandatoryWithoutUserProtection() throws {
        let decision = try item(
            id: "accepted-direction",
            tier: .l2ProjectMemory,
            kind: .acceptedDecision,
            priority: 0,
            content: "Use the local-first runtime.",
            provenanceKind: .user
        )
        let optional = try item(
            id: "optional",
            tier: .l1ActiveWorkingSet,
            kind: .workingNote,
            priority: 100,
            content: String(repeating: "optional ", count: 40),
            authoritative: false
        )

        let capsule = try ProjectCapsuleBuilder.build(
            authority: authority(),
            items: [optional, decision],
            budgetBytes: decision.renderedUTF8Bytes
        )

        XCTAssertEqual(capsule.selectedItems.map(\.id), ["accepted-direction"])
        XCTAssertTrue(decision.mustRetain)
    }

    func testMissionStageAndKnownDefectAreMandatoryTruth() throws {
        let stage = try item(
            id: "stage",
            tier: .l2ProjectMemory,
            kind: .missionStage,
            priority: 0,
            content: "repair"
        )
        let defect = try item(
            id: "defect",
            tier: .l2ProjectMemory,
            kind: .knownDefect,
            priority: 0,
            content: "Launch still fails."
        )

        XCTAssertTrue(stage.mustRetain)
        XCTAssertTrue(defect.mustRetain)
    }

    func testModelSummaryCannotBecomeMandatoryThroughL0OrProtection() throws {
        XCTAssertThrowsError(
            try item(
                id: "summary-l0",
                tier: .l0AlwaysResident,
                kind: .workingNote,
                priority: 100,
                content: "Model-generated note.",
                provenanceKind: .modelSummary,
                authoritative: false
            )
        )

        XCTAssertThrowsError(
            try ForgeCompactContextItem(
                id: "summary-protected",
                sourceRevision: "src-1",
                tier: .l2ProjectMemory,
                kind: .workingNote,
                priority: 100,
                content: "Model-generated protected note.",
                provenance: ForgeCompactProvenance(kind: .modelSummary, reference: "summary"),
                isAuthoritative: false,
                protectedByUser: true
            )
        )
    }

    private func authority() throws -> ProjectCapsuleAuthority {
        try ProjectCapsuleAuthority(
            projectID: "project-1",
            missionID: "mission-1",
            sourceRevision: "src-1",
            missionRevision: 1,
            authorityEpoch: 1,
            capsuleRevision: 1
        )
    }

    private func item(
        id: String,
        tier: ForgeCompactContextTier,
        kind: ForgeCompactFactKind,
        priority: Int,
        content: String,
        provenanceKind: ForgeCompactProvenanceKind = .source,
        authoritative: Bool = true
    ) throws -> ForgeCompactContextItem {
        try ForgeCompactContextItem(
            id: id,
            sourceRevision: "src-1",
            tier: tier,
            kind: kind,
            priority: priority,
            content: content,
            provenance: ForgeCompactProvenance(kind: provenanceKind, reference: "ref-\(id)"),
            isAuthoritative: authoritative
        )
    }
}

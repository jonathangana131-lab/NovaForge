import Foundation
import XCTest
@testable import ForgeCompactCore

final class ForgeCompactPostMergeHardeningTests: XCTestCase {
    private func authority() throws -> ProjectCapsuleAuthority {
        try .init(
            projectID: "project-1",
            missionID: "mission-1",
            sourceRevision: "source-r1",
            missionRevision: 4,
            authorityEpoch: 2,
            capsuleRevision: 7
        )
    }

    private func provenance(_ kind: ForgeCompactProvenanceKind = .source) throws -> ForgeCompactProvenance {
        try .init(kind: kind, reference: "receipt-r1")
    }

    private func item(
        id: String,
        tier: ForgeCompactContextTier = .l2ProjectMemory,
        kind: ForgeCompactFactKind,
        provenanceKind: ForgeCompactProvenanceKind = .source,
        protectedByUser: Bool = false
    ) throws -> ForgeCompactContextItem {
        try .init(
            id: id,
            sourceRevision: "source-r1",
            tier: tier,
            kind: kind,
            priority: 50,
            content: "truth for \(id)",
            provenance: provenance(provenanceKind),
            isAuthoritative: provenanceKind != .modelSummary,
            freshness: .current,
            protectedByUser: protectedByUser
        )
    }

    func testMissionStageKnownDefectAndAcceptedDecisionAreMandatoryTruth() throws {
        let stage = try item(id: "stage", kind: .missionStage)
        let defect = try item(id: "defect", kind: .knownDefect)
        let decision = try item(id: "decision", kind: .acceptedDecision)

        XCTAssertTrue(stage.mustRetain)
        XCTAssertTrue(defect.mustRetain)
        XCTAssertTrue(decision.mustRetain)

        XCTAssertThrowsError(
            try ProjectCapsuleBuilder.build(
                authority: authority(),
                items: [stage, defect, decision],
                budgetBytes: 1
            )
        ) { error in
            guard case .budgetCannotHoldMandatoryTruth = error as? ForgeCompactError else {
                return XCTFail("Expected mandatory truth budget failure, got \(error)")
            }
        }
    }

    func testModelSummaryCannotBecomeMandatoryThroughL0() throws {
        XCTAssertThrowsError(
            try item(
                id: "summary-l0",
                tier: .l0AlwaysResident,
                kind: .workingNote,
                provenanceKind: .modelSummary
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .modelSummaryCannotSupplyMandatoryTruth(itemID: "summary-l0")
            )
        }
    }

    func testModelSummaryCannotBecomeMandatoryThroughUserProtection() throws {
        XCTAssertThrowsError(
            try item(
                id: "summary-protected",
                kind: .workingNote,
                provenanceKind: .modelSummary,
                protectedByUser: true
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .modelSummaryCannotSupplyMandatoryTruth(itemID: "summary-protected")
            )
        }
    }

    func testAuthorityIdentifiersRejectWhitespaceAliasesInsteadOfNormalizing() {
        XCTAssertThrowsError(
            try ProjectCapsuleAuthority(
                projectID: " project-1 ",
                missionID: "mission-1",
                sourceRevision: "source-r1",
                missionRevision: 1,
                authorityEpoch: 1,
                capsuleRevision: 1
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .invalidIdentifier(field: "projectID"))
        }
    }

    func testDecodedAuthorityRejectsWhitespaceAlias() throws {
        let original = try authority()
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["sourceRevision"] = " source-r1 "
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ProjectCapsuleAuthority.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCompactError, .invalidIdentifier(field: "sourceRevision"))
        }
    }
}

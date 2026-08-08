import Foundation
import XCTest
@testable import ForgeCompactCore

final class ForgeCompactRetentionRegressionTests: XCTestCase {
    func testMissionStageAcceptedDecisionAndKnownDefectAreMandatoryTruth() throws {
        let values = try [
            item(id: "stage", kind: .missionStage, content: "visual-critique"),
            item(id: "decision", kind: .acceptedDecision, content: "Keep Local Only enabled."),
            item(id: "defect", kind: .knownDefect, content: "Restart path still fails."),
        ]

        XCTAssertTrue(values.allSatisfy(\.mustRetain))
        XCTAssertTrue(ForgeCompactFactKind.missionStage.requiresRetentionWhenPresent)
        XCTAssertTrue(ForgeCompactFactKind.acceptedDecision.requiresRetentionWhenPresent)
        XCTAssertTrue(ForgeCompactFactKind.knownDefect.requiresRetentionWhenPresent)
    }

    func testMandatoryMissionTruthSurvivesOptionalContextPressure() throws {
        let stage = try item(id: "stage", kind: .missionStage, content: "repair")
        let decision = try item(id: "decision", kind: .acceptedDecision, content: "Preserve the compact composer.")
        let defect = try item(id: "defect", kind: .knownDefect, content: "Launch journey is unresolved.")
        let optional = try ForgeCompactContextItem(
            id: "optional",
            sourceRevision: "src-1",
            tier: .l1ActiveWorkingSet,
            kind: .workingNote,
            priority: 100,
            content: String(repeating: "discardable history ", count: 80),
            provenance: try ForgeCompactProvenance(kind: .source, reference: "ref-optional"),
            isAuthoritative: false
        )
        let mandatory = [stage, decision, defect].sorted(by: ProjectCapsuleBuilder.canonicalOrderForTests)
        let budget = mandatory.map(\.renderedLine).joined(separator: "\n").utf8.count

        let capsule = try ProjectCapsuleBuilder.build(
            authority: authority(),
            items: [optional, defect, decision, stage],
            budgetBytes: budget
        )

        XCTAssertEqual(Set(capsule.selectedItems.map(\.id)), Set(["stage", "decision", "defect"]))
        XCTAssertEqual(capsule.omittedItems.map(\.id), ["optional"])
        XCTAssertFalse(capsule.omittedItems.contains(where: \.mustRetain))
    }

    func testModelSummaryCannotBecomeMandatoryThroughL0Tier() throws {
        XCTAssertThrowsError(
            try item(
                id: "summary-l0",
                tier: .l0AlwaysResident,
                kind: .workingNote,
                content: "The model says this belongs in permanent truth.",
                provenanceKind: .modelSummary,
                authoritative: false
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
                tier: .l3ColdArchive,
                kind: .workingNote,
                content: "The model marked its own summary as protected.",
                provenanceKind: .modelSummary,
                authoritative: false,
                protectedByUser: true
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .modelSummaryCannotSupplyMandatoryTruth(itemID: "summary-protected")
            )
        }
    }

    func testModelSummaryCannotMintAcceptedDecisionTruth() throws {
        XCTAssertThrowsError(
            try item(
                id: "summary-decision",
                kind: .acceptedDecision,
                content: "The model decided without accepted authority.",
                provenanceKind: .modelSummary,
                authoritative: false
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .modelSummaryCannotSupplyMandatoryTruth(itemID: "summary-decision")
            )
        }
    }

    func testDecodedOmittedAcceptedDecisionFailsClosed() throws {
        let optional = try item(
            id: "note",
            kind: .workingNote,
            content: "Optional context.",
            authoritative: false
        )
        let capsule = try ProjectCapsuleBuilder.build(authority: authority(), items: [optional], budgetBytes: 0)
        let encoded = try JSONEncoder().encode(capsule)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var omitted = try XCTUnwrap(object["omittedItems"] as? [[String: Any]])
        omitted[0]["kind"] = ForgeCompactFactKind.acceptedDecision.rawValue
        object["omittedItems"] = omitted

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ProjectCapsule.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    private func authority() throws -> ProjectCapsuleAuthority {
        try ProjectCapsuleAuthority(
            projectID: "project-1",
            missionID: "mission-1",
            sourceRevision: "src-1",
            missionRevision: 3,
            authorityEpoch: 2,
            capsuleRevision: 1
        )
    }

    private func item(
        id: String,
        tier: ForgeCompactContextTier = .l3ColdArchive,
        kind: ForgeCompactFactKind,
        content: String,
        provenanceKind: ForgeCompactProvenanceKind = .source,
        authoritative: Bool = true,
        protectedByUser: Bool = false
    ) throws -> ForgeCompactContextItem {
        try ForgeCompactContextItem(
            id: id,
            sourceRevision: "src-1",
            tier: tier,
            kind: kind,
            priority: 0,
            content: content,
            provenance: try ForgeCompactProvenance(kind: provenanceKind, reference: "ref-\(id)"),
            isAuthoritative: authoritative,
            protectedByUser: protectedByUser
        )
    }
}

private extension ProjectCapsuleBuilder {
    static func canonicalOrderForTests(_ lhs: ForgeCompactContextItem, _ rhs: ForgeCompactContextItem) -> Bool {
        if lhs.tier.selectionRank != rhs.tier.selectionRank {
            return lhs.tier.selectionRank < rhs.tier.selectionRank
        }
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        return lhs.id < rhs.id
    }
}

import Foundation
import XCTest
@testable import ForgeCompactCore

final class ForgeCompactPostMergeHardeningTests: XCTestCase {
    func testAcceptedMissionTruthKindsAreStructurallyMandatory() throws {
        let mandatoryKinds: [ForgeCompactFactKind] = [
            .missionStage,
            .acceptedDecision,
            .designDNA,
            .knownDefect,
        ]

        for kind in mandatoryKinds {
            let value = try item(
                id: kind.rawValue,
                tier: .l2ProjectMemory,
                kind: kind,
                content: "accepted \(kind.rawValue)"
            )
            XCTAssertTrue(value.mustRetain, "\(kind.rawValue) must remain durable mission truth")
            XCTAssertThrowsError(
                try ProjectCapsuleBuilder.build(
                    authority: authority(),
                    items: [value],
                    budgetBytes: 0
                )
            )
        }
    }

    func testModelSummaryCannotBecomeMandatoryThroughTierOrProtection() throws {
        XCTAssertThrowsError(
            try item(
                id: "summary-l0",
                tier: .l0AlwaysResident,
                kind: .workingNote,
                content: "model says this is permanent",
                authoritative: false,
                provenanceKind: .modelSummary
            )
        )

        XCTAssertThrowsError(
            try item(
                id: "summary-protected",
                tier: .l2ProjectMemory,
                kind: .workingNote,
                content: "model says this is protected",
                authoritative: false,
                provenanceKind: .modelSummary,
                protectedByUser: true
            )
        )
    }

    func testOmittedContextPreservesDurableRetrievalProvenance() throws {
        let note = try item(
            id: "cold-note",
            tier: .l3ColdArchive,
            kind: .workingNote,
            content: "Retrieve me later.",
            authoritative: false,
            provenanceKind: .checkpoint,
            provenanceReference: "checkpoint:mission-1:cold-note"
        )

        let capsule = try ProjectCapsuleBuilder.build(
            authority: authority(),
            items: [note],
            budgetBytes: 0
        )
        let omitted = try XCTUnwrap(capsule.omittedItems.first)

        XCTAssertEqual(omitted.id, note.id)
        XCTAssertEqual(omitted.sourceRevision, note.sourceRevision)
        XCTAssertEqual(omitted.kind, note.kind)
        XCTAssertEqual(omitted.provenance, note.provenance)
        XCTAssertEqual(omitted.provenance.reference, "checkpoint:mission-1:cold-note")
    }

    func testOmittedRetrievalProvenanceRevalidatesOnDecode() throws {
        let note = try item(
            id: "cold-note",
            tier: .l3ColdArchive,
            kind: .workingNote,
            content: "Retrieve me later.",
            authoritative: false,
            provenanceKind: .checkpoint,
            provenanceReference: "checkpoint:mission-1:cold-note"
        )
        let capsule = try ProjectCapsuleBuilder.build(
            authority: authority(),
            items: [note],
            budgetBytes: 0
        )
        let encoded = try JSONEncoder().encode(capsule)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var omitted = try XCTUnwrap(json["omittedItems"] as? [[String: Any]])
        var provenance = try XCTUnwrap(omitted[0]["provenance"] as? [String: Any])
        provenance["reference"] = " checkpoint:mission-1:cold-note"
        omitted[0]["provenance"] = provenance
        json["omittedItems"] = omitted
        let tampered = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try JSONDecoder().decode(ProjectCapsule.self, from: tampered))
    }

    func testOpaqueIdentifiersRejectWhitespaceAliases() throws {
        XCTAssertThrowsError(
            try ProjectCapsuleAuthority(
                projectID: " project-1",
                missionID: "mission-1",
                sourceRevision: "src-1",
                missionRevision: 1,
                authorityEpoch: 1,
                capsuleRevision: 1
            )
        )
        XCTAssertThrowsError(
            try ForgeCompactProvenance(kind: .source, reference: "ref-1 ")
        )
        XCTAssertThrowsError(
            try item(
                id: " item-1",
                tier: .l2ProjectMemory,
                kind: .workingNote,
                content: "note",
                authoritative: false
            )
        )
    }

    func testCapsuleSchemaBumpsForDeferredRetrievalMetadata() throws {
        let note = try item(
            id: "note",
            tier: .l3ColdArchive,
            kind: .workingNote,
            content: "note",
            authoritative: false
        )
        let capsule = try ProjectCapsuleBuilder.build(
            authority: authority(),
            items: [note],
            budgetBytes: 0
        )
        XCTAssertEqual(capsule.schemaVersion, 2)

        let encoded = try JSONEncoder().encode(capsule)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["schemaVersion"] = 1
        let legacyShape = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(ProjectCapsule.self, from: legacyShape))
    }

    func testCheckedAccountingFailsClosedOnIntegerOverflow() {
        XCTAssertThrowsError(try ProjectCapsule.checkedAdd(Int.max, 1)) { error in
            XCTAssertEqual(error as? ForgeCompactError, .accountingOverflow)
        }
        XCTAssertNoThrow(try ProjectCapsule.checkedAdd(Int.max - 1, 1))
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
        content: String,
        authoritative: Bool = true,
        provenanceKind: ForgeCompactProvenanceKind = .source,
        provenanceReference: String? = nil,
        protectedByUser: Bool = false
    ) throws -> ForgeCompactContextItem {
        try ForgeCompactContextItem(
            id: id,
            sourceRevision: "src-1",
            tier: tier,
            kind: kind,
            priority: 50,
            content: content,
            provenance: ForgeCompactProvenance(
                kind: provenanceKind,
                reference: provenanceReference ?? "ref-\(id)"
            ),
            isAuthoritative: authoritative,
            freshness: .current,
            protectedByUser: protectedByUser
        )
    }
}

import Foundation
import XCTest
@testable import ForgeCompactCore

final class ForgeCompactDeferredRetrievalTests: XCTestCase {
    func testDesignDNACannotBeBudgetDropped() throws {
        let designDNA = try item(
            id: "design-dna",
            kind: .designDNA,
            content: "Preserve the accepted calm, precise visual identity."
        )

        XCTAssertTrue(designDNA.mustRetain)
        XCTAssertThrowsError(
            try ProjectCapsuleBuilder.build(
                authority: authority(),
                items: [designDNA],
                budgetBytes: 0
            )
        )
    }

    func testDeferredContextPreservesRetrievalProvenance() throws {
        let note = try item(
            id: "cold-note",
            kind: .workingNote,
            content: "A cold fact that should be retrieved only when relevant.",
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

    func testDeferredRetrievalProvenanceRevalidatesOnDecode() throws {
        let note = try item(
            id: "cold-note",
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
        provenance["reference"] = ""
        omitted[0]["provenance"] = provenance
        json["omittedItems"] = omitted
        let tampered = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try JSONDecoder().decode(ProjectCapsule.self, from: tampered))
    }

    func testRetrievalMetadataRequiresCapsuleSchemaV2() throws {
        let note = try item(
            id: "cold-note",
            kind: .workingNote,
            content: "Retrieve me later.",
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
        let staleSchema = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try JSONDecoder().decode(ProjectCapsule.self, from: staleSchema))
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
        kind: ForgeCompactFactKind,
        content: String,
        authoritative: Bool = true,
        provenanceKind: ForgeCompactProvenanceKind = .source,
        provenanceReference: String? = nil
    ) throws -> ForgeCompactContextItem {
        try ForgeCompactContextItem(
            id: id,
            sourceRevision: "src-1",
            tier: .l3ColdArchive,
            kind: kind,
            priority: 50,
            content: content,
            provenance: ForgeCompactProvenance(
                kind: provenanceKind,
                reference: provenanceReference ?? "ref-\(id)"
            ),
            isAuthoritative: authoritative,
            freshness: .current,
            protectedByUser: false
        )
    }
}

import Testing
@testable import ForgeCompactCore

private func hardeningAuthority() throws -> ProjectCapsuleAuthority {
    try ProjectCapsuleAuthority(
        projectID: "project-1",
        missionID: "mission-1",
        sourceRevision: "src-1",
        missionRevision: 3,
        authorityEpoch: 2,
        capsuleRevision: 1
    )
}

private func hardeningItem(
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

@Test func acceptedDecisionIsMandatoryWithoutUserProtection() throws {
    let decision = try hardeningItem(
        id: "accepted-direction",
        tier: .l2ProjectMemory,
        kind: .acceptedDecision,
        priority: 0,
        content: "Use a local-first runtime.",
        provenanceKind: .user
    )
    let optional = try hardeningItem(
        id: "optional",
        tier: .l1ActiveWorkingSet,
        kind: .workingNote,
        priority: 100,
        content: String(repeating: "optional ", count: 60),
        authoritative: false
    )
    let capsule = try ProjectCapsuleBuilder.build(
        authority: hardeningAuthority(),
        items: [optional, decision],
        budgetBytes: decision.renderedUTF8Bytes
    )

    #expect(capsule.selectedItems.map(\.id) == ["accepted-direction"])
}

@Test func modelSummaryCannotBecomeMandatoryThroughL0Tier() throws {
    #expect(throws: ForgeCompactError.self) {
        _ = try hardeningItem(
            id: "summary-l0",
            tier: .l0AlwaysResident,
            kind: .workingNote,
            priority: 100,
            content: "Model-generated note.",
            provenanceKind: .modelSummary,
            authoritative: false
        )
    }
}

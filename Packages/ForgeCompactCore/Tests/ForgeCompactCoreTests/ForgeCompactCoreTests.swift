import Foundation
import Testing
@testable import ForgeCompactCore

private func authority(
    sourceRevision: String = "src-1",
    missionRevision: Int = 3,
    authorityEpoch: Int = 2,
    capsuleRevision: Int = 1,
    projectID: String = "project-1",
    missionID: String = "mission-1"
) throws -> ProjectCapsuleAuthority {
    try ProjectCapsuleAuthority(
        projectID: projectID,
        missionID: missionID,
        sourceRevision: sourceRevision,
        missionRevision: missionRevision,
        authorityEpoch: authorityEpoch,
        capsuleRevision: capsuleRevision
    )
}

private func item(
    id: String,
    tier: ForgeCompactContextTier,
    kind: ForgeCompactFactKind,
    priority: Int,
    content: String,
    provenanceKind: ForgeCompactProvenanceKind = .source,
    authoritative: Bool = true,
    freshness: ForgeCompactFreshness = .current,
    protectedByUser: Bool = false,
    sourceRevision: String = "src-1"
) throws -> ForgeCompactContextItem {
    try ForgeCompactContextItem(
        id: id,
        sourceRevision: sourceRevision,
        tier: tier,
        kind: kind,
        priority: priority,
        content: content,
        provenance: ForgeCompactProvenance(kind: provenanceKind, reference: "ref-\(id)"),
        isAuthoritative: authoritative,
        freshness: freshness,
        protectedByUser: protectedByUser
    )
}

@Test func mandatoryTruthCannotBeDroppedForOptionalContext() throws {
    let critical = try item(
        id: "failed-test",
        tier: .l1ActiveWorkingSet,
        kind: .failingTest,
        priority: 1,
        content: "ForgeRuntime launch test is failing."
    )
    let objective = try item(
        id: "objective",
        tier: .l0AlwaysResident,
        kind: .currentObjective,
        priority: 100,
        content: "Repair the launch path."
    )
    let optional = try item(
        id: "old-note",
        tier: .l3ColdArchive,
        kind: .workingNote,
        priority: 100,
        content: String(repeating: "history ", count: 80),
        authoritative: false
    )
    let mandatoryBytes = [objective, critical].sorted { $0.tier.selectionRank < $1.tier.selectionRank }
        .map(\.renderedLine).joined(separator: "\n").utf8.count

    let capsule = try ProjectCapsuleBuilder.build(
        authority: authority(),
        items: [optional, critical, objective],
        budgetBytes: mandatoryBytes
    )

    #expect(capsule.selectedItems.map(\.id) == ["objective", "failed-test"])
    #expect(capsule.omittedItems.map(\.id) == ["old-note"])
    let omittedMandatoryTruth = capsule.omittedItems.contains { $0.mustRetain }
    #expect(!omittedMandatoryTruth)
}

@Test func insufficientBudgetFailsClosedInsteadOfErasingTruth() throws {
    let critical = try item(
        id: "privacy",
        tier: .l0AlwaysResident,
        kind: .privacyPolicy,
        priority: 100,
        content: "Local Only. Hosted inference is forbidden."
    )

    #expect(throws: ForgeCompactError.self) {
        _ = try ProjectCapsuleBuilder.build(
            authority: authority(),
            items: [critical],
            budgetBytes: critical.renderedUTF8Bytes - 1
        )
    }
}

@Test func selectionIsDeterministicAcrossInputOrdering() throws {
    let values = try [
        item(id: "l2-low", tier: .l2ProjectMemory, kind: .workingNote, priority: 10, content: "low", authoritative: false),
        item(id: "l1-mid", tier: .l1ActiveWorkingSet, kind: .sourceLocation, priority: 50, content: "mid"),
        item(id: "l1-high", tier: .l1ActiveWorkingSet, kind: .sourceLocation, priority: 90, content: "high"),
        item(id: "l0", tier: .l0AlwaysResident, kind: .missionIdentity, priority: 1, content: "mission"),
    ]
    let fullBudget = values.map(\.renderedLine).joined(separator: "\n").utf8.count

    let a = try ProjectCapsuleBuilder.build(authority: authority(), items: values, budgetBytes: fullBudget)
    let b = try ProjectCapsuleBuilder.build(authority: authority(), items: values.reversed(), budgetBytes: fullBudget)

    #expect(a.selectedItems.map(\.id) == ["l0", "l1-high", "l1-mid", "l2-low"])
    #expect(a == b)
}

@Test func modelSummaryCannotMintAuthoritativeProjectTruth() throws {
    #expect(throws: ForgeCompactError.self) {
        _ = try item(
            id: "summary",
            tier: .l2ProjectMemory,
            kind: .workingNote,
            priority: 50,
            content: "The model thinks everything passed.",
            provenanceKind: .modelSummary,
            authoritative: true
        )
    }
}

@Test func modelSummaryCannotSupplyMandatoryStructuredTruth() throws {
    #expect(throws: ForgeCompactError.self) {
        _ = try item(
            id: "summary-requirement",
            tier: .l2ProjectMemory,
            kind: .acceptedRequirement,
            priority: 50,
            content: "The model summarized a requirement without an accepted source.",
            provenanceKind: .modelSummary,
            authoritative: false
        )
    }
}

@Test func staleMandatoryTruthIsRejectedAtIngress() throws {
    #expect(throws: ForgeCompactError.self) {
        _ = try item(
            id: "decision",
            tier: .l1ActiveWorkingSet,
            kind: .unresolvedDecision,
            priority: 70,
            content: "Choose portrait or landscape.",
            freshness: .stale
        )
    }
}

@Test func sourceRevisionMismatchFailsClosed() throws {
    let staleSource = try item(
        id: "source",
        tier: .l1ActiveWorkingSet,
        kind: .sourceLocation,
        priority: 80,
        content: "AgentPad/AppRoot.swift",
        sourceRevision: "src-old"
    )

    #expect(throws: ForgeCompactError.self) {
        _ = try ProjectCapsuleBuilder.build(
            authority: authority(sourceRevision: "src-new"),
            items: [staleSource],
            budgetBytes: 8_000
        )
    }
}

@Test func protectedUserDecisionIsRetainedEvenAtLowPriority() throws {
    let protected = try item(
        id: "design-choice",
        tier: .l2ProjectMemory,
        kind: .acceptedDecision,
        priority: 0,
        content: "Keep the compact composer layout.",
        provenanceKind: .user,
        protectedByUser: true
    )
    let optional = try item(
        id: "optional",
        tier: .l1ActiveWorkingSet,
        kind: .workingNote,
        priority: 100,
        content: String(repeating: "optional ", count: 60),
        authoritative: false
    )

    let capsule = try ProjectCapsuleBuilder.build(
        authority: authority(),
        items: [optional, protected],
        budgetBytes: protected.renderedUTF8Bytes
    )
    #expect(capsule.selectedItems.map(\.id) == ["design-choice"])
}

@Test func capsuleDecodeRevalidatesOmittedMandatoryTruth() throws {
    let optional = try item(
        id: "note",
        tier: .l2ProjectMemory,
        kind: .workingNote,
        priority: 10,
        content: "Optional note.",
        authoritative: false
    )
    let capsule = try ProjectCapsuleBuilder.build(authority: authority(), items: [optional], budgetBytes: 0)
    let encoded = try JSONEncoder().encode(capsule)
    var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var omitted = try #require(json["omittedItems"] as? [[String: Any]])
    omitted[0]["mustRetain"] = true
    json["omittedItems"] = omitted
    let tampered = try JSONSerialization.data(withJSONObject: json)

    #expect(throws: ForgeCompactError.self) {
        _ = try JSONDecoder().decode(ProjectCapsule.self, from: tampered)
    }
}

@Test func cacheReuseRequiresExactRuntimeModelTemplateToolAndCapsuleIdentity() throws {
    let base = try ForgeCompactCacheIdentity(
        modelID: "Qwen-small",
        modelRevision: "r1",
        tokenizerRevision: "tok-1",
        runtimeID: "llama.cpp",
        runtimeRevision: "abc123",
        promptTemplateRevision: "tmpl-2",
        toolSchemaRevision: "tools-7",
        projectID: "project-1",
        sourceRevision: "src-1",
        capsuleRevision: 4
    )
    let same = try ForgeCompactCacheIdentity(
        modelID: "Qwen-small",
        modelRevision: "r1",
        tokenizerRevision: "tok-1",
        runtimeID: "llama.cpp",
        runtimeRevision: "abc123",
        promptTemplateRevision: "tmpl-2",
        toolSchemaRevision: "tools-7",
        projectID: "project-1",
        sourceRevision: "src-1",
        capsuleRevision: 4
    )
    let changedTokenizer = try ForgeCompactCacheIdentity(
        modelID: "Qwen-small",
        modelRevision: "r1",
        tokenizerRevision: "tok-2",
        runtimeID: "llama.cpp",
        runtimeRevision: "abc123",
        promptTemplateRevision: "tmpl-2",
        toolSchemaRevision: "tools-7",
        projectID: "project-1",
        sourceRevision: "src-1",
        capsuleRevision: 4
    )

    #expect(base.canReusePrefixOrKV(with: same))
    #expect(!base.canReusePrefixOrKV(with: changedTokenizer))
}

@Test func archiveRejectsCrossProjectCapsules() throws {
    let note = try item(
        id: "note",
        tier: .l1ActiveWorkingSet,
        kind: .workingNote,
        priority: 20,
        content: "Current work.",
        authoritative: false
    )
    let otherAuthority = try authority(projectID: "project-2")
    let capsule = try ProjectCapsuleBuilder.build(authority: otherAuthority, items: [note], budgetBytes: 1_000)

    #expect(throws: ForgeCompactError.self) {
        _ = try ProjectCapsuleArchive(projectID: "project-1", missionID: "mission-1", capsules: [capsule])
    }
}

@Test func archiveRequiresMonotonicCapsuleMissionAndAuthorityRevisions() throws {
    let note = try item(
        id: "note",
        tier: .l1ActiveWorkingSet,
        kind: .workingNote,
        priority: 20,
        content: "Current work.",
        authoritative: false
    )
    let first = try ProjectCapsuleBuilder.build(
        authority: authority(missionRevision: 4, authorityEpoch: 3, capsuleRevision: 2),
        items: [note],
        budgetBytes: 1_000
    )
    let regressed = try ProjectCapsuleBuilder.build(
        authority: authority(missionRevision: 3, authorityEpoch: 3, capsuleRevision: 3),
        items: [note],
        budgetBytes: 1_000
    )

    #expect(throws: ForgeCompactError.self) {
        _ = try ProjectCapsuleArchive(projectID: "project-1", missionID: "mission-1", capsules: [first, regressed])
    }
}

@Test func capsuleDecodeRejectsNonCanonicalSelectedOrdering() throws {
    let first = try item(
        id: "high",
        tier: .l1ActiveWorkingSet,
        kind: .sourceLocation,
        priority: 90,
        content: "high"
    )
    let second = try item(
        id: "low",
        tier: .l1ActiveWorkingSet,
        kind: .sourceLocation,
        priority: 10,
        content: "low"
    )
    let capsule = try ProjectCapsuleBuilder.build(
        authority: authority(),
        items: [first, second],
        budgetBytes: 8_000
    )
    let data = try JSONEncoder().encode(capsule)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let selected = try #require(object["selectedItems"] as? [[String: Any]])
    let reversed = Array(selected.reversed())
    object["selectedItems"] = reversed
    object["renderedContext"] = [second.renderedLine, first.renderedLine].joined(separator: "\n")
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeCompactError.self) {
        _ = try JSONDecoder().decode(ProjectCapsule.self, from: tampered)
    }
}

@Test func archiveRejectsInvalidIdentityCharacters() throws {
    #expect(throws: ForgeCompactError.self) {
        _ = try ProjectCapsuleArchive(projectID: "project\nspoof", missionID: "mission", capsules: [])
    }
}

@Test func roundTripPreservesDeterministicRenderedBytes() throws {
    let values = try [
        item(id: "objective", tier: .l0AlwaysResident, kind: .currentObjective, priority: 100, content: "Build Forge Compact."),
        item(id: "file", tier: .l1ActiveWorkingSet, kind: .sourceLocation, priority: 80, content: "Packages/ForgeCompactCore"),
        item(id: "note", tier: .l2ProjectMemory, kind: .workingNote, priority: 20, content: "Do not replay raw chat.", authoritative: false),
    ]
    let capsule = try ProjectCapsuleBuilder.build(authority: authority(), items: values, budgetBytes: 4_000)
    let encoded = try JSONEncoder().encode(capsule)
    let decoded = try JSONDecoder().decode(ProjectCapsule.self, from: encoded)

    #expect(decoded == capsule)
    #expect(decoded.renderedUTF8Bytes == decoded.renderedContext.utf8.count)
    #expect(decoded.renderedUTF8Bytes <= decoded.budgetBytes)
}

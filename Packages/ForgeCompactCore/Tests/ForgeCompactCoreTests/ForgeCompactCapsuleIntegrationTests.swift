import Foundation
import XCTest
@testable import ForgeCompactCore

final class ForgeCompactCapsuleIntegrationTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testMandatoryTruthCannotBeDroppedForOptionalContext() throws {
        let objective = try item(
            id: "objective",
            tier: .l0AlwaysResident,
            kind: .currentObjective,
            priority: 100,
            content: "Repair the launch path."
        )
        let failing = try item(
            id: "failing-test",
            tier: .l1ActiveWorkingSet,
            kind: .failingTest,
            priority: 1,
            content: "Runtime launch still fails."
        )
        let optional = try item(
            id: "old-note",
            tier: .l3ColdArchive,
            kind: .workingNote,
            priority: 100,
            content: String(repeating: "history ", count: 80),
            authoritative: false
        )
        let mandatoryBytes = [objective, failing]
            .sorted { $0.tier.selectionRank < $1.tier.selectionRank }
            .map(\.renderedLine)
            .joined(separator: "\n")
            .utf8.count

        let capsule = try ProjectCapsuleBuilder.build(
            authority: authority(),
            items: [optional, failing, objective],
            budgetBytes: mandatoryBytes
        )

        XCTAssertEqual(capsule.selectedItems.map(\.id), ["objective", "failing-test"])
        XCTAssertEqual(capsule.omittedItems.map(\.id), ["old-note"])
        XCTAssertFalse(capsule.omittedItems.contains(where: \.mustRetain))
    }

    func testInsufficientBudgetFailsClosed() throws {
        let privacy = try item(
            id: "privacy",
            tier: .l0AlwaysResident,
            kind: .privacyPolicy,
            priority: 100,
            content: "Local Only. Hosted inference is forbidden."
        )

        XCTAssertThrowsError(
            try ProjectCapsuleBuilder.build(
                authority: authority(),
                items: [privacy],
                budgetBytes: privacy.renderedUTF8Bytes - 1
            )
        )
    }

    func testModelSummaryCannotMintAuthoritativeOrMandatoryTruth() throws {
        XCTAssertThrowsError(
            try item(
                id: "summary",
                tier: .l2ProjectMemory,
                kind: .workingNote,
                priority: 50,
                content: "Everything passed.",
                provenanceKind: .modelSummary,
                authoritative: true
            )
        )
        XCTAssertThrowsError(
            try item(
                id: "summary-requirement",
                tier: .l2ProjectMemory,
                kind: .acceptedRequirement,
                priority: 50,
                content: "Unaccepted summary.",
                provenanceKind: .modelSummary,
                authoritative: false
            )
        )
    }

    func testStaleMandatoryTruthAndSourceRevisionDriftFailClosed() throws {
        XCTAssertThrowsError(
            try item(
                id: "decision",
                tier: .l1ActiveWorkingSet,
                kind: .unresolvedDecision,
                priority: 70,
                content: "Choose orientation.",
                freshness: .stale
            )
        )

        let staleSource = try item(
            id: "source",
            tier: .l1ActiveWorkingSet,
            kind: .sourceLocation,
            priority: 80,
            content: "AgentPad/AppRoot.swift",
            sourceRevision: "src-old"
        )
        XCTAssertThrowsError(
            try ProjectCapsuleBuilder.build(
                authority: authority(sourceRevision: "src-new"),
                items: [staleSource],
                budgetBytes: 8_000
            )
        )
    }

    func testProtectedUserDecisionSurvivesBudgetPressure() throws {
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
        XCTAssertEqual(capsule.selectedItems.map(\.id), ["design-choice"])
    }

    func testCapsuleDecodeRejectsOmittedMandatoryTruthTampering() throws {
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
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var omitted = try XCTUnwrap(json["omittedItems"] as? [[String: Any]])
        omitted[0]["kind"] = ForgeCompactFactKind.acceptedRequirement.rawValue
        json["omittedItems"] = omitted
        let tampered = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try JSONDecoder().decode(ProjectCapsule.self, from: tampered))
    }

    func testCapsuleDecodeRejectsOmittedSourceRevisionTampering() throws {
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
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var omitted = try XCTUnwrap(json["omittedItems"] as? [[String: Any]])
        omitted[0]["sourceRevision"] = "src-other"
        json["omittedItems"] = omitted
        let tampered = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try JSONDecoder().decode(ProjectCapsule.self, from: tampered))
    }

    func testArchiveRejectsCrossProjectAndRevisionRegression() throws {
        let note = try item(
            id: "note",
            tier: .l1ActiveWorkingSet,
            kind: .workingNote,
            priority: 20,
            content: "Current work.",
            authoritative: false
        )
        let wrongProject = try ProjectCapsuleBuilder.build(
            authority: authority(projectID: "project-2"),
            items: [note],
            budgetBytes: 1_000
        )
        XCTAssertThrowsError(
            try ProjectCapsuleArchive(projectID: "project-1", missionID: "mission-1", capsules: [wrongProject])
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
        XCTAssertThrowsError(
            try ProjectCapsuleArchive(projectID: "project-1", missionID: "mission-1", capsules: [first, regressed])
        )
    }

    func testCacheReuseRequiresExactStablePrefixAndMemoryProfile() throws {
        let base = try cacheIdentity()
        XCTAssertTrue(base.canReusePrefixOrKV(with: try cacheIdentity()))
        XCTAssertFalse(base.canReusePrefixOrKV(with: try cacheIdentity(weightProfileID: "Q5_K_M")))
        XCTAssertFalse(base.canReusePrefixOrKV(with: try cacheIdentity(keyCacheType: "q4_0")))
        XCTAssertFalse(base.canReusePrefixOrKV(with: try cacheIdentity(valueCacheType: "q4_0")))
        XCTAssertFalse(base.canReusePrefixOrKV(with: try cacheIdentity(contextCapacityTokens: 16_384)))
        XCTAssertFalse(base.canReusePrefixOrKV(with: try cacheIdentity(backendProfileID: "cpu")))
        XCTAssertFalse(base.canReusePrefixOrKV(with: try cacheIdentity(stablePrefixSHA256: String(repeating: "b", count: 64))))
    }

    func testCacheReuseInvalidatesOnTokenizerRuntimeToolAndCapsuleAuthorityDrift() throws {
        let base = try cacheIdentity()
        XCTAssertFalse(base.canReusePrefixOrKV(with: try cacheIdentity(tokenizerRevision: "tok-r2")))
        XCTAssertFalse(base.canReusePrefixOrKV(with: try cacheIdentity(runtimeRevision: "runtime-r2")))
        XCTAssertFalse(base.canReusePrefixOrKV(with: try cacheIdentity(toolSchemaRevision: "tools-r2")))
        XCTAssertFalse(base.canReusePrefixOrKV(with: try cacheIdentity(sourceRevision: "src-2")))
        XCTAssertFalse(base.canReusePrefixOrKV(with: try cacheIdentity(missionRevision: 4)))
        XCTAssertFalse(base.canReusePrefixOrKV(with: try cacheIdentity(authorityEpoch: 3)))
        XCTAssertFalse(base.canReusePrefixOrKV(with: try cacheIdentity(capsuleRevision: 2)))
    }

    func testCacheIdentityRejectsNonCanonicalIdentityAndDigest() throws {
        XCTAssertThrowsError(try cacheIdentity(modelID: " model "))
        XCTAssertThrowsError(try cacheIdentity(stablePrefixSHA256: "not-a-digest"))
        XCTAssertThrowsError(try cacheIdentity(contextCapacityTokens: 0))
    }

    func testCacheIdentityDecodeReentersValidation() throws {
        let valid = try cacheIdentity()
        let data = try JSONEncoder().encode(valid)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["stablePrefixSHA256"] = "BAD"
        let tampered = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCompactCacheIdentity.self, from: tampered))
    }

    func testCapsuleAndArchiveRoundTripPreserveDeterministicBytes() throws {
        let values = try [
            item(id: "objective", tier: .l0AlwaysResident, kind: .currentObjective, priority: 100, content: "Build Forge Compact."),
            item(id: "file", tier: .l1ActiveWorkingSet, kind: .sourceLocation, priority: 80, content: "Packages/ForgeCompactCore"),
            item(id: "note", tier: .l2ProjectMemory, kind: .workingNote, priority: 20, content: "Do not replay raw chat.", authoritative: false),
        ]
        let capsule = try ProjectCapsuleBuilder.build(authority: authority(), items: values, budgetBytes: 4_000)
        let archive = try ProjectCapsuleArchive(projectID: "project-1", missionID: "mission-1", capsules: [capsule])
        let decodedCapsule = try JSONDecoder().decode(ProjectCapsule.self, from: JSONEncoder().encode(capsule))
        let decodedArchive = try JSONDecoder().decode(ProjectCapsuleArchive.self, from: JSONEncoder().encode(archive))

        XCTAssertEqual(decodedCapsule, capsule)
        XCTAssertEqual(decodedArchive, archive)
        XCTAssertEqual(decodedCapsule.renderedUTF8Bytes, decodedCapsule.renderedContext.utf8.count)
        XCTAssertLessThanOrEqual(decodedCapsule.renderedUTF8Bytes, decodedCapsule.budgetBytes)
    }

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

    private func cacheIdentity(
        modelID: String = "Qwen-small",
        tokenizerRevision: String = "tok-r1",
        runtimeRevision: String = "runtime-r1",
        backendProfileID: String = "metal",
        weightProfileID: String = "Q4_K_M",
        keyCacheType: String = "q8_0",
        valueCacheType: String = "q8_0",
        contextCapacityTokens: UInt64 = 8_192,
        toolSchemaRevision: String = "tools-r1",
        sourceRevision: String = "src-1",
        missionRevision: Int = 3,
        authorityEpoch: Int = 2,
        capsuleRevision: Int = 1,
        stablePrefixSHA256: String? = nil
    ) throws -> ForgeCompactCacheIdentity {
        try ForgeCompactCacheIdentity(
            modelID: modelID,
            modelRevision: "model-r1",
            tokenizerID: "tokenizer",
            tokenizerRevision: tokenizerRevision,
            runtimeID: "llama.cpp",
            runtimeRevision: runtimeRevision,
            backendProfileID: backendProfileID,
            weightProfileID: weightProfileID,
            keyCacheType: keyCacheType,
            valueCacheType: valueCacheType,
            contextCapacityTokens: contextCapacityTokens,
            promptTemplateRevision: "prompt-r1",
            toolSchemaRevision: toolSchemaRevision,
            projectID: "project-1",
            sourceRevision: sourceRevision,
            missionRevision: missionRevision,
            authorityEpoch: authorityEpoch,
            capsuleRevision: capsuleRevision,
            stablePrefixSHA256: stablePrefixSHA256 ?? digest
        )
    }
}

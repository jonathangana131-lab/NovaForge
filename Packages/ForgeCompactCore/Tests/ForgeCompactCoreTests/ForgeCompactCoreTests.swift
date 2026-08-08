import XCTest
@testable import ForgeCompactCore

final class ForgeCompactCoreTests: XCTestCase {
    private func binding(sourceRevision: String = "src-9") throws -> ForgeCompactProjectBinding {
        try ForgeCompactProjectBinding(
            projectID: "project-A",
            missionID: "mission-A",
            acceptedProjectStateID: "state-42",
            sourceRevision: sourceRevision,
            missionRevision: 7,
            constitutionRevision: 3,
            graphRevision: 11,
            authorityEpoch: 5
        )
    }

    private func prefix(
        modelRevision: String = "model-r3",
        kvCacheProfile: String = "q8_0"
    ) throws -> ForgeCompactPrefixReuseIdentity {
        try ForgeCompactPrefixReuseIdentity(
            modelID: "local-model",
            modelRevision: modelRevision,
            tokenizerID: "tokenizer",
            tokenizerRevision: "tok-r2",
            runtimeID: "llama.cpp",
            runtimeRevision: "runtime-r8",
            promptTemplateRevision: "template-r4",
            toolSchemaRevision: "tools-r6",
            quantizationProfile: "Q4_K_M",
            kvCacheProfile: kvCacheProfile,
            contextPolicyRevision: "context-r2"
        )
    }

    private func record(
        _ id: String,
        kind: ForgeCompactRecordKind,
        tier: ForgeCompactContextTier = .projectMemory,
        priority: UInt8 = 128,
        summary: String? = nil
    ) throws -> ForgeCompactRecord {
        try ForgeCompactRecord(
            id: id,
            kind: kind,
            tier: tier,
            provenance: .acceptedCheckpoint,
            sourceRevision: "src-9",
            retrievalKey: "brain://\(id)",
            summary: summary ?? "Accepted \(id)",
            priority: priority
        )
    }

    private func generousBudget(maxIncluded: Int = 64) throws -> ForgeCompactBudget {
        try ForgeCompactBudget(
            maximumCapsuleBytes: 128 * 1_024,
            maximumIncludedRecords: maxIncluded,
            maximumSourceRecords: 128
        )
    }

    func testCanonicalBytesDoNotDependOnInputOrdering() throws {
        let records = [
            try record("req", kind: .acceptedRequirement, tier: .alwaysResident),
            try record("decision", kind: .acceptedDecision, tier: .projectMemory),
            try record("file", kind: .relevantFile, tier: .activeWorkingSet, priority: 200),
            try record("symbol", kind: .relevantSymbol, tier: .activeWorkingSet, priority: 180),
        ]

        let first = try ForgeProjectCapsuleBuilder.build(
            capsuleRevision: 2,
            binding: binding(),
            records: records,
            budget: generousBudget()
        )
        let second = try ForgeProjectCapsuleBuilder.build(
            capsuleRevision: 2,
            binding: binding(),
            records: records.reversed(),
            budget: generousBudget()
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(try first.canonicalJSONData(), try second.canonicalJSONData())
    }

    func testCriticalTruthCannotBeSilentlyDeferred() throws {
        let criticalKinds: [ForgeCompactRecordKind] = [
            .acceptedRequirement,
            .acceptedDecision,
            .unresolvedDecision,
            .failingCheck,
            .privacyConstraint,
            .securityConstraint,
            .knownLimitation,
            .acceptedEvidenceReceipt,
            .protectedDesignRule,
        ]
        let records = try criticalKinds.enumerated().map { index, kind in
            try record("critical-\(index)", kind: kind, tier: .projectMemory)
        }

        XCTAssertThrowsError(
            try ForgeProjectCapsuleBuilder.build(
                capsuleRevision: 1,
                binding: binding(),
                records: records,
                budget: generousBudget(maxIncluded: records.count - 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .mandatoryTruthExceedsRecordBudget(actual: records.count, maximum: records.count - 1)
            )
        }
    }

    func testOptionalContextIsDeferredWithRetrievalKeyInsteadOfForgotten() throws {
        let required = try record("requirement", kind: .acceptedRequirement, tier: .alwaysResident)
        let high = try record("high", kind: .relevantSymbol, tier: .activeWorkingSet, priority: 250)
        let low = try record("low", kind: .priorAcceptedCheckpoint, tier: .projectMemory, priority: 1)

        let capsule = try ForgeProjectCapsuleBuilder.build(
            capsuleRevision: 3,
            binding: binding(),
            records: [low, required, high],
            budget: generousBudget(maxIncluded: 2)
        )

        XCTAssertEqual(Set(capsule.includedRecords.map(\.id)), ["requirement", "high"])
        XCTAssertEqual(capsule.deferredReferences.map(\.recordID), ["low"])
        XCTAssertEqual(capsule.deferredReferences.first?.retrievalKey, "brain://low")
    }

    func testDuplicateRecordIdentityFailsClosed() throws {
        let duplicateA = try record("same", kind: .relevantFile)
        let duplicateB = try record("same", kind: .relevantSymbol)

        XCTAssertThrowsError(
            try ForgeProjectCapsuleBuilder.build(
                capsuleRevision: 1,
                binding: binding(),
                records: [duplicateA, duplicateB],
                budget: generousBudget()
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .duplicateRecordID("same"))
        }
    }

    func testMandatoryTruthMayNotBePlacedOnlyInColdArchive() throws {
        XCTAssertThrowsError(
            try record("privacy", kind: .privacyConstraint, tier: .coldArchive)
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .invalidTierForMandatoryRecord("privacy"))
        }
    }

    func testResumeRejectsSourceAndMissionAuthorityDrift() throws {
        let capsule = try ForgeProjectCapsuleBuilder.build(
            capsuleRevision: 1,
            binding: binding(),
            records: [try record("req", kind: .acceptedRequirement)],
            budget: generousBudget()
        )

        XCTAssertThrowsError(
            try capsule.validateReuse(expectedBinding: binding(sourceRevision: "src-10"))
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .sourceRevisionMismatch)
        }

        let otherMission = try ForgeCompactProjectBinding(
            projectID: "project-A",
            missionID: "mission-B",
            acceptedProjectStateID: "state-42",
            sourceRevision: "src-9",
            missionRevision: 7,
            constitutionRevision: 3,
            graphRevision: 11,
            authorityEpoch: 5
        )
        XCTAssertThrowsError(
            try capsule.validateReuse(expectedBinding: otherMission)
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .missionBindingMismatch)
        }
    }

    func testCapsuleSurvivesModelHotSwapWhilePrefixArtifactInvalidates() throws {
        let capsule = try ForgeProjectCapsuleBuilder.build(
            capsuleRevision: 1,
            binding: binding(),
            records: [try record("req", kind: .acceptedRequirement)],
            budget: generousBudget()
        )

        // Capsule truth is model-agnostic and remains valid across a worker/model switch.
        XCTAssertNoThrow(try capsule.validateReuse(expectedBinding: binding()))

        let artifact = try ForgeCompactPrefixArtifactBinding(
            stablePrefixDigest: "sha256:prefix-A",
            capsuleRevision: capsule.capsuleRevision,
            projectBinding: capsule.binding,
            reuseIdentity: prefix()
        )
        XCTAssertNoThrow(
            try artifact.validateReuse(
                expectedStablePrefixDigest: "sha256:prefix-A",
                expectedCapsule: capsule,
                expectedReuseIdentity: prefix()
            )
        )

        XCTAssertThrowsError(
            try artifact.validateReuse(
                expectedStablePrefixDigest: "sha256:prefix-A",
                expectedCapsule: capsule,
                expectedReuseIdentity: prefix(modelRevision: "model-r4")
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .prefixReuseIdentityMismatch)
        }

        XCTAssertThrowsError(
            try artifact.validateReuse(
                expectedStablePrefixDigest: "sha256:prefix-B",
                expectedCapsule: capsule,
                expectedReuseIdentity: prefix()
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .stablePrefixDigestMismatch)
        }

        let advancedCapsule = try ForgeProjectCapsuleBuilder.build(
            capsuleRevision: 2,
            binding: binding(),
            records: [try record("req", kind: .acceptedRequirement)],
            budget: generousBudget()
        )
        XCTAssertThrowsError(
            try artifact.validateReuse(
                expectedStablePrefixDigest: "sha256:prefix-A",
                expectedCapsule: advancedCapsule,
                expectedReuseIdentity: prefix()
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .prefixCapsuleRevisionMismatch)
        }
    }

    func testCapsuleDecodeRevalidatesSchemaAndAcceptedProvenance() throws {
        let capsule = try ForgeProjectCapsuleBuilder.build(
            capsuleRevision: 1,
            binding: binding(),
            records: [try record("req", kind: .acceptedRequirement)],
            budget: generousBudget()
        )
        let original = try capsule.canonicalJSONData()
        XCTAssertEqual(try JSONDecoder().decode(ForgeProjectCapsule.self, from: original), capsule)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        json["schemaVersion"] = 99
        let futureSchema = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeProjectCapsule.self, from: futureSchema)) { error in
            XCTAssertEqual(error as? ForgeCompactError, .invalidSchemaVersion(99))
        }

        json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var records = try XCTUnwrap(json["includedRecords"] as? [[String: Any]])
        records[0]["provenance"] = "modelGenerated"
        json["includedRecords"] = records
        let modelAuthored = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeProjectCapsule.self, from: modelAuthored))
    }

    func testByteBudgetFailsClosedWhenEvenRetrievalSkeletonCannotFit() throws {
        let records = [
            try record("req", kind: .acceptedRequirement, summary: String(repeating: "x", count: 500)),
            try record("file", kind: .relevantFile, priority: 200),
        ]
        let tinyBudget = try ForgeCompactBudget(
            maximumCapsuleBytes: 64,
            maximumIncludedRecords: 2,
            maximumSourceRecords: 8
        )

        XCTAssertThrowsError(
            try ForgeProjectCapsuleBuilder.build(
                capsuleRevision: 1,
                binding: binding(),
                records: records,
                budget: tinyBudget
            )
        ) { error in
            guard case let ForgeCompactError.capsuleSkeletonExceedsByteBudget(actual, maximum) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, 64)
        }
    }

    func testBuilderRejectsStaleRecordUnderCurrentCapsuleBinding() throws {
        let stale = try ForgeCompactRecord(
            id: "stale-file",
            kind: .relevantFile,
            tier: .activeWorkingSet,
            provenance: .acceptedSource,
            sourceRevision: "src-8",
            retrievalKey: "brain://stale-file",
            summary: "Old source fact"
        )

        XCTAssertThrowsError(
            try ForgeProjectCapsuleBuilder.build(
                capsuleRevision: 1,
                binding: binding(),
                records: [stale],
                budget: generousBudget()
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .deferredSourceRevisionMismatch("stale-file"))
        }
    }

    func testDecodeRejectsForgedMandatoryDeferredReference() throws {
        let capsule = try ForgeProjectCapsuleBuilder.build(
            capsuleRevision: 1,
            binding: binding(),
            records: [try record("file", kind: .relevantFile)],
            budget: generousBudget(maxIncluded: 1)
        )
        let original = try capsule.canonicalJSONData()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var included = try XCTUnwrap(json["includedRecords"] as? [[String: Any]])
        var forged = included.removeFirst()
        forged["recordID"] = forged.removeValue(forKey: "id")
        forged["kind"] = ForgeCompactRecordKind.privacyConstraint.rawValue
        forged.removeValue(forKey: "provenance")
        forged.removeValue(forKey: "summary")
        forged.removeValue(forKey: "priority")
        json["includedRecords"] = included
        json["deferredReferences"] = [forged]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeProjectCapsule.self, from: data)) { error in
            XCTAssertEqual(error as? ForgeCompactError, .mandatoryRecordDeferred("file"))
        }
    }

}

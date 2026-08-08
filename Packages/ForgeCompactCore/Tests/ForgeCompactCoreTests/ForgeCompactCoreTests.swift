import XCTest
@testable import ForgeCompactCore

final class ForgeCompactCoreTests: XCTestCase {
    private func fact(
        _ id: String,
        kind: CapsuleFactKind,
        tier: ContextTier,
        priority: CapsuleFactPriority = .normal,
        tokens: Int = 20,
        text: String? = nil,
        provenance: CapsuleFactProvenance = .checkpoint(reference: "checkpoint-1")
    ) throws -> CapsuleFact {
        try CapsuleFact(
            id: id,
            kind: kind,
            tier: tier,
            priority: priority,
            text: text ?? "fact \(id)",
            estimatedTokenCost: tokens,
            provenance: provenance
        )
    }

    private func requiredFacts(objectiveTokens: Int = 20) throws -> [CapsuleFact] {
        [
            try fact("mission", kind: .missionIdentity, tier: .alwaysResident, priority: .critical, tokens: 10),
            try fact("objective", kind: .currentObjective, tier: .alwaysResident, priority: .critical, tokens: objectiveTokens),
            try fact("stage", kind: .currentStage, tier: .alwaysResident, priority: .critical, tokens: 10)
        ]
    }

    private func capsule(extraFacts: [CapsuleFact] = [], objectiveTokens: Int = 20) throws -> ProjectCapsule {
        try ProjectCapsule(
            projectID: "project-1",
            missionID: "mission-1",
            sourceRevision: "source-abc",
            capsuleRevision: 3,
            facts: requiredFacts(objectiveTokens: objectiveTokens) + extraFacts
        )
    }

    func testCapsuleCanonicalizesFactsAndRoundTrips() throws {
        let decision = try fact(
            "decision-b",
            kind: .acceptedDecision,
            tier: .projectMemory,
            priority: .high,
            provenance: .userDecision(reference: "decision-42")
        )
        let source = try fact(
            "source-a",
            kind: .sourceReference,
            tier: .activeWorkingSet,
            priority: .normal,
            provenance: .sourceRevision(reference: "file.swift@abc")
        )
        let original = try capsule(extraFacts: [decision, source])

        XCTAssertEqual(original.facts.map(\.id), ["mission", "objective", "stage", "source-a", "decision-b"])

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProjectCapsule.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testRequiredMissionFactCannotBeMovedOutOfL0() throws {
        XCTAssertThrowsError(
            try fact("objective", kind: .currentObjective, tier: .projectMemory)
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .invalidTier(kind: .currentObjective, expected: .alwaysResident))
        }
    }

    func testUnresolvedDecisionAndPrivacyStayAlwaysResident() throws {
        for kind in [CapsuleFactKind.unresolvedDecision, .privacyPolicy] {
            XCTAssertThrowsError(try fact("bad-\(kind.rawValue)", kind: kind, tier: .activeWorkingSet))
        }

        let privacy = try fact("privacy", kind: .privacyPolicy, tier: .alwaysResident, priority: .critical, tokens: 20)
        let decision = try fact("pending", kind: .unresolvedDecision, tier: .alwaysResident, priority: .critical, tokens: 20)
        let project = try capsule(extraFacts: [privacy, decision])
        let selection = try ForgeCompactSelector.select(
            from: project,
            budget: ContextBudget(maximumPromptTokens: 300, reservedOutputTokens: 100)
        )

        XCTAssertTrue(selection.selectedFacts.map(\.id).contains("privacy"))
        XCTAssertTrue(selection.selectedFacts.map(\.id).contains("pending"))
    }

    func testSelectorFailsClosedWhenMandatoryTruthExceedsBudget() throws {
        let project = try capsule(objectiveTokens: 250)
        let budget = try ContextBudget(maximumPromptTokens: 300, reservedOutputTokens: 40)

        XCTAssertThrowsError(try ForgeCompactSelector.select(from: project, budget: budget)) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .mandatoryContextExceedsBudget(required: 270, available: 260)
            )
        }
    }

    func testSelectorPrioritizesActiveWorkingSetBeforeProjectMemoryAndColdArchive() throws {
        let active = try fact("active", kind: .sourceReference, tier: .activeWorkingSet, priority: .normal, tokens: 80)
        let memory = try fact("memory", kind: .acceptedDecision, tier: .projectMemory, priority: .critical, tokens: 80)
        let cold = try fact("cold", kind: .workingNote, tier: .coldArchive, priority: .high, tokens: 30)
        let project = try capsule(extraFacts: [cold, memory, active])
        let budget = try ContextBudget(maximumPromptTokens: 300, reservedOutputTokens: 160)

        let selection = try ForgeCompactSelector.select(from: project, budget: budget)
        XCTAssertEqual(selection.selectedFacts.map(\.id), ["mission", "objective", "stage", "active"])
        XCTAssertEqual(selection.omittedFactIDs, ["cold", "memory"])
    }

    func testSelectionIsDeterministicAcrossInputOrder() throws {
        let a = try fact("a", kind: .sourceReference, tier: .activeWorkingSet, priority: .high, tokens: 45)
        let b = try fact("b", kind: .testReceipt, tier: .activeWorkingSet, priority: .high, tokens: 45)
        let c = try fact("c", kind: .acceptedDecision, tier: .projectMemory, priority: .critical, tokens: 45)
        let first = try capsule(extraFacts: [a, b, c])
        let second = try ProjectCapsule(
            projectID: "project-1",
            missionID: "mission-1",
            sourceRevision: "source-abc",
            capsuleRevision: 3,
            facts: [c] + Array(try requiredFacts().reversed()) + [b, a]
        )
        let budget = try ContextBudget(maximumPromptTokens: 300, reservedOutputTokens: 170)

        XCTAssertEqual(
            try ForgeCompactSelector.select(from: first, budget: budget),
            try ForgeCompactSelector.select(from: second, budget: budget)
        )
    }

    func testColdArchiveCannotMintCriticalPriority() throws {
        XCTAssertThrowsError(
            try fact("cold-critical", kind: .workingNote, tier: .coldArchive, priority: .critical)
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .invalidPriorityForColdArchive)
        }
    }

    func testCapsuleRejectsDuplicateFactIdentity() throws {
        let duplicateA = try fact("dup", kind: .sourceReference, tier: .activeWorkingSet)
        let duplicateB = try fact("dup", kind: .testReceipt, tier: .projectMemory)

        XCTAssertThrowsError(try capsule(extraFacts: [duplicateA, duplicateB])) { error in
            XCTAssertEqual(error as? ForgeCompactError, .duplicateFactID("dup"))
        }
    }

    func testCapsuleRejectsMissingOrDuplicateSingletonTruth() throws {
        let missingStage = try requiredFacts().filter { $0.kind != .currentStage }
        XCTAssertThrowsError(
            try ProjectCapsule(
                projectID: "project-1",
                missionID: "mission-1",
                sourceRevision: "rev",
                capsuleRevision: 1,
                facts: missingStage
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .missingRequiredFact(.currentStage))
        }

        let extraStage = try fact("stage-2", kind: .currentStage, tier: .alwaysResident, priority: .critical)
        XCTAssertThrowsError(try capsule(extraFacts: [extraStage])) { error in
            XCTAssertEqual(error as? ForgeCompactError, .duplicateSingletonFact(.currentStage))
        }
    }

    func testDecodeRejectsUnsupportedSchemaInsteadOfTrustingPersistedBytes() throws {
        let original = try capsule()
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 99
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ProjectCapsule.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCompactError, .unsupportedSchemaVersion(99))
        }
    }

    func testDecodeRevalidatesFactTierInvariant() throws {
        let original = try capsule()
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var facts = try XCTUnwrap(object["facts"] as? [[String: Any]])
        let objectiveIndex = try XCTUnwrap(facts.firstIndex { ($0["kind"] as? String) == CapsuleFactKind.currentObjective.rawValue })
        facts[objectiveIndex]["tier"] = ContextTier.projectMemory.rawValue
        object["facts"] = facts
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ProjectCapsule.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCompactError, .invalidTier(kind: .currentObjective, expected: .alwaysResident))
        }
    }

    func testProvenanceAndStableIdentityFailClosedOnWhitespaceAndControls() throws {
        XCTAssertThrowsError(
            try fact(
                "bad\nidentifier",
                kind: .sourceReference,
                tier: .activeWorkingSet,
                provenance: .sourceRevision(reference: "file.swift@abc")
            )
        )
        XCTAssertThrowsError(
            try fact(
                "valid-id",
                kind: .sourceReference,
                tier: .activeWorkingSet,
                provenance: .sourceRevision(reference: "  ")
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .invalidProvenanceReference)
        }
    }

    func testBudgetReserveMustLeavePromptCapacity() throws {
        XCTAssertThrowsError(try ContextBudget(maximumPromptTokens: 512, reservedOutputTokens: 512)) { error in
            XCTAssertEqual(error as? ForgeCompactError, .invalidContextBudget)
        }
        XCTAssertNoThrow(try ContextBudget(maximumPromptTokens: 512, reservedOutputTokens: 128))
    }
}

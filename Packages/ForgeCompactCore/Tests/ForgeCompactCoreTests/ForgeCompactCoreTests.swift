import Foundation
import Testing
@testable import ForgeCompactCore

@Suite("Forge Compact Project Capsule truth")
struct ForgeCompactCoreTests {
    private func criticalState() throws -> ForgeCompactCriticalState {
        try ForgeCompactCriticalState(
            currentObjective: "Repair the generated game and prove completion.",
            currentStageID: "stage.repair",
            privacyPolicyID: "privacy.local-only",
            modelPolicyID: "model.auto-local",
            toolSchemaRevision: "tools.v4",
            acceptedDecisionIDs: ["decision.orientation"],
            unresolvedDecisionIDs: ["decision.physics"],
            failingEvidenceIDs: ["evidence.runtime.crash"],
            blockerIDs: ["blocker.asset-license"],
            knownLimitationIDs: ["limitation.no-native-build"]
        )
    }

    private func item(
        _ id: String,
        tier: ForgeCompactContextTier,
        priority: Int,
        tokens: Int,
        mandatory: Bool = false,
        provenance: ForgeCompactProvenance = .sourceBacked
    ) throws -> ForgeCompactContextItem {
        try ForgeCompactContextItem(
            id: id,
            tier: tier,
            provenance: provenance,
            priority: priority,
            estimatedTokens: tokens,
            isMandatory: mandatory,
            payload: "payload for \(id)"
        )
    }

    private func capsule(items: [ForgeCompactContextItem]) throws -> ForgeCompactProjectCapsule {
        try ForgeCompactProjectCapsule(
            projectID: "project.demo",
            missionID: "mission.demo",
            sourceRevision: "git:abc123",
            missionRevision: 12,
            authorityEpoch: 3,
            criticalState: criticalState(),
            contextItems: items
        )
    }

    @Test func mandatoryModelSummaryIsRejected() throws {
        #expect(throws: ForgeCompactError.mandatoryItemRequiresAcceptedProvenance("summary")) {
            try item(
                "summary",
                tier: .alwaysResident,
                priority: 100,
                tokens: 40,
                mandatory: true,
                provenance: .modelSummary
            )
        }
    }

    @Test func mandatoryColdArchiveTruthIsRejected() throws {
        #expect(throws: ForgeCompactError.mandatoryColdArchiveItem("cold")) {
            try item("cold", tier: .coldArchive, priority: 100, tokens: 40, mandatory: true)
        }
    }

    @Test func duplicateContextIDsFailClosed() throws {
        let first = try item("same", tier: .alwaysResident, priority: 100, tokens: 20)
        let second = try item("same", tier: .activeWorkingSet, priority: 20, tokens: 10)
        #expect(throws: ForgeCompactError.duplicateContextItemID("same")) {
            try capsule(items: [first, second])
        }
    }

    @Test func criticalReferenceListsRejectDuplicates() throws {
        #expect(throws: ForgeCompactError.duplicateReferenceID("decision.same")) {
            try ForgeCompactCriticalState(
                currentObjective: "Build",
                currentStageID: "stage",
                privacyPolicyID: "privacy",
                modelPolicyID: "model",
                toolSchemaRevision: "tools",
                acceptedDecisionIDs: ["decision.same", "decision.same"]
            )
        }
    }

    @Test func mandatoryContextCannotBeSilentlyDropped() throws {
        let a = try item("l0.a", tier: .alwaysResident, priority: 100, tokens: 60, mandatory: true)
        let b = try item("l0.b", tier: .alwaysResident, priority: 90, tokens: 50, mandatory: true)
        let value = try capsule(items: [a, b])
        let budget = try ForgeCompactContextBudget(maxEstimatedTokens: 100)
        #expect(throws: ForgeCompactError.mandatoryContextExceedsBudget(required: 110, budget: 100)) {
            try ForgeCompactContextSelector.select(from: value, budget: budget)
        }
    }

    @Test func selectionPrefersHotterTierThenPriority() throws {
        let mandatory = try item("l0.required", tier: .alwaysResident, priority: 1, tokens: 20, mandatory: true)
        let active = try item("l1.active", tier: .activeWorkingSet, priority: 5, tokens: 30)
        let memoryHigh = try item("l2.high", tier: .projectMemory, priority: 100, tokens: 30)
        let memoryLow = try item("l2.low", tier: .projectMemory, priority: 10, tokens: 30)
        let value = try capsule(items: [memoryLow, memoryHigh, active, mandatory])
        let selection = try ForgeCompactContextSelector.select(
            from: value,
            budget: ForgeCompactContextBudget(maxEstimatedTokens: 80)
        )
        #expect(selection.selected.map(\.id) == ["l0.required", "l1.active", "l2.high"])
        #expect(selection.omittedItemIDs == ["l2.low"])
        #expect(selection.estimatedTokens == 80)
    }

    @Test func coldArchiveRequiresExplicitRetrievalPermission() throws {
        let hot = try item("l1", tier: .activeWorkingSet, priority: 1, tokens: 20)
        let cold = try item("l3", tier: .coldArchive, priority: 100, tokens: 20)
        let value = try capsule(items: [cold, hot])

        let defaultSelection = try ForgeCompactContextSelector.select(
            from: value,
            budget: ForgeCompactContextBudget(maxEstimatedTokens: 100)
        )
        #expect(defaultSelection.selected.map(\.id) == ["l1"])
        #expect(defaultSelection.omittedItemIDs == ["l3"])

        let retrievalSelection = try ForgeCompactContextSelector.select(
            from: value,
            budget: ForgeCompactContextBudget(maxEstimatedTokens: 100, allowColdArchiveRetrieval: true)
        )
        #expect(retrievalSelection.selected.map(\.id) == ["l1", "l3"])
    }

    @Test func capsuleEncodingIsCanonicalAndRoundTrips() throws {
        let z = try item("z", tier: .projectMemory, priority: 1, tokens: 10)
        let a = try item("a", tier: .alwaysResident, priority: 1, tokens: 10, mandatory: true)
        let original = try capsule(items: [z, a])
        #expect(original.contextItems.map(\.id) == ["a", "z"])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(ForgeCompactProjectCapsule.self, from: first)
        let second = try encoder.encode(decoded)
        #expect(decoded == original)
        #expect(first == second)
    }

    @Test func oldCapsuleSchemaFailsClosedOnDecode() throws {
        let value = try capsule(items: [])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object["schemaVersion"] = 0
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ForgeCompactError.unsupportedSchema(0)) {
            try JSONDecoder().decode(ForgeCompactProjectCapsule.self, from: data)
        }
    }

    @Test func prefixReuseRequiresExactIdentity() throws {
        let baseline = try ForgeCompactPrefixReuseIdentity(
            modelID: "qwen.local",
            modelRevision: "r1",
            tokenizerRevision: "tok1",
            runtimeID: "llama.cpp",
            runtimeRevision: "runtime1",
            promptTemplateRevision: "template1",
            toolSchemaRevision: "tools1",
            capsuleSourceRevision: "git:abc",
            capsuleMissionRevision: 7,
            capsuleAuthorityEpoch: 2
        )
        let same = try ForgeCompactPrefixReuseIdentity(
            modelID: "qwen.local",
            modelRevision: "r1",
            tokenizerRevision: "tok1",
            runtimeID: "llama.cpp",
            runtimeRevision: "runtime1",
            promptTemplateRevision: "template1",
            toolSchemaRevision: "tools1",
            capsuleSourceRevision: "git:abc",
            capsuleMissionRevision: 7,
            capsuleAuthorityEpoch: 2
        )
        let changedTemplate = try ForgeCompactPrefixReuseIdentity(
            modelID: "qwen.local",
            modelRevision: "r1",
            tokenizerRevision: "tok1",
            runtimeID: "llama.cpp",
            runtimeRevision: "runtime1",
            promptTemplateRevision: "template2",
            toolSchemaRevision: "tools1",
            capsuleSourceRevision: "git:abc",
            capsuleMissionRevision: 7,
            capsuleAuthorityEpoch: 2
        )
        #expect(baseline.canReusePrefix(with: same))
        #expect(!baseline.canReusePrefix(with: changedTemplate))
    }

    @Test func blankCriticalIdentityFailsClosed() throws {
        #expect(throws: ForgeCompactError.invalidIdentifier("privacyPolicyID")) {
            try ForgeCompactCriticalState(
                currentObjective: "Build",
                currentStageID: "stage",
                privacyPolicyID: "   ",
                modelPolicyID: "model",
                toolSchemaRevision: "tools"
            )
        }
    }

    @Test func invalidBudgetFailsClosed() throws {
        #expect(throws: ForgeCompactError.invalidBudget(0)) {
            try ForgeCompactContextBudget(maxEstimatedTokens: 0)
        }
    }

    @Test func decodedBudgetCannotBypassValidation() throws {
        let data = Data(#"{\"maxEstimatedTokens\":0,\"allowColdArchiveRetrieval\":true}"#.utf8)
        #expect(throws: ForgeCompactError.invalidBudget(0)) {
            try JSONDecoder().decode(ForgeCompactContextBudget.self, from: data)
        }
    }

    @Test func decodedPrefixIdentityCannotBypassValidation() throws {
        let data = Data(#"{\"modelID\":\" \",\"modelRevision\":\"r1\",\"tokenizerRevision\":\"tok1\",\"runtimeID\":\"llama.cpp\",\"runtimeRevision\":\"runtime1\",\"promptTemplateRevision\":\"template1\",\"toolSchemaRevision\":\"tools1\",\"capsuleSourceRevision\":\"git:abc\",\"capsuleMissionRevision\":7,\"capsuleAuthorityEpoch\":2}"#.utf8)
        #expect(throws: ForgeCompactError.invalidIdentifier("modelID")) {
            try JSONDecoder().decode(ForgeCompactPrefixReuseIdentity.self, from: data)
        }
    }
}

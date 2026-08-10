import Foundation
import Testing
@testable import ForgeDesignCore

@Test func structuralUserReceiptAloneCannotRemoveRule() throws {
    let current = try coreSeedDNA()
    let id = DesignRuleID(rawValue: "rule.spacing")
    #expect(throws: ForgeDesignValidationError.invalidArchiveTransition("removeRule must remove an existing rule")) {
        _ = try DesignDNAEditor().applying(
            .removeRule(id, authorization: coreProvenance(.userDecision, "receipt.user")),
            to: current,
            projectID: coreProjectID,
            changeReceiptID: DesignReceiptID(rawValue: "receipt.change"),
            acceptedAt: coreNow
        )
    }
}

@Test func intentReplacementRejectsModelSuggestion() throws {
    let replacement = try IntentCore(productPromise: "Arcade racer", traits: ["Bright"])
    #expect(throws: ForgeDesignValidationError.userAuthorityRequired("replaceIntentCore")) {
        _ = try DesignDNAEditor().applying(
            .replaceIntentCore(replacement, provenance: coreProvenance(.modelSuggestion, "receipt.model")),
            to: coreSeedDNA(),
            projectID: coreProjectID,
            changeReceiptID: DesignReceiptID(rawValue: "receipt.change"),
            acceptedAt: coreNow
        )
    }
}

@Test func userCanAddAndRemoveNeverRuleOnlyWithAuthenticatedAuthority() throws {
    let neverRule = try NeverRule(
        id: NeverRuleID(rawValue: "never.purple"),
        instruction: "No generic purple gradients",
        scope: .project,
        provenance: coreProvenance(.userDecision, "receipt.user.1")
    )
    let withRule = try applyWithUserAuthority(
        .addNeverRule(neverRule),
        to: coreSeedDNA(),
        receiptID: "receipt.change.2",
        acceptedAt: coreNow.addingTimeInterval(1)
    )
    let removed = try applyWithUserAuthority(
        .removeNeverRule(neverRule.id, authorization: coreProvenance(.userDecision, "receipt.user.2")),
        to: withRule,
        receiptID: "receipt.change.3",
        acceptedAt: coreNow.addingTimeInterval(2)
    )
    #expect(removed.neverRules.isEmpty)
    #expect(removed.revision == 3)
}

@Test func modelCannotDowngradeExistingProtectedRule() throws {
    let protected = try DesignRule(
        id: DesignRuleID(rawValue: "rule.motion"),
        category: .motion,
        statement: "Use direct-response springs",
        protection: .protected,
        provenance: coreProvenance(.userDecision, "receipt.user.protect")
    )
    let base = try DesignDNA(
        projectID: coreProjectID,
        revision: 1,
        intentCore: coreIntent(),
        rules: [protected],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.seed"),
        updatedAt: coreNow
    )
    let attemptedDowngrade = try DesignRule(
        id: protected.id,
        category: .motion,
        statement: "Use slow floating motion",
        protection: .advisory,
        provenance: coreProvenance(.modelSuggestion, "receipt.model")
    )
    #expect(throws: ForgeDesignValidationError.protectedRuleMutationRequiresUserAuthority(protected.id)) {
        _ = try DesignDNAEditor().applying(
            .upsertRule(attemptedDowngrade),
            to: base,
            projectID: coreProjectID,
            changeReceiptID: DesignReceiptID(rawValue: "receipt.change"),
            acceptedAt: coreNow
        )
    }
}

@Test func acceptedRuntimeCannotSilentlyReplaceProtectedComponent() throws {
    let componentID = ProtectedDesignComponentID(rawValue: "component.hero")
    let original = try ProtectedDesignComponent(
        id: componentID,
        name: "Hero control",
        stableSourceIdentity: "Forge/HeroControl",
        reason: "Protected by the user",
        provenance: coreProvenance(.userDecision, "receipt.user.protect")
    )
    let base = try DesignDNA(
        projectID: coreProjectID,
        revision: 1,
        intentCore: coreIntent(),
        rules: [],
        protectedComponents: [original],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.seed"),
        updatedAt: coreNow
    )
    let replacement = try ProtectedDesignComponent(
        id: componentID,
        name: "Hero control v2",
        stableSourceIdentity: "Forge/HeroControlV2",
        reason: "Runtime looked better",
        provenance: coreProvenance(.acceptedRuntimeCapture, "receipt.runtime")
    )
    #expect(throws: ForgeDesignValidationError.protectedComponentMutationRequiresUserAuthority(componentID)) {
        _ = try DesignDNAEditor().applying(
            .protectComponent(replacement),
            to: base,
            projectID: coreProjectID,
            changeReceiptID: DesignReceiptID(rawValue: "receipt.change"),
            acceptedAt: coreNow
        )
    }
}

@Test func codableRoundTripRevalidatesDNA() throws {
    let dna = try coreSeedDNA()
    let data = try JSONEncoder().encode(dna)
    let decoded = try JSONDecoder().decode(DesignDNA.self, from: data)
    #expect(decoded == dna)
}

@Test func unsupportedDNAArchiveSchemaFailsClosed() throws {
    #expect(throws: ForgeDesignValidationError.unsupportedSchemaVersion(99)) {
        _ = try DesignDNAArchive(schemaVersion: 99, snapshots: [coreSeedDNA()])
    }
}

@Test func archiveRequiresSingleProjectAndExactSemanticRevisionChain() throws {
    let first = try coreSeedDNA()
    let rule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.archive"),
        category: .motion,
        statement: "Direct motion",
        protection: .advisory,
        provenance: coreProvenance(.modelSuggestion, "receipt.model.archive")
    )
    let editor = DesignDNAEditor()
    let candidate = try editor.candidateApplying(
        .upsertRule(rule),
        to: first,
        projectID: coreProjectID,
        changeReceiptID: DesignReceiptID(rawValue: "receipt.2"),
        acceptedAt: coreNow.addingTimeInterval(1)
    )
    let second = candidate.snapshot
    #expect((try DesignDNAArchive(snapshots: [first, second], changeRecords: [candidate.changeRecord])).snapshots.count == 2)

    #expect(throws: ForgeDesignValidationError.self) {
        _ = try DesignDNAArchive(snapshots: [second, first], changeRecords: [candidate.changeRecord])
    }
}

@Test func archiveDecodeRevalidatesTamperedRevisionOrder() throws {
    let first = try coreSeedDNA()
    let rule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.archive"),
        category: .motion,
        statement: "Direct motion",
        protection: .advisory,
        provenance: coreProvenance(.modelSuggestion, "receipt.model.archive")
    )
    let editor = DesignDNAEditor()
    let candidate = try editor.candidateApplying(
        .upsertRule(rule),
        to: first,
        projectID: coreProjectID,
        changeReceiptID: DesignReceiptID(rawValue: "receipt.2"),
        acceptedAt: coreNow.addingTimeInterval(1)
    )
    let second = candidate.snapshot
    let archive = try DesignDNAArchive(snapshots: [first, second], changeRecords: [candidate.changeRecord])
    let data = try JSONEncoder().encode(archive)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var tampered = object
    let snapshots = try #require(tampered["snapshots"] as? [[String: Any]])
    tampered["snapshots"] = Array(snapshots.reversed())
    let tamperedData = try JSONSerialization.data(withJSONObject: tampered)

    #expect(throws: ForgeDesignValidationError.self) {
        _ = try JSONDecoder().decode(DesignDNAArchive.self, from: tamperedData)
    }
}

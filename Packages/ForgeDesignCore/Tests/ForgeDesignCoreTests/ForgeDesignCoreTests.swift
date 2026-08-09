import Foundation
import Testing
@testable import ForgeDesignCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let projectID = DesignProjectID(rawValue: "project.neon-racer")

private func provenance(_ kind: DesignProvenanceKind, _ id: String) throws -> DesignProvenance {
    try DesignProvenance(kind: kind, receiptID: DesignReceiptID(rawValue: id), recordedAt: now)
}

private func intent() throws -> IntentCore {
    try IntentCore(productPromise: "Fast touch-first driving game", traits: ["Dark", "Fast", "Landscape", "No clutter"])
}

private func seedDNA() throws -> DesignDNA {
    try DesignDNA(
        projectID: projectID,
        revision: 1,
        intentCore: intent(),
        rules: [],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.seed"),
        updatedAt: now
    )
}

@Test func intentRejectsDuplicateTraitsCaseInsensitively() throws {
    #expect(throws: ForgeDesignValidationError.self) {
        _ = try IntentCore(productPromise: "A game", traits: ["Touch-first", "touch-first"])
    }
}

@Test func intentCapsTraitCount() throws {
    #expect(throws: ForgeDesignValidationError.tooManyIntentTraits(13)) {
        _ = try IntentCore(productPromise: "A game", traits: (0..<13).map { "trait-\($0)" })
    }
}

@Test func modelSuggestionMayRemainAdvisory() throws {
    let rule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.motion"),
        category: .motion,
        statement: "Use fast direct-response springs",
        protection: .advisory,
        provenance: provenance(.modelSuggestion, "receipt.model")
    )
    #expect(rule.protection == .advisory)
}

@Test func modelSuggestionCannotProtectRule() throws {
    let id = DesignRuleID(rawValue: "rule.motion")
    #expect(throws: ForgeDesignValidationError.provenanceCannotProtectRule(id)) {
        _ = try DesignRule(
            id: id,
            category: .motion,
            statement: "Use fast direct-response springs",
            protection: .protected,
            provenance: provenance(.modelSuggestion, "receipt.model")
        )
    }
}

@Test func importedReferenceCannotProtectComponent() throws {
    let id = ProtectedDesignComponentID(rawValue: "component.speedometer")
    #expect(throws: ForgeDesignValidationError.provenanceCannotProtectComponent(id)) {
        _ = try ProtectedDesignComponent(
            id: id,
            name: "Speedometer",
            stableSourceIdentity: "HUD/Speedometer",
            reason: "Keep this exact hierarchy",
            provenance: provenance(.importedReference, "receipt.reference")
        )
    }
}

@Test func acceptedRuntimeCaptureMayProtectComponent() throws {
    let component = try ProtectedDesignComponent(
        id: ProtectedDesignComponentID(rawValue: "component.speedometer"),
        name: "Speedometer",
        stableSourceIdentity: "HUD/Speedometer",
        reason: "Accepted by the user after runtime inspection",
        provenance: provenance(.acceptedRuntimeCapture, "receipt.runtime")
    )
    #expect(component.name == "Speedometer")
}

@Test func neverRuleRequiresExplicitUserDecision() throws {
    let id = NeverRuleID(rawValue: "never.purple")
    #expect(throws: ForgeDesignValidationError.neverRuleRequiresUserDecision(id)) {
        _ = try NeverRule(
            id: id,
            instruction: "Do not use generic AI purple gradients",
            scope: .project,
            provenance: provenance(.modelSuggestion, "receipt.model")
        )
    }
}

@Test func neverRuleNormalizesScopedText() throws {
    let rule = try NeverRule(
        id: NeverRuleID(rawValue: "never.toolbar"),
        instruction: "Do not add permanent toolbar clutter",
        scope: .surface("  Forge  "),
        provenance: provenance(.userDecision, "receipt.user")
    )
    #expect(rule.scope == .surface("Forge"))
}

@Test func duplicateIDsFailClosed() throws {
    let rule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.spacing"),
        category: .spacing,
        statement: "Use an 8-point rhythm",
        protection: .advisory,
        provenance: provenance(.acceptedSourceCheckpoint, "receipt.source")
    )
    #expect(throws: ForgeDesignValidationError.duplicateRuleID(rule.id)) {
        _ = try DesignDNA(
            projectID: projectID,
            revision: 1,
            intentCore: intent(),
            rules: [rule, rule],
            protectedComponents: [],
            neverRules: [],
            lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.seed"),
            updatedAt: now
        )
    }
}

@Test func editorUpsertsAndAdvancesRevision() throws {
    let current = try seedDNA()
    let rule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.material"),
        category: .materials,
        statement: "Focused surfaces use restrained elevated glass",
        protection: .protected,
        provenance: provenance(.userDecision, "receipt.user")
    )

    let revised = try DesignDNAEditor().applying(
        .upsertRule(rule),
        to: current,
        projectID: projectID,
        changeReceiptID: DesignReceiptID(rawValue: "receipt.change.2"),
        acceptedAt: now.addingTimeInterval(1)
    )

    #expect(revised.revision == 2)
    #expect(revised.rules == [rule])
    #expect(revised.lastChangeReceiptID.rawValue == "receipt.change.2")
}

@Test func editorRejectsWrongProjectIdentity() throws {
    let current = try seedDNA()
    let rule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.spacing"),
        category: .spacing,
        statement: "Use an 8-point rhythm",
        protection: .advisory,
        provenance: provenance(.acceptedSourceCheckpoint, "receipt.source")
    )

    #expect(throws: ForgeDesignValidationError.projectIdentityMismatch) {
        _ = try DesignDNAEditor().applying(
            .upsertRule(rule),
            to: current,
            projectID: DesignProjectID(rawValue: "project.other"),
            changeReceiptID: DesignReceiptID(rawValue: "receipt.change"),
            acceptedAt: now
        )
    }
}

@Test func protectedRuleRemovalRequiresUserAuthority() throws {
    let current = try seedDNA()
    let id = DesignRuleID(rawValue: "rule.spacing")
    #expect(throws: ForgeDesignValidationError.userAuthorityRequired("removeRule")) {
        _ = try DesignDNAEditor().applying(
            .removeRule(id, authorization: provenance(.modelSuggestion, "receipt.model")),
            to: current,
            projectID: projectID,
            changeReceiptID: DesignReceiptID(rawValue: "receipt.change"),
            acceptedAt: now
        )
    }
}

@Test func intentReplacementRejectsModelSuggestion() throws {
    let replacement = try IntentCore(productPromise: "Arcade racer", traits: ["Bright"])
    #expect(throws: ForgeDesignValidationError.userAuthorityRequired("replaceIntentCore")) {
        _ = try DesignDNAEditor().applying(
            .replaceIntentCore(replacement, provenance: provenance(.modelSuggestion, "receipt.model")),
            to: seedDNA(),
            projectID: projectID,
            changeReceiptID: DesignReceiptID(rawValue: "receipt.change"),
            acceptedAt: now
        )
    }
}

@Test func userCanRemoveNeverRule() throws {
    let neverRule = try NeverRule(
        id: NeverRuleID(rawValue: "never.purple"),
        instruction: "No generic purple gradients",
        scope: .project,
        provenance: provenance(.userDecision, "receipt.user.1")
    )
    let withRule = try DesignDNAEditor().applying(
        .addNeverRule(neverRule),
        to: seedDNA(),
        projectID: projectID,
        changeReceiptID: DesignReceiptID(rawValue: "receipt.change.2"),
        acceptedAt: now
    )
    let removed = try DesignDNAEditor().applying(
        .removeNeverRule(neverRule.id, authorization: provenance(.userDecision, "receipt.user.2")),
        to: withRule,
        projectID: projectID,
        changeReceiptID: DesignReceiptID(rawValue: "receipt.change.3"),
        acceptedAt: now.addingTimeInterval(1)
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
        provenance: provenance(.userDecision, "receipt.user.protect")
    )
    let base = try DesignDNA(
        projectID: projectID,
        revision: 1,
        intentCore: intent(),
        rules: [protected],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.seed"),
        updatedAt: now
    )
    let attemptedDowngrade = try DesignRule(
        id: protected.id,
        category: .motion,
        statement: "Use slow floating motion",
        protection: .advisory,
        provenance: provenance(.modelSuggestion, "receipt.model")
    )

    #expect(throws: ForgeDesignValidationError.protectedRuleMutationRequiresUserAuthority(protected.id)) {
        _ = try DesignDNAEditor().applying(
            .upsertRule(attemptedDowngrade),
            to: base,
            projectID: projectID,
            changeReceiptID: DesignReceiptID(rawValue: "receipt.change"),
            acceptedAt: now
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
        provenance: provenance(.userDecision, "receipt.user.protect")
    )
    let base = try DesignDNA(
        projectID: projectID,
        revision: 1,
        intentCore: intent(),
        rules: [],
        protectedComponents: [original],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.seed"),
        updatedAt: now
    )
    let replacement = try ProtectedDesignComponent(
        id: componentID,
        name: "Hero control v2",
        stableSourceIdentity: "Forge/HeroControlV2",
        reason: "Runtime looked better",
        provenance: provenance(.acceptedRuntimeCapture, "receipt.runtime")
    )

    #expect(throws: ForgeDesignValidationError.protectedComponentMutationRequiresUserAuthority(componentID)) {
        _ = try DesignDNAEditor().applying(
            .protectComponent(replacement),
            to: base,
            projectID: projectID,
            changeReceiptID: DesignReceiptID(rawValue: "receipt.change"),
            acceptedAt: now
        )
    }
}

@Test func codableRoundTripRevalidatesDNA() throws {
    let dna = try seedDNA()
    let data = try JSONEncoder().encode(dna)
    let decoded = try JSONDecoder().decode(DesignDNA.self, from: data)
    #expect(decoded == dna)
}

@Test func unsupportedDNAArchiveSchemaFailsClosed() throws {
    #expect(throws: ForgeDesignValidationError.unsupportedSchemaVersion(99)) {
        _ = try DesignDNAArchive(schemaVersion: 99, snapshots: [seedDNA()])
    }
}

@Test func archiveRequiresSingleProjectAndIncreasingRevision() throws {
    let first = try seedDNA()
    let second = try DesignDNA(
        projectID: projectID,
        revision: 2,
        intentCore: intent(),
        rules: [],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.2"),
        updatedAt: now.addingTimeInterval(1)
    )
    #expect((try DesignDNAArchive(snapshots: [first, second])).snapshots.count == 2)

    #expect(throws: ForgeDesignValidationError.revisionMustAdvance) {
        _ = try DesignDNAArchive(snapshots: [second, first])
    }
}

@Test func archiveDecodeRevalidatesTamperedRevisionOrder() throws {
    let first = try seedDNA()
    let second = try DesignDNA(
        projectID: projectID,
        revision: 2,
        intentCore: intent(),
        rules: [],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.2"),
        updatedAt: now.addingTimeInterval(1)
    )
    let archive = try DesignDNAArchive(snapshots: [first, second])
    let data = try JSONEncoder().encode(archive)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var tampered = object
    let snapshots = try #require(tampered["snapshots"] as? [[String: Any]])
    tampered["snapshots"] = Array(snapshots.reversed())
    let tamperedData = try JSONSerialization.data(withJSONObject: tampered)

    #expect(throws: ForgeDesignValidationError.revisionMustAdvance) {
        _ = try JSONDecoder().decode(DesignDNAArchive.self, from: tamperedData)
    }
}

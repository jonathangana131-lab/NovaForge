import Foundation
import Testing
@testable import ForgeDesignCore

private let hardeningNow = Date(timeIntervalSince1970: 1_800_000_100)
private let hardeningProjectID = DesignProjectID(rawValue: "project.decode-hardening")

private func hardeningProvenance(
    _ kind: DesignProvenanceKind,
    _ id: String
) throws -> DesignProvenance {
    try DesignProvenance(
        kind: kind,
        receiptID: DesignReceiptID(rawValue: id),
        recordedAt: hardeningNow
    )
}

private func hardeningJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func hardeningJSONData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

@Test func decodedModelSuggestionCannotBecomeProtectedRule() throws {
    let id = DesignRuleID(rawValue: "rule.decoded-model")
    let rule = try DesignRule(
        id: id,
        category: .motion,
        statement: "Use direct motion",
        protection: .advisory,
        provenance: hardeningProvenance(.modelSuggestion, "receipt.model")
    )
    var object = try hardeningJSONObject(rule)
    object["protection"] = DesignRuleProtection.protected.rawValue

    #expect(throws: ForgeDesignValidationError.provenanceCannotProtectRule(id)) {
        _ = try JSONDecoder().decode(DesignRule.self, from: hardeningJSONData(object))
    }
}

@Test func decodedImportedReferenceCannotBecomeProtectedComponent() throws {
    let id = ProtectedDesignComponentID(rawValue: "component.decoded-reference")
    let component = try ProtectedDesignComponent(
        id: id,
        name: "Hero control",
        stableSourceIdentity: "Forge/HeroControl",
        reason: "Accepted hierarchy",
        provenance: hardeningProvenance(.userDecision, "receipt.user")
    )
    var object = try hardeningJSONObject(component)
    var provenance = try #require(object["provenance"] as? [String: Any])
    provenance["kind"] = DesignProvenanceKind.importedReference.rawValue
    object["provenance"] = provenance

    #expect(throws: ForgeDesignValidationError.provenanceCannotProtectComponent(id)) {
        _ = try JSONDecoder().decode(ProtectedDesignComponent.self, from: hardeningJSONData(object))
    }
}

@Test func decodedModelSuggestionCannotBecomeNeverRule() throws {
    let id = NeverRuleID(rawValue: "never.decoded-model")
    let rule = try NeverRule(
        id: id,
        instruction: "Never add generic AI gradients",
        scope: .project,
        provenance: hardeningProvenance(.userDecision, "receipt.user")
    )
    var object = try hardeningJSONObject(rule)
    var provenance = try #require(object["provenance"] as? [String: Any])
    provenance["kind"] = DesignProvenanceKind.modelSuggestion.rawValue
    object["provenance"] = provenance

    #expect(throws: ForgeDesignValidationError.neverRuleRequiresUserDecision(id)) {
        _ = try JSONDecoder().decode(NeverRule.self, from: hardeningJSONData(object))
    }
}

@Test func decodedIntentRevalidatesDuplicateTraits() throws {
    let intent = try IntentCore(
        productPromise: "Calm creation surface",
        traits: ["Calm", "Precise"]
    )
    var object = try hardeningJSONObject(intent)
    object["traits"] = ["Calm", "calm"]

    #expect(throws: ForgeDesignValidationError.self) {
        _ = try JSONDecoder().decode(IntentCore.self, from: hardeningJSONData(object))
    }
}

@Test func decodedProvenanceRejectsBlankReceiptIdentity() throws {
    let provenanceValue = try hardeningProvenance(.acceptedRuntimeCapture, "receipt.runtime")
    var object = try hardeningJSONObject(provenanceValue)
    var receiptID = try #require(object["receiptID"] as? [String: Any])
    receiptID["rawValue"] = "   "
    object["receiptID"] = receiptID

    #expect(throws: ForgeDesignValidationError.blankIdentifier("provenance.receiptID")) {
        _ = try JSONDecoder().decode(DesignProvenance.self, from: hardeningJSONData(object))
    }
}

@Test func designDNADecodeCannotLaunderNestedProtectedRuleAuthority() throws {
    let id = DesignRuleID(rawValue: "rule.nested-model")
    let advisory = try DesignRule(
        id: id,
        category: .materials,
        statement: "Consider restrained glass",
        protection: .advisory,
        provenance: hardeningProvenance(.modelSuggestion, "receipt.model.nested")
    )
    let dna = try DesignDNA(
        projectID: hardeningProjectID,
        revision: 1,
        intentCore: IntentCore(productPromise: "Premium local-first builder", traits: ["Calm"]),
        rules: [advisory],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.seed"),
        updatedAt: hardeningNow
    )

    var object = try hardeningJSONObject(dna)
    var rules = try #require(object["rules"] as? [[String: Any]])
    rules[0]["protection"] = DesignRuleProtection.protected.rawValue
    object["rules"] = rules

    #expect(throws: ForgeDesignValidationError.provenanceCannotProtectRule(id)) {
        _ = try JSONDecoder().decode(DesignDNA.self, from: hardeningJSONData(object))
    }
}

import Foundation
import Testing
@testable import ForgeDesignCore

private let trustNow = Date(timeIntervalSince1970: 1_800_000_200)
private let trustProjectID = DesignProjectID(rawValue: "project.design-trust")

private func trustProvenance(
    _ kind: DesignProvenanceKind,
    _ receiptID: String
) throws -> DesignProvenance {
    try DesignProvenance(
        kind: kind,
        receiptID: DesignReceiptID(rawValue: receiptID),
        recordedAt: trustNow
    )
}

private func trustRule(
    protection: DesignRuleProtection = .protected,
    provenance: DesignProvenance? = nil
) throws -> DesignRule {
    try DesignRule(
        id: DesignRuleID(rawValue: "rule.hero-motion"),
        category: .motion,
        statement: "Use direct-response motion",
        protection: protection,
        provenance: provenance ?? trustProvenance(.userDecision, "receipt.user.hero-motion")
    )
}

private func trustDNA(rule: DesignRule) throws -> DesignDNA {
    try DesignDNA(
        projectID: trustProjectID,
        revision: 3,
        intentCore: IntentCore(
            productPromise: "Premium local-first creation",
            traits: ["Calm", "Precise"]
        ),
        rules: [rule],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.snapshot.3"),
        updatedAt: trustNow
    )
}

private func trustJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func trustJSONData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

@Test func acceptedDesignTruthRequiresHostBinding() throws {
    let snapshot = try trustDNA(rule: trustRule())

    #expect(!snapshot.canSupportAcceptedDesignTruth(trustedSnapshots: []))

    let binding = DesignDNATrustBinding(authenticatedSnapshot: snapshot)
    #expect(snapshot.canSupportAcceptedDesignTruth(trustedSnapshots: [binding]))
}

@Test func trustedSnapshotCannotAuthorizeDifferentContentWithSameReceiptAndRevision() throws {
    let snapshot = try trustDNA(rule: trustRule())
    let binding = DesignDNATrustBinding(authenticatedSnapshot: snapshot)

    var object = try trustJSONObject(snapshot)
    var rules = try #require(object["rules"] as? [[String: Any]])
    rules[0]["statement"] = "Use slow floating motion"
    object["rules"] = rules
    let modified = try JSONDecoder().decode(DesignDNA.self, from: trustJSONData(object))

    #expect(modified.projectID == snapshot.projectID)
    #expect(modified.revision == snapshot.revision)
    #expect(modified.lastChangeReceiptID == snapshot.lastChangeReceiptID)
    #expect(modified != snapshot)
    #expect(!modified.canSupportAcceptedDesignTruth(trustedSnapshots: [binding]))
}

@Test func decodedUserDecisionClaimCannotSelfAuthorizeAcceptedDesignTruth() throws {
    let advisory = try trustRule(
        protection: .advisory,
        provenance: trustProvenance(.modelSuggestion, "receipt.model.hero-motion")
    )
    let candidate = try trustDNA(rule: advisory)
    let candidateBinding = DesignDNATrustBinding(authenticatedSnapshot: candidate)

    var object = try trustJSONObject(candidate)
    var rules = try #require(object["rules"] as? [[String: Any]])
    var provenance = try #require(rules[0]["provenance"] as? [String: Any])
    provenance["kind"] = DesignProvenanceKind.userDecision.rawValue
    rules[0]["provenance"] = provenance
    rules[0]["protection"] = DesignRuleProtection.protected.rawValue
    object["rules"] = rules

    let forged = try JSONDecoder().decode(DesignDNA.self, from: trustJSONData(object))
    #expect(forged.rules[0].protection == .protected)
    #expect(forged.rules[0].provenance.kind == .userDecision)
    #expect(!forged.canSupportAcceptedDesignTruth(trustedSnapshots: []))
    #expect(!forged.canSupportAcceptedDesignTruth(trustedSnapshots: [candidateBinding]))
}

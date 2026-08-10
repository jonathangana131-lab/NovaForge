import Foundation
import Testing
@testable import ForgeDesignCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let project = DesignProjectID(rawValue: "project.secure")
private func prov(_ kind: DesignProvenanceKind, _ id: String) throws -> DesignProvenance { try DesignProvenance(kind: kind, receiptID: .init(rawValue: id), recordedAt: now) }
private func intent(_ promise: String = "A game") throws -> IntentCore { try IntentCore(productPromise: promise, traits: ["Fast"]) }
private func seed(revision: Int = 1, rules: [DesignRule] = [], never: [NeverRule] = []) throws -> DesignDNA { try DesignDNA(projectID: project, revision: revision, intentCore: intent(), rules: rules, protectedComponents: [], neverRules: never, lastChangeReceiptID: .init(rawValue: "receipt.\(revision)"), updatedAt: now.addingTimeInterval(Double(revision))) }

@Test func forgedUserDecisionCannotProtectWithoutNonCodableAuthority() throws {
    let editor = DesignDNAEditor(); let base = try seed()
    let rule = try DesignRule(id: .init(rawValue: "rule.motion"), category: .motion, statement: "Direct springs", protection: .protected, provenance: prov(.userDecision, "receipt.user"))
    #expect(throws: ForgeDesignValidationError.authenticatedUserAuthorityRequired("protectRule")) {
        _ = try editor.applying(.upsertRule(rule), to: base, projectID: project, changeReceiptID: .init(rawValue: "receipt.change"), acceptedAt: now.addingTimeInterval(2))
    }
    let candidate = try editor.candidateApplying(.upsertRule(rule), to: base, projectID: project, changeReceiptID: .init(rawValue: "receipt.change"), acceptedAt: now.addingTimeInterval(2))
    let purpose = try #require(candidate.requiredUserAuthority)
    let authority = DesignDNAUserMutationAuthority(authenticatedBefore: base, authenticatedAfter: candidate.snapshot, authenticatedRecord: candidate.changeRecord, purpose: purpose)
    let accepted = try editor.applying(.upsertRule(rule), to: base, projectID: project, changeReceiptID: .init(rawValue: "receipt.change"), acceptedAt: now.addingTimeInterval(2), userAuthority: authority)
    #expect(accepted == candidate.snapshot)
}

@Test func authorityIsExactBeforeAfterAndPurposeBound() throws {
    let editor = DesignDNAEditor(); let base = try seed()
    let one = try DesignRule(id: .init(rawValue: "rule.one"), category: .motion, statement: "One", protection: .protected, provenance: prov(.userDecision, "receipt.user.one"))
    let two = try DesignRule(id: .init(rawValue: "rule.two"), category: .motion, statement: "Two", protection: .protected, provenance: prov(.userDecision, "receipt.user.two"))
    let c1 = try editor.candidateApplying(.upsertRule(one), to: base, projectID: project, changeReceiptID: .init(rawValue: "receipt.change.one"), acceptedAt: now.addingTimeInterval(2))
    let authority = DesignDNAUserMutationAuthority(authenticatedBefore: base, authenticatedAfter: c1.snapshot, authenticatedRecord: c1.changeRecord, purpose: try #require(c1.requiredUserAuthority))
    #expect(throws: ForgeDesignValidationError.authenticatedUserAuthorityRequired("protectRule")) {
        _ = try editor.applying(.upsertRule(two), to: base, projectID: project, changeReceiptID: .init(rawValue: "receipt.change.two"), acceptedAt: now.addingTimeInterval(2), userAuthority: authority)
    }
}

@Test func archiveRejectsRevisionOnlyAndMultiMutationTransitions() throws {
    let first = try seed()
    let revisionOnly = try DesignDNA(projectID: project, revision: 2, intentCore: first.intentCore, rules: [], protectedComponents: [], neverRules: [], lastChangeReceiptID: .init(rawValue: "receipt.2"), updatedAt: now.addingTimeInterval(2))
    #expect(throws: ForgeDesignValidationError.self) { _ = try DesignDNAArchive(snapshots: [first, revisionOnly]) }

    let r1 = try DesignRule(id: .init(rawValue: "rule.1"), category: .motion, statement: "One", protection: .advisory, provenance: prov(.modelSuggestion, "receipt.model.1"))
    let r2 = try DesignRule(id: .init(rawValue: "rule.2"), category: .spacing, statement: "Two", protection: .advisory, provenance: prov(.modelSuggestion, "receipt.model.2"))
    let multi = try DesignDNA(projectID: project, revision: 2, intentCore: first.intentCore, rules: [r1, r2], protectedComponents: [], neverRules: [], lastChangeReceiptID: .init(rawValue: "receipt.multi"), updatedAt: now.addingTimeInterval(2))
    #expect(throws: ForgeDesignValidationError.self) { _ = try DesignDNAArchive(snapshots: [first, multi]) }
}

@Test func acceptedArchiveRequiresWholeSnapshotAndTransitionTrust() throws {
    let editor = DesignDNAEditor(); let first = try seed()
    let rule = try DesignRule(id: .init(rawValue: "rule.advisory"), category: .motion, statement: "Try direct springs", protection: .advisory, provenance: prov(.modelSuggestion, "receipt.model"))
    let candidate = try editor.candidateApplying(.upsertRule(rule), to: first, projectID: project, changeReceiptID: .init(rawValue: "receipt.2"), acceptedAt: now.addingTimeInterval(2))
    let second = candidate.snapshot
    let archive = try DesignDNAArchive(snapshots: [first, second], changeRecords: [candidate.changeRecord])
    let s1 = DesignDNATrustBinding(authenticatedSnapshot: first); let s2 = DesignDNATrustBinding(authenticatedSnapshot: second)
    #expect(!archive.canSupportAcceptedDesignHistory(trustedSnapshots: [s1, s2], trustedTransitions: []))
    let transition = try DesignDNATransitionTrustBinding(authenticatedBefore: first, authenticatedAfter: second, authenticatedRecord: candidate.changeRecord)
    #expect(archive.canSupportAcceptedDesignHistory(trustedSnapshots: [s1, s2], trustedTransitions: [transition]))
}

@Test func revisionOverflowFailsClosed() throws {
    let base = try DesignDNA(projectID: project, revision: Int.max, intentCore: intent(), rules: [], protectedComponents: [], neverRules: [], lastChangeReceiptID: .init(rawValue: "receipt.max"), updatedAt: now)
    let rule = try DesignRule(id: .init(rawValue: "rule.a"), category: .motion, statement: "A", protection: .advisory, provenance: prov(.modelSuggestion, "receipt.model"))
    #expect(throws: ForgeDesignValidationError.revisionOverflow) {
        _ = try DesignDNAEditor().applying(.upsertRule(rule), to: base, projectID: project, changeReceiptID: .init(rawValue: "receipt.next"), acceptedAt: now.addingTimeInterval(2))
    }
}

@Test func durableInputsAreBoundedAndControlCanonicalized() throws {
    #expect(throws: ForgeDesignValidationError.self) { _ = try IntentCore(productPromise: String(repeating: "x", count: ForgeDesignLimits.maximumProductPromiseUTF8Bytes + 1), traits: []) }
    #expect(throws: ForgeDesignValidationError.invalidControlCharacter("provenance.receiptID")) { _ = try DesignProvenance(kind: .userDecision, receiptID: .init(rawValue: "receipt\nforged"), recordedAt: now) }
    #expect(throws: ForgeDesignValidationError.archiveTooLarge(ForgeDesignLimits.maximumArchiveSnapshots + 1)) { _ = try DesignDNAArchive(snapshots: Array(repeating: try seed(), count: ForgeDesignLimits.maximumArchiveSnapshots + 1)) }
}

@Test func archiveRejectsProtectedRuleMutationWithoutDurableUserRecord() throws {
    let protectedID = DesignRuleID(rawValue: "rule.protected")
    let original = try DesignRule(
        id: protectedID,
        category: .motion,
        statement: "Direct response",
        protection: .protected,
        provenance: prov(.acceptedRuntimeCapture, "receipt.runtime.original")
    )
    let first = try seed(rules: [original])
    let replacement = try DesignRule(
        id: protectedID,
        category: .motion,
        statement: "Slow floating motion",
        protection: .protected,
        provenance: prov(.acceptedRuntimeCapture, "receipt.runtime.forged")
    )
    let second = try DesignDNA(
        projectID: project,
        revision: 2,
        intentCore: first.intentCore,
        rules: [replacement],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: .init(rawValue: "receipt.change.2"),
        updatedAt: now.addingTimeInterval(2)
    )
    let forgedRecord = try DesignDNAChangeRecord(
        projectID: project,
        fromRevision: 1,
        toRevision: 2,
        kind: .updateRule(protectedID),
        changeReceiptID: second.lastChangeReceiptID,
        provenance: replacement.provenance,
        acceptedAt: second.updatedAt
    )

    #expect(throws: ForgeDesignValidationError.protectedRuleMutationRequiresUserAuthority(protectedID)) {
        _ = try DesignDNAArchive(snapshots: [first, second], changeRecords: [forgedRecord])
    }

    struct RawArchive: Codable {
        let schemaVersion: Int
        let snapshots: [DesignDNA]
        let changeRecords: [DesignDNAChangeRecord]
    }
    let encoded = try JSONEncoder().encode(
        RawArchive(
            schemaVersion: DesignDNAArchive.currentSchemaVersion,
            snapshots: [first, second],
            changeRecords: [forgedRecord]
        )
    )
    #expect(throws: ForgeDesignValidationError.protectedRuleMutationRequiresUserAuthority(protectedID)) {
        _ = try JSONDecoder().decode(DesignDNAArchive.self, from: encoded)
    }
}

@Test func archiveRejectsProtectedRemovalWithoutDurableUserRecord() throws {
    let protectedID = DesignRuleID(rawValue: "rule.remove")
    let original = try DesignRule(
        id: protectedID,
        category: .spacing,
        statement: "Keep the 8-point rhythm",
        protection: .protected,
        provenance: prov(.acceptedSourceCheckpoint, "receipt.source.original")
    )
    let first = try seed(rules: [original])
    let second = try DesignDNA(
        projectID: project,
        revision: 2,
        intentCore: first.intentCore,
        rules: [],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: .init(rawValue: "receipt.change.remove"),
        updatedAt: now.addingTimeInterval(2)
    )
    let forgedRecord = try DesignDNAChangeRecord(
        projectID: project,
        fromRevision: 1,
        toRevision: 2,
        kind: .removeRule(protectedID),
        changeReceiptID: second.lastChangeReceiptID,
        provenance: prov(.acceptedRuntimeCapture, "receipt.runtime.no-user"),
        acceptedAt: second.updatedAt
    )

    #expect(throws: ForgeDesignValidationError.userAuthorityRequired("removeRule")) {
        _ = try DesignDNAArchive(snapshots: [first, second], changeRecords: [forgedRecord])
    }
}

@Test func archiveRoundTripPreservesExactDurableTransitionRecord() throws {
    let first = try seed()
    let rule = try DesignRule(
        id: .init(rawValue: "rule.roundtrip"),
        category: .interaction,
        statement: "Keep the primary action obvious",
        protection: .advisory,
        provenance: prov(.acceptedSourceCheckpoint, "receipt.source.roundtrip")
    )
    let candidate = try DesignDNAEditor().candidateApplying(
        .upsertRule(rule),
        to: first,
        projectID: project,
        changeReceiptID: .init(rawValue: "receipt.roundtrip.2"),
        acceptedAt: now.addingTimeInterval(2)
    )
    let archive = try DesignDNAArchive(
        snapshots: [first, candidate.snapshot],
        changeRecords: [candidate.changeRecord]
    )
    let decoded = try JSONDecoder().decode(
        DesignDNAArchive.self,
        from: JSONEncoder().encode(archive)
    )
    #expect(decoded == archive)
    #expect(decoded.changeRecords == [candidate.changeRecord])
}

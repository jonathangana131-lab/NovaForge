import Foundation
import Testing
@testable import ForgeDesignCore

private let securityNow = Date(timeIntervalSince1970: 1_800_000_300)
private let securityProjectID = DesignProjectID(rawValue: "project.design-security")

private func securityProvenance(
    _ kind: DesignProvenanceKind,
    _ id: String
) throws -> DesignProvenance {
    try DesignProvenance(
        kind: kind,
        receiptID: DesignReceiptID(rawValue: id),
        recordedAt: securityNow
    )
}

private func securityIntent(_ promise: String = "A game") throws -> IntentCore {
    try IntentCore(productPromise: promise, traits: ["Fast"])
}

private func securitySeed(
    revision: Int = 1,
    rules: [DesignRule] = [],
    neverRules: [NeverRule] = []
) throws -> DesignDNA {
    try DesignDNA(
        projectID: securityProjectID,
        revision: revision,
        intentCore: securityIntent(),
        rules: rules,
        protectedComponents: [],
        neverRules: neverRules,
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.\(revision)"),
        updatedAt: securityNow.addingTimeInterval(Double(revision))
    )
}

@Test func forgedUserDecisionCannotProtectWithoutNonCodableAuthority() throws {
    let editor = DesignDNAEditor()
    let base = try securitySeed()
    let rule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.motion"),
        category: .motion,
        statement: "Direct springs",
        protection: .protected,
        provenance: securityProvenance(.userDecision, "receipt.user")
    )

    #expect(throws: ForgeDesignValidationError.authenticatedUserAuthorityRequired("protectRule")) {
        _ = try editor.applying(
            .upsertRule(rule),
            to: base,
            projectID: securityProjectID,
            changeReceiptID: DesignReceiptID(rawValue: "receipt.change"),
            acceptedAt: securityNow.addingTimeInterval(2)
        )
    }

    let candidate = try editor.candidateApplying(
        .upsertRule(rule),
        to: base,
        projectID: securityProjectID,
        changeReceiptID: DesignReceiptID(rawValue: "receipt.change"),
        acceptedAt: securityNow.addingTimeInterval(2)
    )
    let purpose = try #require(candidate.requiredUserAuthority)
    let authority = DesignDNAUserMutationAuthority(
        authenticatedBefore: base,
        authenticatedAfter: candidate.snapshot,
        purpose: purpose
    )
    let accepted = try editor.applying(
        .upsertRule(rule),
        to: base,
        projectID: securityProjectID,
        changeReceiptID: DesignReceiptID(rawValue: "receipt.change"),
        acceptedAt: securityNow.addingTimeInterval(2),
        userAuthority: authority
    )
    #expect(accepted == candidate.snapshot)
}

@Test func authorityIsExactBeforeAfterAndPurposeBound() throws {
    let editor = DesignDNAEditor()
    let base = try securitySeed()
    let one = try DesignRule(
        id: DesignRuleID(rawValue: "rule.one"),
        category: .motion,
        statement: "One",
        protection: .protected,
        provenance: securityProvenance(.userDecision, "receipt.user.one")
    )
    let two = try DesignRule(
        id: DesignRuleID(rawValue: "rule.two"),
        category: .motion,
        statement: "Two",
        protection: .protected,
        provenance: securityProvenance(.userDecision, "receipt.user.two")
    )
    let firstCandidate = try editor.candidateApplying(
        .upsertRule(one),
        to: base,
        projectID: securityProjectID,
        changeReceiptID: DesignReceiptID(rawValue: "receipt.change.one"),
        acceptedAt: securityNow.addingTimeInterval(2)
    )
    let authority = DesignDNAUserMutationAuthority(
        authenticatedBefore: base,
        authenticatedAfter: firstCandidate.snapshot,
        purpose: try #require(firstCandidate.requiredUserAuthority)
    )

    #expect(throws: ForgeDesignValidationError.authenticatedUserAuthorityRequired("protectRule")) {
        _ = try editor.applying(
            .upsertRule(two),
            to: base,
            projectID: securityProjectID,
            changeReceiptID: DesignReceiptID(rawValue: "receipt.change.two"),
            acceptedAt: securityNow.addingTimeInterval(2),
            userAuthority: authority
        )
    }
}

@Test func archiveRejectsRevisionOnlyAndMultiMutationTransitions() throws {
    let first = try securitySeed()
    let revisionOnly = try DesignDNA(
        projectID: securityProjectID,
        revision: 2,
        intentCore: first.intentCore,
        rules: [],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.2"),
        updatedAt: securityNow.addingTimeInterval(2)
    )
    #expect(throws: ForgeDesignValidationError.self) {
        _ = try DesignDNAArchive(snapshots: [first, revisionOnly])
    }

    let firstRule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.1"),
        category: .motion,
        statement: "One",
        protection: .advisory,
        provenance: securityProvenance(.modelSuggestion, "receipt.model.1")
    )
    let secondRule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.2"),
        category: .spacing,
        statement: "Two",
        protection: .advisory,
        provenance: securityProvenance(.modelSuggestion, "receipt.model.2")
    )
    let multiMutation = try DesignDNA(
        projectID: securityProjectID,
        revision: 2,
        intentCore: first.intentCore,
        rules: [firstRule, secondRule],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.multi"),
        updatedAt: securityNow.addingTimeInterval(2)
    )
    #expect(throws: ForgeDesignValidationError.self) {
        _ = try DesignDNAArchive(snapshots: [first, multiMutation])
    }
}

@Test func archiveRejectsReusedReceiptAndBackdatedTransition() throws {
    let first = try securitySeed()
    let rule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.archive"),
        category: .motion,
        statement: "Direct",
        protection: .advisory,
        provenance: securityProvenance(.modelSuggestion, "receipt.model")
    )

    let reusedReceipt = try DesignDNA(
        projectID: securityProjectID,
        revision: 2,
        intentCore: first.intentCore,
        rules: [rule],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: first.lastChangeReceiptID,
        updatedAt: first.updatedAt.addingTimeInterval(1)
    )
    #expect(throws: ForgeDesignValidationError.invalidArchiveTransition("transition must carry a distinct change receipt")) {
        _ = try DesignDNAArchive(snapshots: [first, reusedReceipt])
    }

    let backdated = try DesignDNA(
        projectID: securityProjectID,
        revision: 2,
        intentCore: first.intentCore,
        rules: [rule],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.backdated"),
        updatedAt: first.updatedAt.addingTimeInterval(-1)
    )
    #expect(throws: ForgeDesignValidationError.invalidArchiveTransition("transition timestamp moved backwards")) {
        _ = try DesignDNAArchive(snapshots: [first, backdated])
    }
}

@Test func acceptedArchiveRequiresWholeSnapshotAndTransitionTrust() throws {
    let editor = DesignDNAEditor()
    let first = try securitySeed()
    let rule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.advisory"),
        category: .motion,
        statement: "Try direct springs",
        protection: .advisory,
        provenance: securityProvenance(.modelSuggestion, "receipt.model")
    )
    let second = try editor.applying(
        .upsertRule(rule),
        to: first,
        projectID: securityProjectID,
        changeReceiptID: DesignReceiptID(rawValue: "receipt.2"),
        acceptedAt: first.updatedAt.addingTimeInterval(1)
    )
    let archive = try DesignDNAArchive(snapshots: [first, second])
    let firstTrust = DesignDNATrustBinding(authenticatedSnapshot: first)
    let secondTrust = DesignDNATrustBinding(authenticatedSnapshot: second)

    #expect(!archive.canSupportAcceptedDesignHistory(
        trustedSnapshots: [firstTrust, secondTrust],
        trustedTransitions: []
    ))

    let kind = try DesignDNAArchive.validatedTransitionKind(from: first, to: second)
    let transition = try DesignDNATransitionTrustBinding(
        authenticatedBefore: first,
        authenticatedAfter: second,
        kind: kind
    )
    #expect(archive.canSupportAcceptedDesignHistory(
        trustedSnapshots: [firstTrust, secondTrust],
        trustedTransitions: [transition]
    ))
    #expect(!(try DesignDNAArchive(snapshots: [])).canSupportAcceptedDesignHistory(
        trustedSnapshots: [],
        trustedTransitions: []
    ))
}

@Test func revisionOverflowFailsClosed() throws {
    let base = try DesignDNA(
        projectID: securityProjectID,
        revision: Int.max,
        intentCore: securityIntent(),
        rules: [],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.max"),
        updatedAt: securityNow
    )
    let rule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.a"),
        category: .motion,
        statement: "A",
        protection: .advisory,
        provenance: securityProvenance(.modelSuggestion, "receipt.model")
    )
    #expect(throws: ForgeDesignValidationError.revisionOverflow) {
        _ = try DesignDNAEditor().applying(
            .upsertRule(rule),
            to: base,
            projectID: securityProjectID,
            changeReceiptID: DesignReceiptID(rawValue: "receipt.next"),
            acceptedAt: securityNow
        )
    }
}

@Test func durableInputsAreBoundedAndControlCanonicalized() throws {
    #expect(throws: ForgeDesignValidationError.self) {
        _ = try IntentCore(
            productPromise: String(repeating: "x", count: ForgeDesignLimits.maximumProductPromiseUTF8Bytes + 1),
            traits: []
        )
    }
    #expect(throws: ForgeDesignValidationError.invalidControlCharacter("provenance.receiptID")) {
        _ = try DesignProvenance(
            kind: .userDecision,
            receiptID: DesignReceiptID(rawValue: "receipt\nforged"),
            recordedAt: securityNow
        )
    }
    #expect(throws: ForgeDesignValidationError.archiveTooLarge(ForgeDesignLimits.maximumArchiveSnapshots + 1)) {
        _ = try DesignDNAArchive(
            snapshots: Array(repeating: try securitySeed(), count: ForgeDesignLimits.maximumArchiveSnapshots + 1)
        )
    }
}

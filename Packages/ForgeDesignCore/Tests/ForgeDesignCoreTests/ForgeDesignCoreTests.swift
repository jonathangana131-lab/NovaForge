import Foundation
import Testing
@testable import ForgeDesignCore

let coreNow = Date(timeIntervalSince1970: 1_800_000_000)
let coreProjectID = DesignProjectID(rawValue: "project.neon-racer")

func coreProvenance(_ kind: DesignProvenanceKind, _ id: String) throws -> DesignProvenance {
    try DesignProvenance(kind: kind, receiptID: DesignReceiptID(rawValue: id), recordedAt: coreNow)
}

func coreIntent() throws -> IntentCore {
    try IntentCore(productPromise: "Fast touch-first driving game", traits: ["Dark", "Fast", "Landscape", "No clutter"])
}

func coreSeedDNA() throws -> DesignDNA {
    try DesignDNA(
        projectID: coreProjectID,
        revision: 1,
        intentCore: coreIntent(),
        rules: [],
        protectedComponents: [],
        neverRules: [],
        lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.seed"),
        updatedAt: coreNow
    )
}

func applyWithUserAuthority(
    _ change: DesignDNAChange,
    to current: DesignDNA,
    receiptID: String,
    acceptedAt: Date
) throws -> DesignDNA {
    let editor = DesignDNAEditor()
    let candidate = try editor.candidateApplying(
        change,
        to: current,
        projectID: current.projectID,
        changeReceiptID: DesignReceiptID(rawValue: receiptID),
        acceptedAt: acceptedAt
    )
    let purpose = try #require(candidate.requiredUserAuthority)
    let authority = DesignDNAUserMutationAuthority(
        authenticatedBefore: current,
        authenticatedAfter: candidate.snapshot,
        authenticatedRecord: candidate.changeRecord,
        purpose: purpose
    )
    return try editor.applying(
        change,
        to: current,
        projectID: current.projectID,
        changeReceiptID: DesignReceiptID(rawValue: receiptID),
        acceptedAt: acceptedAt,
        userAuthority: authority
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
        provenance: coreProvenance(.modelSuggestion, "receipt.model")
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
            provenance: coreProvenance(.modelSuggestion, "receipt.model")
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
            provenance: coreProvenance(.importedReference, "receipt.reference")
        )
    }
}

@Test func acceptedRuntimeCaptureMayProtectComponentCandidate() throws {
    let component = try ProtectedDesignComponent(
        id: ProtectedDesignComponentID(rawValue: "component.speedometer"),
        name: "Speedometer",
        stableSourceIdentity: "HUD/Speedometer",
        reason: "Accepted after runtime inspection",
        provenance: coreProvenance(.acceptedRuntimeCapture, "receipt.runtime")
    )
    #expect(component.name == "Speedometer")
}

@Test func neverRuleRequiresExplicitUserDecisionMetadata() throws {
    let id = NeverRuleID(rawValue: "never.purple")
    #expect(throws: ForgeDesignValidationError.neverRuleRequiresUserDecision(id)) {
        _ = try NeverRule(
            id: id,
            instruction: "Do not use generic AI purple gradients",
            scope: .project,
            provenance: coreProvenance(.modelSuggestion, "receipt.model")
        )
    }
}

@Test func neverRuleNormalizesScopedText() throws {
    let rule = try NeverRule(
        id: NeverRuleID(rawValue: "never.toolbar"),
        instruction: "Do not add permanent toolbar clutter",
        scope: .surface("  Forge  "),
        provenance: coreProvenance(.userDecision, "receipt.user")
    )
    #expect(rule.scope == .surface("Forge"))
}

@Test func duplicateIDsFailClosed() throws {
    let rule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.spacing"),
        category: .spacing,
        statement: "Use an 8-point rhythm",
        protection: .advisory,
        provenance: coreProvenance(.acceptedSourceCheckpoint, "receipt.source")
    )
    #expect(throws: ForgeDesignValidationError.duplicateRuleID(rule.id)) {
        _ = try DesignDNA(
            projectID: coreProjectID,
            revision: 1,
            intentCore: coreIntent(),
            rules: [rule, rule],
            protectedComponents: [],
            neverRules: [],
            lastChangeReceiptID: DesignReceiptID(rawValue: "receipt.seed"),
            updatedAt: coreNow
        )
    }
}

@Test func editorUpsertsProtectedRuleOnlyWithAuthenticatedAuthority() throws {
    let current = try coreSeedDNA()
    let rule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.material"),
        category: .materials,
        statement: "Focused surfaces use restrained elevated glass",
        protection: .protected,
        provenance: coreProvenance(.userDecision, "receipt.user")
    )

    #expect(throws: ForgeDesignValidationError.authenticatedUserAuthorityRequired("protectRule")) {
        _ = try DesignDNAEditor().applying(
            .upsertRule(rule),
            to: current,
            projectID: coreProjectID,
            changeReceiptID: DesignReceiptID(rawValue: "receipt.change.2"),
            acceptedAt: coreNow.addingTimeInterval(1)
        )
    }

    let revised = try applyWithUserAuthority(
        .upsertRule(rule),
        to: current,
        receiptID: "receipt.change.2",
        acceptedAt: coreNow.addingTimeInterval(1)
    )
    #expect(revised.revision == 2)
    #expect(revised.rules == [rule])
}

@Test func editorRejectsWrongProjectIdentity() throws {
    let current = try coreSeedDNA()
    let rule = try DesignRule(
        id: DesignRuleID(rawValue: "rule.spacing"),
        category: .spacing,
        statement: "Use an 8-point rhythm",
        protection: .advisory,
        provenance: coreProvenance(.acceptedSourceCheckpoint, "receipt.source")
    )
    #expect(throws: ForgeDesignValidationError.projectIdentityMismatch) {
        _ = try DesignDNAEditor().applying(
            .upsertRule(rule),
            to: current,
            projectID: DesignProjectID(rawValue: "project.other"),
            changeReceiptID: DesignReceiptID(rawValue: "receipt.change"),
            acceptedAt: coreNow
        )
    }
}

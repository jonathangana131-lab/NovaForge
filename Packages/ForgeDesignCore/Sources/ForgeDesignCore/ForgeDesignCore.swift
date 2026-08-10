import Foundation

public enum ForgeDesignValidationError: Error, Equatable, Sendable {
    case blankIdentifier(String)
    case blankText(String)
    case identifierTooLong(String, Int)
    case textTooLong(String, Int)
    case invalidControlCharacter(String)
    case invalidRevision(Int)
    case revisionOverflow
    case invalidTimestamp(String)
    case duplicateRuleID(DesignRuleID)
    case duplicateProtectedComponentID(ProtectedDesignComponentID)
    case duplicateNeverRuleID(NeverRuleID)
    case tooManyIntentTraits(Int)
    case tooManyRules(Int)
    case tooManyProtectedComponents(Int)
    case tooManyNeverRules(Int)
    case duplicateIntentTrait(String)
    case provenanceCannotProtectRule(DesignRuleID)
    case provenanceCannotProtectComponent(ProtectedDesignComponentID)
    case protectedRuleMutationRequiresUserAuthority(DesignRuleID)
    case protectedComponentMutationRequiresUserAuthority(ProtectedDesignComponentID)
    case neverRuleRequiresUserDecision(NeverRuleID)
    case userAuthorityRequired(String)
    case authenticatedUserAuthorityRequired(String)
    case projectIdentityMismatch
    case revisionMustAdvance
    case archiveTooLarge(Int)
    case invalidArchiveTransition(String)
    case unsupportedSchemaVersion(Int)
}

public enum ForgeDesignLimits {
    public static let maximumIdentifierUTF8Bytes = 192
    public static let maximumProductPromiseUTF8Bytes = 2_048
    public static let maximumTextUTF8Bytes = 4_096
    public static let maximumTraitUTF8Bytes = 256
    public static let maximumRules = 256
    public static let maximumProtectedComponents = 128
    public static let maximumNeverRules = 128
    public static let maximumArchiveSnapshots = 512
}

public protocol ForgeDesignOpaqueID: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    init(rawValue: String)
}

private func canonicalString(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
}

private func containsDisallowedControl(_ value: String, allowLineBreaks: Bool) -> Bool {
    value.unicodeScalars.contains { scalar in
        guard CharacterSet.controlCharacters.contains(scalar) else { return false }
        if allowLineBreaks && (scalar.value == 0x09 || scalar.value == 0x0A) { return false }
        return true
    }
}

private func validatedIdentifier<T: ForgeDesignOpaqueID>(_ value: T, field: String) throws -> T {
    let trimmed = canonicalString(value.rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !trimmed.isEmpty else { throw ForgeDesignValidationError.blankIdentifier(field) }
    guard trimmed.utf8.count <= ForgeDesignLimits.maximumIdentifierUTF8Bytes else {
        throw ForgeDesignValidationError.identifierTooLong(field, trimmed.utf8.count)
    }
    guard !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
        throw ForgeDesignValidationError.invalidControlCharacter(field)
    }
    return T(rawValue: trimmed)
}

private func validatedText(
    _ value: String,
    field: String,
    maximumUTF8Bytes: Int = ForgeDesignLimits.maximumTextUTF8Bytes,
    allowLineBreaks: Bool = true
) throws -> String {
    let trimmed = canonicalString(value.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !trimmed.isEmpty else { throw ForgeDesignValidationError.blankText(field) }
    guard trimmed.utf8.count <= maximumUTF8Bytes else {
        throw ForgeDesignValidationError.textTooLong(field, trimmed.utf8.count)
    }
    guard !containsDisallowedControl(trimmed, allowLineBreaks: allowLineBreaks) else {
        throw ForgeDesignValidationError.invalidControlCharacter(field)
    }
    return trimmed
}

private func validatedDate(_ value: Date, field: String) throws -> Date {
    guard value.timeIntervalSinceReferenceDate.isFinite else {
        throw ForgeDesignValidationError.invalidTimestamp(field)
    }
    return value
}

public struct DesignProjectID: ForgeDesignOpaqueID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct DesignRuleID: ForgeDesignOpaqueID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct ProtectedDesignComponentID: ForgeDesignOpaqueID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct NeverRuleID: ForgeDesignOpaqueID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }
public struct DesignReceiptID: ForgeDesignOpaqueID { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }

public enum DesignProvenanceKind: String, Codable, CaseIterable, Sendable {
    case userDecision, acceptedSourceCheckpoint, acceptedRuntimeCapture, importedReference, modelSuggestion
    public var isUserAuthority: Bool { self == .userDecision }
    public var mayProtectAcceptedDesign: Bool {
        switch self {
        case .userDecision, .acceptedSourceCheckpoint, .acceptedRuntimeCapture: true
        case .importedReference, .modelSuggestion: false
        }
    }
}

public struct DesignProvenance: Codable, Equatable, Hashable, Sendable {
    public let kind: DesignProvenanceKind
    public let receiptID: DesignReceiptID
    public let recordedAt: Date
    public init(kind: DesignProvenanceKind, receiptID: DesignReceiptID, recordedAt: Date) throws {
        self.kind = kind
        self.receiptID = try validatedIdentifier(receiptID, field: "provenance.receiptID")
        self.recordedAt = try validatedDate(recordedAt, field: "provenance.recordedAt")
    }
}

public struct IntentCore: Codable, Equatable, Sendable {
    public static let maximumTraits = 12
    public let productPromise: String
    public let traits: [String]
    public init(productPromise: String, traits: [String]) throws {
        self.productPromise = try validatedText(productPromise, field: "intent.productPromise", maximumUTF8Bytes: ForgeDesignLimits.maximumProductPromiseUTF8Bytes)
        guard traits.count <= Self.maximumTraits else { throw ForgeDesignValidationError.tooManyIntentTraits(traits.count) }
        var seen = Set<String>()
        var normalized: [String] = []
        normalized.reserveCapacity(traits.count)
        for trait in traits {
            let value = try validatedText(trait, field: "intent.trait", maximumUTF8Bytes: ForgeDesignLimits.maximumTraitUTF8Bytes, allowLineBreaks: false)
            let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(key).inserted else { throw ForgeDesignValidationError.duplicateIntentTrait(value) }
            normalized.append(value)
        }
        self.traits = normalized
    }
}

public enum DesignRuleCategory: String, Codable, CaseIterable, Sendable { case typography, spacing, corners, materials, iconography, accent, motion, interaction, layout, accessibility, other }
public enum DesignRuleProtection: String, Codable, CaseIterable, Sendable { case advisory, protected }

public struct DesignRule: Codable, Equatable, Sendable {
    public let id: DesignRuleID
    public let category: DesignRuleCategory
    public let statement: String
    public let protection: DesignRuleProtection
    public let provenance: DesignProvenance
    public init(id: DesignRuleID, category: DesignRuleCategory, statement: String, protection: DesignRuleProtection, provenance: DesignProvenance) throws {
        self.id = try validatedIdentifier(id, field: "rule.id")
        self.category = category
        self.statement = try validatedText(statement, field: "rule.statement")
        if protection == .protected && !provenance.kind.mayProtectAcceptedDesign { throw ForgeDesignValidationError.provenanceCannotProtectRule(id) }
        self.protection = protection
        self.provenance = provenance
    }
}

public struct ProtectedDesignComponent: Codable, Equatable, Sendable {
    public let id: ProtectedDesignComponentID
    public let name: String
    public let stableSourceIdentity: String
    public let reason: String
    public let provenance: DesignProvenance
    public init(id: ProtectedDesignComponentID, name: String, stableSourceIdentity: String, reason: String, provenance: DesignProvenance) throws {
        self.id = try validatedIdentifier(id, field: "protectedComponent.id")
        self.name = try validatedText(name, field: "protectedComponent.name", maximumUTF8Bytes: 512, allowLineBreaks: false)
        self.stableSourceIdentity = try validatedText(stableSourceIdentity, field: "protectedComponent.stableSourceIdentity", maximumUTF8Bytes: 1_024, allowLineBreaks: false)
        self.reason = try validatedText(reason, field: "protectedComponent.reason")
        guard provenance.kind.mayProtectAcceptedDesign else { throw ForgeDesignValidationError.provenanceCannotProtectComponent(id) }
        self.provenance = provenance
    }
}

public enum NeverRuleScope: Codable, Equatable, Sendable {
    case project
    case surface(String)
    case component(String)
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case project, surface, component }
    public func validated() throws -> Self {
        switch self {
        case .project: self
        case .surface(let value): .surface(try validatedText(value, field: "neverRule.scope.surface", maximumUTF8Bytes: 512, allowLineBreaks: false))
        case .component(let value): .component(try validatedText(value, field: "neverRule.scope.component", maximumUTF8Bytes: 512, allowLineBreaks: false))
        }
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .project: self = .project
        case .surface: self = .surface(try container.decode(String.self, forKey: .value))
        case .component: self = .component(try container.decode(String.self, forKey: .value))
        }
        self = try validated()
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .project: try container.encode(Kind.project, forKey: .kind)
        case .surface(let value): try container.encode(Kind.surface, forKey: .kind); try container.encode(value, forKey: .value)
        case .component(let value): try container.encode(Kind.component, forKey: .kind); try container.encode(value, forKey: .value)
        }
    }
}

public struct NeverRule: Codable, Equatable, Sendable {
    public let id: NeverRuleID
    public let instruction: String
    public let scope: NeverRuleScope
    public let provenance: DesignProvenance
    public init(id: NeverRuleID, instruction: String, scope: NeverRuleScope, provenance: DesignProvenance) throws {
        self.id = try validatedIdentifier(id, field: "neverRule.id")
        self.instruction = try validatedText(instruction, field: "neverRule.instruction")
        self.scope = try scope.validated()
        guard provenance.kind.isUserAuthority else { throw ForgeDesignValidationError.neverRuleRequiresUserDecision(id) }
        self.provenance = provenance
    }
}

public struct DesignDNA: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let projectID: DesignProjectID
    public let revision: Int
    public let intentCore: IntentCore
    public let rules: [DesignRule]
    public let protectedComponents: [ProtectedDesignComponent]
    public let neverRules: [NeverRule]
    public let lastChangeReceiptID: DesignReceiptID
    public let updatedAt: Date
    public init(schemaVersion: Int = Self.currentSchemaVersion, projectID: DesignProjectID, revision: Int, intentCore: IntentCore, rules: [DesignRule], protectedComponents: [ProtectedDesignComponent], neverRules: [NeverRule], lastChangeReceiptID: DesignReceiptID, updatedAt: Date) throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw ForgeDesignValidationError.unsupportedSchemaVersion(schemaVersion) }
        guard revision > 0 else { throw ForgeDesignValidationError.invalidRevision(revision) }
        guard rules.count <= ForgeDesignLimits.maximumRules else { throw ForgeDesignValidationError.tooManyRules(rules.count) }
        guard protectedComponents.count <= ForgeDesignLimits.maximumProtectedComponents else { throw ForgeDesignValidationError.tooManyProtectedComponents(protectedComponents.count) }
        guard neverRules.count <= ForgeDesignLimits.maximumNeverRules else { throw ForgeDesignValidationError.tooManyNeverRules(neverRules.count) }
        self.schemaVersion = schemaVersion
        self.projectID = try validatedIdentifier(projectID, field: "designDNA.projectID")
        self.revision = revision
        self.intentCore = intentCore
        self.lastChangeReceiptID = try validatedIdentifier(lastChangeReceiptID, field: "designDNA.lastChangeReceiptID")
        self.updatedAt = try validatedDate(updatedAt, field: "designDNA.updatedAt")
        try Self.validateUniqueIDs(rules: rules, protectedComponents: protectedComponents, neverRules: neverRules)
        self.rules = rules.sorted { $0.id.rawValue < $1.id.rawValue }
        self.protectedComponents = protectedComponents.sorted { $0.id.rawValue < $1.id.rawValue }
        self.neverRules = neverRules.sorted { $0.id.rawValue < $1.id.rawValue }
    }
    static func validateUniqueIDs(rules: [DesignRule], protectedComponents: [ProtectedDesignComponent], neverRules: [NeverRule]) throws {
        var ruleIDs = Set<DesignRuleID>(); for rule in rules where !ruleIDs.insert(rule.id).inserted { throw ForgeDesignValidationError.duplicateRuleID(rule.id) }
        var componentIDs = Set<ProtectedDesignComponentID>(); for component in protectedComponents where !componentIDs.insert(component.id).inserted { throw ForgeDesignValidationError.duplicateProtectedComponentID(component.id) }
        var neverIDs = Set<NeverRuleID>(); for rule in neverRules where !neverIDs.insert(rule.id).inserted { throw ForgeDesignValidationError.duplicateNeverRuleID(rule.id) }
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(schemaVersion: container.decode(Int.self, forKey: .schemaVersion), projectID: container.decode(DesignProjectID.self, forKey: .projectID), revision: container.decode(Int.self, forKey: .revision), intentCore: container.decode(IntentCore.self, forKey: .intentCore), rules: container.decode([DesignRule].self, forKey: .rules), protectedComponents: container.decode([ProtectedDesignComponent].self, forKey: .protectedComponents), neverRules: container.decode([NeverRule].self, forKey: .neverRules), lastChangeReceiptID: container.decode(DesignReceiptID.self, forKey: .lastChangeReceiptID), updatedAt: container.decode(Date.self, forKey: .updatedAt))
    }
}

public enum DesignDNAChange: Sendable {
    case replaceIntentCore(IntentCore, provenance: DesignProvenance)
    case upsertRule(DesignRule)
    case removeRule(DesignRuleID, authorization: DesignProvenance)
    case protectComponent(ProtectedDesignComponent)
    case unprotectComponent(ProtectedDesignComponentID, authorization: DesignProvenance)
    case addNeverRule(NeverRule)
    case removeNeverRule(NeverRuleID, authorization: DesignProvenance)
}

public enum DesignDNAUserMutationPurpose: Equatable, Sendable {
    case replaceIntentCore
    case protectRule(DesignRuleID)
    case mutateProtectedRule(DesignRuleID)
    case removeRule(DesignRuleID)
    case protectComponent(ProtectedDesignComponentID)
    case mutateProtectedComponent(ProtectedDesignComponentID)
    case unprotectComponent(ProtectedDesignComponentID)
    case addNeverRule(NeverRuleID)
    case mutateNeverRule(NeverRuleID)
    case removeNeverRule(NeverRuleID)

    var errorLabel: String {
        switch self {
        case .replaceIntentCore: "replaceIntentCore"
        case .protectRule: "protectRule"
        case .mutateProtectedRule: "mutateProtectedRule"
        case .removeRule: "removeRule"
        case .protectComponent: "protectComponent"
        case .mutateProtectedComponent: "mutateProtectedComponent"
        case .unprotectComponent: "unprotectComponent"
        case .addNeverRule: "addNeverRule"
        case .mutateNeverRule: "mutateNeverRule"
        case .removeNeverRule: "removeNeverRule"
        }
    }
}

public struct DesignDNAEditor: Sendable {
    public init() {}

    public func applying(_ change: DesignDNAChange, to current: DesignDNA, projectID: DesignProjectID, changeReceiptID: DesignReceiptID, acceptedAt: Date, userAuthority: DesignDNAUserMutationAuthority? = nil) throws -> DesignDNA {
        let candidate = try candidateApplying(change, to: current, projectID: projectID, changeReceiptID: changeReceiptID, acceptedAt: acceptedAt)
        if let purpose = candidate.requiredUserAuthority {
            guard let userAuthority, userAuthority.authorizes(before: current, after: candidate.snapshot, purpose: purpose) else {
                throw ForgeDesignValidationError.authenticatedUserAuthorityRequired(purpose.errorLabel)
            }
        }
        return candidate.snapshot
    }

    func candidateApplying(_ change: DesignDNAChange, to current: DesignDNA, projectID: DesignProjectID, changeReceiptID: DesignReceiptID, acceptedAt: Date) throws -> (snapshot: DesignDNA, requiredUserAuthority: DesignDNAUserMutationPurpose?) {
        let validatedProjectID = try validatedIdentifier(projectID, field: "projectID")
        guard current.projectID == validatedProjectID else { throw ForgeDesignValidationError.projectIdentityMismatch }
        let receiptID = try validatedIdentifier(changeReceiptID, field: "changeReceiptID")
        let acceptedAt = try validatedDate(acceptedAt, field: "acceptedAt")
        let (nextRevision, overflow) = current.revision.addingReportingOverflow(1)
        guard !overflow else { throw ForgeDesignValidationError.revisionOverflow }

        var intentCore = current.intentCore
        var rules = current.rules
        var protectedComponents = current.protectedComponents
        var neverRules = current.neverRules
        var required: DesignDNAUserMutationPurpose?

        switch change {
        case .replaceIntentCore(let replacement, let provenance):
            guard provenance.kind.isUserAuthority || provenance.kind == .acceptedSourceCheckpoint else { throw ForgeDesignValidationError.userAuthorityRequired("replaceIntentCore") }
            guard replacement != current.intentCore else { throw ForgeDesignValidationError.invalidArchiveTransition("replaceIntentCore must change durable intent") }
            if provenance.kind.isUserAuthority { required = .replaceIntentCore }
            intentCore = replacement

        case .upsertRule(let rule):
            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                guard rules[index] != rule else { throw ForgeDesignValidationError.invalidArchiveTransition("upsertRule must change durable rule") }
                if rules[index].protection == .protected {
                    guard rule.provenance.kind.isUserAuthority else { throw ForgeDesignValidationError.protectedRuleMutationRequiresUserAuthority(rule.id) }
                    required = .mutateProtectedRule(rule.id)
                } else if rule.protection == .protected && rule.provenance.kind.isUserAuthority {
                    required = .protectRule(rule.id)
                }
                rules[index] = rule
            } else {
                if rule.protection == .protected && rule.provenance.kind.isUserAuthority { required = .protectRule(rule.id) }
                rules.append(rule)
            }

        case .removeRule(let rawID, let authorization):
            guard authorization.kind.isUserAuthority else { throw ForgeDesignValidationError.userAuthorityRequired("removeRule") }
            let id = try validatedIdentifier(rawID, field: "removeRule.id")
            guard rules.contains(where: { $0.id == id }) else { throw ForgeDesignValidationError.invalidArchiveTransition("removeRule must remove an existing rule") }
            rules.removeAll { $0.id == id }
            required = .removeRule(id)

        case .protectComponent(let component):
            if let index = protectedComponents.firstIndex(where: { $0.id == component.id }) {
                guard protectedComponents[index] != component else { throw ForgeDesignValidationError.invalidArchiveTransition("protectComponent must change durable component") }
                guard component.provenance.kind.isUserAuthority else { throw ForgeDesignValidationError.protectedComponentMutationRequiresUserAuthority(component.id) }
                protectedComponents[index] = component
                required = .mutateProtectedComponent(component.id)
            } else {
                protectedComponents.append(component)
                if component.provenance.kind.isUserAuthority { required = .protectComponent(component.id) }
            }

        case .unprotectComponent(let rawID, let authorization):
            guard authorization.kind.isUserAuthority else { throw ForgeDesignValidationError.userAuthorityRequired("unprotectComponent") }
            let id = try validatedIdentifier(rawID, field: "unprotectComponent.id")
            guard protectedComponents.contains(where: { $0.id == id }) else { throw ForgeDesignValidationError.invalidArchiveTransition("unprotectComponent must remove an existing component") }
            protectedComponents.removeAll { $0.id == id }
            required = .unprotectComponent(id)

        case .addNeverRule(let rule):
            if let index = neverRules.firstIndex(where: { $0.id == rule.id }) {
                guard neverRules[index] != rule else { throw ForgeDesignValidationError.invalidArchiveTransition("addNeverRule must change durable rule") }
                neverRules[index] = rule
                required = .mutateNeverRule(rule.id)
            } else {
                neverRules.append(rule)
                required = .addNeverRule(rule.id)
            }

        case .removeNeverRule(let rawID, let authorization):
            guard authorization.kind.isUserAuthority else { throw ForgeDesignValidationError.userAuthorityRequired("removeNeverRule") }
            let id = try validatedIdentifier(rawID, field: "removeNeverRule.id")
            guard neverRules.contains(where: { $0.id == id }) else { throw ForgeDesignValidationError.invalidArchiveTransition("removeNeverRule must remove an existing rule") }
            neverRules.removeAll { $0.id == id }
            required = .removeNeverRule(id)
        }

        let snapshot = try DesignDNA(projectID: current.projectID, revision: nextRevision, intentCore: intentCore, rules: rules, protectedComponents: protectedComponents, neverRules: neverRules, lastChangeReceiptID: receiptID, updatedAt: acceptedAt)
        return (snapshot, required)
    }
}

public enum DesignDNATransitionKind: Equatable, Sendable {
    case replaceIntentCore
    case addRule(DesignRuleID), updateRule(DesignRuleID), removeRule(DesignRuleID)
    case addProtectedComponent(ProtectedDesignComponentID), updateProtectedComponent(ProtectedDesignComponentID), removeProtectedComponent(ProtectedDesignComponentID)
    case addNeverRule(NeverRuleID), updateNeverRule(NeverRuleID), removeNeverRule(NeverRuleID)
}

public struct DesignDNAArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let snapshots: [DesignDNA]
    public init(schemaVersion: Int = Self.currentSchemaVersion, snapshots: [DesignDNA]) throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw ForgeDesignValidationError.unsupportedSchemaVersion(schemaVersion) }
        guard snapshots.count <= ForgeDesignLimits.maximumArchiveSnapshots else { throw ForgeDesignValidationError.archiveTooLarge(snapshots.count) }
        self.schemaVersion = schemaVersion
        guard let first = snapshots.first else { self.snapshots = []; return }
        for snapshot in snapshots where snapshot.projectID != first.projectID { throw ForgeDesignValidationError.projectIdentityMismatch }
        for index in snapshots.indices.dropFirst() { _ = try Self.validatedTransitionKind(from: snapshots[index - 1], to: snapshots[index]) }
        self.snapshots = snapshots
    }
    static func validatedTransitionKind(from before: DesignDNA, to after: DesignDNA) throws -> DesignDNATransitionKind {
        guard before.projectID == after.projectID else { throw ForgeDesignValidationError.projectIdentityMismatch }
        let (expectedRevision, overflow) = before.revision.addingReportingOverflow(1)
        guard !overflow else { throw ForgeDesignValidationError.revisionOverflow }
        guard after.revision == expectedRevision else { throw ForgeDesignValidationError.revisionMustAdvance }
        guard after.updatedAt >= before.updatedAt else {
            throw ForgeDesignValidationError.invalidArchiveTransition("transition timestamp moved backwards")
        }
        guard after.lastChangeReceiptID != before.lastChangeReceiptID else {
            throw ForgeDesignValidationError.invalidArchiveTransition("transition must carry a distinct change receipt")
        }
        var changes: [DesignDNATransitionKind] = []
        if before.intentCore != after.intentCore { changes.append(.replaceIntentCore) }

        func collect<ID: Hashable & Sendable, Value: Equatable>(before: [ID: Value], after: [ID: Value], add: (ID) -> DesignDNATransitionKind, update: (ID) -> DesignDNATransitionKind, remove: (ID) -> DesignDNATransitionKind) {
            let keys = Set(before.keys).union(after.keys)
            for key in keys {
                switch (before[key], after[key]) {
                case (nil, .some): changes.append(add(key))
                case (.some, nil): changes.append(remove(key))
                case let (.some(lhs), .some(rhs)) where lhs != rhs: changes.append(update(key))
                default: break
                }
            }
        }
        collect(before: Dictionary(uniqueKeysWithValues: before.rules.map { ($0.id, $0) }), after: Dictionary(uniqueKeysWithValues: after.rules.map { ($0.id, $0) }), add: DesignDNATransitionKind.addRule, update: DesignDNATransitionKind.updateRule, remove: DesignDNATransitionKind.removeRule)
        collect(before: Dictionary(uniqueKeysWithValues: before.protectedComponents.map { ($0.id, $0) }), after: Dictionary(uniqueKeysWithValues: after.protectedComponents.map { ($0.id, $0) }), add: DesignDNATransitionKind.addProtectedComponent, update: DesignDNATransitionKind.updateProtectedComponent, remove: DesignDNATransitionKind.removeProtectedComponent)
        collect(before: Dictionary(uniqueKeysWithValues: before.neverRules.map { ($0.id, $0) }), after: Dictionary(uniqueKeysWithValues: after.neverRules.map { ($0.id, $0) }), add: DesignDNATransitionKind.addNeverRule, update: DesignDNATransitionKind.updateNeverRule, remove: DesignDNATransitionKind.removeNeverRule)
        guard changes.count == 1, let change = changes.first else { throw ForgeDesignValidationError.invalidArchiveTransition("expected exactly one durable semantic change, found \(changes.count)") }
        return change
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(schemaVersion: container.decode(Int.self, forKey: .schemaVersion), snapshots: container.decode([DesignDNA].self, forKey: .snapshots))
    }
}

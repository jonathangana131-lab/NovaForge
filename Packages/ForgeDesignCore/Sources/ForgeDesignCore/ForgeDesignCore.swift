import Foundation

public enum ForgeDesignValidationError: Error, Equatable, Sendable {
    case blankIdentifier(String)
    case blankText(String)
    case invalidRevision(Int)
    case duplicateRuleID(DesignRuleID)
    case duplicateProtectedComponentID(ProtectedDesignComponentID)
    case duplicateNeverRuleID(NeverRuleID)
    case tooManyIntentTraits(Int)
    case duplicateIntentTrait(String)
    case provenanceCannotProtectRule(DesignRuleID)
    case provenanceCannotProtectComponent(ProtectedDesignComponentID)
    case protectedRuleMutationRequiresUserAuthority(DesignRuleID)
    case protectedComponentMutationRequiresUserAuthority(ProtectedDesignComponentID)
    case neverRuleRequiresUserDecision(NeverRuleID)
    case userAuthorityRequired(String)
    case projectIdentityMismatch
    case revisionMustAdvance
    case unsupportedSchemaVersion(Int)
}

public protocol ForgeDesignOpaqueID: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    init(rawValue: String)
}

private func validatedIdentifier<T: ForgeDesignOpaqueID>(_ value: T, field: String) throws -> T {
    guard !value.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ForgeDesignValidationError.blankIdentifier(field)
    }
    return value
}

private func validatedText(_ value: String, field: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ForgeDesignValidationError.blankText(field)
    }
    return trimmed
}

public struct DesignProjectID: ForgeDesignOpaqueID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct DesignRuleID: ForgeDesignOpaqueID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ProtectedDesignComponentID: ForgeDesignOpaqueID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct NeverRuleID: ForgeDesignOpaqueID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct DesignReceiptID: ForgeDesignOpaqueID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum DesignProvenanceKind: String, Codable, CaseIterable, Sendable {
    case userDecision
    case acceptedSourceCheckpoint
    case acceptedRuntimeCapture
    case importedReference
    case modelSuggestion

    public var isUserAuthority: Bool { self == .userDecision }
    public var mayProtectAcceptedDesign: Bool {
        switch self {
        case .userDecision, .acceptedSourceCheckpoint, .acceptedRuntimeCapture:
            true
        case .importedReference, .modelSuggestion:
            false
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
        self.recordedAt = recordedAt
    }
}

public struct IntentCore: Codable, Equatable, Sendable {
    public static let maximumTraits = 12

    public let productPromise: String
    public let traits: [String]

    public init(productPromise: String, traits: [String]) throws {
        self.productPromise = try validatedText(productPromise, field: "intent.productPromise")
        guard traits.count <= Self.maximumTraits else {
            throw ForgeDesignValidationError.tooManyIntentTraits(traits.count)
        }

        var seen = Set<String>()
        var normalized: [String] = []
        normalized.reserveCapacity(traits.count)
        for trait in traits {
            let value = try validatedText(trait, field: "intent.trait")
            let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(key).inserted else {
                throw ForgeDesignValidationError.duplicateIntentTrait(value)
            }
            normalized.append(value)
        }
        self.traits = normalized
    }
}

public enum DesignRuleCategory: String, Codable, CaseIterable, Sendable {
    case typography
    case spacing
    case corners
    case materials
    case iconography
    case accent
    case motion
    case interaction
    case layout
    case accessibility
    case other
}

public enum DesignRuleProtection: String, Codable, CaseIterable, Sendable {
    case advisory
    case protected
}

public struct DesignRule: Codable, Equatable, Sendable {
    public let id: DesignRuleID
    public let category: DesignRuleCategory
    public let statement: String
    public let protection: DesignRuleProtection
    public let provenance: DesignProvenance

    public init(
        id: DesignRuleID,
        category: DesignRuleCategory,
        statement: String,
        protection: DesignRuleProtection,
        provenance: DesignProvenance
    ) throws {
        self.id = try validatedIdentifier(id, field: "rule.id")
        self.category = category
        self.statement = try validatedText(statement, field: "rule.statement")
        if protection == .protected && !provenance.kind.mayProtectAcceptedDesign {
            throw ForgeDesignValidationError.provenanceCannotProtectRule(id)
        }
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

    public init(
        id: ProtectedDesignComponentID,
        name: String,
        stableSourceIdentity: String,
        reason: String,
        provenance: DesignProvenance
    ) throws {
        self.id = try validatedIdentifier(id, field: "protectedComponent.id")
        self.name = try validatedText(name, field: "protectedComponent.name")
        self.stableSourceIdentity = try validatedText(stableSourceIdentity, field: "protectedComponent.stableSourceIdentity")
        self.reason = try validatedText(reason, field: "protectedComponent.reason")
        guard provenance.kind.mayProtectAcceptedDesign else {
            throw ForgeDesignValidationError.provenanceCannotProtectComponent(id)
        }
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
        case .project:
            return self
        case .surface(let value):
            return .surface(try validatedText(value, field: "neverRule.scope.surface"))
        case .component(let value):
            return .component(try validatedText(value, field: "neverRule.scope.component"))
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .project:
            self = .project
        case .surface:
            self = .surface(try container.decode(String.self, forKey: .value))
        case .component:
            self = .component(try container.decode(String.self, forKey: .value))
        }
        self = try validated()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .project:
            try container.encode(Kind.project, forKey: .kind)
        case .surface(let value):
            try container.encode(Kind.surface, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .component(let value):
            try container.encode(Kind.component, forKey: .kind)
            try container.encode(value, forKey: .value)
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
        guard provenance.kind.isUserAuthority else {
            throw ForgeDesignValidationError.neverRuleRequiresUserDecision(id)
        }
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

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        projectID: DesignProjectID,
        revision: Int,
        intentCore: IntentCore,
        rules: [DesignRule],
        protectedComponents: [ProtectedDesignComponent],
        neverRules: [NeverRule],
        lastChangeReceiptID: DesignReceiptID,
        updatedAt: Date
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeDesignValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.projectID = try validatedIdentifier(projectID, field: "designDNA.projectID")
        guard revision > 0 else { throw ForgeDesignValidationError.invalidRevision(revision) }
        self.revision = revision
        self.intentCore = intentCore
        self.rules = rules
        self.protectedComponents = protectedComponents
        self.neverRules = neverRules
        self.lastChangeReceiptID = try validatedIdentifier(lastChangeReceiptID, field: "designDNA.lastChangeReceiptID")
        self.updatedAt = updatedAt
        try Self.validateUniqueIDs(rules: rules, protectedComponents: protectedComponents, neverRules: neverRules)
    }

    private static func validateUniqueIDs(
        rules: [DesignRule],
        protectedComponents: [ProtectedDesignComponent],
        neverRules: [NeverRule]
    ) throws {
        var ruleIDs = Set<DesignRuleID>()
        for rule in rules where !ruleIDs.insert(rule.id).inserted {
            throw ForgeDesignValidationError.duplicateRuleID(rule.id)
        }

        var componentIDs = Set<ProtectedDesignComponentID>()
        for component in protectedComponents where !componentIDs.insert(component.id).inserted {
            throw ForgeDesignValidationError.duplicateProtectedComponentID(component.id)
        }

        var neverIDs = Set<NeverRuleID>()
        for rule in neverRules where !neverIDs.insert(rule.id).inserted {
            throw ForgeDesignValidationError.duplicateNeverRuleID(rule.id)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            projectID: container.decode(DesignProjectID.self, forKey: .projectID),
            revision: container.decode(Int.self, forKey: .revision),
            intentCore: container.decode(IntentCore.self, forKey: .intentCore),
            rules: container.decode([DesignRule].self, forKey: .rules),
            protectedComponents: container.decode([ProtectedDesignComponent].self, forKey: .protectedComponents),
            neverRules: container.decode([NeverRule].self, forKey: .neverRules),
            lastChangeReceiptID: container.decode(DesignReceiptID.self, forKey: .lastChangeReceiptID),
            updatedAt: container.decode(Date.self, forKey: .updatedAt)
        )
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

public struct DesignDNAEditor: Sendable {
    public init() {}

    public func applying(
        _ change: DesignDNAChange,
        to current: DesignDNA,
        projectID: DesignProjectID,
        changeReceiptID: DesignReceiptID,
        acceptedAt: Date
    ) throws -> DesignDNA {
        guard current.projectID == projectID else { throw ForgeDesignValidationError.projectIdentityMismatch }
        _ = try validatedIdentifier(changeReceiptID, field: "changeReceiptID")

        var intentCore = current.intentCore
        var rules = current.rules
        var protectedComponents = current.protectedComponents
        var neverRules = current.neverRules

        switch change {
        case .replaceIntentCore(let replacement, let provenance):
            guard provenance.kind.isUserAuthority || provenance.kind == .acceptedSourceCheckpoint else {
                throw ForgeDesignValidationError.userAuthorityRequired("replaceIntentCore")
            }
            intentCore = replacement

        case .upsertRule(let rule):
            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                if rules[index].protection == .protected && !rule.provenance.kind.isUserAuthority {
                    throw ForgeDesignValidationError.protectedRuleMutationRequiresUserAuthority(rule.id)
                }
                rules[index] = rule
            } else {
                rules.append(rule)
            }

        case .removeRule(let id, let authorization):
            guard authorization.kind.isUserAuthority else {
                throw ForgeDesignValidationError.userAuthorityRequired("removeRule")
            }
            rules.removeAll { $0.id == id }

        case .protectComponent(let component):
            if let index = protectedComponents.firstIndex(where: { $0.id == component.id }) {
                if !component.provenance.kind.isUserAuthority {
                    throw ForgeDesignValidationError.protectedComponentMutationRequiresUserAuthority(component.id)
                }
                protectedComponents[index] = component
            } else {
                protectedComponents.append(component)
            }

        case .unprotectComponent(let id, let authorization):
            guard authorization.kind.isUserAuthority else {
                throw ForgeDesignValidationError.userAuthorityRequired("unprotectComponent")
            }
            protectedComponents.removeAll { $0.id == id }

        case .addNeverRule(let rule):
            if let index = neverRules.firstIndex(where: { $0.id == rule.id }) {
                neverRules[index] = rule
            } else {
                neverRules.append(rule)
            }

        case .removeNeverRule(let id, let authorization):
            guard authorization.kind.isUserAuthority else {
                throw ForgeDesignValidationError.userAuthorityRequired("removeNeverRule")
            }
            neverRules.removeAll { $0.id == id }
        }

        return try DesignDNA(
            projectID: current.projectID,
            revision: current.revision + 1,
            intentCore: intentCore,
            rules: rules.sorted { $0.id.rawValue < $1.id.rawValue },
            protectedComponents: protectedComponents.sorted { $0.id.rawValue < $1.id.rawValue },
            neverRules: neverRules.sorted { $0.id.rawValue < $1.id.rawValue },
            lastChangeReceiptID: changeReceiptID,
            updatedAt: acceptedAt
        )
    }
}

public struct DesignDNAArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let snapshots: [DesignDNA]

    public init(schemaVersion: Int = Self.currentSchemaVersion, snapshots: [DesignDNA]) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeDesignValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        guard let first = snapshots.first else {
            self.snapshots = []
            return
        }

        var previousRevision = 0
        for snapshot in snapshots {
            guard snapshot.projectID == first.projectID else {
                throw ForgeDesignValidationError.projectIdentityMismatch
            }
            guard snapshot.revision > previousRevision else {
                throw ForgeDesignValidationError.revisionMustAdvance
            }
            previousRevision = snapshot.revision
        }
        self.snapshots = snapshots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            snapshots: container.decode([DesignDNA].self, forKey: .snapshots)
        )
    }
}

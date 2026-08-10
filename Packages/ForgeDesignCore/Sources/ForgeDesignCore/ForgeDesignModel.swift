import Foundation

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

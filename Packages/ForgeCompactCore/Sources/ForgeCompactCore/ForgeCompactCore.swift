import Foundation

public enum ForgeCompactError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidText(field: String)
    case invalidProvenanceReference
    case invalidEstimatedTokenCost
    case invalidFactCount
    case duplicateFactID(String)
    case missingRequiredFact(CapsuleFactKind)
    case duplicateSingletonFact(CapsuleFactKind)
    case invalidTier(kind: CapsuleFactKind, expected: ContextTier)
    case invalidPriorityForColdArchive
    case unsupportedSchemaVersion(Int)
    case invalidCapsuleRevision
    case invalidContextBudget
    case mandatoryContextExceedsBudget(required: Int, available: Int)
}

private enum ForgeCompactValidation {
    static func validateIdentifier(_ value: String, field: String, maxLength: Int = 180) throws -> String {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= maxLength,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgeCompactError.invalidIdentifier(field: field)
        }
        return value
    }

    static func validateText(_ value: String, field: String, maxLength: Int = 8_192) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              value.count <= maxLength,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value == 0x0A || scalar.value == 0x09 || !CharacterSet.controlCharacters.contains(scalar)
              }) else {
            throw ForgeCompactError.invalidText(field: field)
        }
        return value
    }
}

public enum ContextTier: String, Codable, CaseIterable, Sendable {
    case alwaysResident
    case activeWorkingSet
    case projectMemory
    case coldArchive

    fileprivate var rank: Int {
        switch self {
        case .alwaysResident: 0
        case .activeWorkingSet: 1
        case .projectMemory: 2
        case .coldArchive: 3
        }
    }
}

public enum CapsuleFactPriority: String, Codable, CaseIterable, Sendable {
    case critical
    case high
    case normal
    case low

    fileprivate var rank: Int {
        switch self {
        case .critical: 0
        case .high: 1
        case .normal: 2
        case .low: 3
        }
    }
}

public enum CapsuleFactKind: String, Codable, CaseIterable, Sendable {
    case missionIdentity
    case currentObjective
    case currentStage
    case privacyPolicy
    case requirement
    case acceptedDecision
    case designDNA
    case sourceReference
    case testReceipt
    case runtimeReceipt
    case knownDefect
    case unresolvedDecision
    case knownLimitation
    case workingNote

    fileprivate var requiredTier: ContextTier? {
        switch self {
        case .missionIdentity, .currentObjective, .currentStage, .privacyPolicy, .unresolvedDecision:
            return .alwaysResident
        default:
            return nil
        }
    }

    fileprivate var isSingleton: Bool {
        switch self {
        case .missionIdentity, .currentObjective, .currentStage, .privacyPolicy:
            return true
        default:
            return false
        }
    }

    fileprivate var rank: Int {
        switch self {
        case .missionIdentity: 0
        case .currentObjective: 1
        case .currentStage: 2
        case .privacyPolicy: 3
        case .unresolvedDecision: 4
        case .requirement: 5
        case .acceptedDecision: 6
        case .designDNA: 7
        case .sourceReference: 8
        case .knownDefect: 9
        case .testReceipt: 10
        case .runtimeReceipt: 11
        case .knownLimitation: 12
        case .workingNote: 13
        }
    }
}

public enum CapsuleFactProvenance: Codable, Equatable, Sendable {
    case userDecision(reference: String)
    case sourceRevision(reference: String)
    case runtimeReceipt(reference: String)
    case testReceipt(reference: String)
    case checkpoint(reference: String)
    case missionAuthority(reference: String)

    fileprivate var reference: String {
        switch self {
        case let .userDecision(reference),
             let .sourceRevision(reference),
             let .runtimeReceipt(reference),
             let .testReceipt(reference),
             let .checkpoint(reference),
             let .missionAuthority(reference):
            reference
        }
    }

    fileprivate func validated() throws -> CapsuleFactProvenance {
        do {
            _ = try ForgeCompactValidation.validateIdentifier(reference, field: "provenanceReference", maxLength: 240)
            return self
        } catch {
            throw ForgeCompactError.invalidProvenanceReference
        }
    }
}

public struct CapsuleFact: Codable, Equatable, Sendable {
    public let id: String
    public let kind: CapsuleFactKind
    public let tier: ContextTier
    public let priority: CapsuleFactPriority
    public let text: String
    public let estimatedTokenCost: Int
    public let provenance: CapsuleFactProvenance

    public init(
        id: String,
        kind: CapsuleFactKind,
        tier: ContextTier,
        priority: CapsuleFactPriority,
        text: String,
        estimatedTokenCost: Int,
        provenance: CapsuleFactProvenance
    ) throws {
        self.id = try ForgeCompactValidation.validateIdentifier(id, field: "factID")
        self.kind = kind
        self.tier = tier
        self.priority = priority
        self.text = try ForgeCompactValidation.validateText(text, field: "factText")
        guard (1...32_768).contains(estimatedTokenCost) else {
            throw ForgeCompactError.invalidEstimatedTokenCost
        }
        self.estimatedTokenCost = estimatedTokenCost
        self.provenance = try provenance.validated()

        if let requiredTier = kind.requiredTier, tier != requiredTier {
            throw ForgeCompactError.invalidTier(kind: kind, expected: requiredTier)
        }
        if tier == .coldArchive, priority == .critical {
            throw ForgeCompactError.invalidPriorityForColdArchive
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, tier, priority, text, estimatedTokenCost, provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            kind: container.decode(CapsuleFactKind.self, forKey: .kind),
            tier: container.decode(ContextTier.self, forKey: .tier),
            priority: container.decode(CapsuleFactPriority.self, forKey: .priority),
            text: container.decode(String.self, forKey: .text),
            estimatedTokenCost: container.decode(Int.self, forKey: .estimatedTokenCost),
            provenance: container.decode(CapsuleFactProvenance.self, forKey: .provenance)
        )
    }
}

public struct ProjectCapsule: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumFactCount = 512
    public static let maximumEstimatedTokenCost = 1_000_000

    public let schemaVersion: Int
    public let projectID: String
    public let missionID: String
    public let sourceRevision: String
    public let capsuleRevision: UInt64
    public let facts: [CapsuleFact]

    public var estimatedTokenCost: Int {
        facts.reduce(into: 0) { $0 += $1.estimatedTokenCost }
    }

    public init(
        projectID: String,
        missionID: String,
        sourceRevision: String,
        capsuleRevision: UInt64,
        facts: [CapsuleFact],
        schemaVersion: Int = ProjectCapsule.currentSchemaVersion
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompactError.unsupportedSchemaVersion(schemaVersion)
        }
        guard capsuleRevision > 0 else {
            throw ForgeCompactError.invalidCapsuleRevision
        }
        guard !facts.isEmpty, facts.count <= Self.maximumFactCount else {
            throw ForgeCompactError.invalidFactCount
        }

        self.schemaVersion = schemaVersion
        self.projectID = try ForgeCompactValidation.validateIdentifier(projectID, field: "projectID")
        self.missionID = try ForgeCompactValidation.validateIdentifier(missionID, field: "missionID")
        self.sourceRevision = try ForgeCompactValidation.validateIdentifier(sourceRevision, field: "sourceRevision")
        self.capsuleRevision = capsuleRevision

        var seenIDs = Set<String>()
        var singletonCounts: [CapsuleFactKind: Int] = [:]
        var totalEstimatedTokens = 0

        for fact in facts {
            guard seenIDs.insert(fact.id).inserted else {
                throw ForgeCompactError.duplicateFactID(fact.id)
            }
            totalEstimatedTokens += fact.estimatedTokenCost
            if fact.kind.isSingleton {
                singletonCounts[fact.kind, default: 0] += 1
            }
        }

        guard totalEstimatedTokens <= Self.maximumEstimatedTokenCost else {
            throw ForgeCompactError.invalidEstimatedTokenCost
        }

        for requiredKind in [CapsuleFactKind.missionIdentity, .currentObjective, .currentStage] {
            let count = singletonCounts[requiredKind, default: 0]
            guard count > 0 else {
                throw ForgeCompactError.missingRequiredFact(requiredKind)
            }
            guard count == 1 else {
                throw ForgeCompactError.duplicateSingletonFact(requiredKind)
            }
        }

        if singletonCounts[.privacyPolicy, default: 0] > 1 {
            throw ForgeCompactError.duplicateSingletonFact(.privacyPolicy)
        }

        self.facts = Self.canonicalize(facts)
    }

    private static func canonicalize(_ facts: [CapsuleFact]) -> [CapsuleFact] {
        facts.sorted { lhs, rhs in
            if lhs.tier.rank != rhs.tier.rank { return lhs.tier.rank < rhs.tier.rank }
            if lhs.priority.rank != rhs.priority.rank { return lhs.priority.rank < rhs.priority.rank }
            if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank < rhs.kind.rank }
            return lhs.id < rhs.id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projectID, missionID, sourceRevision, capsuleRevision, facts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            missionID: container.decode(String.self, forKey: .missionID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            capsuleRevision: container.decode(UInt64.self, forKey: .capsuleRevision),
            facts: container.decode([CapsuleFact].self, forKey: .facts),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion)
        )
    }
}

public struct ContextBudget: Codable, Equatable, Sendable {
    public let maximumPromptTokens: Int
    public let reservedOutputTokens: Int

    public var availableContextTokens: Int {
        maximumPromptTokens - reservedOutputTokens
    }

    public init(maximumPromptTokens: Int, reservedOutputTokens: Int) throws {
        guard (256...1_000_000).contains(maximumPromptTokens),
              reservedOutputTokens >= 0,
              reservedOutputTokens < maximumPromptTokens else {
            throw ForgeCompactError.invalidContextBudget
        }
        self.maximumPromptTokens = maximumPromptTokens
        self.reservedOutputTokens = reservedOutputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case maximumPromptTokens, reservedOutputTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumPromptTokens: container.decode(Int.self, forKey: .maximumPromptTokens),
            reservedOutputTokens: container.decode(Int.self, forKey: .reservedOutputTokens)
        )
    }
}

public struct ContextSelection: Equatable, Sendable {
    public let projectID: String
    public let missionID: String
    public let sourceRevision: String
    public let capsuleRevision: UInt64
    public let budget: ContextBudget
    public let selectedFacts: [CapsuleFact]
    public let omittedFactIDs: [String]
    public let usedEstimatedTokens: Int

    public var remainingEstimatedTokens: Int {
        budget.availableContextTokens - usedEstimatedTokens
    }
}

public enum ForgeCompactSelector {
    /// Deterministically selects the smallest active context that honors all L0 facts.
    /// L0 never silently truncates. Optional facts are considered by tier, priority, then stable ID.
    public static func select(from capsule: ProjectCapsule, budget: ContextBudget) throws -> ContextSelection {
        let mandatory = capsule.facts.filter { $0.tier == .alwaysResident }
        let mandatoryCost = mandatory.reduce(into: 0) { $0 += $1.estimatedTokenCost }
        guard mandatoryCost <= budget.availableContextTokens else {
            throw ForgeCompactError.mandatoryContextExceedsBudget(
                required: mandatoryCost,
                available: budget.availableContextTokens
            )
        }

        let optional = capsule.facts.filter { $0.tier != .alwaysResident }.sorted { lhs, rhs in
            if lhs.tier.rank != rhs.tier.rank { return lhs.tier.rank < rhs.tier.rank }
            if lhs.priority.rank != rhs.priority.rank { return lhs.priority.rank < rhs.priority.rank }
            if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank < rhs.kind.rank }
            return lhs.id < rhs.id
        }

        var selected = mandatory
        var omitted: [String] = []
        var used = mandatoryCost

        for fact in optional {
            if used + fact.estimatedTokenCost <= budget.availableContextTokens {
                selected.append(fact)
                used += fact.estimatedTokenCost
            } else {
                omitted.append(fact.id)
            }
        }

        selected.sort { lhs, rhs in
            if lhs.tier.rank != rhs.tier.rank { return lhs.tier.rank < rhs.tier.rank }
            if lhs.priority.rank != rhs.priority.rank { return lhs.priority.rank < rhs.priority.rank }
            if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank < rhs.kind.rank }
            return lhs.id < rhs.id
        }

        return ContextSelection(
            projectID: capsule.projectID,
            missionID: capsule.missionID,
            sourceRevision: capsule.sourceRevision,
            capsuleRevision: capsule.capsuleRevision,
            budget: budget,
            selectedFacts: selected,
            omittedFactIDs: omitted.sorted(),
            usedEstimatedTokens: used
        )
    }
}

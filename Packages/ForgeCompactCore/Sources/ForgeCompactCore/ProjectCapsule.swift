import Foundation

public enum ProjectCapsuleOmissionReason: String, Codable, Sendable {
    case tokenBudget
    case factCountBudget
    case coldArchive
}

public struct ProjectCapsuleOmission: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let kind: ProjectCapsuleFactKind
    public let estimatedTokens: Int
    public let reason: ProjectCapsuleOmissionReason

    public init(id: String, kind: ProjectCapsuleFactKind, estimatedTokens: Int, reason: ProjectCapsuleOmissionReason) throws {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ForgeCompactError.blankFactID }
        guard estimatedTokens > 0 else { throw ForgeCompactError.invalidTokenEstimate(id: normalized) }
        self.id = normalized
        self.kind = kind
        self.estimatedTokens = estimatedTokens
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case id, kind, estimatedTokens, reason }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            kind: container.decode(ProjectCapsuleFactKind.self, forKey: .kind),
            estimatedTokens: container.decode(Int.self, forKey: .estimatedTokens),
            reason: container.decode(ProjectCapsuleOmissionReason.self, forKey: .reason)
        )
    }
}

public struct ProjectCapsule: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let identity: ProjectCapsuleIdentity
    public let budget: ProjectCapsuleBudget
    public let facts: [ProjectCapsuleFact]
    public let omissions: [ProjectCapsuleOmission]
    public let estimatedTokens: Int

    fileprivate init(
        identity: ProjectCapsuleIdentity,
        budget: ProjectCapsuleBudget,
        facts: [ProjectCapsuleFact],
        omissions: [ProjectCapsuleOmission]
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.identity = identity
        self.budget = budget
        self.facts = facts
        self.omissions = omissions
        self.estimatedTokens = facts.reduce(0) { $0 + $1.estimatedTokens }
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, identity, budget, facts, omissions, estimatedTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        identity = try container.decode(ProjectCapsuleIdentity.self, forKey: .identity)
        budget = try container.decode(ProjectCapsuleBudget.self, forKey: .budget)
        facts = try container.decode([ProjectCapsuleFact].self, forKey: .facts)
        omissions = try container.decode([ProjectCapsuleOmission].self, forKey: .omissions)
        estimatedTokens = try container.decode(Int.self, forKey: .estimatedTokens)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(identity, forKey: .identity)
        try container.encode(budget, forKey: .budget)
        try container.encode(facts, forKey: .facts)
        try container.encode(omissions, forKey: .omissions)
        try container.encode(estimatedTokens, forKey: .estimatedTokens)
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompactError.archiveSchema(schemaVersion)
        }
        guard estimatedTokens == facts.reduce(0, { $0 + $1.estimatedTokens }) else {
            throw ForgeCompactError.archiveTokenTotalMismatch
        }
        guard estimatedTokens <= budget.availableCapsuleTokens, facts.count <= budget.maxFactCount else {
            throw ForgeCompactError.archiveBudgetMismatch
        }

        var seen = Set<String>()
        for fact in facts {
            guard seen.insert(fact.id).inserted else {
                throw ForgeCompactError.archiveContainsDuplicateFact(fact.id)
            }
        }
        for omission in omissions {
            guard seen.insert(omission.id).inserted else {
                throw ForgeCompactError.archiveContainsDuplicateFact(omission.id)
            }
            if omission.kind.isProtectedTruth {
                throw ForgeCompactError.archiveOmittedProtectedTruth(omission.id)
            }
        }

        let sorted = facts.sorted(by: Self.selectionOrder)
        guard sorted == facts else { throw ForgeCompactError.archiveSelectionOrder }
    }

    fileprivate static func selectionOrder(_ lhs: ProjectCapsuleFact, _ rhs: ProjectCapsuleFact) -> Bool {
        if lhs.kind.isProtectedTruth != rhs.kind.isProtectedTruth {
            return lhs.kind.isProtectedTruth && !rhs.kind.isProtectedTruth
        }
        if lhs.layer != rhs.layer { return lhs.layer < rhs.layer }
        if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
        if lhs.estimatedTokens != rhs.estimatedTokens { return lhs.estimatedTokens < rhs.estimatedTokens }
        return lhs.id < rhs.id
    }
}

public enum ProjectCapsulePlanner {
    public static func build(
        identity: ProjectCapsuleIdentity,
        budget: ProjectCapsuleBudget,
        candidates: [ProjectCapsuleFact]
    ) throws -> ProjectCapsule {
        var seen = Set<String>()
        for fact in candidates {
            guard seen.insert(fact.id).inserted else { throw ForgeCompactError.duplicateFactID(fact.id) }
        }

        let protectedFacts = candidates
            .filter(\.kind.isProtectedTruth)
            .sorted(by: ProjectCapsule.selectionOrder)
        let requiredTokens = protectedFacts.reduce(0) { $0 + $1.estimatedTokens }
        guard requiredTokens <= budget.availableCapsuleTokens else {
            throw ForgeCompactError.requiredTruthExceedsBudget(
                required: requiredTokens,
                available: budget.availableCapsuleTokens
            )
        }
        guard protectedFacts.count <= budget.maxFactCount else {
            throw ForgeCompactError.requiredTruthExceedsFactCount(
                required: protectedFacts.count,
                available: budget.maxFactCount
            )
        }

        var selected = protectedFacts
        var selectedIDs = Set(protectedFacts.map(\.id))
        var usedTokens = requiredTokens

        let optional = candidates
            .filter { !selectedIDs.contains($0.id) }
            .sorted(by: ProjectCapsule.selectionOrder)

        var omissions: [ProjectCapsuleOmission] = []
        for fact in optional {
            if fact.layer == .l2ProjectMemory, fact.relevance == 0 {
                omissions.append(try .init(id: fact.id, kind: fact.kind, estimatedTokens: fact.estimatedTokens, reason: .coldArchive))
                continue
            }
            guard selected.count < budget.maxFactCount else {
                omissions.append(try .init(id: fact.id, kind: fact.kind, estimatedTokens: fact.estimatedTokens, reason: .factCountBudget))
                continue
            }
            guard usedTokens + fact.estimatedTokens <= budget.availableCapsuleTokens else {
                omissions.append(try .init(id: fact.id, kind: fact.kind, estimatedTokens: fact.estimatedTokens, reason: .tokenBudget))
                continue
            }
            selected.append(fact)
            selectedIDs.insert(fact.id)
            usedTokens += fact.estimatedTokens
        }

        selected.sort(by: ProjectCapsule.selectionOrder)
        omissions.sort {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.id < $1.id
        }
        return try ProjectCapsule(identity: identity, budget: budget, facts: selected, omissions: omissions)
    }
}

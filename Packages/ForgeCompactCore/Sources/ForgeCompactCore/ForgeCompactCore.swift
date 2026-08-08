import Foundation

public enum ForgeCompactError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidText(String)
    case invalidRevision
    case invalidBudget
    case invalidCost
    case duplicateEntryID(String)
    case crossProjectEntry(entryID: String)
    case requiredEntryIneligible(entryID: String, reason: ForgeCompactOmissionReason)
    case requiredBudgetExceeded(requiredUnits: Int, maximumUnits: Int)
    case unsupportedSchema(Int)
}

public enum ForgeCompactEntryKind: String, Codable, CaseIterable, Sendable {
    case requirement
    case currentObjective
    case relevantSource
    case acceptedDecision
    case designDNA
    case evidenceReceipt
    case knownDefect
    case unresolvedDecision
    case missionStage
    case conciseSummary
}

public enum ForgeCompactPriority: Int, Codable, Comparable, Sendable {
    case low = 0
    case normal = 1
    case high = 2
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ForgeCompactInclusion: String, Codable, Sendable {
    case required
    case preferred
    case optional
}

public enum ForgeCompactFreshness: String, Codable, Sendable {
    case current
    case stale
    case unknown
}

public enum ForgeCompactAuthority: String, Codable, Sendable {
    case userAccepted
    case sourceBacked
    case checkpointAccepted
    case runtimeEvidence
    case testEvidence
    case modelObservation

    public var isAcceptedTruth: Bool {
        switch self {
        case .userAccepted, .sourceBacked, .checkpointAccepted, .runtimeEvidence, .testEvidence:
            true
        case .modelObservation:
            false
        }
    }
}

public enum ForgeCompactCostBasis: Codable, Equatable, Sendable {
    case exactTokenizer(tokenizerID: String, tokenizerRevision: String)
    case heuristic(name: String)

    public var isExact: Bool {
        if case .exactTokenizer = self { return true }
        return false
    }
}

public struct ForgeCompactContextCost: Codable, Equatable, Sendable {
    public let units: Int
    public let basis: ForgeCompactCostBasis

    public init(units: Int, basis: ForgeCompactCostBasis) throws {
        guard units > 0 else { throw ForgeCompactError.invalidCost }
        switch basis {
        case let .exactTokenizer(tokenizerID, tokenizerRevision):
            guard Self.isValidIdentifier(tokenizerID), Self.isValidIdentifier(tokenizerRevision) else {
                throw ForgeCompactError.invalidCost
            }
        case let .heuristic(name):
            guard Self.isValidIdentifier(name) else { throw ForgeCompactError.invalidCost }
        }
        self.units = units
        self.basis = basis
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 160 && !trimmed.contains(where: { $0.isNewline })
    }
}

public struct ForgeCompactSourceReference: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case userDecision
        case repositoryFile
        case runtimeReceipt
        case testReceipt
        case checkpoint
        case projectBrainFact
        case modelOutput
    }

    public let kind: Kind
    public let locator: String
    public let revision: String

    public init(kind: Kind, locator: String, revision: String) throws {
        guard Self.valid(locator) else { throw ForgeCompactError.invalidIdentifier(locator) }
        guard Self.valid(revision) else { throw ForgeCompactError.invalidRevision }
        self.kind = kind
        self.locator = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        self.revision = revision.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func valid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 512 && !trimmed.contains(where: { $0.isNewline })
    }
}

public struct ForgeCompactEntry: Codable, Equatable, Sendable {
    public let id: String
    public let projectID: String
    public let kind: ForgeCompactEntryKind
    public let text: String
    public let priority: ForgeCompactPriority
    public let inclusion: ForgeCompactInclusion
    public let freshness: ForgeCompactFreshness
    public let authority: ForgeCompactAuthority
    public let source: ForgeCompactSourceReference
    public let cost: ForgeCompactContextCost

    public init(
        id: String,
        projectID: String,
        kind: ForgeCompactEntryKind,
        text: String,
        priority: ForgeCompactPriority = .normal,
        inclusion: ForgeCompactInclusion = .optional,
        freshness: ForgeCompactFreshness = .current,
        authority: ForgeCompactAuthority,
        source: ForgeCompactSourceReference,
        cost: ForgeCompactContextCost
    ) throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validID(normalizedID) else { throw ForgeCompactError.invalidIdentifier(id) }
        guard Self.validID(normalizedProjectID) else { throw ForgeCompactError.invalidIdentifier(projectID) }
        guard !normalizedText.isEmpty, normalizedText.count <= 16_384 else {
            throw ForgeCompactError.invalidText(id)
        }
        self.id = normalizedID
        self.projectID = normalizedProjectID
        self.kind = kind
        self.text = normalizedText
        self.priority = priority
        self.inclusion = inclusion
        self.freshness = freshness
        self.authority = authority
        self.source = source
        self.cost = cost
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160 && !value.contains(where: { $0.isWhitespace || $0.isNewline })
    }
}

public struct ForgeCompactPolicy: Codable, Equatable, Sendable {
    public let maximumUnits: Int
    public let requireExactCost: Bool

    public init(maximumUnits: Int, requireExactCost: Bool = false) throws {
        guard maximumUnits > 0 else { throw ForgeCompactError.invalidBudget }
        self.maximumUnits = maximumUnits
        self.requireExactCost = requireExactCost
    }
}

public enum ForgeCompactOmissionReason: String, Codable, Equatable, Sendable {
    case stale
    case freshnessUnknown
    case nonAuthoritative
    case estimatedCostDisallowed
    case budget
}

public struct ForgeCompactOmission: Codable, Equatable, Sendable {
    public let entryID: String
    public let reason: ForgeCompactOmissionReason
}

public enum ForgeCompactCostTruth: String, Codable, Equatable, Sendable {
    case exact
    case includesEstimates
}

public struct ForgeCompactReceipt: Codable, Equatable, Sendable {
    public let maximumUnits: Int
    public let selectedUnits: Int
    public let selectedEntryIDs: [String]
    public let omissions: [ForgeCompactOmission]
    public let costTruth: ForgeCompactCostTruth
}

public struct ProjectCapsule: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let projectID: String
    public let missionID: String
    public let authorityRevision: Int
    public let entries: [ForgeCompactEntry]
    public let receipt: ForgeCompactReceipt

    public init(
        projectID: String,
        missionID: String,
        authorityRevision: Int,
        entries: [ForgeCompactEntry],
        receipt: ForgeCompactReceipt
    ) throws {
        try Self.validate(
            schemaVersion: Self.currentSchemaVersion,
            projectID: projectID,
            missionID: missionID,
            authorityRevision: authorityRevision,
            entries: entries,
            receipt: receipt
        )
        self.schemaVersion = Self.currentSchemaVersion
        self.projectID = projectID
        self.missionID = missionID
        self.authorityRevision = authorityRevision
        self.entries = entries
        self.receipt = receipt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projectID, missionID, authorityRevision, entries, receipt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let projectID = try container.decode(String.self, forKey: .projectID)
        let missionID = try container.decode(String.self, forKey: .missionID)
        let authorityRevision = try container.decode(Int.self, forKey: .authorityRevision)
        let entries = try container.decode([ForgeCompactEntry].self, forKey: .entries)
        let receipt = try container.decode(ForgeCompactReceipt.self, forKey: .receipt)
        try Self.validate(
            schemaVersion: schemaVersion,
            projectID: projectID,
            missionID: missionID,
            authorityRevision: authorityRevision,
            entries: entries,
            receipt: receipt
        )
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.missionID = missionID
        self.authorityRevision = authorityRevision
        self.entries = entries
        self.receipt = receipt
    }

    private static func validate(
        schemaVersion: Int,
        projectID: String,
        missionID: String,
        authorityRevision: Int,
        entries: [ForgeCompactEntry],
        receipt: ForgeCompactReceipt
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompactError.unsupportedSchema(schemaVersion)
        }
        guard validID(projectID) else { throw ForgeCompactError.invalidIdentifier(projectID) }
        guard validID(missionID) else { throw ForgeCompactError.invalidIdentifier(missionID) }
        guard authorityRevision >= 0 else { throw ForgeCompactError.invalidRevision }
        guard receipt.maximumUnits > 0, receipt.selectedUnits >= 0, receipt.selectedUnits <= receipt.maximumUnits else {
            throw ForgeCompactError.invalidBudget
        }

        var seen = Set<String>()
        var selectedUnits = 0
        var includesEstimate = false
        for entry in entries {
            guard entry.projectID == projectID else {
                throw ForgeCompactError.crossProjectEntry(entryID: entry.id)
            }
            guard seen.insert(entry.id).inserted else {
                throw ForgeCompactError.duplicateEntryID(entry.id)
            }
            guard entry.freshness == .current else {
                let reason: ForgeCompactOmissionReason = entry.freshness == .stale ? .stale : .freshnessUnknown
                throw ForgeCompactError.requiredEntryIneligible(entryID: entry.id, reason: reason)
            }
            guard entry.authority.isAcceptedTruth else {
                throw ForgeCompactError.requiredEntryIneligible(entryID: entry.id, reason: .nonAuthoritative)
            }
            selectedUnits += entry.cost.units
            includesEstimate = includesEstimate || !entry.cost.basis.isExact
        }

        guard selectedUnits == receipt.selectedUnits else { throw ForgeCompactError.invalidCost }
        guard entries.map(\.id) == receipt.selectedEntryIDs else { throw ForgeCompactError.invalidRevision }
        let expectedTruth: ForgeCompactCostTruth = includesEstimate ? .includesEstimates : .exact
        guard receipt.costTruth == expectedTruth else { throw ForgeCompactError.invalidCost }

        let omittedIDs = receipt.omissions.map(\.entryID)
        guard Set(omittedIDs).count == omittedIDs.count,
              Set(omittedIDs).isDisjoint(with: seen) else {
            throw ForgeCompactError.duplicateEntryID(omittedIDs.first ?? "omission")
        }
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160 && !value.contains(where: { $0.isWhitespace || $0.isNewline })
    }
}

public enum ForgeCompactPlanner {
    public static func build(
        projectID: String,
        missionID: String,
        authorityRevision: Int,
        entries: [ForgeCompactEntry],
        policy: ForgeCompactPolicy
    ) throws -> ProjectCapsule {
        guard authorityRevision >= 0 else { throw ForgeCompactError.invalidRevision }
        let normalizedProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMissionID = missionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validID(normalizedProjectID) else { throw ForgeCompactError.invalidIdentifier(projectID) }
        guard validID(normalizedMissionID) else { throw ForgeCompactError.invalidIdentifier(missionID) }

        var seen = Set<String>()
        for entry in entries {
            guard seen.insert(entry.id).inserted else { throw ForgeCompactError.duplicateEntryID(entry.id) }
            guard entry.projectID == normalizedProjectID else {
                throw ForgeCompactError.crossProjectEntry(entryID: entry.id)
            }
        }

        var eligible: [ForgeCompactEntry] = []
        var omissions: [ForgeCompactOmission] = []

        for entry in entries {
            if let reason = ineligibilityReason(entry, policy: policy) {
                if entry.inclusion == .required {
                    throw ForgeCompactError.requiredEntryIneligible(entryID: entry.id, reason: reason)
                }
                omissions.append(.init(entryID: entry.id, reason: reason))
            } else {
                eligible.append(entry)
            }
        }

        let required = eligible.filter { $0.inclusion == .required }.sorted(by: stableOrdering)
        let requiredUnits = required.reduce(0) { $0 + $1.cost.units }
        guard requiredUnits <= policy.maximumUnits else {
            throw ForgeCompactError.requiredBudgetExceeded(
                requiredUnits: requiredUnits,
                maximumUnits: policy.maximumUnits
            )
        }

        var selected = required
        var selectedUnits = requiredUnits

        let candidates = eligible
            .filter { $0.inclusion != .required }
            .sorted(by: candidateOrdering)

        for entry in candidates {
            if selectedUnits + entry.cost.units <= policy.maximumUnits {
                selected.append(entry)
                selectedUnits += entry.cost.units
            } else {
                omissions.append(.init(entryID: entry.id, reason: .budget))
            }
        }

        selected.sort(by: outputOrdering)
        omissions.sort {
            if $0.entryID != $1.entryID { return $0.entryID < $1.entryID }
            return $0.reason.rawValue < $1.reason.rawValue
        }

        let costTruth: ForgeCompactCostTruth = selected.allSatisfy { $0.cost.basis.isExact } ? .exact : .includesEstimates
        let receipt = ForgeCompactReceipt(
            maximumUnits: policy.maximumUnits,
            selectedUnits: selectedUnits,
            selectedEntryIDs: selected.map(\.id),
            omissions: omissions,
            costTruth: costTruth
        )

        return try ProjectCapsule(
            projectID: normalizedProjectID,
            missionID: normalizedMissionID,
            authorityRevision: authorityRevision,
            entries: selected,
            receipt: receipt
        )
    }

    private static func ineligibilityReason(
        _ entry: ForgeCompactEntry,
        policy: ForgeCompactPolicy
    ) -> ForgeCompactOmissionReason? {
        switch entry.freshness {
        case .stale: return .stale
        case .unknown: return .freshnessUnknown
        case .current: break
        }
        guard entry.authority.isAcceptedTruth else { return .nonAuthoritative }
        if policy.requireExactCost && !entry.cost.basis.isExact {
            return .estimatedCostDisallowed
        }
        return nil
    }

    private static func candidateOrdering(_ lhs: ForgeCompactEntry, _ rhs: ForgeCompactEntry) -> Bool {
        if lhs.inclusion != rhs.inclusion {
            return lhs.inclusion == .preferred
        }
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        if lhs.cost.units != rhs.cost.units {
            return lhs.cost.units < rhs.cost.units
        }
        return lhs.id < rhs.id
    }

    private static func stableOrdering(_ lhs: ForgeCompactEntry, _ rhs: ForgeCompactEntry) -> Bool {
        lhs.id < rhs.id
    }

    private static func outputOrdering(_ lhs: ForgeCompactEntry, _ rhs: ForgeCompactEntry) -> Bool {
        if lhs.inclusion != rhs.inclusion {
            let rank: [ForgeCompactInclusion: Int] = [.required: 0, .preferred: 1, .optional: 2]
            return rank[lhs.inclusion, default: 3] < rank[rhs.inclusion, default: 3]
        }
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.id < rhs.id
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160 && !value.contains(where: { $0.isWhitespace || $0.isNewline })
    }
}

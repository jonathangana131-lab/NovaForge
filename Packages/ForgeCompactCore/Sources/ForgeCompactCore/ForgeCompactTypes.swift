import Foundation

public enum ForgeCompactError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidContent
    case invalidPriority(Int)
    case invalidRevision(field: String, value: Int)
    case invalidBudget(Int)
    case duplicateItemID(String)
    case sourceRevisionMismatch(itemID: String)
    case modelSummaryCannotBeAuthoritative(itemID: String)
    case modelSummaryCannotSupplyMandatoryTruth(itemID: String)
    case staleMandatoryTruth(itemID: String)
    case budgetCannotHoldMandatoryTruth(requiredBytes: Int, budgetBytes: Int)
    case invalidCapsuleSchema(Int)
    case invalidArchiveSchema(Int)
    case invalidCapsuleShape
    case archiveIdentityMismatch
    case archiveRevisionRegression
    case invalidCacheIdentity(field: String)
}

enum ForgeCompactValidation {
    static func identifier(_ value: String, field: String, maxUTF8Bytes: Int = 256) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == trimmed,
              !trimmed.isEmpty,
              trimmed.utf8.count <= maxUTF8Bytes,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ForgeCompactError.invalidIdentifier(field: field)
        }
        return value
    }

    static func content(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 32_768,
              !trimmed.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw ForgeCompactError.invalidContent
        }
        return trimmed
    }
}

public struct ProjectCapsuleAuthority: Codable, Hashable, Sendable {
    public let projectID: String
    public let missionID: String
    public let sourceRevision: String
    public let missionRevision: Int
    public let authorityEpoch: Int
    public let capsuleRevision: Int

    public init(
        projectID: String,
        missionID: String,
        sourceRevision: String,
        missionRevision: Int,
        authorityEpoch: Int,
        capsuleRevision: Int
    ) throws {
        self.projectID = try ForgeCompactValidation.identifier(projectID, field: "projectID")
        self.missionID = try ForgeCompactValidation.identifier(missionID, field: "missionID")
        self.sourceRevision = try ForgeCompactValidation.identifier(sourceRevision, field: "sourceRevision")
        guard missionRevision >= 0 else {
            throw ForgeCompactError.invalidRevision(field: "missionRevision", value: missionRevision)
        }
        guard authorityEpoch >= 0 else {
            throw ForgeCompactError.invalidRevision(field: "authorityEpoch", value: authorityEpoch)
        }
        guard capsuleRevision >= 0 else {
            throw ForgeCompactError.invalidRevision(field: "capsuleRevision", value: capsuleRevision)
        }
        self.missionRevision = missionRevision
        self.authorityEpoch = authorityEpoch
        self.capsuleRevision = capsuleRevision
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, missionID, sourceRevision, missionRevision, authorityEpoch, capsuleRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: c.decode(String.self, forKey: .projectID),
            missionID: c.decode(String.self, forKey: .missionID),
            sourceRevision: c.decode(String.self, forKey: .sourceRevision),
            missionRevision: c.decode(Int.self, forKey: .missionRevision),
            authorityEpoch: c.decode(Int.self, forKey: .authorityEpoch),
            capsuleRevision: c.decode(Int.self, forKey: .capsuleRevision)
        )
    }
}

public enum ForgeCompactContextTier: String, Codable, CaseIterable, Sendable {
    case l0AlwaysResident
    case l1ActiveWorkingSet
    case l2ProjectMemory
    case l3ColdArchive

    var selectionRank: Int {
        switch self {
        case .l0AlwaysResident: 0
        case .l1ActiveWorkingSet: 1
        case .l2ProjectMemory: 2
        case .l3ColdArchive: 3
        }
    }

    var renderLabel: String {
        switch self {
        case .l0AlwaysResident: "L0"
        case .l1ActiveWorkingSet: "L1"
        case .l2ProjectMemory: "L2"
        case .l3ColdArchive: "L3"
        }
    }
}

public enum ForgeCompactFactKind: String, Codable, CaseIterable, Sendable {
    case missionIdentity
    case currentObjective
    case missionStage
    case safetyPolicy
    case privacyPolicy
    case acceptedRequirement
    case unresolvedDecision
    case knownDefect
    case failingTest
    case knownLimitation
    case acceptedDecision
    case designDNA
    case sourceLocation
    case testReceipt
    case runtimeReceipt
    case workingNote

    public var requiresRetentionWhenPresent: Bool {
        switch self {
        case .missionIdentity, .currentObjective, .missionStage, .safetyPolicy, .privacyPolicy,
             .acceptedRequirement, .unresolvedDecision, .knownDefect, .failingTest,
             .knownLimitation, .acceptedDecision:
            true
        case .designDNA, .sourceLocation, .testReceipt, .runtimeReceipt, .workingNote:
            false
        }
    }
}

public enum ForgeCompactProvenanceKind: String, Codable, CaseIterable, Sendable {
    case user
    case source
    case runtime
    case test
    case checkpoint
    case modelSummary
}

public enum ForgeCompactFreshness: String, Codable, Sendable {
    case current
    case stale
}

public struct ForgeCompactProvenance: Codable, Hashable, Sendable {
    public let kind: ForgeCompactProvenanceKind
    public let reference: String

    public init(kind: ForgeCompactProvenanceKind, reference: String) throws {
        self.kind = kind
        self.reference = try ForgeCompactValidation.identifier(reference, field: "provenance.reference", maxUTF8Bytes: 512)
    }

    private enum CodingKeys: String, CodingKey { case kind, reference }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: c.decode(ForgeCompactProvenanceKind.self, forKey: .kind),
            reference: c.decode(String.self, forKey: .reference)
        )
    }
}

public struct ForgeCompactContextItem: Codable, Hashable, Sendable {
    public let id: String
    public let sourceRevision: String
    public let tier: ForgeCompactContextTier
    public let kind: ForgeCompactFactKind
    public let priority: Int
    public let content: String
    public let provenance: ForgeCompactProvenance
    public let isAuthoritative: Bool
    public let freshness: ForgeCompactFreshness
    public let protectedByUser: Bool

    public var mustRetain: Bool {
        tier == .l0AlwaysResident || kind.requiresRetentionWhenPresent || protectedByUser
    }

    public init(
        id: String,
        sourceRevision: String,
        tier: ForgeCompactContextTier,
        kind: ForgeCompactFactKind,
        priority: Int,
        content: String,
        provenance: ForgeCompactProvenance,
        isAuthoritative: Bool,
        freshness: ForgeCompactFreshness = .current,
        protectedByUser: Bool = false
    ) throws {
        self.id = try ForgeCompactValidation.identifier(id, field: "item.id")
        self.sourceRevision = try ForgeCompactValidation.identifier(sourceRevision, field: "item.sourceRevision")
        guard (0...100).contains(priority) else {
            throw ForgeCompactError.invalidPriority(priority)
        }
        self.tier = tier
        self.kind = kind
        self.priority = priority
        self.content = try ForgeCompactValidation.content(content)
        self.provenance = provenance
        if isAuthoritative && provenance.kind == .modelSummary {
            throw ForgeCompactError.modelSummaryCannotBeAuthoritative(itemID: self.id)
        }
        let requestsMandatoryRetention =
            tier == .l0AlwaysResident || kind.requiresRetentionWhenPresent || protectedByUser
        if requestsMandatoryRetention && provenance.kind == .modelSummary {
            throw ForgeCompactError.modelSummaryCannotSupplyMandatoryTruth(itemID: self.id)
        }
        self.isAuthoritative = isAuthoritative
        self.freshness = freshness
        self.protectedByUser = protectedByUser
        if mustRetain && freshness != .current {
            throw ForgeCompactError.staleMandatoryTruth(itemID: self.id)
        }
    }

    public var renderedLine: String {
        let authority = isAuthoritative ? "truth" : "advisory"
        let freshnessLabel = freshness == .current ? "current" : "stale"
        return "[\(tier.renderLabel)][\(kind.rawValue)][\(authority)][\(freshnessLabel)][\(id)] \(content)"
    }

    public var renderedUTF8Bytes: Int { renderedLine.utf8.count }

    private enum CodingKeys: String, CodingKey {
        case id, sourceRevision, tier, kind, priority, content, provenance, isAuthoritative, freshness, protectedByUser
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id),
            sourceRevision: c.decode(String.self, forKey: .sourceRevision),
            tier: c.decode(ForgeCompactContextTier.self, forKey: .tier),
            kind: c.decode(ForgeCompactFactKind.self, forKey: .kind),
            priority: c.decode(Int.self, forKey: .priority),
            content: c.decode(String.self, forKey: .content),
            provenance: c.decode(ForgeCompactProvenance.self, forKey: .provenance),
            isAuthoritative: c.decode(Bool.self, forKey: .isAuthoritative),
            freshness: c.decode(ForgeCompactFreshness.self, forKey: .freshness),
            protectedByUser: c.decode(Bool.self, forKey: .protectedByUser)
        )
    }
}

/// Compact reference for context not selected into the rendered capsule. It retains enough
/// source and retention metadata to prove that persisted bytes did not hide mandatory truth or
/// move an omitted fact across source revisions.
public struct ForgeCompactOmittedItem: Codable, Hashable, Sendable {
    public let id: String
    public let sourceRevision: String
    public let tier: ForgeCompactContextTier
    public let kind: ForgeCompactFactKind
    public let priority: Int
    public let protectedByUser: Bool

    public var mustRetain: Bool {
        tier == .l0AlwaysResident || kind.requiresRetentionWhenPresent || protectedByUser
    }

    init(item: ForgeCompactContextItem) {
        id = item.id
        sourceRevision = item.sourceRevision
        tier = item.tier
        kind = item.kind
        priority = item.priority
        protectedByUser = item.protectedByUser
    }

    private init(
        id: String,
        sourceRevision: String,
        tier: ForgeCompactContextTier,
        kind: ForgeCompactFactKind,
        priority: Int,
        protectedByUser: Bool
    ) throws {
        self.id = try ForgeCompactValidation.identifier(id, field: "omitted.id")
        self.sourceRevision = try ForgeCompactValidation.identifier(sourceRevision, field: "omitted.sourceRevision")
        guard (0...100).contains(priority) else {
            throw ForgeCompactError.invalidPriority(priority)
        }
        self.tier = tier
        self.kind = kind
        self.priority = priority
        self.protectedByUser = protectedByUser
        guard !mustRetain else {
            throw ForgeCompactError.invalidCapsuleShape
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceRevision, tier, kind, priority, protectedByUser
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id),
            sourceRevision: c.decode(String.self, forKey: .sourceRevision),
            tier: c.decode(ForgeCompactContextTier.self, forKey: .tier),
            kind: c.decode(ForgeCompactFactKind.self, forKey: .kind),
            priority: c.decode(Int.self, forKey: .priority),
            protectedByUser: c.decode(Bool.self, forKey: .protectedByUser)
        )
    }
}

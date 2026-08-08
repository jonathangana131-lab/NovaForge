import Foundation

public enum ForgeCompactError: Error, Equatable, Sendable {
    case emptyField(String)
    case invalidRevision(String)
    case invalidPriority(Int)
    case invalidBudget(Int)
    case duplicateRecordID(String)
    case protectedRecordRequiresAuthoritativeProvenance(String)
    case protectedRecordMustBeCurrent(String)
    case protectedRecordCannotBeCold(String)
    case selectedRecordMustBeCurrent(String)
    case criticalTruthExceedsBudget(required: Int, budget: Int)
    case activeContextExceedsBudget(actual: Int, budget: Int)
    case unsupportedSchema(Int)
    case inconsistentSourceRecordCount(expected: Int, actual: Int)
    case inconsistentUsedByteCount(expected: Int, actual: Int)
    case inconsistentOmissionReceipt
    case selectedAndOmittedOverlap(String)
    case nonCanonicalRecordOrder
    case nonCanonicalColdReferenceOrder
}

private func normalized(_ value: String, field: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ForgeCompactError.emptyField(field)
    }
    return trimmed
}

private func canonicalUTF8Cost(_ fields: [String]) -> Int {
    fields.joined(separator: "\u{1F}").utf8.count
}

public enum ForgeCompactLayer: Int, Codable, CaseIterable, Sendable {
    /// L1: the bounded active working set for the current stage.
    case activeWorkingSet = 1
    /// L2: retrieved project memory relevant to the current stage.
    case projectMemory = 2
}

public enum ForgeCompactRecordKind: String, Codable, CaseIterable, Sendable {
    case acceptedRequirement
    case unresolvedDecision
    case policyConstraint
    case failingTest
    case knownLimitation
    case acceptedDecision
    case designDNA
    case sourceFact
    case runtimeEvidence
    case checkpointEvidence
    case fileOrSymbol
    case compactSummary

    public var requiresProtection: Bool {
        switch self {
        case .acceptedRequirement, .unresolvedDecision, .policyConstraint, .failingTest, .knownLimitation:
            true
        case .acceptedDecision, .designDNA, .sourceFact, .runtimeEvidence, .checkpointEvidence, .fileOrSymbol, .compactSummary:
            false
        }
    }
}

public enum ForgeCompactProvenance: String, Codable, CaseIterable, Sendable {
    case user
    case source
    case runtimeReceipt
    case testReceipt
    case checkpoint
    case modelSuggestion

    public var isAuthoritativeForProtectedTruth: Bool {
        self != .modelSuggestion
    }
}

public enum ForgeCompactFreshness: String, Codable, CaseIterable, Sendable {
    case current
    case stale
    case unknown
}

public struct ForgeCompactSourceBinding: Codable, Equatable, Sendable {
    public let authorityID: String
    public let revision: String

    public init(authorityID: String, revision: String) throws {
        self.authorityID = try normalized(authorityID, field: "authorityID")
        self.revision = try normalized(revision, field: "revision")
    }

    private enum CodingKeys: String, CodingKey {
        case authorityID
        case revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            authorityID: container.decode(String.self, forKey: .authorityID),
            revision: container.decode(String.self, forKey: .revision)
        )
    }
}

/// L0 is always resident. These are opaque adapter-bound identities and policy references;
/// this package never mints Mission Engine, Project Brain, provider, or runtime authority.
public struct ForgeCompactCoreContext: Codable, Equatable, Sendable {
    public let missionID: String
    public let projectID: String
    public let missionRevision: Int
    public let authorityEpoch: Int
    public let sourceAuthorityRevision: String
    public let currentObjective: String
    public let currentStageID: String
    public let privacyPolicyReference: String
    public let localityPolicyReference: String

    public init(
        missionID: String,
        projectID: String,
        missionRevision: Int,
        authorityEpoch: Int,
        sourceAuthorityRevision: String,
        currentObjective: String,
        currentStageID: String,
        privacyPolicyReference: String,
        localityPolicyReference: String
    ) throws {
        guard missionRevision >= 0 else {
            throw ForgeCompactError.invalidRevision("missionRevision")
        }
        guard authorityEpoch >= 0 else {
            throw ForgeCompactError.invalidRevision("authorityEpoch")
        }

        self.missionID = try normalized(missionID, field: "missionID")
        self.projectID = try normalized(projectID, field: "projectID")
        self.missionRevision = missionRevision
        self.authorityEpoch = authorityEpoch
        self.sourceAuthorityRevision = try normalized(sourceAuthorityRevision, field: "sourceAuthorityRevision")
        self.currentObjective = try normalized(currentObjective, field: "currentObjective")
        self.currentStageID = try normalized(currentStageID, field: "currentStageID")
        self.privacyPolicyReference = try normalized(privacyPolicyReference, field: "privacyPolicyReference")
        self.localityPolicyReference = try normalized(localityPolicyReference, field: "localityPolicyReference")
    }

    public var promptByteCost: Int {
        canonicalUTF8Cost([
            "L0",
            missionID,
            projectID,
            String(missionRevision),
            String(authorityEpoch),
            sourceAuthorityRevision,
            currentObjective,
            currentStageID,
            privacyPolicyReference,
            localityPolicyReference,
        ])
    }

    private enum CodingKeys: String, CodingKey {
        case missionID
        case projectID
        case missionRevision
        case authorityEpoch
        case sourceAuthorityRevision
        case currentObjective
        case currentStageID
        case privacyPolicyReference
        case localityPolicyReference
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            missionID: container.decode(String.self, forKey: .missionID),
            projectID: container.decode(String.self, forKey: .projectID),
            missionRevision: container.decode(Int.self, forKey: .missionRevision),
            authorityEpoch: container.decode(Int.self, forKey: .authorityEpoch),
            sourceAuthorityRevision: container.decode(String.self, forKey: .sourceAuthorityRevision),
            currentObjective: container.decode(String.self, forKey: .currentObjective),
            currentStageID: container.decode(String.self, forKey: .currentStageID),
            privacyPolicyReference: container.decode(String.self, forKey: .privacyPolicyReference),
            localityPolicyReference: container.decode(String.self, forKey: .localityPolicyReference)
        )
    }
}

public struct ForgeCompactRecord: Codable, Equatable, Sendable {
    public let id: String
    public let layer: ForgeCompactLayer
    public let kind: ForgeCompactRecordKind
    public let provenance: ForgeCompactProvenance
    public let freshness: ForgeCompactFreshness
    public let priority: Int
    public let value: String
    public let sourceBinding: ForgeCompactSourceBinding

    public init(
        id: String,
        layer: ForgeCompactLayer,
        kind: ForgeCompactRecordKind,
        provenance: ForgeCompactProvenance,
        freshness: ForgeCompactFreshness,
        priority: Int,
        value: String,
        sourceBinding: ForgeCompactSourceBinding
    ) throws {
        guard (0...100).contains(priority) else {
            throw ForgeCompactError.invalidPriority(priority)
        }

        let normalizedID = try normalized(id, field: "record.id")
        let normalizedValue = try normalized(value, field: "record.value")

        if kind.requiresProtection {
            guard provenance.isAuthoritativeForProtectedTruth else {
                throw ForgeCompactError.protectedRecordRequiresAuthoritativeProvenance(normalizedID)
            }
            guard freshness == .current else {
                throw ForgeCompactError.protectedRecordMustBeCurrent(normalizedID)
            }
        }

        self.id = normalizedID
        self.layer = layer
        self.kind = kind
        self.provenance = provenance
        self.freshness = freshness
        self.priority = priority
        self.value = normalizedValue
        self.sourceBinding = sourceBinding
    }

    public var isProtected: Bool {
        kind.requiresProtection
    }

    public var promptByteCost: Int {
        canonicalUTF8Cost([
            "L\(layer.rawValue)",
            id,
            kind.rawValue,
            provenance.rawValue,
            freshness.rawValue,
            String(priority),
            sourceBinding.authorityID,
            sourceBinding.revision,
            value,
        ])
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case layer
        case kind
        case provenance
        case freshness
        case priority
        case value
        case sourceBinding
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            layer: container.decode(ForgeCompactLayer.self, forKey: .layer),
            kind: container.decode(ForgeCompactRecordKind.self, forKey: .kind),
            provenance: container.decode(ForgeCompactProvenance.self, forKey: .provenance),
            freshness: container.decode(ForgeCompactFreshness.self, forKey: .freshness),
            priority: container.decode(Int.self, forKey: .priority),
            value: container.decode(String.self, forKey: .value),
            sourceBinding: container.decode(ForgeCompactSourceBinding.self, forKey: .sourceBinding)
        )
    }
}

public enum ForgeCompactOmissionReason: String, Codable, CaseIterable, Sendable {
    case activeContextBudget
    case notCurrent
}

/// L3 keeps only a retrieval-addressable pointer for material omitted from the active prompt.
/// It deliberately does not retain the omitted value itself.
public struct ForgeCompactColdReference: Codable, Equatable, Sendable {
    public let recordID: String
    public let kind: ForgeCompactRecordKind
    public let freshness: ForgeCompactFreshness
    public let sourceBinding: ForgeCompactSourceBinding
    public let reason: ForgeCompactOmissionReason

    public init(
        recordID: String,
        kind: ForgeCompactRecordKind,
        freshness: ForgeCompactFreshness,
        sourceBinding: ForgeCompactSourceBinding,
        reason: ForgeCompactOmissionReason
    ) throws {
        let normalizedID = try normalized(recordID, field: "coldReference.recordID")
        guard !kind.requiresProtection else {
            throw ForgeCompactError.protectedRecordCannotBeCold(normalizedID)
        }
        self.recordID = normalizedID
        self.kind = kind
        self.freshness = freshness
        self.sourceBinding = sourceBinding
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case recordID
        case kind
        case freshness
        case sourceBinding
        case reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordID: container.decode(String.self, forKey: .recordID),
            kind: container.decode(ForgeCompactRecordKind.self, forKey: .kind),
            freshness: container.decode(ForgeCompactFreshness.self, forKey: .freshness),
            sourceBinding: container.decode(ForgeCompactSourceBinding.self, forKey: .sourceBinding),
            reason: container.decode(ForgeCompactOmissionReason.self, forKey: .reason)
        )
    }
}

public struct ForgeProjectCapsule: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let core: ForgeCompactCoreContext
    public let selectedRecords: [ForgeCompactRecord]
    public let coldReferences: [ForgeCompactColdReference]
    public let omittedRecordIDs: [String]
    public let maximumActiveContextBytes: Int
    public let usedActiveContextBytes: Int
    public let sourceRecordCount: Int

    public init(
        schemaVersion: Int = ForgeProjectCapsule.currentSchemaVersion,
        core: ForgeCompactCoreContext,
        selectedRecords: [ForgeCompactRecord],
        coldReferences: [ForgeCompactColdReference],
        omittedRecordIDs: [String],
        maximumActiveContextBytes: Int,
        usedActiveContextBytes: Int,
        sourceRecordCount: Int
    ) throws {
        self.schemaVersion = schemaVersion
        self.core = core
        self.selectedRecords = selectedRecords
        self.coldReferences = coldReferences
        self.omittedRecordIDs = omittedRecordIDs
        self.maximumActiveContextBytes = maximumActiveContextBytes
        self.usedActiveContextBytes = usedActiveContextBytes
        self.sourceRecordCount = sourceRecordCount
        try validate()
    }

    public var activeContextUtilization: Double {
        guard maximumActiveContextBytes > 0 else { return 0 }
        return Double(usedActiveContextBytes) / Double(maximumActiveContextBytes)
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompactError.unsupportedSchema(schemaVersion)
        }
        guard maximumActiveContextBytes > 0 else {
            throw ForgeCompactError.invalidBudget(maximumActiveContextBytes)
        }

        var selectedIDs = Set<String>()
        for record in selectedRecords {
            guard selectedIDs.insert(record.id).inserted else {
                throw ForgeCompactError.duplicateRecordID(record.id)
            }
            guard record.freshness == .current else {
                throw ForgeCompactError.selectedRecordMustBeCurrent(record.id)
            }
        }

        let canonicalSelected = selectedRecords.sorted(by: Self.recordOrdering)
        guard canonicalSelected == selectedRecords else {
            throw ForgeCompactError.nonCanonicalRecordOrder
        }

        var coldIDs = Set<String>()
        for reference in coldReferences {
            guard coldIDs.insert(reference.recordID).inserted else {
                throw ForgeCompactError.duplicateRecordID(reference.recordID)
            }
            if selectedIDs.contains(reference.recordID) {
                throw ForgeCompactError.selectedAndOmittedOverlap(reference.recordID)
            }
        }

        let canonicalCold = coldReferences.sorted { $0.recordID < $1.recordID }
        guard canonicalCold == coldReferences else {
            throw ForgeCompactError.nonCanonicalColdReferenceOrder
        }

        let canonicalOmitted = coldReferences.map(\.recordID).sorted()
        guard omittedRecordIDs == canonicalOmitted else {
            throw ForgeCompactError.inconsistentOmissionReceipt
        }

        let expectedSourceRecordCount = selectedRecords.count + coldReferences.count
        guard sourceRecordCount == expectedSourceRecordCount else {
            throw ForgeCompactError.inconsistentSourceRecordCount(
                expected: expectedSourceRecordCount,
                actual: sourceRecordCount
            )
        }

        let expectedUsedBytes = core.promptByteCost + selectedRecords.reduce(0) { partial, record in
            partial + record.promptByteCost
        }
        guard usedActiveContextBytes == expectedUsedBytes else {
            throw ForgeCompactError.inconsistentUsedByteCount(
                expected: expectedUsedBytes,
                actual: usedActiveContextBytes
            )
        }
        guard usedActiveContextBytes <= maximumActiveContextBytes else {
            throw ForgeCompactError.activeContextExceedsBudget(
                actual: usedActiveContextBytes,
                budget: maximumActiveContextBytes
            )
        }
    }

    fileprivate static func recordOrdering(_ lhs: ForgeCompactRecord, _ rhs: ForgeCompactRecord) -> Bool {
        if lhs.isProtected != rhs.isProtected {
            return lhs.isProtected && !rhs.isProtected
        }
        if lhs.layer != rhs.layer {
            return lhs.layer.rawValue < rhs.layer.rawValue
        }
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        return lhs.id < rhs.id
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case core
        case selectedRecords
        case coldReferences
        case omittedRecordIDs
        case maximumActiveContextBytes
        case usedActiveContextBytes
        case sourceRecordCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            core: container.decode(ForgeCompactCoreContext.self, forKey: .core),
            selectedRecords: container.decode([ForgeCompactRecord].self, forKey: .selectedRecords),
            coldReferences: container.decode([ForgeCompactColdReference].self, forKey: .coldReferences),
            omittedRecordIDs: container.decode([String].self, forKey: .omittedRecordIDs),
            maximumActiveContextBytes: container.decode(Int.self, forKey: .maximumActiveContextBytes),
            usedActiveContextBytes: container.decode(Int.self, forKey: .usedActiveContextBytes),
            sourceRecordCount: container.decode(Int.self, forKey: .sourceRecordCount)
        )
    }
}

public enum ForgeCompactBuilder {
    /// Produces an L0-L2 active context plus L3 cold references without ever dropping protected truth.
    /// The byte budget is deterministic UTF-8 cost of the canonical prompt fields, not a claim about
    /// provider tokenizer counts or runtime KV memory.
    public static func build(
        core: ForgeCompactCoreContext,
        records: [ForgeCompactRecord],
        maximumActiveContextBytes: Int
    ) throws -> ForgeProjectCapsule {
        guard maximumActiveContextBytes > 0 else {
            throw ForgeCompactError.invalidBudget(maximumActiveContextBytes)
        }

        var seenIDs = Set<String>()
        for record in records {
            guard seenIDs.insert(record.id).inserted else {
                throw ForgeCompactError.duplicateRecordID(record.id)
            }
        }

        let protectedRecords = records
            .filter(\.isProtected)
            .sorted(by: ForgeProjectCapsule.recordOrdering)

        let requiredBytes = core.promptByteCost + protectedRecords.reduce(0) { partial, record in
            partial + record.promptByteCost
        }
        guard requiredBytes <= maximumActiveContextBytes else {
            throw ForgeCompactError.criticalTruthExceedsBudget(
                required: requiredBytes,
                budget: maximumActiveContextBytes
            )
        }

        var selected = protectedRecords
        var selectedIDs = Set(protectedRecords.map(\.id))
        var usedBytes = requiredBytes
        var coldReferences: [ForgeCompactColdReference] = []

        let ordinaryRecords = records
            .filter { !$0.isProtected }
            .sorted(by: ForgeProjectCapsule.recordOrdering)

        for record in ordinaryRecords {
            guard record.freshness == .current else {
                coldReferences.append(
                    try ForgeCompactColdReference(
                        recordID: record.id,
                        kind: record.kind,
                        freshness: record.freshness,
                        sourceBinding: record.sourceBinding,
                        reason: .notCurrent
                    )
                )
                continue
            }

            if usedBytes + record.promptByteCost <= maximumActiveContextBytes {
                selected.append(record)
                selectedIDs.insert(record.id)
                usedBytes += record.promptByteCost
            } else {
                coldReferences.append(
                    try ForgeCompactColdReference(
                        recordID: record.id,
                        kind: record.kind,
                        freshness: record.freshness,
                        sourceBinding: record.sourceBinding,
                        reason: .activeContextBudget
                    )
                )
            }
        }

        // Defensive: any record not selected must have an explicit cold receipt.
        let coldIDs = Set(coldReferences.map(\.recordID))
        for record in records where !selectedIDs.contains(record.id) && !coldIDs.contains(record.id) {
            coldReferences.append(
                try ForgeCompactColdReference(
                    recordID: record.id,
                    kind: record.kind,
                    freshness: record.freshness,
                    sourceBinding: record.sourceBinding,
                    reason: record.freshness == .current ? .activeContextBudget : .notCurrent
                )
            )
        }

        selected.sort(by: ForgeProjectCapsule.recordOrdering)
        coldReferences.sort { $0.recordID < $1.recordID }

        return try ForgeProjectCapsule(
            core: core,
            selectedRecords: selected,
            coldReferences: coldReferences,
            omittedRecordIDs: coldReferences.map(\.recordID),
            maximumActiveContextBytes: maximumActiveContextBytes,
            usedActiveContextBytes: core.promptByteCost + selected.reduce(0) { $0 + $1.promptByteCost },
            sourceRecordCount: records.count
        )
    }
}

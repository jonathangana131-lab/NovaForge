import Foundation

public enum ForgeCompactError: Error, Equatable, Sendable {
    case blankField(String)
    case oversizedField(String)
    case invalidControlCharacter(String)
    case invalidSchemaVersion(Int)
    case invalidBudget
    case duplicateRecordID(String)
    case duplicateDeferredRecordID(String)
    case invalidTierForMandatoryRecord(String)
    case tooManySourceRecords(actual: Int, maximum: Int)
    case mandatoryTruthExceedsRecordBudget(actual: Int, maximum: Int)
    case capsuleSkeletonExceedsByteBudget(actual: Int, maximum: Int)
    case projectBindingMismatch
    case missionBindingMismatch
    case acceptedProjectStateMismatch
    case sourceRevisionMismatch
    case missionRevisionMismatch
    case constitutionRevisionMismatch
    case graphRevisionMismatch
    case authorityEpochMismatch
    case prefixReuseIdentityMismatch
    case stablePrefixDigestMismatch
    case prefixCapsuleRevisionMismatch
    case prefixProjectBindingMismatch
    case recordSourceRevisionMismatch(String)
    case deferredSourceRevisionMismatch(String)
    case mandatoryRecordDeferred(String)
}

private enum ForgeCompactValidation {
    static func bounded(
        _ value: String,
        field: String,
        maxUTF8Bytes: Int,
        allowNewlines: Bool = false
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ForgeCompactError.blankField(field) }
        guard trimmed.utf8.count <= maxUTF8Bytes else { throw ForgeCompactError.oversizedField(field) }

        for scalar in trimmed.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                if allowNewlines && (scalar.value == 0x0A || scalar.value == 0x09) {
                    continue
                }
                throw ForgeCompactError.invalidControlCharacter(field)
            }
        }
        return trimmed
    }
}

/// Opaque identities supplied by the canonical Mission / Project Brain / ProjectStore lineage.
/// ForgeCompactCore validates and binds these values; it does not author their semantics.
public struct ForgeCompactProjectBinding: Codable, Hashable, Sendable {
    public let projectID: String
    public let missionID: String
    public let acceptedProjectStateID: String
    public let sourceRevision: String
    public let missionRevision: UInt64
    public let constitutionRevision: UInt64
    public let graphRevision: UInt64
    public let authorityEpoch: UInt64

    public init(
        projectID: String,
        missionID: String,
        acceptedProjectStateID: String,
        sourceRevision: String,
        missionRevision: UInt64,
        constitutionRevision: UInt64,
        graphRevision: UInt64,
        authorityEpoch: UInt64
    ) throws {
        self.projectID = try ForgeCompactValidation.bounded(projectID, field: "projectID", maxUTF8Bytes: 256)
        self.missionID = try ForgeCompactValidation.bounded(missionID, field: "missionID", maxUTF8Bytes: 256)
        self.acceptedProjectStateID = try ForgeCompactValidation.bounded(
            acceptedProjectStateID,
            field: "acceptedProjectStateID",
            maxUTF8Bytes: 512
        )
        self.sourceRevision = try ForgeCompactValidation.bounded(sourceRevision, field: "sourceRevision", maxUTF8Bytes: 256)
        self.missionRevision = missionRevision
        self.constitutionRevision = constitutionRevision
        self.graphRevision = graphRevision
        self.authorityEpoch = authorityEpoch
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, missionID, acceptedProjectStateID, sourceRevision
        case missionRevision, constitutionRevision, graphRevision, authorityEpoch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            missionID: container.decode(String.self, forKey: .missionID),
            acceptedProjectStateID: container.decode(String.self, forKey: .acceptedProjectStateID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            missionRevision: container.decode(UInt64.self, forKey: .missionRevision),
            constitutionRevision: container.decode(UInt64.self, forKey: .constitutionRevision),
            graphRevision: container.decode(UInt64.self, forKey: .graphRevision),
            authorityEpoch: container.decode(UInt64.self, forKey: .authorityEpoch)
        )
    }
}

/// Exact compatibility identity for a future prefix/KV reuse adapter. Equality is intentionally strict:
/// changing any model/tokenizer/runtime/template/tool/quant/KV/context authority invalidates reuse.
public struct ForgeCompactPrefixReuseIdentity: Codable, Hashable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let tokenizerID: String
    public let tokenizerRevision: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let promptTemplateRevision: String
    public let toolSchemaRevision: String
    public let quantizationProfile: String
    public let kvCacheProfile: String
    public let contextPolicyRevision: String

    public init(
        modelID: String,
        modelRevision: String,
        tokenizerID: String,
        tokenizerRevision: String,
        runtimeID: String,
        runtimeRevision: String,
        promptTemplateRevision: String,
        toolSchemaRevision: String,
        quantizationProfile: String,
        kvCacheProfile: String,
        contextPolicyRevision: String
    ) throws {
        self.modelID = try ForgeCompactValidation.bounded(modelID, field: "modelID", maxUTF8Bytes: 256)
        self.modelRevision = try ForgeCompactValidation.bounded(modelRevision, field: "modelRevision", maxUTF8Bytes: 256)
        self.tokenizerID = try ForgeCompactValidation.bounded(tokenizerID, field: "tokenizerID", maxUTF8Bytes: 256)
        self.tokenizerRevision = try ForgeCompactValidation.bounded(tokenizerRevision, field: "tokenizerRevision", maxUTF8Bytes: 256)
        self.runtimeID = try ForgeCompactValidation.bounded(runtimeID, field: "runtimeID", maxUTF8Bytes: 256)
        self.runtimeRevision = try ForgeCompactValidation.bounded(runtimeRevision, field: "runtimeRevision", maxUTF8Bytes: 256)
        self.promptTemplateRevision = try ForgeCompactValidation.bounded(
            promptTemplateRevision,
            field: "promptTemplateRevision",
            maxUTF8Bytes: 256
        )
        self.toolSchemaRevision = try ForgeCompactValidation.bounded(toolSchemaRevision, field: "toolSchemaRevision", maxUTF8Bytes: 256)
        self.quantizationProfile = try ForgeCompactValidation.bounded(
            quantizationProfile,
            field: "quantizationProfile",
            maxUTF8Bytes: 128
        )
        self.kvCacheProfile = try ForgeCompactValidation.bounded(kvCacheProfile, field: "kvCacheProfile", maxUTF8Bytes: 128)
        self.contextPolicyRevision = try ForgeCompactValidation.bounded(
            contextPolicyRevision,
            field: "contextPolicyRevision",
            maxUTF8Bytes: 256
        )
    }

    private enum CodingKeys: String, CodingKey {
        case modelID, modelRevision, tokenizerID, tokenizerRevision, runtimeID, runtimeRevision
        case promptTemplateRevision, toolSchemaRevision, quantizationProfile, kvCacheProfile, contextPolicyRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            modelID: container.decode(String.self, forKey: .modelID),
            modelRevision: container.decode(String.self, forKey: .modelRevision),
            tokenizerID: container.decode(String.self, forKey: .tokenizerID),
            tokenizerRevision: container.decode(String.self, forKey: .tokenizerRevision),
            runtimeID: container.decode(String.self, forKey: .runtimeID),
            runtimeRevision: container.decode(String.self, forKey: .runtimeRevision),
            promptTemplateRevision: container.decode(String.self, forKey: .promptTemplateRevision),
            toolSchemaRevision: container.decode(String.self, forKey: .toolSchemaRevision),
            quantizationProfile: container.decode(String.self, forKey: .quantizationProfile),
            kvCacheProfile: container.decode(String.self, forKey: .kvCacheProfile),
            contextPolicyRevision: container.decode(String.self, forKey: .contextPolicyRevision)
        )
    }
}

/// Binding for a concrete cached stable-prefix/KV artifact. This is deliberately separate from
/// `ForgeProjectCapsule`: a mission capsule must survive model/runtime hot-swap, while any cache
/// produced for a different exact prefix or inference identity must be invalidated.
public struct ForgeCompactPrefixArtifactBinding: Codable, Hashable, Sendable {
    public let stablePrefixDigest: String
    public let capsuleRevision: UInt64
    public let projectBinding: ForgeCompactProjectBinding
    public let reuseIdentity: ForgeCompactPrefixReuseIdentity

    public init(
        stablePrefixDigest: String,
        capsuleRevision: UInt64,
        projectBinding: ForgeCompactProjectBinding,
        reuseIdentity: ForgeCompactPrefixReuseIdentity
    ) throws {
        self.stablePrefixDigest = try ForgeCompactValidation.bounded(
            stablePrefixDigest,
            field: "stablePrefixDigest",
            maxUTF8Bytes: 512
        )
        self.capsuleRevision = capsuleRevision
        self.projectBinding = projectBinding
        self.reuseIdentity = reuseIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case stablePrefixDigest, capsuleRevision, projectBinding, reuseIdentity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            stablePrefixDigest: container.decode(String.self, forKey: .stablePrefixDigest),
            capsuleRevision: container.decode(UInt64.self, forKey: .capsuleRevision),
            projectBinding: container.decode(ForgeCompactProjectBinding.self, forKey: .projectBinding),
            reuseIdentity: container.decode(ForgeCompactPrefixReuseIdentity.self, forKey: .reuseIdentity)
        )
    }

    /// The caller supplies a digest of the exact rendered stable prefix. This type does not claim
    /// which hash algorithm produced it; it only requires exact equality before cache reuse.
    public func validateReuse(
        expectedStablePrefixDigest: String,
        expectedCapsule: ForgeProjectCapsule,
        expectedReuseIdentity: ForgeCompactPrefixReuseIdentity
    ) throws {
        let normalizedDigest = try ForgeCompactValidation.bounded(
            expectedStablePrefixDigest,
            field: "expectedStablePrefixDigest",
            maxUTF8Bytes: 512
        )
        guard stablePrefixDigest == normalizedDigest else { throw ForgeCompactError.stablePrefixDigestMismatch }
        guard capsuleRevision == expectedCapsule.capsuleRevision else {
            throw ForgeCompactError.prefixCapsuleRevisionMismatch
        }
        guard projectBinding == expectedCapsule.binding else {
            throw ForgeCompactError.prefixProjectBindingMismatch
        }
        guard reuseIdentity == expectedReuseIdentity else {
            throw ForgeCompactError.prefixReuseIdentityMismatch
        }
    }
}

public enum ForgeCompactContextTier: String, Codable, CaseIterable, Sendable {
    /// Mission identity/current task/current stage and safety/privacy/model policy facts.
    case alwaysResident
    /// Exact files/symbols/diffs/failures and recent accepted decisions for the current bounded step.
    case activeWorkingSet
    /// Retrieved Project Brain, Design DNA, evidence and prior accepted checkpoint facts.
    case projectMemory
    /// Raw transcripts/logs/full diffs/screenshots retained behind explicit retrieval references.
    case coldArchive

    fileprivate var sortRank: Int {
        switch self {
        case .alwaysResident: 0
        case .activeWorkingSet: 1
        case .projectMemory: 2
        case .coldArchive: 3
        }
    }
}

public enum ForgeCompactRecordKind: String, Codable, CaseIterable, Sendable {
    // Critical structured truth: these can never be silently truncated by Forge Compact.
    case acceptedRequirement
    case acceptedDecision
    case unresolvedDecision
    case failingCheck
    case privacyConstraint
    case securityConstraint
    case knownLimitation
    case acceptedEvidenceReceipt
    case protectedDesignRule

    // Retrieval-addressable context: these may be deferred, but the capsule must retain a retrieval reference.
    case relevantFile
    case relevantSymbol
    case recentAcceptedDelta
    case priorAcceptedCheckpoint
    case runtimeObservation
    case visualObservation

    public var mustPreserveInline: Bool {
        switch self {
        case .acceptedRequirement, .acceptedDecision, .unresolvedDecision, .failingCheck,
             .privacyConstraint, .securityConstraint, .knownLimitation,
             .acceptedEvidenceReceipt, .protectedDesignRule:
            true
        case .relevantFile, .relevantSymbol, .recentAcceptedDelta, .priorAcceptedCheckpoint,
             .runtimeObservation, .visualObservation:
            false
        }
    }
}

/// Accepted provenance only. There is deliberately no model-generated provenance case: speculative
/// model text must first cross an existing Mission/Project Brain acceptance boundary before entering a capsule.
public enum ForgeCompactAcceptedProvenance: String, Codable, CaseIterable, Sendable {
    case userDecision
    case acceptedSource
    case acceptedRuntime
    case acceptedTest
    case acceptedCheckpoint
    case acceptedMissionDecision
}

public struct ForgeCompactRecord: Codable, Hashable, Sendable {
    public let id: String
    public let kind: ForgeCompactRecordKind
    public let tier: ForgeCompactContextTier
    public let provenance: ForgeCompactAcceptedProvenance
    public let sourceRevision: String
    public let retrievalKey: String
    public let summary: String
    public let priority: UInt8

    public init(
        id: String,
        kind: ForgeCompactRecordKind,
        tier: ForgeCompactContextTier,
        provenance: ForgeCompactAcceptedProvenance,
        sourceRevision: String,
        retrievalKey: String,
        summary: String,
        priority: UInt8 = 128
    ) throws {
        let normalizedID = try ForgeCompactValidation.bounded(id, field: "record.id", maxUTF8Bytes: 256)
        if kind.mustPreserveInline && tier == .coldArchive {
            throw ForgeCompactError.invalidTierForMandatoryRecord(normalizedID)
        }
        self.id = normalizedID
        self.kind = kind
        self.tier = tier
        self.provenance = provenance
        self.sourceRevision = try ForgeCompactValidation.bounded(
            sourceRevision,
            field: "record.sourceRevision",
            maxUTF8Bytes: 256
        )
        self.retrievalKey = try ForgeCompactValidation.bounded(
            retrievalKey,
            field: "record.retrievalKey",
            maxUTF8Bytes: 512
        )
        self.summary = try ForgeCompactValidation.bounded(
            summary,
            field: "record.summary",
            maxUTF8Bytes: 4_096,
            allowNewlines: true
        )
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, tier, provenance, sourceRevision, retrievalKey, summary, priority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            kind: container.decode(ForgeCompactRecordKind.self, forKey: .kind),
            tier: container.decode(ForgeCompactContextTier.self, forKey: .tier),
            provenance: container.decode(ForgeCompactAcceptedProvenance.self, forKey: .provenance),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            retrievalKey: container.decode(String.self, forKey: .retrievalKey),
            summary: container.decode(String.self, forKey: .summary),
            priority: container.decode(UInt8.self, forKey: .priority)
        )
    }
}

public struct ForgeCompactDeferredReference: Codable, Hashable, Sendable {
    public let recordID: String
    public let kind: ForgeCompactRecordKind
    public let tier: ForgeCompactContextTier
    public let sourceRevision: String
    public let retrievalKey: String

    private init(
        recordID: String,
        kind: ForgeCompactRecordKind,
        tier: ForgeCompactContextTier,
        sourceRevision: String,
        retrievalKey: String
    ) throws {
        let normalizedID = try ForgeCompactValidation.bounded(
            recordID,
            field: "deferred.recordID",
            maxUTF8Bytes: 256
        )
        guard !kind.mustPreserveInline else {
            throw ForgeCompactError.mandatoryRecordDeferred(normalizedID)
        }
        self.recordID = normalizedID
        self.kind = kind
        self.tier = tier
        self.sourceRevision = try ForgeCompactValidation.bounded(
            sourceRevision,
            field: "deferred.sourceRevision",
            maxUTF8Bytes: 256
        )
        self.retrievalKey = try ForgeCompactValidation.bounded(
            retrievalKey,
            field: "deferred.retrievalKey",
            maxUTF8Bytes: 512
        )
    }

    fileprivate init(record: ForgeCompactRecord) {
        precondition(!record.kind.mustPreserveInline)
        self.recordID = record.id
        self.kind = record.kind
        self.tier = record.tier
        self.sourceRevision = record.sourceRevision
        self.retrievalKey = record.retrievalKey
    }

    private enum CodingKeys: String, CodingKey {
        case recordID, kind, tier, sourceRevision, retrievalKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordID: container.decode(String.self, forKey: .recordID),
            kind: container.decode(ForgeCompactRecordKind.self, forKey: .kind),
            tier: container.decode(ForgeCompactContextTier.self, forKey: .tier),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            retrievalKey: container.decode(String.self, forKey: .retrievalKey)
        )
    }
}

public struct ForgeCompactBudget: Hashable, Sendable {
    public let maximumCapsuleBytes: Int
    public let maximumIncludedRecords: Int
    public let maximumSourceRecords: Int

    public init(
        maximumCapsuleBytes: Int,
        maximumIncludedRecords: Int,
        maximumSourceRecords: Int
    ) throws {
        guard maximumCapsuleBytes > 0, maximumIncludedRecords > 0, maximumSourceRecords > 0,
              maximumIncludedRecords <= maximumSourceRecords else {
            throw ForgeCompactError.invalidBudget
        }
        self.maximumCapsuleBytes = maximumCapsuleBytes
        self.maximumIncludedRecords = maximumIncludedRecords
        self.maximumSourceRecords = maximumSourceRecords
    }
}

/// Deterministic structured mission resume state. This is a compact projection of already-accepted
/// upstream truth, never a replacement authority for Mission, Project Brain, ProjectStore or History.
public struct ForgeProjectCapsule: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let capsuleRevision: UInt64
    public let binding: ForgeCompactProjectBinding
    public let includedRecords: [ForgeCompactRecord]
    public let deferredReferences: [ForgeCompactDeferredReference]

    private init(
        schemaVersion: Int,
        capsuleRevision: UInt64,
        binding: ForgeCompactProjectBinding,
        includedRecords: [ForgeCompactRecord],
        deferredReferences: [ForgeCompactDeferredReference]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompactError.invalidSchemaVersion(schemaVersion)
        }
        var seen = Set<String>()
        for record in includedRecords {
            guard record.sourceRevision == binding.sourceRevision else {
                throw ForgeCompactError.recordSourceRevisionMismatch(record.id)
            }
            guard seen.insert(record.id).inserted else { throw ForgeCompactError.duplicateRecordID(record.id) }
        }
        for reference in deferredReferences {
            guard reference.sourceRevision == binding.sourceRevision else {
                throw ForgeCompactError.deferredSourceRevisionMismatch(reference.recordID)
            }
            guard seen.insert(reference.recordID).inserted else {
                throw ForgeCompactError.duplicateDeferredRecordID(reference.recordID)
            }
        }
        self.schemaVersion = schemaVersion
        self.capsuleRevision = capsuleRevision
        self.binding = binding
        self.includedRecords = Self.canonicalRecords(includedRecords)
        self.deferredReferences = Self.canonicalDeferredReferences(deferredReferences)
    }

    fileprivate static func make(
        capsuleRevision: UInt64,
        binding: ForgeCompactProjectBinding,
        includedRecords: [ForgeCompactRecord],
        deferredReferences: [ForgeCompactDeferredReference]
    ) throws -> Self {
        try Self(
            schemaVersion: currentSchemaVersion,
            capsuleRevision: capsuleRevision,
            binding: binding,
            includedRecords: includedRecords,
            deferredReferences: deferredReferences
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, capsuleRevision, binding, includedRecords, deferredReferences
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            capsuleRevision: container.decode(UInt64.self, forKey: .capsuleRevision),
            binding: container.decode(ForgeCompactProjectBinding.self, forKey: .binding),
            includedRecords: container.decode([ForgeCompactRecord].self, forKey: .includedRecords),
            deferredReferences: container.decode([ForgeCompactDeferredReference].self, forKey: .deferredReferences)
        )
    }

    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Fail-closed resume/reuse guard. Callers must resolve the current upstream authorities first.
    public func validateReuse(expectedBinding: ForgeCompactProjectBinding) throws {
        guard binding.projectID == expectedBinding.projectID else { throw ForgeCompactError.projectBindingMismatch }
        guard binding.missionID == expectedBinding.missionID else { throw ForgeCompactError.missionBindingMismatch }
        guard binding.acceptedProjectStateID == expectedBinding.acceptedProjectStateID else {
            throw ForgeCompactError.acceptedProjectStateMismatch
        }
        guard binding.sourceRevision == expectedBinding.sourceRevision else { throw ForgeCompactError.sourceRevisionMismatch }
        guard binding.missionRevision == expectedBinding.missionRevision else { throw ForgeCompactError.missionRevisionMismatch }
        guard binding.constitutionRevision == expectedBinding.constitutionRevision else {
            throw ForgeCompactError.constitutionRevisionMismatch
        }
        guard binding.graphRevision == expectedBinding.graphRevision else { throw ForgeCompactError.graphRevisionMismatch }
        guard binding.authorityEpoch == expectedBinding.authorityEpoch else { throw ForgeCompactError.authorityEpochMismatch }
    }

    fileprivate static func canonicalRecords(_ records: [ForgeCompactRecord]) -> [ForgeCompactRecord] {
        records.sorted { lhs, rhs in
            if lhs.tier.sortRank != rhs.tier.sortRank { return lhs.tier.sortRank < rhs.tier.sortRank }
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.id < rhs.id
        }
    }

    fileprivate static func canonicalDeferredReferences(
        _ references: [ForgeCompactDeferredReference]
    ) -> [ForgeCompactDeferredReference] {
        references.sorted { lhs, rhs in
            if lhs.tier.sortRank != rhs.tier.sortRank { return lhs.tier.sortRank < rhs.tier.sortRank }
            return lhs.recordID < rhs.recordID
        }
    }
}

public enum ForgeProjectCapsuleBuilder {
    public static func build(
        capsuleRevision: UInt64,
        binding: ForgeCompactProjectBinding,
        records: [ForgeCompactRecord],
        budget: ForgeCompactBudget
    ) throws -> ForgeProjectCapsule {
        guard records.count <= budget.maximumSourceRecords else {
            throw ForgeCompactError.tooManySourceRecords(actual: records.count, maximum: budget.maximumSourceRecords)
        }

        var recordIDs = Set<String>()
        for record in records {
            guard recordIDs.insert(record.id).inserted else { throw ForgeCompactError.duplicateRecordID(record.id) }
        }

        let mandatory = ForgeProjectCapsule.canonicalRecords(records.filter(\.kind.mustPreserveInline))
        guard mandatory.count <= budget.maximumIncludedRecords else {
            throw ForgeCompactError.mandatoryTruthExceedsRecordBudget(
                actual: mandatory.count,
                maximum: budget.maximumIncludedRecords
            )
        }

        let candidates = records
            .filter { !$0.kind.mustPreserveInline }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                if lhs.tier.sortRank != rhs.tier.sortRank { return lhs.tier.sortRank < rhs.tier.sortRank }
                return lhs.id < rhs.id
            }

        var included = mandatory
        var deferred = candidates.map(ForgeCompactDeferredReference.init(record:))

        var capsule = try ForgeProjectCapsule.make(
            capsuleRevision: capsuleRevision,
            binding: binding,
            includedRecords: included,
            deferredReferences: deferred
        )
        var byteCount = try capsule.canonicalJSONData().count
        guard byteCount <= budget.maximumCapsuleBytes else {
            throw ForgeCompactError.capsuleSkeletonExceedsByteBudget(
                actual: byteCount,
                maximum: budget.maximumCapsuleBytes
            )
        }

        for candidate in candidates {
            guard included.count < budget.maximumIncludedRecords else { break }
            let trialIncluded = included + [candidate]
            let trialDeferred = deferred.filter { $0.recordID != candidate.id }
            let trial = try ForgeProjectCapsule.make(
                capsuleRevision: capsuleRevision,
                binding: binding,
                includedRecords: trialIncluded,
                deferredReferences: trialDeferred
            )
            let trialBytes = try trial.canonicalJSONData().count
            if trialBytes <= budget.maximumCapsuleBytes {
                included = trialIncluded
                deferred = trialDeferred
                capsule = trial
                byteCount = trialBytes
            }
        }

        precondition(byteCount <= budget.maximumCapsuleBytes)
        return capsule
    }
}

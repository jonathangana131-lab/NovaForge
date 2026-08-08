import Foundation

public enum ForgeCompactError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidIdentifier(String)
    case invalidText(String)
    case invalidRevision(String)
    case invalidPriority(Int)
    case invalidTokenEstimate(Int)
    case invalidContextCapacity(Int)
    case duplicateContextItemID(String)
    case duplicateReferenceID(String)
    case mandatoryItemRequiresAcceptedProvenance(String)
    case mandatoryColdArchiveItem(String)
    case invalidBudget(Int)
    case mandatoryContextExceedsBudget(required: Int, budget: Int)
}

public enum ForgeCompactContextTier: Int, Codable, CaseIterable, Sendable {
    case alwaysResident = 0
    case activeWorkingSet = 1
    case projectMemory = 2
    case coldArchive = 3
}

public enum ForgeCompactProvenance: String, Codable, CaseIterable, Sendable {
    case userAccepted
    case sourceBacked
    case runtimeAccepted
    case testAccepted
    case checkpointAccepted
    case modelSummary

    public var canBackMandatoryTruth: Bool {
        self != .modelSummary
    }
}

public struct ForgeCompactCriticalState: Codable, Equatable, Sendable {
    public let currentObjective: String
    public let currentStageID: String
    public let privacyPolicyID: String
    public let modelPolicyID: String
    public let toolSchemaRevision: String
    public let acceptedDecisionIDs: [String]
    public let unresolvedDecisionIDs: [String]
    public let failingEvidenceIDs: [String]
    public let blockerIDs: [String]
    public let knownLimitationIDs: [String]

    public init(
        currentObjective: String,
        currentStageID: String,
        privacyPolicyID: String,
        modelPolicyID: String,
        toolSchemaRevision: String,
        acceptedDecisionIDs: [String] = [],
        unresolvedDecisionIDs: [String] = [],
        failingEvidenceIDs: [String] = [],
        blockerIDs: [String] = [],
        knownLimitationIDs: [String] = []
    ) throws {
        self.currentObjective = try ForgeCompactValidation.text(currentObjective, field: "currentObjective", maxLength: 2_048)
        self.currentStageID = try ForgeCompactValidation.identifier(currentStageID, field: "currentStageID")
        self.privacyPolicyID = try ForgeCompactValidation.identifier(privacyPolicyID, field: "privacyPolicyID")
        self.modelPolicyID = try ForgeCompactValidation.identifier(modelPolicyID, field: "modelPolicyID")
        self.toolSchemaRevision = try ForgeCompactValidation.identifier(toolSchemaRevision, field: "toolSchemaRevision")
        self.acceptedDecisionIDs = try ForgeCompactValidation.uniqueIdentifiers(acceptedDecisionIDs, field: "acceptedDecisionIDs")
        self.unresolvedDecisionIDs = try ForgeCompactValidation.uniqueIdentifiers(unresolvedDecisionIDs, field: "unresolvedDecisionIDs")
        self.failingEvidenceIDs = try ForgeCompactValidation.uniqueIdentifiers(failingEvidenceIDs, field: "failingEvidenceIDs")
        self.blockerIDs = try ForgeCompactValidation.uniqueIdentifiers(blockerIDs, field: "blockerIDs")
        self.knownLimitationIDs = try ForgeCompactValidation.uniqueIdentifiers(knownLimitationIDs, field: "knownLimitationIDs")
    }

    private enum CodingKeys: CodingKey {
        case currentObjective, currentStageID, privacyPolicyID, modelPolicyID, toolSchemaRevision
        case acceptedDecisionIDs, unresolvedDecisionIDs, failingEvidenceIDs, blockerIDs, knownLimitationIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            currentObjective: container.decode(String.self, forKey: .currentObjective),
            currentStageID: container.decode(String.self, forKey: .currentStageID),
            privacyPolicyID: container.decode(String.self, forKey: .privacyPolicyID),
            modelPolicyID: container.decode(String.self, forKey: .modelPolicyID),
            toolSchemaRevision: container.decode(String.self, forKey: .toolSchemaRevision),
            acceptedDecisionIDs: container.decode([String].self, forKey: .acceptedDecisionIDs),
            unresolvedDecisionIDs: container.decode([String].self, forKey: .unresolvedDecisionIDs),
            failingEvidenceIDs: container.decode([String].self, forKey: .failingEvidenceIDs),
            blockerIDs: container.decode([String].self, forKey: .blockerIDs),
            knownLimitationIDs: container.decode([String].self, forKey: .knownLimitationIDs)
        )
    }
}

public struct ForgeCompactContextItem: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let tier: ForgeCompactContextTier
    public let provenance: ForgeCompactProvenance
    public let priority: Int
    public let estimatedTokens: Int
    public let isMandatory: Bool
    public let payload: String

    public init(
        id: String,
        tier: ForgeCompactContextTier,
        provenance: ForgeCompactProvenance,
        priority: Int,
        estimatedTokens: Int,
        isMandatory: Bool,
        payload: String
    ) throws {
        self.id = try ForgeCompactValidation.identifier(id, field: "contextItem.id")
        guard (0...100).contains(priority) else { throw ForgeCompactError.invalidPriority(priority) }
        guard (1...16_384).contains(estimatedTokens) else { throw ForgeCompactError.invalidTokenEstimate(estimatedTokens) }
        if isMandatory && !provenance.canBackMandatoryTruth {
            throw ForgeCompactError.mandatoryItemRequiresAcceptedProvenance(id)
        }
        if isMandatory && tier == .coldArchive {
            throw ForgeCompactError.mandatoryColdArchiveItem(id)
        }
        self.tier = tier
        self.provenance = provenance
        self.priority = priority
        self.estimatedTokens = estimatedTokens
        self.isMandatory = isMandatory
        self.payload = try ForgeCompactValidation.text(payload, field: "contextItem.payload", maxLength: 16_384)
    }

    private enum CodingKeys: CodingKey {
        case id, tier, provenance, priority, estimatedTokens, isMandatory, payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            tier: container.decode(ForgeCompactContextTier.self, forKey: .tier),
            provenance: container.decode(ForgeCompactProvenance.self, forKey: .provenance),
            priority: container.decode(Int.self, forKey: .priority),
            estimatedTokens: container.decode(Int.self, forKey: .estimatedTokens),
            isMandatory: container.decode(Bool.self, forKey: .isMandatory),
            payload: container.decode(String.self, forKey: .payload)
        )
    }
}

public struct ForgeCompactProjectCapsule: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let projectID: String
    public let missionID: String
    public let sourceRevision: String
    public let missionRevision: Int
    public let authorityEpoch: Int
    public let criticalState: ForgeCompactCriticalState
    public let contextItems: [ForgeCompactContextItem]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        projectID: String,
        missionID: String,
        sourceRevision: String,
        missionRevision: Int,
        authorityEpoch: Int,
        criticalState: ForgeCompactCriticalState,
        contextItems: [ForgeCompactContextItem]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw ForgeCompactError.unsupportedSchema(schemaVersion) }
        guard missionRevision >= 0 else { throw ForgeCompactError.invalidRevision("missionRevision") }
        guard authorityEpoch >= 0 else { throw ForgeCompactError.invalidRevision("authorityEpoch") }
        self.schemaVersion = schemaVersion
        self.projectID = try ForgeCompactValidation.identifier(projectID, field: "projectID")
        self.missionID = try ForgeCompactValidation.identifier(missionID, field: "missionID")
        self.sourceRevision = try ForgeCompactValidation.identifier(sourceRevision, field: "sourceRevision")
        self.missionRevision = missionRevision
        self.authorityEpoch = authorityEpoch
        self.criticalState = criticalState

        var seen = Set<String>()
        for item in contextItems where !seen.insert(item.id).inserted {
            throw ForgeCompactError.duplicateContextItemID(item.id)
        }
        self.contextItems = contextItems.sorted(by: Self.canonicalOrder)
    }

    private enum CodingKeys: CodingKey {
        case schemaVersion, projectID, missionID, sourceRevision, missionRevision, authorityEpoch, criticalState, contextItems
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            projectID: container.decode(String.self, forKey: .projectID),
            missionID: container.decode(String.self, forKey: .missionID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            missionRevision: container.decode(Int.self, forKey: .missionRevision),
            authorityEpoch: container.decode(Int.self, forKey: .authorityEpoch),
            criticalState: container.decode(ForgeCompactCriticalState.self, forKey: .criticalState),
            contextItems: container.decode([ForgeCompactContextItem].self, forKey: .contextItems)
        )
    }

    private static func canonicalOrder(_ lhs: ForgeCompactContextItem, _ rhs: ForgeCompactContextItem) -> Bool {
        if lhs.tier.rawValue != rhs.tier.rawValue { return lhs.tier.rawValue < rhs.tier.rawValue }
        if lhs.isMandatory != rhs.isMandatory { return lhs.isMandatory && !rhs.isMandatory }
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.id < rhs.id
    }
}

public struct ForgeCompactContextBudget: Codable, Equatable, Sendable {
    public let maxEstimatedTokens: Int
    public let allowColdArchiveRetrieval: Bool

    public init(maxEstimatedTokens: Int, allowColdArchiveRetrieval: Bool = false) throws {
        guard (1...1_000_000).contains(maxEstimatedTokens) else { throw ForgeCompactError.invalidBudget(maxEstimatedTokens) }
        self.maxEstimatedTokens = maxEstimatedTokens
        self.allowColdArchiveRetrieval = allowColdArchiveRetrieval
    }

    private enum CodingKeys: CodingKey {
        case maxEstimatedTokens, allowColdArchiveRetrieval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maxEstimatedTokens: container.decode(Int.self, forKey: .maxEstimatedTokens),
            allowColdArchiveRetrieval: container.decode(Bool.self, forKey: .allowColdArchiveRetrieval)
        )
    }
}

public struct ForgeCompactContextSelection: Equatable, Sendable {
    public let selected: [ForgeCompactContextItem]
    public let omittedItemIDs: [String]
    public let estimatedTokens: Int
}

public enum ForgeCompactContextSelector {
    public static func select(
        from capsule: ForgeCompactProjectCapsule,
        budget: ForgeCompactContextBudget
    ) throws -> ForgeCompactContextSelection {
        let eligible = capsule.contextItems.filter { item in
            item.tier != .coldArchive || budget.allowColdArchiveRetrieval
        }
        let mandatory = eligible.filter(\.isMandatory)
        let required = mandatory.reduce(into: 0) { $0 += $1.estimatedTokens }
        guard required <= budget.maxEstimatedTokens else {
            throw ForgeCompactError.mandatoryContextExceedsBudget(required: required, budget: budget.maxEstimatedTokens)
        }

        var selected = mandatory
        var used = required
        let selectedIDs = Set(mandatory.map(\.id))
        let optional = eligible.filter { !selectedIDs.contains($0.id) }.sorted(by: optionalOrder)
        for item in optional where used + item.estimatedTokens <= budget.maxEstimatedTokens {
            selected.append(item)
            used += item.estimatedTokens
        }

        selected.sort(by: selectionOrder)
        let finalIDs = Set(selected.map(\.id))
        let omitted = capsule.contextItems.map(\.id).filter { !finalIDs.contains($0) }.sorted()
        return ForgeCompactContextSelection(selected: selected, omittedItemIDs: omitted, estimatedTokens: used)
    }

    private static func optionalOrder(_ lhs: ForgeCompactContextItem, _ rhs: ForgeCompactContextItem) -> Bool {
        if lhs.tier.rawValue != rhs.tier.rawValue { return lhs.tier.rawValue < rhs.tier.rawValue }
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.estimatedTokens != rhs.estimatedTokens { return lhs.estimatedTokens < rhs.estimatedTokens }
        return lhs.id < rhs.id
    }

    private static func selectionOrder(_ lhs: ForgeCompactContextItem, _ rhs: ForgeCompactContextItem) -> Bool {
        if lhs.tier.rawValue != rhs.tier.rawValue { return lhs.tier.rawValue < rhs.tier.rawValue }
        if lhs.isMandatory != rhs.isMandatory { return lhs.isMandatory && !rhs.isMandatory }
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.id < rhs.id
    }
}

public struct ForgeCompactPrefixReuseIdentity: Codable, Equatable, Hashable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let tokenizerRevision: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let backendProfileID: String
    public let weightProfileID: String
    public let keyCacheType: String
    public let valueCacheType: String
    public let contextCapacityTokens: Int
    public let promptTemplateRevision: String
    public let toolSchemaRevision: String
    public let capsuleSourceRevision: String
    public let capsuleMissionRevision: Int
    public let capsuleAuthorityEpoch: Int

    public init(
        modelID: String,
        modelRevision: String,
        tokenizerRevision: String,
        runtimeID: String,
        runtimeRevision: String,
        backendProfileID: String,
        weightProfileID: String,
        keyCacheType: String,
        valueCacheType: String,
        contextCapacityTokens: Int,
        promptTemplateRevision: String,
        toolSchemaRevision: String,
        capsuleSourceRevision: String,
        capsuleMissionRevision: Int,
        capsuleAuthorityEpoch: Int
    ) throws {
        guard (1...1_000_000).contains(contextCapacityTokens) else { throw ForgeCompactError.invalidContextCapacity(contextCapacityTokens) }
        guard capsuleMissionRevision >= 0 else { throw ForgeCompactError.invalidRevision("capsuleMissionRevision") }
        guard capsuleAuthorityEpoch >= 0 else { throw ForgeCompactError.invalidRevision("capsuleAuthorityEpoch") }
        self.modelID = try ForgeCompactValidation.identifier(modelID, field: "modelID")
        self.modelRevision = try ForgeCompactValidation.identifier(modelRevision, field: "modelRevision")
        self.tokenizerRevision = try ForgeCompactValidation.identifier(tokenizerRevision, field: "tokenizerRevision")
        self.runtimeID = try ForgeCompactValidation.identifier(runtimeID, field: "runtimeID")
        self.runtimeRevision = try ForgeCompactValidation.identifier(runtimeRevision, field: "runtimeRevision")
        self.backendProfileID = try ForgeCompactValidation.identifier(backendProfileID, field: "backendProfileID")
        self.weightProfileID = try ForgeCompactValidation.identifier(weightProfileID, field: "weightProfileID")
        self.keyCacheType = try ForgeCompactValidation.identifier(keyCacheType, field: "keyCacheType")
        self.valueCacheType = try ForgeCompactValidation.identifier(valueCacheType, field: "valueCacheType")
        self.contextCapacityTokens = contextCapacityTokens
        self.promptTemplateRevision = try ForgeCompactValidation.identifier(promptTemplateRevision, field: "promptTemplateRevision")
        self.toolSchemaRevision = try ForgeCompactValidation.identifier(toolSchemaRevision, field: "toolSchemaRevision")
        self.capsuleSourceRevision = try ForgeCompactValidation.identifier(capsuleSourceRevision, field: "capsuleSourceRevision")
        self.capsuleMissionRevision = capsuleMissionRevision
        self.capsuleAuthorityEpoch = capsuleAuthorityEpoch
    }

    private enum CodingKeys: CodingKey {
        case modelID, modelRevision, tokenizerRevision, runtimeID, runtimeRevision
        case backendProfileID, weightProfileID, keyCacheType, valueCacheType, contextCapacityTokens
        case promptTemplateRevision, toolSchemaRevision, capsuleSourceRevision
        case capsuleMissionRevision, capsuleAuthorityEpoch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            modelID: container.decode(String.self, forKey: .modelID),
            modelRevision: container.decode(String.self, forKey: .modelRevision),
            tokenizerRevision: container.decode(String.self, forKey: .tokenizerRevision),
            runtimeID: container.decode(String.self, forKey: .runtimeID),
            runtimeRevision: container.decode(String.self, forKey: .runtimeRevision),
            backendProfileID: container.decode(String.self, forKey: .backendProfileID),
            weightProfileID: container.decode(String.self, forKey: .weightProfileID),
            keyCacheType: container.decode(String.self, forKey: .keyCacheType),
            valueCacheType: container.decode(String.self, forKey: .valueCacheType),
            contextCapacityTokens: container.decode(Int.self, forKey: .contextCapacityTokens),
            promptTemplateRevision: container.decode(String.self, forKey: .promptTemplateRevision),
            toolSchemaRevision: container.decode(String.self, forKey: .toolSchemaRevision),
            capsuleSourceRevision: container.decode(String.self, forKey: .capsuleSourceRevision),
            capsuleMissionRevision: container.decode(Int.self, forKey: .capsuleMissionRevision),
            capsuleAuthorityEpoch: container.decode(Int.self, forKey: .capsuleAuthorityEpoch)
        )
    }

    public func canReusePrefix(with candidate: Self) -> Bool {
        self == candidate
    }
}

private enum ForgeCompactValidation {
    static func identifier(_ raw: String, field: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 256,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ForgeCompactError.invalidIdentifier(field)
        }
        return value
    }

    static func text(_ raw: String, field: String, maxLength: Int) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= maxLength,
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw ForgeCompactError.invalidText(field)
        }
        return value
    }

    static func uniqueIdentifiers(_ values: [String], field: String) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let value = try identifier(raw, field: field)
            guard seen.insert(value).inserted else { throw ForgeCompactError.duplicateReferenceID(value) }
            result.append(value)
        }
        return result.sorted()
    }
}

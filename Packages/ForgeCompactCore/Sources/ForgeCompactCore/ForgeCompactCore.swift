import Foundation

public enum ForgeCompactError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidEstimatedTokenCount
    case invalidBudget
    case invalidPriority
    case duplicateContextItem(String)
    case alwaysResidentItemMustBeRequired(String)
    case mandatoryContextExceedsBudget(required: Int, budget: Int)
    case unsupportedCapsuleSchema(Int)
    case invalidMissionRevision
    case duplicateCapsuleReference(String)
    case conflictingDecisionReference(String)
    case missingQualificationIdentity
}

private func validatedIdentifier(_ value: String, field: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed == value,
          value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
        throw ForgeCompactError.invalidIdentifier(field: field)
    }
    return value
}

private func canonicalReferences(_ values: [String], field: String) throws -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    result.reserveCapacity(values.count)

    for value in values {
        let validated = try validatedIdentifier(value, field: field)
        guard seen.insert(validated).inserted else {
            throw ForgeCompactError.duplicateCapsuleReference(validated)
        }
        result.append(validated)
    }

    return result.sorted()
}

public enum ForgeCompactTier: Int, Codable, CaseIterable, Sendable {
    case alwaysResident = 0
    case activeWorkingSet = 1
    case projectMemory = 2
    case coldArchive = 3
}

public struct ForgeCompactContextItem: Equatable, Sendable {
    public let id: String
    public let tier: ForgeCompactTier
    public let estimatedTokens: Int
    public let required: Bool
    public let relevancePriority: Int

    public init(
        id: String,
        tier: ForgeCompactTier,
        estimatedTokens: Int,
        required: Bool,
        relevancePriority: Int = 0
    ) throws {
        self.id = try validatedIdentifier(id, field: "contextItem.id")
        guard estimatedTokens > 0 else {
            throw ForgeCompactError.invalidEstimatedTokenCount
        }
        guard relevancePriority >= 0 else {
            throw ForgeCompactError.invalidPriority
        }
        if tier == .alwaysResident && !required {
            throw ForgeCompactError.alwaysResidentItemMustBeRequired(id)
        }
        self.tier = tier
        self.estimatedTokens = estimatedTokens
        self.required = required
        self.relevancePriority = relevancePriority
    }
}

public struct ForgeCompactContextBudget: Equatable, Sendable {
    public let maximumTokens: Int

    public init(maximumTokens: Int) throws {
        guard maximumTokens > 0 else {
            throw ForgeCompactError.invalidBudget
        }
        self.maximumTokens = maximumTokens
    }
}

public struct ForgeCompactContextPlan: Equatable, Sendable {
    public let selected: [ForgeCompactContextItem]
    public let dropped: [ForgeCompactContextItem]
    public let totalEstimatedTokens: Int

    public var selectedIDs: [String] {
        selected.map(\.id)
    }

    public var droppedIDs: [String] {
        dropped.map(\.id)
    }
}

public enum ForgeCompactContextPlanner {
    public static func select(
        _ items: [ForgeCompactContextItem],
        budget: ForgeCompactContextBudget
    ) throws -> ForgeCompactContextPlan {
        var seen = Set<String>()
        for item in items {
            guard seen.insert(item.id).inserted else {
                throw ForgeCompactError.duplicateContextItem(item.id)
            }
        }

        let mandatory = items
            .filter(\.required)
            .sorted(by: contextPriority)
        let mandatoryTokens = mandatory.reduce(0) { $0 + $1.estimatedTokens }

        guard mandatoryTokens <= budget.maximumTokens else {
            throw ForgeCompactError.mandatoryContextExceedsBudget(
                required: mandatoryTokens,
                budget: budget.maximumTokens
            )
        }

        let optional = items
            .filter { !$0.required }
            .sorted(by: contextPriority)

        var selected = mandatory
        var dropped: [ForgeCompactContextItem] = []
        var usedTokens = mandatoryTokens

        for item in optional {
            if usedTokens + item.estimatedTokens <= budget.maximumTokens {
                selected.append(item)
                usedTokens += item.estimatedTokens
            } else {
                dropped.append(item)
            }
        }

        selected.sort(by: contextPriority)
        dropped.sort(by: contextPriority)

        return ForgeCompactContextPlan(
            selected: selected,
            dropped: dropped,
            totalEstimatedTokens: usedTokens
        )
    }

    private static func contextPriority(
        _ lhs: ForgeCompactContextItem,
        _ rhs: ForgeCompactContextItem
    ) -> Bool {
        if lhs.tier.rawValue != rhs.tier.rawValue {
            return lhs.tier.rawValue < rhs.tier.rawValue
        }
        if lhs.required != rhs.required {
            return lhs.required && !rhs.required
        }
        if lhs.relevancePriority != rhs.relevancePriority {
            return lhs.relevancePriority > rhs.relevancePriority
        }
        return lhs.id < rhs.id
    }
}

public struct ForgeProjectCapsule: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let projectID: String
    public let missionID: String
    public let checkpointID: String
    public let sourceRevision: String
    public let missionRevision: Int
    public let acceptedDecisionIDs: [String]
    public let unresolvedDecisionIDs: [String]
    public let evidenceReceiptIDs: [String]
    public let knownDefectIDs: [String]
    public let estimatedTokens: Int

    public init(
        schemaVersion: Int = ForgeProjectCapsule.currentSchemaVersion,
        projectID: String,
        missionID: String,
        checkpointID: String,
        sourceRevision: String,
        missionRevision: Int,
        acceptedDecisionIDs: [String] = [],
        unresolvedDecisionIDs: [String] = [],
        evidenceReceiptIDs: [String] = [],
        knownDefectIDs: [String] = [],
        estimatedTokens: Int
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeCompactError.unsupportedCapsuleSchema(schemaVersion)
        }
        guard missionRevision > 0 else {
            throw ForgeCompactError.invalidMissionRevision
        }
        guard estimatedTokens > 0 else {
            throw ForgeCompactError.invalidEstimatedTokenCount
        }

        let canonicalAcceptedDecisionIDs = try canonicalReferences(
            acceptedDecisionIDs,
            field: "capsule.acceptedDecisionID"
        )
        let canonicalUnresolvedDecisionIDs = try canonicalReferences(
            unresolvedDecisionIDs,
            field: "capsule.unresolvedDecisionID"
        )
        if let conflictingDecision = Set(canonicalAcceptedDecisionIDs)
            .intersection(canonicalUnresolvedDecisionIDs)
            .sorted()
            .first {
            throw ForgeCompactError.conflictingDecisionReference(conflictingDecision)
        }

        self.schemaVersion = schemaVersion
        self.projectID = try validatedIdentifier(projectID, field: "capsule.projectID")
        self.missionID = try validatedIdentifier(missionID, field: "capsule.missionID")
        self.checkpointID = try validatedIdentifier(checkpointID, field: "capsule.checkpointID")
        self.sourceRevision = try validatedIdentifier(sourceRevision, field: "capsule.sourceRevision")
        self.missionRevision = missionRevision
        self.acceptedDecisionIDs = canonicalAcceptedDecisionIDs
        self.unresolvedDecisionIDs = canonicalUnresolvedDecisionIDs
        self.evidenceReceiptIDs = try canonicalReferences(
            evidenceReceiptIDs,
            field: "capsule.evidenceReceiptID"
        )
        self.knownDefectIDs = try canonicalReferences(
            knownDefectIDs,
            field: "capsule.knownDefectID"
        )
        self.estimatedTokens = estimatedTokens
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projectID
        case missionID
        case checkpointID
        case sourceRevision
        case missionRevision
        case acceptedDecisionIDs
        case unresolvedDecisionIDs
        case evidenceReceiptIDs
        case knownDefectIDs
        case estimatedTokens
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            projectID: container.decode(String.self, forKey: .projectID),
            missionID: container.decode(String.self, forKey: .missionID),
            checkpointID: container.decode(String.self, forKey: .checkpointID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            missionRevision: container.decode(Int.self, forKey: .missionRevision),
            acceptedDecisionIDs: container.decode([String].self, forKey: .acceptedDecisionIDs),
            unresolvedDecisionIDs: container.decode([String].self, forKey: .unresolvedDecisionIDs),
            evidenceReceiptIDs: container.decode([String].self, forKey: .evidenceReceiptIDs),
            knownDefectIDs: container.decode([String].self, forKey: .knownDefectIDs),
            estimatedTokens: container.decode(Int.self, forKey: .estimatedTokens)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(missionID, forKey: .missionID)
        try container.encode(checkpointID, forKey: .checkpointID)
        try container.encode(sourceRevision, forKey: .sourceRevision)
        try container.encode(missionRevision, forKey: .missionRevision)
        try container.encode(acceptedDecisionIDs, forKey: .acceptedDecisionIDs)
        try container.encode(unresolvedDecisionIDs, forKey: .unresolvedDecisionIDs)
        try container.encode(evidenceReceiptIDs, forKey: .evidenceReceiptIDs)
        try container.encode(knownDefectIDs, forKey: .knownDefectIDs)
        try container.encode(estimatedTokens, forKey: .estimatedTokens)
    }
}

public struct ForgeCompactPrefixIdentity: Equatable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let tokenizerID: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let promptTemplateRevision: String
    public let toolSchemaRevision: String
    public let stablePrefixDigest: String

    public init(
        modelID: String,
        modelRevision: String,
        tokenizerID: String,
        runtimeID: String,
        runtimeRevision: String,
        promptTemplateRevision: String,
        toolSchemaRevision: String,
        stablePrefixDigest: String
    ) throws {
        self.modelID = try validatedIdentifier(modelID, field: "prefix.modelID")
        self.modelRevision = try validatedIdentifier(modelRevision, field: "prefix.modelRevision")
        self.tokenizerID = try validatedIdentifier(tokenizerID, field: "prefix.tokenizerID")
        self.runtimeID = try validatedIdentifier(runtimeID, field: "prefix.runtimeID")
        self.runtimeRevision = try validatedIdentifier(runtimeRevision, field: "prefix.runtimeRevision")
        self.promptTemplateRevision = try validatedIdentifier(
            promptTemplateRevision,
            field: "prefix.promptTemplateRevision"
        )
        self.toolSchemaRevision = try validatedIdentifier(
            toolSchemaRevision,
            field: "prefix.toolSchemaRevision"
        )
        self.stablePrefixDigest = try validatedIdentifier(
            stablePrefixDigest,
            field: "prefix.stablePrefixDigest"
        )
    }
}

public enum ForgeCompactPrefixReuse {
    public static func canReuse(
        previous: ForgeCompactPrefixIdentity,
        current: ForgeCompactPrefixIdentity
    ) -> Bool {
        previous == current
    }
}

public enum ForgeCompactTechnique: String, Codable, CaseIterable, Sendable {
    case quantizedKVQ8
    case quantizedKVQ4
    case adaptiveKV
    case turboQuant
    case memoryMappedWeights
    case flashBackedColdWeights
    case sparseExpertPaging
    case speculativeDecoding
}

public enum ForgeCompactEvidenceKind: String, Codable, Sendable {
    case sourceReported
    case runtimeObserved
    case exactDeviceMeasured
}

public struct ForgeCompactRuntimeIdentity: Equatable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let tokenizerID: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let quantization: String
    public let kvType: String
    public let contextTokens: Int
    public let deviceModel: String
    public let osVersion: String

    public init(
        modelID: String,
        modelRevision: String,
        tokenizerID: String,
        runtimeID: String,
        runtimeRevision: String,
        quantization: String,
        kvType: String,
        contextTokens: Int,
        deviceModel: String,
        osVersion: String
    ) throws {
        guard contextTokens > 0 else {
            throw ForgeCompactError.invalidBudget
        }
        self.modelID = try validatedIdentifier(modelID, field: "qualification.modelID")
        self.modelRevision = try validatedIdentifier(modelRevision, field: "qualification.modelRevision")
        self.tokenizerID = try validatedIdentifier(tokenizerID, field: "qualification.tokenizerID")
        self.runtimeID = try validatedIdentifier(runtimeID, field: "qualification.runtimeID")
        self.runtimeRevision = try validatedIdentifier(
            runtimeRevision,
            field: "qualification.runtimeRevision"
        )
        self.quantization = try validatedIdentifier(
            quantization,
            field: "qualification.quantization"
        )
        self.kvType = try validatedIdentifier(kvType, field: "qualification.kvType")
        self.contextTokens = contextTokens
        self.deviceModel = try validatedIdentifier(deviceModel, field: "qualification.deviceModel")
        self.osVersion = try validatedIdentifier(osVersion, field: "qualification.osVersion")
    }
}

public struct ForgeCompactTechniqueEvidence: Equatable, Sendable {
    public let kind: ForgeCompactEvidenceKind
    public let runtimeIdentity: ForgeCompactRuntimeIdentity?
    public let qualificationSucceeded: Bool

    public init(
        kind: ForgeCompactEvidenceKind,
        runtimeIdentity: ForgeCompactRuntimeIdentity? = nil,
        qualificationSucceeded: Bool = false
    ) throws {
        if kind != .sourceReported && runtimeIdentity == nil {
            throw ForgeCompactError.missingQualificationIdentity
        }
        self.kind = kind
        self.runtimeIdentity = runtimeIdentity
        self.qualificationSucceeded = qualificationSucceeded
    }
}

public enum ForgeCompactTechniqueAvailability: String, Codable, Sendable {
    case unavailable
    case experimental
    case qualified
}

public enum ForgeCompactTechniqueGate {
    public static func availability(
        evidence: ForgeCompactTechniqueEvidence?,
        explicitResearchOptIn: Bool
    ) -> ForgeCompactTechniqueAvailability {
        guard let evidence else {
            return .unavailable
        }

        switch evidence.kind {
        case .exactDeviceMeasured:
            return evidence.qualificationSucceeded ? .qualified : .unavailable
        case .runtimeObserved:
            return explicitResearchOptIn && evidence.qualificationSucceeded
                ? .experimental
                : .unavailable
        case .sourceReported:
            return explicitResearchOptIn ? .experimental : .unavailable
        }
    }
}

public enum ForgeCompactMemoryPressure: String, Codable, Sendable {
    case normal
    case elevated
    case critical
}

public enum ForgeCompactContextMode: String, Codable, Sendable {
    case full
    case reduced
    case minimal
}

public struct ForgeCompactPressurePolicy: Codable, Equatable, Sendable {
    public let contextMode: ForgeCompactContextMode
    public let permitsDeepModelTier: Bool
    public let permitsSpeculativeDecoding: Bool
    public let permitsExperimentalBeyondRAMByPressure: Bool
    public let preservesAlwaysResidentTruth: Bool
}

public enum ForgeCompactPressureGovernor {
    public static func policy(for pressure: ForgeCompactMemoryPressure) -> ForgeCompactPressurePolicy {
        switch pressure {
        case .normal:
            return ForgeCompactPressurePolicy(
                contextMode: .full,
                permitsDeepModelTier: true,
                permitsSpeculativeDecoding: true,
                permitsExperimentalBeyondRAMByPressure: true,
                preservesAlwaysResidentTruth: true
            )
        case .elevated:
            return ForgeCompactPressurePolicy(
                contextMode: .reduced,
                permitsDeepModelTier: true,
                permitsSpeculativeDecoding: false,
                permitsExperimentalBeyondRAMByPressure: false,
                preservesAlwaysResidentTruth: true
            )
        case .critical:
            return ForgeCompactPressurePolicy(
                contextMode: .minimal,
                permitsDeepModelTier: false,
                permitsSpeculativeDecoding: false,
                permitsExperimentalBeyondRAMByPressure: false,
                preservesAlwaysResidentTruth: true
            )
        }
    }
}

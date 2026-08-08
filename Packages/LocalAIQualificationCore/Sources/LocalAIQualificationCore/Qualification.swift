public enum LocalAICompatibilityBadge: String, Codable, Hashable, Sendable {
    case qualified
    case experimental
    case unsupported
    case unverified
}

/// Current product qualification authority. This is intentionally not Codable:
/// persisted evidence must be re-evaluated against the app's current standard.
public struct LocalAIQualificationStandard: Hashable, Sendable {
    public let standardID: String
    public let standardRevision: String
    public let taskSuiteID: String
    public let taskSuiteRevision: String
    public let requiredTaskIDs: [String]

    public init(
        standardID: String,
        standardRevision: String,
        taskSuiteID: String,
        taskSuiteRevision: String,
        requiredTaskIDs: [String]
    ) throws {
        self.standardID = try validatedIdentifier(standardID, field: "standardID")
        self.standardRevision = try validatedIdentifier(standardRevision, field: "standardRevision")
        self.taskSuiteID = try validatedIdentifier(taskSuiteID, field: "taskSuiteID")
        self.taskSuiteRevision = try validatedIdentifier(taskSuiteRevision, field: "taskSuiteRevision")
        guard !requiredTaskIDs.isEmpty else { throw LocalAIQualificationError.invalidTaskSuite }

        var seen = Set<String>()
        var canonical: [String] = []
        for rawID in requiredTaskIDs {
            let taskID = try validatedIdentifier(rawID, field: "requiredTaskID")
            guard seen.insert(taskID).inserted else {
                throw LocalAIQualificationError.duplicateTaskID(taskID)
            }
            canonical.append(taskID)
        }
        self.requiredTaskIDs = canonical.sorted()
    }
}

public enum LocalAIQualificationEvaluator {
    public static func badge(
        for receipt: LocalAIQualificationReceipt?,
        against standard: LocalAIQualificationStandard
    ) -> LocalAICompatibilityBadge {
        guard let receipt else { return .unverified }

        guard receipt.taskSuite.suiteID == standard.taskSuiteID,
              receipt.taskSuite.suiteRevision == standard.taskSuiteRevision
        else {
            return .unverified
        }

        let taskOutcomes = Dictionary(uniqueKeysWithValues: receipt.taskSuite.results.map { ($0.taskID, $0.outcome) })
        guard standard.requiredTaskIDs.allSatisfy({ taskOutcomes[$0] != nil }) else {
            return .unverified
        }

        if receipt.measurements.memoryPressure == .terminated ||
            receipt.measurements.memoryPressure == .critical ||
            receipt.measurements.thermalEnd == .critical ||
            receipt.taskSuite.results.contains(where: { $0.outcome == .failed }) ||
            (receipt.localityPolicy == .localOnly && receipt.networkAudit == .externalAccessObserved) {
            return .unsupported
        }

        guard receipt.profile.device.environment == .physicalDevice,
              receipt.networkAudit != .notMeasured,
              !(receipt.localityPolicy == .localOnly && receipt.networkAudit != .noExternalAccessObserved),
              !receipt.profile.runtime.weightLoadingMode.isExperimental
        else {
            return .experimental
        }

        return .qualified
    }
}

public struct LocalAIQualificationArchive: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let profile: LocalAIExactProfile
    public let receipts: [LocalAIQualificationReceipt]

    public init(profile: LocalAIExactProfile, receipts: [LocalAIQualificationReceipt]) throws {
        guard !receipts.isEmpty else { throw LocalAIQualificationError.emptyArchive }
        var previousRevision = 0
        for receipt in receipts {
            guard receipt.profile == profile else { throw LocalAIQualificationError.archiveProfileMismatch }
            guard receipt.evidenceRevision > previousRevision else {
                throw LocalAIQualificationError.revisionNotIncreasing
            }
            previousRevision = receipt.evidenceRevision
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.profile = profile
        self.receipts = receipts
    }

    public var latestReceipt: LocalAIQualificationReceipt { receipts[receipts.count - 1] }

    public func badge(against standard: LocalAIQualificationStandard) -> LocalAICompatibilityBadge {
        LocalAIQualificationEvaluator.badge(for: latestReceipt, against: standard)
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, profile, receipts }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw LocalAIQualificationError.archiveSchemaUnsupported(schemaVersion)
        }
        let profile = try container.decode(LocalAIExactProfile.self, forKey: .profile)
        let receipts = try container.decode([LocalAIQualificationReceipt].self, forKey: .receipts)
        try self.init(profile: profile, receipts: receipts)
    }
}

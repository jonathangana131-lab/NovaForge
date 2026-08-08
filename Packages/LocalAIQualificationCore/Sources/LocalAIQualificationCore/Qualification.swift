public enum LocalAICompatibilityBadge: String, Codable, Hashable, Sendable {
    case qualified
    case experimental
    case unsupported
    case unverified
}

public enum LocalAIQualificationEvaluator {
    public static func badge(for receipt: LocalAIQualificationReceipt?) -> LocalAICompatibilityBadge {
        guard let receipt else { return .unverified }

        if receipt.measurements.memoryPressure == .terminated ||
            receipt.measurements.memoryPressure == .critical ||
            receipt.measurements.thermalEnd == .critical ||
            !receipt.taskSuite.allPassed ||
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
    public var badge: LocalAICompatibilityBadge { LocalAIQualificationEvaluator.badge(for: latestReceipt) }

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

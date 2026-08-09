import Foundation

public struct ForgeAccessibilityRequirement: Codable, Hashable, Sendable {
    public let id: ForgeAccessibilityID
    public let category: ForgeAccessibilityCategory
    public let environmentProfile: ForgeAccessibilityEnvironmentProfile

    public init(
        id: ForgeAccessibilityID,
        category: ForgeAccessibilityCategory,
        environmentProfile: ForgeAccessibilityEnvironmentProfile
    ) {
        self.id = id
        self.category = category
        self.environmentProfile = environmentProfile
    }
}

public struct ForgeAccessibilityAcceptancePolicy: Codable, Hashable, Sendable {
    public static let maximumRequirements = 32

    public let requirements: [ForgeAccessibilityRequirement]
    public let allowedExecutionKinds: [ForgeAccessibilityExecutionKind]
    public let requiredDeviceIdentifier: String?
    public let requiredOSBuild: String?
    public let blocksMediumFindings: Bool
    public let blocksLowFindings: Bool

    public init(
        requirements: [ForgeAccessibilityRequirement],
        allowedExecutionKinds: [ForgeAccessibilityExecutionKind],
        requiredDeviceIdentifier: String? = nil,
        requiredOSBuild: String? = nil,
        blocksMediumFindings: Bool = false,
        blocksLowFindings: Bool = false
    ) throws {
        guard !requirements.isEmpty else { throw ForgeAccessibilityError.emptyRequirements }
        guard requirements.count <= Self.maximumRequirements else {
            throw ForgeAccessibilityError.tooManyRequirements(requirements.count)
        }
        var requirementIDs = Set<ForgeAccessibilityID>()
        for requirement in requirements {
            guard requirementIDs.insert(requirement.id).inserted else {
                throw ForgeAccessibilityError.duplicateRequirementID(requirement.id.rawValue)
            }
        }

        guard !allowedExecutionKinds.isEmpty else { throw ForgeAccessibilityError.emptyExecutionKinds }
        let kindSet = Set(allowedExecutionKinds)
        guard kindSet.count == allowedExecutionKinds.count else {
            let duplicate = allowedExecutionKinds
                .map(\.rawValue)
                .sorted()
                .first { value in allowedExecutionKinds.filter { $0.rawValue == value }.count > 1 } ?? "unknown"
            throw ForgeAccessibilityError.duplicateExecutionKind(duplicate)
        }

        self.requirements = requirements
        self.allowedExecutionKinds = allowedExecutionKinds.sorted { $0.rawValue < $1.rawValue }
        self.requiredDeviceIdentifier = try Self.optionalEnvironmentValue(requiredDeviceIdentifier, field: "requiredDeviceIdentifier")
        self.requiredOSBuild = try Self.optionalEnvironmentValue(requiredOSBuild, field: "requiredOSBuild")
        self.blocksMediumFindings = blocksMediumFindings
        self.blocksLowFindings = blocksLowFindings
    }

    public func accepts(_ environment: ForgeAccessibilityEnvironment) -> Bool {
        guard allowedExecutionKinds.contains(environment.executionKind) else { return false }
        if let requiredDeviceIdentifier, environment.deviceIdentifier != requiredDeviceIdentifier { return false }
        if let requiredOSBuild, environment.osBuild != requiredOSBuild { return false }
        return true
    }

    private static func optionalEnvironmentValue(_ raw: String?, field: String) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == raw,
              (1...128).contains(value.utf8.count),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ForgeAccessibilityError.invalidEnvironment(field: field)
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case requirements, allowedExecutionKinds, requiredDeviceIdentifier, requiredOSBuild
        case blocksMediumFindings, blocksLowFindings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requirements: c.decode([ForgeAccessibilityRequirement].self, forKey: .requirements),
            allowedExecutionKinds: c.decode([ForgeAccessibilityExecutionKind].self, forKey: .allowedExecutionKinds),
            requiredDeviceIdentifier: c.decodeIfPresent(String.self, forKey: .requiredDeviceIdentifier),
            requiredOSBuild: c.decodeIfPresent(String.self, forKey: .requiredOSBuild),
            blocksMediumFindings: c.decode(Bool.self, forKey: .blocksMediumFindings),
            blocksLowFindings: c.decode(Bool.self, forKey: .blocksLowFindings)
        )
    }
}

public enum ForgeAccessibilityFindingSeverity: Int, Codable, CaseIterable, Hashable, Sendable, Comparable {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ForgeAccessibilityFinding: Codable, Hashable, Sendable {
    public let id: ForgeAccessibilityID
    public let category: ForgeAccessibilityCategory
    public let severity: ForgeAccessibilityFindingSeverity
    public let summary: String
    public let elementID: ForgeAccessibilityID?

    public init(
        id: ForgeAccessibilityID,
        category: ForgeAccessibilityCategory,
        severity: ForgeAccessibilityFindingSeverity,
        summary: String,
        elementID: ForgeAccessibilityID? = nil
    ) throws {
        self.id = id
        self.category = category
        self.severity = severity
        self.summary = try Self.validatedText(summary, field: "finding.summary", maximumBytes: 512)
        self.elementID = elementID
    }

    private static func validatedText(_ raw: String, field: String, maximumBytes: Int) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == raw,
              (1...maximumBytes).contains(value.utf8.count),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ForgeAccessibilityError.invalidText(field: field)
        }
        return value
    }

    private enum CodingKeys: String, CodingKey { case id, category, severity, summary, elementID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(ForgeAccessibilityID.self, forKey: .id),
            category: c.decode(ForgeAccessibilityCategory.self, forKey: .category),
            severity: c.decode(ForgeAccessibilityFindingSeverity.self, forKey: .severity),
            summary: c.decode(String.self, forKey: .summary),
            elementID: c.decodeIfPresent(ForgeAccessibilityID.self, forKey: .elementID)
        )
    }
}

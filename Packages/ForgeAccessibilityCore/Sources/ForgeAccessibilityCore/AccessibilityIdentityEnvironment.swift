import Foundation

public enum ForgeAccessibilityError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidText(field: String)
    case invalidEnvironment(field: String)
    case unsupportedSchema(Int)
    case emptyRequirements
    case tooManyRequirements(Int)
    case duplicateRequirementID(String)
    case emptyExecutionKinds
    case duplicateExecutionKind(String)
    case tooManyObservations(Int)
    case duplicateObservationID(String)
    case unknownRequirement(String)
    case duplicateObservationForRequirement(String)
    case observationTargetMismatch(String)
    case observationCategoryMismatch(String)
    case duplicateEvidenceReceiptID(String)
    case tooManyFindings(observationID: String, count: Int)
    case duplicateFindingID(String)
    case findingCategoryMismatch(String)
    case failedObservationRequiresFinding(String)
}

public struct ForgeAccessibilityID: Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == rawValue,
              (1...128).contains(value.utf8.count),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
        else {
            throw ForgeAccessibilityError.invalidIdentifier(rawValue)
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:/@,+"))
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ForgeAccessibilityError.invalidIdentifier(rawValue)
        }
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ForgeAccessibilityTarget: Codable, Hashable, Sendable {
    public let projectID: ForgeAccessibilityID
    public let sourceRevision: ForgeAccessibilityID
    public let journeyID: ForgeAccessibilityID?

    public init(
        projectID: ForgeAccessibilityID,
        sourceRevision: ForgeAccessibilityID,
        journeyID: ForgeAccessibilityID? = nil
    ) {
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.journeyID = journeyID
    }
}

public enum ForgeAccessibilityCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case semanticLabelsAndValues
    case voiceOverNavigation
    case touchTargets
    case dynamicType
    case reduceMotion
    case reduceTransparency
    case increasedContrast
    case keyboardAndSwitchFocus
    case orientationAndSafeAreas
    case textClippingAndReadability
}

public enum ForgeAccessibilityEnvironmentProfile: String, Codable, Hashable, Sendable {
    case defaultPresentation
    case voiceOver
    case dynamicTypeXXXL
    case reduceMotion
    case reduceTransparency
    case increasedContrast
    case voiceOverAndDynamicTypeXXXL
}

public enum ForgeAccessibilityExecutionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case simulator
    case physicalDevice
}

public enum ForgeAccessibilityOrientation: String, Codable, Hashable, Sendable {
    case portrait
    case landscape
}

public enum ForgeAccessibilityContentSize: String, Codable, CaseIterable, Hashable, Sendable {
    case large
    case extraLarge
    case extraExtraLarge
    case extraExtraExtraLarge
    case accessibilityMedium
    case accessibilityLarge
    case accessibilityExtraLarge
    case accessibilityExtraExtraLarge
    case accessibilityExtraExtraExtraLarge

    fileprivate var rank: Int {
        switch self {
        case .large: 0
        case .extraLarge: 1
        case .extraExtraLarge: 2
        case .extraExtraExtraLarge: 3
        case .accessibilityMedium: 4
        case .accessibilityLarge: 5
        case .accessibilityExtraLarge: 6
        case .accessibilityExtraExtraLarge: 7
        case .accessibilityExtraExtraExtraLarge: 8
        }
    }
}

public struct ForgeAccessibilityEnvironment: Codable, Hashable, Sendable {
    public let executionKind: ForgeAccessibilityExecutionKind
    public let deviceIdentifier: String
    public let osName: String
    public let osVersion: String
    public let osBuild: String
    public let orientation: ForgeAccessibilityOrientation
    public let contentSize: ForgeAccessibilityContentSize
    public let voiceOverEnabled: Bool
    public let reduceMotionEnabled: Bool
    public let reduceTransparencyEnabled: Bool
    public let increasedContrastEnabled: Bool

    public init(
        executionKind: ForgeAccessibilityExecutionKind,
        deviceIdentifier: String,
        osName: String,
        osVersion: String,
        osBuild: String,
        orientation: ForgeAccessibilityOrientation,
        contentSize: ForgeAccessibilityContentSize,
        voiceOverEnabled: Bool,
        reduceMotionEnabled: Bool,
        reduceTransparencyEnabled: Bool,
        increasedContrastEnabled: Bool
    ) throws {
        self.executionKind = executionKind
        self.deviceIdentifier = try Self.environmentValue(deviceIdentifier, field: "deviceIdentifier")
        self.osName = try Self.environmentValue(osName, field: "osName")
        self.osVersion = try Self.environmentValue(osVersion, field: "osVersion")
        self.osBuild = try Self.environmentValue(osBuild, field: "osBuild")
        self.orientation = orientation
        self.contentSize = contentSize
        self.voiceOverEnabled = voiceOverEnabled
        self.reduceMotionEnabled = reduceMotionEnabled
        self.reduceTransparencyEnabled = reduceTransparencyEnabled
        self.increasedContrastEnabled = increasedContrastEnabled
    }

    public func satisfies(_ profile: ForgeAccessibilityEnvironmentProfile) -> Bool {
        switch profile {
        case .defaultPresentation:
            true
        case .voiceOver:
            voiceOverEnabled
        case .dynamicTypeXXXL:
            contentSize.rank >= ForgeAccessibilityContentSize.extraExtraExtraLarge.rank
        case .reduceMotion:
            reduceMotionEnabled
        case .reduceTransparency:
            reduceTransparencyEnabled
        case .increasedContrast:
            increasedContrastEnabled
        case .voiceOverAndDynamicTypeXXXL:
            voiceOverEnabled && contentSize.rank >= ForgeAccessibilityContentSize.extraExtraExtraLarge.rank
        }
    }

    private static func environmentValue(_ raw: String, field: String) throws -> String {
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
        case executionKind, deviceIdentifier, osName, osVersion, osBuild, orientation, contentSize
        case voiceOverEnabled, reduceMotionEnabled, reduceTransparencyEnabled, increasedContrastEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            executionKind: c.decode(ForgeAccessibilityExecutionKind.self, forKey: .executionKind),
            deviceIdentifier: c.decode(String.self, forKey: .deviceIdentifier),
            osName: c.decode(String.self, forKey: .osName),
            osVersion: c.decode(String.self, forKey: .osVersion),
            osBuild: c.decode(String.self, forKey: .osBuild),
            orientation: c.decode(ForgeAccessibilityOrientation.self, forKey: .orientation),
            contentSize: c.decode(ForgeAccessibilityContentSize.self, forKey: .contentSize),
            voiceOverEnabled: c.decode(Bool.self, forKey: .voiceOverEnabled),
            reduceMotionEnabled: c.decode(Bool.self, forKey: .reduceMotionEnabled),
            reduceTransparencyEnabled: c.decode(Bool.self, forKey: .reduceTransparencyEnabled),
            increasedContrastEnabled: c.decode(Bool.self, forKey: .increasedContrastEnabled)
        )
    }
}

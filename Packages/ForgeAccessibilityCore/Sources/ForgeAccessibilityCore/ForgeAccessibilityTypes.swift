import Foundation

public enum ForgeAccessibilityError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidText(String)
    case unsupportedSchema(Int)
    case collectionTooLarge(field: String, maximum: Int)
    case duplicateScenarioID(String)
    case duplicateRequiredCheck(scenarioID: String, check: ForgeAccessibilityCheckKind)
    case duplicateRunID(String)
    case duplicateProducerReceiptID(String)
    case duplicateTrustedProducerReceiptID(String)
    case duplicateScenarioEvidence(String)
    case duplicateCheckKind(runID: String, check: ForgeAccessibilityCheckKind)
    case targetMismatch(String)
    case unknownScenario(String)
    case invalidCheckResult(String)
    case insufficientBaselineCoverage(String)
    case emptyExecutionKinds
    case duplicateExecutionKind(ForgeAccessibilityExecutionKind)
    case invalidExecutionEnvironment(String)
}

enum ForgeAccessibilityValidation {
    static func identifier(_ value: String, field: String, maximumLength: Int = 512) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else {
            throw ForgeAccessibilityError.invalidIdentifier(field)
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgeAccessibilityError.invalidIdentifier(field)
        }
        return trimmed
    }

    static func text(_ value: String, field: String, maximumLength: Int = 4_096) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else {
            throw ForgeAccessibilityError.invalidText(field)
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgeAccessibilityError.invalidText(field)
        }
        return trimmed
    }

    static func maximumCount(_ count: Int, field: String, maximum: Int) throws {
        guard count <= maximum else {
            throw ForgeAccessibilityError.collectionTooLarge(field: field, maximum: maximum)
        }
    }
}

/// Exact generated-product state the accessibility evidence describes.
/// Receipt authentication remains owned by the host producer boundary.
public struct ForgeAccessibilityTarget: Codable, Equatable, Hashable, Sendable {
    public let projectID: String
    public let sourceRevision: String
    public let checkpointID: String
    public let runtimeVersion: String

    public init(
        projectID: String,
        sourceRevision: String,
        checkpointID: String,
        runtimeVersion: String
    ) throws {
        self.projectID = try ForgeAccessibilityValidation.identifier(
            projectID,
            field: "target.projectID",
            maximumLength: 256
        )
        self.sourceRevision = try ForgeAccessibilityValidation.identifier(
            sourceRevision,
            field: "target.sourceRevision"
        )
        self.checkpointID = try ForgeAccessibilityValidation.identifier(
            checkpointID,
            field: "target.checkpointID",
            maximumLength: 256
        )
        self.runtimeVersion = try ForgeAccessibilityValidation.identifier(
            runtimeVersion,
            field: "target.runtimeVersion",
            maximumLength: 256
        )
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case sourceRevision
        case checkpointID
        case runtimeVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            checkpointID: container.decode(String.self, forKey: .checkpointID),
            runtimeVersion: container.decode(String.self, forKey: .runtimeVersion)
        )
    }
}


public enum ForgeAccessibilityExecutionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case simulator
    case physicalDevice
}

/// Concrete host execution environment that produced accessibility observations.
/// Simulator evidence and physical-device evidence remain structurally distinct.
public struct ForgeAccessibilityExecutionContext: Codable, Equatable, Hashable, Sendable {
    public let kind: ForgeAccessibilityExecutionKind
    public let deviceIdentifier: String
    public let osName: String
    public let osVersion: String
    public let osBuild: String

    public init(
        kind: ForgeAccessibilityExecutionKind,
        deviceIdentifier: String,
        osName: String,
        osVersion: String,
        osBuild: String
    ) throws {
        self.kind = kind
        self.deviceIdentifier = try ForgeAccessibilityValidation.identifier(
            deviceIdentifier,
            field: "execution.deviceIdentifier",
            maximumLength: 128
        )
        self.osName = try ForgeAccessibilityValidation.identifier(
            osName,
            field: "execution.osName",
            maximumLength: 64
        )
        self.osVersion = try ForgeAccessibilityValidation.identifier(
            osVersion,
            field: "execution.osVersion",
            maximumLength: 64
        )
        self.osBuild = try ForgeAccessibilityValidation.identifier(
            osBuild,
            field: "execution.osBuild",
            maximumLength: 128
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case deviceIdentifier
        case osName
        case osVersion
        case osBuild
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(ForgeAccessibilityExecutionKind.self, forKey: .kind),
            deviceIdentifier: container.decode(String.self, forKey: .deviceIdentifier),
            osName: container.decode(String.self, forKey: .osName),
            osVersion: container.decode(String.self, forKey: .osVersion),
            osBuild: container.decode(String.self, forKey: .osBuild)
        )
    }
}

public enum ForgeAccessibilityOrientation: String, Codable, CaseIterable, Hashable, Sendable {
    case portrait
    case landscape
}

public enum ForgeAccessibilityAssistiveTechnology: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case voiceOver
}

public enum ForgeAccessibilityContentSize: String, Codable, CaseIterable, Hashable, Sendable {
    case large
    case extraExtraExtraLarge
    case accessibilityMedium
    case accessibilityLarge
    case accessibilityExtraLarge
    case accessibilityExtraExtraLarge
    case accessibilityExtraExtraExtraLarge

    public var isAccessibilitySize: Bool {
        switch self {
        case .large, .extraExtraExtraLarge:
            return false
        case .accessibilityMedium,
             .accessibilityLarge,
             .accessibilityExtraLarge,
             .accessibilityExtraExtraLarge,
             .accessibilityExtraExtraExtraLarge:
            return true
        }
    }
}

public struct ForgeAccessibilityEnvironment: Codable, Equatable, Hashable, Sendable {
    public let orientation: ForgeAccessibilityOrientation
    public let assistiveTechnology: ForgeAccessibilityAssistiveTechnology
    public let contentSize: ForgeAccessibilityContentSize
    public let reduceMotion: Bool
    public let reduceTransparency: Bool
    public let increasedContrast: Bool
    public let differentiateWithoutColor: Bool
    public let boldText: Bool

    public init(
        orientation: ForgeAccessibilityOrientation,
        assistiveTechnology: ForgeAccessibilityAssistiveTechnology,
        contentSize: ForgeAccessibilityContentSize,
        reduceMotion: Bool = false,
        reduceTransparency: Bool = false,
        increasedContrast: Bool = false,
        differentiateWithoutColor: Bool = false,
        boldText: Bool = false
    ) {
        self.orientation = orientation
        self.assistiveTechnology = assistiveTechnology
        self.contentSize = contentSize
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.increasedContrast = increasedContrast
        self.differentiateWithoutColor = differentiateWithoutColor
        self.boldText = boldText
    }
}

public enum ForgeAccessibilityCheckKind: String, Codable, CaseIterable, Hashable, Sendable {
    case voiceOverReachability
    case semanticNameRoleValue
    case focusOrder
    case touchTargetGeometry
    case dynamicTypeLayout
    case reduceMotionBehavior
    case reduceTransparencyFallback
    case contrast
    case keyboardFocus
}

public struct ForgeAccessibilityScenario: Codable, Equatable, Sendable {
    public static let maximumRequiredChecks = 32

    public let id: String
    public let environment: ForgeAccessibilityEnvironment
    public let requiredChecks: [ForgeAccessibilityCheckKind]

    public init(
        id: String,
        environment: ForgeAccessibilityEnvironment,
        requiredChecks: [ForgeAccessibilityCheckKind]
    ) throws {
        self.id = try ForgeAccessibilityValidation.identifier(
            id,
            field: "scenario.id",
            maximumLength: 256
        )
        guard !requiredChecks.isEmpty else {
            throw ForgeAccessibilityError.insufficientBaselineCoverage("scenario:\(self.id):requiredChecks")
        }
        try ForgeAccessibilityValidation.maximumCount(
            requiredChecks.count,
            field: "scenario.requiredChecks",
            maximum: Self.maximumRequiredChecks
        )

        var seen = Set<ForgeAccessibilityCheckKind>()
        for check in requiredChecks {
            guard seen.insert(check).inserted else {
                throw ForgeAccessibilityError.duplicateRequiredCheck(scenarioID: self.id, check: check)
            }
        }
        self.environment = environment
        self.requiredChecks = requiredChecks.sorted { $0.rawValue < $1.rawValue }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case environment
        case requiredChecks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            environment: container.decode(ForgeAccessibilityEnvironment.self, forKey: .environment),
            requiredChecks: container.decode([ForgeAccessibilityCheckKind].self, forKey: .requiredChecks)
        )
    }
}

import Foundation


public struct ForgeAccessibilityExecutionPolicy: Codable, Equatable, Sendable {
    public let allowedKinds: [ForgeAccessibilityExecutionKind]
    public let requiredDeviceIdentifier: String?
    public let requiredOSBuild: String?

    public init(
        allowedKinds: [ForgeAccessibilityExecutionKind],
        requiredDeviceIdentifier: String? = nil,
        requiredOSBuild: String? = nil
    ) throws {
        guard !allowedKinds.isEmpty else {
            throw ForgeAccessibilityError.emptyExecutionKinds
        }
        var seen = Set<ForgeAccessibilityExecutionKind>()
        for kind in allowedKinds {
            guard seen.insert(kind).inserted else {
                throw ForgeAccessibilityError.duplicateExecutionKind(kind)
            }
        }
        self.allowedKinds = allowedKinds.sorted { $0.rawValue < $1.rawValue }
        self.requiredDeviceIdentifier = try Self.optionalIdentifier(
            requiredDeviceIdentifier,
            field: "executionPolicy.requiredDeviceIdentifier"
        )
        self.requiredOSBuild = try Self.optionalIdentifier(
            requiredOSBuild,
            field: "executionPolicy.requiredOSBuild"
        )
    }

    public func accepts(_ context: ForgeAccessibilityExecutionContext) -> Bool {
        guard allowedKinds.contains(context.kind) else { return false }
        if let requiredDeviceIdentifier, requiredDeviceIdentifier != context.deviceIdentifier { return false }
        if let requiredOSBuild, requiredOSBuild != context.osBuild { return false }
        return true
    }

    private static func optionalIdentifier(_ value: String?, field: String) throws -> String? {
        guard let value else { return nil }
        return try ForgeAccessibilityValidation.identifier(value, field: field, maximumLength: 128)
    }

    private enum CodingKeys: String, CodingKey {
        case allowedKinds
        case requiredDeviceIdentifier
        case requiredOSBuild
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            allowedKinds: container.decode([ForgeAccessibilityExecutionKind].self, forKey: .allowedKinds),
            requiredDeviceIdentifier: container.decodeIfPresent(String.self, forKey: .requiredDeviceIdentifier),
            requiredOSBuild: container.decodeIfPresent(String.self, forKey: .requiredOSBuild)
        )
    }
}

/// Host-authored accessibility acceptance policy for one exact product state.
/// A policy that omits the baseline accessibility surfaces cannot mint an accepted projection.
public struct ForgeAccessibilityPolicy: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumScenarios = 64

    public let schemaVersion: Int
    public let target: ForgeAccessibilityTarget
    public let executionPolicy: ForgeAccessibilityExecutionPolicy
    public let scenarios: [ForgeAccessibilityScenario]

    public init(
        target: ForgeAccessibilityTarget,
        executionPolicy: ForgeAccessibilityExecutionPolicy,
        scenarios: [ForgeAccessibilityScenario]
    ) throws {
        guard !scenarios.isEmpty else {
            throw ForgeAccessibilityError.insufficientBaselineCoverage("policy.scenarios")
        }
        try ForgeAccessibilityValidation.maximumCount(
            scenarios.count,
            field: "policy.scenarios",
            maximum: Self.maximumScenarios
        )

        var seen = Set<String>()
        for scenario in scenarios {
            guard seen.insert(scenario.id).inserted else {
                throw ForgeAccessibilityError.duplicateScenarioID(scenario.id)
            }
        }
        try Self.validateBaselineCoverage(scenarios)

        self.schemaVersion = Self.currentSchemaVersion
        self.target = target
        self.executionPolicy = executionPolicy
        self.scenarios = scenarios.sorted { $0.id < $1.id }
    }

    private static func validateBaselineCoverage(_ scenarios: [ForgeAccessibilityScenario]) throws {
        let requiredBaseline: Set<ForgeAccessibilityCheckKind> = [
            .voiceOverReachability,
            .semanticNameRoleValue,
            .focusOrder,
            .touchTargetGeometry,
            .dynamicTypeLayout,
            .reduceMotionBehavior,
            .reduceTransparencyFallback,
            .contrast,
        ]
        let declaredChecks = Set(scenarios.flatMap(\.requiredChecks))
        if let missing = requiredBaseline.subtracting(declaredChecks).sorted(by: { $0.rawValue < $1.rawValue }).first {
            throw ForgeAccessibilityError.insufficientBaselineCoverage("missing:\(missing.rawValue)")
        }

        let voiceOverCoverage = scenarios.contains { scenario in
            scenario.environment.assistiveTechnology == .voiceOver
                && scenario.requiredChecks.contains(.voiceOverReachability)
                && scenario.requiredChecks.contains(.semanticNameRoleValue)
                && scenario.requiredChecks.contains(.focusOrder)
        }
        guard voiceOverCoverage else {
            throw ForgeAccessibilityError.insufficientBaselineCoverage("voiceOverEnvironment")
        }

        let dynamicTypeCoverage = scenarios.contains { scenario in
            scenario.environment.contentSize.isAccessibilitySize
                && scenario.requiredChecks.contains(.dynamicTypeLayout)
        }
        guard dynamicTypeCoverage else {
            throw ForgeAccessibilityError.insufficientBaselineCoverage("accessibilityContentSize")
        }

        let reduceMotionCoverage = scenarios.contains { scenario in
            scenario.environment.reduceMotion
                && scenario.requiredChecks.contains(.reduceMotionBehavior)
        }
        guard reduceMotionCoverage else {
            throw ForgeAccessibilityError.insufficientBaselineCoverage("reduceMotionEnvironment")
        }

        let reduceTransparencyCoverage = scenarios.contains { scenario in
            scenario.environment.reduceTransparency
                && scenario.requiredChecks.contains(.reduceTransparencyFallback)
        }
        guard reduceTransparencyCoverage else {
            throw ForgeAccessibilityError.insufficientBaselineCoverage("reduceTransparencyEnvironment")
        }

        let contrastCoverage = scenarios.contains { scenario in
            scenario.environment.increasedContrast
                && scenario.requiredChecks.contains(.contrast)
        }
        guard contrastCoverage else {
            throw ForgeAccessibilityError.insufficientBaselineCoverage("increasedContrastEnvironment")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case target
        case executionPolicy
        case scenarios
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeAccessibilityError.unsupportedSchema(schemaVersion)
        }
        try self.init(
            target: container.decode(ForgeAccessibilityTarget.self, forKey: .target),
            executionPolicy: container.decode(ForgeAccessibilityExecutionPolicy.self, forKey: .executionPolicy),
            scenarios: container.decode([ForgeAccessibilityScenario].self, forKey: .scenarios)
        )
    }
}

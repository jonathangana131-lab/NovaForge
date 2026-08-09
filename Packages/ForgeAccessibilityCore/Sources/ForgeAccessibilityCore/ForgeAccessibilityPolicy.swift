import Foundation

/// Host-authored accessibility acceptance policy for one exact product state.
/// A policy that omits the baseline accessibility surfaces cannot mint an accepted projection.
public struct ForgeAccessibilityPolicy: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumScenarios = 64

    public let schemaVersion: Int
    public let target: ForgeAccessibilityTarget
    public let scenarios: [ForgeAccessibilityScenario]

    public init(target: ForgeAccessibilityTarget, scenarios: [ForgeAccessibilityScenario]) throws {
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
            scenarios: container.decode([ForgeAccessibilityScenario].self, forKey: .scenarios)
        )
    }
}

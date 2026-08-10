import Foundation

public struct ForgePerformanceThresholds: Codable, Equatable, Sendable {
    public let minimumFrameSamples: Int
    public let maximumP95FrameTimeMilliseconds: Double
    public let maximumP99FrameTimeMilliseconds: Double
    public let maximumPeakResidentMemoryBytes: UInt64?
    public let minimumInteractionSamples: Int?
    public let maximumInteractionP95LatencyMilliseconds: Double?
    public let maximumColdLaunchMilliseconds: Double?

    public init(
        minimumFrameSamples: Int,
        maximumP95FrameTimeMilliseconds: Double,
        maximumP99FrameTimeMilliseconds: Double,
        maximumPeakResidentMemoryBytes: UInt64? = nil,
        minimumInteractionSamples: Int? = nil,
        maximumInteractionP95LatencyMilliseconds: Double? = nil,
        maximumColdLaunchMilliseconds: Double? = nil
    ) throws {
        guard (1...1_000_000).contains(minimumFrameSamples) else { throw ForgePerformanceError.invalidPolicy("thresholds.minimumFrameSamples") }
        let p95 = try ForgePerformanceValidation.finiteNonnegative(maximumP95FrameTimeMilliseconds, field: "thresholds.maximumP95FrameTimeMilliseconds")
        let p99 = try ForgePerformanceValidation.finiteNonnegative(maximumP99FrameTimeMilliseconds, field: "thresholds.maximumP99FrameTimeMilliseconds")
        guard p95 > 0, p99 >= p95 else { throw ForgePerformanceError.invalidPolicy("thresholds.frameTimes") }
        if let maximumPeakResidentMemoryBytes, maximumPeakResidentMemoryBytes == 0 { throw ForgePerformanceError.invalidPolicy("thresholds.maximumPeakResidentMemoryBytes") }
        if let minimumInteractionSamples, !(1...1_000_000).contains(minimumInteractionSamples) { throw ForgePerformanceError.invalidPolicy("thresholds.minimumInteractionSamples") }
        let interactionLimit = try maximumInteractionP95LatencyMilliseconds.map { try ForgePerformanceValidation.finiteNonnegative($0, field: "thresholds.maximumInteractionP95LatencyMilliseconds") }
        if let interactionLimit, interactionLimit == 0 { throw ForgePerformanceError.invalidPolicy("thresholds.maximumInteractionP95LatencyMilliseconds") }
        guard (minimumInteractionSamples == nil) == (maximumInteractionP95LatencyMilliseconds == nil) else {
            throw ForgePerformanceError.invalidPolicy("thresholds.interactionPair")
        }
        let launchLimit = try maximumColdLaunchMilliseconds.map { try ForgePerformanceValidation.finiteNonnegative($0, field: "thresholds.maximumColdLaunchMilliseconds") }
        if let launchLimit, launchLimit == 0 { throw ForgePerformanceError.invalidPolicy("thresholds.maximumColdLaunchMilliseconds") }

        self.minimumFrameSamples = minimumFrameSamples
        self.maximumP95FrameTimeMilliseconds = p95
        self.maximumP99FrameTimeMilliseconds = p99
        self.maximumPeakResidentMemoryBytes = maximumPeakResidentMemoryBytes
        self.minimumInteractionSamples = minimumInteractionSamples
        self.maximumInteractionP95LatencyMilliseconds = interactionLimit
        self.maximumColdLaunchMilliseconds = launchLimit
    }

    private enum CodingKeys: String, CodingKey {
        case minimumFrameSamples, maximumP95FrameTimeMilliseconds, maximumP99FrameTimeMilliseconds
        case maximumPeakResidentMemoryBytes, minimumInteractionSamples, maximumInteractionP95LatencyMilliseconds, maximumColdLaunchMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minimumFrameSamples: c.decode(Int.self, forKey: .minimumFrameSamples),
            maximumP95FrameTimeMilliseconds: c.decode(Double.self, forKey: .maximumP95FrameTimeMilliseconds),
            maximumP99FrameTimeMilliseconds: c.decode(Double.self, forKey: .maximumP99FrameTimeMilliseconds),
            maximumPeakResidentMemoryBytes: c.decodeIfPresent(UInt64.self, forKey: .maximumPeakResidentMemoryBytes),
            minimumInteractionSamples: c.decodeIfPresent(Int.self, forKey: .minimumInteractionSamples),
            maximumInteractionP95LatencyMilliseconds: c.decodeIfPresent(Double.self, forKey: .maximumInteractionP95LatencyMilliseconds),
            maximumColdLaunchMilliseconds: c.decodeIfPresent(Double.self, forKey: .maximumColdLaunchMilliseconds)
        )
    }
}

public struct ForgePerformanceScenario: Codable, Equatable, Sendable {
    public let id: String
    public let revision: String
    public let executionContext: ForgePerformanceExecutionContext
    public let thresholds: ForgePerformanceThresholds

    public init(id: String, revision: String, executionContext: ForgePerformanceExecutionContext, thresholds: ForgePerformanceThresholds) throws {
        self.id = try ForgePerformanceValidation.identifier(id, field: "scenario.id", maximumLength: 256)
        self.revision = try ForgePerformanceValidation.identifier(revision, field: "scenario.revision", maximumLength: 256)
        self.executionContext = executionContext
        self.thresholds = thresholds
    }

    private enum CodingKeys: String, CodingKey { case id, revision, executionContext, thresholds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id),
            revision: c.decode(String.self, forKey: .revision),
            executionContext: c.decode(ForgePerformanceExecutionContext.self, forKey: .executionContext),
            thresholds: c.decode(ForgePerformanceThresholds.self, forKey: .thresholds)
        )
    }
}

public struct ForgePerformancePolicy: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumScenarios = 32

    public let schema: Int
    public let policyRevision: String
    public let target: ForgePerformanceTarget
    public let scenarios: [ForgePerformanceScenario]

    public init(schema: Int = Self.schemaVersion, policyRevision: String, target: ForgePerformanceTarget, scenarios: [ForgePerformanceScenario]) throws {
        guard schema == Self.schemaVersion else { throw ForgePerformanceError.unsupportedSchema(schema) }
        self.policyRevision = try ForgePerformanceValidation.identifier(policyRevision, field: "policy.policyRevision", maximumLength: 256)
        guard !scenarios.isEmpty else { throw ForgePerformanceError.invalidPolicy("policy.scenarios") }
        try ForgePerformanceValidation.maximumCount(scenarios.count, field: "policy.scenarios", maximum: Self.maximumScenarios)
        var seen = Set<String>()
        for scenario in scenarios where !seen.insert(scenario.id).inserted { throw ForgePerformanceError.duplicateScenarioID(scenario.id) }
        self.schema = schema
        self.target = target
        self.scenarios = scenarios.sorted { $0.id < $1.id }
    }

    private enum CodingKeys: String, CodingKey { case schema, policyRevision, target, scenarios }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: c.decode(Int.self, forKey: .schema),
            policyRevision: c.decode(String.self, forKey: .policyRevision),
            target: c.decode(ForgePerformanceTarget.self, forKey: .target),
            scenarios: c.decode([ForgePerformanceScenario].self, forKey: .scenarios)
        )
    }
}

/// Non-Codable host trust for the complete acceptance policy. Its initializer is module-internal
/// so caller/model-authored policy bytes cannot relax thresholds and mint their own definition of done.
public struct ForgePerformanceTrustedPolicyReceipt: Equatable, Sendable {
    private let authenticatedPolicy: ForgePerformancePolicy

    public var policyRevision: String { authenticatedPolicy.policyRevision }
    public var target: ForgePerformanceTarget { authenticatedPolicy.target }

    init(authenticatedPolicy: ForgePerformancePolicy) {
        self.authenticatedPolicy = authenticatedPolicy
    }

    func exactlyMatches(_ policy: ForgePerformancePolicy) -> Bool { authenticatedPolicy == policy }
}

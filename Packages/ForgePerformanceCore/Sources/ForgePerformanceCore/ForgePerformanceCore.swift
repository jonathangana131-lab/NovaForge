import Foundation

public enum ForgePerformanceError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidText(String)
    case invalidExecutionContext(String)
    case invalidBudget(String)
    case duplicateBudgetMetric(ForgePerformanceMetricKind)
    case invalidObservation(String)
    case duplicateObservationMetric(ForgePerformanceMetricKind)
    case targetMismatch
    case scenarioMismatch
    case untrustedProducer
    case unsupportedSchema(Int)
    case archiveMismatch
}

enum ForgePerformanceValidation {
    static func identifier(_ value: String, field: String, maximumLength: Int = 256) throws -> String {
        guard !value.isEmpty, value.count <= maximumLength, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ForgePerformanceError.invalidIdentifier(field)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:@/,"))
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ForgePerformanceError.invalidIdentifier(field)
        }
        return value
    }

    static func text(_ value: String, field: String, maximumLength: Int) throws -> String {
        guard !value.isEmpty, value.count <= maximumLength, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgePerformanceError.invalidText(field)
        }
        return value
    }
}

public struct ForgePerformanceTarget: Codable, Equatable, Sendable {
    public let missionID: String
    public let projectID: String
    public let sourceRevision: String
    public let checkpointID: String
    public let constitutionRevision: Int

    public init(missionID: String, projectID: String, sourceRevision: String, checkpointID: String, constitutionRevision: Int) throws {
        self.missionID = try ForgePerformanceValidation.identifier(missionID, field: "target.missionID")
        self.projectID = try ForgePerformanceValidation.identifier(projectID, field: "target.projectID")
        self.sourceRevision = try ForgePerformanceValidation.identifier(sourceRevision, field: "target.sourceRevision", maximumLength: 512)
        self.checkpointID = try ForgePerformanceValidation.identifier(checkpointID, field: "target.checkpointID")
        guard constitutionRevision >= 0 else { throw ForgePerformanceError.invalidIdentifier("target.constitutionRevision") }
        self.constitutionRevision = constitutionRevision
    }

    private enum CodingKeys: String, CodingKey { case missionID, projectID, sourceRevision, checkpointID, constitutionRevision }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            missionID: c.decode(String.self, forKey: .missionID),
            projectID: c.decode(String.self, forKey: .projectID),
            sourceRevision: c.decode(String.self, forKey: .sourceRevision),
            checkpointID: c.decode(String.self, forKey: .checkpointID),
            constitutionRevision: c.decode(Int.self, forKey: .constitutionRevision)
        )
    }
}

public enum ForgePerformanceEnvironment: String, Codable, CaseIterable, Sendable {
    case physicalDevice
    case simulator
    case macHost
}

public struct ForgePerformanceExecutionContext: Codable, Equatable, Sendable {
    public let runtimeID: String
    public let runtimeRevision: String
    public let environment: ForgePerformanceEnvironment
    public let hardwareIdentifier: String
    public let osVersion: String
    public let osBuild: String

    public init(runtimeID: String, runtimeRevision: String, environment: ForgePerformanceEnvironment, hardwareIdentifier: String, osVersion: String, osBuild: String) throws {
        self.runtimeID = try ForgePerformanceValidation.identifier(runtimeID, field: "context.runtimeID")
        self.runtimeRevision = try ForgePerformanceValidation.identifier(runtimeRevision, field: "context.runtimeRevision")
        self.environment = environment
        self.hardwareIdentifier = try ForgePerformanceValidation.identifier(hardwareIdentifier, field: "context.hardwareIdentifier")
        self.osVersion = try ForgePerformanceValidation.text(osVersion, field: "context.osVersion", maximumLength: 128)
        self.osBuild = try ForgePerformanceValidation.identifier(osBuild, field: "context.osBuild", maximumLength: 128)
    }

    private enum CodingKeys: String, CodingKey { case runtimeID, runtimeRevision, environment, hardwareIdentifier, osVersion, osBuild }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            runtimeID: c.decode(String.self, forKey: .runtimeID),
            runtimeRevision: c.decode(String.self, forKey: .runtimeRevision),
            environment: c.decode(ForgePerformanceEnvironment.self, forKey: .environment),
            hardwareIdentifier: c.decode(String.self, forKey: .hardwareIdentifier),
            osVersion: c.decode(String.self, forKey: .osVersion),
            osBuild: c.decode(String.self, forKey: .osBuild)
        )
    }
}

public enum ForgePerformanceUnit: String, Codable, CaseIterable, Sendable {
    case milliseconds
    case ratio
    case bytes
}

public enum ForgePerformanceMetricKind: String, Codable, CaseIterable, Sendable {
    case frameTimeP95Milliseconds
    case frameTimeP99Milliseconds
    case droppedFrameRatio
    case interactionLatencyP95Milliseconds
    case launchTimeMilliseconds
    case peakResidentMemoryBytes

    public var unit: ForgePerformanceUnit {
        switch self {
        case .frameTimeP95Milliseconds, .frameTimeP99Milliseconds, .interactionLatencyP95Milliseconds, .launchTimeMilliseconds:
            return .milliseconds
        case .droppedFrameRatio:
            return .ratio
        case .peakResidentMemoryBytes:
            return .bytes
        }
    }

    fileprivate func validates(value: Double) -> Bool {
        guard value.isFinite, value >= 0 else { return false }
        if self == .droppedFrameRatio { return value <= 1 }
        return true
    }
}

public struct ForgePerformanceBudget: Codable, Equatable, Sendable {
    public let metric: ForgePerformanceMetricKind
    public let maximumAllowedValue: Double
    public let minimumSampleCount: Int

    public init(metric: ForgePerformanceMetricKind, maximumAllowedValue: Double, minimumSampleCount: Int) throws {
        guard metric.validates(value: maximumAllowedValue),
              (1...10_000_000).contains(minimumSampleCount) else {
            throw ForgePerformanceError.invalidBudget(metric.rawValue)
        }
        self.metric = metric
        self.maximumAllowedValue = maximumAllowedValue
        self.minimumSampleCount = minimumSampleCount
    }

    private enum CodingKeys: String, CodingKey { case metric, maximumAllowedValue, minimumSampleCount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metric: c.decode(ForgePerformanceMetricKind.self, forKey: .metric),
            maximumAllowedValue: c.decode(Double.self, forKey: .maximumAllowedValue),
            minimumSampleCount: c.decode(Int.self, forKey: .minimumSampleCount)
        )
    }
}

public struct ForgePerformancePolicy: Codable, Equatable, Sendable {
    public static let maximumBudgets = 32
    public let policyID: String
    public let target: ForgePerformanceTarget
    public let scenarioID: String
    public let budgets: [ForgePerformanceBudget]

    public init(policyID: String, target: ForgePerformanceTarget, scenarioID: String, budgets: [ForgePerformanceBudget]) throws {
        self.policyID = try ForgePerformanceValidation.identifier(policyID, field: "policy.policyID")
        self.target = target
        self.scenarioID = try ForgePerformanceValidation.identifier(scenarioID, field: "policy.scenarioID")
        guard !budgets.isEmpty, budgets.count <= Self.maximumBudgets else { throw ForgePerformanceError.invalidBudget("policy.budgets") }
        var seen = Set<ForgePerformanceMetricKind>()
        for budget in budgets where !seen.insert(budget.metric).inserted { throw ForgePerformanceError.duplicateBudgetMetric(budget.metric) }
        self.budgets = budgets.sorted { $0.metric.rawValue < $1.metric.rawValue }
    }

    private enum CodingKeys: String, CodingKey { case policyID, target, scenarioID, budgets }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            policyID: c.decode(String.self, forKey: .policyID),
            target: c.decode(ForgePerformanceTarget.self, forKey: .target),
            scenarioID: c.decode(String.self, forKey: .scenarioID),
            budgets: c.decode([ForgePerformanceBudget].self, forKey: .budgets)
        )
    }
}

public struct ForgePerformanceObservation: Codable, Equatable, Sendable {
    public let metric: ForgePerformanceMetricKind
    public let measuredValue: Double
    public let sampleCount: Int

    public init(metric: ForgePerformanceMetricKind, measuredValue: Double, sampleCount: Int) throws {
        guard metric.validates(value: measuredValue), (1...10_000_000).contains(sampleCount) else {
            throw ForgePerformanceError.invalidObservation(metric.rawValue)
        }
        self.metric = metric
        self.measuredValue = measuredValue
        self.sampleCount = sampleCount
    }

    private enum CodingKeys: String, CodingKey { case metric, measuredValue, sampleCount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metric: c.decode(ForgePerformanceMetricKind.self, forKey: .metric),
            measuredValue: c.decode(Double.self, forKey: .measuredValue),
            sampleCount: c.decode(Int.self, forKey: .sampleCount)
        )
    }
}

public enum ForgePerformanceEvidenceAuthority: String, Codable, CaseIterable, Sendable {
    case hostRuntimeProfiler
    case xctestMetricHarness
    case instrumentsImport
}

/// Codable run data is candidate evidence only. `authority` and `producerReceiptID` cannot authorize themselves.
public struct ForgePerformanceRunEvidence: Codable, Equatable, Sendable {
    public static let maximumObservations = 32
    public let runID: String
    public let target: ForgePerformanceTarget
    public let executionContext: ForgePerformanceExecutionContext
    public let scenarioID: String
    public let authority: ForgePerformanceEvidenceAuthority
    public let producerReceiptID: String
    public let observations: [ForgePerformanceObservation]

    public init(runID: String, target: ForgePerformanceTarget, executionContext: ForgePerformanceExecutionContext, scenarioID: String, authority: ForgePerformanceEvidenceAuthority, producerReceiptID: String, observations: [ForgePerformanceObservation]) throws {
        self.runID = try ForgePerformanceValidation.identifier(runID, field: "run.runID")
        self.target = target
        self.executionContext = executionContext
        self.scenarioID = try ForgePerformanceValidation.identifier(scenarioID, field: "run.scenarioID")
        self.authority = authority
        self.producerReceiptID = try ForgePerformanceValidation.identifier(producerReceiptID, field: "run.producerReceiptID", maximumLength: 512)
        guard !observations.isEmpty, observations.count <= Self.maximumObservations else { throw ForgePerformanceError.invalidObservation("run.observations") }
        var seen = Set<ForgePerformanceMetricKind>()
        for observation in observations where !seen.insert(observation.metric).inserted { throw ForgePerformanceError.duplicateObservationMetric(observation.metric) }
        self.observations = observations.sorted { $0.metric.rawValue < $1.metric.rawValue }
    }

    private enum CodingKeys: String, CodingKey { case runID, target, executionContext, scenarioID, authority, producerReceiptID, observations }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            runID: c.decode(String.self, forKey: .runID),
            target: c.decode(ForgePerformanceTarget.self, forKey: .target),
            executionContext: c.decode(ForgePerformanceExecutionContext.self, forKey: .executionContext),
            scenarioID: c.decode(String.self, forKey: .scenarioID),
            authority: c.decode(ForgePerformanceEvidenceAuthority.self, forKey: .authority),
            producerReceiptID: c.decode(String.self, forKey: .producerReceiptID),
            observations: c.decode([ForgePerformanceObservation].self, forKey: .observations)
        )
    }
}

/// Host trust binds the entire validated run. It is intentionally non-Codable and not externally constructible.
public struct ForgePerformanceTrustedProducerReceipt: Equatable, Sendable {
    private let authenticatedRun: ForgePerformanceRunEvidence
    public var runID: String { authenticatedRun.runID }
    public var producerReceiptID: String { authenticatedRun.producerReceiptID }
    public var target: ForgePerformanceTarget { authenticatedRun.target }
    public var executionContext: ForgePerformanceExecutionContext { authenticatedRun.executionContext }
    public var scenarioID: String { authenticatedRun.scenarioID }
    public var authority: ForgePerformanceEvidenceAuthority { authenticatedRun.authority }

    init(authenticatedRun: ForgePerformanceRunEvidence) { self.authenticatedRun = authenticatedRun }
    func exactlyMatches(_ run: ForgePerformanceRunEvidence) -> Bool { authenticatedRun == run }
}

public enum ForgePerformanceBlocker: Equatable, Sendable {
    case missingMetric(ForgePerformanceMetricKind)
    case insufficientSamples(metric: ForgePerformanceMetricKind, required: Int, actual: Int)
    case exceedsBudget(metric: ForgePerformanceMetricKind, maximum: Double, actual: Double)
}

public struct ForgePerformanceAcceptedReceipt: Equatable, Sendable {
    private let acceptedPolicy: ForgePerformancePolicy
    private let acceptedRun: ForgePerformanceRunEvidence

    public var policyID: String { acceptedPolicy.policyID }
    public var runID: String { acceptedRun.runID }
    public var target: ForgePerformanceTarget { acceptedRun.target }
    public var scenarioID: String { acceptedRun.scenarioID }
    public var producerReceiptID: String { acceptedRun.producerReceiptID }
    public var executionContext: ForgePerformanceExecutionContext { acceptedRun.executionContext }
    public var budgets: [ForgePerformanceBudget] { acceptedPolicy.budgets }
    public var observations: [ForgePerformanceObservation] { acceptedRun.observations }

    init(policy: ForgePerformancePolicy, run: ForgePerformanceRunEvidence) {
        self.acceptedPolicy = policy
        self.acceptedRun = run
    }
}

public struct ForgePerformanceEvaluation: Equatable, Sendable {
    public let blockers: [ForgePerformanceBlocker]
    public let acceptedReceipt: ForgePerformanceAcceptedReceipt?
    public var passed: Bool { acceptedReceipt != nil && blockers.isEmpty }

    init(blockers: [ForgePerformanceBlocker], acceptedReceipt: ForgePerformanceAcceptedReceipt?) {
        self.blockers = blockers
        self.acceptedReceipt = acceptedReceipt
    }
}

public enum ForgePerformanceEvaluator {
    public static func evaluate(policy: ForgePerformancePolicy, run: ForgePerformanceRunEvidence, trustedProducer: ForgePerformanceTrustedProducerReceipt) throws -> ForgePerformanceEvaluation {
        guard policy.target == run.target else { throw ForgePerformanceError.targetMismatch }
        guard policy.scenarioID == run.scenarioID else { throw ForgePerformanceError.scenarioMismatch }
        guard trustedProducer.exactlyMatches(run) else { throw ForgePerformanceError.untrustedProducer }

        let observations = Dictionary(uniqueKeysWithValues: run.observations.map { ($0.metric, $0) })
        var blockers: [ForgePerformanceBlocker] = []
        for budget in policy.budgets {
            guard let observation = observations[budget.metric] else {
                blockers.append(.missingMetric(budget.metric))
                continue
            }
            if observation.sampleCount < budget.minimumSampleCount {
                blockers.append(.insufficientSamples(metric: budget.metric, required: budget.minimumSampleCount, actual: observation.sampleCount))
                continue
            }
            if observation.measuredValue > budget.maximumAllowedValue {
                blockers.append(.exceedsBudget(metric: budget.metric, maximum: budget.maximumAllowedValue, actual: observation.measuredValue))
            }
        }

        blockers.sort { blockerKey($0) < blockerKey($1) }
        let receipt = blockers.isEmpty ? ForgePerformanceAcceptedReceipt(policy: policy, run: run) : nil
        return ForgePerformanceEvaluation(blockers: blockers, acceptedReceipt: receipt)
    }

    private static func blockerKey(_ blocker: ForgePerformanceBlocker) -> String {
        switch blocker {
        case .missingMetric(let metric): return "0:\(metric.rawValue)"
        case .insufficientSamples(let metric, _, _): return "1:\(metric.rawValue)"
        case .exceedsBudget(let metric, _, _): return "2:\(metric.rawValue)"
        }
    }
}

/// Durable historical inputs only. Decoding never restores trusted producer or accepted performance authority.
public struct ForgePerformanceArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let policy: ForgePerformancePolicy
    public let run: ForgePerformanceRunEvidence

    public init(policy: ForgePerformancePolicy, run: ForgePerformanceRunEvidence) throws {
        guard policy.target == run.target else { throw ForgePerformanceError.targetMismatch }
        guard policy.scenarioID == run.scenarioID else { throw ForgePerformanceError.scenarioMismatch }
        self.schemaVersion = Self.currentSchemaVersion
        self.policy = policy
        self.run = run
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, policy, run }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decode(Int.self, forKey: .schemaVersion)
        guard schema == Self.currentSchemaVersion else { throw ForgePerformanceError.unsupportedSchema(schema) }
        let policy = try c.decode(ForgePerformancePolicy.self, forKey: .policy)
        let run = try c.decode(ForgePerformanceRunEvidence.self, forKey: .run)
        try self.init(policy: policy, run: run)
    }

    /// Relaunch must supply fresh host trust for the exact archived run; pass state is always recomputed.
    public func restore(trustedProducer: ForgePerformanceTrustedProducerReceipt) throws -> ForgePerformanceEvaluation {
        try ForgePerformanceEvaluator.evaluate(policy: policy, run: run, trustedProducer: trustedProducer)
    }
}

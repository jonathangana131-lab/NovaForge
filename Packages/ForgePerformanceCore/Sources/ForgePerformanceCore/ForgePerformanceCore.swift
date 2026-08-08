import Foundation

public enum ForgePerformanceError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidRevision(String)
    case invalidConstraint(String)
    case invalidObservation(String)
    case invalidRunCount(Int)
    case collectionTooLarge(field: String, maximum: Int)
    case duplicateMetric(String)
    case duplicateRunID(String)
    case targetMismatch(String)
    case untrustedBudgetAuthorityReceipt(String)
    case untrustedBatchReceipt(String)
    case unsupportedSchema(Int)
}

private enum ForgePerformanceValidation {
    static func identifier(_ value: String, field: String, maximum: Int = 512) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value, trimmed.utf8.count <= maximum else {
            throw ForgePerformanceError.invalidIdentifier(field)
        }
        guard !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ForgePerformanceError.invalidIdentifier(field)
        }
        return trimmed
    }

    static func positiveRevision(_ value: Int, field: String) throws -> Int {
        guard value > 0 else { throw ForgePerformanceError.invalidRevision(field) }
        return value
    }

    static func boundedCount(_ count: Int, field: String, maximum: Int) throws {
        guard count <= maximum else {
            throw ForgePerformanceError.collectionTooLarge(field: field, maximum: maximum)
        }
    }
}

public enum ForgePerformanceEnvironmentKind: String, Codable, CaseIterable, Sendable {
    case physicalDevice
    case simulator
}

public struct ForgePerformanceEnvironment: Hashable, Codable, Sendable {
    public let kind: ForgePerformanceEnvironmentKind
    public let hardwareIdentifier: String
    public let osVersion: String
    public let osBuild: String

    public init(
        kind: ForgePerformanceEnvironmentKind,
        hardwareIdentifier: String,
        osVersion: String,
        osBuild: String
    ) throws {
        self.kind = kind
        self.hardwareIdentifier = try ForgePerformanceValidation.identifier(
            hardwareIdentifier,
            field: "environment.hardwareIdentifier",
            maximum: 256
        )
        self.osVersion = try ForgePerformanceValidation.identifier(
            osVersion,
            field: "environment.osVersion",
            maximum: 128
        )
        self.osBuild = try ForgePerformanceValidation.identifier(
            osBuild,
            field: "environment.osBuild",
            maximum: 128
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind, hardwareIdentifier, osVersion, osBuild
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(ForgePerformanceEnvironmentKind.self, forKey: .kind),
            hardwareIdentifier: container.decode(String.self, forKey: .hardwareIdentifier),
            osVersion: container.decode(String.self, forKey: .osVersion),
            osBuild: container.decode(String.self, forKey: .osBuild)
        )
    }
}

/// Exact accepted product/runtime/device authority for a performance budget and its measurements.
/// Receipt authenticity belongs to the host/Mission policy boundary; this value only binds identity.
public struct ForgePerformanceTarget: Hashable, Codable, Sendable {
    public let projectID: String
    public let sourceRevision: String
    public let missionID: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let environment: ForgePerformanceEnvironment
    public let measurementProtocolID: String
    public let measurementProtocolRevision: Int
    public let budgetRevision: Int
    public let budgetAuthorityReceiptID: String

    public init(
        projectID: String,
        sourceRevision: String,
        missionID: String,
        runtimeID: String,
        runtimeRevision: String,
        environment: ForgePerformanceEnvironment,
        measurementProtocolID: String,
        measurementProtocolRevision: Int,
        budgetRevision: Int,
        budgetAuthorityReceiptID: String
    ) throws {
        self.projectID = try ForgePerformanceValidation.identifier(projectID, field: "target.projectID", maximum: 256)
        self.sourceRevision = try ForgePerformanceValidation.identifier(sourceRevision, field: "target.sourceRevision")
        self.missionID = try ForgePerformanceValidation.identifier(missionID, field: "target.missionID", maximum: 256)
        self.runtimeID = try ForgePerformanceValidation.identifier(runtimeID, field: "target.runtimeID", maximum: 256)
        self.runtimeRevision = try ForgePerformanceValidation.identifier(runtimeRevision, field: "target.runtimeRevision")
        self.environment = environment
        self.measurementProtocolID = try ForgePerformanceValidation.identifier(
            measurementProtocolID,
            field: "target.measurementProtocolID",
            maximum: 256
        )
        self.measurementProtocolRevision = try ForgePerformanceValidation.positiveRevision(
            measurementProtocolRevision,
            field: "target.measurementProtocolRevision"
        )
        self.budgetRevision = try ForgePerformanceValidation.positiveRevision(
            budgetRevision,
            field: "target.budgetRevision"
        )
        self.budgetAuthorityReceiptID = try ForgePerformanceValidation.identifier(
            budgetAuthorityReceiptID,
            field: "target.budgetAuthorityReceiptID"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, sourceRevision, missionID, runtimeID, runtimeRevision, environment
        case measurementProtocolID, measurementProtocolRevision, budgetRevision, budgetAuthorityReceiptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            missionID: container.decode(String.self, forKey: .missionID),
            runtimeID: container.decode(String.self, forKey: .runtimeID),
            runtimeRevision: container.decode(String.self, forKey: .runtimeRevision),
            environment: container.decode(ForgePerformanceEnvironment.self, forKey: .environment),
            measurementProtocolID: container.decode(String.self, forKey: .measurementProtocolID),
            measurementProtocolRevision: container.decode(Int.self, forKey: .measurementProtocolRevision),
            budgetRevision: container.decode(Int.self, forKey: .budgetRevision),
            budgetAuthorityReceiptID: container.decode(String.self, forKey: .budgetAuthorityReceiptID)
        )
    }
}

public enum ForgePerformanceMetric: String, Codable, CaseIterable, Comparable, Sendable {
    case frameTimeP95Milliseconds
    case frameTimeP99Milliseconds
    case inputLatencyP95Milliseconds
    case launchTimeMilliseconds
    case peakResidentBytes
    case memoryPressureEventCount
    case thermalSeriousOrCriticalEventCount
    case droppedFramePercent
    case hitchRatePercent
    case energyMilliwattHours

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var unit: ForgePerformanceUnit {
        switch self {
        case .frameTimeP95Milliseconds, .frameTimeP99Milliseconds, .inputLatencyP95Milliseconds, .launchTimeMilliseconds:
            return .milliseconds
        case .peakResidentBytes:
            return .bytes
        case .memoryPressureEventCount, .thermalSeriousOrCriticalEventCount:
            return .count
        case .droppedFramePercent, .hitchRatePercent:
            return .percent
        case .energyMilliwattHours:
            return .milliwattHours
        }
    }
}

public enum ForgePerformanceUnit: String, Codable, Sendable {
    case milliseconds
    case bytes
    case count
    case percent
    case milliwattHours
}

/// Completion budgets are conservative upper bounds. Metrics are chosen so lower is better.
public struct ForgePerformanceConstraint: Hashable, Codable, Sendable {
    public static let maximumSamplesPerRun = 10_000_000

    public let metric: ForgePerformanceMetric
    public let maximumAllowed: Double
    public let minimumSamplesPerRun: Int

    public init(metric: ForgePerformanceMetric, maximumAllowed: Double, minimumSamplesPerRun: Int = 1) throws {
        guard maximumAllowed.isFinite, maximumAllowed >= 0 else {
            throw ForgePerformanceError.invalidConstraint(metric.rawValue)
        }
        switch metric.unit {
        case .percent:
            guard maximumAllowed <= 100 else { throw ForgePerformanceError.invalidConstraint(metric.rawValue) }
        case .bytes, .count:
            guard maximumAllowed.rounded(.towardZero) == maximumAllowed else {
                throw ForgePerformanceError.invalidConstraint(metric.rawValue)
            }
        case .milliseconds, .milliwattHours:
            break
        }
        guard (1...Self.maximumSamplesPerRun).contains(minimumSamplesPerRun) else {
            throw ForgePerformanceError.invalidConstraint(metric.rawValue)
        }
        self.metric = metric
        self.maximumAllowed = maximumAllowed
        self.minimumSamplesPerRun = minimumSamplesPerRun
    }

    private enum CodingKeys: String, CodingKey { case metric, maximumAllowed, minimumSamplesPerRun }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metric: container.decode(ForgePerformanceMetric.self, forKey: .metric),
            maximumAllowed: container.decode(Double.self, forKey: .maximumAllowed),
            minimumSamplesPerRun: container.decode(Int.self, forKey: .minimumSamplesPerRun)
        )
    }
}

public struct ForgePerformanceBudget: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumConstraints = 32
    public static let maximumRequiredRuns = 20

    public let schemaVersion: Int
    public let target: ForgePerformanceTarget
    public let requiredRunCount: Int
    public let constraints: [ForgePerformanceConstraint]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        target: ForgePerformanceTarget,
        requiredRunCount: Int,
        constraints: [ForgePerformanceConstraint]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgePerformanceError.unsupportedSchema(schemaVersion)
        }
        guard (1...Self.maximumRequiredRuns).contains(requiredRunCount) else {
            throw ForgePerformanceError.invalidRunCount(requiredRunCount)
        }
        guard !constraints.isEmpty else { throw ForgePerformanceError.invalidConstraint("constraints") }
        try ForgePerformanceValidation.boundedCount(
            constraints.count,
            field: "budget.constraints",
            maximum: Self.maximumConstraints
        )
        var seen = Set<ForgePerformanceMetric>()
        for constraint in constraints where !seen.insert(constraint.metric).inserted {
            throw ForgePerformanceError.duplicateMetric(constraint.metric.rawValue)
        }
        self.schemaVersion = schemaVersion
        self.target = target
        self.requiredRunCount = requiredRunCount
        self.constraints = constraints.sorted { $0.metric < $1.metric }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, target, requiredRunCount, constraints }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            target: container.decode(ForgePerformanceTarget.self, forKey: .target),
            requiredRunCount: container.decode(Int.self, forKey: .requiredRunCount),
            constraints: container.decode([ForgePerformanceConstraint].self, forKey: .constraints)
        )
    }
}

public struct ForgePerformanceObservation: Hashable, Codable, Sendable {
    public let metric: ForgePerformanceMetric
    public let value: Double
    public let sampleCount: Int

    public init(metric: ForgePerformanceMetric, value: Double, sampleCount: Int) throws {
        guard value.isFinite, value >= 0 else {
            throw ForgePerformanceError.invalidObservation(metric.rawValue)
        }
        switch metric.unit {
        case .percent:
            guard value <= 100 else { throw ForgePerformanceError.invalidObservation(metric.rawValue) }
        case .bytes, .count:
            guard value.rounded(.towardZero) == value else {
                throw ForgePerformanceError.invalidObservation(metric.rawValue)
            }
        case .milliseconds, .milliwattHours:
            break
        }
        guard (1...ForgePerformanceConstraint.maximumSamplesPerRun).contains(sampleCount) else {
            throw ForgePerformanceError.invalidObservation(metric.rawValue)
        }
        self.metric = metric
        self.value = value
        self.sampleCount = sampleCount
    }

    private enum CodingKeys: String, CodingKey { case metric, value, sampleCount }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metric: container.decode(ForgePerformanceMetric.self, forKey: .metric),
            value: container.decode(Double.self, forKey: .value),
            sampleCount: container.decode(Int.self, forKey: .sampleCount)
        )
    }
}

public struct ForgePerformanceRun: Hashable, Codable, Sendable {
    public static let maximumObservations = 64

    public let runID: String
    public let target: ForgePerformanceTarget
    public let observations: [ForgePerformanceObservation]

    public init(runID: String, target: ForgePerformanceTarget, observations: [ForgePerformanceObservation]) throws {
        self.runID = try ForgePerformanceValidation.identifier(runID, field: "run.runID", maximum: 256)
        guard !observations.isEmpty else { throw ForgePerformanceError.invalidObservation("run.observations") }
        try ForgePerformanceValidation.boundedCount(
            observations.count,
            field: "run.observations",
            maximum: Self.maximumObservations
        )
        var seen = Set<ForgePerformanceMetric>()
        for observation in observations where !seen.insert(observation.metric).inserted {
            throw ForgePerformanceError.duplicateMetric(observation.metric.rawValue)
        }
        self.target = target
        self.observations = observations.sorted { $0.metric < $1.metric }
    }

    private enum CodingKeys: String, CodingKey { case runID, target, observations }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            runID: container.decode(String.self, forKey: .runID),
            target: container.decode(ForgePerformanceTarget.self, forKey: .target),
            observations: container.decode([ForgePerformanceObservation].self, forKey: .observations)
        )
    }
}

/// A host measurement batch is the selective-omission seam: the host authority is responsible for
/// making `batchReceiptID` vouch for this complete run set rather than individual cherry-picked runs.
public struct ForgePerformanceMeasurementBatch: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumRuns = 32

    public let schemaVersion: Int
    public let batchReceiptID: String
    public let target: ForgePerformanceTarget
    public let runs: [ForgePerformanceRun]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        batchReceiptID: String,
        target: ForgePerformanceTarget,
        runs: [ForgePerformanceRun]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgePerformanceError.unsupportedSchema(schemaVersion)
        }
        self.batchReceiptID = try ForgePerformanceValidation.identifier(
            batchReceiptID,
            field: "batch.batchReceiptID"
        )
        guard !runs.isEmpty else { throw ForgePerformanceError.invalidRunCount(0) }
        try ForgePerformanceValidation.boundedCount(runs.count, field: "batch.runs", maximum: Self.maximumRuns)
        var seen = Set<String>()
        for run in runs {
            guard seen.insert(run.runID).inserted else {
                throw ForgePerformanceError.duplicateRunID(run.runID)
            }
            guard run.target == target else { throw ForgePerformanceError.targetMismatch("run:\(run.runID)") }
        }
        self.schemaVersion = schemaVersion
        self.target = target
        self.runs = runs.sorted { $0.runID < $1.runID }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, batchReceiptID, target, runs }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            batchReceiptID: container.decode(String.self, forKey: .batchReceiptID),
            target: container.decode(ForgePerformanceTarget.self, forKey: .target),
            runs: container.decode([ForgePerformanceRun].self, forKey: .runs)
        )
    }
}

public enum ForgePerformanceAcceptanceStatus: String, Sendable {
    case blocked
    case failed
    case accepted
}

public enum ForgePerformanceBlocker: Equatable, Sendable {
    case insufficientRuns(required: Int, actual: Int)
    case missingMetric(metric: ForgePerformanceMetric, runID: String)
    case insufficientSamples(metric: ForgePerformanceMetric, runID: String, required: Int, actual: Int)
}

public struct ForgePerformanceFailure: Equatable, Sendable {
    public let metric: ForgePerformanceMetric
    public let worstObserved: Double
    public let maximumAllowed: Double

    fileprivate init(metric: ForgePerformanceMetric, worstObserved: Double, maximumAllowed: Double) {
        self.metric = metric
        self.worstObserved = worstObserved
        self.maximumAllowed = maximumAllowed
    }
}

/// Derived-only evaluator output. It is deliberately non-Codable and cannot be restored as authority.
public struct ForgePerformanceEvaluation: Equatable, Sendable {
    public let status: ForgePerformanceAcceptanceStatus
    public let batchReceiptID: String
    public let blockers: [ForgePerformanceBlocker]
    public let failures: [ForgePerformanceFailure]
    public let acceptedMetricValues: [ForgePerformanceMetric: Double]

    fileprivate init(
        status: ForgePerformanceAcceptanceStatus,
        batchReceiptID: String,
        blockers: [ForgePerformanceBlocker],
        failures: [ForgePerformanceFailure],
        acceptedMetricValues: [ForgePerformanceMetric: Double]
    ) {
        self.status = status
        self.batchReceiptID = batchReceiptID
        self.blockers = blockers
        self.failures = failures
        self.acceptedMetricValues = acceptedMetricValues
    }
}

public enum ForgePerformanceEvaluator {
    /// Both trust sets must come from host-owned authorities, not model/persisted payload.
    /// Serialized budget/batch data cannot authorize itself merely by spelling receipt IDs.
    public static func evaluate(
        budget: ForgePerformanceBudget,
        batch: ForgePerformanceMeasurementBatch,
        trustedBudgetAuthorityReceiptIDs: Set<String>,
        trustedBatchReceiptIDs: Set<String>
    ) throws -> ForgePerformanceEvaluation {
        guard batch.target == budget.target else { throw ForgePerformanceError.targetMismatch("batch.target") }
        guard trustedBudgetAuthorityReceiptIDs.contains(budget.target.budgetAuthorityReceiptID) else {
            throw ForgePerformanceError.untrustedBudgetAuthorityReceipt(budget.target.budgetAuthorityReceiptID)
        }
        guard trustedBatchReceiptIDs.contains(batch.batchReceiptID) else {
            throw ForgePerformanceError.untrustedBatchReceipt(batch.batchReceiptID)
        }

        var blockers: [ForgePerformanceBlocker] = []
        if batch.runs.count < budget.requiredRunCount {
            blockers.append(.insufficientRuns(required: budget.requiredRunCount, actual: batch.runs.count))
        }

        let constraints = Dictionary(uniqueKeysWithValues: budget.constraints.map { ($0.metric, $0) })
        var worstValues: [ForgePerformanceMetric: Double] = [:]

        for run in batch.runs {
            let observations = Dictionary(uniqueKeysWithValues: run.observations.map { ($0.metric, $0) })
            for constraint in budget.constraints {
                guard let observation = observations[constraint.metric] else {
                    blockers.append(.missingMetric(metric: constraint.metric, runID: run.runID))
                    continue
                }
                guard observation.sampleCount >= constraint.minimumSamplesPerRun else {
                    blockers.append(
                        .insufficientSamples(
                            metric: constraint.metric,
                            runID: run.runID,
                            required: constraint.minimumSamplesPerRun,
                            actual: observation.sampleCount
                        )
                    )
                    continue
                }
                worstValues[constraint.metric] = max(worstValues[constraint.metric] ?? 0, observation.value)
            }
        }

        if !blockers.isEmpty {
            return ForgePerformanceEvaluation(
                status: .blocked,
                batchReceiptID: batch.batchReceiptID,
                blockers: blockers.sorted(by: blockerSort),
                failures: [],
                acceptedMetricValues: [:]
            )
        }

        let failures = worstValues.compactMap { metric, value -> ForgePerformanceFailure? in
            guard let constraint = constraints[metric], value > constraint.maximumAllowed else { return nil }
            return ForgePerformanceFailure(metric: metric, worstObserved: value, maximumAllowed: constraint.maximumAllowed)
        }.sorted { $0.metric < $1.metric }

        guard failures.isEmpty else {
            return ForgePerformanceEvaluation(
                status: .failed,
                batchReceiptID: batch.batchReceiptID,
                blockers: [],
                failures: failures,
                acceptedMetricValues: [:]
            )
        }

        return ForgePerformanceEvaluation(
            status: .accepted,
            batchReceiptID: batch.batchReceiptID,
            blockers: [],
            failures: [],
            acceptedMetricValues: worstValues
        )
    }

    private static func blockerSort(_ lhs: ForgePerformanceBlocker, _ rhs: ForgePerformanceBlocker) -> Bool {
        func key(_ blocker: ForgePerformanceBlocker) -> String {
            switch blocker {
            case let .insufficientRuns(required, actual):
                return "0|\(required)|\(actual)"
            case let .missingMetric(metric, runID):
                return "1|\(metric.rawValue)|\(runID)"
            case let .insufficientSamples(metric, runID, required, actual):
                return "2|\(metric.rawValue)|\(runID)|\(required)|\(actual)"
            }
        }
        return key(lhs) < key(rhs)
    }
}

/// Persist only validated raw budget/measurement inputs. Accepted/failed verdicts are always recomputed
/// with a fresh host-trusted receipt set and are never serialized here.
public struct ForgePerformanceEvidenceArchive: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let budget: ForgePerformanceBudget
    public let batch: ForgePerformanceMeasurementBatch

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        budget: ForgePerformanceBudget,
        batch: ForgePerformanceMeasurementBatch
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgePerformanceError.unsupportedSchema(schemaVersion)
        }
        guard budget.target == batch.target else { throw ForgePerformanceError.targetMismatch("archive.batch") }
        self.schemaVersion = schemaVersion
        self.budget = budget
        self.batch = batch
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, budget, batch }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            budget: container.decode(ForgePerformanceBudget.self, forKey: .budget),
            batch: container.decode(ForgePerformanceMeasurementBatch.self, forKey: .batch)
        )
    }
}

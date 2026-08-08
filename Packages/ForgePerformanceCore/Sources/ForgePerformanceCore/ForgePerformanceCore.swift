import Foundation

public enum ForgePerformanceError: Error, Equatable, Sendable {
    case blankValue(field: String)
    case valueTooLong(field: String, maximum: Int)
    case controlCharacter(field: String)
    case invalidMetricValue
    case invalidThreshold
    case invalidSampleCount
    case emptyRequirements
    case tooManyRequirements(maximum: Int)
    case tooManyObservations(maximum: Int)
    case duplicateRequirement(ForgePerformanceMetricKind)
    case duplicateObservation(ForgePerformanceMetricKind)
    case targetMismatch
    case budgetMismatch
    case duplicateReceiptID(String)
}

public struct ForgePerformanceTarget: Hashable, Sendable {
    public let projectID: String
    public let sourceRevision: String
    public let journeyID: String
    public let runID: String
    public let appBuildRevision: String
    public let runtimeRevision: String

    public init(
        projectID: String,
        sourceRevision: String,
        journeyID: String,
        runID: String,
        appBuildRevision: String,
        runtimeRevision: String
    ) throws {
        self.projectID = try ForgePerformanceValidation.stableValue(projectID, field: "projectID", maximum: 160)
        self.sourceRevision = try ForgePerformanceValidation.stableValue(sourceRevision, field: "sourceRevision", maximum: 200)
        self.journeyID = try ForgePerformanceValidation.stableValue(journeyID, field: "journeyID", maximum: 160)
        self.runID = try ForgePerformanceValidation.stableValue(runID, field: "runID", maximum: 160)
        self.appBuildRevision = try ForgePerformanceValidation.stableValue(appBuildRevision, field: "appBuildRevision", maximum: 200)
        self.runtimeRevision = try ForgePerformanceValidation.stableValue(runtimeRevision, field: "runtimeRevision", maximum: 200)
    }
}

public enum ForgePerformanceEnvironmentKind: String, Hashable, Sendable {
    case simulator
    case physicalDevice
}

public struct ForgePerformanceEnvironment: Hashable, Sendable {
    public let kind: ForgePerformanceEnvironmentKind
    public let deviceModel: String
    public let osVersion: String

    public init(kind: ForgePerformanceEnvironmentKind, deviceModel: String, osVersion: String) throws {
        self.kind = kind
        self.deviceModel = try ForgePerformanceValidation.stableValue(deviceModel, field: "deviceModel", maximum: 160)
        self.osVersion = try ForgePerformanceValidation.stableValue(osVersion, field: "osVersion", maximum: 160)
    }
}

/// A closed set of accepted measurement producers. Model output is intentionally not an authority.
public enum ForgePerformanceEvidenceAuthority: String, Hashable, Sendable {
    case runtimeHarness
    case testHarness
    case deviceMetricsHarness
}

public enum ForgePerformanceMetricUnit: String, Hashable, Sendable {
    case milliseconds
    case bytes
    case framesPerSecond
    case percent
    case eventsPerMinute
}

public enum ForgePerformanceMetricDirection: String, Hashable, Sendable {
    case maximum
    case minimum
}

public enum ForgePerformanceMetricKind: String, CaseIterable, Hashable, Sendable {
    case frameTimeP95Milliseconds
    case frameTimeP99Milliseconds
    case hitchRatePerMinute
    case startupToInteractiveMilliseconds
    case peakResidentMemoryBytes
    case droppedFrameRatePercent
    case sustainedFramesPerSecond
    case inputLatencyP95Milliseconds

    public var unit: ForgePerformanceMetricUnit {
        switch self {
        case .frameTimeP95Milliseconds, .frameTimeP99Milliseconds,
             .startupToInteractiveMilliseconds, .inputLatencyP95Milliseconds:
            return .milliseconds
        case .peakResidentMemoryBytes:
            return .bytes
        case .droppedFrameRatePercent:
            return .percent
        case .sustainedFramesPerSecond:
            return .framesPerSecond
        case .hitchRatePerMinute:
            return .eventsPerMinute
        }
    }

    public var direction: ForgePerformanceMetricDirection {
        switch self {
        case .sustainedFramesPerSecond:
            return .minimum
        default:
            return .maximum
        }
    }
}

public struct ForgePerformanceRequirement: Hashable, Sendable {
    public let metric: ForgePerformanceMetricKind
    public let threshold: Double
    public let minimumSampleCount: Int

    public init(
        metric: ForgePerformanceMetricKind,
        threshold: Double,
        minimumSampleCount: Int = 1
    ) throws {
        guard threshold.isFinite, threshold >= 0 else { throw ForgePerformanceError.invalidThreshold }
        if metric.unit == .percent, threshold > 100 {
            throw ForgePerformanceError.invalidThreshold
        }
        guard (1 ... 1_000_000).contains(minimumSampleCount) else {
            throw ForgePerformanceError.invalidSampleCount
        }
        self.metric = metric
        self.threshold = threshold
        self.minimumSampleCount = minimumSampleCount
    }

    public func passes(value: Double) -> Bool {
        switch metric.direction {
        case .maximum: return value <= threshold
        case .minimum: return value >= threshold
        }
    }
}

public enum ForgePerformanceEnvironmentRequirement: Hashable, Sendable {
    case measuredEnvironment
    case physicalDevice
    case exactPhysicalDevice(deviceModel: String, osVersion: String)

    fileprivate func normalized() throws -> Self {
        switch self {
        case .measuredEnvironment:
            return .measuredEnvironment
        case .physicalDevice:
            return .physicalDevice
        case let .exactPhysicalDevice(deviceModel, osVersion):
            return try .exactPhysicalDevice(
                deviceModel: ForgePerformanceValidation.stableValue(
                    deviceModel,
                    field: "requiredDeviceModel",
                    maximum: 160
                ),
                osVersion: ForgePerformanceValidation.stableValue(
                    osVersion,
                    field: "requiredOSVersion",
                    maximum: 160
                )
            )
        }
    }
}

public struct ForgePerformanceBudget: Hashable, Sendable {
    public static let maximumRequirements = ForgePerformanceMetricKind.allCases.count

    public let budgetID: String
    public let budgetRevision: String
    public let environmentRequirement: ForgePerformanceEnvironmentRequirement
    public let requirements: [ForgePerformanceRequirement]

    public init(
        budgetID: String,
        budgetRevision: String,
        environmentRequirement: ForgePerformanceEnvironmentRequirement,
        requirements: [ForgePerformanceRequirement]
    ) throws {
        self.budgetID = try ForgePerformanceValidation.stableValue(budgetID, field: "budgetID", maximum: 160)
        self.budgetRevision = try ForgePerformanceValidation.stableValue(budgetRevision, field: "budgetRevision", maximum: 200)
        guard !requirements.isEmpty else { throw ForgePerformanceError.emptyRequirements }
        guard requirements.count <= Self.maximumRequirements else {
            throw ForgePerformanceError.tooManyRequirements(maximum: Self.maximumRequirements)
        }
        var metrics = Set<ForgePerformanceMetricKind>()
        for requirement in requirements {
            guard metrics.insert(requirement.metric).inserted else {
                throw ForgePerformanceError.duplicateRequirement(requirement.metric)
            }
        }
        self.environmentRequirement = try environmentRequirement.normalized()
        self.requirements = requirements.sorted { $0.metric.rawValue < $1.metric.rawValue }
    }
}

public struct ForgePerformanceObservation: Hashable, Sendable {
    public let metric: ForgePerformanceMetricKind
    public let value: Double
    public let sampleCount: Int
    public let evidenceReceiptID: String

    public init(
        metric: ForgePerformanceMetricKind,
        value: Double,
        sampleCount: Int,
        evidenceReceiptID: String
    ) throws {
        guard value.isFinite, value >= 0 else { throw ForgePerformanceError.invalidMetricValue }
        if metric.unit == .percent, value > 100 {
            throw ForgePerformanceError.invalidMetricValue
        }
        guard (1 ... 1_000_000).contains(sampleCount) else {
            throw ForgePerformanceError.invalidSampleCount
        }
        self.metric = metric
        self.value = value
        self.sampleCount = sampleCount
        self.evidenceReceiptID = try ForgePerformanceValidation.stableValue(
            evidenceReceiptID,
            field: "evidenceReceiptID",
            maximum: 200
        )
    }
}

public struct ForgePerformanceMeasurement: Hashable, Sendable {
    public static let maximumObservations = ForgePerformanceMetricKind.allCases.count

    public let target: ForgePerformanceTarget
    public let environment: ForgePerformanceEnvironment
    public let authority: ForgePerformanceEvidenceAuthority
    public let budgetID: String
    public let budgetRevision: String
    public let observations: [ForgePerformanceObservation]

    public init(
        target: ForgePerformanceTarget,
        environment: ForgePerformanceEnvironment,
        authority: ForgePerformanceEvidenceAuthority,
        budgetID: String,
        budgetRevision: String,
        observations: [ForgePerformanceObservation]
    ) throws {
        self.target = target
        self.environment = environment
        self.authority = authority
        self.budgetID = try ForgePerformanceValidation.stableValue(budgetID, field: "budgetID", maximum: 160)
        self.budgetRevision = try ForgePerformanceValidation.stableValue(budgetRevision, field: "budgetRevision", maximum: 200)
        guard observations.count <= Self.maximumObservations else {
            throw ForgePerformanceError.tooManyObservations(maximum: Self.maximumObservations)
        }
        var metrics = Set<ForgePerformanceMetricKind>()
        var receipts = Set<String>()
        for observation in observations {
            guard metrics.insert(observation.metric).inserted else {
                throw ForgePerformanceError.duplicateObservation(observation.metric)
            }
            guard receipts.insert(observation.evidenceReceiptID).inserted else {
                throw ForgePerformanceError.duplicateReceiptID(observation.evidenceReceiptID)
            }
        }
        self.observations = observations.sorted { $0.metric.rawValue < $1.metric.rawValue }
    }
}

public enum ForgePerformanceBlocker: Hashable, Sendable {
    case physicalDeviceRequired
    case deviceModelMismatch(expected: String, actual: String)
    case osVersionMismatch(expected: String, actual: String)
    case missingMetric(ForgePerformanceMetricKind)
    case insufficientSamples(metric: ForgePerformanceMetricKind, required: Int, actual: Int)
}

public struct ForgePerformanceViolation: Hashable, Sendable {
    public let metric: ForgePerformanceMetricKind
    public let measuredValue: Double
    public let requiredThreshold: Double
    public let direction: ForgePerformanceMetricDirection

    fileprivate init(
        metric: ForgePerformanceMetricKind,
        measuredValue: Double,
        requiredThreshold: Double,
        direction: ForgePerformanceMetricDirection
    ) {
        self.metric = metric
        self.measuredValue = measuredValue
        self.requiredThreshold = requiredThreshold
        self.direction = direction
    }
}

public struct ForgePerformanceAcceptanceReceipt: Hashable, Sendable {
    public let target: ForgePerformanceTarget
    public let environment: ForgePerformanceEnvironment
    public let authority: ForgePerformanceEvidenceAuthority
    public let budgetID: String
    public let budgetRevision: String
    public let contributingReceiptIDs: [String]

    fileprivate init(
        target: ForgePerformanceTarget,
        environment: ForgePerformanceEnvironment,
        authority: ForgePerformanceEvidenceAuthority,
        budgetID: String,
        budgetRevision: String,
        contributingReceiptIDs: [String]
    ) {
        self.target = target
        self.environment = environment
        self.authority = authority
        self.budgetID = budgetID
        self.budgetRevision = budgetRevision
        self.contributingReceiptIDs = contributingReceiptIDs
    }
}

public enum ForgePerformanceVerdict: Hashable, Sendable {
    case inconclusive([ForgePerformanceBlocker])
    case failed([ForgePerformanceViolation])
    case accepted(ForgePerformanceAcceptanceReceipt)
}

public enum ForgePerformanceEvaluator {
    public static func evaluate(
        target: ForgePerformanceTarget,
        budget: ForgePerformanceBudget,
        measurement: ForgePerformanceMeasurement
    ) throws -> ForgePerformanceVerdict {
        guard measurement.target == target else { throw ForgePerformanceError.targetMismatch }
        guard measurement.budgetID == budget.budgetID,
              measurement.budgetRevision == budget.budgetRevision
        else { throw ForgePerformanceError.budgetMismatch }

        switch budget.environmentRequirement {
        case .measuredEnvironment:
            break
        case .physicalDevice:
            guard measurement.environment.kind == .physicalDevice else {
                return .inconclusive([.physicalDeviceRequired])
            }
        case let .exactPhysicalDevice(deviceModel, osVersion):
            guard measurement.environment.kind == .physicalDevice else {
                return .inconclusive([.physicalDeviceRequired])
            }
            var environmentBlockers: [ForgePerformanceBlocker] = []
            if measurement.environment.deviceModel != deviceModel {
                environmentBlockers.append(.deviceModelMismatch(
                    expected: deviceModel,
                    actual: measurement.environment.deviceModel
                ))
            }
            if measurement.environment.osVersion != osVersion {
                environmentBlockers.append(.osVersionMismatch(
                    expected: osVersion,
                    actual: measurement.environment.osVersion
                ))
            }
            if !environmentBlockers.isEmpty {
                return .inconclusive(environmentBlockers.sorted(by: blockerOrder))
            }
        }

        let observationsByMetric = Dictionary(
            uniqueKeysWithValues: measurement.observations.map { ($0.metric, $0) }
        )
        var blockers: [ForgePerformanceBlocker] = []
        var violations: [ForgePerformanceViolation] = []
        var contributingReceipts = Set<String>()

        for requirement in budget.requirements {
            guard let observation = observationsByMetric[requirement.metric] else {
                blockers.append(.missingMetric(requirement.metric))
                continue
            }
            guard observation.sampleCount >= requirement.minimumSampleCount else {
                blockers.append(.insufficientSamples(
                    metric: requirement.metric,
                    required: requirement.minimumSampleCount,
                    actual: observation.sampleCount
                ))
                continue
            }
            contributingReceipts.insert(observation.evidenceReceiptID)
            if !requirement.passes(value: observation.value) {
                violations.append(ForgePerformanceViolation(
                    metric: requirement.metric,
                    measuredValue: observation.value,
                    requiredThreshold: requirement.threshold,
                    direction: requirement.metric.direction
                ))
            }
        }

        if !violations.isEmpty {
            return .failed(violations.sorted { $0.metric.rawValue < $1.metric.rawValue })
        }
        if !blockers.isEmpty {
            return .inconclusive(blockers.sorted(by: blockerOrder))
        }
        return .accepted(ForgePerformanceAcceptanceReceipt(
            target: target,
            environment: measurement.environment,
            authority: measurement.authority,
            budgetID: budget.budgetID,
            budgetRevision: budget.budgetRevision,
            contributingReceiptIDs: contributingReceipts.sorted()
        ))
    }

    private static func blockerOrder(_ lhs: ForgePerformanceBlocker, _ rhs: ForgePerformanceBlocker) -> Bool {
        blockerKey(lhs) < blockerKey(rhs)
    }

    private static func blockerKey(_ blocker: ForgePerformanceBlocker) -> String {
        switch blocker {
        case .physicalDeviceRequired: return "0-physical-device-required"
        case let .deviceModelMismatch(expected, actual): return "1-device-\(expected)-\(actual)"
        case let .osVersionMismatch(expected, actual): return "2-os-\(expected)-\(actual)"
        case let .missingMetric(metric): return "3-missing-\(metric.rawValue)"
        case let .insufficientSamples(metric, _, _): return "4-samples-\(metric.rawValue)"
        }
    }
}

private enum ForgePerformanceValidation {
    static func stableValue(_ value: String, field: String, maximum: Int) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ForgePerformanceError.blankValue(field: field) }
        guard normalized.count <= maximum else {
            throw ForgePerformanceError.valueTooLong(field: field, maximum: maximum)
        }
        guard !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgePerformanceError.controlCharacter(field: field)
        }
        return normalized
    }
}

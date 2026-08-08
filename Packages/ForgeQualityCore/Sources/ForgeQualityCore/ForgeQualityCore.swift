import Foundation

public enum ForgeQualityError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidRevision
    case emptyPolicy
    case tooManyTargets
    case duplicateTarget(metric: ForgeQualityMetric, scope: ForgeQualityScope)
    case invalidThreshold(ForgeQualityMetric)
    case unsupportedComparator(metric: ForgeQualityMetric, comparator: ForgeQualityComparator)
    case invalidMeasurement(ForgeQualityMetric)
    case evidenceKindMismatch(metric: ForgeQualityMetric, expected: ForgeQualityEvidenceKind, actual: ForgeQualityEvidenceKind)
    case duplicateMeasurement(metric: ForgeQualityMetric, scope: ForgeQualityScope)
    case duplicateReceiptID(ForgeQualityID)
    case unexpectedMeasurement(metric: ForgeQualityMetric, scope: ForgeQualityScope)
    case evidenceBindingMismatch(receiptID: ForgeQualityID)
    case completionTargetMismatch
    case untrustedPolicyAuthorityReceipt(expected: ForgeQualityID, actual: ForgeQualityID)
}

public struct ForgeQualityID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isCanonical(rawValue) else {
            throw ForgeQualityError.invalidIdentifier
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: ForgeQualityID, rhs: ForgeQualityID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        try self.init(rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isCanonical(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public struct ForgeQualityCompletionTarget: Codable, Hashable, Sendable {
    public let missionID: ForgeQualityID
    public let projectID: ForgeQualityID
    public let sourceRevision: ForgeQualityID
    public let constitutionRevision: UInt64
    public let constitutionReceiptID: ForgeQualityID

    public init(
        missionID: ForgeQualityID,
        projectID: ForgeQualityID,
        sourceRevision: ForgeQualityID,
        constitutionRevision: UInt64,
        constitutionReceiptID: ForgeQualityID
    ) {
        self.missionID = missionID
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.constitutionRevision = constitutionRevision
        self.constitutionReceiptID = constitutionReceiptID
    }
}

public enum ForgeQualityMetric: String, CaseIterable, Codable, Hashable, Sendable {
    case averageFrameTimeMilliseconds
    case p95FrameTimeMilliseconds
    case p99FrameTimeMilliseconds
    case longFrameRatePercent
    case inputLatencyP95Milliseconds
    case fatalRuntimeErrorCount
    case accessibilityCriticalViolationCount
    case accessibilitySeriousViolationCount
    case clippedInteractiveControlCount

    public var expectedEvidenceKind: ForgeQualityEvidenceKind {
        switch self {
        case .averageFrameTimeMilliseconds,
             .p95FrameTimeMilliseconds,
             .p99FrameTimeMilliseconds,
             .longFrameRatePercent:
            return .runtimeTelemetry
        case .inputLatencyP95Milliseconds:
            return .interactionHarness
        case .fatalRuntimeErrorCount:
            return .runtimeDiagnostics
        case .accessibilityCriticalViolationCount,
             .accessibilitySeriousViolationCount,
             .clippedInteractiveControlCount:
            return .accessibilityAudit
        }
    }

    fileprivate func accepts(_ comparator: ForgeQualityComparator) -> Bool {
        // Every metric currently defined here is a maximum-bound quality budget.
        // Future higher-is-better metrics must opt in explicitly instead of inheriting
        // a comparator that could invert completion semantics.
        comparator == .atMost
    }

    fileprivate func accepts(_ value: Double) -> Bool {
        guard value.isFinite, value >= 0 else { return false }
        switch self {
        case .longFrameRatePercent:
            return value <= 100
        case .fatalRuntimeErrorCount,
             .accessibilityCriticalViolationCount,
             .accessibilitySeriousViolationCount,
             .clippedInteractiveControlCount:
            return value.rounded(.towardZero) == value
        default:
            return true
        }
    }
}

public enum ForgeQualityEvidenceKind: String, Codable, Hashable, Sendable {
    case runtimeTelemetry
    case runtimeDiagnostics
    case interactionHarness
    case accessibilityAudit
}

public enum ForgeQualityComparator: String, Codable, Hashable, Sendable {
    case atMost
    case atLeast

    fileprivate func accepts(value: Double, threshold: Double) -> Bool {
        switch self {
        case .atMost:
            return value <= threshold
        case .atLeast:
            return value >= threshold
        }
    }
}

public enum ForgeQualityEnvironmentKind: String, Codable, Hashable, Sendable {
    case simulator
    case physicalDevice
}

/// The acceptance scope a quality budget applies to. Journey scope prevents a
/// measurement from one autonomous playtest path from satisfying another path.
public enum ForgeQualityScope: Codable, Hashable, Sendable {
    case run
    case journey(ForgeQualityID)

    fileprivate var sortKey: String {
        switch self {
        case .run:
            return "0:run"
        case let .journey(journeyID):
            return "1:\(journeyID.rawValue)"
        }
    }
}

private struct ForgeQualityTargetKey: Hashable {
    let metric: ForgeQualityMetric
    let scope: ForgeQualityScope
}

public struct ForgeQualityTarget: Codable, Hashable, Sendable {
    public let metric: ForgeQualityMetric
    public let scope: ForgeQualityScope
    public let comparator: ForgeQualityComparator
    public let threshold: Double
    public let requiresPhysicalDevice: Bool

    public init(
        metric: ForgeQualityMetric,
        scope: ForgeQualityScope = .run,
        comparator: ForgeQualityComparator,
        threshold: Double,
        requiresPhysicalDevice: Bool = false
    ) throws {
        guard metric.accepts(comparator) else {
            throw ForgeQualityError.unsupportedComparator(metric: metric, comparator: comparator)
        }
        guard metric.accepts(threshold) else {
            throw ForgeQualityError.invalidThreshold(metric)
        }
        self.metric = metric
        self.scope = scope
        self.comparator = comparator
        self.threshold = threshold
        self.requiresPhysicalDevice = requiresPhysicalDevice
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metric: container.decode(ForgeQualityMetric.self, forKey: .metric),
            scope: container.decode(ForgeQualityScope.self, forKey: .scope),
            comparator: container.decode(ForgeQualityComparator.self, forKey: .comparator),
            threshold: container.decode(Double.self, forKey: .threshold),
            requiresPhysicalDevice: container.decode(Bool.self, forKey: .requiresPhysicalDevice)
        )
    }

    fileprivate var key: ForgeQualityTargetKey {
        ForgeQualityTargetKey(metric: metric, scope: scope)
    }
}

public struct ForgeQualityPolicy: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumTargets = 32

    public let schemaVersion: Int
    public let policyID: ForgeQualityID
    public let policyAuthorityReceiptID: ForgeQualityID
    public let criterionID: ForgeQualityID
    public let completionTarget: ForgeQualityCompletionTarget
    public let targets: [ForgeQualityTarget]

    public init(
        policyID: ForgeQualityID,
        policyAuthorityReceiptID: ForgeQualityID,
        criterionID: ForgeQualityID,
        completionTarget: ForgeQualityCompletionTarget,
        targets: [ForgeQualityTarget]
    ) throws {
        guard !targets.isEmpty else { throw ForgeQualityError.emptyPolicy }
        guard targets.count <= Self.maximumTargets else { throw ForgeQualityError.tooManyTargets }

        var seen = Set<ForgeQualityTargetKey>()
        for target in targets {
            guard seen.insert(target.key).inserted else {
                throw ForgeQualityError.duplicateTarget(metric: target.metric, scope: target.scope)
            }
        }

        self.schemaVersion = Self.currentSchemaVersion
        self.policyID = policyID
        self.policyAuthorityReceiptID = policyAuthorityReceiptID
        self.criterionID = criterionID
        self.completionTarget = completionTarget
        self.targets = targets.sorted { lhs, rhs in
            if lhs.scope.sortKey == rhs.scope.sortKey {
                return lhs.metric.rawValue < rhs.metric.rawValue
            }
            return lhs.scope.sortKey < rhs.scope.sortKey
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeQualityError.invalidRevision
        }
        try self.init(
            policyID: container.decode(ForgeQualityID.self, forKey: .policyID),
            policyAuthorityReceiptID: container.decode(ForgeQualityID.self, forKey: .policyAuthorityReceiptID),
            criterionID: container.decode(ForgeQualityID.self, forKey: .criterionID),
            completionTarget: container.decode(ForgeQualityCompletionTarget.self, forKey: .completionTarget),
            targets: container.decode([ForgeQualityTarget].self, forKey: .targets)
        )
    }
}

public struct ForgeQualityRunBinding: Codable, Hashable, Sendable {
    public let projectID: ForgeQualityID
    public let sourceRevision: ForgeQualityID
    public let checkpointID: ForgeQualityID
    public let runtimeRevision: ForgeQualityID
    public let runID: ForgeQualityID
    public let environmentKind: ForgeQualityEnvironmentKind
    public let environmentProfileID: ForgeQualityID
    public let osBuild: ForgeQualityID

    public init(
        projectID: ForgeQualityID,
        sourceRevision: ForgeQualityID,
        checkpointID: ForgeQualityID,
        runtimeRevision: ForgeQualityID,
        runID: ForgeQualityID,
        environmentKind: ForgeQualityEnvironmentKind,
        environmentProfileID: ForgeQualityID,
        osBuild: ForgeQualityID
    ) {
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.checkpointID = checkpointID
        self.runtimeRevision = runtimeRevision
        self.runID = runID
        self.environmentKind = environmentKind
        self.environmentProfileID = environmentProfileID
        self.osBuild = osBuild
    }
}

public struct ForgeQualityMeasurement: Codable, Hashable, Sendable {
    public let receiptID: ForgeQualityID
    public let binding: ForgeQualityRunBinding
    public let metric: ForgeQualityMetric
    public let scope: ForgeQualityScope
    public let evidenceKind: ForgeQualityEvidenceKind
    public let value: Double

    public init(
        receiptID: ForgeQualityID,
        binding: ForgeQualityRunBinding,
        metric: ForgeQualityMetric,
        scope: ForgeQualityScope = .run,
        evidenceKind: ForgeQualityEvidenceKind,
        value: Double
    ) throws {
        guard metric.accepts(value) else {
            throw ForgeQualityError.invalidMeasurement(metric)
        }
        guard evidenceKind == metric.expectedEvidenceKind else {
            throw ForgeQualityError.evidenceKindMismatch(
                metric: metric,
                expected: metric.expectedEvidenceKind,
                actual: evidenceKind
            )
        }
        self.receiptID = receiptID
        self.binding = binding
        self.metric = metric
        self.scope = scope
        self.evidenceKind = evidenceKind
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            receiptID: container.decode(ForgeQualityID.self, forKey: .receiptID),
            binding: container.decode(ForgeQualityRunBinding.self, forKey: .binding),
            metric: container.decode(ForgeQualityMetric.self, forKey: .metric),
            scope: container.decode(ForgeQualityScope.self, forKey: .scope),
            evidenceKind: container.decode(ForgeQualityEvidenceKind.self, forKey: .evidenceKind),
            value: container.decode(Double.self, forKey: .value)
        )
    }

    fileprivate var key: ForgeQualityTargetKey {
        ForgeQualityTargetKey(metric: metric, scope: scope)
    }
}

public enum ForgeQualityFindingReason: String, Codable, Hashable, Sendable {
    case missingEvidence
    case physicalDeviceRequired
    case thresholdExceeded
}

public struct ForgeQualityFinding: Codable, Hashable, Sendable {
    public let metric: ForgeQualityMetric
    public let scope: ForgeQualityScope
    public let reason: ForgeQualityFindingReason
    public let measuredValue: Double?
    public let comparator: ForgeQualityComparator
    public let threshold: Double

    public init(
        metric: ForgeQualityMetric,
        scope: ForgeQualityScope,
        reason: ForgeQualityFindingReason,
        measuredValue: Double?,
        comparator: ForgeQualityComparator,
        threshold: Double
    ) {
        self.metric = metric
        self.scope = scope
        self.reason = reason
        self.measuredValue = measuredValue
        self.comparator = comparator
        self.threshold = threshold
    }
}

public enum ForgeQualityGateStatus: String, Codable, Hashable, Sendable {
    case passed
    case blocked
    case failed
}

public struct ForgeQualityAssessment: Encodable, Hashable, Sendable {
    public let policyID: ForgeQualityID
    public let policyAuthorityReceiptID: ForgeQualityID
    public let criterionID: ForgeQualityID
    public let completionTarget: ForgeQualityCompletionTarget
    public let binding: ForgeQualityRunBinding
    public let status: ForgeQualityGateStatus
    public let findings: [ForgeQualityFinding]
    public let supportingReceiptIDs: [ForgeQualityID]
    public let acceptedReceiptIDs: [ForgeQualityID]

    fileprivate init(
        policyID: ForgeQualityID,
        policyAuthorityReceiptID: ForgeQualityID,
        criterionID: ForgeQualityID,
        completionTarget: ForgeQualityCompletionTarget,
        binding: ForgeQualityRunBinding,
        status: ForgeQualityGateStatus,
        findings: [ForgeQualityFinding],
        supportingReceiptIDs: [ForgeQualityID],
        acceptedReceiptIDs: [ForgeQualityID]
    ) {
        self.policyID = policyID
        self.policyAuthorityReceiptID = policyAuthorityReceiptID
        self.criterionID = criterionID
        self.completionTarget = completionTarget
        self.binding = binding
        self.status = status
        self.findings = findings
        self.supportingReceiptIDs = supportingReceiptIDs
        self.acceptedReceiptIDs = acceptedReceiptIDs
    }
}

public enum ForgeQualityEvaluator {
    public static func evaluate(
        policy: ForgeQualityPolicy,
        trustedPolicyAuthorityReceiptID: ForgeQualityID,
        acceptedCompletionTarget: ForgeQualityCompletionTarget,
        binding: ForgeQualityRunBinding,
        measurements: [ForgeQualityMeasurement]
    ) throws -> ForgeQualityAssessment {
        guard policy.policyAuthorityReceiptID == trustedPolicyAuthorityReceiptID else {
            throw ForgeQualityError.untrustedPolicyAuthorityReceipt(
                expected: trustedPolicyAuthorityReceiptID,
                actual: policy.policyAuthorityReceiptID
            )
        }
        guard policy.completionTarget == acceptedCompletionTarget else {
            throw ForgeQualityError.completionTargetMismatch
        }

        let measurementsByTarget = try validatedMeasurements(
            policy: policy,
            binding: binding,
            measurements: measurements
        )

        var findings: [ForgeQualityFinding] = []
        var supportingReceiptIDs: [ForgeQualityID] = []

        for target in policy.targets {
            guard let measurement = measurementsByTarget[target.key] else {
                findings.append(
                    ForgeQualityFinding(
                        metric: target.metric,
                        scope: target.scope,
                        reason: .missingEvidence,
                        measuredValue: nil,
                        comparator: target.comparator,
                        threshold: target.threshold
                    )
                )
                continue
            }

            supportingReceiptIDs.append(measurement.receiptID)

            if target.requiresPhysicalDevice, binding.environmentKind != .physicalDevice {
                findings.append(
                    ForgeQualityFinding(
                        metric: target.metric,
                        scope: target.scope,
                        reason: .physicalDeviceRequired,
                        measuredValue: measurement.value,
                        comparator: target.comparator,
                        threshold: target.threshold
                    )
                )
                continue
            }

            if !target.comparator.accepts(value: measurement.value, threshold: target.threshold) {
                findings.append(
                    ForgeQualityFinding(
                        metric: target.metric,
                        scope: target.scope,
                        reason: .thresholdExceeded,
                        measuredValue: measurement.value,
                        comparator: target.comparator,
                        threshold: target.threshold
                    )
                )
            }
        }

        findings.sort { lhs, rhs in
            if lhs.scope.sortKey == rhs.scope.sortKey {
                if lhs.metric.rawValue == rhs.metric.rawValue {
                    return lhs.reason.rawValue < rhs.reason.rawValue
                }
                return lhs.metric.rawValue < rhs.metric.rawValue
            }
            return lhs.scope.sortKey < rhs.scope.sortKey
        }
        supportingReceiptIDs.sort()

        let hasFailure = findings.contains { $0.reason == .thresholdExceeded }
        let hasBlocker = findings.contains {
            $0.reason == .missingEvidence || $0.reason == .physicalDeviceRequired
        }
        let status: ForgeQualityGateStatus
        if hasFailure {
            status = .failed
        } else if hasBlocker {
            status = .blocked
        } else {
            status = .passed
        }

        return ForgeQualityAssessment(
            policyID: policy.policyID,
            policyAuthorityReceiptID: policy.policyAuthorityReceiptID,
            criterionID: policy.criterionID,
            completionTarget: policy.completionTarget,
            binding: binding,
            status: status,
            findings: findings,
            supportingReceiptIDs: supportingReceiptIDs,
            acceptedReceiptIDs: status == .passed ? supportingReceiptIDs : []
        )
    }

    fileprivate static func validatedMeasurements(
        policy: ForgeQualityPolicy,
        binding: ForgeQualityRunBinding,
        measurements: [ForgeQualityMeasurement]
    ) throws -> [ForgeQualityTargetKey: ForgeQualityMeasurement] {
        guard policy.completionTarget.projectID == binding.projectID,
              policy.completionTarget.sourceRevision == binding.sourceRevision else {
            throw ForgeQualityError.completionTargetMismatch
        }

        let targetKeys = Set(policy.targets.map(\.key))
        var measurementsByTarget: [ForgeQualityTargetKey: ForgeQualityMeasurement] = [:]
        var receiptIDs = Set<ForgeQualityID>()

        for measurement in measurements {
            guard measurement.binding == binding else {
                throw ForgeQualityError.evidenceBindingMismatch(receiptID: measurement.receiptID)
            }
            guard targetKeys.contains(measurement.key) else {
                throw ForgeQualityError.unexpectedMeasurement(metric: measurement.metric, scope: measurement.scope)
            }
            guard measurementsByTarget[measurement.key] == nil else {
                throw ForgeQualityError.duplicateMeasurement(metric: measurement.metric, scope: measurement.scope)
            }
            guard receiptIDs.insert(measurement.receiptID).inserted else {
                throw ForgeQualityError.duplicateReceiptID(measurement.receiptID)
            }
            measurementsByTarget[measurement.key] = measurement
        }

        return measurementsByTarget
    }
}

public struct ForgeQualitySnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let policy: ForgeQualityPolicy
    public let binding: ForgeQualityRunBinding
    public let measurements: [ForgeQualityMeasurement]

    public init(
        policy: ForgeQualityPolicy,
        binding: ForgeQualityRunBinding,
        measurements: [ForgeQualityMeasurement]
    ) throws {
        _ = try ForgeQualityEvaluator.validatedMeasurements(
            policy: policy,
            binding: binding,
            measurements: measurements
        )
        self.schemaVersion = Self.currentSchemaVersion
        self.policy = policy
        self.binding = binding
        self.measurements = measurements.sorted { lhs, rhs in
            if lhs.scope.sortKey == rhs.scope.sortKey {
                if lhs.metric.rawValue == rhs.metric.rawValue {
                    return lhs.receiptID < rhs.receiptID
                }
                return lhs.metric.rawValue < rhs.metric.rawValue
            }
            return lhs.scope.sortKey < rhs.scope.sortKey
        }
    }

    public func assessment(
        trustedPolicyAuthorityReceiptID: ForgeQualityID,
        acceptedCompletionTarget: ForgeQualityCompletionTarget
    ) throws -> ForgeQualityAssessment {
        try ForgeQualityEvaluator.evaluate(
            policy: policy,
            trustedPolicyAuthorityReceiptID: trustedPolicyAuthorityReceiptID,
            acceptedCompletionTarget: acceptedCompletionTarget,
            binding: binding,
            measurements: measurements
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeQualityError.invalidRevision
        }
        try self.init(
            policy: container.decode(ForgeQualityPolicy.self, forKey: .policy),
            binding: container.decode(ForgeQualityRunBinding.self, forKey: .binding),
            measurements: container.decode([ForgeQualityMeasurement].self, forKey: .measurements)
        )
    }
}

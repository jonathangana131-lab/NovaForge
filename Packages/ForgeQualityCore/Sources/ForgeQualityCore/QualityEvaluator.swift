import Foundation

/// Non-Codable host-accepted identity for the exact execution run whose quality may be evaluated.
///
/// A public `ForgeQualityRunBinding` is transport metadata only. A future canonical Runtime/Mission
/// adapter inside this module must mint this subject only after proving the run is the currently
/// accepted execution for the completion target. This prevents a caller from replaying an older
/// otherwise-authentic measurement bundle from the same source/checkpoint.
public struct ForgeQualityTrustedRunBinding: Equatable, Sendable {
    private let authenticatedBinding: ForgeQualityRunBinding

    public var binding: ForgeQualityRunBinding { authenticatedBinding }

    init(authenticatedBinding: ForgeQualityRunBinding) {
        self.authenticatedBinding = authenticatedBinding
    }
}

public enum ForgeQualityEvaluator {
    public static func evaluate(
        policy: ForgeQualityTrustedPolicy,
        binding: ForgeQualityTrustedRunBinding,
        measurements: [ForgeQualityTrustedMeasurement]
    ) throws -> ForgeQualityAssessment {
        try evaluate(
            policy: policy,
            binding: binding.binding,
            measurements: measurements
        )
    }

    /// Package-internal seam used by canonical producer adapters and package tests after run trust
    /// has already been established. Ordinary external consumers cannot select an arbitrary run.
    internal static func evaluate(
        policy: ForgeQualityTrustedPolicy,
        binding: ForgeQualityRunBinding,
        measurements: [ForgeQualityTrustedMeasurement]
    ) throws -> ForgeQualityAssessment {
        guard binding.projectID == policy.completionTarget.projectID,
              binding.sourceRevision == policy.completionTarget.sourceRevision,
              binding.checkpointID == policy.checkpointID else {
            throw ForgeQualityError.completionBindingMismatch
        }

        let candidateMeasurements = measurements.map(\.candidate)
        let measurementsByTarget = try validateMeasurements(
            targets: policy.targets,
            binding: binding,
            measurements: candidateMeasurements
        )

        var findings: [ForgeQualityFinding] = []
        var contributingReceipts: [ForgeQualityID] = []
        var passingReceipts: [ForgeQualityID] = []
        var hasFailure = false
        var hasBlocker = false

        for target in policy.targets {
            guard let measurement = measurementsByTarget[target.key] else {
                findings.append(ForgeQualityFinding(target: target, reason: .missingEvidence, measurement: nil))
                hasBlocker = true
                continue
            }

            contributingReceipts.append(measurement.producerReceiptID)

            guard target.environmentRequirement.matches(binding) else {
                findings.append(
                    ForgeQualityFinding(target: target, reason: .environmentMismatch, measurement: measurement)
                )
                hasBlocker = true
                continue
            }

            guard measurement.sampleCount >= target.minimumSampleCount else {
                findings.append(
                    ForgeQualityFinding(target: target, reason: .insufficientSamples, measurement: measurement)
                )
                hasBlocker = true
                continue
            }

            guard target.comparator.accepts(value: measurement.value, threshold: target.threshold) else {
                findings.append(
                    ForgeQualityFinding(target: target, reason: .thresholdViolated, measurement: measurement)
                )
                hasFailure = true
                continue
            }

            passingReceipts.append(measurement.producerReceiptID)
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
            trustedPolicy: policy,
            binding: binding,
            status: status,
            findings: findings,
            contributingProducerReceiptIDs: contributingReceipts,
            passingProducerReceiptIDs: passingReceipts
        )
    }

    private static func validateMeasurements(
        targets: [ForgeQualityTarget],
        binding: ForgeQualityRunBinding,
        measurements: [ForgeQualityMeasurement]
    ) throws -> [ForgeQualityTargetKey: ForgeQualityMeasurement] {
        let targetKeys = Set(targets.map(\.key))
        var byTarget: [ForgeQualityTargetKey: ForgeQualityMeasurement] = [:]
        var measurementIDs = Set<ForgeQualityID>()
        var producerReceiptIDs = Set<ForgeQualityID>()

        for measurement in measurements {
            guard measurement.binding == binding else {
                throw ForgeQualityError.evidenceBindingMismatch(measurementID: measurement.measurementID)
            }
            guard targetKeys.contains(measurement.key) else {
                throw ForgeQualityError.unexpectedMeasurement(
                    metric: measurement.metric,
                    scope: measurement.scope
                )
            }
            guard measurementIDs.insert(measurement.measurementID).inserted else {
                throw ForgeQualityError.duplicateMeasurementID(measurement.measurementID)
            }
            guard producerReceiptIDs.insert(measurement.producerReceiptID).inserted else {
                throw ForgeQualityError.duplicateProducerReceiptID(measurement.producerReceiptID)
            }
            guard byTarget.updateValue(measurement, forKey: measurement.key) == nil else {
                throw ForgeQualityError.duplicateMeasurement(
                    metric: measurement.metric,
                    scope: measurement.scope
                )
            }
        }

        return byTarget
    }
}

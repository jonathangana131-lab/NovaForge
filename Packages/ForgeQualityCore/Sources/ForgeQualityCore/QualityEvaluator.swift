import Foundation

/// Non-Codable host-accepted identity for the exact execution run whose quality may be evaluated.
///
/// A public `ForgeQualityRunBinding` is transport metadata only. A future canonical Runtime/Mission
/// adapter inside this module must mint this subject only after proving the run is the currently
/// accepted execution for the exact Completion target retained here. Keeping the whole relation
/// prevents a trusted run from one mission/Constitution from being replayed against another target
/// that happens to share project/source/checkpoint identity.
public struct ForgeQualityTrustedRunBinding: Equatable, Sendable {
    private let authenticatedBinding: ForgeQualityRunBinding
    private let authenticatedCompletionTarget: ForgeQualityCompletionTarget

    public var binding: ForgeQualityRunBinding { authenticatedBinding }
    public var completionTarget: ForgeQualityCompletionTarget { authenticatedCompletionTarget }

    init(
        authenticatedBinding: ForgeQualityRunBinding,
        authenticatedCompletionTarget: ForgeQualityCompletionTarget
    ) {
        self.authenticatedBinding = authenticatedBinding
        self.authenticatedCompletionTarget = authenticatedCompletionTarget
    }
}

public enum ForgeQualityEvaluator {
    /// Authoritative package boundary. Quality acceptance consumes one authenticated whole-batch
    /// subject, not independently trusted scalar observations that can be cherry-picked or mixed.
    public static func evaluate(
        policy: ForgeQualityTrustedPolicy,
        binding: ForgeQualityTrustedRunBinding,
        batch: ForgeQualityTrustedMeasurementBatch
    ) throws -> ForgeQualityAssessment {
        guard binding.completionTarget == policy.completionTarget else {
            throw ForgeQualityError.completionBindingMismatch
        }

        let candidateBatch = batch.candidate
        guard candidateBatch.binding == binding.binding else {
            throw ForgeQualityError.measurementBatchBindingMismatch
        }
        guard candidateBatch.measurementProtocol == policy.measurementProtocol else {
            throw ForgeQualityError.measurementBatchProtocolMismatch
        }

        return try evaluateAuthenticated(
            policy: policy,
            binding: binding.binding,
            batchReceiptID: candidateBatch.batchReceiptID,
            measurements: candidateBatch.measurements,
            allowSharedProducerReceiptIDs: true
        )
    }

    /// Package-internal compatibility seam for the pre-batch deterministic test corpus. It preserves
    /// the old duplicate-producer-receipt rule and cannot be invoked by ordinary imports. Product
    /// adapters must use the public whole-batch authority path above.
    static func evaluate(
        policy: ForgeQualityTrustedPolicy,
        binding: ForgeQualityTrustedRunBinding,
        measurements: [ForgeQualityTrustedMeasurement]
    ) throws -> ForgeQualityAssessment {
        guard binding.completionTarget == policy.completionTarget else {
            throw ForgeQualityError.completionBindingMismatch
        }

        return try evaluateAuthenticated(
            policy: policy,
            binding: binding.binding,
            batchReceiptID: try ForgeQualityID("package-internal-quality-batch", field: "batchReceiptID"),
            measurements: measurements.map(\.candidate),
            allowSharedProducerReceiptIDs: false
        )
    }

    private static func evaluateAuthenticated(
        policy: ForgeQualityTrustedPolicy,
        binding: ForgeQualityRunBinding,
        batchReceiptID: ForgeQualityID,
        measurements: [ForgeQualityMeasurement],
        allowSharedProducerReceiptIDs: Bool
    ) throws -> ForgeQualityAssessment {
        guard binding.projectID == policy.completionTarget.projectID,
              binding.sourceRevision == policy.completionTarget.sourceRevision,
              binding.checkpointID == policy.checkpointID else {
            throw ForgeQualityError.completionBindingMismatch
        }

        let measurementsByTarget = try validateMeasurements(
            targets: policy.targets,
            measurementProtocol: policy.measurementProtocol,
            binding: binding,
            measurements: measurements,
            allowSharedProducerReceiptIDs: allowSharedProducerReceiptIDs
        )

        var findings: [ForgeQualityFinding] = []
        var contributingReceipts = Set<ForgeQualityID>()
        var passingReceipts = Set<ForgeQualityID>()
        var hasFailure = false
        var hasBlocker = false

        for target in policy.targets {
            guard let measurement = measurementsByTarget[target.key] else {
                findings.append(ForgeQualityFinding(target: target, reason: .missingEvidence, measurement: nil))
                hasBlocker = true
                continue
            }

            contributingReceipts.insert(measurement.producerReceiptID)

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

            passingReceipts.insert(measurement.producerReceiptID)
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
            measurementBatchReceiptID: batchReceiptID,
            status: status,
            findings: findings,
            contributingProducerReceiptIDs: contributingReceipts.sorted(),
            passingProducerReceiptIDs: passingReceipts.sorted()
        )
    }

    private static func validateMeasurements(
        targets: [ForgeQualityTarget],
        measurementProtocol: ForgeQualityMeasurementProtocolIdentity,
        binding: ForgeQualityRunBinding,
        measurements: [ForgeQualityMeasurement],
        allowSharedProducerReceiptIDs: Bool
    ) throws -> [ForgeQualityTargetKey: ForgeQualityMeasurement] {
        let targetKeys = Set(targets.map(\.key))
        var byTarget: [ForgeQualityTargetKey: ForgeQualityMeasurement] = [:]
        var measurementIDs = Set<ForgeQualityID>()
        var producerReceiptIDs = Set<ForgeQualityID>()

        for measurement in measurements {
            guard measurement.binding == binding else {
                throw ForgeQualityError.evidenceBindingMismatch(measurementID: measurement.measurementID)
            }
            guard measurement.measurementProtocol == measurementProtocol else {
                throw ForgeQualityError.measurementProtocolMismatch(measurementID: measurement.measurementID)
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
            if !allowSharedProducerReceiptIDs,
               !producerReceiptIDs.insert(measurement.producerReceiptID).inserted {
                throw ForgeQualityError.duplicateProducerReceiptID(measurement.producerReceiptID)
            }
            guard byTarget.updateValue(measurement, forKey: measurement.key) == nil else {
                throw ForgeQualityError.duplicateMeasurement(
                    metric: measurement.metric,
                    scope: measurement.scope
                )
            }
        }

        try validateCoherentFramePercentiles(measurements)
        return byTarget
    }

    /// p95 and p99 are order statistics and therefore must be monotonic when the accepted protocol
    /// emits them for the same exact run/scope population. Average frame time is deliberately not
    /// constrained relative to p95: a heavy upper tail can legitimately make the arithmetic mean
    /// exceed p95, so enforcing `average <= p95` would reject valid telemetry.
    private static func validateCoherentFramePercentiles(
        _ measurements: [ForgeQualityMeasurement]
    ) throws {
        var byScope: [ForgeQualityScope: [ForgeQualityMetric: ForgeQualityMeasurement]] = [:]
        for measurement in measurements where
            measurement.metric == .p95FrameTimeMilliseconds || measurement.metric == .p99FrameTimeMilliseconds {
            byScope[measurement.scope, default: [:]][measurement.metric] = measurement
        }

        for (scope, metrics) in byScope {
            guard let p95 = metrics[.p95FrameTimeMilliseconds],
                  let p99 = metrics[.p99FrameTimeMilliseconds] else {
                continue
            }
            guard p95.sampleCount == p99.sampleCount,
                  p95.value <= p99.value else {
                throw ForgeQualityError.incoherentFramePercentiles(scope: scope)
            }
        }
    }
}

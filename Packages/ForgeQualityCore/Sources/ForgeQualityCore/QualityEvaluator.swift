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
    public static func evaluate(
        policy: ForgeQualityTrustedPolicy,
        binding: ForgeQualityTrustedRunBinding,
        batches: [ForgeQualityTrustedMeasurementBatch]
    ) throws -> ForgeQualityAssessment {
        guard binding.completionTarget == policy.completionTarget else {
            throw ForgeQualityError.completionBindingMismatch
        }

        return try evaluateAuthenticated(
            policy: policy,
            binding: binding.binding,
            batches: batches
        )
    }

    /// Private evaluator reached only after non-Codable trusted run and whole-batch producer
    /// authority have been retained. Individual trusted measurements are intentionally not an
    /// acceptance API: quality evidence must arrive as the exact producer batch that was attested.
    private static func evaluateAuthenticated(
        policy: ForgeQualityTrustedPolicy,
        binding: ForgeQualityRunBinding,
        batches: [ForgeQualityTrustedMeasurementBatch]
    ) throws -> ForgeQualityAssessment {
        guard binding.projectID == policy.completionTarget.projectID,
              binding.sourceRevision == policy.completionTarget.sourceRevision,
              binding.checkpointID == policy.checkpointID else {
            throw ForgeQualityError.completionBindingMismatch
        }

        let candidateBatches = batches.map(\.candidate)
        let measurementsByTarget = try validateBatches(
            targets: policy.targets,
            measurementProtocol: policy.measurementProtocol,
            binding: binding,
            batches: candidateBatches
        )

        var findings: [ForgeQualityFinding] = []
        var contributingReceipts = Set<ForgeQualityID>()
        var nonPassingReceipts = Set<ForgeQualityID>()
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
                nonPassingReceipts.insert(measurement.producerReceiptID)
                hasBlocker = true
                continue
            }

            guard measurement.sampleCount >= target.minimumSampleCount else {
                findings.append(
                    ForgeQualityFinding(target: target, reason: .insufficientSamples, measurement: measurement)
                )
                nonPassingReceipts.insert(measurement.producerReceiptID)
                hasBlocker = true
                continue
            }

            guard target.comparator.accepts(value: measurement.value, threshold: target.threshold) else {
                findings.append(
                    ForgeQualityFinding(target: target, reason: .thresholdViolated, measurement: measurement)
                )
                nonPassingReceipts.insert(measurement.producerReceiptID)
                hasFailure = true
                continue
            }
        }

        let status: ForgeQualityGateStatus
        if hasFailure {
            status = .failed
        } else if hasBlocker {
            status = .blocked
        } else {
            status = .passed
        }

        let passingReceipts = contributingReceipts.subtracting(nonPassingReceipts)

        return ForgeQualityAssessment(
            trustedPolicy: policy,
            binding: binding,
            status: status,
            findings: findings,
            contributingProducerReceiptIDs: contributingReceipts.sorted(),
            passingProducerReceiptIDs: passingReceipts.sorted()
        )
    }

    private static func validateBatches(
        targets: [ForgeQualityTarget],
        measurementProtocol: ForgeQualityMeasurementProtocolIdentity,
        binding: ForgeQualityRunBinding,
        batches: [ForgeQualityMeasurementBatch]
    ) throws -> [ForgeQualityTargetKey: ForgeQualityMeasurement] {
        let targetKeys = Set(targets.map(\.key))
        var byTarget: [ForgeQualityTargetKey: ForgeQualityMeasurement] = [:]
        var measurementIDs = Set<ForgeQualityID>()
        var producerReceiptIDs = Set<ForgeQualityID>()

        for batch in batches {
            let firstMeasurementID = batch.measurements[0].measurementID
            guard batch.binding == binding else {
                throw ForgeQualityError.evidenceBindingMismatch(measurementID: firstMeasurementID)
            }
            guard batch.measurementProtocol == measurementProtocol else {
                throw ForgeQualityError.measurementProtocolMismatch(measurementID: firstMeasurementID)
            }
            guard producerReceiptIDs.insert(batch.producerReceiptID).inserted else {
                throw ForgeQualityError.duplicateProducerReceiptID(batch.producerReceiptID)
            }

            for measurement in batch.measurements {
                guard targetKeys.contains(measurement.key) else {
                    throw ForgeQualityError.unexpectedMeasurement(
                        metric: measurement.metric,
                        scope: measurement.scope
                    )
                }
                guard measurementIDs.insert(measurement.measurementID).inserted else {
                    throw ForgeQualityError.duplicateMeasurementID(measurement.measurementID)
                }
                guard byTarget.updateValue(measurement, forKey: measurement.key) == nil else {
                    throw ForgeQualityError.duplicateMeasurement(
                        metric: measurement.metric,
                        scope: measurement.scope
                    )
                }
            }
        }

        try validateFrameStatisticSetCoherence(
            targets: targets,
            measurementsByTarget: byTarget
        )
        return byTarget
    }

    /// Frame statistics selected together for one scope must describe one producer-attested sample
    /// population. Mean ordering is deliberately not constrained: a small extreme upper tail can
    /// validly make arithmetic mean exceed p95. Percentile monotonicity (p95 <= p99) is mandatory.
    private static func validateFrameStatisticSetCoherence(
        targets: [ForgeQualityTarget],
        measurementsByTarget: [ForgeQualityTargetKey: ForgeQualityMeasurement]
    ) throws {
        let frameTargets = targets.filter { target in
            switch target.metric {
            case .averageFrameTimeMilliseconds,
                 .p95FrameTimeMilliseconds,
                 .p99FrameTimeMilliseconds:
                true
            default:
                false
            }
        }
        let targetsByScope = Dictionary(grouping: frameTargets) { $0.scope }

        for (scope, scopedTargets) in targetsByScope {
            let measurements = scopedTargets.compactMap { measurementsByTarget[$0.key] }
            guard measurements.count > 1 else { continue }

            guard Set(measurements.map(\.producerReceiptID)).count == 1,
                  Set(measurements.map(\.sampleCount)).count == 1 else {
                throw ForgeQualityError.incoherentMeasurementSet(scope: scope)
            }

            let byMetric = Dictionary(uniqueKeysWithValues: measurements.map { ($0.metric, $0) })
            if let p95 = byMetric[.p95FrameTimeMilliseconds],
               let p99 = byMetric[.p99FrameTimeMilliseconds],
               p95.value > p99.value {
                throw ForgeQualityError.incoherentMeasurementSet(scope: scope)
            }
        }
    }
}

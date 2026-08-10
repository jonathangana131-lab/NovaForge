import Foundation

public enum ForgeQualityFindingReason: String, Codable, Hashable, Sendable {
    case missingEvidence
    case environmentMismatch
    case insufficientSamples
    case thresholdViolated
}

public struct ForgeQualityFinding: Hashable, Sendable {
    public let metric: ForgeQualityMetric
    public let scope: ForgeQualityScope
    public let reason: ForgeQualityFindingReason
    public let measuredValue: Double?
    public let sampleCount: Int?
    public let comparator: ForgeQualityComparator
    public let threshold: Double
    public let minimumSampleCount: Int

    internal init(
        target: ForgeQualityTarget,
        reason: ForgeQualityFindingReason,
        measurement: ForgeQualityMeasurement?
    ) {
        metric = target.metric
        scope = target.scope
        self.reason = reason
        measuredValue = measurement?.value
        sampleCount = measurement?.sampleCount
        comparator = target.comparator
        threshold = target.threshold
        minimumSampleCount = target.minimumSampleCount
    }
}

public enum ForgeQualityGateStatus: String, Hashable, Sendable {
    case passed
    case blocked
    case failed
}

/// Derived quality verdict. Intentionally non-Codable: relaunch/restore must re-evaluate the current
/// trusted policy and currently authenticated producer measurements rather than replay a saved pass.
public struct ForgeQualityAssessment: Hashable, Sendable {
    public let policyID: ForgeQualityID
    public let policyRevision: UInt64
    public let policyAuthorityReceiptID: ForgeQualityID
    public let criterionID: ForgeQualityID
    public let completionTarget: ForgeQualityCompletionTarget
    public let binding: ForgeQualityRunBinding
    public let status: ForgeQualityGateStatus
    public let findings: [ForgeQualityFinding]
    public let contributingProducerReceiptIDs: [ForgeQualityID]
    public let passingProducerReceiptIDs: [ForgeQualityID]

    internal init(
        trustedPolicy: ForgeQualityTrustedPolicy,
        binding: ForgeQualityRunBinding,
        status: ForgeQualityGateStatus,
        findings: [ForgeQualityFinding],
        contributingProducerReceiptIDs: [ForgeQualityID],
        passingProducerReceiptIDs: [ForgeQualityID]
    ) {
        policyID = trustedPolicy.policyID
        policyRevision = trustedPolicy.policyRevision
        policyAuthorityReceiptID = trustedPolicy.policyAuthorityReceiptID
        criterionID = trustedPolicy.criterionID
        completionTarget = trustedPolicy.completionTarget
        self.binding = binding
        self.status = status
        self.findings = findings
        self.contributingProducerReceiptIDs = contributingProducerReceiptIDs
        self.passingProducerReceiptIDs = passingProducerReceiptIDs
    }
}

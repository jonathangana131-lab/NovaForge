import Foundation

/// Host code must authenticate the complete observation subject against the canonical producer receipt.
/// Decoding an observation, seeing a known producer enum, or matching a receipt ID is never sufficient.
public protocol ForgeAccessibilityEvidenceAuthenticating: Sendable {
    func authenticates(_ observation: ForgeAccessibilityObservation) -> Bool
}

public enum ForgeAccessibilityBlocker: Hashable, Sendable {
    case missingObservation(requirementID: ForgeAccessibilityID)
    case environmentMismatch(requirementID: ForgeAccessibilityID, observationID: ForgeAccessibilityID)
    case unauthenticatedObservation(observationID: ForgeAccessibilityID)
    case failedObservation(observationID: ForgeAccessibilityID)
    case inconclusiveObservation(observationID: ForgeAccessibilityID)
    case notRunObservation(observationID: ForgeAccessibilityID)
    case blockingFinding(findingID: ForgeAccessibilityID, severity: ForgeAccessibilityFindingSeverity)
}

public enum ForgeAccessibilityVerdict: String, Hashable, Sendable {
    case accepted
    case blocked
}

/// Derived live state only. Persist the assessment and re-authenticate/re-evaluate after relaunch.
public struct ForgeAccessibilityEvaluation: Hashable, Sendable {
    public let verdict: ForgeAccessibilityVerdict
    public let blockers: [ForgeAccessibilityBlocker]
    public let contributingObservationIDs: [ForgeAccessibilityID]
    public let contributingEvidenceReceiptIDs: [ForgeAccessibilityID]
    public let nonBlockingFindingIDs: [ForgeAccessibilityID]

    public var isAccepted: Bool { verdict == .accepted }
}

public enum ForgeAccessibilityEvaluator {
    public static func evaluate<Authenticator: ForgeAccessibilityEvidenceAuthenticating>(
        _ assessment: ForgeAccessibilityAssessment,
        authenticator: Authenticator
    ) -> ForgeAccessibilityEvaluation {
        let observationsByRequirement = Dictionary(
            uniqueKeysWithValues: assessment.observations.map { ($0.requirementID, $0) }
        )
        var blockers: [ForgeAccessibilityBlocker] = []
        var contributingObservationIDs: [ForgeAccessibilityID] = []
        var contributingReceiptIDs: [ForgeAccessibilityID] = []
        var nonBlockingFindingIDs: [ForgeAccessibilityID] = []

        for requirement in assessment.policy.requirements {
            guard let observation = observationsByRequirement[requirement.id] else {
                blockers.append(.missingObservation(requirementID: requirement.id))
                continue
            }

            let environmentAccepted = assessment.policy.accepts(observation.environment)
                && observation.environment.satisfies(requirement.environmentProfile)
            guard environmentAccepted else {
                blockers.append(
                    .environmentMismatch(requirementID: requirement.id, observationID: observation.id)
                )
                continue
            }

            guard authenticator.authenticates(observation) else {
                blockers.append(.unauthenticatedObservation(observationID: observation.id))
                continue
            }

            switch observation.outcome {
            case .passed:
                break
            case .failed:
                blockers.append(.failedObservation(observationID: observation.id))
            case .inconclusive:
                blockers.append(.inconclusiveObservation(observationID: observation.id))
            case .notRun:
                blockers.append(.notRunObservation(observationID: observation.id))
            }

            var observationHasBlockingFinding = false
            for finding in observation.findings {
                if blocks(finding.severity, under: assessment.policy) {
                    observationHasBlockingFinding = true
                    blockers.append(.blockingFinding(findingID: finding.id, severity: finding.severity))
                } else {
                    nonBlockingFindingIDs.append(finding.id)
                }
            }

            if observation.outcome == .passed && !observationHasBlockingFinding {
                contributingObservationIDs.append(observation.id)
                contributingReceiptIDs.append(observation.evidenceReceiptID)
            }
        }

        return ForgeAccessibilityEvaluation(
            verdict: blockers.isEmpty ? .accepted : .blocked,
            blockers: blockers,
            contributingObservationIDs: contributingObservationIDs.sorted(),
            contributingEvidenceReceiptIDs: contributingReceiptIDs.sorted(),
            nonBlockingFindingIDs: nonBlockingFindingIDs.sorted()
        )
    }

    private static func blocks(
        _ severity: ForgeAccessibilityFindingSeverity,
        under policy: ForgeAccessibilityAcceptancePolicy
    ) -> Bool {
        switch severity {
        case .critical, .high:
            true
        case .medium:
            policy.blocksMediumFindings
        case .low:
            policy.blocksLowFindings
        }
    }
}

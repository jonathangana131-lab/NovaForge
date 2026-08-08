import Foundation

public enum ForgeCompletionCriterionResult: String, Codable, Sendable {
    case passed
    case missingEvidence
    case failedEvidence
    case inconclusiveEvidence
    case environmentMismatch
}

public struct ForgeCompletionCriterionAssessment: Codable, Sendable {
    public let criterionID: String
    public let result: ForgeCompletionCriterionResult
    public let acceptedReceiptIDs: [String]
}

public enum ForgeCompletionBlocker: Equatable, Sendable {
    case criterion(String, ForgeCompletionCriterionResult)
    case unresolvedSevereDefect(String)
    case undisclosedDefect(String)
    case knownLimitationsNotAllowed
}

public enum ForgeCompletionDisposition: String, Codable, Sendable {
    case incomplete
    case completeWithEvidence
    case completeWithKnownLimitations
}

public struct ForgeCompletionAssessment: Sendable {
    public let disposition: ForgeCompletionDisposition
    public let criteria: [ForgeCompletionCriterionAssessment]
    public let blockers: [ForgeCompletionBlocker]
    public let ignoredModelAssertionReceiptIDs: [String]
}

public enum ForgeCompletionGate {
    public static func assess(
        constitution: ForgeCompletionConstitution,
        evidence: ForgeCompletionEvidenceArchive,
        defects: ForgeCompletionDefectSnapshot
    ) -> ForgeCompletionAssessment {
        let ignoredModelAssertions = evidence.receipts
            .filter { $0.evidenceClass == .modelAssertion && $0.scope == constitution.scope }
            .map(\.receiptID)
            .sorted()

        var criterionAssessments: [ForgeCompletionCriterionAssessment] = []
        var blockers: [ForgeCompletionBlocker] = []

        for criterion in constitution.criteria {
            var acceptedReceiptIDs: [String] = []
            var result: ForgeCompletionCriterionResult = .passed

            for requiredClass in criterion.requiredEvidenceClasses {
                let current = evidence.receipts.filter {
                    $0.scope == constitution.scope &&
                    $0.criterionID == criterion.id &&
                    $0.evidenceClass == requiredClass
                }

                guard let receipt = current.first else {
                    result = stronger(result, .missingEvidence)
                    continue
                }
                guard criterion.environmentRequirement.accepts(receipt.environment) else {
                    result = stronger(result, .environmentMismatch)
                    continue
                }
                switch receipt.verdict {
                case .passed:
                    acceptedReceiptIDs.append(receipt.receiptID)
                case .failed:
                    result = stronger(result, .failedEvidence)
                case .inconclusive:
                    result = stronger(result, .inconclusiveEvidence)
                }
            }

            acceptedReceiptIDs.sort()
            criterionAssessments.append(.init(criterionID: criterion.id, result: result, acceptedReceiptIDs: acceptedReceiptIDs))
            if result != .passed { blockers.append(.criterion(criterion.id, result)) }
        }

        let currentDefects = defects.defects.filter { $0.scope == constitution.scope && $0.state != .resolved }
        for defect in currentDefects where defect.severity >= .high {
            blockers.append(.unresolvedSevereDefect(defect.defectID))
        }

        let relatedLimitationDefectIDs = Set(defects.knownLimitations.compactMap(\.relatedDefectID))
        let unresolvedNonSevere = currentDefects.filter { $0.severity < .high }
        for defect in unresolvedNonSevere where !relatedLimitationDefectIDs.contains(defect.defectID) {
            blockers.append(.undisclosedDefect(defect.defectID))
        }

        let hasKnownLimitations = !defects.knownLimitations.isEmpty || !unresolvedNonSevere.isEmpty
        if hasKnownLimitations && !constitution.allowsKnownLimitations {
            blockers.append(.knownLimitationsNotAllowed)
        }

        if !blockers.isEmpty {
            return .init(
                disposition: .incomplete,
                criteria: criterionAssessments,
                blockers: blockers,
                ignoredModelAssertionReceiptIDs: ignoredModelAssertions
            )
        }

        return .init(
            disposition: hasKnownLimitations ? .completeWithKnownLimitations : .completeWithEvidence,
            criteria: criterionAssessments,
            blockers: [],
            ignoredModelAssertionReceiptIDs: ignoredModelAssertions
        )
    }

    private static func stronger(_ lhs: ForgeCompletionCriterionResult, _ rhs: ForgeCompletionCriterionResult) -> ForgeCompletionCriterionResult {
        func rank(_ value: ForgeCompletionCriterionResult) -> Int {
            switch value {
            case .passed: 0
            case .missingEvidence: 1
            case .inconclusiveEvidence: 2
            case .environmentMismatch: 3
            case .failedEvidence: 4
            }
        }
        return rank(rhs) > rank(lhs) ? rhs : lhs
    }
}

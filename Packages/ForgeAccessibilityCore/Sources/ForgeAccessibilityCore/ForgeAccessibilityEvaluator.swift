import Foundation

public enum ForgeAccessibilityBlocker: Equatable, Sendable {
    case missingScenario(scenarioID: String)
    case executionEnvironmentMismatch(scenarioID: String)
    case untrustedProducerReceipt(scenarioID: String, producerReceiptID: String)
    case missingRequiredCheck(scenarioID: String, check: ForgeAccessibilityCheckKind)
    case checkNotPassed(
        scenarioID: String,
        check: ForgeAccessibilityCheckKind,
        outcome: ForgeAccessibilityCheckOutcome
    )

    fileprivate var sortKey: String {
        switch self {
        case let .missingScenario(scenarioID):
            return "0|\(scenarioID)"
        case let .executionEnvironmentMismatch(scenarioID):
            return "1|\(scenarioID)"
        case let .untrustedProducerReceipt(scenarioID, receiptID):
            return "2|\(scenarioID)|\(receiptID)"
        case let .missingRequiredCheck(scenarioID, check):
            return "3|\(scenarioID)|\(check.rawValue)"
        case let .checkNotPassed(scenarioID, check, outcome):
            return "4|\(scenarioID)|\(check.rawValue)|\(outcome.rawValue)"
        }
    }
}

public enum ForgeAccessibilityAcceptanceStatus: String, Sendable {
    case blocked
    case accepted
}

/// Ephemeral derived projection only. It is intentionally not Codable so persisted bytes cannot
/// manufacture an accepted accessibility verdict without re-evaluating current trusted receipts.
public struct ForgeAccessibilityEvaluation: Equatable, Sendable {
    public let target: ForgeAccessibilityTarget
    public let status: ForgeAccessibilityAcceptanceStatus
    public let blockers: [ForgeAccessibilityBlocker]
    public let acceptedProducerReceiptIDs: [String]

    public var isAccepted: Bool { status == .accepted }
}

public enum ForgeAccessibilityEvaluator {
    public static let maximumRuns = 64
    public static let maximumTrustedProducerReceipts = 256

    public static func evaluate(
        policy: ForgeAccessibilityPolicy,
        runs: [ForgeAccessibilityRunEvidence],
        trustedProducerReceipts: [ForgeAccessibilityTrustedProducerReceipt]
    ) throws -> ForgeAccessibilityEvaluation {
        try ForgeAccessibilityValidation.maximumCount(
            runs.count,
            field: "evaluation.runs",
            maximum: Self.maximumRuns
        )
        try ForgeAccessibilityValidation.maximumCount(
            trustedProducerReceipts.count,
            field: "evaluation.trustedProducerReceipts",
            maximum: Self.maximumTrustedProducerReceipts
        )
        var trustedReceiptsByID: [String: ForgeAccessibilityTrustedProducerReceipt] = [:]
        for trustedReceipt in trustedProducerReceipts {
            guard trustedReceiptsByID[trustedReceipt.producerReceiptID] == nil else {
                throw ForgeAccessibilityError.duplicateTrustedProducerReceiptID(
                    trustedReceipt.producerReceiptID
                )
            }
            trustedReceiptsByID[trustedReceipt.producerReceiptID] = trustedReceipt
        }

        let scenariosByID = Dictionary(uniqueKeysWithValues: policy.scenarios.map { ($0.id, $0) })
        var runIDs = Set<String>()
        var producerReceiptIDs = Set<String>()
        var evidenceByScenarioID: [String: ForgeAccessibilityRunEvidence] = [:]

        for run in runs {
            guard run.target == policy.target else {
                throw ForgeAccessibilityError.targetMismatch("run:\(run.runID)")
            }
            guard runIDs.insert(run.runID).inserted else {
                throw ForgeAccessibilityError.duplicateRunID(run.runID)
            }
            guard producerReceiptIDs.insert(run.producerReceiptID).inserted else {
                throw ForgeAccessibilityError.duplicateProducerReceiptID(run.producerReceiptID)
            }
            guard scenariosByID[run.scenarioID] != nil else {
                throw ForgeAccessibilityError.unknownScenario(run.scenarioID)
            }
            guard evidenceByScenarioID[run.scenarioID] == nil else {
                throw ForgeAccessibilityError.duplicateScenarioEvidence(run.scenarioID)
            }
            evidenceByScenarioID[run.scenarioID] = run
        }

        var blockers: [ForgeAccessibilityBlocker] = []
        var acceptedProducerReceiptIDs: [String] = []

        for scenario in policy.scenarios {
            let blockerCountBeforeScenario = blockers.count
            guard let run = evidenceByScenarioID[scenario.id] else {
                blockers.append(.missingScenario(scenarioID: scenario.id))
                continue
            }

            if !policy.executionPolicy.accepts(run.executionContext) {
                blockers.append(.executionEnvironmentMismatch(scenarioID: scenario.id))
            }

            if trustedReceiptsByID[run.producerReceiptID]?.exactlyMatches(run) != true {
                blockers.append(.untrustedProducerReceipt(
                    scenarioID: scenario.id,
                    producerReceiptID: run.producerReceiptID
                ))
            }

            let resultsByKind = Dictionary(uniqueKeysWithValues: run.checkResults.map { ($0.kind, $0) })
            for requiredCheck in scenario.requiredChecks where resultsByKind[requiredCheck] == nil {
                blockers.append(.missingRequiredCheck(scenarioID: scenario.id, check: requiredCheck))
            }

            // A producer may report more than the minimum required checks, but a reported failure or
            // inconclusive result cannot be hidden merely because that check was optional in policy.
            for result in run.checkResults where result.outcome != .passed {
                blockers.append(.checkNotPassed(
                    scenarioID: scenario.id,
                    check: result.kind,
                    outcome: result.outcome
                ))
            }

            if blockers.count == blockerCountBeforeScenario {
                acceptedProducerReceiptIDs.append(run.producerReceiptID)
            }
        }

        let canonicalBlockers = blockers.sorted { $0.sortKey < $1.sortKey }
        return ForgeAccessibilityEvaluation(
            target: policy.target,
            status: canonicalBlockers.isEmpty ? .accepted : .blocked,
            blockers: canonicalBlockers,
            acceptedProducerReceiptIDs: acceptedProducerReceiptIDs.sorted()
        )
    }
}

import Foundation

public enum ForgePerformanceBlocker: Equatable, Sendable {
    case missingScenario(scenarioID: String)
    case policyRevisionMismatch(scenarioID: String)
    case scenarioRevisionMismatch(scenarioID: String)
    case executionEnvironmentMismatch(scenarioID: String)
    case untrustedProducerReceipt(scenarioID: String, producerReceiptID: String)
    case insufficientFrameSamples(scenarioID: String, observed: Int, required: Int)
    case p95FrameTimeExceeded(scenarioID: String, observed: Double, maximum: Double)
    case p99FrameTimeExceeded(scenarioID: String, observed: Double, maximum: Double)
    case missingPeakResidentMemory(scenarioID: String)
    case peakResidentMemoryExceeded(scenarioID: String, observed: UInt64, maximum: UInt64)
    case missingInteractionLatency(scenarioID: String)
    case insufficientInteractionSamples(scenarioID: String, observed: Int, required: Int)
    case interactionP95LatencyExceeded(scenarioID: String, observed: Double, maximum: Double)
    case missingColdLaunch(scenarioID: String)
    case coldLaunchExceeded(scenarioID: String, observed: Double, maximum: Double)

    fileprivate var sortKey: String {
        switch self {
        case let .missingScenario(id): return "00|\(id)"
        case let .policyRevisionMismatch(id): return "01|\(id)"
        case let .scenarioRevisionMismatch(id): return "02|\(id)"
        case let .executionEnvironmentMismatch(id): return "03|\(id)"
        case let .untrustedProducerReceipt(id, receipt): return "04|\(id)|\(receipt)"
        case let .insufficientFrameSamples(id, _, _): return "05|\(id)"
        case let .p95FrameTimeExceeded(id, _, _): return "06|\(id)"
        case let .p99FrameTimeExceeded(id, _, _): return "07|\(id)"
        case let .missingPeakResidentMemory(id): return "08|\(id)"
        case let .peakResidentMemoryExceeded(id, _, _): return "09|\(id)"
        case let .missingInteractionLatency(id): return "10|\(id)"
        case let .insufficientInteractionSamples(id, _, _): return "11|\(id)"
        case let .interactionP95LatencyExceeded(id, _, _): return "12|\(id)"
        case let .missingColdLaunch(id): return "13|\(id)"
        case let .coldLaunchExceeded(id, _, _): return "14|\(id)"
        }
    }
}

public enum ForgePerformanceAcceptanceStatus: String, Sendable {
    case blocked
    case accepted
}

/// Ephemeral derived acceptance. Deliberately non-Codable: restore must re-evaluate current policy,
/// exact run evidence, and current host trust instead of deserializing a `passed` verdict.
public struct ForgePerformanceEvaluation: Equatable, Sendable {
    public let target: ForgePerformanceTarget
    public let policyRevision: String
    public let status: ForgePerformanceAcceptanceStatus
    public let blockers: [ForgePerformanceBlocker]
    public let acceptedProducerReceiptIDs: [String]
    public var isAccepted: Bool { status == .accepted }
}

public enum ForgePerformanceEvaluator {
    public static let maximumRuns = 64
    public static let maximumTrustedProducerReceipts = 256

    public static func evaluate(
        policy: ForgePerformancePolicy,
        runs: [ForgePerformanceRunEvidence],
        trustedProducerReceipts: [ForgePerformanceTrustedProducerReceipt]
    ) throws -> ForgePerformanceEvaluation {
        try ForgePerformanceValidation.maximumCount(runs.count, field: "evaluation.runs", maximum: maximumRuns)
        try ForgePerformanceValidation.maximumCount(trustedProducerReceipts.count, field: "evaluation.trustedProducerReceipts", maximum: maximumTrustedProducerReceipts)

        var trustedByID: [String: ForgePerformanceTrustedProducerReceipt] = [:]
        for receipt in trustedProducerReceipts {
            guard trustedByID[receipt.producerReceiptID] == nil else { throw ForgePerformanceError.duplicateTrustedProducerReceiptID(receipt.producerReceiptID) }
            trustedByID[receipt.producerReceiptID] = receipt
        }

        let scenariosByID = Dictionary(uniqueKeysWithValues: policy.scenarios.map { ($0.id, $0) })
        var runIDs = Set<String>()
        var producerReceiptIDs = Set<String>()
        var runByScenarioID: [String: ForgePerformanceRunEvidence] = [:]

        for run in runs {
            guard run.target == policy.target else { throw ForgePerformanceError.targetMismatch("run:\(run.runID)") }
            guard runIDs.insert(run.runID).inserted else { throw ForgePerformanceError.duplicateRunID(run.runID) }
            guard producerReceiptIDs.insert(run.producerReceiptID).inserted else { throw ForgePerformanceError.duplicateProducerReceiptID(run.producerReceiptID) }
            guard scenariosByID[run.scenarioID] != nil else { throw ForgePerformanceError.unknownScenario(run.scenarioID) }
            guard runByScenarioID[run.scenarioID] == nil else { throw ForgePerformanceError.duplicateScenarioEvidence(run.scenarioID) }
            runByScenarioID[run.scenarioID] = run
        }

        var blockers: [ForgePerformanceBlocker] = []
        var acceptedReceiptIDs: [String] = []

        for scenario in policy.scenarios {
            let countBefore = blockers.count
            guard let run = runByScenarioID[scenario.id] else {
                blockers.append(.missingScenario(scenarioID: scenario.id))
                continue
            }

            if run.policyRevision != policy.policyRevision { blockers.append(.policyRevisionMismatch(scenarioID: scenario.id)) }
            if run.scenarioRevision != scenario.revision { blockers.append(.scenarioRevisionMismatch(scenarioID: scenario.id)) }
            if run.executionContext != scenario.executionContext { blockers.append(.executionEnvironmentMismatch(scenarioID: scenario.id)) }
            if trustedByID[run.producerReceiptID]?.exactlyMatches(run) != true {
                blockers.append(.untrustedProducerReceipt(scenarioID: scenario.id, producerReceiptID: run.producerReceiptID))
            }

            let t = scenario.thresholds
            let m = run.metrics
            if m.frameSampleCount < t.minimumFrameSamples {
                blockers.append(.insufficientFrameSamples(scenarioID: scenario.id, observed: m.frameSampleCount, required: t.minimumFrameSamples))
            }
            if m.p95FrameTimeMilliseconds > t.maximumP95FrameTimeMilliseconds {
                blockers.append(.p95FrameTimeExceeded(scenarioID: scenario.id, observed: m.p95FrameTimeMilliseconds, maximum: t.maximumP95FrameTimeMilliseconds))
            }
            if m.p99FrameTimeMilliseconds > t.maximumP99FrameTimeMilliseconds {
                blockers.append(.p99FrameTimeExceeded(scenarioID: scenario.id, observed: m.p99FrameTimeMilliseconds, maximum: t.maximumP99FrameTimeMilliseconds))
            }
            if let maximum = t.maximumPeakResidentMemoryBytes {
                if let observed = m.peakResidentMemoryBytes {
                    if observed > maximum { blockers.append(.peakResidentMemoryExceeded(scenarioID: scenario.id, observed: observed, maximum: maximum)) }
                } else {
                    blockers.append(.missingPeakResidentMemory(scenarioID: scenario.id))
                }
            }
            if let requiredSamples = t.minimumInteractionSamples, let maximumLatency = t.maximumInteractionP95LatencyMilliseconds {
                if let observedSamples = m.interactionSampleCount, let observedLatency = m.interactionP95LatencyMilliseconds {
                    if observedSamples < requiredSamples { blockers.append(.insufficientInteractionSamples(scenarioID: scenario.id, observed: observedSamples, required: requiredSamples)) }
                    if observedLatency > maximumLatency { blockers.append(.interactionP95LatencyExceeded(scenarioID: scenario.id, observed: observedLatency, maximum: maximumLatency)) }
                } else {
                    blockers.append(.missingInteractionLatency(scenarioID: scenario.id))
                }
            }
            if let maximumLaunch = t.maximumColdLaunchMilliseconds {
                if let observedLaunch = m.coldLaunchMilliseconds {
                    if observedLaunch > maximumLaunch { blockers.append(.coldLaunchExceeded(scenarioID: scenario.id, observed: observedLaunch, maximum: maximumLaunch)) }
                } else {
                    blockers.append(.missingColdLaunch(scenarioID: scenario.id))
                }
            }

            if blockers.count == countBefore { acceptedReceiptIDs.append(run.producerReceiptID) }
        }

        let canonical = blockers.sorted { $0.sortKey < $1.sortKey }
        return ForgePerformanceEvaluation(
            target: policy.target,
            policyRevision: policy.policyRevision,
            status: canonical.isEmpty ? .accepted : .blocked,
            blockers: canonical,
            acceptedProducerReceiptIDs: acceptedReceiptIDs.sorted()
        )
    }
}

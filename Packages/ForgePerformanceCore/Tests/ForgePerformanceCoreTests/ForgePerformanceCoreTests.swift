import Foundation
import Testing
@testable import ForgePerformanceCore

private func target(_ revision: String = "src-1") throws -> ForgePerformanceTarget {
    try ForgePerformanceTarget(projectID: "project-1", sourceRevision: revision, checkpointID: "checkpoint-1", runtimeVersion: "runtime-1")
}

private func context(_ kind: ForgePerformanceExecutionKind = .simulator, build: String = "24A1") throws -> ForgePerformanceExecutionContext {
    try ForgePerformanceExecutionContext(kind: kind, deviceIdentifier: kind == .simulator ? "iPhone13,2-sim" : "iPhone13,2", osName: "iOS", osVersion: "27.0", osBuild: build)
}

private func thresholds() throws -> ForgePerformanceThresholds {
    try ForgePerformanceThresholds(
        minimumFrameSamples: 120,
        maximumP95FrameTimeMilliseconds: 20,
        maximumP99FrameTimeMilliseconds: 32,
        maximumPeakResidentMemoryBytes: 600_000_000,
        minimumInteractionSamples: 20,
        maximumInteractionP95LatencyMilliseconds: 100,
        maximumColdLaunchMilliseconds: 1_500
    )
}

private func policy(context execution: ForgePerformanceExecutionContext? = nil) throws -> ForgePerformancePolicy {
    try ForgePerformancePolicy(
        policyRevision: "perf-policy-1",
        target: target(),
        scenarios: [
            ForgePerformanceScenario(
                id: "core-loop",
                revision: "journey-3",
                executionContext: execution ?? context(),
                thresholds: thresholds()
            )
        ]
    )
}

private func metrics(
    frames: Int = 240,
    p95: Double = 16,
    p99: Double = 24,
    memory: UInt64? = 450_000_000,
    interactions: Int? = 30,
    latency: Double? = 60,
    launch: Double? = 900
) throws -> ForgePerformanceMetrics {
    try ForgePerformanceMetrics(
        frameSampleCount: frames,
        p50FrameTimeMilliseconds: 12,
        p95FrameTimeMilliseconds: p95,
        p99FrameTimeMilliseconds: p99,
        maximumFrameTimeMilliseconds: max(40, p99),
        peakResidentMemoryBytes: memory,
        interactionSampleCount: interactions,
        interactionP95LatencyMilliseconds: latency,
        coldLaunchMilliseconds: launch
    )
}

private func run(
    target runTarget: ForgePerformanceTarget? = nil,
    policyRevision: String = "perf-policy-1",
    scenarioRevision: String = "journey-3",
    executionContext: ForgePerformanceExecutionContext? = nil,
    producerReceiptID: String = "producer-1",
    metrics runMetrics: ForgePerformanceMetrics? = nil
) throws -> ForgePerformanceRunEvidence {
    try ForgePerformanceRunEvidence(
        runID: "run-1",
        target: runTarget ?? target(),
        policyRevision: policyRevision,
        scenarioID: "core-loop",
        scenarioRevision: scenarioRevision,
        executionContext: executionContext ?? context(),
        authority: .hostRuntimeProfiler,
        producerReceiptID: producerReceiptID,
        metrics: runMetrics ?? metrics()
    )
}

private func trustedEvaluate(
    policy: ForgePerformancePolicy,
    runs: [ForgePerformanceRunEvidence],
    trustedProducerReceipts: [ForgePerformanceTrustedProducerReceipt]
) throws -> ForgePerformanceEvaluation {
    try ForgePerformanceEvaluator.evaluate(
        policy: policy,
        trustedPolicyReceipt: ForgePerformanceTrustedPolicyReceipt(authenticatedPolicy: policy),
        runs: runs,
        trustedProducerReceipts: trustedProducerReceipts
    )
}

@Test func acceptsOnlyExactTrustedPassingRun() throws {
    let p = try policy()
    let r = try run()
    let evaluation = try trustedEvaluate(
        policy: p,
        runs: [r],
        trustedProducerReceipts: [ForgePerformanceTrustedProducerReceipt(authenticatedRun: r)]
    )
    #expect(evaluation.isAccepted)
    #expect(evaluation.blockers.isEmpty)
    #expect(evaluation.acceptedProducerReceiptIDs == ["producer-1"])
}

@Test func candidatePolicyCannotSelfAuthorizeRelaxedDefinitionOfDone() throws {
    let relaxed = try policy()
    let r = try run()
    let evaluation = try ForgePerformanceEvaluator.evaluate(
        policy: relaxed,
        runs: [r],
        trustedProducerReceipts: [ForgePerformanceTrustedProducerReceipt(authenticatedRun: r)]
    )
    #expect(!evaluation.isAccepted)
    #expect(evaluation.blockers.contains(.untrustedPolicy(policyRevision: "perf-policy-1")))
    #expect(evaluation.acceptedProducerReceiptIDs.isEmpty)
}

@Test func candidateAuthorityCannotSelfAuthorize() throws {
    let evaluation = try trustedEvaluate(policy: policy(), runs: [run()], trustedProducerReceipts: [])
    #expect(!evaluation.isAccepted)
    #expect(evaluation.blockers == [.untrustedProducerReceipt(scenarioID: "core-loop", producerReceiptID: "producer-1")])
}

@Test func exactTrustRejectsSameReceiptWithChangedMetrics() throws {
    let trustedRun = try run()
    let changed = try run(metrics: metrics(p95: 19))
    let evaluation = try trustedEvaluate(
        policy: policy(),
        runs: [changed],
        trustedProducerReceipts: [ForgePerformanceTrustedProducerReceipt(authenticatedRun: trustedRun)]
    )
    #expect(evaluation.blockers.contains(.untrustedProducerReceipt(scenarioID: "core-loop", producerReceiptID: "producer-1")))
}

@Test func crossRevisionEvidenceFailsClosed() throws {
    #expect(throws: ForgePerformanceError.targetMismatch("run:run-1")) {
        _ = try trustedEvaluate(
            policy: policy(),
            runs: [run(target: target("src-2"))],
            trustedProducerReceipts: []
        )
    }
}

@Test func policyAndScenarioRevisionDriftBlockAcceptance() throws {
    let r = try run(policyRevision: "old-policy", scenarioRevision: "journey-2")
    let evaluation = try trustedEvaluate(
        policy: policy(),
        runs: [r],
        trustedProducerReceipts: [ForgePerformanceTrustedProducerReceipt(authenticatedRun: r)]
    )
    #expect(evaluation.blockers.contains(.policyRevisionMismatch(scenarioID: "core-loop")))
    #expect(evaluation.blockers.contains(.scenarioRevisionMismatch(scenarioID: "core-loop")))
}

@Test func simulatorEvidenceCannotSatisfyPhysicalDeviceScenario() throws {
    let physical = try context(.physicalDevice)
    let p = try policy(context: physical)
    let r = try run()
    let evaluation = try trustedEvaluate(
        policy: p,
        runs: [r],
        trustedProducerReceipts: [ForgePerformanceTrustedProducerReceipt(authenticatedRun: r)]
    )
    #expect(evaluation.blockers.contains(.executionEnvironmentMismatch(scenarioID: "core-loop")))
}

@Test func osBuildDriftBlocksAcceptance() throws {
    let p = try policy(context: context(.simulator, build: "24A2"))
    let r = try run()
    let evaluation = try trustedEvaluate(
        policy: p,
        runs: [r],
        trustedProducerReceipts: [ForgePerformanceTrustedProducerReceipt(authenticatedRun: r)]
    )
    #expect(evaluation.blockers.contains(.executionEnvironmentMismatch(scenarioID: "core-loop")))
}

@Test func frameThresholdsAreDerivedFromMeasurements() throws {
    let r = try run(metrics: metrics(frames: 100, p95: 25, p99: 35))
    let evaluation = try trustedEvaluate(
        policy: policy(), runs: [r], trustedProducerReceipts: [ForgePerformanceTrustedProducerReceipt(authenticatedRun: r)]
    )
    #expect(evaluation.blockers.contains(.insufficientFrameSamples(scenarioID: "core-loop", observed: 100, required: 120)))
    #expect(evaluation.blockers.contains(.p95FrameTimeExceeded(scenarioID: "core-loop", observed: 25, maximum: 20)))
    #expect(evaluation.blockers.contains(.p99FrameTimeExceeded(scenarioID: "core-loop", observed: 35, maximum: 32)))
}

@Test func requiredMeasuredMetricsCannotBeOmitted() throws {
    let r = try run(metrics: metrics(memory: nil, interactions: nil, latency: nil, launch: nil))
    let evaluation = try trustedEvaluate(
        policy: policy(), runs: [r], trustedProducerReceipts: [ForgePerformanceTrustedProducerReceipt(authenticatedRun: r)]
    )
    #expect(evaluation.blockers.contains(.missingPeakResidentMemory(scenarioID: "core-loop")))
    #expect(evaluation.blockers.contains(.missingInteractionLatency(scenarioID: "core-loop")))
    #expect(evaluation.blockers.contains(.missingColdLaunch(scenarioID: "core-loop")))
}

@Test func memoryLatencyAndLaunchThresholdsBlock() throws {
    let r = try run(metrics: metrics(memory: 700_000_000, interactions: 10, latency: 150, launch: 2_000))
    let evaluation = try trustedEvaluate(
        policy: policy(), runs: [r], trustedProducerReceipts: [ForgePerformanceTrustedProducerReceipt(authenticatedRun: r)]
    )
    #expect(evaluation.blockers.contains(.peakResidentMemoryExceeded(scenarioID: "core-loop", observed: 700_000_000, maximum: 600_000_000)))
    #expect(evaluation.blockers.contains(.insufficientInteractionSamples(scenarioID: "core-loop", observed: 10, required: 20)))
    #expect(evaluation.blockers.contains(.interactionP95LatencyExceeded(scenarioID: "core-loop", observed: 150, maximum: 100)))
    #expect(evaluation.blockers.contains(.coldLaunchExceeded(scenarioID: "core-loop", observed: 2_000, maximum: 1_500)))
}

@Test func malformedPercentilesAndNonFiniteMetricsReject() throws {
    #expect(throws: ForgePerformanceError.invalidMetric(field: "metrics.framePercentiles")) {
        _ = try ForgePerformanceMetrics(frameSampleCount: 100, p50FrameTimeMilliseconds: 15, p95FrameTimeMilliseconds: 14, p99FrameTimeMilliseconds: 20, maximumFrameTimeMilliseconds: 30)
    }
    #expect(throws: ForgePerformanceError.invalidMetric(field: "metrics.p95FrameTimeMilliseconds")) {
        _ = try ForgePerformanceMetrics(frameSampleCount: 100, p50FrameTimeMilliseconds: 10, p95FrameTimeMilliseconds: .nan, p99FrameTimeMilliseconds: 20, maximumFrameTimeMilliseconds: 30)
    }
}

@Test func decodedNestedIdentifiersRevalidateAndRejectWhitespaceAliases() throws {
    let p = try policy()
    let data = try JSONEncoder().encode(p)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var targetObject = try #require(object["target"] as? [String: Any])
    targetObject["sourceRevision"] = " src-1 "
    object["target"] = targetObject
    let tampered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ForgePerformanceError.invalidIdentifier("target.sourceRevision")) {
        _ = try JSONDecoder().decode(ForgePerformancePolicy.self, from: tampered)
    }
}

@Test func unknownSchemaRejectsOnDecode() throws {
    let data = try JSONEncoder().encode(policy())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schema"] = 2
    let tampered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ForgePerformanceError.unsupportedSchema(2)) {
        _ = try JSONDecoder().decode(ForgePerformancePolicy.self, from: tampered)
    }
}

@Test func duplicateEvidenceIdentityRejects() throws {
    let p = try ForgePerformancePolicy(
        policyRevision: "perf-policy-1",
        target: target(),
        scenarios: [
            ForgePerformanceScenario(id: "a", revision: "1", executionContext: context(), thresholds: thresholds()),
            ForgePerformanceScenario(id: "b", revision: "1", executionContext: context(), thresholds: thresholds()),
        ]
    )
    let a = try ForgePerformanceRunEvidence(runID: "run-a", target: target(), policyRevision: "perf-policy-1", scenarioID: "a", scenarioRevision: "1", executionContext: context(), authority: .hostRuntimeProfiler, producerReceiptID: "same", metrics: metrics())
    let b = try ForgePerformanceRunEvidence(runID: "run-b", target: target(), policyRevision: "perf-policy-1", scenarioID: "b", scenarioRevision: "1", executionContext: context(), authority: .hostRuntimeProfiler, producerReceiptID: "same", metrics: metrics())
    #expect(throws: ForgePerformanceError.duplicateProducerReceiptID("same")) {
        _ = try trustedEvaluate(policy: p, runs: [a, b], trustedProducerReceipts: [])
    }
}

@Test func missingScenarioBlocksAndOrderingIsDeterministic() throws {
    let p = try ForgePerformancePolicy(
        policyRevision: "perf-policy-1",
        target: target(),
        scenarios: [
            ForgePerformanceScenario(id: "z", revision: "1", executionContext: context(), thresholds: thresholds()),
            ForgePerformanceScenario(id: "a", revision: "1", executionContext: context(), thresholds: thresholds()),
        ]
    )
    let evaluation = try trustedEvaluate(policy: p, runs: [], trustedProducerReceipts: [])
    #expect(evaluation.blockers == [.missingScenario(scenarioID: "a"), .missingScenario(scenarioID: "z")])
}

@Test func policyThresholdPairsFailClosed() throws {
    #expect(throws: ForgePerformanceError.invalidPolicy("thresholds.interactionPair")) {
        _ = try ForgePerformanceThresholds(minimumFrameSamples: 60, maximumP95FrameTimeMilliseconds: 20, maximumP99FrameTimeMilliseconds: 30, minimumInteractionSamples: 10)
    }
}

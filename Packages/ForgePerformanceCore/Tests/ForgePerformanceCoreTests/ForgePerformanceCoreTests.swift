import Foundation
import Testing
@testable import ForgePerformanceCore

@Suite("ForgePerformanceCore")
struct ForgePerformanceCoreTests {
    private func target(_ source: String = "source-1") throws -> ForgePerformanceTarget {
        try ForgePerformanceTarget(missionID: "mission-1", projectID: "project-1", sourceRevision: source, checkpointID: "checkpoint-1", constitutionRevision: 4)
    }

    private func context(_ runtimeRevision: String = "runtime-7") throws -> ForgePerformanceExecutionContext {
        try ForgePerformanceExecutionContext(runtimeID: "forge-web", runtimeRevision: runtimeRevision, environment: .simulator, hardwareIdentifier: "iPhone13,2-Simulator", osVersion: "27.0", osBuild: "24A999")
    }

    private func policy(target: ForgePerformanceTarget? = nil) throws -> ForgePerformancePolicy {
        try ForgePerformancePolicy(
            policyID: "perf-policy-1",
            target: target ?? self.target(),
            scenarioID: "goal-runner",
            scenarioDefinitionDigest: "sha256-scenario-goal-runner-v1",
            budgets: [
                try ForgePerformanceBudget(metric: .frameTimeP95Milliseconds, maximumAllowedValue: 20, minimumSampleCount: 120),
                try ForgePerformanceBudget(metric: .droppedFrameRatio, maximumAllowedValue: 0.02, minimumSampleCount: 120),
                try ForgePerformanceBudget(metric: .peakResidentMemoryBytes, maximumAllowedValue: 800_000_000, minimumSampleCount: 1),
            ]
        )
    }

    private func run(target: ForgePerformanceTarget? = nil, context: ForgePerformanceExecutionContext? = nil, frameTime: Double = 17, frameSamples: Int = 240, droppedRatio: Double = 0.01, memory: Double = 700_000_000) throws -> ForgePerformanceRunEvidence {
        try ForgePerformanceRunEvidence(
            runID: "perf-run-1",
            target: target ?? self.target(),
            executionContext: context ?? self.context(),
            scenarioID: "goal-runner",
            scenarioDefinitionDigest: "sha256-scenario-goal-runner-v1",
            authority: .hostRuntimeProfiler,
            producerReceiptID: "host-perf-receipt-1",
            observations: [
                try ForgePerformanceObservation(metric: .frameTimeP95Milliseconds, measuredValue: frameTime, sampleCount: frameSamples),
                try ForgePerformanceObservation(metric: .droppedFrameRatio, measuredValue: droppedRatio, sampleCount: frameSamples),
                try ForgePerformanceObservation(metric: .peakResidentMemoryBytes, measuredValue: memory, sampleCount: 1),
            ]
        )
    }

    @Test func trustedPassingRunProducesAcceptedReceipt() throws {
        let p = try policy()
        let r = try run()
        let trust = ForgePerformanceTrustedProducerReceipt(authenticatedRun: r)
        let evaluation = try ForgePerformanceEvaluator.evaluate(policy: p, run: r, trustedProducer: trust)
        #expect(evaluation.passed)
        #expect(evaluation.blockers.isEmpty)
        #expect(evaluation.acceptedReceipt?.target == r.target)
        #expect(evaluation.acceptedReceipt?.executionContext == r.executionContext)
    }

    @Test func budgetFailureCannotMintAcceptedReceipt() throws {
        let p = try policy()
        let r = try run(frameTime: 25)
        let evaluation = try ForgePerformanceEvaluator.evaluate(policy: p, run: r, trustedProducer: .init(authenticatedRun: r))
        #expect(!evaluation.passed)
        #expect(evaluation.acceptedReceipt == nil)
        #expect(evaluation.blockers.contains(.exceedsBudget(metric: .frameTimeP95Milliseconds, maximum: 20, actual: 25)))
    }

    @Test func insufficientSamplesBlockEvenWhenAggregateLooksFast() throws {
        let p = try policy()
        let r = try run(frameSamples: 10)
        let evaluation = try ForgePerformanceEvaluator.evaluate(policy: p, run: r, trustedProducer: .init(authenticatedRun: r))
        #expect(!evaluation.passed)
        #expect(evaluation.blockers.contains(.insufficientSamples(metric: .frameTimeP95Milliseconds, required: 120, actual: 10)))
        #expect(evaluation.blockers.contains(.insufficientSamples(metric: .droppedFrameRatio, required: 120, actual: 10)))
    }

    @Test func exactTargetPreventsCrossRevisionReplay() throws {
        let p = try policy()
        let stale = try run(target: target("source-old"))
        #expect(throws: ForgePerformanceError.targetMismatch) {
            _ = try ForgePerformanceEvaluator.evaluate(policy: p, run: stale, trustedProducer: .init(authenticatedRun: stale))
        }
    }

    @Test func sameReceiptIDWithChangedRuntimeContextDoesNotReuseTrust() throws {
        let original = try run()
        let changed = try run(context: context("runtime-8"))
        let trust = ForgePerformanceTrustedProducerReceipt(authenticatedRun: original)
        #expect(throws: ForgePerformanceError.untrustedProducer) {
            _ = try ForgePerformanceEvaluator.evaluate(policy: policy(), run: changed, trustedProducer: trust)
        }
    }

    @Test func sameReceiptIDWithChangedMeasurementsDoesNotReuseTrust() throws {
        let original = try run()
        let changed = try run(memory: 799_999_999)
        let trust = ForgePerformanceTrustedProducerReceipt(authenticatedRun: original)
        #expect(throws: ForgePerformanceError.untrustedProducer) {
            _ = try ForgePerformanceEvaluator.evaluate(policy: policy(), run: changed, trustedProducer: trust)
        }
    }

    @Test func sameScenarioIDWithChangedDefinitionDigestFailsClosed() throws {
        let p = try policy()
        let original = try run()
        let changed = try ForgePerformanceRunEvidence(
            runID: original.runID,
            target: original.target,
            executionContext: original.executionContext,
            scenarioID: original.scenarioID,
            scenarioDefinitionDigest: "sha256-scenario-goal-runner-v2",
            authority: original.authority,
            producerReceiptID: original.producerReceiptID,
            observations: original.observations
        )
        #expect(throws: ForgePerformanceError.scenarioMismatch) {
            _ = try ForgePerformanceEvaluator.evaluate(policy: p, run: changed, trustedProducer: .init(authenticatedRun: changed))
        }
    }

    @Test func duplicateMetricsFailClosed() throws {
        let observation = try ForgePerformanceObservation(metric: .launchTimeMilliseconds, measuredValue: 50, sampleCount: 1)
        #expect(throws: ForgePerformanceError.duplicateObservationMetric(.launchTimeMilliseconds)) {
            _ = try ForgePerformanceRunEvidence(runID: "r", target: target(), executionContext: context(), scenarioID: "s", scenarioDefinitionDigest: "sha256-s", authority: .xctestMetricHarness, producerReceiptID: "p", observations: [observation, observation])
        }
        let budget = try ForgePerformanceBudget(metric: .launchTimeMilliseconds, maximumAllowedValue: 100, minimumSampleCount: 1)
        #expect(throws: ForgePerformanceError.duplicateBudgetMetric(.launchTimeMilliseconds)) {
            _ = try ForgePerformancePolicy(policyID: "p", target: target(), scenarioID: "s", scenarioDefinitionDigest: "sha256-s", budgets: [budget, budget])
        }
    }

    @Test func invalidOrNonFiniteMeasurementsFailClosed() throws {
        #expect(throws: ForgePerformanceError.invalidObservation(ForgePerformanceMetricKind.frameTimeP95Milliseconds.rawValue)) {
            _ = try ForgePerformanceObservation(metric: .frameTimeP95Milliseconds, measuredValue: .nan, sampleCount: 1)
        }
        #expect(throws: ForgePerformanceError.invalidObservation(ForgePerformanceMetricKind.droppedFrameRatio.rawValue)) {
            _ = try ForgePerformanceObservation(metric: .droppedFrameRatio, measuredValue: 1.1, sampleCount: 1)
        }
        #expect(throws: ForgePerformanceError.invalidBudget(ForgePerformanceMetricKind.launchTimeMilliseconds.rawValue)) {
            _ = try ForgePerformanceBudget(metric: .launchTimeMilliseconds, maximumAllowedValue: .infinity, minimumSampleCount: 1)
        }
    }

    @Test func candidateAuthorityFieldDoesNotSurviveWholeRunTrustMismatch() throws {
        let original = try run()
        let other = try ForgePerformanceRunEvidence(
            runID: original.runID,
            target: original.target,
            executionContext: original.executionContext,
            scenarioID: original.scenarioID,
            scenarioDefinitionDigest: original.scenarioDefinitionDigest,
            authority: .instrumentsImport,
            producerReceiptID: original.producerReceiptID,
            observations: original.observations
        )
        #expect(throws: ForgePerformanceError.untrustedProducer) {
            _ = try ForgePerformanceEvaluator.evaluate(policy: policy(), run: other, trustedProducer: .init(authenticatedRun: original))
        }
    }

    @Test func archiveRoundTripRevalidatesAndRequiresFreshTrust() throws {
        let p = try policy()
        let r = try run()
        let archive = try ForgePerformanceArchive(policy: p, run: r)
        let data = try JSONEncoder().encode(archive)
        let decoded = try JSONDecoder().decode(ForgePerformanceArchive.self, from: data)
        #expect(decoded == archive)
        let restored = try decoded.restore(trustedProducer: .init(authenticatedRun: r))
        #expect(restored.passed)
    }

    @Test func archiveRejectsUnknownSchema() throws {
        let archive = try ForgePerformanceArchive(policy: policy(), run: run())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        object["schemaVersion"] = 999
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ForgePerformanceArchive.self, from: data)
        }
    }

    @Test func archiveRejectsCrossTargetTamper() throws {
        let archive = try ForgePerformanceArchive(policy: policy(), run: run())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        var runObject = try #require(object["run"] as? [String: Any])
        var targetObject = try #require(runObject["target"] as? [String: Any])
        targetObject["sourceRevision"] = "source-tampered"
        runObject["target"] = targetObject
        object["run"] = runObject
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ForgePerformanceError.targetMismatch) {
            _ = try JSONDecoder().decode(ForgePerformanceArchive.self, from: data)
        }
    }

    @Test func candidateRunRoundTripDoesNotContainAcceptanceBit() throws {
        let data = try JSONEncoder().encode(run())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["passed"] == nil)
        #expect(object["accepted"] == nil)
        #expect(object["trusted"] == nil)
    }
}

@Suite("ForgePerformanceMetricUnits")
struct ForgePerformanceMetricUnitsTests {
    @Test func unitsAreExplicitAndZeroDropBudgetIsValid() throws {
        #expect(ForgePerformanceMetricKind.frameTimeP95Milliseconds.unit == .milliseconds)
        #expect(ForgePerformanceMetricKind.droppedFrameRatio.unit == .ratio)
        #expect(ForgePerformanceMetricKind.peakResidentMemoryBytes.unit == .bytes)
        let zeroDropBudget = try ForgePerformanceBudget(metric: .droppedFrameRatio, maximumAllowedValue: 0, minimumSampleCount: 60)
        #expect(zeroDropBudget.maximumAllowedValue == 0)
    }
}

import Foundation
import Testing
@testable import ForgePerformanceCore

private func environment(kind: ForgePerformanceEnvironmentKind = .simulator) -> ForgePerformanceEnvironment {
    try! ForgePerformanceEnvironment(
        kind: kind,
        hardwareIdentifier: kind == .physicalDevice ? "iPhone13,2" : "iPhone13,2-simulator",
        osVersion: "27.0",
        osBuild: "24A123"
    )
}

private func target(
    source: String = "source-abc",
    mission: String = "mission-1",
    environment: ForgePerformanceEnvironment = environment(),
    budgetRevision: Int = 3,
    budgetReceipt: String = "budget-receipt-3",
    protocolRevision: Int = 2
) -> ForgePerformanceTarget {
    try! ForgePerformanceTarget(
        projectID: "project-alpha",
        sourceRevision: source,
        missionID: mission,
        runtimeID: "forge-web-runtime",
        runtimeRevision: "runtime-7",
        environment: environment,
        measurementProtocolID: "generated-runtime-perf",
        measurementProtocolRevision: protocolRevision,
        budgetRevision: budgetRevision,
        budgetAuthorityReceiptID: budgetReceipt
    )
}

private func constraint(_ metric: ForgePerformanceMetric, max: Double, samples: Int = 1) -> ForgePerformanceConstraint {
    try! ForgePerformanceConstraint(metric: metric, maximumAllowed: max, minimumSamplesPerRun: samples)
}

private func budget(
    target: ForgePerformanceTarget = target(),
    runs: Int = 2,
    frameMaximum: Double = 20
) -> ForgePerformanceBudget {
    try! ForgePerformanceBudget(
        target: target,
        requiredRunCount: runs,
        constraints: [
            constraint(.frameTimeP95Milliseconds, max: frameMaximum, samples: 120),
            constraint(.peakResidentBytes, max: 500_000_000),
        ]
    )
}

private func observation(_ metric: ForgePerformanceMetric, _ value: Double, samples: Int = 1) -> ForgePerformanceObservation {
    try! ForgePerformanceObservation(metric: metric, value: value, sampleCount: samples)
}

private func run(
    _ id: String,
    target: ForgePerformanceTarget = target(),
    frame: Double = 16,
    frameSamples: Int = 120,
    memory: Double = 400_000_000
) -> ForgePerformanceRun {
    try! ForgePerformanceRun(
        runID: id,
        target: target,
        observations: [
            observation(.frameTimeP95Milliseconds, frame, samples: frameSamples),
            observation(.peakResidentBytes, memory),
        ]
    )
}

private func batch(
    target: ForgePerformanceTarget = target(),
    receipt: String = "trusted-batch",
    runs: [ForgePerformanceRun]? = nil
) -> ForgePerformanceMeasurementBatch {
    try! ForgePerformanceMeasurementBatch(
        batchReceiptID: receipt,
        target: target,
        runs: runs ?? [run("run-1", target: target), run("run-2", target: target)]
    )
}

private func evaluate(_ budget: ForgePerformanceBudget, _ batch: ForgePerformanceMeasurementBatch) throws -> ForgePerformanceEvaluation {
    try ForgePerformanceEvaluator.evaluate(
        budget: budget,
        batch: batch,
        budgetTrust: ForgePerformanceBudgetTrustBinding(authenticatedBudget: budget),
        measurementTrust: ForgePerformanceMeasurementTrustBinding(authenticatedBatch: batch)
    )
}

@Test func exactBudgetPassIsDerivedFromMeasurements() throws {
    let target = target()
    let budget = budget(target: target)
    let batch = batch(target: target)
    let evaluation = try evaluate(budget, batch)
    #expect(evaluation.status == .accepted)
    #expect(evaluation.acceptedMetricValues[.frameTimeP95Milliseconds] == 16)
    #expect(evaluation.acceptedMetricValues[.peakResidentBytes] == 400_000_000)
}

@Test func thresholdEqualityPasses() throws {
    let target = target()
    let budget = budget(target: target)
    let exact = batch(target: target, runs: [
        run("run-1", target: target, frame: 20, memory: 500_000_000),
        run("run-2", target: target, frame: 20, memory: 500_000_000),
    ])
    #expect(try evaluate(budget, exact).status == .accepted)
}

@Test func worstRunCannotBeAveragedAway() throws {
    let target = target()
    let budget = budget(target: target)
    let measurements = batch(target: target, runs: [
        run("fast", target: target, frame: 10),
        run("slow", target: target, frame: 25),
    ])
    let evaluation = try evaluate(budget, measurements)
    #expect(evaluation.status == .failed)
    #expect(evaluation.failures.first?.metric == .frameTimeP95Milliseconds)
    #expect(evaluation.failures.first?.worstObserved == 25)
}

@Test func missingMetricBlocksInsteadOfPassing() throws {
    let target = target()
    let incomplete = try ForgePerformanceRun(
        runID: "run-1",
        target: target,
        observations: [observation(.frameTimeP95Milliseconds, 15, samples: 120)]
    )
    let measurements = batch(target: target, runs: [incomplete, run("run-2", target: target)])
    let evaluation = try evaluate(budget(target: target), measurements)
    #expect(evaluation.status == .blocked)
    #expect(evaluation.blockers.contains(.missingMetric(metric: .peakResidentBytes, runID: "run-1")))
}

@Test func insufficientSamplesBlock() throws {
    let target = target()
    let measurements = batch(target: target, runs: [
        run("run-1", target: target, frameSamples: 119),
        run("run-2", target: target),
    ])
    let evaluation = try evaluate(budget(target: target), measurements)
    #expect(evaluation.status == .blocked)
    #expect(evaluation.blockers.contains(
        .insufficientSamples(metric: .frameTimeP95Milliseconds, runID: "run-1", required: 120, actual: 119)
    ))
}

@Test func insufficientRunCountBlocks() throws {
    let target = target()
    let measurements = batch(target: target, runs: [run("only", target: target)])
    let evaluation = try evaluate(budget(target: target, runs: 2), measurements)
    #expect(evaluation.status == .blocked)
    #expect(evaluation.blockers.contains(.insufficientRuns(required: 2, actual: 1)))
}

@Test func sameBudgetReceiptCannotAuthorizeAlteredBudget() throws {
    let target = target()
    let trusted = budget(target: target, frameMaximum: 20)
    let altered = budget(target: target, frameMaximum: 40)
    let measurements = batch(target: target)
    let trust = ForgePerformanceBudgetTrustBinding(authenticatedBudget: trusted)
    #expect(throws: ForgePerformanceError.untrustedBudgetAuthorityReceipt(target.budgetAuthorityReceiptID)) {
        try ForgePerformanceEvaluator.evaluate(
            budget: altered,
            batch: measurements,
            budgetTrust: trust,
            measurementTrust: ForgePerformanceMeasurementTrustBinding(authenticatedBatch: measurements)
        )
    }
}

@Test func sameBatchReceiptCannotAuthorizeAlteredObservations() throws {
    let target = target()
    let original = batch(target: target, receipt: "same-batch")
    let altered = batch(
        target: target,
        receipt: "same-batch",
        runs: [run("run-1", target: target, frame: 40), run("run-2", target: target)]
    )
    let budget = budget(target: target)
    #expect(throws: ForgePerformanceError.untrustedMeasurementBatchReceipt("same-batch")) {
        try ForgePerformanceEvaluator.evaluate(
            budget: budget,
            batch: altered,
            budgetTrust: ForgePerformanceBudgetTrustBinding(authenticatedBudget: budget),
            measurementTrust: ForgePerformanceMeasurementTrustBinding(authenticatedBatch: original)
        )
    }
}

@Test func staleSourceBatchFailsClosed() throws {
    let current = target(source: "source-new")
    let stale = target(source: "source-old")
    let currentBudget = budget(target: current)
    let staleBatch = batch(target: stale)
    #expect(throws: ForgePerformanceError.targetMismatch("batch.target")) {
        try ForgePerformanceEvaluator.evaluate(
            budget: currentBudget,
            batch: staleBatch,
            budgetTrust: ForgePerformanceBudgetTrustBinding(authenticatedBudget: currentBudget),
            measurementTrust: ForgePerformanceMeasurementTrustBinding(authenticatedBatch: staleBatch)
        )
    }
}

@Test func simulatorEvidenceCannotSatisfyPhysicalDeviceTarget() throws {
    let physical = target(environment: environment(kind: .physicalDevice))
    let simulator = target(environment: environment(kind: .simulator))
    let currentBudget = budget(target: physical)
    let simulatorBatch = batch(target: simulator)
    #expect(throws: ForgePerformanceError.targetMismatch("batch.target")) {
        try ForgePerformanceEvaluator.evaluate(
            budget: currentBudget,
            batch: simulatorBatch,
            budgetTrust: ForgePerformanceBudgetTrustBinding(authenticatedBudget: currentBudget),
            measurementTrust: ForgePerformanceMeasurementTrustBinding(authenticatedBatch: simulatorBatch)
        )
    }
}

@Test func protocolRevisionDriftIsTargetDrift() throws {
    let p2 = target(protocolRevision: 2)
    let p3 = target(protocolRevision: 3)
    let currentBudget = budget(target: p3)
    let staleBatch = batch(target: p2)
    #expect(throws: ForgePerformanceError.targetMismatch("batch.target")) {
        try ForgePerformanceEvaluator.evaluate(
            budget: currentBudget,
            batch: staleBatch,
            budgetTrust: ForgePerformanceBudgetTrustBinding(authenticatedBudget: currentBudget),
            measurementTrust: ForgePerformanceMeasurementTrustBinding(authenticatedBatch: staleBatch)
        )
    }
}

@Test func duplicateConstraintMetricsRejected() {
    let duplicate = constraint(.frameTimeP95Milliseconds, max: 20)
    #expect(throws: ForgePerformanceError.duplicateMetric("frameTimeP95Milliseconds")) {
        try ForgePerformanceBudget(target: target(), requiredRunCount: 1, constraints: [duplicate, duplicate])
    }
}

@Test func duplicateObservationMetricsRejected() {
    let duplicate = observation(.launchTimeMilliseconds, 100)
    #expect(throws: ForgePerformanceError.duplicateMetric("launchTimeMilliseconds")) {
        try ForgePerformanceRun(runID: "run", target: target(), observations: [duplicate, duplicate])
    }
}

@Test func duplicateRunIDsRejected() {
    let target = target()
    #expect(throws: ForgePerformanceError.duplicateRunID("same")) {
        try ForgePerformanceMeasurementBatch(
            batchReceiptID: "batch",
            target: target,
            runs: [run("same", target: target), run("same", target: target)]
        )
    }
}

@Test func nonFiniteMeasurementsRejected() {
    #expect(throws: ForgePerformanceError.invalidObservation("frameTimeP95Milliseconds")) {
        try ForgePerformanceObservation(metric: .frameTimeP95Milliseconds, value: .infinity, sampleCount: 1)
    }
    #expect(throws: ForgePerformanceError.invalidObservation("frameTimeP95Milliseconds")) {
        try ForgePerformanceObservation(metric: .frameTimeP95Milliseconds, value: .nan, sampleCount: 1)
    }
}

@Test func percentageOverHundredRejected() {
    #expect(throws: ForgePerformanceError.invalidObservation("droppedFramePercent")) {
        try ForgePerformanceObservation(metric: .droppedFramePercent, value: 100.1, sampleCount: 1)
    }
    #expect(throws: ForgePerformanceError.invalidConstraint("hitchRatePercent")) {
        try ForgePerformanceConstraint(metric: .hitchRatePercent, maximumAllowed: 101)
    }
}

@Test func discreteMetricsRejectFractions() {
    #expect(throws: ForgePerformanceError.invalidObservation("memoryPressureEventCount")) {
        try ForgePerformanceObservation(metric: .memoryPressureEventCount, value: 0.5, sampleCount: 1)
    }
    #expect(throws: ForgePerformanceError.invalidConstraint("peakResidentBytes")) {
        try ForgePerformanceConstraint(metric: .peakResidentBytes, maximumAllowed: 100.5)
    }
}

@Test func receiptAndIdentityWhitespaceIsRejectedInsteadOfNormalized() {
    #expect(throws: ForgePerformanceError.invalidIdentifier("target.projectID")) {
        try ForgePerformanceTarget(
            projectID: " project-alpha ",
            sourceRevision: "source-abc",
            missionID: "mission-1",
            runtimeID: "runtime",
            runtimeRevision: "1",
            environment: environment(),
            measurementProtocolID: "protocol",
            measurementProtocolRevision: 1,
            budgetRevision: 1,
            budgetAuthorityReceiptID: "budget-receipt"
        )
    }
}

@Test func archiveRoundTripRevalidatesRawInputsAndVerdictIsRecomputed() throws {
    let target = target()
    let originalBudget = budget(target: target)
    let originalBatch = batch(target: target)
    let archive = try ForgePerformanceEvidenceArchive(budget: originalBudget, batch: originalBatch)
    let data = try JSONEncoder().encode(archive)
    let decoded = try JSONDecoder().decode(ForgePerformanceEvidenceArchive.self, from: data)
    let evaluation = try evaluate(decoded.budget, decoded.batch)
    #expect(evaluation.status == .accepted)
}

@Test func archiveRejectsFutureSchema() throws {
    let target = target()
    let archive = try ForgePerformanceEvidenceArchive(budget: budget(target: target), batch: batch(target: target))
    let data = try JSONEncoder().encode(archive)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 99
    let tampered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ForgePerformanceEvidenceArchive.self, from: tampered)
    }
}

@Test func archiveRejectsCrossTargetTampering() throws {
    let target = target()
    let archive = try ForgePerformanceEvidenceArchive(budget: budget(target: target), batch: batch(target: target))
    let data = try JSONEncoder().encode(archive)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var batchObject = try #require(object["batch"] as? [String: Any])
    var batchTarget = try #require(batchObject["target"] as? [String: Any])
    batchTarget["missionID"] = "forged-mission"
    batchObject["target"] = batchTarget
    object["batch"] = batchObject
    let tampered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ForgePerformanceEvidenceArchive.self, from: tampered)
    }
}

@Test func deterministicOrderingOfBudgetAndRuns() throws {
    let target = target()
    let orderedBudget = try ForgePerformanceBudget(
        target: target,
        requiredRunCount: 1,
        constraints: [
            constraint(.peakResidentBytes, max: 500_000_000),
            constraint(.frameTimeP95Milliseconds, max: 20),
        ]
    )
    let measurements = try ForgePerformanceMeasurementBatch(
        batchReceiptID: "batch",
        target: target,
        runs: [run("z", target: target), run("a", target: target)]
    )
    #expect(orderedBudget.constraints.map(\.metric) == [.frameTimeP95Milliseconds, .peakResidentBytes])
    #expect(measurements.runs.map(\.runID) == ["a", "z"])
}

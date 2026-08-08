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

private func constraint(
    _ metric: ForgePerformanceMetric,
    max: Double,
    samples: Int = 1
) -> ForgePerformanceConstraint {
    try! ForgePerformanceConstraint(metric: metric, maximumAllowed: max, minimumSamplesPerRun: samples)
}

private func budget(
    target: ForgePerformanceTarget = target(),
    runs: Int = 2,
    constraints: [ForgePerformanceConstraint] = [
        constraint(.frameTimeP95Milliseconds, max: 20, samples: 120),
        constraint(.peakResidentBytes, max: 500_000_000),
    ]
) -> ForgePerformanceBudget {
    try! ForgePerformanceBudget(target: target, requiredRunCount: runs, constraints: constraints)
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
    let actualRuns = runs ?? [run("run-1", target: target), run("run-2", target: target)]
    return try! ForgePerformanceMeasurementBatch(batchReceiptID: receipt, target: target, runs: actualRuns)
}

@Test func exactBudgetPassIsDerivedFromMeasurements() throws {
    let target = target()
    let evaluation = try ForgePerformanceEvaluator.evaluate(
        budget: budget(target: target),
        batch: batch(target: target),
        trustedBatchReceiptIDs: ["trusted-batch"]
    )

    #expect(evaluation.status == .accepted)
    #expect(evaluation.failures.isEmpty)
    #expect(evaluation.blockers.isEmpty)
    #expect(evaluation.acceptedMetricValues[.frameTimeP95Milliseconds] == 16)
    #expect(evaluation.acceptedMetricValues[.peakResidentBytes] == 400_000_000)
}

@Test func thresholdEqualityPasses() throws {
    let target = target()
    let exact = batch(target: target, runs: [
        run("run-1", target: target, frame: 20, memory: 500_000_000),
        run("run-2", target: target, frame: 20, memory: 500_000_000),
    ])
    let evaluation = try ForgePerformanceEvaluator.evaluate(
        budget: budget(target: target), batch: exact, trustedBatchReceiptIDs: ["trusted-batch"]
    )
    #expect(evaluation.status == .accepted)
}

@Test func worstRunCannotBeAveragedAway() throws {
    let target = target()
    let measurements = batch(target: target, runs: [
        run("fast", target: target, frame: 10),
        run("slow", target: target, frame: 25),
    ])
    let evaluation = try ForgePerformanceEvaluator.evaluate(
        budget: budget(target: target), batch: measurements, trustedBatchReceiptIDs: ["trusted-batch"]
    )

    #expect(evaluation.status == .failed)
    #expect(evaluation.failures.count == 1)
    #expect(evaluation.failures.first?.metric == .frameTimeP95Milliseconds)
    #expect(evaluation.failures.first?.worstObserved == 25)
    #expect(evaluation.failures.first?.maximumAllowed == 20)
    #expect(evaluation.acceptedMetricValues.isEmpty)
}

@Test func missingMetricBlocksInsteadOfPassing() throws {
    let target = target()
    let incompleteRun = try ForgePerformanceRun(
        runID: "run-1",
        target: target,
        observations: [observation(.frameTimeP95Milliseconds, 15, samples: 120)]
    )
    let measurements = batch(target: target, runs: [incompleteRun, run("run-2", target: target)])
    let evaluation = try ForgePerformanceEvaluator.evaluate(
        budget: budget(target: target), batch: measurements, trustedBatchReceiptIDs: ["trusted-batch"]
    )

    #expect(evaluation.status == .blocked)
    #expect(evaluation.blockers.contains(.missingMetric(metric: .peakResidentBytes, runID: "run-1")))
}

@Test func insufficientSamplesBlock() throws {
    let target = target()
    let measurements = batch(target: target, runs: [
        run("run-1", target: target, frameSamples: 119),
        run("run-2", target: target),
    ])
    let evaluation = try ForgePerformanceEvaluator.evaluate(
        budget: budget(target: target), batch: measurements, trustedBatchReceiptIDs: ["trusted-batch"]
    )
    #expect(evaluation.status == .blocked)
    #expect(evaluation.blockers.contains(
        .insufficientSamples(metric: .frameTimeP95Milliseconds, runID: "run-1", required: 120, actual: 119)
    ))
}

@Test func insufficientRunCountBlocks() throws {
    let target = target()
    let measurements = batch(target: target, runs: [run("only", target: target)])
    let evaluation = try ForgePerformanceEvaluator.evaluate(
        budget: budget(target: target, runs: 2), batch: measurements, trustedBatchReceiptIDs: ["trusted-batch"]
    )
    #expect(evaluation.status == .blocked)
    #expect(evaluation.blockers.contains(.insufficientRuns(required: 2, actual: 1)))
}

@Test func serializedReceiptCannotAuthorizeItself() throws {
    let target = target()
    #expect(throws: ForgePerformanceError.untrustedBatchReceipt("trusted-batch")) {
        try ForgePerformanceEvaluator.evaluate(
            budget: budget(target: target), batch: batch(target: target), trustedBatchReceiptIDs: []
        )
    }
}

@Test func staleSourceBatchFailsClosed() throws {
    let currentTarget = target(source: "source-new")
    let staleTarget = target(source: "source-old")
    #expect(throws: ForgePerformanceError.targetMismatch("batch.target")) {
        try ForgePerformanceEvaluator.evaluate(
            budget: budget(target: currentTarget),
            batch: batch(target: staleTarget),
            trustedBatchReceiptIDs: ["trusted-batch"]
        )
    }
}

@Test func crossMissionBatchFailsClosed() throws {
    let currentTarget = target(mission: "mission-new")
    let staleTarget = target(mission: "mission-old")
    #expect(throws: ForgePerformanceError.targetMismatch("batch.target")) {
        try ForgePerformanceEvaluator.evaluate(
            budget: budget(target: currentTarget),
            batch: batch(target: staleTarget),
            trustedBatchReceiptIDs: ["trusted-batch"]
        )
    }
}

@Test func staleBudgetAuthorityFailsClosed() throws {
    let currentTarget = target(budgetRevision: 4, budgetReceipt: "budget-4")
    let staleTarget = target(budgetRevision: 3, budgetReceipt: "budget-3")
    #expect(throws: ForgePerformanceError.targetMismatch("batch.target")) {
        try ForgePerformanceEvaluator.evaluate(
            budget: budget(target: currentTarget),
            batch: batch(target: staleTarget),
            trustedBatchReceiptIDs: ["trusted-batch"]
        )
    }
}

@Test func simulatorEvidenceCannotSatisfyPhysicalDeviceTarget() throws {
    let physical = target(environment: environment(kind: .physicalDevice))
    let simulator = target(environment: environment(kind: .simulator))
    #expect(throws: ForgePerformanceError.targetMismatch("batch.target")) {
        try ForgePerformanceEvaluator.evaluate(
            budget: budget(target: physical),
            batch: batch(target: simulator),
            trustedBatchReceiptIDs: ["trusted-batch"]
        )
    }
}

@Test func duplicateConstraintMetricsRejected() {
    let duplicate = constraint(.frameTimeP95Milliseconds, max: 20)
    #expect(throws: ForgePerformanceError.duplicateMetric("frameTimeP95Milliseconds")) {
        try ForgePerformanceBudget(
            target: target(), requiredRunCount: 1, constraints: [duplicate, duplicate]
        )
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

@Test func invalidRequiredRunCountRejected() {
    #expect(throws: ForgePerformanceError.invalidRunCount(0)) {
        try ForgePerformanceBudget(
            target: target(), requiredRunCount: 0, constraints: [constraint(.launchTimeMilliseconds, max: 1_000)]
        )
    }
}

@Test func protocolRevisionDriftIsTargetDrift() throws {
    let p2 = target(protocolRevision: 2)
    let p3 = target(protocolRevision: 3)
    #expect(throws: ForgePerformanceError.targetMismatch("batch.target")) {
        try ForgePerformanceEvaluator.evaluate(
            budget: budget(target: p3), batch: batch(target: p2), trustedBatchReceiptIDs: ["trusted-batch"]
        )
    }
}

@Test func archiveRoundTripRevalidatesRawInputsAndVerdictIsRecomputed() throws {
    let target = target()
    let archive = try ForgePerformanceEvidenceArchive(
        budget: budget(target: target), batch: batch(target: target)
    )
    let data = try JSONEncoder().encode(archive)
    let decoded = try JSONDecoder().decode(ForgePerformanceEvidenceArchive.self, from: data)

    let evaluation = try ForgePerformanceEvaluator.evaluate(
        budget: decoded.budget,
        batch: decoded.batch,
        trustedBatchReceiptIDs: [decoded.batch.batchReceiptID]
    )
    #expect(evaluation.status == .accepted)
}

@Test func archiveRejectsFutureSchema() throws {
    let target = target()
    let archive = try ForgePerformanceEvidenceArchive(
        budget: budget(target: target), batch: batch(target: target)
    )
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
    let archive = try ForgePerformanceEvidenceArchive(
        budget: budget(target: target), batch: batch(target: target)
    )
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
    let constraints = [
        constraint(.peakResidentBytes, max: 500_000_000),
        constraint(.frameTimeP95Milliseconds, max: 20),
    ]
    let budget = try ForgePerformanceBudget(target: target, requiredRunCount: 1, constraints: constraints)
    let measurements = try ForgePerformanceMeasurementBatch(
        batchReceiptID: "batch",
        target: target,
        runs: [run("z", target: target), run("a", target: target)]
    )

    #expect(budget.constraints.map(\.metric) == [.frameTimeP95Milliseconds, .peakResidentBytes])
    #expect(measurements.runs.map(\.runID) == ["a", "z"])
}

import XCTest
@testable import ForgePerformanceCore

final class ForgePerformanceCoreTests: XCTestCase {
    private func target(_ revision: String = "src-7") throws -> ForgePerformanceTarget {
        try ForgePerformanceTarget(
            projectID: "project-alpha",
            sourceRevision: revision,
            journeyID: "goal-run",
            runID: "run-17",
            appBuildRevision: "app-build-42",
            runtimeRevision: "forge-runtime-9"
        )
    }

    private func environment(_ kind: ForgePerformanceEnvironmentKind = .simulator) throws -> ForgePerformanceEnvironment {
        try ForgePerformanceEnvironment(kind: kind, deviceModel: "iPhone 12", osVersion: "iOS 27.0")
    }

    private func requirement(
        _ metric: ForgePerformanceMetricKind,
        threshold: Double,
        samples: Int = 1
    ) throws -> ForgePerformanceRequirement {
        try ForgePerformanceRequirement(metric: metric, threshold: threshold, minimumSampleCount: samples)
    }

    private func observation(
        _ metric: ForgePerformanceMetricKind,
        value: Double,
        samples: Int = 120,
        receipt: String? = nil
    ) throws -> ForgePerformanceObservation {
        try ForgePerformanceObservation(
            metric: metric,
            value: value,
            sampleCount: samples,
            evidenceReceiptID: receipt ?? "receipt-\(metric.rawValue)"
        )
    }

    private func budget(
        environmentRequirement: ForgePerformanceEnvironmentRequirement = .measuredEnvironment,
        requirements: [ForgePerformanceRequirement]
    ) throws -> ForgePerformanceBudget {
        try ForgePerformanceBudget(
            budgetID: "gameplay-v1",
            budgetRevision: "budget-r3",
            environmentRequirement: environmentRequirement,
            requirements: requirements
        )
    }

    private func measurement(
        environment: ForgePerformanceEnvironment? = nil,
        observations: [ForgePerformanceObservation]
    ) throws -> ForgePerformanceMeasurement {
        try ForgePerformanceMeasurement(
            target: target(),
            environment: environment ?? self.environment(),
            authority: .runtimeHarness,
            budgetID: "gameplay-v1",
            budgetRevision: "budget-r3",
            observations: observations
        )
    }

    func testMetricUnitsAndDirectionsAreExplicit() {
        XCTAssertEqual(ForgePerformanceMetricKind.frameTimeP95Milliseconds.unit, .milliseconds)
        XCTAssertEqual(ForgePerformanceMetricKind.frameTimeP95Milliseconds.direction, .maximum)
        XCTAssertEqual(ForgePerformanceMetricKind.sustainedFramesPerSecond.unit, .framesPerSecond)
        XCTAssertEqual(ForgePerformanceMetricKind.sustainedFramesPerSecond.direction, .minimum)
    }

    func testNonFiniteOrNegativeMetricValuesFailClosed() {
        XCTAssertThrowsError(try observation(.frameTimeP95Milliseconds, value: .nan))
        XCTAssertThrowsError(try observation(.frameTimeP95Milliseconds, value: -.leastNonzeroMagnitude))
        XCTAssertThrowsError(try requirement(.frameTimeP95Milliseconds, threshold: .infinity))
    }

    func testDuplicateRequirementsAreRejected() throws {
        let first = try requirement(.frameTimeP95Milliseconds, threshold: 20)
        let second = try requirement(.frameTimeP95Milliseconds, threshold: 24)
        XCTAssertThrowsError(try budget(requirements: [first, second])) {
            XCTAssertEqual($0 as? ForgePerformanceError, .duplicateRequirement(.frameTimeP95Milliseconds))
        }
    }

    func testDuplicateObservationKindsAreRejected() throws {
        let first = try observation(.frameTimeP95Milliseconds, value: 16, receipt: "r1")
        let second = try observation(.frameTimeP95Milliseconds, value: 17, receipt: "r2")
        XCTAssertThrowsError(try measurement(observations: [first, second])) {
            XCTAssertEqual($0 as? ForgePerformanceError, .duplicateObservation(.frameTimeP95Milliseconds))
        }
    }

    func testDuplicateReceiptIDsAcrossMetricsAreRejected() throws {
        let frame = try observation(.frameTimeP95Milliseconds, value: 16, receipt: "shared")
        let memory = try observation(.peakResidentMemoryBytes, value: 100, receipt: "shared")
        XCTAssertThrowsError(try measurement(observations: [frame, memory])) {
            XCTAssertEqual($0 as? ForgePerformanceError, .duplicateReceiptID("shared"))
        }
    }

    func testExactTargetRevisionIsRequired() throws {
        let budget = try budget(requirements: [try requirement(.frameTimeP95Milliseconds, threshold: 20)])
        let measurement = try measurement(observations: [try observation(.frameTimeP95Milliseconds, value: 16)])
        XCTAssertThrowsError(
            try ForgePerformanceEvaluator.evaluate(target: target("newer-source"), budget: budget, measurement: measurement)
        ) {
            XCTAssertEqual($0 as? ForgePerformanceError, .targetMismatch)
        }
    }

    func testExactBudgetRevisionIsRequired() throws {
        let budget = try ForgePerformanceBudget(
            budgetID: "gameplay-v1",
            budgetRevision: "budget-r4",
            environmentRequirement: .measuredEnvironment,
            requirements: [try requirement(.frameTimeP95Milliseconds, threshold: 20)]
        )
        let measurement = try measurement(observations: [try observation(.frameTimeP95Milliseconds, value: 16)])
        XCTAssertThrowsError(
            try ForgePerformanceEvaluator.evaluate(target: target(), budget: budget, measurement: measurement)
        ) {
            XCTAssertEqual($0 as? ForgePerformanceError, .budgetMismatch)
        }
    }

    func testPhysicalDevicePolicyDoesNotTreatSimulatorAsProof() throws {
        let budget = try budget(
            environmentRequirement: .physicalDevice,
            requirements: [try requirement(.frameTimeP95Milliseconds, threshold: 20)]
        )
        let measurement = try measurement(observations: [try observation(.frameTimeP95Milliseconds, value: 12)])
        XCTAssertEqual(
            try ForgePerformanceEvaluator.evaluate(target: target(), budget: budget, measurement: measurement),
            .inconclusive([.physicalDeviceRequired])
        )
    }

    func testMissingMetricIsInconclusiveNotAccepted() throws {
        let budget = try budget(requirements: [
            try requirement(.frameTimeP95Milliseconds, threshold: 20),
            try requirement(.peakResidentMemoryBytes, threshold: 500_000_000),
        ])
        let measurement = try measurement(observations: [
            try observation(.frameTimeP95Milliseconds, value: 16),
        ])
        XCTAssertEqual(
            try ForgePerformanceEvaluator.evaluate(target: target(), budget: budget, measurement: measurement),
            .inconclusive([.missingMetric(.peakResidentMemoryBytes)])
        )
    }

    func testInsufficientSampleCountIsInconclusive() throws {
        let budget = try budget(requirements: [
            try requirement(.frameTimeP95Milliseconds, threshold: 20, samples: 120),
        ])
        let measurement = try measurement(observations: [
            try observation(.frameTimeP95Milliseconds, value: 10, samples: 60),
        ])
        XCTAssertEqual(
            try ForgePerformanceEvaluator.evaluate(target: target(), budget: budget, measurement: measurement),
            .inconclusive([.insufficientSamples(metric: .frameTimeP95Milliseconds, required: 120, actual: 60)])
        )
    }

    func testMaximumMetricAboveBudgetFails() throws {
        let budget = try budget(requirements: [try requirement(.frameTimeP99Milliseconds, threshold: 25)])
        let measurement = try measurement(observations: [try observation(.frameTimeP99Milliseconds, value: 31)])
        guard case let .failed(violations) = try ForgePerformanceEvaluator.evaluate(
            target: target(), budget: budget, measurement: measurement
        ) else { return XCTFail("Expected failed") }
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.metric, .frameTimeP99Milliseconds)
        XCTAssertEqual(violations.first?.measuredValue, 31)
        XCTAssertEqual(violations.first?.requiredThreshold, 25)
        XCTAssertEqual(violations.first?.direction, .maximum)
    }

    func testMinimumMetricBelowBudgetFails() throws {
        let budget = try budget(requirements: [try requirement(.sustainedFramesPerSecond, threshold: 55)])
        let measurement = try measurement(observations: [try observation(.sustainedFramesPerSecond, value: 48)])
        guard case let .failed(violations) = try ForgePerformanceEvaluator.evaluate(
            target: target(), budget: budget, measurement: measurement
        ) else { return XCTFail("Expected failed") }
        XCTAssertEqual(violations.map(\.metric), [.sustainedFramesPerSecond])
        XCTAssertEqual(violations.first?.direction, .minimum)
    }

    func testThresholdBoundaryPasses() throws {
        let budget = try budget(requirements: [
            try requirement(.frameTimeP95Milliseconds, threshold: 20),
            try requirement(.sustainedFramesPerSecond, threshold: 55),
        ])
        let measurement = try measurement(observations: [
            try observation(.frameTimeP95Milliseconds, value: 20),
            try observation(.sustainedFramesPerSecond, value: 55),
        ])
        guard case .accepted = try ForgePerformanceEvaluator.evaluate(
            target: target(), budget: budget, measurement: measurement
        ) else { return XCTFail("Expected boundary values to pass") }
    }

    func testAcceptedReceiptContainsOnlyRequiredMetricEvidence() throws {
        let budget = try budget(requirements: [
            try requirement(.frameTimeP95Milliseconds, threshold: 20),
            try requirement(.peakResidentMemoryBytes, threshold: 500_000_000),
        ])
        let measurement = try measurement(observations: [
            try observation(.frameTimeP95Milliseconds, value: 16, receipt: "frame-proof"),
            try observation(.peakResidentMemoryBytes, value: 400_000_000, receipt: "memory-proof"),
            try observation(.startupToInteractiveMilliseconds, value: 150, receipt: "extra-proof"),
        ])
        guard case let .accepted(receipt) = try ForgePerformanceEvaluator.evaluate(
            target: target(), budget: budget, measurement: measurement
        ) else { return XCTFail("Expected accepted") }
        XCTAssertEqual(receipt.target, try target())
        XCTAssertEqual(receipt.budgetID, "gameplay-v1")
        XCTAssertEqual(receipt.budgetRevision, "budget-r3")
        XCTAssertEqual(receipt.contributingReceiptIDs, ["frame-proof", "memory-proof"])
        XCTAssertFalse(receipt.contributingReceiptIDs.contains("extra-proof"))
    }

    func testPhysicalDeviceMeasurementCanSatisfyPhysicalPolicyWithoutClaimingNumbers() throws {
        let budget = try budget(
            environmentRequirement: .physicalDevice,
            requirements: [try requirement(.frameTimeP95Milliseconds, threshold: 20, samples: 120)]
        )
        let device = try environment(.physicalDevice)
        let measurement = try self.measurement(
            environment: device,
            observations: [try observation(.frameTimeP95Milliseconds, value: 18, samples: 120)]
        )
        guard case let .accepted(receipt) = try ForgePerformanceEvaluator.evaluate(
            target: target(), budget: budget, measurement: measurement
        ) else { return XCTFail("Expected physical measurement to satisfy policy") }
        XCTAssertEqual(receipt.environment.kind, .physicalDevice)
        XCTAssertEqual(receipt.authority, .runtimeHarness)
    }

    func testExactPhysicalDeviceAndOSRequirementFailsClosedOnMismatch() throws {
        let budget = try self.budget(
            environmentRequirement: .exactPhysicalDevice(deviceModel: "iPhone 12", osVersion: "iOS 27.0"),
            requirements: [try requirement(.frameTimeP95Milliseconds, threshold: 20)]
        )
        let wrongDevice = try ForgePerformanceEnvironment(
            kind: .physicalDevice,
            deviceModel: "iPhone 15 Pro",
            osVersion: "iOS 27.1"
        )
        let measurement = try self.measurement(
            environment: wrongDevice,
            observations: [try observation(.frameTimeP95Milliseconds, value: 10)]
        )
        XCTAssertEqual(
            try ForgePerformanceEvaluator.evaluate(target: target(), budget: budget, measurement: measurement),
            .inconclusive([
                .deviceModelMismatch(expected: "iPhone 12", actual: "iPhone 15 Pro"),
                .osVersionMismatch(expected: "iOS 27.0", actual: "iOS 27.1"),
            ])
        )
    }

    func testKnownViolationIsNotHiddenByAnotherMissingMetric() throws {
        let budget = try self.budget(requirements: [
            try requirement(.frameTimeP95Milliseconds, threshold: 20),
            try requirement(.peakResidentMemoryBytes, threshold: 500_000_000),
        ])
        let measurement = try self.measurement(observations: [
            try observation(.frameTimeP95Milliseconds, value: 40),
        ])
        guard case let .failed(violations) = try ForgePerformanceEvaluator.evaluate(
            target: target(), budget: budget, measurement: measurement
        ) else { return XCTFail("A definitive budget failure must not be hidden by missing evidence") }
        XCTAssertEqual(violations.map(\.metric), [.frameTimeP95Milliseconds])
    }

    func testPercentMetricRejectsValuesAboveOneHundred() {
        XCTAssertThrowsError(try observation(.droppedFrameRatePercent, value: 100.01)) {
            XCTAssertEqual($0 as? ForgePerformanceError, .invalidMetricValue)
        }
        XCTAssertNoThrow(try observation(.droppedFrameRatePercent, value: 100))
    }

    func testPercentBudgetRejectsThresholdAboveOneHundred() {
        XCTAssertThrowsError(try requirement(.droppedFrameRatePercent, threshold: 100.01)) {
            XCTAssertEqual($0 as? ForgePerformanceError, .invalidThreshold)
        }
        XCTAssertNoThrow(try requirement(.droppedFrameRatePercent, threshold: 100))
    }

    func testExactPhysicalRequirementRejectsBlankDeviceOrOSIdentity() throws {
        let req = try requirement(.frameTimeP95Milliseconds, threshold: 20)
        XCTAssertThrowsError(
            try budget(
                environmentRequirement: .exactPhysicalDevice(deviceModel: "   ", osVersion: "iOS 27.0"),
                requirements: [req]
            )
        )
        XCTAssertThrowsError(
            try budget(
                environmentRequirement: .exactPhysicalDevice(deviceModel: "iPhone 12", osVersion: "\n"),
                requirements: [req]
            )
        )
    }

    func testEmptyMeasurementCannotAcceptNonEmptyBudget() throws {
        let budget = try budget(requirements: [
            try requirement(.frameTimeP95Milliseconds, threshold: 20),
            try requirement(.sustainedFramesPerSecond, threshold: 55),
        ])
        let measurement = try measurement(observations: [])
        XCTAssertEqual(
            try ForgePerformanceEvaluator.evaluate(target: target(), budget: budget, measurement: measurement),
            .inconclusive([
                .missingMetric(.frameTimeP95Milliseconds),
                .missingMetric(.sustainedFramesPerSecond),
            ])
        )
    }

    func testMeasurementAuthorityHasNoModelReportedCase() {
        XCTAssertEqual(
            Set([ForgePerformanceEvidenceAuthority.runtimeHarness, .testHarness, .deviceMetricsHarness]),
            Set([.runtimeHarness, .testHarness, .deviceMetricsHarness])
        )
    }
}

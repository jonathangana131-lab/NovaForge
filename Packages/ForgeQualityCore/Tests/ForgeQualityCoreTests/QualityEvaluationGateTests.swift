import XCTest
@testable import ForgeQualityCore

extension ForgeQualityCoreTests {
    func testMixedPerformanceAndAccessibilityCanPassWithExactTrustedSubjects() throws {
        let binding = runBinding()
        let exactPhysical = ForgeQualityEnvironmentRequirement.exact(
            kind: .physicalDevice,
            deviceProfileID: binding.deviceProfileID,
            osBuild: binding.osBuild
        )
        let targets = [
            try ForgeQualityTarget(
                metric: .sustainedFramesPerSecond,
                comparator: .atLeast,
                threshold: 55,
                minimumSampleCount: 120,
                environmentRequirement: exactPhysical
            ),
            try ForgeQualityTarget(
                metric: .p95FrameTimeMilliseconds,
                comparator: .atMost,
                threshold: 22,
                minimumSampleCount: 120,
                environmentRequirement: exactPhysical
            ),
            try ForgeQualityTarget(
                metric: .accessibilityCriticalViolationCount,
                comparator: .atMost,
                threshold: 0,
                environmentRequirement: exactPhysical
            ),
        ]
        let trustedPolicy = ForgeQualityTrustedPolicy(authenticatedPolicy: try policy(targets: targets))
        let measurements = try [
            trusted(measurement(metric: .sustainedFramesPerSecond, value: 59, samples: 180, receipt: "fps")),
            trusted(measurement(metric: .p95FrameTimeMilliseconds, value: 18, samples: 180, receipt: "frame")),
            trusted(measurement(metric: .accessibilityCriticalViolationCount, value: 0, receipt: "a11y")),
        ]

        let result = try ForgeQualityEvaluator.evaluate(
            policy: trustedPolicy,
            binding: binding,
            measurements: measurements
        )

        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.contributingProducerReceiptIDs, [id("a11y"), id("frame"), id("fps")])
        XCTAssertEqual(result.passingProducerReceiptIDs, result.contributingProducerReceiptIDs)
    }

    func testMissingEvidenceBlocks() throws {
        let target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let result = try ForgeQualityEvaluator.evaluate(
            policy: trustedPolicy(targets: [target]),
            binding: runBinding(),
            measurements: []
        )
        XCTAssertEqual(result.status, .blocked)
        XCTAssertEqual(result.findings.map(\.reason), [.missingEvidence])
    }

    func testKnownThresholdViolationWinsOverAnotherMissingMetric() throws {
        let frame = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let a11y = try ForgeQualityTarget(
            metric: .accessibilityCriticalViolationCount,
            comparator: .atMost,
            threshold: 0
        )
        let result = try ForgeQualityEvaluator.evaluate(
            policy: trustedPolicy(targets: [frame, a11y]),
            binding: runBinding(),
            measurements: [trusted(try measurement(metric: .p95FrameTimeMilliseconds, value: 30, receipt: "slow"))]
        )
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(Set(result.findings.map(\.reason)), Set([.missingEvidence, .thresholdViolated]))
    }

    func testUndersampledMeasurementBlocksInsteadOfPassing() throws {
        let target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20,
            minimumSampleCount: 120
        )
        let result = try ForgeQualityEvaluator.evaluate(
            policy: trustedPolicy(targets: [target]),
            binding: runBinding(),
            measurements: [trusted(try measurement(metric: .p95FrameTimeMilliseconds, value: 15, samples: 10, receipt: "few"))]
        )
        XCTAssertEqual(result.status, .blocked)
        XCTAssertEqual(result.findings.map(\.reason), [.insufficientSamples])
    }

    func testExactPhysicalEnvironmentRejectsSimulatorAndOSDrift() throws {
        let physical = runBinding()
        let target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20,
            environmentRequirement: .exact(
                kind: .physicalDevice,
                deviceProfileID: physical.deviceProfileID,
                osBuild: physical.osBuild
            )
        )
        let simulator = runBinding(environmentKind: .simulator)
        let simMeasurement = try measurement(binding: simulator, metric: .p95FrameTimeMilliseconds, value: 15, receipt: "sim")
        let simResult = try ForgeQualityEvaluator.evaluate(
            policy: trustedPolicy(targets: [target]),
            binding: simulator,
            measurements: [trusted(simMeasurement)]
        )
        XCTAssertEqual(simResult.status, .blocked)
        XCTAssertEqual(simResult.findings.map(\.reason), [.environmentMismatch])

        let otherOS = runBinding(osBuild: "ios-other")
        let otherMeasurement = try measurement(binding: otherOS, metric: .p95FrameTimeMilliseconds, value: 15, receipt: "other")
        let otherResult = try ForgeQualityEvaluator.evaluate(
            policy: trustedPolicy(targets: [target]),
            binding: otherOS,
            measurements: [trusted(otherMeasurement)]
        )
        XCTAssertEqual(otherResult.status, .blocked)
        XCTAssertEqual(otherResult.findings.map(\.reason), [.environmentMismatch])
    }


    func testPolicyBindsCurrentProjectSourceAndCheckpoint() throws {
        let target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let acceptedPolicy = trustedPolicy(targets: [target])

        let wrongProject = ForgeQualityRunBinding(
            projectID: id("project-other"), sourceRevision: id("source-1"), checkpointID: id("checkpoint-7"),
            runtimeRevision: id("runtime-9"), hostAppBuildID: id("novaforge-build-42"), runID: id("run-x"),
            environmentKind: .physicalDevice, deviceProfileID: id("iPhone13,2"), osBuild: id("ios-build-27A1")
        )
        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(policy: acceptedPolicy, binding: wrongProject, measurements: [])
        ) { error in
            XCTAssertEqual(error as? ForgeQualityError, .completionBindingMismatch)
        }

        let wrongCheckpoint = ForgeQualityRunBinding(
            projectID: id("project-1"), sourceRevision: id("source-1"), checkpointID: id("checkpoint-old"),
            runtimeRevision: id("runtime-9"), hostAppBuildID: id("novaforge-build-42"), runID: id("run-y"),
            environmentKind: .physicalDevice, deviceProfileID: id("iPhone13,2"), osBuild: id("ios-build-27A1")
        )
        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(policy: acceptedPolicy, binding: wrongCheckpoint, measurements: [])
        ) { error in
            XCTAssertEqual(error as? ForgeQualityError, .completionBindingMismatch)
        }
    }

}

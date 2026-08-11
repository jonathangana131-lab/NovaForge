import XCTest
@testable import ForgeQualityCore

extension ForgeQualityCoreTests {
    func testCrossRunBindingFailsClosed() throws {
        let target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let otherBinding = runBinding(runID: "run-2")
        let other = try measurement(binding: otherBinding, metric: .p95FrameTimeMilliseconds, value: 15, receipt: "other")
        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: trustedPolicy(targets: [target]),
                binding: trustedRunBinding(),
                measurements: [trusted(other)]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeQualityError, .evidenceBindingMismatch(measurementID: id("measurement-other")))
        }
    }

    func testTrustedRunCannotReplayAcrossDifferentCompletionTarget() throws {
        let target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let completionA = try completionTarget()
        let completionB = try ForgeQualityCompletionTarget(
            missionID: id("mission-2"),
            projectID: completionA.projectID,
            sourceRevision: completionA.sourceRevision,
            constitutionRevision: completionA.constitutionRevision + 1,
            constitutionReceiptID: id("constitution-receipt-5")
        )
        let trustedForA = trustedRunBinding(completionTarget: completionA)
        let policyForB = trustedPolicy(targets: [target], completionTarget: completionB)

        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: policyForB,
                binding: trustedForA,
                measurements: []
            )
        ) { error in
            XCTAssertEqual(error as? ForgeQualityError, .completionBindingMismatch)
        }
    }

    func testDuplicateMetricScopeFailsClosed() throws {
        let target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let one = try measurement(metric: .p95FrameTimeMilliseconds, value: 15, receipt: "r1")
        let two = try ForgeQualityMeasurement(
            measurementID: id("m2"), producerReceiptID: id("r2"), binding: runBinding(),
            metric: .p95FrameTimeMilliseconds, evidenceKind: .runtimeTelemetry, value: 16, sampleCount: 1
        )
        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: trustedPolicy(targets: [target]), binding: trustedRunBinding(),
                measurements: [trusted(one), trusted(two)]
            )
        )
    }

    func testDuplicateProducerReceiptCannotSatisfyTwoTargets() throws {
        let frame = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let fps = try ForgeQualityTarget(
            metric: .sustainedFramesPerSecond,
            comparator: .atLeast,
            threshold: 50
        )
        let one = try measurement(metric: .p95FrameTimeMilliseconds, value: 15, receipt: "shared")
        let two = try ForgeQualityMeasurement(
            measurementID: id("measurement-shared-2"), producerReceiptID: id("shared"), binding: runBinding(),
            metric: .sustainedFramesPerSecond, evidenceKind: .runtimeTelemetry, value: 60, sampleCount: 1
        )
        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: trustedPolicy(targets: [frame, fps]), binding: trustedRunBinding(),
                measurements: [trusted(one), trusted(two)]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeQualityError, .duplicateProducerReceiptID(id("shared")))
        }
    }

    func testUnexpectedMeasurementIsRejectedInsteadOfAppearingInProjection() throws {
        let target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let extra = try measurement(metric: .fatalRuntimeErrorCount, value: 0, receipt: "extra")
        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: trustedPolicy(targets: [target]), binding: trustedRunBinding(),
                measurements: [trusted(extra)]
            )
        )
    }

    func testJourneyEvidenceCannotSatisfyDifferentJourney() throws {
        let journeyA = ForgeQualityScope.journey(id("journey-a"))
        let journeyB = ForgeQualityScope.journey(id("journey-b"))
        let target = try ForgeQualityTarget(
            metric: .inputLatencyP95Milliseconds,
            scope: journeyA,
            comparator: .atMost,
            threshold: 50
        )
        let wrong = try ForgeQualityMeasurement(
            measurementID: id("latency-b"), producerReceiptID: id("receipt-b"), binding: runBinding(),
            metric: .inputLatencyP95Milliseconds, scope: journeyB, evidenceKind: .interactionHarness,
            value: 20, sampleCount: 30
        )
        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: trustedPolicy(targets: [target]), binding: trustedRunBinding(),
                measurements: [trusted(wrong)]
            )
        )
    }

    func testTrustedSubjectsRetainWholeValueNotSparseReceiptIdentity() throws {
        let targetA = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let targetB = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 16
        )
        let policyA = try policy(targets: [targetA])
        let policyB = try policy(targets: [targetB])
        let trust = ForgeQualityTrustedPolicy(authenticatedPolicy: policyA)
        XCTAssertTrue(trust.exactlyMatches(policyA))
        XCTAssertFalse(trust.exactlyMatches(policyB))

        let measurementA = try measurement(metric: .p95FrameTimeMilliseconds, value: 15, receipt: "same")
        let measurementB = try measurement(metric: .p95FrameTimeMilliseconds, value: 19, receipt: "same")
        let measurementTrust = ForgeQualityTrustedMeasurement(authenticatedMeasurement: measurementA)
        XCTAssertTrue(measurementTrust.exactlyMatches(measurementA))
        XCTAssertFalse(measurementTrust.exactlyMatches(measurementB))
    }
}

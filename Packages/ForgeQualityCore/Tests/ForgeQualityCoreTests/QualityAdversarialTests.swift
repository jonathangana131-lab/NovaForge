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
                batches: [trustedBatch(other)]
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
                batches: []
            )
        ) { error in
            XCTAssertEqual(error as? ForgeQualityError, .completionBindingMismatch)
        }
    }

    func testMeasurementProtocolRevisionDriftFailsClosed() throws {
        let target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let stale = try measurement(
            protocolIdentity: measurementProtocol(revision: 6),
            metric: .p95FrameTimeMilliseconds,
            value: 15,
            receipt: "stale-protocol"
        )

        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: trustedPolicy(
                    targets: [target],
                    protocolIdentity: measurementProtocol(revision: 7)
                ),
                binding: trustedRunBinding(),
                batches: [trustedBatch(stale)]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeQualityError,
                .measurementProtocolMismatch(measurementID: id("measurement-stale-protocol"))
            )
        }
    }

    func testSameJourneyIDDifferentDefinitionCannotReplay() throws {
        let currentScope = journeyScope(
            id: "journey-same",
            definitionDigest: "journey-definition-v2"
        )
        let staleScope = journeyScope(
            id: "journey-same",
            definitionDigest: "journey-definition-v1"
        )
        let target = try ForgeQualityTarget(
            metric: .inputLatencyP95Milliseconds,
            scope: currentScope,
            comparator: .atMost,
            threshold: 50
        )
        let stale = try measurement(
            metric: .inputLatencyP95Milliseconds,
            scope: staleScope,
            value: 20,
            samples: 30,
            receipt: "stale-journey"
        )

        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: trustedPolicy(targets: [target]),
                binding: trustedRunBinding(),
                batches: [trustedBatch(stale)]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeQualityError,
                .unexpectedMeasurement(
                    metric: .inputLatencyP95Milliseconds,
                    scope: staleScope
                )
            )
        }
    }

    func testDuplicateMetricScopeFailsClosedAcrossBatches() throws {
        let target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let one = try measurement(metric: .p95FrameTimeMilliseconds, value: 15, receipt: "r1")
        let two = try measurement(metric: .p95FrameTimeMilliseconds, value: 16, receipt: "r2")

        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: trustedPolicy(targets: [target]),
                binding: trustedRunBinding(),
                batches: [trustedBatch(one), trustedBatch(two)]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeQualityError,
                .duplicateMeasurement(metric: .p95FrameTimeMilliseconds, scope: .run)
            )
        }
    }

    func testProducerReceiptCannotBeSplitAcrossTrustedBatches() throws {
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
        let one = try measurement(
            measurementID: "measurement-shared-frame",
            metric: .p95FrameTimeMilliseconds,
            value: 15,
            receipt: "shared"
        )
        let two = try measurement(
            measurementID: "measurement-shared-fps",
            metric: .sustainedFramesPerSecond,
            value: 60,
            receipt: "shared"
        )

        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: trustedPolicy(targets: [frame, fps]),
                binding: trustedRunBinding(),
                batches: [trustedBatch(one), trustedBatch(two)]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeQualityError, .duplicateProducerReceiptID(id("shared")))
        }
    }

    func testOneTrustedBatchCanSatisfyMultipleTargetsWithOneProducerReceipt() throws {
        let frame = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20,
            minimumSampleCount: 120
        )
        let fps = try ForgeQualityTarget(
            metric: .sustainedFramesPerSecond,
            comparator: .atLeast,
            threshold: 50,
            minimumSampleCount: 120
        )
        let frameMeasurement = try measurement(
            measurementID: "measurement-batch-frame",
            metric: .p95FrameTimeMilliseconds,
            value: 15,
            samples: 180,
            receipt: "telemetry-batch"
        )
        let fpsMeasurement = try measurement(
            measurementID: "measurement-batch-fps",
            metric: .sustainedFramesPerSecond,
            value: 60,
            samples: 180,
            receipt: "telemetry-batch"
        )

        let result = try ForgeQualityEvaluator.evaluate(
            policy: trustedPolicy(targets: [frame, fps]),
            binding: trustedRunBinding(),
            batches: [trustedBatch([frameMeasurement, fpsMeasurement])]
        )

        XCTAssertEqual(result.status, .passed)
        XCTAssertEqual(result.contributingProducerReceiptIDs, [id("telemetry-batch")])
        XCTAssertEqual(result.passingProducerReceiptIDs, [id("telemetry-batch")])
    }

    func testImpossibleP95GreaterThanP99FailsBatchConstruction() throws {
        let p95 = try measurement(
            measurementID: "measurement-p95",
            metric: .p95FrameTimeMilliseconds,
            value: 22,
            samples: 180,
            receipt: "frame-batch"
        )
        let p99 = try measurement(
            measurementID: "measurement-p99",
            metric: .p99FrameTimeMilliseconds,
            value: 18,
            samples: 180,
            receipt: "frame-batch"
        )

        XCTAssertThrowsError(try batch([p95, p99])) { error in
            XCTAssertEqual(error as? ForgeQualityError, .incoherentMeasurementSet(scope: .run))
        }
    }

    func testFrameStatisticsSelectedTogetherCannotComeFromSplitPopulations() throws {
        let p95Target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let p99Target = try ForgeQualityTarget(
            metric: .p99FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 30
        )
        let p95 = try measurement(
            metric: .p95FrameTimeMilliseconds,
            value: 18,
            samples: 180,
            receipt: "population-a"
        )
        let p99 = try measurement(
            metric: .p99FrameTimeMilliseconds,
            value: 24,
            samples: 180,
            receipt: "population-b"
        )

        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: trustedPolicy(targets: [p95Target, p99Target]),
                binding: trustedRunBinding(),
                batches: [trustedBatch(p95), trustedBatch(p99)]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeQualityError, .incoherentMeasurementSet(scope: .run))
        }
    }

    func testFrameStatisticsSelectedTogetherRequireMatchingSampleCounts() throws {
        let p95 = try measurement(
            measurementID: "measurement-count-p95",
            metric: .p95FrameTimeMilliseconds,
            value: 18,
            samples: 180,
            receipt: "count-batch"
        )
        let p99 = try measurement(
            measurementID: "measurement-count-p99",
            metric: .p99FrameTimeMilliseconds,
            value: 24,
            samples: 181,
            receipt: "count-batch"
        )

        XCTAssertThrowsError(try batch([p95, p99])) { error in
            XCTAssertEqual(error as? ForgeQualityError, .incoherentMeasurementSet(scope: .run))
        }
    }

    func testAverageMayValidlyExceedP95ForOnePopulation() throws {
        let averageTarget = try ForgeQualityTarget(
            metric: .averageFrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 50
        )
        let p95Target = try ForgeQualityTarget(
            metric: .p95FrameTimeMilliseconds,
            comparator: .atMost,
            threshold: 20
        )
        let average = try measurement(
            measurementID: "measurement-average-tail",
            metric: .averageFrameTimeMilliseconds,
            value: 40,
            samples: 100,
            receipt: "tail-population"
        )
        let p95 = try measurement(
            measurementID: "measurement-p95-tail",
            metric: .p95FrameTimeMilliseconds,
            value: 10,
            samples: 100,
            receipt: "tail-population"
        )

        let result = try ForgeQualityEvaluator.evaluate(
            policy: trustedPolicy(targets: [averageTarget, p95Target]),
            binding: trustedRunBinding(),
            batches: [trustedBatch([average, p95])]
        )

        XCTAssertEqual(result.status, .passed)
        XCTAssertTrue(result.findings.isEmpty)
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
                policy: trustedPolicy(targets: [target]),
                binding: trustedRunBinding(),
                batches: [trustedBatch(extra)]
            )
        )
    }

    func testJourneyEvidenceCannotSatisfyDifferentJourney() throws {
        let journeyA = journeyScope(
            id: "journey-a",
            definitionDigest: "journey-a-definition-v1"
        )
        let journeyB = journeyScope(
            id: "journey-b",
            definitionDigest: "journey-b-definition-v1"
        )
        let target = try ForgeQualityTarget(
            metric: .inputLatencyP95Milliseconds,
            scope: journeyA,
            comparator: .atMost,
            threshold: 50
        )
        let wrong = try measurement(
            metric: .inputLatencyP95Milliseconds,
            scope: journeyB,
            value: 20,
            samples: 30,
            receipt: "receipt-b"
        )
        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: trustedPolicy(targets: [target]),
                binding: trustedRunBinding(),
                batches: [trustedBatch(wrong)]
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

        let batchA = try batch([measurementA])
        let batchB = try batch([measurementB])
        let batchTrust = ForgeQualityTrustedMeasurementBatch(authenticatedBatch: batchA)
        XCTAssertTrue(batchTrust.exactlyMatches(batchA))
        XCTAssertFalse(batchTrust.exactlyMatches(batchB))
    }
}

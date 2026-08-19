import XCTest
@testable import ForgeQualityCore

extension ForgeQualityCoreTests {
    func testTrustedBatchAllowsOneProducerReceiptAcrossMultipleMetrics() throws {
        let binding = runBinding()
        let protocolIdentity = measurementProtocol()
        let sharedProducerReceipt = id("runtime-telemetry-run-1")

        let p95 = try ForgeQualityMeasurement(
            measurementID: id("measurement-p95"),
            producerReceiptID: sharedProducerReceipt,
            binding: binding,
            measurementProtocol: protocolIdentity,
            metric: .p95FrameTimeMilliseconds,
            evidenceKind: .runtimeTelemetry,
            value: 16,
            sampleCount: 1_000
        )
        let p99 = try ForgeQualityMeasurement(
            measurementID: id("measurement-p99"),
            producerReceiptID: sharedProducerReceipt,
            binding: binding,
            measurementProtocol: protocolIdentity,
            metric: .p99FrameTimeMilliseconds,
            evidenceKind: .runtimeTelemetry,
            value: 20,
            sampleCount: 1_000
        )
        let batch = try ForgeQualityMeasurementBatch(
            batchReceiptID: id("quality-batch-1"),
            binding: binding,
            measurementProtocol: protocolIdentity,
            measurements: [p99, p95]
        )
        let trustedBatch = ForgeQualityTrustedMeasurementBatch(authenticatedBatch: batch)
        let acceptedPolicy = trustedPolicy(
            targets: [
                try ForgeQualityTarget(
                    metric: .p95FrameTimeMilliseconds,
                    comparator: .atMost,
                    threshold: 18,
                    minimumSampleCount: 1_000
                ),
                try ForgeQualityTarget(
                    metric: .p99FrameTimeMilliseconds,
                    comparator: .atMost,
                    threshold: 22,
                    minimumSampleCount: 1_000
                ),
            ],
            protocolIdentity: protocolIdentity
        )

        let assessment = try ForgeQualityEvaluator.evaluate(
            policy: acceptedPolicy,
            binding: trustedRunBinding(binding),
            batch: trustedBatch
        )

        XCTAssertEqual(assessment.status, .passed)
        XCTAssertEqual(assessment.measurementBatchReceiptID, id("quality-batch-1"))
        XCTAssertEqual(assessment.contributingProducerReceiptIDs, [sharedProducerReceipt])
        XCTAssertEqual(assessment.passingProducerReceiptIDs, [sharedProducerReceipt])
    }

    func testTrustedBatchRejectsImpossibleFramePercentileOrdering() throws {
        let binding = runBinding()
        let protocolIdentity = measurementProtocol()
        let producerReceipt = id("runtime-telemetry-run-1")

        let p95 = try ForgeQualityMeasurement(
            measurementID: id("measurement-p95"),
            producerReceiptID: producerReceipt,
            binding: binding,
            measurementProtocol: protocolIdentity,
            metric: .p95FrameTimeMilliseconds,
            evidenceKind: .runtimeTelemetry,
            value: 18,
            sampleCount: 2_000
        )
        let p99 = try ForgeQualityMeasurement(
            measurementID: id("measurement-p99"),
            producerReceiptID: producerReceipt,
            binding: binding,
            measurementProtocol: protocolIdentity,
            metric: .p99FrameTimeMilliseconds,
            evidenceKind: .runtimeTelemetry,
            value: 10,
            sampleCount: 2_000
        )
        let trustedBatch = ForgeQualityTrustedMeasurementBatch(
            authenticatedBatch: try ForgeQualityMeasurementBatch(
                batchReceiptID: id("quality-batch-impossible"),
                binding: binding,
                measurementProtocol: protocolIdentity,
                measurements: [p95, p99]
            )
        )
        let acceptedPolicy = trustedPolicy(
            targets: [
                try ForgeQualityTarget(
                    metric: .p95FrameTimeMilliseconds,
                    comparator: .atMost,
                    threshold: 30,
                    minimumSampleCount: 100
                ),
                try ForgeQualityTarget(
                    metric: .p99FrameTimeMilliseconds,
                    comparator: .atMost,
                    threshold: 30,
                    minimumSampleCount: 100
                ),
            ],
            protocolIdentity: protocolIdentity
        )

        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: acceptedPolicy,
                binding: trustedRunBinding(binding),
                batch: trustedBatch
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeQualityError,
                .incoherentFramePercentiles(scope: .run)
            )
        }
    }

    func testTrustedBatchRejectsPercentilesFromDifferentSamplePopulations() throws {
        let binding = runBinding()
        let protocolIdentity = measurementProtocol()

        let p95 = try ForgeQualityMeasurement(
            measurementID: id("measurement-p95"),
            producerReceiptID: id("telemetry-p95"),
            binding: binding,
            measurementProtocol: protocolIdentity,
            metric: .p95FrameTimeMilliseconds,
            evidenceKind: .runtimeTelemetry,
            value: 16,
            sampleCount: 1_000
        )
        let p99 = try ForgeQualityMeasurement(
            measurementID: id("measurement-p99"),
            producerReceiptID: id("telemetry-p99"),
            binding: binding,
            measurementProtocol: protocolIdentity,
            metric: .p99FrameTimeMilliseconds,
            evidenceKind: .runtimeTelemetry,
            value: 20,
            sampleCount: 900
        )
        let trustedBatch = ForgeQualityTrustedMeasurementBatch(
            authenticatedBatch: try ForgeQualityMeasurementBatch(
                batchReceiptID: id("quality-batch-population-mismatch"),
                binding: binding,
                measurementProtocol: protocolIdentity,
                measurements: [p95, p99]
            )
        )
        let acceptedPolicy = trustedPolicy(
            targets: [
                try ForgeQualityTarget(
                    metric: .p95FrameTimeMilliseconds,
                    comparator: .atMost,
                    threshold: 30
                ),
                try ForgeQualityTarget(
                    metric: .p99FrameTimeMilliseconds,
                    comparator: .atMost,
                    threshold: 30
                ),
            ],
            protocolIdentity: protocolIdentity
        )

        XCTAssertThrowsError(
            try ForgeQualityEvaluator.evaluate(
                policy: acceptedPolicy,
                binding: trustedRunBinding(binding),
                batch: trustedBatch
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeQualityError,
                .incoherentFramePercentiles(scope: .run)
            )
        }
    }

    func testBatchDecodeRevalidatesWholeRunIdentity() throws {
        let binding = runBinding()
        let protocolIdentity = measurementProtocol()
        let measurement = try ForgeQualityMeasurement(
            measurementID: id("measurement-p95"),
            producerReceiptID: id("producer"),
            binding: binding,
            measurementProtocol: protocolIdentity,
            metric: .p95FrameTimeMilliseconds,
            evidenceKind: .runtimeTelemetry,
            value: 16,
            sampleCount: 100
        )
        let batch = try ForgeQualityMeasurementBatch(
            batchReceiptID: id("quality-batch-roundtrip"),
            binding: binding,
            measurementProtocol: protocolIdentity,
            measurements: [measurement]
        )

        let data = try JSONEncoder().encode(batch)
        let decoded = try JSONDecoder().decode(ForgeQualityMeasurementBatch.self, from: data)
        XCTAssertEqual(decoded, batch)
    }
}

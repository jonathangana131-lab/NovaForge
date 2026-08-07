import XCTest
@testable import AgentDomain

final class LocalModelCompatibilityTests: XCTestCase {
    func testUnsupportedArchitectureFailsClosedWithoutMeasuredEvidence() {
        let result = evaluate(
            descriptor: descriptor(architecture: "unsupported-arch"),
            benchmark: benchmark()
        )

        XCTAssertEqual(result.label, .unsupported)
        XCTAssertEqual(result.reasons, [.architectureUnsupported])
        XCTAssertFalse(result.isPreflightEligible)
        XCTAssertFalse(result.hasMeasuredEvidence)
        XCTAssertTrue(result.evidence.contains { $0.code == "architecture.unsupported" })
    }

    func testInsufficientStorageIsTooLargeBeforeBenchmark() {
        let result = evaluate(
            descriptor: descriptor(fileSizeBytes: 9_000),
            device: device(availableStorageBytes: 8_000),
            benchmark: benchmark()
        )

        XCTAssertEqual(result.label, .tooLarge)
        XCTAssertEqual(result.reasons, [.insufficientStorage])
        XCTAssertFalse(result.isPreflightEligible)
        XCTAssertFalse(result.hasMeasuredEvidence)
    }

    func testMissingMemoryEstimateRemainsUntestedInsteadOfGuessingGood() {
        let result = evaluate(
            descriptor: descriptor(estimatedPeakMemoryBytes: nil),
            benchmark: nil
        )

        XCTAssertEqual(result.label, .untested)
        XCTAssertEqual(result.reasons, [.missingMemoryEstimate])
        XCTAssertTrue(result.isPreflightEligible)
        XCTAssertFalse(result.hasMeasuredEvidence)
    }

    func testSafePreflightWithoutBenchmarkRemainsUntested() {
        let result = evaluate(benchmark: nil)

        XCTAssertEqual(result.label, .untested)
        XCTAssertEqual(result.reasons, [.benchmarkMissing])
        XCTAssertTrue(result.isPreflightEligible)
        XCTAssertFalse(result.hasMeasuredEvidence)
    }

    func testStaleRevisionBenchmarkCannotMintMeasuredCompatibility() {
        let result = evaluate(
            benchmark: benchmark(revision: "older-revision")
        )

        XCTAssertEqual(result.label, .untested)
        XCTAssertEqual(result.reasons, [.benchmarkNotApplicable])
        XCTAssertFalse(result.hasMeasuredEvidence)
        XCTAssertTrue(result.evidence.contains { $0.code == "benchmark.not_applicable" })
    }

    func testExactDeviceBenchmarkProducesMeasuredExcellentLabel() {
        let result = evaluate(
            benchmark: benchmark(
                generationTokensPerSecond: 9.5,
                successfulSmokeRuns: 3,
                failedSmokeRuns: 0,
                peakMemoryBytes: 3_500
            )
        )

        XCTAssertEqual(result.label, .excellent)
        XCTAssertEqual(result.reasons, [.measuredPerformance])
        XCTAssertTrue(result.isPreflightEligible)
        XCTAssertTrue(result.hasMeasuredEvidence)
        XCTAssertTrue(result.evidence.contains {
            $0.kind == .measured && $0.code == "benchmark.exact_device"
        })
        XCTAssertTrue(result.evidence.contains {
            $0.kind == .measured && $0.code == "memory.peak_observed"
        })
    }

    func testExactBenchmarkBelowGoodThresholdIsMeasuredSlow() {
        let result = evaluate(
            benchmark: benchmark(
                generationTokensPerSecond: 1.5,
                successfulSmokeRuns: 2,
                failedSmokeRuns: 0
            )
        )

        XCTAssertEqual(result.label, .slow)
        XCTAssertEqual(result.reasons, [.measuredPerformance])
        XCTAssertTrue(result.hasMeasuredEvidence)
    }

    func testMeasuredPeakMemoryCanBlockDespiteCatalogEstimatePassing() {
        let result = evaluate(
            benchmark: benchmark(
                generationTokensPerSecond: 9,
                successfulSmokeRuns: 2,
                failedSmokeRuns: 0,
                peakMemoryBytes: 9_000
            )
        )

        XCTAssertEqual(result.label, .tooLarge)
        XCTAssertEqual(result.reasons, [.memoryBudgetExceeded])
        XCTAssertFalse(result.isPreflightEligible)
        XCTAssertTrue(result.hasMeasuredEvidence)
        XCTAssertTrue(result.evidence.contains { $0.code == "memory.measured_budget_exceeded" })
    }

    func testKnownUnsupportedMissionCapabilityFailsClosed() {
        let result = LocalModelCompatibilityEvaluator.evaluate(
            descriptor: descriptor(toolCalling: .unsupported),
            device: device(),
            requirements: .init(requiresToolCalling: true),
            benchmark: benchmark()
        )

        XCTAssertEqual(result.label, .unsupported)
        XCTAssertEqual(result.reasons, [.toolCallingUnavailable])
        XCTAssertFalse(result.hasMeasuredEvidence)
    }

    func testUnknownMissionCapabilityRemainsUntestedRatherThanUnsupported() {
        let result = LocalModelCompatibilityEvaluator.evaluate(
            descriptor: descriptor(toolCalling: .unknown),
            device: device(),
            requirements: .init(requiresToolCalling: true),
            benchmark: benchmark()
        )

        XCTAssertEqual(result.label, .untested)
        XCTAssertEqual(result.reasons, [.toolCallingUnverified])
        XCTAssertTrue(result.isPreflightEligible)
        XCTAssertFalse(result.hasMeasuredEvidence)
        XCTAssertTrue(result.evidence.contains { $0.code == "capability.tool_calling.unverified" })
    }

    func testUnknownStructuredOutputRequirementRemainsUntested() {
        let result = LocalModelCompatibilityEvaluator.evaluate(
            descriptor: descriptor(structuredOutput: .unknown),
            device: device(),
            requirements: .init(requiresStructuredOutput: true),
            benchmark: benchmark()
        )

        XCTAssertEqual(result.label, .untested)
        XCTAssertEqual(result.reasons, [.structuredOutputUnverified])
        XCTAssertFalse(result.hasMeasuredEvidence)
    }

    func testUnstableBenchmarkDoesNotMislabelReliabilityAsSlowPerformance() {
        let result = evaluate(
            benchmark: benchmark(
                generationTokensPerSecond: 20,
                successfulSmokeRuns: 1,
                failedSmokeRuns: 1
            )
        )

        XCTAssertEqual(result.label, .untested)
        XCTAssertEqual(result.reasons, [.benchmarkUnstable])
        XCTAssertTrue(result.hasMeasuredEvidence)
        XCTAssertFalse(result.evidence.contains { $0.code == "performance.policy_classification" })
    }

    func testInvalidPolicyCannotMintFriendlyMeasuredLabel() {
        let invalidPolicy = LocalModelCompatibilityPolicy(
            minimumCompletedSmokeRuns: 2,
            maximumFailureRate: 0,
            excellentTokensPerSecond: 2,
            goodTokensPerSecond: 8
        )

        let result = LocalModelCompatibilityEvaluator.evaluate(
            descriptor: descriptor(),
            device: device(),
            benchmark: benchmark(),
            policy: invalidPolicy
        )

        XCTAssertEqual(result.label, .untested)
        XCTAssertEqual(result.reasons, [.invalidPolicy])
        XCTAssertTrue(result.hasMeasuredEvidence)
        XCTAssertFalse(result.evidence.contains { $0.code == "performance.policy_classification" })
    }

    func testResultRoundTripsThroughCodableWithoutLosingEvidenceProvenance() throws {
        let result = evaluate(benchmark: benchmark())
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(LocalModelCompatibilityResult.self, from: data)

        XCTAssertEqual(decoded, result)
        XCTAssertTrue(decoded.evidence.contains { $0.kind == .sourceReported })
        XCTAssertTrue(decoded.evidence.contains { $0.kind == .inferred })
        XCTAssertTrue(decoded.evidence.contains { $0.kind == .measured })
    }

    private func evaluate(
        descriptor: LocalModelCatalogDescriptor? = nil,
        device: LocalModelDeviceProfile? = nil,
        benchmark: LocalModelBenchmarkObservation?
    ) -> LocalModelCompatibilityResult {
        LocalModelCompatibilityEvaluator.evaluate(
            descriptor: descriptor ?? self.descriptor(),
            device: device ?? self.device(),
            benchmark: benchmark
        )
    }

    private func descriptor(
        architecture: String = "llama",
        fileSizeBytes: UInt64 = 4_000,
        estimatedPeakMemoryBytes: UInt64? = 5_000,
        toolCalling: LocalModelCapabilityStatus = .supported,
        structuredOutput: LocalModelCapabilityStatus = .supported
    ) -> LocalModelCatalogDescriptor {
        LocalModelCatalogDescriptor(
            modelID: "example/code-model",
            revision: "rev-2",
            architecture: architecture,
            fileSizeBytes: fileSizeBytes,
            estimatedPeakMemoryBytes: estimatedPeakMemoryBytes,
            toolCalling: toolCalling,
            structuredOutput: structuredOutput,
            source: "fixture-catalog",
            license: "test-license"
        )
    }

    private func device(
        availableStorageBytes: UInt64 = 10_000,
        memoryBudgetBytes: UInt64 = 8_000
    ) -> LocalModelDeviceProfile {
        LocalModelDeviceProfile(
            profileID: "iphone12-test-profile",
            supportedArchitectures: ["llama", "qwen"],
            availableStorageBytes: availableStorageBytes,
            memoryBudgetBytes: memoryBudgetBytes
        )
    }

    private func benchmark(
        revision: String = "rev-2",
        generationTokensPerSecond: Double = 8.25,
        successfulSmokeRuns: UInt16 = 2,
        failedSmokeRuns: UInt16 = 0,
        peakMemoryBytes: UInt64? = 4_000
    ) -> LocalModelBenchmarkObservation {
        LocalModelBenchmarkObservation(
            modelID: "example/code-model",
            revision: revision,
            deviceProfileID: "iphone12-test-profile",
            measuredAt: AgentInstant(rawValue: 1_784_000_000_000),
            generationTokensPerSecond: generationTokensPerSecond,
            successfulSmokeRuns: successfulSmokeRuns,
            failedSmokeRuns: failedSmokeRuns,
            peakMemoryBytes: peakMemoryBytes
        )
    }
}

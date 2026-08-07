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

    func testInferredMemoryEstimatePreservesInferredProvenance() {
        let result = evaluate(
            descriptor: descriptor(memoryEstimateProvenance: .inferred),
            benchmark: nil
        )

        XCTAssertTrue(result.evidence.contains {
            $0.code == "catalog.memory_estimate" && $0.kind == .inferred
        })
        XCTAssertFalse(result.evidence.contains {
            $0.code == "catalog.memory_estimate" && $0.kind == .sourceReported
        })
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

    func testDifferentArtifactBenchmarkCannotMintMeasuredCompatibility() {
        let result = evaluate(
            benchmark: benchmark(artifactID: "artifact-q8")
        )

        XCTAssertEqual(result.label, .untested)
        XCTAssertEqual(result.reasons, [.benchmarkNotApplicable])
        XCTAssertFalse(result.hasMeasuredEvidence)
    }

    func testDifferentQuantizationBenchmarkCannotMintMeasuredCompatibility() {
        let result = evaluate(
            benchmark: benchmark(quantization: "Q8_0")
        )

        XCTAssertEqual(result.label, .untested)
        XCTAssertEqual(result.reasons, [.benchmarkNotApplicable])
        XCTAssertFalse(result.hasMeasuredEvidence)
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

    func testKnownInsufficientContextWindowFailsMissionRequirement() {
        let result = LocalModelCompatibilityEvaluator.evaluate(
            descriptor: descriptor(contextWindowTokens: 8_192),
            device: device(),
            requirements: .init(minimumContextTokens: 16_384),
            benchmark: benchmark()
        )

        XCTAssertEqual(result.label, .unsupported)
        XCTAssertEqual(result.reasons, [.contextWindowInsufficient])
        XCTAssertFalse(result.hasMeasuredEvidence)
        XCTAssertTrue(result.evidence.contains { $0.code == "context.window.insufficient" })
    }

    func testUnknownContextWindowRemainsUntestedForContextSensitiveMission() {
        let result = LocalModelCompatibilityEvaluator.evaluate(
            descriptor: descriptor(contextWindowTokens: nil),
            device: device(),
            requirements: .init(minimumContextTokens: 16_384),
            benchmark: benchmark()
        )

        XCTAssertEqual(result.label, .untested)
        XCTAssertEqual(result.reasons, [.contextWindowUnverified])
        XCTAssertTrue(result.isPreflightEligible)
        XCTAssertFalse(result.hasMeasuredEvidence)
    }

    func testUnstableBenchmarkDoesNotMislabelReliabilityAsSlowPerformance() {
        let result = evaluate(
            benchmark: benchmark(
                generationTokensPerSecond: 20,
                successfulSmokeRuns: 2,
                failedSmokeRuns: 1
            )
        )

        XCTAssertEqual(result.label, .untested)
        XCTAssertEqual(result.reasons, [.benchmarkUnstable])
        XCTAssertTrue(result.hasMeasuredEvidence)
        XCTAssertFalse(result.evidence.contains { $0.code == "performance.policy_classification" })
    }

    func testAllFailedBenchmarkCannotMintPerformanceEvenWithPermissiveFailurePolicy() {
        let permissivePolicy = LocalModelCompatibilityPolicy(
            minimumSuccessfulSmokeRuns: 1,
            maximumFailureRate: 1,
            excellentTokensPerSecond: 8,
            goodTokensPerSecond: 3
        )
        let result = LocalModelCompatibilityEvaluator.evaluate(
            descriptor: descriptor(),
            device: device(),
            benchmark: benchmark(
                generationTokensPerSecond: 100,
                successfulSmokeRuns: 0,
                failedSmokeRuns: 4
            ),
            policy: permissivePolicy
        )

        XCTAssertEqual(result.label, .untested)
        XCTAssertEqual(result.reasons, [.benchmarkInsufficient])
        XCTAssertTrue(result.hasMeasuredEvidence)
        XCTAssertFalse(result.evidence.contains { $0.code == "performance.policy_classification" })
    }

    func testInvalidPolicyCannotMintFriendlyMeasuredLabel() {
        let invalidPolicy = LocalModelCompatibilityPolicy(
            minimumSuccessfulSmokeRuns: 2,
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

    func testDescriptorCarriesCatalogFormatQuantizationAndContextEvidence() {
        let result = evaluate(benchmark: nil)

        XCTAssertTrue(result.evidence.contains { $0.code == "catalog.format" })
        XCTAssertTrue(result.evidence.contains { $0.code == "catalog.quantization" })
        XCTAssertTrue(result.evidence.contains { $0.code == "catalog.context_window" })
        XCTAssertTrue(result.evidence.contains { $0.code == "catalog.identity" && $0.detail.contains("artifact-q4") })
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
        artifactID: String = "artifact-q4",
        architecture: String = "llama",
        quantization: String? = "Q4_K_M",
        contextWindowTokens: UInt64? = 32_768,
        fileSizeBytes: UInt64 = 4_000,
        estimatedPeakMemoryBytes: UInt64? = 5_000,
        memoryEstimateProvenance: LocalModelEstimateProvenance = .sourceReported,
        toolCalling: LocalModelCapabilityStatus = .supported,
        structuredOutput: LocalModelCapabilityStatus = .supported
    ) -> LocalModelCatalogDescriptor {
        LocalModelCatalogDescriptor(
            modelID: "example/code-model",
            revision: "rev-2",
            artifactID: artifactID,
            format: "gguf",
            architecture: architecture,
            quantization: quantization,
            contextWindowTokens: contextWindowTokens,
            fileSizeBytes: fileSizeBytes,
            estimatedPeakMemory: estimatedPeakMemoryBytes.map {
                LocalModelMemoryEstimate(
                    peakBytes: $0,
                    provenance: memoryEstimateProvenance
                )
            },
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
        artifactID: String = "artifact-q4",
        quantization: String? = "Q4_K_M",
        generationTokensPerSecond: Double = 8.25,
        successfulSmokeRuns: UInt16 = 2,
        failedSmokeRuns: UInt16 = 0,
        peakMemoryBytes: UInt64? = 4_000
    ) -> LocalModelBenchmarkObservation {
        LocalModelBenchmarkObservation(
            modelID: "example/code-model",
            revision: revision,
            artifactID: artifactID,
            quantization: quantization,
            deviceProfileID: "iphone12-test-profile",
            measuredAt: AgentInstant(rawValue: 1_784_000_000_000),
            generationTokensPerSecond: generationTokensPerSecond,
            successfulSmokeRuns: successfulSmokeRuns,
            failedSmokeRuns: failedSmokeRuns,
            peakMemoryBytes: peakMemoryBytes
        )
    }
}

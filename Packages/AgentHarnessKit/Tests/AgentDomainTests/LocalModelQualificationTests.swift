import XCTest
@testable import AgentDomain

final class LocalModelQualificationTests: XCTestCase {
    private let artifactSHA256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let measuredAt = AgentInstant(rawValue: 1_786_000_000_000)

    func testExactPhysicalDeviceReceiptIsBadgeEligible() {
        let benchmark = benchmark()
        let decision = qualify(benchmark: benchmark)

        XCTAssertTrue(decision.isCompatibilityBadgeEligible)
        XCTAssertEqual(decision.reasons, [])
        XCTAssertTrue(decision.evidence.contains { $0.code == "qualification.exact_execution_identity" })
        XCTAssertTrue(decision.evidence.contains { $0.code == "qualification.resource_observation" })
        XCTAssertTrue(decision.evidence.contains { $0.code == "qualification.thermal_observation" })
        XCTAssertTrue(decision.evidence.contains { $0.code == "qualification.task_suite" })
        XCTAssertTrue(decision.evidence.allSatisfy { $0.kind == .measured })
    }

    func testSimulatorEvidenceCannotQualifyPhysicalDeviceBadge() {
        let target = target(environment: .simulator)
        let decision = qualify(target: target, receipt: receipt(target: target))

        XCTAssertFalse(decision.isCompatibilityBadgeEligible)
        XCTAssertEqual(decision.reasons, [.environmentNotPhysicalDevice])
        XCTAssertTrue(decision.evidence.contains { $0.code == "qualification.environment_not_physical_device" })
    }

    func testReceiptFromDifferentRuntimeRevisionCannotQualifyCurrentTarget() {
        let currentTarget = target(runtimeRevision: "llama.cpp-main@abc123")
        let staleTarget = target(runtimeRevision: "llama.cpp-main@older")
        let decision = qualify(
            target: currentTarget,
            receipt: receipt(target: staleTarget)
        )

        XCTAssertFalse(decision.isCompatibilityBadgeEligible)
        XCTAssertEqual(decision.reasons, [.targetIdentityMismatch])
        XCTAssertTrue(decision.evidence.contains { $0.code == "qualification.target_identity_mismatch" })
    }

    func testMissingTokenizerIdentityFailsClosed() {
        let invalidTarget = target(tokenizerRevision: "   ")
        let decision = qualify(
            target: invalidTarget,
            receipt: receipt(target: invalidTarget)
        )

        XCTAssertFalse(decision.isCompatibilityBadgeEligible)
        XCTAssertEqual(decision.reasons, [.targetIdentityInvalid])
        XCTAssertTrue(decision.evidence.contains { $0.code == "qualification.target_identity_invalid" })
    }

    func testCompatibilityWithoutMeasuredPerformanceCannotQualify() {
        let descriptor = descriptor()
        let device = device()
        let benchmark = benchmark(generationRateProvenance: .estimatedFromOutput)
        let compatibility = LocalModelCompatibilityEvaluator.evaluate(
            descriptor: descriptor,
            device: device,
            benchmark: benchmark
        )
        let target = target()
        let decision = LocalModelQualificationGate.evaluate(
            descriptor: descriptor,
            device: device,
            compatibility: compatibility,
            benchmark: benchmark,
            target: target,
            receipt: receipt(target: target)
        )

        XCTAssertEqual(compatibility.label, .untested)
        XCTAssertFalse(decision.isCompatibilityBadgeEligible)
        XCTAssertEqual(decision.reasons, [.compatibilityNotMeasured])
    }

    func testMissingMeasuredPeakMemoryCannotQualify() {
        let benchmark = benchmark(peakMemoryBytes: nil)
        let decision = qualify(
            benchmark: benchmark,
            receipt: receipt(target: target(), peakMemoryBytes: 4_000)
        )

        XCTAssertFalse(decision.isCompatibilityBadgeEligible)
        XCTAssertEqual(decision.reasons, [.measuredMemoryMissing])
        XCTAssertTrue(decision.evidence.contains { $0.code == "qualification.measured_memory_missing" })
    }

    func testReceiptMemoryAndGenerationRateMustMatchBenchmark() {
        let memoryMismatch = qualify(
            receipt: receipt(target: target(), peakMemoryBytes: 4_001)
        )
        XCTAssertFalse(memoryMismatch.isCompatibilityBadgeEligible)
        XCTAssertEqual(memoryMismatch.reasons, [.measuredMemoryMismatch])

        let rateMismatch = qualify(
            receipt: receipt(target: target(), generationTokensPerSecond: 8.26)
        )
        XCTAssertFalse(rateMismatch.isCompatibilityBadgeEligible)
        XCTAssertEqual(rateMismatch.reasons, [.measuredRateMismatch])
    }

    func testTaskSuiteFailureBlocksBadgePromotionEvenWhenSpeedIsExcellent() {
        let decision = qualify(
            receipt: receipt(
                target: target(),
                successfulTasks: 7,
                failedTasks: 1
            )
        )

        XCTAssertFalse(decision.isCompatibilityBadgeEligible)
        XCTAssertEqual(decision.reasons, [.taskSuiteInsufficient])
        XCTAssertTrue(decision.evidence.contains { $0.code == "qualification.task_suite_insufficient" })
    }

    func testQualificationReceiptRoundTripsWithoutLosingExactIdentity() throws {
        let original = receipt(target: target())
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LocalModelQualificationReceipt.self, from: encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.target.environment, .physicalDevice)
        XCTAssertEqual(decoded.target.deviceModel, "iPhone13,2")
        XCTAssertEqual(decoded.target.runtimeRevision, "llama.cpp-main@abc123")
        XCTAssertEqual(decoded.target.kvCacheType, "q8_0")
        XCTAssertEqual(decoded.observation.taskSuite.suiteRevision, "v14.1")
    }

    private func qualify(
        benchmark: LocalModelBenchmarkObservation? = nil,
        target: LocalModelQualificationTarget? = nil,
        receipt: LocalModelQualificationReceipt? = nil
    ) -> LocalModelQualificationDecision {
        let descriptor = descriptor()
        let device = device()
        let resolvedBenchmark = benchmark ?? self.benchmark()
        let resolvedTarget = target ?? self.target()
        let compatibility = LocalModelCompatibilityEvaluator.evaluate(
            descriptor: descriptor,
            device: device,
            benchmark: resolvedBenchmark
        )

        return LocalModelQualificationGate.evaluate(
            descriptor: descriptor,
            device: device,
            compatibility: compatibility,
            benchmark: resolvedBenchmark,
            target: resolvedTarget,
            receipt: receipt ?? self.receipt(target: resolvedTarget)
        )
    }

    private func descriptor() -> LocalModelCatalogDescriptor {
        LocalModelCatalogDescriptor(
            modelID: "example/code-model",
            revision: "rev-2",
            artifactID: "artifact-q4",
            artifactSHA256: artifactSHA256,
            format: "gguf",
            architecture: "llama",
            quantization: "Q4_K_M",
            contextWindowTokens: 32_768,
            fileSizeBytes: 4_000,
            estimatedPeakMemory: .init(
                peakBytes: 5_000,
                provenance: .sourceReported
            ),
            toolCalling: .supported,
            structuredOutput: .supported,
            source: "fixture-catalog",
            license: "test-license"
        )
    }

    private func device() -> LocalModelDeviceProfile {
        LocalModelDeviceProfile(
            profileID: "iphone12-test-profile",
            supportedArchitectures: ["llama"],
            availableStorageBytes: 10_000,
            memoryBudgetBytes: 8_000
        )
    }

    private func benchmark(
        generationRateProvenance: LocalModelGenerationRateProvenance = .measuredTokenCount,
        peakMemoryBytes: UInt64? = 4_000
    ) -> LocalModelBenchmarkObservation {
        LocalModelBenchmarkObservation(
            modelID: "example/code-model",
            revision: "rev-2",
            artifactID: "artifact-q4",
            artifactSHA256: artifactSHA256,
            quantization: "Q4_K_M",
            deviceProfileID: "iphone12-test-profile",
            measuredAt: measuredAt,
            generationTokensPerSecond: 8.25,
            generationRateProvenance: generationRateProvenance,
            successfulSmokeRuns: 3,
            failedSmokeRuns: 0,
            peakMemoryBytes: peakMemoryBytes
        )
    }

    private func target(
        runtimeRevision: String = "llama.cpp-main@abc123",
        tokenizerRevision: String = "tokenizer-rev-2",
        environment: LocalModelQualificationEnvironment = .physicalDevice
    ) -> LocalModelQualificationTarget {
        LocalModelQualificationTarget(
            deviceProfileID: "iphone12-test-profile",
            deviceModel: "iPhone13,2",
            osVersion: "iOS 27.0",
            osBuild: "24A000-test",
            runtimeID: "llama.cpp-metal",
            runtimeRevision: runtimeRevision,
            tokenizerID: "example/tokenizer",
            tokenizerRevision: tokenizerRevision,
            kvCacheType: "q8_0",
            contextTokens: 16_384,
            environment: environment
        )
    }

    private func receipt(
        target: LocalModelQualificationTarget,
        peakMemoryBytes: UInt64 = 4_000,
        generationTokensPerSecond: Double = 8.25,
        successfulTasks: UInt16 = 8,
        failedTasks: UInt16 = 0
    ) -> LocalModelQualificationReceipt {
        LocalModelQualificationReceipt(
            modelID: "example/code-model",
            revision: "rev-2",
            artifactID: "artifact-q4",
            artifactSHA256: artifactSHA256,
            quantization: "Q4_K_M",
            target: target,
            measuredAt: measuredAt,
            observation: .init(
                peakMemoryBytes: peakMemoryBytes,
                memoryPressureEvents: 0,
                thermalStateAtStart: "nominal",
                thermalStateAtEnd: "fair",
                timeToFirstTokenMilliseconds: 780,
                prefillTokensPerSecond: 42.5,
                generationTokensPerSecond: generationTokensPerSecond,
                taskSuite: .init(
                    suiteID: "novaforge-local-agent",
                    suiteRevision: "v14.1",
                    successfulTasks: successfulTasks,
                    failedTasks: failedTasks
                )
            )
        )
    }
}

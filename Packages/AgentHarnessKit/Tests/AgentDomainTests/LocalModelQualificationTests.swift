import XCTest
@testable import AgentDomain

final class LocalModelQualificationTests: XCTestCase {
    private let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let instant = AgentInstant(rawValue: 1_786_000_000_000)

    func testExactPhysicalDeviceReceiptMintsBoundBadge() throws {
        let decision = qualify()

        XCTAssertTrue(decision.isQualified)
        XCTAssertEqual(decision.blockers, [])
        XCTAssertEqual(decision.badge?.label, .excellent)
        XCTAssertEqual(decision.badge?.identity.runtimeRevision, "llama.cpp-deadbeef")
        XCTAssertEqual(decision.badge?.identity.kvCacheType, "q8_0")
        XCTAssertEqual(decision.badge?.identity.contextTokens, 16_384)
        XCTAssertEqual(decision.badge?.identity.hardwareIdentifier, "iPhone13,2")
        XCTAssertEqual(decision.badge?.taskSuite.suiteRevision, "forge-agent-v14.1")
        XCTAssertEqual(decision.badge?.networkIsolationAudit, .passed)

        let data = try JSONEncoder().encode(decision)
        XCTAssertEqual(
            try JSONDecoder().decode(LocalModelQualificationDecision.self, from: data),
            decision
        )
    }

    func testSimulatorEvidenceCannotMintPhysicalDeviceBadge() {
        let decision = qualify(
            receipt: receipt(identity: identity(environment: .simulator))
        )

        XCTAssertFalse(decision.isQualified)
        XCTAssertNil(decision.badge)
        XCTAssertEqual(decision.blockers, [.physicalDeviceEvidenceRequired])
    }

    func testIncompleteTokenizerOrRuntimeIdentityFailsClosed() {
        let incomplete = LocalModelQualificationIdentity(
            tokenizerID: "tokenizer",
            tokenizerRevision: "",
            runtimeID: "llama.cpp",
            runtimeRevision: "llama.cpp-deadbeef",
            kvCacheType: "q8_0",
            contextTokens: 16_384,
            hardwareIdentifier: "iPhone13,2",
            osVersion: "27.0",
            osBuild: "24A000",
            environment: .physicalDevice
        )

        let decision = qualify(receipt: receipt(identity: incomplete))

        XCTAssertFalse(decision.isQualified)
        XCTAssertEqual(decision.blockers, [.executionIdentityIncomplete])
    }

    func testBenchmarkMetricMismatchCannotBorrowAQualificationReceipt() {
        let decision = qualify(
            benchmark: benchmark(generationTokensPerSecond: 7.75),
            receipt: receipt(generationTokensPerSecond: 8.25)
        )

        XCTAssertFalse(decision.isQualified)
        XCTAssertEqual(decision.blockers, [.benchmarkMetricsMismatch])
    }

    func testMissingMeasuredPeakMemoryCannotMintBadge() {
        let decision = qualify(
            benchmark: benchmark(peakMemoryBytes: nil)
        )

        XCTAssertFalse(decision.isQualified)
        XCTAssertEqual(decision.blockers, [.peakMemoryMissing])
    }

    func testReceiptCannotClaimContextBeyondCatalogQualification() {
        let decision = qualify(
            descriptor: descriptor(contextWindowTokens: 8_192),
            receipt: receipt(identity: identity(contextTokens: 16_384))
        )

        XCTAssertFalse(decision.isQualified)
        XCTAssertEqual(decision.blockers, [.contextNotQualified])
    }

    func testReceiptMustMeetMissionContextRequirement() {
        let decision = qualify(
            requirements: .init(minimumContextTokens: 32_768)
        )

        XCTAssertFalse(decision.isQualified)
        XCTAssertEqual(decision.blockers, [.contextNotQualified])
    }

    func testTaskSuiteFailureBlocksFriendlyCompatibilityBadge() {
        let decision = qualify(
            receipt: receipt(
                taskSuite: .init(
                    suiteID: "novaforge-forge-agent",
                    suiteRevision: "forge-agent-v14.1",
                    successfulCases: 23,
                    failedCases: 1
                )
            )
        )

        XCTAssertFalse(decision.isQualified)
        XCTAssertEqual(decision.blockers, [.taskSuiteFailed])
    }

    func testMissingTaskSuiteIdentityOrCasesFailsClosed() {
        let decision = qualify(
            receipt: receipt(
                taskSuite: .init(
                    suiteID: "",
                    suiteRevision: "",
                    successfulCases: 0,
                    failedCases: 0
                )
            )
        )

        XCTAssertFalse(decision.isQualified)
        XCTAssertEqual(decision.blockers, [.taskSuiteMissing])
    }

    func testLocalOnlyNetworkAuditMustActuallyPass() {
        let decision = qualify(
            receipt: receipt(networkIsolationAudit: .notRun)
        )

        XCTAssertFalse(decision.isQualified)
        XCTAssertEqual(decision.blockers, [.networkIsolationUnverified])
    }

    func testUnknownThermalStateDoesNotCountAsThermalEvidence() {
        let decision = qualify(
            receipt: receipt(peakThermalState: .unknown)
        )

        XCTAssertFalse(decision.isQualified)
        XCTAssertEqual(decision.blockers, [.thermalEvidenceMissing])
    }

    func testRawUntestedCompatibilityCannotBeUpgradedByStrongReceipt() {
        let compatibility = LocalModelCompatibilityResult(
            label: .untested,
            reasons: [.benchmarkMissing],
            evidence: [
                .init(
                    kind: .measured,
                    code: "benchmark.exact_device_smoke",
                    detail: "fixture",
                    observedAt: instant
                )
            ]
        )

        let decision = qualify(compatibility: compatibility)

        XCTAssertFalse(decision.isQualified)
        XCTAssertEqual(decision.blockers, [.compatibilityNotMeasured])
    }

    func testReceiptForDifferentArtifactCannotBeReused() {
        let mismatched = LocalModelQualificationReceipt(
            modelID: "example/code-model",
            revision: "rev-2",
            artifactID: "artifact-q4",
            artifactSHA256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            quantization: "Q4_K_M",
            deviceProfileID: "iphone12-test-profile",
            measuredAt: instant,
            identity: identity(),
            peakMemoryBytes: 4_000,
            generationTokensPerSecond: 8.25,
            peakThermalState: .fair,
            taskSuite: taskSuite(),
            networkIsolationAudit: .passed
        )

        let decision = qualify(receipt: mismatched)

        XCTAssertFalse(decision.isQualified)
        XCTAssertEqual(decision.blockers, [.benchmarkIdentityMismatch])
    }

    private func qualify(
        compatibility: LocalModelCompatibilityResult? = nil,
        descriptor: LocalModelCatalogDescriptor? = nil,
        device: LocalModelDeviceProfile? = nil,
        requirements: LocalModelMissionRequirements = .init(),
        benchmark: LocalModelBenchmarkObservation? = nil,
        receipt: LocalModelQualificationReceipt? = nil
    ) -> LocalModelQualificationDecision {
        LocalModelQualificationGate.qualify(
            compatibility: compatibility ?? measuredCompatibility(),
            descriptor: descriptor ?? self.descriptor(),
            device: device ?? self.device(),
            requirements: requirements,
            benchmark: benchmark ?? self.benchmark(),
            receipt: receipt ?? self.receipt()
        )
    }

    private func measuredCompatibility() -> LocalModelCompatibilityResult {
        LocalModelCompatibilityResult(
            label: .excellent,
            reasons: [.measuredPerformance],
            evidence: [
                .init(
                    kind: .measured,
                    code: "benchmark.exact_device_smoke",
                    detail: "fixture",
                    observedAt: instant
                ),
                .init(
                    kind: .measured,
                    code: "benchmark.generation_rate",
                    detail: "fixture",
                    observedAt: instant
                ),
            ]
        )
    }

    private func descriptor(
        contextWindowTokens: UInt64? = 32_768
    ) -> LocalModelCatalogDescriptor {
        LocalModelCatalogDescriptor(
            modelID: "example/code-model",
            revision: "rev-2",
            artifactID: "artifact-q4",
            artifactSHA256: sha,
            format: "gguf",
            architecture: "llama",
            quantization: "Q4_K_M",
            contextWindowTokens: contextWindowTokens,
            fileSizeBytes: 4_000,
            estimatedPeakMemory: LocalModelMemoryEstimate(
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
        generationTokensPerSecond: Double = 8.25,
        peakMemoryBytes: UInt64? = 4_000
    ) -> LocalModelBenchmarkObservation {
        LocalModelBenchmarkObservation(
            modelID: "example/code-model",
            revision: "rev-2",
            artifactID: "artifact-q4",
            artifactSHA256: sha,
            quantization: "Q4_K_M",
            deviceProfileID: "iphone12-test-profile",
            measuredAt: instant,
            generationTokensPerSecond: generationTokensPerSecond,
            generationRateProvenance: .measuredTokenCount,
            successfulSmokeRuns: 3,
            failedSmokeRuns: 0,
            peakMemoryBytes: peakMemoryBytes
        )
    }

    private func identity(
        contextTokens: UInt64 = 16_384,
        environment: LocalModelQualificationEnvironment = .physicalDevice
    ) -> LocalModelQualificationIdentity {
        LocalModelQualificationIdentity(
            tokenizerID: "example/tokenizer",
            tokenizerRevision: "tokenizer-rev-4",
            runtimeID: "llama.cpp",
            runtimeRevision: "llama.cpp-deadbeef",
            kvCacheType: "q8_0",
            contextTokens: contextTokens,
            hardwareIdentifier: "iPhone13,2",
            osVersion: "27.0",
            osBuild: "24A000",
            environment: environment
        )
    }

    private func taskSuite() -> LocalModelTaskSuiteObservation {
        .init(
            suiteID: "novaforge-forge-agent",
            suiteRevision: "forge-agent-v14.1",
            successfulCases: 24,
            failedCases: 0
        )
    }

    private func receipt(
        identity: LocalModelQualificationIdentity? = nil,
        generationTokensPerSecond: Double = 8.25,
        peakThermalState: LocalModelQualificationThermalState = .fair,
        taskSuite: LocalModelTaskSuiteObservation? = nil,
        networkIsolationAudit: LocalModelNetworkIsolationAuditStatus = .passed
    ) -> LocalModelQualificationReceipt {
        LocalModelQualificationReceipt(
            modelID: "example/code-model",
            revision: "rev-2",
            artifactID: "artifact-q4",
            artifactSHA256: sha,
            quantization: "Q4_K_M",
            deviceProfileID: "iphone12-test-profile",
            measuredAt: instant,
            identity: identity ?? self.identity(),
            peakMemoryBytes: 4_000,
            generationTokensPerSecond: generationTokensPerSecond,
            peakThermalState: peakThermalState,
            taskSuite: taskSuite ?? self.taskSuite(),
            networkIsolationAudit: networkIsolationAudit
        )
    }
}

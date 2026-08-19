import XCTest
import AgentDomain
import LocalModelQualificationCore
@testable import LocalModelFabricCore

final class LocalModelFabricCoreTests: XCTestCase {
    private let shaA = String(repeating: "a", count: 64)
    private let shaB = String(repeating: "b", count: 64)

    func testMissionPrefersFirstQualifiedTier() throws {
        let instant = try candidate(model: "instant", sha: shaA, tier: .instant)
        let core = try candidate(model: "core", sha: shaB, tier: .core)
        let decision = selectWithTrustedQualification(
            candidates: [core, instant],
            request: try request(preferredTiers: [.instant, .core])
        )

        XCTAssertEqual(decision.selection?.subject.artifact.modelID, "instant")
        XCTAssertEqual(decision.selection?.basis, .canonicalDeviceQualification)
        XCTAssertEqual(decision.selection?.qualificationClaim, .deviceRuntimeQualified)
    }

    func testLegacyUntestedPreflightDoesNotBlockCanonicalQualifiedMission() throws {
        let qualified = try candidate(model: "qualified", sha: shaA, tier: .core, includeLegacyBenchmark: false)
        let decision = selectWithTrustedQualification(
            candidates: [qualified],
            request: try request(preferredTiers: [.core])
        )

        XCTAssertNotNil(decision.selection)
        XCTAssertTrue(decision.rejections.isEmpty)
    }

    func testPublicMissionWithoutOpaqueQualificationEvidenceFailsClosed() throws {
        let untrusted = try candidate(model: "untrusted", sha: shaA, tier: .core)
        let decision = LocalModelFabricSelector.select(
            candidates: [untrusted],
            request: try request(preferredTiers: [.core])
        )

        XCTAssertNil(decision.selection)
        XCTAssertTrue(decision.rejections[0].reasons.contains(.canonicalQualificationRejected))
        XCTAssertFalse(decision.rejections[0].canonicalBlockingReasons.isEmpty)
    }

    func testSimulatorCandidateCannotSelfAuthorizeMission() throws {
        let simulatorDevice = try device(environment: .simulator, hardwareIdentifier: "iPhone13,2-sim")
        let simulator = try candidate(
            model: "sim",
            sha: shaA,
            tier: .core,
            exactDevice: simulatorDevice
        )
        let decision = LocalModelFabricSelector.select(
            candidates: [simulator],
            request: try request(preferredTiers: [.core], currentDevice: simulatorDevice)
        )

        XCTAssertNil(decision.selection)
        XCTAssertTrue(decision.rejections[0].reasons.contains(.canonicalQualificationRejected))
    }

    func testLocalOnlyMissionWithoutOpaqueQualificationEvidenceFailsClosed() throws {
        let noAudit = try candidate(model: "local", sha: shaA, tier: .core, includeLocalOnlyAudit: false)
        let decision = LocalModelFabricSelector.select(
            candidates: [noAudit],
            request: try request(preferredTiers: [.core], privacy: .localOnly)
        )

        XCTAssertNil(decision.selection)
        XCTAssertTrue(decision.rejections[0].reasons.contains(.canonicalQualificationRejected))
        XCTAssertFalse(decision.rejections[0].canonicalBlockingReasons.isEmpty)
    }

    func testRoleSuiteRevisionAndPassThresholdFailClosed() throws {
        let oldSuite = try candidate(
            model: "old-suite",
            sha: shaA,
            tier: .core,
            suiteRevision: "old",
            attempted: 10,
            passed: 6
        )
        let decision = selectWithTrustedQualification(
            candidates: [oldSuite],
            request: try request(preferredTiers: [.core], minimumPassRate: 0.8)
        )

        XCTAssertNil(decision.selection)
        let reasons = decision.rejections[0].reasons
        XCTAssertTrue(reasons.contains(.taskSuiteMismatch))
        XCTAssertTrue(reasons.contains(.taskSuccessBelowThreshold))
    }

    func testPassedPayloadStillFailsRoutingResourcePolicyWhenPressureAndThermalAreUnsafe() throws {
        let unsafe = try candidate(
            model: "unsafe",
            sha: shaA,
            tier: .core,
            memoryPressure: .critical,
            thermal: .serious
        )
        let decision = selectWithTrustedQualification(
            candidates: [unsafe],
            request: try request(
                preferredTiers: [.core],
                maximumMemoryPressure: .warning,
                maximumThermal: .fair
            )
        )

        XCTAssertNil(decision.selection)
        let reasons = decision.rejections[0].reasons
        XCTAssertTrue(reasons.contains(.measuredMemoryPressureExceeded))
        XCTAssertTrue(reasons.contains(.measuredThermalExceeded))
    }

    func testExactOSBuildDriftCannotReuseQualification() throws {
        let oldDevice = try device(osBuild: "24A-old")
        let stale = try candidate(model: "stale", sha: shaA, tier: .core, exactDevice: oldDevice)
        let decision = selectWithTrustedQualification(
            candidates: [stale],
            request: try request(preferredTiers: [.core], currentDevice: try device())
        )

        XCTAssertNil(decision.selection)
        XCTAssertTrue(decision.rejections[0].reasons.contains(.exactDeviceMismatch))
    }

    func testQualificationProbeCanSelectProfileWithoutQualificationRecord() throws {
        let probe = try candidate(
            model: "probe",
            sha: shaA,
            tier: .instant,
            includeRecord: false
        )
        let decision = LocalModelFabricSelector.select(
            candidates: [probe],
            request: try request(preferredTiers: [.instant], mode: .qualificationProbe)
        )

        XCTAssertNotNil(decision.selection)
        XCTAssertEqual(decision.selection?.basis, .qualificationProbePreflight)
        XCTAssertNil(decision.selection?.qualificationClaim)
        XCTAssertNil(decision.selection?.qualificationRecordRevision)
    }

    func testExperimentalBeyondRAMRequiresExplicitOptIn() throws {
        let experimental = try candidate(model: "experimental", sha: shaA, tier: .experimentalBeyondRAM)
        let denied = selectWithTrustedQualification(
            candidates: [experimental],
            request: try request(preferredTiers: [.experimentalBeyondRAM], allowExperimental: false)
        )
        XCTAssertNil(denied.selection)
        XCTAssertTrue(denied.rejections[0].reasons.contains(.experimentalOptInRequired))

        let allowed = selectWithTrustedQualification(
            candidates: [experimental],
            request: try request(preferredTiers: [.experimentalBeyondRAM], allowExperimental: true)
        )
        XCTAssertNotNil(allowed.selection)
    }

    func testCanonicalSubjectTieBreakIsStableAcrossInputOrderAndTokenizerRevision() throws {
        let alpha = try candidate(model: "same", sha: shaA, tier: .core, tokenizerRevision: "alpha")
        let beta = try candidate(model: "same", sha: shaA, tier: .core, tokenizerRevision: "beta")
        let request = try request(preferredTiers: [.core])

        let forward = selectWithTrustedQualification(candidates: [alpha, beta], request: request)
        let reversed = selectWithTrustedQualification(candidates: [beta, alpha], request: request)

        XCTAssertEqual(
            forward.selection?.subject.artifact.tokenizerRevision,
            reversed.selection?.subject.artifact.tokenizerRevision
        )
    }

    func testWithinTierPrefersTaskSuccessBeforeSpeed() throws {
        let reliable = try candidate(
            model: "reliable",
            sha: shaA,
            tier: .core,
            attempted: 10,
            passed: 10,
            ttft: 200,
            decode: 8
        )
        let faster = try candidate(
            model: "faster",
            sha: shaB,
            tier: .core,
            attempted: 10,
            passed: 9,
            ttft: 50,
            decode: 30
        )
        let decision = selectWithTrustedQualification(
            candidates: [faster, reliable],
            request: try request(preferredTiers: [.core], minimumPassRate: 0.8)
        )

        XCTAssertEqual(decision.selection?.subject.artifact.modelID, "reliable")
    }

    private func descriptor(model: String, sha: String) -> LocalModelCatalogDescriptor {
        .init(
            modelID: model,
            revision: "model-r1",
            artifactID: "artifact-\(model)",
            artifactSHA256: sha,
            format: "gguf",
            architecture: "test-arch",
            quantization: "Q4_K_M",
            contextWindowTokens: 8_192,
            fileSizeBytes: 200,
            estimatedPeakMemory: .init(peakBytes: 1_000, provenance: .sourceReported),
            toolCalling: .supported,
            structuredOutput: .supported,
            source: "fixture"
        )
    }

    private func deviceProfile() -> LocalModelDeviceProfile {
        .init(
            profileID: "iphone12-ios27",
            supportedArchitectures: ["test-arch"],
            availableStorageBytes: 10_000,
            memoryBudgetBytes: 5_000
        )
    }

    private func device(
        environment: LocalExecutionEnvironment = .physicalDevice,
        hardwareIdentifier: String = "iPhone13,2",
        osBuild: String = "24A-current"
    ) throws -> LocalDeviceIdentity {
        try .init(
            environment: environment,
            hardwareIdentifier: hardwareIdentifier,
            marketingName: "iPhone 12",
            chip: "A14",
            osVersion: "27.0",
            osBuild: osBuild
        )
    }

    private func subject(
        model: String,
        sha: String,
        tokenizerRevision: String,
        exactDevice: LocalDeviceIdentity
    ) throws -> LocalModelQualificationSubject {
        try .init(
            artifact: .init(
                modelID: model,
                modelRevision: "model-r1",
                tokenizerID: "fixture-tokenizer",
                tokenizerRevision: tokenizerRevision,
                artifactSHA256: sha
            ),
            runtime: .init(
                runtimeID: "llama.cpp",
                runtimeRevision: "runtime-r1",
                backend: "metal"
            ),
            execution: .init(
                quantization: "Q4_K_M",
                keyCacheType: "q8_0",
                valueCacheType: "q8_0",
                contextTokens: 4_096,
                batchTokens: 256
            ),
            device: exactDevice
        )
    }

    private func measurement(
        peakResident: UInt64,
        memoryPressure: LocalModelMemoryPressure,
        ttft: Double,
        decode: Double
    ) throws -> LocalModelPerformanceMeasurement {
        try .init(
            promptTokens: 128,
            generatedTokens: 64,
            timeToFirstTokenMilliseconds: ttft,
            prefillTokensPerSecond: 25,
            decodeTokensPerSecond: decode,
            peakResidentBytes: peakResident,
            peakKVCacheBytes: 100,
            energyJoules: 1,
            peakMemoryPressure: memoryPressure
        )
    }

    private func evidence(
        subject: LocalModelQualificationSubject,
        suiteRevision: String,
        attempted: Int,
        passed: Int,
        peakResident: UInt64,
        memoryPressure: LocalModelMemoryPressure,
        thermal: LocalModelThermalState,
        ttft: Double,
        decode: Double,
        includeLocalOnlyAudit: Bool
    ) throws -> [LocalModelQualificationEvidence] {
        let performance = try measurement(
            peakResident: peakResident,
            memoryPressure: memoryPressure,
            ttft: ttft,
            decode: decode
        )
        var items: [LocalModelQualificationEvidence] = [
            try .init(
                evidenceID: "artifact",
                subject: subject,
                evidenceClass: .artifactIntegrity,
                source: .staticAnalysis,
                authority: .deterministicHarness,
                status: .passed,
                payload: .none
            ),
            try .init(
                evidenceID: "load",
                subject: subject,
                evidenceClass: .modelLoad,
                source: subject.device.environment == .physicalDevice ? .physicalDevice : .simulator,
                authority: .deterministicHarness,
                status: .passed,
                payload: .none
            ),
            try .init(
                evidenceID: "first-token",
                subject: subject,
                evidenceClass: .firstToken,
                source: subject.device.environment == .physicalDevice ? .physicalDevice : .simulator,
                authority: .deterministicHarness,
                status: .passed,
                payload: .performance(performance)
            ),
            try .init(
                evidenceID: "throughput",
                subject: subject,
                evidenceClass: .throughput,
                source: subject.device.environment == .physicalDevice ? .physicalDevice : .simulator,
                authority: .deterministicHarness,
                status: .passed,
                payload: .performance(performance)
            ),
            try .init(
                evidenceID: "memory",
                subject: subject,
                evidenceClass: .memory,
                source: subject.device.environment == .physicalDevice ? .physicalDevice : .simulator,
                authority: .deterministicHarness,
                status: .passed,
                payload: .performance(performance)
            ),
            try .init(
                evidenceID: "thermal",
                subject: subject,
                evidenceClass: .thermal,
                source: subject.device.environment == .physicalDevice ? .physicalDevice : .simulator,
                authority: .deterministicHarness,
                status: .passed,
                payload: .thermal(thermal)
            ),
            try .init(
                evidenceID: "task-suite",
                subject: subject,
                evidenceClass: .taskSuite,
                source: subject.device.environment == .physicalDevice ? .physicalDevice : .simulator,
                authority: .deterministicHarness,
                status: .passed,
                payload: .taskSuite(
                    try .init(
                        suiteID: "forge-tools",
                        suiteRevision: suiteRevision,
                        attempted: attempted,
                        passed: passed
                    )
                )
            ),
        ]
        if includeLocalOnlyAudit {
            items.append(
                try .init(
                    evidenceID: "local-only",
                    subject: subject,
                    evidenceClass: .localOnlyNetworkAudit,
                    source: subject.device.environment == .physicalDevice ? .physicalDevice : .simulator,
                    authority: .deterministicHarness,
                    status: .passed,
                    payload: .localOnlyAudit(receiptID: "network-audit")
                )
            )
        }
        return items
    }

    private func benchmark(
        descriptor: LocalModelCatalogDescriptor,
        device: LocalModelDeviceProfile
    ) -> LocalModelBenchmarkObservation {
        .init(
            modelID: descriptor.modelID,
            revision: descriptor.revision,
            artifactID: descriptor.artifactID,
            artifactSHA256: descriptor.artifactSHA256,
            quantization: descriptor.quantization,
            deviceProfileID: device.profileID,
            measuredAt: .init(rawValue: 1_000),
            generationTokensPerSecond: 10,
            generationRateProvenance: .measuredTokenCount,
            successfulSmokeRuns: 2,
            failedSmokeRuns: 0,
            peakMemoryBytes: 1_000
        )
    }

    private func candidate(
        model: String,
        sha: String,
        tier: LocalModelFabricTier,
        tokenizerRevision: String = "tokenizer-r1",
        exactDevice: LocalDeviceIdentity? = nil,
        suiteRevision: String = "suite-r1",
        attempted: Int = 10,
        passed: Int = 10,
        peakResident: UInt64 = 900,
        memoryPressure: LocalModelMemoryPressure = .nominal,
        thermal: LocalModelThermalState = .nominal,
        ttft: Double = 100,
        decode: Double = 10,
        includeLocalOnlyAudit: Bool = true,
        includeLegacyBenchmark: Bool = false,
        includeRecord: Bool = true
    ) throws -> LocalModelFabricCandidate {
        let descriptor = descriptor(model: model, sha: sha)
        let deviceProfile = deviceProfile()
        let subject = try subject(
            model: model,
            sha: sha,
            tokenizerRevision: tokenizerRevision,
            exactDevice: exactDevice ?? device()
        )
        let items = try evidence(
            subject: subject,
            suiteRevision: suiteRevision,
            attempted: attempted,
            passed: passed,
            peakResident: peakResident,
            memoryPressure: memoryPressure,
            thermal: thermal,
            ttft: ttft,
            decode: decode,
            includeLocalOnlyAudit: includeLocalOnlyAudit
        )
        let record = includeRecord ? try LocalModelQualificationRecord(revision: 1, subject: subject, evidence: items) : nil
        return try .init(
            tier: tier,
            descriptor: descriptor,
            deviceProfile: deviceProfile,
            legacyBenchmark: includeLegacyBenchmark ? benchmark(descriptor: descriptor, device: deviceProfile) : nil,
            subject: subject,
            qualificationRecord: record,
            trustedReceipts: []
        )
    }

    private func selectWithTrustedQualification(
        candidates: [LocalModelFabricCandidate],
        request: LocalModelFabricRequest
    ) -> LocalModelFabricSelectionDecision {
        LocalModelFabricSelector.selectForTesting(
            candidates: candidates,
            request: request
        ) { _, _, _ in
            (isQualified: true, blockingReasons: [])
        }
    }

    private func request(
        preferredTiers: [LocalModelFabricTier],
        mode: LocalModelFabricSelectionMode = .mission,
        privacy: LocalModelFabricPrivacyRequirement = .localExecution,
        currentDevice: LocalDeviceIdentity? = nil,
        allowExperimental: Bool = false,
        minimumPassRate: Double = 1,
        maximumMemoryPressure: LocalModelMemoryPressure = .warning,
        maximumThermal: LocalModelThermalState = .fair
    ) throws -> LocalModelFabricRequest {
        try .init(
            role: .toolAgent,
            mode: mode,
            privacy: privacy,
            currentDevice: currentDevice ?? device(),
            deviceProfileID: "iphone12-ios27",
            requirements: .init(
                requiresToolCalling: true,
                requiresStructuredOutput: true,
                minimumContextTokens: 2_048
            ),
            taskSuiteID: "forge-tools",
            taskSuiteRevision: "suite-r1",
            policy: .init(
                policyID: "fabric-routing",
                revision: "v1",
                preferredTiers: preferredTiers,
                allowExperimentalBeyondRAM: allowExperimental,
                minimumTaskAttempts: 2,
                minimumTaskPassRate: minimumPassRate,
                maximumPeakResidentBytes: 2_000,
                maximumMemoryPressure: maximumMemoryPressure,
                maximumThermalState: maximumThermal
            )
        )
    }
}

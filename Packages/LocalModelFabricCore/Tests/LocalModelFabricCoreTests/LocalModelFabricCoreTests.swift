import Foundation
import XCTest
import AgentDomain
@testable import LocalModelFabricCore

final class LocalModelFabricCoreTests: XCTestCase {
    private let shaA = String(repeating: "a", count: 64)
    private let shaB = String(repeating: "b", count: 64)

    func testMissionSelectsFirstPreferredTierWithExactMeasuredRoleEvidence() throws {
        let core = try candidate(model: "core", sha: shaA, tier: .core, success: 10, failed: 0, peakMemory: 900)
        let instant = try candidate(model: "instant", sha: shaB, tier: .instant, success: 8, failed: 0, peakMemory: 400)
        let request = try request(preferred: [.instant, .core])

        let decision = LocalModelFabricSelector.select(candidates: [core, instant], request: request)
        XCTAssertEqual(decision.selection?.runtimeIdentity.modelID, "instant")
        XCTAssertEqual(decision.selection?.basis, .measuredRoleQualification)
        XCTAssertEqual(decision.selection?.qualificationSuiteID, "forge-tools")
    }

    func testWithinTierPrefersHigherTaskSuccessBeforeSpeed() throws {
        let perfect = try candidate(model: "perfect", sha: shaA, tier: .core, success: 9, failed: 0, peakMemory: 900, ttft: 200)
        let fasterButWorse = try candidate(model: "faster", sha: shaB, tier: .core, success: 8, failed: 1, peakMemory: 700, ttft: 50)
        let request = try request(preferred: [.core], minimumTaskSuccessRate: 0.8)

        let decision = LocalModelFabricSelector.select(candidates: [fasterButWorse, perfect], request: request)
        XCTAssertEqual(decision.selection?.runtimeIdentity.modelID, "perfect")
    }

    func testUntestedCandidateCannotRunMissionButCanBeChosenForQualificationProbe() throws {
        let candidate = try self.candidate(model: "new", sha: shaA, tier: .instant, includeBenchmark: false, includeQualification: false)
        let mission = try request(preferred: [.instant])
        let missionDecision = LocalModelFabricSelector.select(candidates: [candidate], request: mission)
        XCTAssertNil(missionDecision.selection)
        XCTAssertTrue(missionDecision.rejections[0].reasons.contains(.measuredCompatibilityRequired))

        let probe = try request(preferred: [.instant], mode: .qualificationProbe)
        let probeDecision = LocalModelFabricSelector.select(candidates: [candidate], request: probe)
        XCTAssertEqual(probeDecision.selection?.runtimeIdentity.modelID, "new")
        XCTAssertEqual(probeDecision.selection?.basis, .qualificationProbePreflight)
        XCTAssertNil(probeDecision.selection?.qualificationMeasuredAt)
    }

    func testExperimentalBeyondRAMRequiresExplicitOptIn() throws {
        let experimental = try candidate(model: "experimental", sha: shaA, tier: .experimentalBeyondRAM)
        let denied = try request(preferred: [.experimentalBeyondRAM], allowExperimental: false)
        let deniedDecision = LocalModelFabricSelector.select(candidates: [experimental], request: denied)
        XCTAssertNil(deniedDecision.selection)
        XCTAssertTrue(deniedDecision.rejections[0].reasons.contains(.experimentalOptInRequired))

        let allowed = try request(preferred: [.experimentalBeyondRAM], allowExperimental: true)
        let allowedDecision = LocalModelFabricSelector.select(candidates: [experimental], request: allowed)
        XCTAssertNotNil(allowedDecision.selection)
    }

    func testWrongRuntimeRevisionQualificationCannotAuthorizeMission() throws {
        let descriptor = descriptor(model: "model", sha: shaA)
        let device = deviceProfile()
        let runtime = try runtimeIdentity(descriptor: descriptor)
        let otherRuntime = try LocalModelRuntimeIdentity(
            descriptor: descriptor,
            tokenizerID: "tok",
            tokenizerRevision: "tok-r1",
            runtimeID: "llama.cpp",
            runtimeRevision: "other-runtime",
            kvCacheType: "q8_0",
            contextTokens: 4096,
            deviceProfileID: device.profileID,
            osBuild: "iOS-27-build"
        )
        let qualification = try qualification(identity: otherRuntime)
        let candidate = try LocalModelFabricCandidate(
            tier: .core,
            descriptor: descriptor,
            device: device,
            benchmark: benchmark(descriptor: descriptor, device: device),
            runtimeIdentity: runtime,
            qualifications: [qualification]
        )

        let decision = LocalModelFabricSelector.select(candidates: [candidate], request: try request(preferred: [.core]))
        XCTAssertNil(decision.selection)
        XCTAssertTrue(decision.rejections[0].reasons.contains(.qualificationMissing))
    }

    func testOldTaskSuiteCannotAuthorizeCurrentMission() throws {
        let descriptor = descriptor(model: "model", sha: shaA)
        let device = deviceProfile()
        let runtime = try runtimeIdentity(descriptor: descriptor)
        let qualification = try self.qualification(identity: runtime, suiteRevision: "old")
        let candidate = try LocalModelFabricCandidate(
            tier: .core,
            descriptor: descriptor,
            device: device,
            benchmark: benchmark(descriptor: descriptor, device: device),
            runtimeIdentity: runtime,
            qualifications: [qualification]
        )

        let decision = LocalModelFabricSelector.select(candidates: [candidate], request: try request(preferred: [.core]))
        XCTAssertNil(decision.selection)
        XCTAssertTrue(decision.rejections[0].reasons.contains(.qualificationSuiteMismatch))
    }

    func testMeasuredResourceLimitsFailClosed() throws {
        let hot = try candidate(model: "hot", sha: shaA, tier: .core, peakMemory: 2_000, pressure: 3, thermal: .serious)
        let request = try request(
            preferred: [.core],
            maxMemory: 1_500,
            maxPressure: 0,
            maxThermal: .fair
        )
        let decision = LocalModelFabricSelector.select(candidates: [hot], request: request)
        XCTAssertNil(decision.selection)
        let reasons = decision.rejections[0].reasons
        XCTAssertTrue(reasons.contains(.measuredMemoryExceeded))
        XCTAssertTrue(reasons.contains(.measuredMemoryPressureExceeded))
        XCTAssertTrue(reasons.contains(.measuredThermalExceeded))
    }

    func testRuntimeIdentityBindsTokenizerRuntimeKVContextDeviceAndOS() throws {
        let descriptor = descriptor(model: "model", sha: shaA)
        let identity = try runtimeIdentity(descriptor: descriptor)
        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(LocalModelRuntimeIdentity.self, from: data)
        XCTAssertEqual(decoded, identity)
        XCTAssertEqual(decoded.tokenizerRevision, "tok-r1")
        XCTAssertEqual(decoded.runtimeRevision, "runtime-r1")
        XCTAssertEqual(decoded.kvCacheType, "q8_0")
        XCTAssertEqual(decoded.contextTokens, 4096)
        XCTAssertEqual(decoded.osBuild, "iOS-27-build")
    }

    func testRuntimeIdentityDecodeRejectsTamperedArtifactSHA() throws {
        let descriptor = descriptor(model: "model", sha: shaA)
        let identity = try runtimeIdentity(descriptor: descriptor)
        let data = try JSONEncoder().encode(identity)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["artifactSHA256"] = "NOT-A-SHA"
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalModelRuntimeIdentity.self, from: tampered))
    }

    func testQualificationDecodeRevalidatesTaskCountsAndMetrics() throws {
        let descriptor = descriptor(model: "model", sha: shaA)
        let qualification = try self.qualification(identity: try runtimeIdentity(descriptor: descriptor))
        let data = try JSONEncoder().encode(qualification)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["successfulTasks"] = 0
        object["failedTasks"] = 0
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalModelRoleQualification.self, from: tampered))
    }

    func testCandidateRejectsDescriptorRuntimeArtifactMismatch() throws {
        let descriptor = descriptor(model: "model", sha: shaA)
        let device = deviceProfile()
        let otherDescriptor = self.descriptor(model: "model", sha: shaB)
        let runtime = try runtimeIdentity(descriptor: otherDescriptor)
        XCTAssertThrowsError(
            try LocalModelFabricCandidate(
                tier: .core,
                descriptor: descriptor,
                device: device,
                benchmark: nil,
                runtimeIdentity: runtime,
                qualifications: []
            )
        )
    }

    func testPolicyRejectsDuplicateTierAndInvalidThreshold() throws {
        XCTAssertThrowsError(
            try LocalModelFabricPolicy(
                policyID: "p",
                revision: "1",
                preferredTiers: [.instant, .instant]
            )
        )
        XCTAssertThrowsError(
            try LocalModelFabricPolicy(
                policyID: "p",
                revision: "1",
                preferredTiers: [.instant],
                minimumTaskSuccessRate: .nan
            )
        )
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

    private func runtimeIdentity(descriptor: LocalModelCatalogDescriptor) throws -> LocalModelRuntimeIdentity {
        try .init(
            descriptor: descriptor,
            tokenizerID: "tok",
            tokenizerRevision: "tok-r1",
            runtimeID: "llama.cpp",
            runtimeRevision: "runtime-r1",
            kvCacheType: "q8_0",
            contextTokens: 4_096,
            deviceProfileID: "iphone12-ios27",
            osBuild: "iOS-27-build"
        )
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

    private func qualification(
        identity: LocalModelRuntimeIdentity,
        suiteRevision: String = "suite-r1",
        success: UInt16 = 10,
        failed: UInt16 = 0,
        peakMemory: UInt64 = 900,
        pressure: UInt16 = 0,
        thermal: LocalModelFabricThermalState = .nominal,
        ttft: Double = 100
    ) throws -> LocalModelRoleQualification {
        try .init(
            identity: identity,
            role: .toolAgent,
            suiteID: "forge-tools",
            suiteRevision: suiteRevision,
            measuredAt: .init(rawValue: 2_000),
            successfulTasks: success,
            failedTasks: failed,
            peakResidentMemoryBytes: peakMemory,
            memoryPressureEvents: pressure,
            peakThermalState: thermal,
            ttftMilliseconds: ttft,
            prefillTokensPerSecond: 30,
            decodeTokensPerSecond: 10,
            energyMilliwattHours: 2
        )
    }

    private func candidate(
        model: String,
        sha: String,
        tier: LocalModelFabricTier,
        success: UInt16 = 10,
        failed: UInt16 = 0,
        peakMemory: UInt64 = 900,
        pressure: UInt16 = 0,
        thermal: LocalModelFabricThermalState = .nominal,
        ttft: Double = 100,
        includeBenchmark: Bool = true,
        includeQualification: Bool = true
    ) throws -> LocalModelFabricCandidate {
        let descriptor = descriptor(model: model, sha: sha)
        let device = deviceProfile()
        let identity = try runtimeIdentity(descriptor: descriptor)
        let qualifications = includeQualification
            ? [try qualification(identity: identity, success: success, failed: failed, peakMemory: peakMemory, pressure: pressure, thermal: thermal, ttft: ttft)]
            : []
        return try .init(
            tier: tier,
            descriptor: descriptor,
            device: device,
            benchmark: includeBenchmark ? benchmark(descriptor: descriptor, device: device) : nil,
            runtimeIdentity: identity,
            qualifications: qualifications
        )
    }

    private func request(
        preferred: [LocalModelFabricTier],
        mode: LocalModelFabricSelectionMode = .mission,
        allowExperimental: Bool = false,
        minimumTaskSuccessRate: Double = 1,
        maxMemory: UInt64? = nil,
        maxPressure: UInt16? = nil,
        maxThermal: LocalModelFabricThermalState? = nil
    ) throws -> LocalModelFabricRequest {
        try .init(
            role: .toolAgent,
            mode: mode,
            deviceProfileID: "iphone12-ios27",
            requirements: .init(requiresToolCalling: true, requiresStructuredOutput: true, minimumContextTokens: 2_048),
            qualificationSuiteID: "forge-tools",
            qualificationSuiteRevision: "suite-r1",
            policy: .init(
                policyID: "fabric-v1",
                revision: "1",
                preferredTiers: preferred,
                allowExperimentalBeyondRAM: allowExperimental,
                minimumCompletedTasks: 2,
                minimumTaskSuccessRate: minimumTaskSuccessRate,
                maximumPeakResidentMemoryBytes: maxMemory,
                maximumMemoryPressureEvents: maxPressure,
                maximumThermalState: maxThermal
            )
        )
    }
}

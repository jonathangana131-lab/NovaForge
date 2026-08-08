import XCTest
@testable import AgentDomain

final class ForgeCompactQualificationTests: XCTestCase {
    private let sha256 = String(repeating: "a", count: 64)

    func testMissingObservationCannotPromoteProfile() {
        let result = ForgeCompactQualifier.evaluate(profile: profile(), observation: nil)

        XCTAssertEqual(result.status, .unverified)
        XCTAssertEqual(result.reasons, [.observationMissing])
        XCTAssertFalse(result.isProductBadgeEligible)
    }

    func testExactPhysicalDeviceEvidenceCanQualify() {
        let profile = profile()
        let result = ForgeCompactQualifier.evaluate(
            profile: profile,
            observation: observation(profile: profile, environment: .physicalDevice)
        )

        XCTAssertEqual(result.status, .deviceQualified)
        XCTAssertEqual(result.reasons, [.exactPhysicalDeviceEvidence])
        XCTAssertTrue(result.isProductBadgeEligible)
    }

    func testSimulatorEvidenceNeverBecomesDeviceQualification() {
        let profile = profile()
        let result = ForgeCompactQualifier.evaluate(
            profile: profile,
            observation: observation(profile: profile, environment: .simulator)
        )

        XCTAssertEqual(result.status, .functionallyVerified)
        XCTAssertEqual(result.reasons, [.nonPhysicalDeviceEvidence])
        XCTAssertFalse(result.isProductBadgeEligible)
    }

    func testRuntimeRevisionDriftFailsClosed() {
        let expected = profile(runtimeRevision: "runtime-r1")
        let measured = profile(runtimeRevision: "runtime-r2")
        let result = ForgeCompactQualifier.evaluate(
            profile: expected,
            observation: observation(profile: measured)
        )

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.reasons, [.observationIdentityMismatch])
    }

    func testKVTypeDriftFailsClosed() {
        let expected = profile(kvCacheKeyType: "q8_0", kvCacheValueType: "q8_0")
        let measured = profile(kvCacheKeyType: "q4_0", kvCacheValueType: "q8_0")
        let result = ForgeCompactQualifier.evaluate(
            profile: expected,
            observation: observation(profile: measured)
        )

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.reasons, [.observationIdentityMismatch])
    }

    func testContextAndOSBuildDriftFailClosed() {
        let expected = profile(contextTokens: 8_192, osBuild: "24A100")
        let contextDrift = profile(contextTokens: 16_384, osBuild: "24A100")
        let osDrift = profile(contextTokens: 8_192, osBuild: "24A101")

        XCTAssertEqual(
            ForgeCompactQualifier.evaluate(profile: expected, observation: observation(profile: contextDrift)).reasons,
            [.observationIdentityMismatch]
        )
        XCTAssertEqual(
            ForgeCompactQualifier.evaluate(profile: expected, observation: observation(profile: osDrift)).reasons,
            [.observationIdentityMismatch]
        )
    }

    func testMalformedArtifactIdentityAndDuplicateTechniqueAreRejected() {
        let malformed = profile(artifactSHA256: "NOT-A-DIGEST")
        let duplicated = profile(techniques: [.projectCapsule, .projectCapsule])

        XCTAssertEqual(
            ForgeCompactQualifier.evaluate(profile: malformed, observation: nil).reasons,
            [.invalidProfileIdentity]
        )
        XCTAssertEqual(
            ForgeCompactQualifier.evaluate(profile: duplicated, observation: nil).reasons,
            [.duplicateTechnique]
        )
    }

    func testBadMeasurementsDoNotBecomeEvidence() {
        let profile = profile()
        let result = ForgeCompactQualifier.evaluate(
            profile: profile,
            observation: observation(profile: profile, decodeTokensPerSecond: .nan)
        )

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.reasons, [.invalidMeasurement])
    }

    func testInsufficientRunsRemainUnverified() {
        let profile = profile()
        let result = ForgeCompactQualifier.evaluate(
            profile: profile,
            observation: observation(profile: profile, successfulRuns: 1)
        )

        XCTAssertEqual(result.status, .unverified)
        XCTAssertEqual(result.reasons, [.insufficientSuccessfulRuns])
    }

    func testObservedFailureFailsConservativePolicy() {
        let profile = profile()
        let result = ForgeCompactQualifier.evaluate(
            profile: profile,
            observation: observation(profile: profile, failedRuns: 1)
        )

        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.reasons, [.failureRateExceeded])
    }

    func testCodableRoundTripPreservesExactProfileIdentity() throws {
        let source = observation(profile: profile())
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(ForgeCompactObservation.self, from: data)

        XCTAssertEqual(decoded, source)
    }

    private func profile(
        artifactSHA256: String? = nil,
        runtimeRevision: String = "runtime-r1",
        kvCacheKeyType: String = "q8_0",
        kvCacheValueType: String = "q8_0",
        contextTokens: UInt64 = 8_192,
        osBuild: String = "24A100",
        techniques: [ForgeCompactTechnique] = [.projectCapsule, .projectBrainRetrieval, .quantizedKVCache]
    ) -> ForgeCompactProfileIdentity {
        .init(
            profileID: "iphone12-local-agent-q4-kv-q8",
            modelID: "example/local-agent",
            modelRevision: "model-r1",
            artifactSHA256: artifactSHA256 ?? sha256,
            tokenizerID: "example/tokenizer",
            tokenizerRevision: "tokenizer-r1",
            runtimeID: "llama.cpp",
            runtimeRevision: runtimeRevision,
            quantization: "Q4_K_M",
            kvCacheKeyType: kvCacheKeyType,
            kvCacheValueType: kvCacheValueType,
            contextTokens: contextTokens,
            deviceModelIdentifier: "iPhone13,2",
            osVersion: "27.0",
            osBuild: osBuild,
            techniques: techniques
        )
    }

    private func observation(
        profile: ForgeCompactProfileIdentity,
        environment: ForgeCompactEvidenceEnvironment = .physicalDevice,
        successfulRuns: UInt16 = 2,
        failedRuns: UInt16 = 0,
        decodeTokensPerSecond: Double? = 8
    ) -> ForgeCompactObservation {
        .init(
            profile: profile,
            environment: environment,
            receiptID: "receipt-001",
            taskSuiteID: "forge-compact-smoke",
            taskSuiteRevision: "suite-r1",
            successfulRuns: successfulRuns,
            failedRuns: failedRuns,
            peakResidentMemoryBytes: 1_500_000_000,
            memoryPressureEvents: 0,
            timeToFirstTokenMilliseconds: 850,
            prefillTokensPerSecond: 45,
            decodeTokensPerSecond: decodeTokensPerSecond,
            energyJoules: 12.5,
            thermalStart: .nominal,
            thermalEnd: .fair
        )
    }
}

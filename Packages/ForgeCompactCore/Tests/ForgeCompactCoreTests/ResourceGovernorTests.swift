import XCTest
@testable import ForgeCompactCore

final class ResourceGovernorTests: XCTestCase {
    private func qualified(peak: UInt64) throws -> QualifiedLocalRuntimeProfile {
        let profile = try LocalRuntimeProfileIdentity(
            modelID: "model", modelRevision: "m1", tokenizerID: "tok", tokenizerRevision: "t1",
            runtimeID: "runtime", runtimeRevision: "r1", weightQuantization: "Q4_K_M",
            keyCacheType: "q8_0", valueCacheType: "q8_0", contextTokens: 2_048,
            deviceIdentifier: "iPhone13,2", osBuild: "27A"
        )
        let evidence = try LocalRuntimeQualificationEvidence(
            profile: profile, evidenceRevision: "e1", observedAt: .now,
            loadSucceeded: true, completedWithoutTermination: true, localOnlyNetworkAuditPassed: true,
            peakResidentMemoryBytes: peak, timeToFirstTokenMilliseconds: 10,
            promptTokensPerSecond: 10, decodeTokensPerSecond: 5, thermalState: .fair,
            taskSuiteID: "suite", taskCaseCount: 1, taskPassedCount: 1
        )
        return try QualifiedLocalRuntimeProfile(evidence: evidence, acceptanceID: "accepted")
    }

    func testGovernorKeepsLocalOnlyLocalAndSelectsHighestEligibleTier() throws {
        let instant = try ForgeCompactRuntimeCandidate(id: "instant", tier: .instant, executionKind: .local, qualifiedLocalProfile: qualified(peak: 500))
        let core = try ForgeCompactRuntimeCandidate(id: "core", tier: .core, executionKind: .local, qualifiedLocalProfile: qualified(peak: 1_000))
        let hosted = try ForgeCompactRuntimeCandidate(id: "cloud", tier: .deep, executionKind: .hosted)
        let decision = ForgeCompactGovernor.decide(
            candidates: [instant, core, hosted],
            resources: .init(availableMemoryBytes: 2_000, thermalState: .fair, isForeground: true),
            policy: .init(privacyPolicy: .localOnly, maximumTier: .deep, allowExperimentalBeyondRAM: false, minimumMemoryHeadroomBytes: 500)
        )
        XCTAssertEqual(decision, .select(candidateID: "core"))
    }

    func testGovernorDegradesToInstantUnderSeriousThermalState() throws {
        let instant = try ForgeCompactRuntimeCandidate(id: "instant", tier: .instant, executionKind: .local, qualifiedLocalProfile: qualified(peak: 500))
        let core = try ForgeCompactRuntimeCandidate(id: "core", tier: .core, executionKind: .local, qualifiedLocalProfile: qualified(peak: 1_000))
        let decision = ForgeCompactGovernor.decide(
            candidates: [core, instant], resources: .init(availableMemoryBytes: 3_000, thermalState: .serious, isForeground: true),
            policy: .init(privacyPolicy: .localOnly, maximumTier: .deep, allowExperimentalBeyondRAM: false, minimumMemoryHeadroomBytes: 200)
        )
        XCTAssertEqual(decision, .select(candidateID: "instant"))
    }

    func testGovernorRejectsExperimentalTierWithoutExplicitOptIn() throws {
        let experimental = try ForgeCompactRuntimeCandidate(id: "beyond-ram", tier: .experimentalBeyondRAM, executionKind: .local, qualifiedLocalProfile: qualified(peak: 500))
        let decision = ForgeCompactGovernor.decide(
            candidates: [experimental], resources: .init(availableMemoryBytes: 3_000, thermalState: .fair, isForeground: true),
            policy: .init(privacyPolicy: .localOnly, maximumTier: .experimentalBeyondRAM, allowExperimentalBeyondRAM: false, minimumMemoryHeadroomBytes: 100)
        )
        XCTAssertEqual(decision, .blocked(reason: "no runtime candidate satisfies current privacy, qualification, memory, thermal, and tier policy"))
    }

    func testGovernorCheckpointsOnCriticalThermalOrBackground() throws {
        let local = try ForgeCompactRuntimeCandidate(id: "core", tier: .core, executionKind: .local, qualifiedLocalProfile: qualified(peak: 1_200))
        XCTAssertEqual(
            ForgeCompactGovernor.decide(
                candidates: [local], resources: .init(availableMemoryBytes: 5_000, thermalState: .critical, isForeground: true),
                policy: .init(privacyPolicy: .localOnly, maximumTier: .core, allowExperimentalBeyondRAM: false, minimumMemoryHeadroomBytes: 100)
            ), .checkpointAndUnload(reason: "critical thermal state")
        )
        XCTAssertEqual(
            ForgeCompactGovernor.decide(
                candidates: [local], resources: .init(availableMemoryBytes: 5_000, thermalState: .fair, isForeground: false),
                policy: .init(privacyPolicy: .localOnly, maximumTier: .core, allowExperimentalBeyondRAM: false, minimumMemoryHeadroomBytes: 100)
            ), .checkpointAndUnload(reason: "foreground execution authority is unavailable")
        )
    }
}

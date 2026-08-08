import Foundation
import Testing
@testable import ForgeCompactCore

private let hash = String(repeating: "a", count: 64)
private func id(runtime: String = "r1", key: ForgeCompactKVType = .q8_0, value: ForgeCompactKVType = .q8_0, context: UInt64 = 4096) throws -> ForgeCompactExecutionIdentity {
    try .init(modelID: "example/model", modelRevision: "m1", artifactSHA256: hash, tokenizerID: "tok", tokenizerRevision: "t1",
              runtimeID: "llama.cpp", runtimeRevision: runtime, quantization: "Q4_K_M", keyCacheType: key, valueCacheType: value,
              contextTokens: context, deviceID: "iPhone13,2", osBuild: "27.0-test")
}
private func profile(name: String = "core", tier: ForgeCompactTier = .core, roles: Set<ForgeCompactRole> = [.agent, .coder],
                     identity: ForgeCompactExecutionIdentity? = nil, residency: ForgeCompactWeightResidency = .memoryMapped) throws -> ForgeCompactProfile {
    try .init(id: name, tier: tier, roles: roles, identity: identity ?? id(), weightResidency: residency, compatibilityReceiptID: "compat-1")
}
private func measured(identity: ForgeCompactExecutionIdentity, runs: UInt16 = 3, failed: UInt16 = 0, peak: UInt64 = 1_400_000_000,
                      success: Double = 0.9, thermal: ForgeCompactThermalLevel = .fair, decode: Double = 8) throws -> ForgeCompactMeasurement {
    try .init(receiptID: "measure-1", identity: identity, successfulRuns: runs, failedRuns: failed, peakResidentBytes: peak,
              timeToFirstTokenMilliseconds: 800, prefillTokensPerSecond: 40, decodeTokensPerSecond: decode, taskSuccessRate: success,
              peakThermalLevel: thermal, observedAtISO8601: "2026-08-08T12:00:00Z")
}

@Test func exactMeasuredIdentityQualifies() throws {
    let p = try profile(); let m = try measured(identity: p.identity)
    #expect(ForgeCompactQualifier.qualify(profile: p, measurement: m, memoryBudgetBytes: 2_000_000_000).disposition == .qualified)
}
@Test func missingOrMismatchedEvidenceNeverQualifies() throws {
    let p = try profile()
    #expect(ForgeCompactQualifier.qualify(profile: p, measurement: nil, memoryBudgetBytes: 2_000_000_000).disposition == .unverified)
    let mismatch = try measured(identity: id(runtime: "r2"))
    #expect(ForgeCompactQualifier.qualify(profile: p, measurement: mismatch, memoryBudgetBytes: 2_000_000_000).reasons.contains(.executionIdentityMismatch))
}
@Test func kvAndContextArePartOfExactIdentity() throws {
    let p = try profile()
    for other in [try id(key: .q4_0, value: .q4_0), try id(context: 2048)] {
        let q = ForgeCompactQualifier.qualify(profile: p, measurement: try measured(identity: other), memoryBudgetBytes: 2_000_000_000)
        #expect(q.disposition == .unverified)
    }
}
@Test func resourceAndTaskFailuresReject() throws {
    let p = try profile(); let m = try measured(identity: p.identity, runs: 2, failed: 1, peak: 2_100_000_000, success: 0.5, thermal: .serious)
    let q = ForgeCompactQualifier.qualify(profile: p, measurement: m, memoryBudgetBytes: 2_000_000_000)
    #expect(q.disposition == .rejected)
    #expect(q.reasons == [.insufficientSuccessfulRuns, .failureRateExceeded, .taskSuccessInsufficient, .memoryBudgetExceeded, .thermalBudgetExceeded])
}
@Test func beyondRamCanNeverMasqueradeAsQualified() throws {
    let p = try profile(name: "flash", tier: .experimentalBeyondRAM, residency: .flashStreamingExperimental)
    let good = ForgeCompactQualifier.qualify(profile: p, measurement: try measured(identity: p.identity), memoryBudgetBytes: 2_000_000_000)
    #expect(good.disposition == .experimentalOnly)
    let unsafe = ForgeCompactQualifier.qualify(profile: p, measurement: try measured(identity: p.identity, peak: 2_500_000_000, thermal: .serious), memoryBudgetBytes: 2_000_000_000)
    #expect(unsafe.disposition == .rejected)
}
@Test func experimentalResidencyRequiresExperimentalTier() throws {
    #expect(throws: ForgeCompactValidationError.experimentalResidencyRequiresExperimentalTier) { try profile(residency: .expertPagingExperimental) }
}
@Test func malformedDurableIdentityFailsDecode() throws {
    let data = try JSONEncoder().encode(id())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]); object["modelID"] = "   "
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(ForgeCompactExecutionIdentity.self, from: JSONSerialization.data(withJSONObject: object)) }
}
@Test func malformedMeasurementIsRejected() throws {
    let i = try id()
    #expect(throws: ForgeCompactValidationError.invalidMetric("decodeTokensPerSecond")) {
        _ = try ForgeCompactMeasurement(receiptID: "m", identity: i, successfulRuns: 1, failedRuns: 0, peakResidentBytes: 1,
                                        timeToFirstTokenMilliseconds: 1, prefillTokensPerSecond: 1, decodeTokensPerSecond: .nan,
                                        taskSuccessRate: 1, peakThermalLevel: .nominal, observedAtISO8601: "2026-08-08T12:00:00Z")
    }
    #expect(throws: ForgeCompactValidationError.invalidTimestamp) {
        _ = try ForgeCompactMeasurement(receiptID: "m", identity: i, successfulRuns: 1, failedRuns: 0, peakResidentBytes: 1,
                                        timeToFirstTokenMilliseconds: 1, prefillTokensPerSecond: 1, decodeTokensPerSecond: 1,
                                        taskSuccessRate: 1, peakThermalLevel: .nominal, observedAtISO8601: "not-a-time")
    }
}
@Test func governorPrefersSmallestQualifiedRoleTier() throws {
    let instant = try profile(name: "instant", tier: .instant, roles: [.router], residency: .resident)
    let core = try profile(name: "core", roles: [.router, .agent], identity: id(runtime: "core"))
    let im = try measured(identity: instant.identity, success: 0.85, decode: 15), cm = try measured(identity: core.identity, success: 0.99, decode: 20)
    let candidates = [
        ForgeCompactCandidate(profile: core, qualification: ForgeCompactQualifier.qualify(profile: core, measurement: cm, memoryBudgetBytes: 2_000_000_000), measurement: cm),
        ForgeCompactCandidate(profile: instant, qualification: ForgeCompactQualifier.qualify(profile: instant, measurement: im, memoryBudgetBytes: 2_000_000_000), measurement: im)]
    let chosen = ForgeCompactGovernor.select(candidates: candidates, requirement: try .init(role: .router, minimumContextTokens: 1024), memoryPressure: .normal, thermalLevel: .nominal)
    #expect(chosen?.profile.id == "instant")
}
@Test func governorShedsDeepOrStopsUnderPressure() throws {
    let deep = try profile(name: "deep", tier: .deep, roles: [.coder])
    let dm = try measured(identity: deep.identity)
    let candidate = ForgeCompactCandidate(profile: deep, qualification: ForgeCompactQualifier.qualify(profile: deep, measurement: dm, memoryBudgetBytes: 2_000_000_000), measurement: dm)
    let req = try ForgeCompactTaskRequirement(role: .coder, minimumContextTokens: 1024)
    #expect(ForgeCompactGovernor.select(candidates: [candidate], requirement: req, memoryPressure: .warning, thermalLevel: .nominal) == nil)
    #expect(ForgeCompactGovernor.select(candidates: [candidate], requirement: req, memoryPressure: .normal, thermalLevel: .critical) == nil)
}

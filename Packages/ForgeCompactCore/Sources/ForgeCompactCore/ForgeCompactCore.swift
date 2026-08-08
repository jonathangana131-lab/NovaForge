import Foundation

public enum ForgeCompactTier: String, Codable, Sendable { case instant, core, deep, experimentalBeyondRAM }
public enum ForgeCompactRole: String, Codable, Hashable, Sendable { case router, retrieval, agent, coder, critic, compactor, visualCritic }
public enum ForgeCompactKVType: String, Codable, Sendable { case f16, q8_0, q4_0 }
public enum ForgeCompactWeightResidency: String, Codable, Sendable {
    case resident, memoryMapped, flashStreamingExperimental, expertPagingExperimental
    public var isExperimental: Bool { self == .flashStreamingExperimental || self == .expertPagingExperimental }
}
public enum ForgeCompactThermalLevel: Int, Codable, Comparable, Sendable {
    case nominal, fair, serious, critical
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
public enum ForgeCompactMemoryPressure: String, Sendable { case normal, warning, critical }

public enum ForgeCompactValidationError: Error, Equatable, Sendable {
    case blankField(String), invalidArtifactSHA256, noRoles, invalidContextTokens
    case experimentalTierRequiresExperimentalResidency, experimentalResidencyRequiresExperimentalTier
    case invalidMetric(String), invalidRunCount, invalidTimestamp
}

private func nonblank(_ value: String, _ field: String) throws -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw ForgeCompactValidationError.blankField(field) }
    return value
}
private func sha256(_ value: String) throws -> String {
    let value = value.lowercased()
    guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else { throw ForgeCompactValidationError.invalidArtifactSHA256 }
    return value
}

/// Identity required before any local runtime/quant/KV/context/device result may be reused.
public struct ForgeCompactExecutionIdentity: Codable, Hashable, Sendable {
    public let modelID, modelRevision, artifactSHA256, tokenizerID, tokenizerRevision: String
    public let runtimeID, runtimeRevision, quantization: String
    public let keyCacheType, valueCacheType: ForgeCompactKVType
    public let contextTokens: UInt64
    public let deviceID, osBuild: String

    public init(modelID: String, modelRevision: String, artifactSHA256: String,
                tokenizerID: String, tokenizerRevision: String, runtimeID: String,
                runtimeRevision: String, quantization: String, keyCacheType: ForgeCompactKVType,
                valueCacheType: ForgeCompactKVType, contextTokens: UInt64,
                deviceID: String, osBuild: String) throws {
        self.modelID = try nonblank(modelID, "modelID")
        self.modelRevision = try nonblank(modelRevision, "modelRevision")
        self.artifactSHA256 = try sha256(artifactSHA256)
        self.tokenizerID = try nonblank(tokenizerID, "tokenizerID")
        self.tokenizerRevision = try nonblank(tokenizerRevision, "tokenizerRevision")
        self.runtimeID = try nonblank(runtimeID, "runtimeID")
        self.runtimeRevision = try nonblank(runtimeRevision, "runtimeRevision")
        self.quantization = try nonblank(quantization, "quantization")
        self.keyCacheType = keyCacheType
        self.valueCacheType = valueCacheType
        guard contextTokens > 0 else { throw ForgeCompactValidationError.invalidContextTokens }
        self.contextTokens = contextTokens
        self.deviceID = try nonblank(deviceID, "deviceID")
        self.osBuild = try nonblank(osBuild, "osBuild")
    }

    private enum CodingKeys: String, CodingKey {
        case modelID, modelRevision, artifactSHA256, tokenizerID, tokenizerRevision, runtimeID, runtimeRevision
        case quantization, keyCacheType, valueCacheType, contextTokens, deviceID, osBuild
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(modelID: c.decode(String.self, forKey: .modelID), modelRevision: c.decode(String.self, forKey: .modelRevision),
                      artifactSHA256: c.decode(String.self, forKey: .artifactSHA256), tokenizerID: c.decode(String.self, forKey: .tokenizerID),
                      tokenizerRevision: c.decode(String.self, forKey: .tokenizerRevision), runtimeID: c.decode(String.self, forKey: .runtimeID),
                      runtimeRevision: c.decode(String.self, forKey: .runtimeRevision), quantization: c.decode(String.self, forKey: .quantization),
                      keyCacheType: c.decode(ForgeCompactKVType.self, forKey: .keyCacheType), valueCacheType: c.decode(ForgeCompactKVType.self, forKey: .valueCacheType),
                      contextTokens: c.decode(UInt64.self, forKey: .contextTokens), deviceID: c.decode(String.self, forKey: .deviceID), osBuild: c.decode(String.self, forKey: .osBuild))
    }
}

/// Configuration only. Compatibility authority stays outside this package and is referenced by opaque receipt ID.
public struct ForgeCompactProfile: Sendable {
    public let id: String
    public let tier: ForgeCompactTier
    public let roles: Set<ForgeCompactRole>
    public let identity: ForgeCompactExecutionIdentity
    public let weightResidency: ForgeCompactWeightResidency
    public let compatibilityReceiptID: String

    public init(id: String, tier: ForgeCompactTier, roles: Set<ForgeCompactRole>, identity: ForgeCompactExecutionIdentity,
                weightResidency: ForgeCompactWeightResidency, compatibilityReceiptID: String) throws {
        self.id = try nonblank(id, "profileID")
        guard !roles.isEmpty else { throw ForgeCompactValidationError.noRoles }
        if tier == .experimentalBeyondRAM && !weightResidency.isExperimental { throw ForgeCompactValidationError.experimentalTierRequiresExperimentalResidency }
        if tier != .experimentalBeyondRAM && weightResidency.isExperimental { throw ForgeCompactValidationError.experimentalResidencyRequiresExperimentalTier }
        self.tier = tier; self.roles = roles; self.identity = identity; self.weightResidency = weightResidency
        self.compatibilityReceiptID = try nonblank(compatibilityReceiptID, "compatibilityReceiptID")
    }
}

/// Only reproduced measurements belong here; source/paper claims cannot qualify a profile.
public struct ForgeCompactMeasurement: Sendable {
    public let receiptID: String
    public let identity: ForgeCompactExecutionIdentity
    public let successfulRuns, failedRuns: UInt16
    public let peakResidentBytes: UInt64
    public let timeToFirstTokenMilliseconds, prefillTokensPerSecond, decodeTokensPerSecond, taskSuccessRate: Double
    public let peakThermalLevel: ForgeCompactThermalLevel
    public let observedAtISO8601: String

    public init(receiptID: String, identity: ForgeCompactExecutionIdentity, successfulRuns: UInt16, failedRuns: UInt16,
                peakResidentBytes: UInt64, timeToFirstTokenMilliseconds: Double, prefillTokensPerSecond: Double,
                decodeTokensPerSecond: Double, taskSuccessRate: Double, peakThermalLevel: ForgeCompactThermalLevel,
                observedAtISO8601: String) throws {
        self.receiptID = try nonblank(receiptID, "measurementReceiptID")
        guard successfulRuns > 0 || failedRuns > 0 else { throw ForgeCompactValidationError.invalidRunCount }
        for (name, value) in [("timeToFirstTokenMilliseconds", timeToFirstTokenMilliseconds), ("prefillTokensPerSecond", prefillTokensPerSecond), ("decodeTokensPerSecond", decodeTokensPerSecond)] {
            guard value.isFinite && value >= 0 else { throw ForgeCompactValidationError.invalidMetric(name) }
        }
        guard taskSuccessRate.isFinite && (0...1).contains(taskSuccessRate) else { throw ForgeCompactValidationError.invalidMetric("taskSuccessRate") }
        let timestamp = try nonblank(observedAtISO8601, "observedAtISO8601")
        guard ISO8601DateFormatter().date(from: timestamp) != nil else { throw ForgeCompactValidationError.invalidTimestamp }
        self.identity = identity; self.successfulRuns = successfulRuns; self.failedRuns = failedRuns
        self.peakResidentBytes = peakResidentBytes; self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.prefillTokensPerSecond = prefillTokensPerSecond; self.decodeTokensPerSecond = decodeTokensPerSecond
        self.taskSuccessRate = taskSuccessRate; self.peakThermalLevel = peakThermalLevel; self.observedAtISO8601 = timestamp
    }
}

public struct ForgeCompactQualificationPolicy: Sendable {
    public let minimumSuccessfulRuns: UInt16
    public let maximumFailureRate, minimumTaskSuccessRate: Double
    public let maximumPeakThermalLevel: ForgeCompactThermalLevel
    public init(minimumSuccessfulRuns: UInt16 = 3, maximumFailureRate: Double = 0,
                minimumTaskSuccessRate: Double = 0.8, maximumPeakThermalLevel: ForgeCompactThermalLevel = .fair) throws {
        guard minimumSuccessfulRuns > 0 else { throw ForgeCompactValidationError.invalidRunCount }
        guard maximumFailureRate.isFinite && (0...1).contains(maximumFailureRate) else { throw ForgeCompactValidationError.invalidMetric("maximumFailureRate") }
        guard minimumTaskSuccessRate.isFinite && (0...1).contains(minimumTaskSuccessRate) else { throw ForgeCompactValidationError.invalidMetric("minimumTaskSuccessRate") }
        self.minimumSuccessfulRuns = minimumSuccessfulRuns; self.maximumFailureRate = maximumFailureRate
        self.minimumTaskSuccessRate = minimumTaskSuccessRate; self.maximumPeakThermalLevel = maximumPeakThermalLevel
    }
    public static var conservativeV1: Self { try! .init() }
}

public enum ForgeCompactQualificationReason: String, Hashable, Sendable {
    case measurementMissing, executionIdentityMismatch, insufficientSuccessfulRuns, failureRateExceeded
    case taskSuccessInsufficient, memoryBudgetExceeded, thermalBudgetExceeded, experimentalBeyondRAM
}
public enum ForgeCompactQualificationDisposition: String, Sendable { case qualified, unverified, rejected, experimentalOnly }
public struct ForgeCompactQualification: Sendable {
    public let disposition: ForgeCompactQualificationDisposition
    public let reasons: Set<ForgeCompactQualificationReason>
    public let measurementReceiptID: String?
}

public enum ForgeCompactQualifier {
    public static func qualify(profile: ForgeCompactProfile, measurement: ForgeCompactMeasurement?, memoryBudgetBytes: UInt64,
                               policy: ForgeCompactQualificationPolicy = .conservativeV1) -> ForgeCompactQualification {
        guard let m = measurement else {
            var reasons: Set<ForgeCompactQualificationReason> = [.measurementMissing]
            if profile.tier == .experimentalBeyondRAM { reasons.insert(.experimentalBeyondRAM) }
            return .init(disposition: .unverified, reasons: reasons, measurementReceiptID: nil)
        }
        guard m.identity == profile.identity else {
            var reasons: Set<ForgeCompactQualificationReason> = [.executionIdentityMismatch]
            if profile.tier == .experimentalBeyondRAM { reasons.insert(.experimentalBeyondRAM) }
            return .init(disposition: .unverified, reasons: reasons, measurementReceiptID: m.receiptID)
        }
        var reasons = Set<ForgeCompactQualificationReason>()
        if m.successfulRuns < policy.minimumSuccessfulRuns { reasons.insert(.insufficientSuccessfulRuns) }
        let total = UInt32(m.successfulRuns) + UInt32(m.failedRuns)
        if Double(m.failedRuns) / Double(total) > policy.maximumFailureRate { reasons.insert(.failureRateExceeded) }
        if m.taskSuccessRate < policy.minimumTaskSuccessRate { reasons.insert(.taskSuccessInsufficient) }
        if m.peakResidentBytes > memoryBudgetBytes { reasons.insert(.memoryBudgetExceeded) }
        if m.peakThermalLevel > policy.maximumPeakThermalLevel { reasons.insert(.thermalBudgetExceeded) }
        if !reasons.isEmpty {
            if profile.tier == .experimentalBeyondRAM { reasons.insert(.experimentalBeyondRAM) }
            return .init(disposition: .rejected, reasons: reasons, measurementReceiptID: m.receiptID)
        }
        if profile.tier == .experimentalBeyondRAM {
            return .init(disposition: .experimentalOnly, reasons: [.experimentalBeyondRAM], measurementReceiptID: m.receiptID)
        }
        return .init(disposition: .qualified, reasons: [], measurementReceiptID: m.receiptID)
    }
}

public struct ForgeCompactCandidate: Sendable {
    public let profile: ForgeCompactProfile; public let qualification: ForgeCompactQualification; public let measurement: ForgeCompactMeasurement?
    public init(profile: ForgeCompactProfile, qualification: ForgeCompactQualification, measurement: ForgeCompactMeasurement?) {
        self.profile = profile; self.qualification = qualification; self.measurement = measurement
    }
}
public struct ForgeCompactTaskRequirement: Sendable {
    public let role: ForgeCompactRole; public let minimumContextTokens: UInt64
    public init(role: ForgeCompactRole, minimumContextTokens: UInt64) throws {
        guard minimumContextTokens > 0 else { throw ForgeCompactValidationError.invalidContextTokens }
        self.role = role; self.minimumContextTokens = minimumContextTokens
    }
}

public enum ForgeCompactGovernor {
    public static func select(candidates: [ForgeCompactCandidate], requirement: ForgeCompactTaskRequirement,
                              memoryPressure: ForgeCompactMemoryPressure, thermalLevel: ForgeCompactThermalLevel) -> ForgeCompactCandidate? {
        guard memoryPressure != .critical, thermalLevel != .critical else { return nil }
        let shedDeep = memoryPressure == .warning || thermalLevel >= .serious
        return candidates.filter {
            $0.qualification.disposition == .qualified && $0.profile.roles.contains(requirement.role)
                && $0.profile.identity.contextTokens >= requirement.minimumContextTokens
                && (!shedDeep || rank($0.profile.tier) <= rank(.core))
        }.sorted {
            let lr = rank($0.profile.tier), rr = rank($1.profile.tier)
            if lr != rr { return lr < rr }
            let ls = $0.measurement?.taskSuccessRate ?? 0, rs = $1.measurement?.taskSuccessRate ?? 0
            if ls != rs { return ls > rs }
            let ld = $0.measurement?.decodeTokensPerSecond ?? 0, rd = $1.measurement?.decodeTokensPerSecond ?? 0
            if ld != rd { return ld > rd }
            return $0.profile.id < $1.profile.id
        }.first
    }
    private static func rank(_ tier: ForgeCompactTier) -> Int {
        switch tier { case .instant: 0; case .core: 1; case .deep: 2; case .experimentalBeyondRAM: 3 }
    }
}

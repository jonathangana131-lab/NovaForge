import Foundation

/// Forge Compact features are product capabilities only after their exact runtime profile
/// has evidence. Research papers and nearby model/runtime configurations never promote a profile.
public enum ForgeCompactTechnique: String, Codable, CaseIterable, Hashable, Sendable {
    case projectCapsule
    case projectBrainRetrieval
    case quantizedKVCache
    case exactPrefixReuse
    case speculativeDecoding
    case memoryMappedWeights
    case adaptiveKVPrecision
    case flashBackedWeights
    case sparseExpertPaging
}

/// Exact identity for one local-inference configuration. Every field participates in equality so
/// a benchmark cannot silently drift across tokenizer/runtime/quant/KV/context/device/OS changes.
public struct ForgeCompactProfileIdentity: Codable, Equatable, Hashable, Sendable {
    public let profileID: String
    public let modelID: String
    public let modelRevision: String
    public let artifactSHA256: String
    public let tokenizerID: String
    public let tokenizerRevision: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let quantization: String
    public let kvCacheKeyType: String
    public let kvCacheValueType: String
    public let contextTokens: UInt64
    public let deviceModelIdentifier: String
    public let osVersion: String
    public let osBuild: String
    public let techniques: [ForgeCompactTechnique]

    public init(
        profileID: String,
        modelID: String,
        modelRevision: String,
        artifactSHA256: String,
        tokenizerID: String,
        tokenizerRevision: String,
        runtimeID: String,
        runtimeRevision: String,
        quantization: String,
        kvCacheKeyType: String,
        kvCacheValueType: String,
        contextTokens: UInt64,
        deviceModelIdentifier: String,
        osVersion: String,
        osBuild: String,
        techniques: [ForgeCompactTechnique]
    ) {
        self.profileID = profileID
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.artifactSHA256 = artifactSHA256
        self.tokenizerID = tokenizerID
        self.tokenizerRevision = tokenizerRevision
        self.runtimeID = runtimeID
        self.runtimeRevision = runtimeRevision
        self.quantization = quantization
        self.kvCacheKeyType = kvCacheKeyType
        self.kvCacheValueType = kvCacheValueType
        self.contextTokens = contextTokens
        self.deviceModelIdentifier = deviceModelIdentifier
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.techniques = techniques
    }
}

public enum ForgeCompactEvidenceEnvironment: String, Codable, Hashable, Sendable {
    /// Deterministic unit/integration proof with no simulator/device performance authority.
    case deterministicHarness
    /// Simulator evidence can prove functional integration, never physical-device efficiency.
    case simulator
    /// Measurement produced on the exact physical device named by the profile identity.
    case physicalDevice
}

public enum ForgeCompactThermalState: String, Codable, Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

/// One bounded benchmark/qualification observation. Optional metrics stay optional rather than
/// being fabricated when a platform adapter cannot measure them truthfully.
public struct ForgeCompactObservation: Codable, Equatable, Sendable {
    public let profile: ForgeCompactProfileIdentity
    public let environment: ForgeCompactEvidenceEnvironment
    public let receiptID: String
    public let taskSuiteID: String
    public let taskSuiteRevision: String
    public let successfulRuns: UInt16
    public let failedRuns: UInt16
    public let peakResidentMemoryBytes: UInt64?
    public let memoryPressureEvents: UInt16?
    public let timeToFirstTokenMilliseconds: Double?
    public let prefillTokensPerSecond: Double?
    public let decodeTokensPerSecond: Double?
    public let energyJoules: Double?
    public let thermalStart: ForgeCompactThermalState
    public let thermalEnd: ForgeCompactThermalState

    public init(
        profile: ForgeCompactProfileIdentity,
        environment: ForgeCompactEvidenceEnvironment,
        receiptID: String,
        taskSuiteID: String,
        taskSuiteRevision: String,
        successfulRuns: UInt16,
        failedRuns: UInt16,
        peakResidentMemoryBytes: UInt64? = nil,
        memoryPressureEvents: UInt16? = nil,
        timeToFirstTokenMilliseconds: Double? = nil,
        prefillTokensPerSecond: Double? = nil,
        decodeTokensPerSecond: Double? = nil,
        energyJoules: Double? = nil,
        thermalStart: ForgeCompactThermalState = .unknown,
        thermalEnd: ForgeCompactThermalState = .unknown
    ) {
        self.profile = profile
        self.environment = environment
        self.receiptID = receiptID
        self.taskSuiteID = taskSuiteID
        self.taskSuiteRevision = taskSuiteRevision
        self.successfulRuns = successfulRuns
        self.failedRuns = failedRuns
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.memoryPressureEvents = memoryPressureEvents
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.energyJoules = energyJoules
        self.thermalStart = thermalStart
        self.thermalEnd = thermalEnd
    }
}

public struct ForgeCompactQualificationPolicy: Codable, Equatable, Sendable {
    public let minimumSuccessfulRuns: UInt16
    public let maximumFailureRate: Double

    public init(minimumSuccessfulRuns: UInt16 = 2, maximumFailureRate: Double = 0) {
        self.minimumSuccessfulRuns = minimumSuccessfulRuns
        self.maximumFailureRate = maximumFailureRate
    }

    public static let conservativeV1 = ForgeCompactQualificationPolicy()

    public var isValid: Bool {
        minimumSuccessfulRuns > 0
            && maximumFailureRate.isFinite
            && maximumFailureRate >= 0
            && maximumFailureRate <= 1
    }
}

public enum ForgeCompactQualificationStatus: String, Codable, Hashable, Sendable {
    case rejected
    case unverified
    case functionallyVerified
    case deviceQualified
}

public enum ForgeCompactQualificationReason: String, Codable, Hashable, Sendable {
    case invalidPolicy
    case invalidProfileIdentity
    case duplicateTechnique
    case observationMissing
    case observationIdentityMismatch
    case invalidObservationMetadata
    case invalidMeasurement
    case insufficientSuccessfulRuns
    case failureRateExceeded
    case nonPhysicalDeviceEvidence
    case missingRequiredDeviceMeasurements
    case exactPhysicalDeviceEvidence
}

public struct ForgeCompactQualificationResult: Codable, Equatable, Sendable {
    public let status: ForgeCompactQualificationStatus
    public let reasons: [ForgeCompactQualificationReason]

    public init(status: ForgeCompactQualificationStatus, reasons: [ForgeCompactQualificationReason]) {
        self.status = status
        self.reasons = reasons
    }

    /// Only exact physical-device evidence is eligible for a compatibility/performance badge.
    public var isProductBadgeEligible: Bool {
        status == .deviceQualified
    }
}

public enum ForgeCompactQualifier {
    public static func evaluate(
        profile: ForgeCompactProfileIdentity,
        observation: ForgeCompactObservation?,
        policy: ForgeCompactQualificationPolicy = .conservativeV1
    ) -> ForgeCompactQualificationResult {
        guard policy.isValid else {
            return .init(status: .rejected, reasons: [.invalidPolicy])
        }

        let profileValidation = validate(profile: profile)
        guard profileValidation.isEmpty else {
            return .init(status: .rejected, reasons: profileValidation)
        }

        guard let observation else {
            return .init(status: .unverified, reasons: [.observationMissing])
        }

        guard observation.profile == profile else {
            return .init(status: .rejected, reasons: [.observationIdentityMismatch])
        }

        guard isMeaningful(observation.receiptID),
              isMeaningful(observation.taskSuiteID),
              isMeaningful(observation.taskSuiteRevision)
        else {
            return .init(status: .rejected, reasons: [.invalidObservationMetadata])
        }

        guard measurementsAreValid(observation) else {
            return .init(status: .rejected, reasons: [.invalidMeasurement])
        }

        guard observation.successfulRuns >= policy.minimumSuccessfulRuns else {
            return .init(status: .unverified, reasons: [.insufficientSuccessfulRuns])
        }

        let totalRuns = UInt32(observation.successfulRuns) + UInt32(observation.failedRuns)
        guard totalRuns > 0 else {
            return .init(status: .unverified, reasons: [.insufficientSuccessfulRuns])
        }

        let failureRate = Double(observation.failedRuns) / Double(totalRuns)
        guard failureRate <= policy.maximumFailureRate else {
            return .init(status: .rejected, reasons: [.failureRateExceeded])
        }

        guard observation.environment == .physicalDevice else {
            return .init(status: .functionallyVerified, reasons: [.nonPhysicalDeviceEvidence])
        }

        guard hasRequiredDeviceMeasurements(observation) else {
            return .init(status: .unverified, reasons: [.missingRequiredDeviceMeasurements])
        }

        return .init(status: .deviceQualified, reasons: [.exactPhysicalDeviceEvidence])
    }

    private static func validate(profile: ForgeCompactProfileIdentity) -> [ForgeCompactQualificationReason] {
        let requiredStrings = [
            profile.profileID,
            profile.modelID,
            profile.modelRevision,
            profile.tokenizerID,
            profile.tokenizerRevision,
            profile.runtimeID,
            profile.runtimeRevision,
            profile.quantization,
            profile.kvCacheKeyType,
            profile.kvCacheValueType,
            profile.deviceModelIdentifier,
            profile.osVersion,
            profile.osBuild,
        ]

        guard requiredStrings.allSatisfy(isMeaningful),
              isCanonicalSHA256(profile.artifactSHA256),
              profile.contextTokens > 0,
              !profile.techniques.isEmpty
        else {
            return [.invalidProfileIdentity]
        }

        guard Set(profile.techniques).count == profile.techniques.count else {
            return [.duplicateTechnique]
        }

        return []
    }

    private static func hasRequiredDeviceMeasurements(_ observation: ForgeCompactObservation) -> Bool {
        guard let peakResidentMemoryBytes = observation.peakResidentMemoryBytes,
              peakResidentMemoryBytes > 0,
              let timeToFirstTokenMilliseconds = observation.timeToFirstTokenMilliseconds,
              timeToFirstTokenMilliseconds > 0,
              let prefillTokensPerSecond = observation.prefillTokensPerSecond,
              prefillTokensPerSecond > 0,
              let decodeTokensPerSecond = observation.decodeTokensPerSecond,
              decodeTokensPerSecond > 0,
              observation.thermalStart != .unknown,
              observation.thermalEnd != .unknown
        else {
            return false
        }

        return true
    }

    private static func measurementsAreValid(_ observation: ForgeCompactObservation) -> Bool {
        if let peakResidentMemoryBytes = observation.peakResidentMemoryBytes,
           peakResidentMemoryBytes == 0 {
            return false
        }

        let nonNegativeFiniteMeasurements = [
            observation.timeToFirstTokenMilliseconds,
            observation.prefillTokensPerSecond,
            observation.decodeTokensPerSecond,
            observation.energyJoules,
        ]

        return nonNegativeFiniteMeasurements.allSatisfy { measurement in
            guard let measurement else { return true }
            return measurement.isFinite && measurement >= 0
        }
    }

    private static func isMeaningful(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            ("0"..."9").contains(Character(String(scalar)))
                || ("a"..."f").contains(Character(String(scalar)))
        }
    }
}

import Foundation

/// Distinguishes evidence collected on a real device from Simulator-only research.
/// Simulator observations may be useful for development, but they cannot mint a
/// physical-device compatibility claim.
public enum LocalModelQualificationEnvironment: String, Codable, Hashable, Sendable {
    case physicalDevice
    case simulator
}

/// Mirrors the semantic thermal states exposed by Apple platforms without claiming
/// access to a more precise temperature measurement than the OS provides.
public enum LocalModelQualificationThermalState: String, Codable, CaseIterable, Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

/// Exact execution identity required to reproduce one local-model qualification run.
/// Friendly family names or parameter counts are intentionally insufficient here.
/// `runtimeConfigurationSHA256` binds runtime options not modeled as first-class fields
/// (for example attention/offload/thread settings) without teaching AgentDomain about
/// backend-specific command-line flags.
public struct LocalModelQualificationIdentity: Codable, Equatable, Hashable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let artifactSHA256: String
    public let artifactFormat: String
    public let tokenizerID: String
    public let tokenizerRevision: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let backendID: String
    public let runtimeConfigurationSHA256: String
    public let quantization: String
    public let keyCacheType: String
    public let valueCacheType: String
    public let contextWindowTokens: UInt64
    public let deviceModelIdentifier: String
    public let operatingSystemVersion: String
    public let environment: LocalModelQualificationEnvironment

    public init(
        modelID: String,
        modelRevision: String,
        artifactSHA256: String,
        artifactFormat: String,
        tokenizerID: String,
        tokenizerRevision: String,
        runtimeID: String,
        runtimeRevision: String,
        backendID: String,
        runtimeConfigurationSHA256: String,
        quantization: String,
        keyCacheType: String,
        valueCacheType: String,
        contextWindowTokens: UInt64,
        deviceModelIdentifier: String,
        operatingSystemVersion: String,
        environment: LocalModelQualificationEnvironment
    ) {
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.artifactSHA256 = artifactSHA256
        self.artifactFormat = artifactFormat
        self.tokenizerID = tokenizerID
        self.tokenizerRevision = tokenizerRevision
        self.runtimeID = runtimeID
        self.runtimeRevision = runtimeRevision
        self.backendID = backendID
        self.runtimeConfigurationSHA256 = runtimeConfigurationSHA256
        self.quantization = quantization
        self.keyCacheType = keyCacheType
        self.valueCacheType = valueCacheType
        self.contextWindowTokens = contextWindowTokens
        self.deviceModelIdentifier = deviceModelIdentifier
        self.operatingSystemVersion = operatingSystemVersion
        self.environment = environment
    }
}

/// Measured runtime values for one exact qualification identity.
/// Energy is optional because not every supported measurement environment can expose
/// a trustworthy energy value. When present it is still validated as measured data.
public struct LocalModelQualificationMetrics: Codable, Equatable, Sendable {
    public let peakResidentMemoryBytes: UInt64
    public let timeToFirstTokenMilliseconds: Double
    public let prefillTokensPerSecond: Double
    public let decodeTokensPerSecond: Double
    public let maximumThermalState: LocalModelQualificationThermalState
    public let memoryPressureEvents: UInt16
    public let energyMillijoules: Double?

    public init(
        peakResidentMemoryBytes: UInt64,
        timeToFirstTokenMilliseconds: Double,
        prefillTokensPerSecond: Double,
        decodeTokensPerSecond: Double,
        maximumThermalState: LocalModelQualificationThermalState,
        memoryPressureEvents: UInt16 = 0,
        energyMillijoules: Double? = nil
    ) {
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.maximumThermalState = maximumThermalState
        self.memoryPressureEvents = memoryPressureEvents
        self.energyMillijoules = energyMillijoules
    }
}

/// Result of a versioned NovaForge task suite. A failing suite is still valuable
/// measurement evidence; this type records the result instead of converting it into
/// a fabricated pass or hiding it from compatibility decisions.
public struct LocalModelTaskSuiteObservation: Codable, Equatable, Hashable, Sendable {
    public let suiteID: String
    public let suiteRevision: String
    public let successfulTasks: UInt16
    public let failedTasks: UInt16

    public init(
        suiteID: String,
        suiteRevision: String,
        successfulTasks: UInt16,
        failedTasks: UInt16
    ) {
        self.suiteID = suiteID
        self.suiteRevision = suiteRevision
        self.successfulTasks = successfulTasks
        self.failedTasks = failedTasks
    }

    public var totalTasks: UInt32 {
        UInt32(successfulTasks) + UInt32(failedTasks)
    }
}

/// One reproducible qualification record. Decoding fails closed if persisted bytes
/// contain an invalid identity, invalid metrics, or missing/duplicate task-suite truth.
/// Simulator observations remain decodable but are classified as research-only.
public struct LocalModelQualificationObservation: Codable, Equatable, Sendable {
    public let identity: LocalModelQualificationIdentity
    public let measuredAt: AgentInstant
    public let metrics: LocalModelQualificationMetrics
    public let taskSuites: [LocalModelTaskSuiteObservation]

    public init(
        identity: LocalModelQualificationIdentity,
        measuredAt: AgentInstant,
        metrics: LocalModelQualificationMetrics,
        taskSuites: [LocalModelTaskSuiteObservation]
    ) {
        self.identity = identity
        self.measuredAt = measuredAt
        self.metrics = metrics
        self.taskSuites = taskSuites
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case measuredAt
        case metrics
        case taskSuites
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = Self(
            identity: try container.decode(LocalModelQualificationIdentity.self, forKey: .identity),
            measuredAt: try container.decode(AgentInstant.self, forKey: .measuredAt),
            metrics: try container.decode(LocalModelQualificationMetrics.self, forKey: .metrics),
            taskSuites: try container.decode([LocalModelTaskSuiteObservation].self, forKey: .taskSuites)
        )

        let assessment = LocalModelQualificationValidator.evaluate(decoded)
        guard assessment.status != .invalid else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid local-model qualification record: \(assessment.issues.map(\.rawValue).joined(separator: ", "))"
            ))
        }

        self = decoded
    }
}

/// This status describes evidence completeness only. It is deliberately not a model
/// quality/support label; the compatibility policy remains a separate authority.
public enum LocalModelQualificationEvidenceStatus: String, Codable, Hashable, Sendable {
    case eligibleForMeasuredClassification
    case researchOnly
    case invalid
}

public enum LocalModelQualificationIssue: String, Codable, CaseIterable, Hashable, Sendable {
    case incompleteIdentity
    case malformedArtifactSHA256
    case malformedRuntimeConfigurationSHA256
    case invalidContextWindow
    case invalidMemoryMeasurement
    case invalidPerformanceMeasurement
    case invalidEnergyMeasurement
    case missingTaskSuiteEvidence
    case invalidTaskSuiteEvidence
    case duplicateTaskSuiteIdentity
    case physicalDeviceEvidenceRequired
}

public struct LocalModelQualificationAssessment: Codable, Equatable, Sendable {
    public let status: LocalModelQualificationEvidenceStatus
    public let issues: [LocalModelQualificationIssue]

    public init(
        status: LocalModelQualificationEvidenceStatus,
        issues: [LocalModelQualificationIssue]
    ) {
        self.status = status
        self.issues = issues
    }

    /// This means the evidence is complete enough for a measured compatibility policy
    /// to consume. It does not mean the model is fast, stable, supported, or recommended.
    public var canDriveMeasuredCompatibility: Bool {
        status == .eligibleForMeasuredClassification
    }
}

public enum LocalModelQualificationValidator {
    private struct TaskSuiteIdentity: Hashable {
        let id: String
        let revision: String
    }

    public static func evaluate(
        _ observation: LocalModelQualificationObservation
    ) -> LocalModelQualificationAssessment {
        var issues: [LocalModelQualificationIssue] = []
        let identity = observation.identity

        let exactIdentityStrings = [
            identity.modelID,
            identity.modelRevision,
            identity.artifactFormat,
            identity.tokenizerID,
            identity.tokenizerRevision,
            identity.runtimeID,
            identity.runtimeRevision,
            identity.backendID,
            identity.quantization,
            identity.keyCacheType,
            identity.valueCacheType,
            identity.deviceModelIdentifier,
            identity.operatingSystemVersion,
        ]

        if exactIdentityStrings.contains(where: { !isCanonicalIdentityText($0) }) {
            issues.append(.incompleteIdentity)
        }

        if !isCanonicalSHA256(identity.artifactSHA256) {
            issues.append(.malformedArtifactSHA256)
        }

        if !isCanonicalSHA256(identity.runtimeConfigurationSHA256) {
            issues.append(.malformedRuntimeConfigurationSHA256)
        }

        if identity.contextWindowTokens == 0 {
            issues.append(.invalidContextWindow)
        }

        if observation.metrics.peakResidentMemoryBytes == 0 {
            issues.append(.invalidMemoryMeasurement)
        }

        if !isPositiveFinite(observation.metrics.timeToFirstTokenMilliseconds)
            || !isPositiveFinite(observation.metrics.prefillTokensPerSecond)
            || !isPositiveFinite(observation.metrics.decodeTokensPerSecond)
        {
            issues.append(.invalidPerformanceMeasurement)
        }

        if let energyMillijoules = observation.metrics.energyMillijoules,
           !isNonnegativeFinite(energyMillijoules)
        {
            issues.append(.invalidEnergyMeasurement)
        }

        if observation.taskSuites.isEmpty {
            issues.append(.missingTaskSuiteEvidence)
        } else {
            var identities = Set<TaskSuiteIdentity>()
            var hasInvalidSuite = false
            var hasDuplicateSuite = false

            for suite in observation.taskSuites {
                if !isCanonicalIdentityText(suite.suiteID)
                    || !isCanonicalIdentityText(suite.suiteRevision)
                    || suite.totalTasks == 0
                {
                    hasInvalidSuite = true
                }

                let identityKey = TaskSuiteIdentity(id: suite.suiteID, revision: suite.suiteRevision)
                if !identities.insert(identityKey).inserted {
                    hasDuplicateSuite = true
                }
            }

            if hasInvalidSuite {
                issues.append(.invalidTaskSuiteEvidence)
            }
            if hasDuplicateSuite {
                issues.append(.duplicateTaskSuiteIdentity)
            }
        }

        if issues.isEmpty {
            switch identity.environment {
            case .physicalDevice:
                return .init(status: .eligibleForMeasuredClassification, issues: [])
            case .simulator:
                return .init(status: .researchOnly, issues: [.physicalDeviceEvidenceRequired])
            }
        }

        return .init(status: .invalid, issues: issues)
    }

    private static func isCanonicalIdentityText(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            ("0"..."9").contains(Character(String($0)))
                || ("a"..."f").contains(Character(String($0)))
        }
    }

    private static func isPositiveFinite(_ value: Double) -> Bool {
        value.isFinite && value > 0
    }

    private static func isNonnegativeFinite(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }
}

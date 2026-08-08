import Foundation

public struct LocalRuntimeProfileIdentity: Hashable, Codable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let tokenizerID: String
    public let tokenizerRevision: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let weightQuantization: String
    public let keyCacheType: String
    public let valueCacheType: String
    public let contextTokens: Int
    public let deviceIdentifier: String
    public let osBuild: String

    public init(
        modelID: String,
        modelRevision: String,
        tokenizerID: String,
        tokenizerRevision: String,
        runtimeID: String,
        runtimeRevision: String,
        weightQuantization: String,
        keyCacheType: String,
        valueCacheType: String,
        contextTokens: Int,
        deviceIdentifier: String,
        osBuild: String
    ) throws {
        self.modelID = try validatedText(modelID, field: "modelID")
        self.modelRevision = try validatedText(modelRevision, field: "modelRevision")
        self.tokenizerID = try validatedText(tokenizerID, field: "tokenizerID")
        self.tokenizerRevision = try validatedText(tokenizerRevision, field: "tokenizerRevision")
        self.runtimeID = try validatedText(runtimeID, field: "runtimeID")
        self.runtimeRevision = try validatedText(runtimeRevision, field: "runtimeRevision")
        self.weightQuantization = try validatedText(weightQuantization, field: "weightQuantization", maximumLength: 64)
        self.keyCacheType = try validatedText(keyCacheType, field: "keyCacheType", maximumLength: 64)
        self.valueCacheType = try validatedText(valueCacheType, field: "valueCacheType", maximumLength: 64)
        guard (1...1_048_576).contains(contextTokens) else {
            throw ForgeCompactValidationError.invalidContextTokens
        }
        self.contextTokens = contextTokens
        self.deviceIdentifier = try validatedText(deviceIdentifier, field: "deviceIdentifier", maximumLength: 128)
        self.osBuild = try validatedText(osBuild, field: "osBuild", maximumLength: 128)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            modelID: values.decode(String.self, forKey: .modelID),
            modelRevision: values.decode(String.self, forKey: .modelRevision),
            tokenizerID: values.decode(String.self, forKey: .tokenizerID),
            tokenizerRevision: values.decode(String.self, forKey: .tokenizerRevision),
            runtimeID: values.decode(String.self, forKey: .runtimeID),
            runtimeRevision: values.decode(String.self, forKey: .runtimeRevision),
            weightQuantization: values.decode(String.self, forKey: .weightQuantization),
            keyCacheType: values.decode(String.self, forKey: .keyCacheType),
            valueCacheType: values.decode(String.self, forKey: .valueCacheType),
            contextTokens: values.decode(Int.self, forKey: .contextTokens),
            deviceIdentifier: values.decode(String.self, forKey: .deviceIdentifier),
            osBuild: values.decode(String.self, forKey: .osBuild)
        )
    }
}

public enum ForgeCompactThermalState: String, Codable, Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

public struct LocalRuntimeQualificationEvidence: Hashable, Codable, Sendable {
    public let profile: LocalRuntimeProfileIdentity
    public let evidenceRevision: String
    public let observedAt: Date
    public let loadSucceeded: Bool
    public let completedWithoutTermination: Bool
    public let localOnlyNetworkAuditPassed: Bool
    public let peakResidentMemoryBytes: UInt64
    public let timeToFirstTokenMilliseconds: Double
    public let promptTokensPerSecond: Double
    public let decodeTokensPerSecond: Double
    public let thermalState: ForgeCompactThermalState
    public let taskSuiteID: String
    public let taskCaseCount: Int
    public let taskPassedCount: Int

    public init(
        profile: LocalRuntimeProfileIdentity,
        evidenceRevision: String,
        observedAt: Date,
        loadSucceeded: Bool,
        completedWithoutTermination: Bool,
        localOnlyNetworkAuditPassed: Bool,
        peakResidentMemoryBytes: UInt64,
        timeToFirstTokenMilliseconds: Double,
        promptTokensPerSecond: Double,
        decodeTokensPerSecond: Double,
        thermalState: ForgeCompactThermalState,
        taskSuiteID: String,
        taskCaseCount: Int,
        taskPassedCount: Int
    ) throws {
        guard peakResidentMemoryBytes > 0 else {
            throw ForgeCompactValidationError.invalidMetric("peakResidentMemoryBytes")
        }
        guard timeToFirstTokenMilliseconds.isFinite, timeToFirstTokenMilliseconds > 0 else {
            throw ForgeCompactValidationError.invalidMetric("timeToFirstTokenMilliseconds")
        }
        guard promptTokensPerSecond.isFinite, promptTokensPerSecond > 0 else {
            throw ForgeCompactValidationError.invalidMetric("promptTokensPerSecond")
        }
        guard decodeTokensPerSecond.isFinite, decodeTokensPerSecond > 0 else {
            throw ForgeCompactValidationError.invalidMetric("decodeTokensPerSecond")
        }
        guard taskCaseCount > 0, taskPassedCount >= 0, taskPassedCount <= taskCaseCount else {
            throw ForgeCompactValidationError.invalidMetric("taskSuiteResults")
        }

        self.profile = profile
        self.evidenceRevision = try validatedText(evidenceRevision, field: "evidenceRevision")
        self.observedAt = observedAt
        self.loadSucceeded = loadSucceeded
        self.completedWithoutTermination = completedWithoutTermination
        self.localOnlyNetworkAuditPassed = localOnlyNetworkAuditPassed
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.promptTokensPerSecond = promptTokensPerSecond
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.thermalState = thermalState
        self.taskSuiteID = try validatedText(taskSuiteID, field: "taskSuiteID")
        self.taskCaseCount = taskCaseCount
        self.taskPassedCount = taskPassedCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            profile: values.decode(LocalRuntimeProfileIdentity.self, forKey: .profile),
            evidenceRevision: values.decode(String.self, forKey: .evidenceRevision),
            observedAt: values.decode(Date.self, forKey: .observedAt),
            loadSucceeded: values.decode(Bool.self, forKey: .loadSucceeded),
            completedWithoutTermination: values.decode(Bool.self, forKey: .completedWithoutTermination),
            localOnlyNetworkAuditPassed: values.decode(Bool.self, forKey: .localOnlyNetworkAuditPassed),
            peakResidentMemoryBytes: values.decode(UInt64.self, forKey: .peakResidentMemoryBytes),
            timeToFirstTokenMilliseconds: values.decode(Double.self, forKey: .timeToFirstTokenMilliseconds),
            promptTokensPerSecond: values.decode(Double.self, forKey: .promptTokensPerSecond),
            decodeTokensPerSecond: values.decode(Double.self, forKey: .decodeTokensPerSecond),
            thermalState: values.decode(ForgeCompactThermalState.self, forKey: .thermalState),
            taskSuiteID: values.decode(String.self, forKey: .taskSuiteID),
            taskCaseCount: values.decode(Int.self, forKey: .taskCaseCount),
            taskPassedCount: values.decode(Int.self, forKey: .taskPassedCount)
        )
    }
}

public struct QualifiedLocalRuntimeProfile: Hashable, Codable, Sendable {
    public let evidence: LocalRuntimeQualificationEvidence
    public let acceptanceID: String

    public init(evidence: LocalRuntimeQualificationEvidence, acceptanceID: String) throws {
        guard evidence.loadSucceeded else {
            throw ForgeCompactValidationError.invalidQualification("load did not succeed")
        }
        guard evidence.completedWithoutTermination else {
            throw ForgeCompactValidationError.invalidQualification("runtime did not complete without termination")
        }
        guard evidence.localOnlyNetworkAuditPassed else {
            throw ForgeCompactValidationError.invalidQualification("local-only network audit did not pass")
        }
        guard evidence.thermalState != .unknown else {
            throw ForgeCompactValidationError.invalidQualification("thermal state was not observed")
        }
        self.evidence = evidence
        self.acceptanceID = try validatedText(acceptanceID, field: "acceptanceID")
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            evidence: values.decode(LocalRuntimeQualificationEvidence.self, forKey: .evidence),
            acceptanceID: values.decode(String.self, forKey: .acceptanceID)
        )
    }

    public var profile: LocalRuntimeProfileIdentity { evidence.profile }
}

public enum LocalAIMemoryPressureOutcome: String, Codable, Hashable, Sendable {
    case none
    case warning
    case critical
    case terminated
}

public enum LocalAIThermalState: String, Codable, Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unavailable
}

public struct LocalAIMeasurements: Codable, Hashable, Sendable {
    public let coldLoadMilliseconds: Double
    public let timeToFirstTokenMilliseconds: Double
    public let prefillTokensPerSecond: Double
    public let decodeTokensPerSecond: Double
    public let peakResidentMemoryBytes: UInt64
    public let observedContextTokens: Int
    public let memoryPressure: LocalAIMemoryPressureOutcome
    public let thermalStart: LocalAIThermalState
    public let thermalEnd: LocalAIThermalState
    public let energyJoules: Double?

    public init(
        coldLoadMilliseconds: Double,
        timeToFirstTokenMilliseconds: Double,
        prefillTokensPerSecond: Double,
        decodeTokensPerSecond: Double,
        peakResidentMemoryBytes: UInt64,
        observedContextTokens: Int,
        memoryPressure: LocalAIMemoryPressureOutcome,
        thermalStart: LocalAIThermalState,
        thermalEnd: LocalAIThermalState,
        energyJoules: Double?
    ) throws {
        let finitePositive: [(String, Double)] = [
            ("coldLoadMilliseconds", coldLoadMilliseconds),
            ("timeToFirstTokenMilliseconds", timeToFirstTokenMilliseconds),
            ("prefillTokensPerSecond", prefillTokensPerSecond),
            ("decodeTokensPerSecond", decodeTokensPerSecond),
        ]
        for (name, value) in finitePositive where !value.isFinite || value <= 0 {
            throw LocalAIQualificationError.invalidMetric(name)
        }
        guard peakResidentMemoryBytes > 0 else {
            throw LocalAIQualificationError.invalidMetric("peakResidentMemoryBytes")
        }
        guard observedContextTokens > 0 else {
            throw LocalAIQualificationError.invalidMetric("observedContextTokens")
        }
        if let energyJoules, !energyJoules.isFinite || energyJoules <= 0 {
            throw LocalAIQualificationError.invalidMetric("energyJoules")
        }
        self.coldLoadMilliseconds = coldLoadMilliseconds
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.observedContextTokens = observedContextTokens
        self.memoryPressure = memoryPressure
        self.thermalStart = thermalStart
        self.thermalEnd = thermalEnd
        self.energyJoules = energyJoules
    }

    private enum CodingKeys: String, CodingKey {
        case coldLoadMilliseconds, timeToFirstTokenMilliseconds, prefillTokensPerSecond, decodeTokensPerSecond
        case peakResidentMemoryBytes, observedContextTokens, memoryPressure, thermalStart, thermalEnd, energyJoules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            coldLoadMilliseconds: container.decode(Double.self, forKey: .coldLoadMilliseconds),
            timeToFirstTokenMilliseconds: container.decode(Double.self, forKey: .timeToFirstTokenMilliseconds),
            prefillTokensPerSecond: container.decode(Double.self, forKey: .prefillTokensPerSecond),
            decodeTokensPerSecond: container.decode(Double.self, forKey: .decodeTokensPerSecond),
            peakResidentMemoryBytes: container.decode(UInt64.self, forKey: .peakResidentMemoryBytes),
            observedContextTokens: container.decode(Int.self, forKey: .observedContextTokens),
            memoryPressure: container.decode(LocalAIMemoryPressureOutcome.self, forKey: .memoryPressure),
            thermalStart: container.decode(LocalAIThermalState.self, forKey: .thermalStart),
            thermalEnd: container.decode(LocalAIThermalState.self, forKey: .thermalEnd),
            energyJoules: container.decodeIfPresent(Double.self, forKey: .energyJoules)
        )
    }
}

public enum LocalAITaskOutcome: String, Codable, Hashable, Sendable {
    case passed
    case failed
}

public struct LocalAITaskResult: Codable, Hashable, Sendable {
    public let taskID: String
    public let outcome: LocalAITaskOutcome

    public init(taskID: String, outcome: LocalAITaskOutcome) throws {
        self.taskID = try validatedIdentifier(taskID, field: "taskID")
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey { case taskID, outcome }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            taskID: container.decode(String.self, forKey: .taskID),
            outcome: container.decode(LocalAITaskOutcome.self, forKey: .outcome)
        )
    }
}

public struct LocalAITaskSuiteReceipt: Codable, Hashable, Sendable {
    public let suiteID: String
    public let suiteRevision: String
    public let results: [LocalAITaskResult]

    public init(suiteID: String, suiteRevision: String, results: [LocalAITaskResult]) throws {
        self.suiteID = try validatedIdentifier(suiteID, field: "suiteID")
        self.suiteRevision = try validatedIdentifier(suiteRevision, field: "suiteRevision")
        guard !results.isEmpty else { throw LocalAIQualificationError.invalidTaskSuite }
        var seen = Set<String>()
        for result in results where !seen.insert(result.taskID).inserted {
            throw LocalAIQualificationError.duplicateTaskID(result.taskID)
        }
        self.results = results.sorted { $0.taskID < $1.taskID }
    }

    public var allPassed: Bool { results.allSatisfy { $0.outcome == .passed } }

    private enum CodingKeys: String, CodingKey { case suiteID, suiteRevision, results }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            suiteID: container.decode(String.self, forKey: .suiteID),
            suiteRevision: container.decode(String.self, forKey: .suiteRevision),
            results: container.decode([LocalAITaskResult].self, forKey: .results)
        )
    }
}

public enum LocalAINetworkAudit: String, Codable, Hashable, Sendable {
    case noExternalAccessObserved
    case externalAccessObserved
    case notMeasured
}

public enum LocalAILocalityPolicy: String, Codable, Hashable, Sendable {
    case localOnly
    case networkAllowed
}

public struct LocalAIQualificationReceipt: Codable, Hashable, Sendable {
    public let profile: LocalAIExactProfile
    public let evidenceRevision: Int
    public let measurements: LocalAIMeasurements
    public let taskSuite: LocalAITaskSuiteReceipt
    public let localityPolicy: LocalAILocalityPolicy
    public let networkAudit: LocalAINetworkAudit

    public init(
        profile: LocalAIExactProfile,
        evidenceRevision: Int,
        measurements: LocalAIMeasurements,
        taskSuite: LocalAITaskSuiteReceipt,
        localityPolicy: LocalAILocalityPolicy,
        networkAudit: LocalAINetworkAudit
    ) throws {
        guard evidenceRevision > 0 else {
            throw LocalAIQualificationError.invalidMetric("evidenceRevision")
        }
        guard measurements.observedContextTokens <= profile.runtime.contextTokens else {
            throw LocalAIQualificationError.invalidMetric("observedContextTokens")
        }
        self.profile = profile
        self.evidenceRevision = evidenceRevision
        self.measurements = measurements
        self.taskSuite = taskSuite
        self.localityPolicy = localityPolicy
        self.networkAudit = networkAudit
    }

    private enum CodingKeys: String, CodingKey {
        case profile, evidenceRevision, measurements, taskSuite, localityPolicy, networkAudit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            profile: container.decode(LocalAIExactProfile.self, forKey: .profile),
            evidenceRevision: container.decode(Int.self, forKey: .evidenceRevision),
            measurements: container.decode(LocalAIMeasurements.self, forKey: .measurements),
            taskSuite: container.decode(LocalAITaskSuiteReceipt.self, forKey: .taskSuite),
            localityPolicy: container.decode(LocalAILocalityPolicy.self, forKey: .localityPolicy),
            networkAudit: container.decode(LocalAINetworkAudit.self, forKey: .networkAudit)
        )
    }
}

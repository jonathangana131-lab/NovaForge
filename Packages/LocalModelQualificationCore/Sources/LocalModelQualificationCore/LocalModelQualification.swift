import Foundation

public enum LocalModelQualificationError: Error, Equatable, Sendable {
    case invalidField(String)
    case invalidSHA256
    case invalidExecutionBudget
    case invalidMeasurement
    case invalidTaskSuite
    case evidenceSubjectMismatch
    case evidenceSourceMismatch
    case invalidEvidencePayload
    case duplicateEvidenceID(String)
    case duplicateEvidenceClass(LocalModelEvidenceClass)
    case invalidRecordRevision
    case unsupportedArchiveSchema(Int)
    case duplicateArchiveRecord
}

private enum QualificationValidation {
    static func text(_ value: String, field: String, maxLength: Int = 192) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else {
            throw LocalModelQualificationError.invalidField(field)
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LocalModelQualificationError.invalidField(field)
        }
        return trimmed
    }

    static func sha256(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64,
              normalized.unicodeScalars.allSatisfy({ scalar in
                  ("0"..."9").contains(Character(scalar)) || ("a"..."f").contains(Character(scalar))
              })
        else {
            throw LocalModelQualificationError.invalidSHA256
        }
        return normalized
    }

    static func positiveFinite(_ value: Double) -> Bool {
        value.isFinite && value > 0
    }
}

public enum LocalExecutionEnvironment: String, Codable, Hashable, Sendable {
    case physicalDevice
    case simulator
}

public enum LocalModelEvidenceSource: String, Codable, Hashable, Sendable {
    case physicalDevice
    case simulator
    case staticAnalysis
}

public enum LocalModelEvidenceAuthority: String, Codable, Hashable, Sendable {
    /// Produced by a deterministic NovaForge or independently controlled qualification harness.
    case deterministicHarness
    /// Useful research evidence that remains non-promoting until reproduced by a deterministic harness.
    case manualObservation
    /// Model/provider-authored prose or self-report. Never qualifies a product support claim.
    case modelReported
}

public enum LocalModelEvidenceStatus: String, Codable, Hashable, Sendable {
    case passed
    case failed
}

public enum LocalModelEvidenceClass: String, Codable, CaseIterable, Hashable, Sendable {
    case artifactIntegrity
    case modelLoad
    case firstToken
    case throughput
    case memory
    case thermal
    case taskSuite
    case localOnlyNetworkAudit
}

public enum LocalModelThermalState: String, Codable, Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

public enum LocalModelMemoryPressure: String, Codable, Hashable, Sendable {
    case nominal
    case warning
    case critical
    case terminated
    case unknown
}

public struct LocalModelArtifactIdentity: Codable, Hashable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let tokenizerID: String
    public let tokenizerRevision: String
    public let artifactSHA256: String

    public init(
        modelID: String,
        modelRevision: String,
        tokenizerID: String,
        tokenizerRevision: String,
        artifactSHA256: String
    ) throws {
        self.modelID = try QualificationValidation.text(modelID, field: "modelID")
        self.modelRevision = try QualificationValidation.text(modelRevision, field: "modelRevision")
        self.tokenizerID = try QualificationValidation.text(tokenizerID, field: "tokenizerID")
        self.tokenizerRevision = try QualificationValidation.text(tokenizerRevision, field: "tokenizerRevision")
        self.artifactSHA256 = try QualificationValidation.sha256(artifactSHA256)
    }

    fileprivate func revalidated() throws -> Self {
        try .init(
            modelID: modelID,
            modelRevision: modelRevision,
            tokenizerID: tokenizerID,
            tokenizerRevision: tokenizerRevision,
            artifactSHA256: artifactSHA256
        )
    }
}

public struct LocalModelRuntimeIdentity: Codable, Hashable, Sendable {
    public let runtimeID: String
    public let runtimeRevision: String
    public let backend: String

    public init(runtimeID: String, runtimeRevision: String, backend: String) throws {
        self.runtimeID = try QualificationValidation.text(runtimeID, field: "runtimeID")
        self.runtimeRevision = try QualificationValidation.text(runtimeRevision, field: "runtimeRevision")
        self.backend = try QualificationValidation.text(backend, field: "backend", maxLength: 80)
    }

    fileprivate func revalidated() throws -> Self {
        try .init(runtimeID: runtimeID, runtimeRevision: runtimeRevision, backend: backend)
    }
}

public struct LocalModelExecutionProfile: Codable, Hashable, Sendable {
    public let quantization: String
    public let keyCacheType: String
    public let valueCacheType: String
    public let contextTokens: Int
    public let batchTokens: Int

    public init(
        quantization: String,
        keyCacheType: String,
        valueCacheType: String,
        contextTokens: Int,
        batchTokens: Int
    ) throws {
        self.quantization = try QualificationValidation.text(quantization, field: "quantization", maxLength: 80)
        self.keyCacheType = try QualificationValidation.text(keyCacheType, field: "keyCacheType", maxLength: 80)
        self.valueCacheType = try QualificationValidation.text(valueCacheType, field: "valueCacheType", maxLength: 80)
        guard contextTokens > 0, contextTokens <= 10_000_000,
              batchTokens > 0, batchTokens <= contextTokens
        else {
            throw LocalModelQualificationError.invalidExecutionBudget
        }
        self.contextTokens = contextTokens
        self.batchTokens = batchTokens
    }

    fileprivate func revalidated() throws -> Self {
        try .init(
            quantization: quantization,
            keyCacheType: keyCacheType,
            valueCacheType: valueCacheType,
            contextTokens: contextTokens,
            batchTokens: batchTokens
        )
    }
}

public struct LocalDeviceIdentity: Codable, Hashable, Sendable {
    public let environment: LocalExecutionEnvironment
    public let hardwareIdentifier: String
    public let marketingName: String
    public let chip: String
    public let osVersion: String
    public let osBuild: String

    public init(
        environment: LocalExecutionEnvironment,
        hardwareIdentifier: String,
        marketingName: String,
        chip: String,
        osVersion: String,
        osBuild: String
    ) throws {
        self.environment = environment
        self.hardwareIdentifier = try QualificationValidation.text(hardwareIdentifier, field: "hardwareIdentifier", maxLength: 96)
        self.marketingName = try QualificationValidation.text(marketingName, field: "marketingName", maxLength: 96)
        self.chip = try QualificationValidation.text(chip, field: "chip", maxLength: 96)
        self.osVersion = try QualificationValidation.text(osVersion, field: "osVersion", maxLength: 96)
        self.osBuild = try QualificationValidation.text(osBuild, field: "osBuild", maxLength: 96)
    }

    fileprivate func revalidated() throws -> Self {
        try .init(
            environment: environment,
            hardwareIdentifier: hardwareIdentifier,
            marketingName: marketingName,
            chip: chip,
            osVersion: osVersion,
            osBuild: osBuild
        )
    }
}

/// The exact subject of a qualification result. Changing model/tokenizer/runtime/quant/KV/context/device/OS
/// creates a different subject and prevents evidence reuse across the boundary.
public struct LocalModelQualificationSubject: Codable, Hashable, Sendable {
    public let artifact: LocalModelArtifactIdentity
    public let runtime: LocalModelRuntimeIdentity
    public let execution: LocalModelExecutionProfile
    public let device: LocalDeviceIdentity

    public init(
        artifact: LocalModelArtifactIdentity,
        runtime: LocalModelRuntimeIdentity,
        execution: LocalModelExecutionProfile,
        device: LocalDeviceIdentity
    ) throws {
        self.artifact = try artifact.revalidated()
        self.runtime = try runtime.revalidated()
        self.execution = try execution.revalidated()
        self.device = try device.revalidated()
    }

    fileprivate func revalidated() throws -> Self {
        try .init(artifact: artifact, runtime: runtime, execution: execution, device: device)
    }
}

public struct LocalModelPerformanceMeasurement: Codable, Hashable, Sendable {
    public let promptTokens: Int
    public let generatedTokens: Int
    public let timeToFirstTokenMilliseconds: Double
    public let prefillTokensPerSecond: Double
    public let decodeTokensPerSecond: Double
    public let peakResidentBytes: UInt64
    public let peakKVCacheBytes: UInt64?
    public let energyJoules: Double?
    public let peakMemoryPressure: LocalModelMemoryPressure

    public init(
        promptTokens: Int,
        generatedTokens: Int,
        timeToFirstTokenMilliseconds: Double,
        prefillTokensPerSecond: Double,
        decodeTokensPerSecond: Double,
        peakResidentBytes: UInt64,
        peakKVCacheBytes: UInt64? = nil,
        energyJoules: Double? = nil,
        peakMemoryPressure: LocalModelMemoryPressure
    ) throws {
        guard promptTokens > 0,
              generatedTokens > 0,
              QualificationValidation.positiveFinite(timeToFirstTokenMilliseconds),
              QualificationValidation.positiveFinite(prefillTokensPerSecond),
              QualificationValidation.positiveFinite(decodeTokensPerSecond),
              peakResidentBytes > 0,
              peakKVCacheBytes.map({ $0 > 0 }) ?? true,
              energyJoules.map({ $0.isFinite && $0 >= 0 }) ?? true
        else {
            throw LocalModelQualificationError.invalidMeasurement
        }
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.peakResidentBytes = peakResidentBytes
        self.peakKVCacheBytes = peakKVCacheBytes
        self.energyJoules = energyJoules
        self.peakMemoryPressure = peakMemoryPressure
    }

    fileprivate func revalidated() throws -> Self {
        try .init(
            promptTokens: promptTokens,
            generatedTokens: generatedTokens,
            timeToFirstTokenMilliseconds: timeToFirstTokenMilliseconds,
            prefillTokensPerSecond: prefillTokensPerSecond,
            decodeTokensPerSecond: decodeTokensPerSecond,
            peakResidentBytes: peakResidentBytes,
            peakKVCacheBytes: peakKVCacheBytes,
            energyJoules: energyJoules,
            peakMemoryPressure: peakMemoryPressure
        )
    }
}

public struct LocalModelTaskSuiteResult: Codable, Hashable, Sendable {
    public let suiteID: String
    public let suiteRevision: String
    public let attempted: Int
    public let passed: Int

    public init(suiteID: String, suiteRevision: String, attempted: Int, passed: Int) throws {
        self.suiteID = try QualificationValidation.text(suiteID, field: "suiteID")
        self.suiteRevision = try QualificationValidation.text(suiteRevision, field: "suiteRevision")
        guard attempted > 0, passed >= 0, passed <= attempted else {
            throw LocalModelQualificationError.invalidTaskSuite
        }
        self.attempted = attempted
        self.passed = passed
    }

    public var passRate: Double {
        Double(passed) / Double(attempted)
    }

    fileprivate func revalidated() throws -> Self {
        try .init(suiteID: suiteID, suiteRevision: suiteRevision, attempted: attempted, passed: passed)
    }
}

public enum LocalModelEvidencePayload: Codable, Hashable, Sendable {
    case none
    case performance(LocalModelPerformanceMeasurement)
    case thermal(LocalModelThermalState)
    case taskSuite(LocalModelTaskSuiteResult)
    case localOnlyAudit(receiptID: String)

    fileprivate func revalidated() throws -> Self {
        switch self {
        case .none:
            return .none
        case .performance(let measurement):
            return .performance(try measurement.revalidated())
        case .thermal(let state):
            return .thermal(state)
        case .taskSuite(let result):
            return .taskSuite(try result.revalidated())
        case .localOnlyAudit(let receiptID):
            return .localOnlyAudit(
                receiptID: try QualificationValidation.text(receiptID, field: "localOnlyAuditReceiptID")
            )
        }
    }
}

public struct LocalModelQualificationEvidence: Codable, Hashable, Sendable {
    public let evidenceID: String
    public let subject: LocalModelQualificationSubject
    public let evidenceClass: LocalModelEvidenceClass
    public let source: LocalModelEvidenceSource
    public let authority: LocalModelEvidenceAuthority
    public let status: LocalModelEvidenceStatus
    public let payload: LocalModelEvidencePayload

    public init(
        evidenceID: String,
        subject: LocalModelQualificationSubject,
        evidenceClass: LocalModelEvidenceClass,
        source: LocalModelEvidenceSource,
        authority: LocalModelEvidenceAuthority,
        status: LocalModelEvidenceStatus,
        payload: LocalModelEvidencePayload
    ) throws {
        self.evidenceID = try QualificationValidation.text(evidenceID, field: "evidenceID")
        self.subject = try subject.revalidated()
        self.evidenceClass = evidenceClass
        self.source = source
        self.authority = authority
        self.status = status
        self.payload = try payload.revalidated()

        switch source {
        case .physicalDevice:
            guard self.subject.device.environment == .physicalDevice else {
                throw LocalModelQualificationError.evidenceSourceMismatch
            }
        case .simulator:
            guard self.subject.device.environment == .simulator else {
                throw LocalModelQualificationError.evidenceSourceMismatch
            }
        case .staticAnalysis:
            guard evidenceClass == .artifactIntegrity else {
                throw LocalModelQualificationError.evidenceSourceMismatch
            }
        }

        switch (evidenceClass, self.payload) {
        case (.artifactIntegrity, .none),
             (.modelLoad, .none),
             (.firstToken, .performance),
             (.throughput, .performance),
             (.memory, .performance),
             (.thermal, .thermal),
             (.taskSuite, .taskSuite),
             (.localOnlyNetworkAudit, .localOnlyAudit):
            break
        default:
            throw LocalModelQualificationError.invalidEvidencePayload
        }
    }

    fileprivate func revalidated() throws -> Self {
        try .init(
            evidenceID: evidenceID,
            subject: subject,
            evidenceClass: evidenceClass,
            source: source,
            authority: authority,
            status: status,
            payload: payload
        )
    }
}

public enum LocalModelQualificationClaim: String, Codable, Hashable, Sendable {
    /// Exact artifact bytes/revision/tokenizer identity were deterministically verified.
    case artifactVerified
    /// This exact runtime/profile/device/OS combination has deterministic physical-device runtime evidence.
    case deviceRuntimeQualified
    /// Device runtime qualification plus a deterministic local-only network audit.
    case localOnlyDeviceQualified
}

public struct LocalModelQualificationReadiness: Codable, Equatable, Sendable {
    public let claim: LocalModelQualificationClaim
    public let isQualified: Bool
    public let blockingReasons: [String]

    public init(claim: LocalModelQualificationClaim, blockingReasons: [String]) {
        self.claim = claim
        self.blockingReasons = blockingReasons
        self.isQualified = blockingReasons.isEmpty
    }
}

/// Current evidence snapshot for one exact qualification subject.
/// Only one receipt per evidence class is accepted, so an older failed result cannot be hidden behind a second pass.
public struct LocalModelQualificationRecord: Codable, Hashable, Sendable {
    public let revision: Int
    public let subject: LocalModelQualificationSubject
    public let evidence: [LocalModelQualificationEvidence]

    public init(
        revision: Int,
        subject: LocalModelQualificationSubject,
        evidence: [LocalModelQualificationEvidence]
    ) throws {
        guard revision > 0 else {
            throw LocalModelQualificationError.invalidRecordRevision
        }
        self.revision = revision
        self.subject = try subject.revalidated()

        var ids = Set<String>()
        var classes = Set<LocalModelEvidenceClass>()
        var validated: [LocalModelQualificationEvidence] = []
        validated.reserveCapacity(evidence.count)

        for rawReceipt in evidence {
            let receipt = try rawReceipt.revalidated()
            guard receipt.subject == self.subject else {
                throw LocalModelQualificationError.evidenceSubjectMismatch
            }
            guard ids.insert(receipt.evidenceID).inserted else {
                throw LocalModelQualificationError.duplicateEvidenceID(receipt.evidenceID)
            }
            guard classes.insert(receipt.evidenceClass).inserted else {
                throw LocalModelQualificationError.duplicateEvidenceClass(receipt.evidenceClass)
            }
            validated.append(receipt)
        }

        self.evidence = validated.sorted {
            if $0.evidenceClass.rawValue == $1.evidenceClass.rawValue {
                return $0.evidenceID < $1.evidenceID
            }
            return $0.evidenceClass.rawValue < $1.evidenceClass.rawValue
        }
    }

    /// Evaluates a claim only against receipt IDs independently trusted by the host qualification boundary.
    /// Persisted/model-authored JSON cannot promote itself merely by spelling `deterministicHarness`.
    public func readiness(
        for claim: LocalModelQualificationClaim,
        trustedEvidence: Set<LocalModelQualificationEvidence>
    ) -> LocalModelQualificationReadiness {
        var reasons: [String] = []

        func receipt(for evidenceClass: LocalModelEvidenceClass) -> LocalModelQualificationEvidence? {
            evidence.first { $0.evidenceClass == evidenceClass }
        }

        func require(
            _ evidenceClass: LocalModelEvidenceClass,
            physicalDevice: Bool,
            deterministicHarness: Bool
        ) {
            guard let item = receipt(for: evidenceClass) else {
                reasons.append("Missing \(evidenceClass.rawValue) evidence.")
                return
            }
            if !trustedEvidence.contains(item) {
                reasons.append("\(evidenceClass.rawValue) evidence is not trusted by the host qualification boundary.")
            }
            if item.status != .passed {
                reasons.append("\(evidenceClass.rawValue) evidence did not pass.")
            }
            if physicalDevice && item.source != .physicalDevice {
                reasons.append("\(evidenceClass.rawValue) must be reproduced on the exact physical device.")
            }
            if deterministicHarness && item.authority != .deterministicHarness {
                reasons.append("\(evidenceClass.rawValue) is not deterministic-harness evidence.")
            }
        }

        switch claim {
        case .artifactVerified:
            require(.artifactIntegrity, physicalDevice: false, deterministicHarness: true)

        case .deviceRuntimeQualified, .localOnlyDeviceQualified:
            if subject.device.environment != .physicalDevice {
                reasons.append("Qualification subject is a Simulator, not a physical device.")
            }
            require(.artifactIntegrity, physicalDevice: false, deterministicHarness: true)
            require(.modelLoad, physicalDevice: true, deterministicHarness: true)
            require(.firstToken, physicalDevice: true, deterministicHarness: true)
            require(.throughput, physicalDevice: true, deterministicHarness: true)
            require(.memory, physicalDevice: true, deterministicHarness: true)
            require(.thermal, physicalDevice: true, deterministicHarness: true)
            require(.taskSuite, physicalDevice: true, deterministicHarness: true)

            if claim == .localOnlyDeviceQualified {
                require(.localOnlyNetworkAudit, physicalDevice: true, deterministicHarness: true)
            }
        }

        return .init(claim: claim, blockingReasons: reasons)
    }

    fileprivate func revalidated() throws -> Self {
        try .init(revision: revision, subject: subject, evidence: evidence)
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case subject
        case evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let revision = try container.decode(Int.self, forKey: .revision)
        let subject = try container.decode(LocalModelQualificationSubject.self, forKey: .subject)
        let evidence = try container.decode([LocalModelQualificationEvidence].self, forKey: .evidence)
        self = try .init(revision: revision, subject: subject, evidence: evidence)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(subject, forKey: .subject)
        try container.encode(evidence, forKey: .evidence)
    }
}

/// Versioned durable envelope. Decode always re-enters record/domain validation.
public struct LocalModelQualificationArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let records: [LocalModelQualificationRecord]

    public init(records: [LocalModelQualificationRecord]) throws {
        self.schemaVersion = Self.currentSchemaVersion

        var keys = Set<RecordKey>()
        var validated: [LocalModelQualificationRecord] = []
        validated.reserveCapacity(records.count)
        for rawRecord in records {
            let record = try rawRecord.revalidated()
            let key = RecordKey(subject: record.subject, revision: record.revision)
            guard keys.insert(key).inserted else {
                throw LocalModelQualificationError.duplicateArchiveRecord
            }
            validated.append(record)
        }
        self.records = validated.sorted(by: Self.canonicalRecordOrder)
    }

    private struct RecordKey: Hashable {
        let subject: LocalModelQualificationSubject
        let revision: Int
    }

    private static func canonicalRecordOrder(
        _ lhs: LocalModelQualificationRecord,
        _ rhs: LocalModelQualificationRecord
    ) -> Bool {
        let left = canonicalSubjectKey(lhs.subject)
        let right = canonicalSubjectKey(rhs.subject)
        if left == right { return lhs.revision < rhs.revision }
        return left < right
    }

    private static func canonicalSubjectKey(_ subject: LocalModelQualificationSubject) -> String {
        [
            subject.artifact.modelID,
            subject.artifact.modelRevision,
            subject.artifact.tokenizerID,
            subject.artifact.tokenizerRevision,
            subject.artifact.artifactSHA256,
            subject.runtime.runtimeID,
            subject.runtime.runtimeRevision,
            subject.runtime.backend,
            subject.execution.quantization,
            subject.execution.keyCacheType,
            subject.execution.valueCacheType,
            String(subject.execution.contextTokens),
            String(subject.execution.batchTokens),
            subject.device.environment.rawValue,
            subject.device.hardwareIdentifier,
            subject.device.marketingName,
            subject.device.chip,
            subject.device.osVersion,
            subject.device.osBuild,
        ].joined(separator: "\u{1f}")
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case records
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw LocalModelQualificationError.unsupportedArchiveSchema(schemaVersion)
        }
        let records = try container.decode([LocalModelQualificationRecord].self, forKey: .records)
        self = try .init(records: records)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(records, forKey: .records)
    }
}

import Foundation

/// Thermal state captured with an exact local-model qualification run. These values
/// intentionally mirror the semantic severity of ProcessInfo.ThermalState without
/// persisting an Apple framework type into the domain archive.
public enum LocalModelQualificationThermalState: String, Codable, Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

/// A network audit is separate from ordinary inference success. Local-only product
/// promotion may require an explicit pass; missing evidence must never be treated as pass.
public enum LocalModelQualificationNetworkAudit: String, Codable, Hashable, Sendable {
    case notRun
    case passed
    case failed
}

public enum LocalModelQualificationValidationIssue: String, Codable, Hashable, Sendable {
    case unsupportedSchemaVersion
    case invalidIdentity
    case nonCanonicalArtifactDigest
    case invalidContextBudget
    case invalidMetrics
    case invalidTaskSuite
}

public enum LocalModelQualificationDecisionReason: String, Codable, Hashable, Sendable {
    case measuredCompatibilityEvidenceMissing
    case qualificationMissing
    case qualificationInvalid
    case qualificationIdentityMismatch
    case localOnlyAuditMissing
    case localOnlyAuditFailed
}

/// Exact execution identity for one measured local-model profile.
///
/// A V14 compatibility/performance receipt is only reusable when every field matches.
/// This prevents a benchmark from silently crossing tokenizer/template changes, runtime
/// revisions, Metal/CPU backends, KV precision, context size, device hardware, or OS builds.
public struct LocalModelRuntimeQualificationIdentity: Codable, Equatable, Hashable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let artifactID: String
    public let artifactSHA256: String
    public let quantization: String
    public let tokenizerID: String
    public let tokenizerRevision: String
    public let promptTemplateID: String
    public let promptTemplateRevision: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let backendID: String
    public let kvCacheKeyType: String
    public let kvCacheValueType: String
    public let contextTokens: UInt64
    public let deviceProfileID: String
    public let deviceModelIdentifier: String
    public let osVersion: String
    public let osBuild: String

    public init(
        modelID: String,
        modelRevision: String,
        artifactID: String,
        artifactSHA256: String,
        quantization: String,
        tokenizerID: String,
        tokenizerRevision: String,
        promptTemplateID: String,
        promptTemplateRevision: String,
        runtimeID: String,
        runtimeRevision: String,
        backendID: String,
        kvCacheKeyType: String,
        kvCacheValueType: String,
        contextTokens: UInt64,
        deviceProfileID: String,
        deviceModelIdentifier: String,
        osVersion: String,
        osBuild: String
    ) {
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.artifactID = artifactID
        self.artifactSHA256 = artifactSHA256
        self.quantization = quantization
        self.tokenizerID = tokenizerID
        self.tokenizerRevision = tokenizerRevision
        self.promptTemplateID = promptTemplateID
        self.promptTemplateRevision = promptTemplateRevision
        self.runtimeID = runtimeID
        self.runtimeRevision = runtimeRevision
        self.backendID = backendID
        self.kvCacheKeyType = kvCacheKeyType
        self.kvCacheValueType = kvCacheValueType
        self.contextTokens = contextTokens
        self.deviceProfileID = deviceProfileID
        self.deviceModelIdentifier = deviceModelIdentifier
        self.osVersion = osVersion
        self.osBuild = osBuild
    }

    public var validationIssues: [LocalModelQualificationValidationIssue] {
        var issues: [LocalModelQualificationValidationIssue] = []

        let requiredText = [
            modelID,
            modelRevision,
            artifactID,
            quantization,
            tokenizerID,
            tokenizerRevision,
            promptTemplateID,
            promptTemplateRevision,
            runtimeID,
            runtimeRevision,
            backendID,
            kvCacheKeyType,
            kvCacheValueType,
            deviceProfileID,
            deviceModelIdentifier,
            osVersion,
            osBuild,
        ]

        if requiredText.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            issues.append(.invalidIdentity)
        }

        if !Self.isCanonicalSHA256(artifactSHA256) {
            issues.append(.nonCanonicalArtifactDigest)
        }

        if contextTokens == 0 {
            issues.append(.invalidContextBudget)
        }

        return issues
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...102:
                true
            default:
                false
            }
        }
    }
}

/// Exact measured resource/performance facts for a qualification run. These are
/// observations, not generic device promises or catalog estimates.
public struct LocalModelRuntimeQualificationMetrics: Codable, Equatable, Sendable {
    public let peakResidentMemoryBytes: UInt64
    public let timeToFirstTokenMilliseconds: Double
    public let prefillTokensPerSecond: Double
    public let decodeTokensPerSecond: Double
    public let memoryPressureEvents: UInt16
    public let thermalStart: LocalModelQualificationThermalState
    public let thermalEnd: LocalModelQualificationThermalState

    public init(
        peakResidentMemoryBytes: UInt64,
        timeToFirstTokenMilliseconds: Double,
        prefillTokensPerSecond: Double,
        decodeTokensPerSecond: Double,
        memoryPressureEvents: UInt16,
        thermalStart: LocalModelQualificationThermalState,
        thermalEnd: LocalModelQualificationThermalState
    ) {
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.memoryPressureEvents = memoryPressureEvents
        self.thermalStart = thermalStart
        self.thermalEnd = thermalEnd
    }

    public var isValid: Bool {
        peakResidentMemoryBytes > 0
            && timeToFirstTokenMilliseconds.isFinite
            && timeToFirstTokenMilliseconds >= 0
            && prefillTokensPerSecond.isFinite
            && prefillTokensPerSecond > 0
            && decodeTokensPerSecond.isFinite
            && decodeTokensPerSecond > 0
    }
}

/// Reproducible NovaForge task-suite evidence carried alongside speed/memory results.
/// The contract records outcomes but deliberately does not invent a universal pass-rate
/// threshold; a higher-level qualification policy may decide what a given suite requires.
public struct LocalModelQualificationTaskSuite: Codable, Equatable, Sendable {
    public let suiteID: String
    public let suiteRevision: String
    public let totalTasks: UInt16
    public let passedTasks: UInt16
    public let failedTasks: UInt16
    public let toolCallAttempts: UInt16
    public let validToolCalls: UInt16
    public let structuredOutputAttempts: UInt16
    public let validStructuredOutputs: UInt16
    public let autonomousMissionAttempts: UInt16
    public let successfulAutonomousMissions: UInt16

    public init(
        suiteID: String,
        suiteRevision: String,
        totalTasks: UInt16,
        passedTasks: UInt16,
        failedTasks: UInt16,
        toolCallAttempts: UInt16,
        validToolCalls: UInt16,
        structuredOutputAttempts: UInt16,
        validStructuredOutputs: UInt16,
        autonomousMissionAttempts: UInt16,
        successfulAutonomousMissions: UInt16
    ) {
        self.suiteID = suiteID
        self.suiteRevision = suiteRevision
        self.totalTasks = totalTasks
        self.passedTasks = passedTasks
        self.failedTasks = failedTasks
        self.toolCallAttempts = toolCallAttempts
        self.validToolCalls = validToolCalls
        self.structuredOutputAttempts = structuredOutputAttempts
        self.validStructuredOutputs = validStructuredOutputs
        self.autonomousMissionAttempts = autonomousMissionAttempts
        self.successfulAutonomousMissions = successfulAutonomousMissions
    }

    public var isValid: Bool {
        !suiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !suiteRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && totalTasks > 0
            && UInt32(passedTasks) + UInt32(failedTasks) == UInt32(totalTasks)
            && validToolCalls <= toolCallAttempts
            && validStructuredOutputs <= structuredOutputAttempts
            && successfulAutonomousMissions <= autonomousMissionAttempts
    }
}

/// Durable exact-profile qualification evidence. Schema changes must fail closed at
/// the promotion gate rather than allowing older receipts to acquire newer meaning.
public struct LocalModelRuntimeQualificationReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let identity: LocalModelRuntimeQualificationIdentity
    public let measuredAt: AgentInstant
    public let metrics: LocalModelRuntimeQualificationMetrics
    public let taskSuite: LocalModelQualificationTaskSuite
    public let localOnlyNetworkAudit: LocalModelQualificationNetworkAudit

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        identity: LocalModelRuntimeQualificationIdentity,
        measuredAt: AgentInstant,
        metrics: LocalModelRuntimeQualificationMetrics,
        taskSuite: LocalModelQualificationTaskSuite,
        localOnlyNetworkAudit: LocalModelQualificationNetworkAudit
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.measuredAt = measuredAt
        self.metrics = metrics
        self.taskSuite = taskSuite
        self.localOnlyNetworkAudit = localOnlyNetworkAudit
    }

    public var validationIssues: [LocalModelQualificationValidationIssue] {
        var issues = identity.validationIssues

        if schemaVersion != Self.currentSchemaVersion {
            issues.append(.unsupportedSchemaVersion)
        }
        if !metrics.isValid {
            issues.append(.invalidMetrics)
        }
        if !taskSuite.isValid {
            issues.append(.invalidTaskSuite)
        }

        return Array(Set(issues)).sorted { $0.rawValue < $1.rawValue }
    }
}

/// Result used by a V14 Model Center adapter before it presents an existing measured
/// Excellent/Good/Slow label as applicable to the exact current runtime profile.
public struct LocalModelRuntimeQualificationDecision: Codable, Equatable, Sendable {
    public let effectiveLabel: LocalModelCompatibilityLabel
    public let canPresentMeasuredPerformanceLabel: Bool
    public let reasons: [LocalModelQualificationDecisionReason]

    public init(
        effectiveLabel: LocalModelCompatibilityLabel,
        canPresentMeasuredPerformanceLabel: Bool,
        reasons: [LocalModelQualificationDecisionReason]
    ) {
        self.effectiveLabel = effectiveLabel
        self.canPresentMeasuredPerformanceLabel = canPresentMeasuredPerformanceLabel
        self.reasons = reasons
    }
}

public enum LocalModelRuntimeQualificationGate {
    public static func evaluate(
        compatibility: LocalModelCompatibilityResult,
        expectedIdentity: LocalModelRuntimeQualificationIdentity,
        receipt: LocalModelRuntimeQualificationReceipt?,
        requiresPassedLocalOnlyNetworkAudit: Bool = false
    ) -> LocalModelRuntimeQualificationDecision {
        guard isMeasuredPerformanceLabel(compatibility.label) else {
            return .init(
                effectiveLabel: compatibility.label,
                canPresentMeasuredPerformanceLabel: false,
                reasons: []
            )
        }

        guard compatibility.hasMeasuredEvidence,
              compatibility.reasons.contains(.measuredPerformance),
              compatibility.evidence.contains(where: {
                  $0.kind == .measured && $0.code == "benchmark.generation_rate"
              })
        else {
            return demoted(.measuredCompatibilityEvidenceMissing)
        }

        guard let receipt else {
            return demoted(.qualificationMissing)
        }

        guard expectedIdentity.validationIssues.isEmpty,
              receipt.validationIssues.isEmpty
        else {
            return demoted(.qualificationInvalid)
        }

        guard receipt.identity == expectedIdentity else {
            return demoted(.qualificationIdentityMismatch)
        }

        if requiresPassedLocalOnlyNetworkAudit {
            switch receipt.localOnlyNetworkAudit {
            case .notRun:
                return demoted(.localOnlyAuditMissing)
            case .failed:
                return demoted(.localOnlyAuditFailed)
            case .passed:
                break
            }
        }

        return .init(
            effectiveLabel: compatibility.label,
            canPresentMeasuredPerformanceLabel: true,
            reasons: []
        )
    }

    private static func isMeasuredPerformanceLabel(_ label: LocalModelCompatibilityLabel) -> Bool {
        switch label {
        case .excellent, .good, .slow:
            true
        case .tooLarge, .untested, .unsupported:
            false
        }
    }

    private static func demoted(
        _ reason: LocalModelQualificationDecisionReason
    ) -> LocalModelRuntimeQualificationDecision {
        .init(
            effectiveLabel: .untested,
            canPresentMeasuredPerformanceLabel: false,
            reasons: [reason]
        )
    }
}

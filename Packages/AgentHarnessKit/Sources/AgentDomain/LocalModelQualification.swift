import Foundation

/// Where a local-model benchmark was actually executed.
///
/// Simulator and host runs are useful engineering evidence, but they cannot promote a
/// physical-device compatibility badge.
public enum LocalModelQualificationEnvironment: String, Codable, CaseIterable, Hashable, Sendable {
    case physicalDevice
    case simulator
    case host
}

/// Thermal state captured during an exact local-model qualification run.
public enum LocalModelQualificationThermalState: String, Codable, CaseIterable, Hashable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

/// Local-only qualification includes an explicit network-isolation audit rather than
/// assuming a local runtime stayed offline because the selected provider was named "Local".
public enum LocalModelNetworkIsolationAuditStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case passed
    case failed
    case notRun
}

/// Exact execution identity that makes a device observation reproducible.
///
/// A model family name, parameter count, or GGUF filename is deliberately insufficient.
/// The identity binds the tokenizer, runtime, KV profile, context size, concrete device,
/// OS build, and execution environment that produced the evidence.
public struct LocalModelQualificationIdentity: Codable, Equatable, Sendable {
    public let tokenizerID: String
    public let tokenizerRevision: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let kvCacheType: String
    public let contextTokens: UInt64
    public let hardwareIdentifier: String
    public let osVersion: String
    public let osBuild: String
    public let environment: LocalModelQualificationEnvironment

    public init(
        tokenizerID: String,
        tokenizerRevision: String,
        runtimeID: String,
        runtimeRevision: String,
        kvCacheType: String,
        contextTokens: UInt64,
        hardwareIdentifier: String,
        osVersion: String,
        osBuild: String,
        environment: LocalModelQualificationEnvironment
    ) {
        self.tokenizerID = tokenizerID
        self.tokenizerRevision = tokenizerRevision
        self.runtimeID = runtimeID
        self.runtimeRevision = runtimeRevision
        self.kvCacheType = kvCacheType
        self.contextTokens = contextTokens
        self.hardwareIdentifier = hardwareIdentifier
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.environment = environment
    }

    fileprivate var hasCompleteIdentity: Bool {
        contextTokens > 0
            && Self.isPresent(tokenizerID)
            && Self.isPresent(tokenizerRevision)
            && Self.isPresent(runtimeID)
            && Self.isPresent(runtimeRevision)
            && Self.isPresent(kvCacheType)
            && Self.isPresent(hardwareIdentifier)
            && Self.isPresent(osVersion)
            && Self.isPresent(osBuild)
    }

    private static func isPresent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Task-suite evidence is distinct from smoke-run stability. A speed measurement can be
/// perfectly valid while the model still fails the coding/tool tasks NovaForge needs.
public struct LocalModelTaskSuiteObservation: Codable, Equatable, Sendable {
    public let suiteID: String
    public let suiteRevision: String
    public let successfulCases: UInt32
    public let failedCases: UInt32

    public init(
        suiteID: String,
        suiteRevision: String,
        successfulCases: UInt32,
        failedCases: UInt32
    ) {
        self.suiteID = suiteID
        self.suiteRevision = suiteRevision
        self.successfulCases = successfulCases
        self.failedCases = failedCases
    }

    fileprivate var hasCompleteIdentity: Bool {
        !suiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !suiteRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    fileprivate var completedCases: UInt64 {
        UInt64(successfulCases) + UInt64(failedCases)
    }
}

/// Physical-device evidence required to promote a friendly compatibility badge.
///
/// This augments the existing `LocalModelBenchmarkObservation` instead of replacing it:
/// the benchmark remains the performance/stability observation while this receipt binds
/// the V14 execution identity, task-suite result, thermal state, and local-only audit.
public struct LocalModelQualificationReceipt: Codable, Equatable, Sendable {
    public let modelID: String
    public let revision: String
    public let artifactID: String
    public let artifactSHA256: String
    public let quantization: String?
    public let deviceProfileID: String
    public let measuredAt: AgentInstant
    public let identity: LocalModelQualificationIdentity
    public let peakMemoryBytes: UInt64
    public let generationTokensPerSecond: Double
    public let peakThermalState: LocalModelQualificationThermalState
    public let taskSuite: LocalModelTaskSuiteObservation
    public let networkIsolationAudit: LocalModelNetworkIsolationAuditStatus

    public init(
        modelID: String,
        revision: String,
        artifactID: String,
        artifactSHA256: String,
        quantization: String?,
        deviceProfileID: String,
        measuredAt: AgentInstant,
        identity: LocalModelQualificationIdentity,
        peakMemoryBytes: UInt64,
        generationTokensPerSecond: Double,
        peakThermalState: LocalModelQualificationThermalState,
        taskSuite: LocalModelTaskSuiteObservation,
        networkIsolationAudit: LocalModelNetworkIsolationAuditStatus
    ) {
        self.modelID = modelID
        self.revision = revision
        self.artifactID = artifactID
        self.artifactSHA256 = artifactSHA256
        self.quantization = quantization
        self.deviceProfileID = deviceProfileID
        self.measuredAt = measuredAt
        self.identity = identity
        self.peakMemoryBytes = peakMemoryBytes
        self.generationTokensPerSecond = generationTokensPerSecond
        self.peakThermalState = peakThermalState
        self.taskSuite = taskSuite
        self.networkIsolationAudit = networkIsolationAudit
    }
}

public enum LocalModelQualificationBlocker: String, Codable, CaseIterable, Hashable, Sendable {
    case compatibilityNotMeasured
    case executionIdentityIncomplete
    case physicalDeviceEvidenceRequired
    case benchmarkIdentityMismatch
    case benchmarkMetricsMismatch
    case peakMemoryMissing
    case contextNotQualified
    case thermalEvidenceMissing
    case taskSuiteMissing
    case taskSuiteFailed
    case networkIsolationUnverified
}

/// The user-facing badge is intentionally a separate type from a raw compatibility result.
/// Callers should only surface this badge after `LocalModelQualificationGate` accepts the
/// physical-device receipt.
public struct LocalModelCompatibilityBadge: Codable, Equatable, Sendable {
    public let label: LocalModelCompatibilityLabel
    public let modelID: String
    public let revision: String
    public let artifactID: String
    public let artifactSHA256: String
    public let quantization: String?
    public let deviceProfileID: String
    public let measuredAt: AgentInstant
    public let identity: LocalModelQualificationIdentity
    public let peakMemoryBytes: UInt64
    public let generationTokensPerSecond: Double
    public let peakThermalState: LocalModelQualificationThermalState
    public let taskSuite: LocalModelTaskSuiteObservation
    public let networkIsolationAudit: LocalModelNetworkIsolationAuditStatus

    fileprivate init(
        label: LocalModelCompatibilityLabel,
        receipt: LocalModelQualificationReceipt
    ) {
        self.label = label
        self.modelID = receipt.modelID
        self.revision = receipt.revision
        self.artifactID = receipt.artifactID
        self.artifactSHA256 = receipt.artifactSHA256
        self.quantization = receipt.quantization
        self.deviceProfileID = receipt.deviceProfileID
        self.measuredAt = receipt.measuredAt
        self.identity = receipt.identity
        self.peakMemoryBytes = receipt.peakMemoryBytes
        self.generationTokensPerSecond = receipt.generationTokensPerSecond
        self.peakThermalState = receipt.peakThermalState
        self.taskSuite = receipt.taskSuite
        self.networkIsolationAudit = receipt.networkIsolationAudit
    }
}

public struct LocalModelQualificationDecision: Codable, Equatable, Sendable {
    public let badge: LocalModelCompatibilityBadge?
    public let blockers: [LocalModelQualificationBlocker]

    public init(
        badge: LocalModelCompatibilityBadge?,
        blockers: [LocalModelQualificationBlocker]
    ) {
        self.badge = badge
        self.blockers = blockers
    }

    public var isQualified: Bool {
        badge != nil && blockers.isEmpty
    }
}

/// Fail-closed gate for V14 Local Model Center compatibility badges.
///
/// The existing compatibility evaluator may still produce useful preflight or benchmark
/// classifications. This gate is the stronger product boundary: a friendly measured badge
/// is promotable only when the exact physical-device qualification receipt matches the
/// benchmark that produced that classification.
public enum LocalModelQualificationGate {
    public static func qualify(
        compatibility: LocalModelCompatibilityResult,
        descriptor: LocalModelCatalogDescriptor,
        device: LocalModelDeviceProfile,
        requirements: LocalModelMissionRequirements = .init(),
        benchmark: LocalModelBenchmarkObservation,
        receipt: LocalModelQualificationReceipt
    ) -> LocalModelQualificationDecision {
        var blockers: [LocalModelQualificationBlocker] = []

        guard isMeasuredPerformanceLabel(compatibility.label),
              compatibility.hasMeasuredEvidence,
              benchmark.generationRateProvenance == .measuredTokenCount
        else {
            return .init(badge: nil, blockers: [.compatibilityNotMeasured])
        }

        if !receipt.identity.hasCompleteIdentity {
            blockers.append(.executionIdentityIncomplete)
        }

        if receipt.identity.environment != .physicalDevice {
            blockers.append(.physicalDeviceEvidenceRequired)
        }

        let identityMatches =
            receipt.modelID == descriptor.modelID
            && receipt.revision == descriptor.revision
            && receipt.artifactID == descriptor.artifactID
            && receipt.artifactSHA256 == descriptor.artifactSHA256
            && receipt.quantization == descriptor.quantization
            && receipt.deviceProfileID == device.profileID
            && benchmark.modelID == receipt.modelID
            && benchmark.revision == receipt.revision
            && benchmark.artifactID == receipt.artifactID
            && benchmark.artifactSHA256 == receipt.artifactSHA256
            && benchmark.quantization == receipt.quantization
            && benchmark.deviceProfileID == receipt.deviceProfileID
            && benchmark.measuredAt == receipt.measuredAt

        if !identityMatches {
            blockers.append(.benchmarkIdentityMismatch)
        }

        guard let benchmarkPeakMemory = benchmark.peakMemoryBytes else {
            blockers.append(.peakMemoryMissing)
            return .init(badge: nil, blockers: canonicalize(blockers))
        }

        let metricMatches =
            receipt.peakMemoryBytes > 0
            && receipt.peakMemoryBytes == benchmarkPeakMemory
            && receipt.generationTokensPerSecond.isFinite
            && receipt.generationTokensPerSecond >= 0
            && benchmark.generationTokensPerSecond.isFinite
            && receipt.generationTokensPerSecond == benchmark.generationTokensPerSecond

        if !metricMatches {
            blockers.append(.benchmarkMetricsMismatch)
        }

        let contextFitsCatalog = descriptor.contextWindowTokens.map {
            receipt.identity.contextTokens <= $0
        } ?? true
        let contextMeetsMission = requirements.minimumContextTokens.map {
            receipt.identity.contextTokens >= $0
        } ?? true
        if receipt.identity.contextTokens == 0 || !contextFitsCatalog || !contextMeetsMission {
            blockers.append(.contextNotQualified)
        }

        if receipt.peakThermalState == .unknown {
            blockers.append(.thermalEvidenceMissing)
        }

        if !receipt.taskSuite.hasCompleteIdentity || receipt.taskSuite.completedCases == 0 {
            blockers.append(.taskSuiteMissing)
        } else if receipt.taskSuite.failedCases > 0 {
            blockers.append(.taskSuiteFailed)
        }

        if receipt.networkIsolationAudit != .passed {
            blockers.append(.networkIsolationUnverified)
        }

        let canonicalBlockers = canonicalize(blockers)
        guard canonicalBlockers.isEmpty else {
            return .init(badge: nil, blockers: canonicalBlockers)
        }

        return .init(
            badge: LocalModelCompatibilityBadge(label: compatibility.label, receipt: receipt),
            blockers: []
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

    private static func canonicalize(
        _ blockers: [LocalModelQualificationBlocker]
    ) -> [LocalModelQualificationBlocker] {
        var seen = Set<LocalModelQualificationBlocker>()
        return blockers.filter { seen.insert($0).inserted }
    }
}

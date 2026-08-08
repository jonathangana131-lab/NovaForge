import Foundation

/// The environment in which a local-model qualification observation was collected.
/// Only physical-device evidence may qualify an exact device/runtime configuration for
/// a user-facing compatibility badge. Simulator and desktop observations remain useful
/// engineering evidence, but they are not iPhone performance proof.
public enum LocalModelQualificationEnvironment: String, Codable, Hashable, Sendable {
    case physicalDevice
    case simulator
    case desktop
    case unknown
}

public enum LocalModelQualificationReason: String, Codable, Hashable, Sendable {
    case compatibilityNotMeasured
    case benchmarkIdentityMismatch
    case targetIdentityInvalid
    case targetIdentityMismatch
    case environmentNotPhysicalDevice
    case observationInvalid
    case measuredMemoryMissing
    case measuredMemoryMismatch
    case measuredRateMismatch
    case taskSuiteInsufficient
}

/// Exact execution identity for one local-model qualification target.
///
/// This deliberately binds the fields that can materially change memory, speed, and
/// correctness even when the model artifact itself is unchanged. A receipt measured
/// with another tokenizer, runtime revision, KV representation, context size, OS build,
/// or execution environment cannot silently qualify this target.
public struct LocalModelQualificationTarget: Codable, Equatable, Sendable {
    public let deviceProfileID: String
    public let deviceModel: String
    public let osVersion: String
    public let osBuild: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let tokenizerID: String
    public let tokenizerRevision: String
    public let kvCacheType: String
    public let contextTokens: UInt64
    public let environment: LocalModelQualificationEnvironment

    public init(
        deviceProfileID: String,
        deviceModel: String,
        osVersion: String,
        osBuild: String,
        runtimeID: String,
        runtimeRevision: String,
        tokenizerID: String,
        tokenizerRevision: String,
        kvCacheType: String,
        contextTokens: UInt64,
        environment: LocalModelQualificationEnvironment
    ) {
        self.deviceProfileID = deviceProfileID
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.runtimeID = runtimeID
        self.runtimeRevision = runtimeRevision
        self.tokenizerID = tokenizerID
        self.tokenizerRevision = tokenizerRevision
        self.kvCacheType = kvCacheType
        self.contextTokens = contextTokens
        self.environment = environment
    }
}

/// Bounded task-suite evidence attached to the exact qualification observation.
/// A badge cannot be promoted from speed alone.
public struct LocalModelQualificationTaskSuite: Codable, Equatable, Sendable {
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
}

/// Measurements captured during the exact target run. Thermal values are retained as
/// OS/runtime-observed labels rather than translated into invented temperatures.
public struct LocalModelQualificationObservation: Codable, Equatable, Sendable {
    public let peakMemoryBytes: UInt64
    public let memoryPressureEvents: UInt16
    public let thermalStateAtStart: String
    public let thermalStateAtEnd: String
    public let timeToFirstTokenMilliseconds: Double
    public let prefillTokensPerSecond: Double
    public let generationTokensPerSecond: Double
    public let taskSuite: LocalModelQualificationTaskSuite

    public init(
        peakMemoryBytes: UInt64,
        memoryPressureEvents: UInt16,
        thermalStateAtStart: String,
        thermalStateAtEnd: String,
        timeToFirstTokenMilliseconds: Double,
        prefillTokensPerSecond: Double,
        generationTokensPerSecond: Double,
        taskSuite: LocalModelQualificationTaskSuite
    ) {
        self.peakMemoryBytes = peakMemoryBytes
        self.memoryPressureEvents = memoryPressureEvents
        self.thermalStateAtStart = thermalStateAtStart
        self.thermalStateAtEnd = thermalStateAtEnd
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.generationTokensPerSecond = generationTokensPerSecond
        self.taskSuite = taskSuite
    }
}

/// Immutable evidence packet for one exact local-model qualification run.
///
/// It repeats the artifact identity rather than relying on a mutable catalog lookup so
/// a later catalog refresh cannot reinterpret old measurements as evidence for new bytes.
public struct LocalModelQualificationReceipt: Codable, Equatable, Sendable {
    public let modelID: String
    public let revision: String
    public let artifactID: String
    public let artifactSHA256: String
    public let quantization: String?
    public let target: LocalModelQualificationTarget
    public let measuredAt: AgentInstant
    public let observation: LocalModelQualificationObservation

    public init(
        modelID: String,
        revision: String,
        artifactID: String,
        artifactSHA256: String,
        quantization: String?,
        target: LocalModelQualificationTarget,
        measuredAt: AgentInstant,
        observation: LocalModelQualificationObservation
    ) {
        self.modelID = modelID
        self.revision = revision
        self.artifactID = artifactID
        self.artifactSHA256 = artifactSHA256
        self.quantization = quantization
        self.target = target
        self.measuredAt = measuredAt
        self.observation = observation
    }
}

public struct LocalModelQualificationDecision: Codable, Equatable, Sendable {
    public let isCompatibilityBadgeEligible: Bool
    public let reasons: [LocalModelQualificationReason]
    public let evidence: [LocalModelEvidence]

    public init(
        isCompatibilityBadgeEligible: Bool,
        reasons: [LocalModelQualificationReason],
        evidence: [LocalModelEvidence]
    ) {
        self.isCompatibilityBadgeEligible = isCompatibilityBadgeEligible
        self.reasons = reasons
        self.evidence = evidence
    }
}

/// V14 promotion gate for user-facing exact-device compatibility claims.
///
/// `LocalModelCompatibilityEvaluator` remains useful for catalog/resource preflight and
/// measured performance classification. This gate is intentionally stricter: a friendly
/// measured label is not enough to claim that an exact runtime configuration is qualified.
public enum LocalModelQualificationGate {
    public static func evaluate(
        descriptor: LocalModelCatalogDescriptor,
        device: LocalModelDeviceProfile,
        compatibility: LocalModelCompatibilityResult,
        benchmark: LocalModelBenchmarkObservation,
        target: LocalModelQualificationTarget,
        receipt: LocalModelQualificationReceipt
    ) -> LocalModelQualificationDecision {
        guard compatibility.reasons == [.measuredPerformance],
              compatibility.hasMeasuredEvidence,
              [.excellent, .good, .slow].contains(compatibility.label),
              benchmark.generationRateProvenance == .measuredTokenCount
        else {
            return rejection(
                .compatibilityNotMeasured,
                code: "qualification.compatibility_not_measured",
                detail: "The base compatibility result is not a stable measured-performance classification."
            )
        }

        guard benchmark.modelID == descriptor.modelID,
              benchmark.revision == descriptor.revision,
              benchmark.artifactID == descriptor.artifactID,
              benchmark.artifactSHA256 == descriptor.artifactSHA256,
              benchmark.quantization == descriptor.quantization,
              benchmark.deviceProfileID == device.profileID
        else {
            return rejection(
                .benchmarkIdentityMismatch,
                code: "qualification.benchmark_identity_mismatch",
                detail: "The benchmark does not match the exact catalog artifact and device profile being qualified."
            )
        }

        guard targetIsWellFormed(target),
              target.deviceProfileID == device.profileID
        else {
            return rejection(
                .targetIdentityInvalid,
                code: "qualification.target_identity_invalid",
                detail: "Runtime, tokenizer, KV-cache, context, device, and OS identities must all be explicit before qualification."
            )
        }

        guard target.environment == .physicalDevice else {
            return rejection(
                .environmentNotPhysicalDevice,
                code: "qualification.environment_not_physical_device",
                detail: "Only a physical-device observation may qualify an exact iPhone configuration."
            )
        }

        guard receipt.target == target else {
            return rejection(
                .targetIdentityMismatch,
                code: "qualification.target_identity_mismatch",
                detail: "The qualification receipt was collected for a different runtime, tokenizer, KV-cache, context, device, OS, or execution environment."
            )
        }

        guard receipt.modelID == descriptor.modelID,
              receipt.revision == descriptor.revision,
              receipt.artifactID == descriptor.artifactID,
              receipt.artifactSHA256 == descriptor.artifactSHA256,
              receipt.quantization == descriptor.quantization
        else {
            return rejection(
                .benchmarkIdentityMismatch,
                code: "qualification.receipt_artifact_mismatch",
                detail: "The qualification receipt does not match the exact model artifact identity."
            )
        }

        if let catalogContext = descriptor.contextWindowTokens,
           target.contextTokens > catalogContext {
            return rejection(
                .targetIdentityInvalid,
                code: "qualification.context_exceeds_catalog",
                detail: "The qualification context exceeds the catalog-reported context window for this artifact."
            )
        }

        guard observationIsWellFormed(receipt.observation) else {
            return rejection(
                .observationInvalid,
                code: "qualification.observation_invalid",
                detail: "Qualification measurements contain missing, non-finite, or impossible values."
            )
        }

        guard let benchmarkPeakMemory = benchmark.peakMemoryBytes else {
            return rejection(
                .measuredMemoryMissing,
                code: "qualification.measured_memory_missing",
                detail: "A compatibility badge requires observed peak-memory evidence from the same benchmark run."
            )
        }

        guard receipt.measuredAt == benchmark.measuredAt,
              receipt.observation.peakMemoryBytes == benchmarkPeakMemory
        else {
            return rejection(
                .measuredMemoryMismatch,
                code: "qualification.measured_memory_mismatch",
                detail: "Receipt time or peak-memory evidence does not match the exact benchmark observation."
            )
        }

        guard receipt.observation.generationTokensPerSecond == benchmark.generationTokensPerSecond else {
            return rejection(
                .measuredRateMismatch,
                code: "qualification.measured_rate_mismatch",
                detail: "Receipt generation speed does not match the exact measured-token benchmark observation."
            )
        }

        guard receipt.observation.taskSuite.successfulTasks > 0,
              receipt.observation.taskSuite.failedTasks == 0
        else {
            return rejection(
                .taskSuiteInsufficient,
                code: "qualification.task_suite_insufficient",
                detail: "At least one bounded qualification task must pass with no failures before badge promotion."
            )
        }

        let evidence = [
            LocalModelEvidence(
                kind: .measured,
                code: "qualification.exact_execution_identity",
                detail: "Physical-device evidence is bound to runtime \(target.runtimeID)@\(target.runtimeRevision), tokenizer \(target.tokenizerID)@\(target.tokenizerRevision), KV \(target.kvCacheType), context \(target.contextTokens), device \(target.deviceModel), and OS \(target.osVersion) (\(target.osBuild)).",
                observedAt: receipt.measuredAt
            ),
            LocalModelEvidence(
                kind: .measured,
                code: "qualification.resource_observation",
                detail: "Observed peak memory \(receipt.observation.peakMemoryBytes) bytes, \(receipt.observation.memoryPressureEvents) memory-pressure events, TTFT \(receipt.observation.timeToFirstTokenMilliseconds) ms, prefill \(receipt.observation.prefillTokensPerSecond) tok/s, and generation \(receipt.observation.generationTokensPerSecond) tok/s.",
                observedAt: receipt.measuredAt
            ),
            LocalModelEvidence(
                kind: .measured,
                code: "qualification.thermal_observation",
                detail: "Observed thermal state moved from \(receipt.observation.thermalStateAtStart) to \(receipt.observation.thermalStateAtEnd).",
                observedAt: receipt.measuredAt
            ),
            LocalModelEvidence(
                kind: .measured,
                code: "qualification.task_suite",
                detail: "Task suite \(receipt.observation.taskSuite.suiteID)@\(receipt.observation.taskSuite.suiteRevision) recorded \(receipt.observation.taskSuite.successfulTasks) successes and \(receipt.observation.taskSuite.failedTasks) failures.",
                observedAt: receipt.measuredAt
            ),
        ]

        return .init(
            isCompatibilityBadgeEligible: true,
            reasons: [],
            evidence: evidence
        )
    }

    private static func targetIsWellFormed(_ target: LocalModelQualificationTarget) -> Bool {
        target.contextTokens > 0
            && nonblank(target.deviceProfileID)
            && nonblank(target.deviceModel)
            && nonblank(target.osVersion)
            && nonblank(target.osBuild)
            && nonblank(target.runtimeID)
            && nonblank(target.runtimeRevision)
            && nonblank(target.tokenizerID)
            && nonblank(target.tokenizerRevision)
            && nonblank(target.kvCacheType)
    }

    private static func observationIsWellFormed(
        _ observation: LocalModelQualificationObservation
    ) -> Bool {
        observation.peakMemoryBytes > 0
            && nonblank(observation.thermalStateAtStart)
            && nonblank(observation.thermalStateAtEnd)
            && observation.timeToFirstTokenMilliseconds.isFinite
            && observation.timeToFirstTokenMilliseconds >= 0
            && observation.prefillTokensPerSecond.isFinite
            && observation.prefillTokensPerSecond >= 0
            && observation.generationTokensPerSecond.isFinite
            && observation.generationTokensPerSecond >= 0
            && nonblank(observation.taskSuite.suiteID)
            && nonblank(observation.taskSuite.suiteRevision)
    }

    private static func nonblank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func rejection(
        _ reason: LocalModelQualificationReason,
        code: String,
        detail: String
    ) -> LocalModelQualificationDecision {
        .init(
            isCompatibilityBadgeEligible: false,
            reasons: [reason],
            evidence: [
                .init(
                    kind: .inferred,
                    code: code,
                    detail: detail
                ),
            ]
        )
    }
}

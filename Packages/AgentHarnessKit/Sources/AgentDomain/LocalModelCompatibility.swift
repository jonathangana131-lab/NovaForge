import Foundation

public enum LocalModelCompatibilityLabel: String, Codable, CaseIterable, Hashable, Sendable {
    case excellent
    case good
    case slow
    case tooLarge
    case untested
    case unsupported
}

public enum LocalModelEvidenceKind: String, Codable, Hashable, Sendable {
    /// Metadata asserted by a catalog/source. It is not a NovaForge device measurement.
    case sourceReported
    /// A deterministic conclusion NovaForge derives from source metadata + device/policy inputs.
    case inferred
    /// An observation produced for this exact model revision on this exact device profile.
    case measured
}

/// Capability truth must preserve the difference between "known unsupported" and
/// "not yet verified". Treating unknown as false would turn missing metadata into a lie.
public enum LocalModelCapabilityStatus: String, Codable, Hashable, Sendable {
    case supported
    case unsupported
    case unknown
}

public enum LocalModelCompatibilityReason: String, Codable, Hashable, Sendable {
    case architectureUnsupported
    case insufficientStorage
    case memoryBudgetExceeded
    case missingMemoryEstimate
    case toolCallingUnavailable
    case toolCallingUnverified
    case structuredOutputUnavailable
    case structuredOutputUnverified
    case contextWindowInsufficient
    case contextWindowUnverified
    case benchmarkMissing
    case benchmarkNotApplicable
    case benchmarkInsufficient
    case benchmarkUnstable
    case invalidPolicy
    case measuredPerformance
}

public struct LocalModelEvidence: Codable, Equatable, Sendable {
    public let kind: LocalModelEvidenceKind
    public let code: String
    public let detail: String
    public let observedAt: AgentInstant?

    public init(
        kind: LocalModelEvidenceKind,
        code: String,
        detail: String,
        observedAt: AgentInstant? = nil
    ) {
        self.kind = kind
        self.code = code
        self.detail = detail
        self.observedAt = observedAt
    }
}

/// Catalog metadata used by compatibility preflight. None of these values are
/// treated as physical-device measurements merely because they came from a catalog.
public struct LocalModelCatalogDescriptor: Codable, Equatable, Sendable {
    public let modelID: String
    public let revision: String
    public let format: String
    public let architecture: String
    public let quantization: String?
    public let contextWindowTokens: UInt64?
    public let fileSizeBytes: UInt64
    public let estimatedPeakMemoryBytes: UInt64?
    public let toolCalling: LocalModelCapabilityStatus
    public let structuredOutput: LocalModelCapabilityStatus
    public let source: String
    public let license: String?

    public init(
        modelID: String,
        revision: String,
        format: String,
        architecture: String,
        quantization: String?,
        contextWindowTokens: UInt64?,
        fileSizeBytes: UInt64,
        estimatedPeakMemoryBytes: UInt64?,
        toolCalling: LocalModelCapabilityStatus,
        structuredOutput: LocalModelCapabilityStatus,
        source: String,
        license: String? = nil
    ) {
        self.modelID = modelID
        self.revision = revision
        self.format = format
        self.architecture = architecture
        self.quantization = quantization
        self.contextWindowTokens = contextWindowTokens
        self.fileSizeBytes = fileSizeBytes
        self.estimatedPeakMemoryBytes = estimatedPeakMemoryBytes
        self.toolCalling = toolCalling
        self.structuredOutput = structuredOutput
        self.source = source
        self.license = license
    }
}

/// A stable compatibility identity + conservative resource budget for one device.
/// The memory budget is intentionally not named "physical RAM": callers can reduce
/// it for thermal/headroom policy without changing the device identity.
public struct LocalModelDeviceProfile: Codable, Equatable, Sendable {
    public let profileID: String
    public let supportedArchitectures: [String]
    public let availableStorageBytes: UInt64
    public let memoryBudgetBytes: UInt64

    public init(
        profileID: String,
        supportedArchitectures: [String],
        availableStorageBytes: UInt64,
        memoryBudgetBytes: UInt64
    ) {
        self.profileID = profileID
        self.supportedArchitectures = supportedArchitectures
        self.availableStorageBytes = availableStorageBytes
        self.memoryBudgetBytes = memoryBudgetBytes
    }
}

public struct LocalModelMissionRequirements: Codable, Equatable, Sendable {
    public let requiresToolCalling: Bool
    public let requiresStructuredOutput: Bool
    public let minimumContextTokens: UInt64?

    public init(
        requiresToolCalling: Bool = false,
        requiresStructuredOutput: Bool = false,
        minimumContextTokens: UInt64? = nil
    ) {
        self.requiresToolCalling = requiresToolCalling
        self.requiresStructuredOutput = requiresStructuredOutput
        self.minimumContextTokens = minimumContextTokens
    }
}

/// A benchmark observation is eligible to produce `measured` compatibility evidence
/// only when model ID, revision, and device profile all exactly match the evaluation.
public struct LocalModelBenchmarkObservation: Codable, Equatable, Sendable {
    public let modelID: String
    public let revision: String
    public let deviceProfileID: String
    public let measuredAt: AgentInstant
    public let generationTokensPerSecond: Double
    public let successfulSmokeRuns: UInt16
    public let failedSmokeRuns: UInt16
    public let peakMemoryBytes: UInt64?

    public init(
        modelID: String,
        revision: String,
        deviceProfileID: String,
        measuredAt: AgentInstant,
        generationTokensPerSecond: Double,
        successfulSmokeRuns: UInt16,
        failedSmokeRuns: UInt16,
        peakMemoryBytes: UInt64? = nil
    ) {
        self.modelID = modelID
        self.revision = revision
        self.deviceProfileID = deviceProfileID
        self.measuredAt = measuredAt
        self.generationTokensPerSecond = generationTokensPerSecond
        self.successfulSmokeRuns = successfulSmokeRuns
        self.failedSmokeRuns = failedSmokeRuns
        self.peakMemoryBytes = peakMemoryBytes
    }
}

/// Product policy for translating exact-device measurements into friendly labels.
/// Thresholds are explicit inputs so labels remain explainable and versionable.
public struct LocalModelCompatibilityPolicy: Codable, Equatable, Sendable {
    public let minimumCompletedSmokeRuns: UInt16
    public let maximumFailureRate: Double
    public let excellentTokensPerSecond: Double
    public let goodTokensPerSecond: Double

    public init(
        minimumCompletedSmokeRuns: UInt16 = 2,
        maximumFailureRate: Double = 0,
        excellentTokensPerSecond: Double = 8,
        goodTokensPerSecond: Double = 3
    ) {
        self.minimumCompletedSmokeRuns = minimumCompletedSmokeRuns
        self.maximumFailureRate = maximumFailureRate
        self.excellentTokensPerSecond = excellentTokensPerSecond
        self.goodTokensPerSecond = goodTokensPerSecond
    }

    public static let conservativeV1 = LocalModelCompatibilityPolicy()

    public var isValid: Bool {
        minimumCompletedSmokeRuns > 0
            && maximumFailureRate.isFinite
            && maximumFailureRate >= 0
            && maximumFailureRate <= 1
            && excellentTokensPerSecond.isFinite
            && goodTokensPerSecond.isFinite
            && excellentTokensPerSecond >= goodTokensPerSecond
            && goodTokensPerSecond >= 0
    }
}

public struct LocalModelCompatibilityResult: Codable, Equatable, Sendable {
    public let label: LocalModelCompatibilityLabel
    public let reasons: [LocalModelCompatibilityReason]
    public let evidence: [LocalModelEvidence]

    public init(
        label: LocalModelCompatibilityLabel,
        reasons: [LocalModelCompatibilityReason],
        evidence: [LocalModelEvidence]
    ) {
        self.label = label
        self.reasons = reasons
        self.evidence = evidence
    }

    /// `untested` is preflight-eligible but still requires validation before NovaForge
    /// may call the model verified. Unsupported/resource-blocked models are not runnable.
    public var isPreflightEligible: Bool {
        switch label {
        case .excellent, .good, .slow, .untested:
            true
        case .tooLarge, .unsupported:
            false
        }
    }

    public var hasMeasuredEvidence: Bool {
        evidence.contains { $0.kind == .measured }
    }
}

public enum LocalModelCompatibilityEvaluator {
    public static func evaluate(
        descriptor: LocalModelCatalogDescriptor,
        device: LocalModelDeviceProfile,
        requirements: LocalModelMissionRequirements = .init(),
        benchmark: LocalModelBenchmarkObservation? = nil,
        policy: LocalModelCompatibilityPolicy = .conservativeV1
    ) -> LocalModelCompatibilityResult {
        var evidence = sourceEvidence(for: descriptor)

        if requirements.requiresToolCalling {
            switch descriptor.toolCalling {
            case .supported:
                break
            case .unsupported:
                evidence.append(.init(
                    kind: .inferred,
                    code: "capability.tool_calling.unsupported",
                    detail: "This mission requires tool calling, which the catalog explicitly marks unsupported."
                ))
                return .init(
                    label: .unsupported,
                    reasons: [.toolCallingUnavailable],
                    evidence: evidence
                )
            case .unknown:
                evidence.append(.init(
                    kind: .inferred,
                    code: "capability.tool_calling.unverified",
                    detail: "This mission requires tool calling, but catalog support is not verified."
                ))
                return .init(
                    label: .untested,
                    reasons: [.toolCallingUnverified],
                    evidence: evidence
                )
            }
        }

        if requirements.requiresStructuredOutput {
            switch descriptor.structuredOutput {
            case .supported:
                break
            case .unsupported:
                evidence.append(.init(
                    kind: .inferred,
                    code: "capability.structured_output.unsupported",
                    detail: "This mission requires structured output, which the catalog explicitly marks unsupported."
                ))
                return .init(
                    label: .unsupported,
                    reasons: [.structuredOutputUnavailable],
                    evidence: evidence
                )
            case .unknown:
                evidence.append(.init(
                    kind: .inferred,
                    code: "capability.structured_output.unverified",
                    detail: "This mission requires structured output, but catalog support is not verified."
                ))
                return .init(
                    label: .untested,
                    reasons: [.structuredOutputUnverified],
                    evidence: evidence
                )
            }
        }

        if let minimumContextTokens = requirements.minimumContextTokens {
            guard let contextWindowTokens = descriptor.contextWindowTokens else {
                evidence.append(.init(
                    kind: .inferred,
                    code: "context.window.unverified",
                    detail: "This mission requires at least \(minimumContextTokens) context tokens, but the catalog has no verified context-window value."
                ))
                return .init(
                    label: .untested,
                    reasons: [.contextWindowUnverified],
                    evidence: evidence
                )
            }

            guard contextWindowTokens >= minimumContextTokens else {
                evidence.append(.init(
                    kind: .inferred,
                    code: "context.window.insufficient",
                    detail: "The catalog reports \(contextWindowTokens) context tokens, below this mission's \(minimumContextTokens)-token requirement."
                ))
                return .init(
                    label: .unsupported,
                    reasons: [.contextWindowInsufficient],
                    evidence: evidence
                )
            }
        }

        let normalizedArchitecture = descriptor.architecture.lowercased()
        let supportedArchitectures = Set(device.supportedArchitectures.map { $0.lowercased() })
        guard supportedArchitectures.contains(normalizedArchitecture) else {
            evidence.append(.init(
                kind: .inferred,
                code: "architecture.unsupported",
                detail: "Architecture \(descriptor.architecture) is not in device profile \(device.profileID)'s supported set."
            ))
            return .init(
                label: .unsupported,
                reasons: [.architectureUnsupported],
                evidence: evidence
            )
        }

        guard descriptor.fileSizeBytes <= device.availableStorageBytes else {
            evidence.append(.init(
                kind: .inferred,
                code: "storage.insufficient",
                detail: "Model file size exceeds the device profile's currently available storage budget."
            ))
            return .init(
                label: .tooLarge,
                reasons: [.insufficientStorage],
                evidence: evidence
            )
        }

        guard let estimatedPeakMemoryBytes = descriptor.estimatedPeakMemoryBytes else {
            evidence.append(.init(
                kind: .inferred,
                code: "memory.estimate_missing",
                detail: "No trustworthy peak-memory estimate is available, so compatibility remains untested."
            ))
            return .init(
                label: .untested,
                reasons: [.missingMemoryEstimate],
                evidence: evidence
            )
        }

        guard estimatedPeakMemoryBytes <= device.memoryBudgetBytes else {
            evidence.append(.init(
                kind: .inferred,
                code: "memory.budget_exceeded",
                detail: "Estimated peak memory exceeds the device profile's local-compute budget."
            ))
            return .init(
                label: .tooLarge,
                reasons: [.memoryBudgetExceeded],
                evidence: evidence
            )
        }

        guard let benchmark else {
            evidence.append(.init(
                kind: .inferred,
                code: "benchmark.missing",
                detail: "Resource preflight passed, but no exact-device benchmark has verified performance."
            ))
            return .init(
                label: .untested,
                reasons: [.benchmarkMissing],
                evidence: evidence
            )
        }

        guard benchmark.modelID == descriptor.modelID,
              benchmark.revision == descriptor.revision,
              benchmark.deviceProfileID == device.profileID
        else {
            evidence.append(.init(
                kind: .inferred,
                code: "benchmark.not_applicable",
                detail: "A benchmark exists, but it does not exactly match this model revision and device profile."
            ))
            return .init(
                label: .untested,
                reasons: [.benchmarkNotApplicable],
                evidence: evidence
            )
        }

        guard benchmark.generationTokensPerSecond.isFinite,
              benchmark.generationTokensPerSecond >= 0
        else {
            evidence.append(.init(
                kind: .inferred,
                code: "benchmark.invalid",
                detail: "The exact-device benchmark contains an invalid generation-rate measurement."
            ))
            return .init(
                label: .untested,
                reasons: [.benchmarkInsufficient],
                evidence: evidence
            )
        }

        evidence.append(.init(
            kind: .measured,
            code: "benchmark.exact_device",
            detail: "Exact revision/device benchmark measured \(benchmark.generationTokensPerSecond) generation tokens/sec across \(benchmark.successfulSmokeRuns) successful and \(benchmark.failedSmokeRuns) failed smoke runs.",
            observedAt: benchmark.measuredAt
        ))

        if let peakMemoryBytes = benchmark.peakMemoryBytes {
            evidence.append(.init(
                kind: .measured,
                code: "memory.peak_observed",
                detail: "Exact-device benchmark observed peak memory of \(peakMemoryBytes) bytes.",
                observedAt: benchmark.measuredAt
            ))

            guard peakMemoryBytes <= device.memoryBudgetBytes else {
                evidence.append(.init(
                    kind: .inferred,
                    code: "memory.measured_budget_exceeded",
                    detail: "Measured peak memory exceeds the configured local-compute budget."
                ))
                return .init(
                    label: .tooLarge,
                    reasons: [.memoryBudgetExceeded],
                    evidence: evidence
                )
            }
        }

        let successful = UInt64(benchmark.successfulSmokeRuns)
        let failed = UInt64(benchmark.failedSmokeRuns)
        let completed = successful + failed

        guard completed > 0 else {
            evidence.append(.init(
                kind: .inferred,
                code: "benchmark.no_completed_runs",
                detail: "The exact-device observation contains no completed smoke runs."
            ))
            return .init(
                label: .untested,
                reasons: [.benchmarkInsufficient],
                evidence: evidence
            )
        }

        guard policy.isValid else {
            evidence.append(.init(
                kind: .inferred,
                code: "compatibility.policy.invalid",
                detail: "Compatibility policy thresholds are internally invalid, so NovaForge will not classify measured performance."
            ))
            return .init(
                label: .untested,
                reasons: [.invalidPolicy],
                evidence: evidence
            )
        }

        guard completed >= UInt64(policy.minimumCompletedSmokeRuns) else {
            evidence.append(.init(
                kind: .inferred,
                code: "benchmark.insufficient_runs",
                detail: "The benchmark has too few completed smoke runs for a verified performance label."
            ))
            return .init(
                label: .untested,
                reasons: [.benchmarkInsufficient],
                evidence: evidence
            )
        }

        let failureRate = Double(failed) / Double(completed)
        guard failureRate <= policy.maximumFailureRate else {
            evidence.append(.init(
                kind: .inferred,
                code: "benchmark.unstable",
                detail: "Measured smoke-run failure rate exceeds the compatibility policy; speed is not promoted to a compatibility label."
            ))
            return .init(
                label: .untested,
                reasons: [.benchmarkUnstable],
                evidence: evidence
            )
        }

        let label: LocalModelCompatibilityLabel
        if benchmark.generationTokensPerSecond >= policy.excellentTokensPerSecond {
            label = .excellent
        } else if benchmark.generationTokensPerSecond >= policy.goodTokensPerSecond {
            label = .good
        } else {
            label = .slow
        }

        evidence.append(.init(
            kind: .inferred,
            code: "performance.policy_classification",
            detail: "The friendly compatibility label was derived from the exact-device measurement using explicit policy thresholds."
        ))

        return .init(
            label: label,
            reasons: [.measuredPerformance],
            evidence: evidence
        )
    }

    private static func sourceEvidence(
        for descriptor: LocalModelCatalogDescriptor
    ) -> [LocalModelEvidence] {
        var evidence = [
            LocalModelEvidence(
                kind: .sourceReported,
                code: "catalog.identity",
                detail: "\(descriptor.source) reports model \(descriptor.modelID) revision \(descriptor.revision)."
            ),
            LocalModelEvidence(
                kind: .sourceReported,
                code: "catalog.format",
                detail: "\(descriptor.source) reports model format \(descriptor.format)."
            ),
            LocalModelEvidence(
                kind: .sourceReported,
                code: "catalog.architecture",
                detail: "\(descriptor.source) reports architecture \(descriptor.architecture)."
            ),
            LocalModelEvidence(
                kind: .sourceReported,
                code: "catalog.file_size",
                detail: "\(descriptor.source) reports a model file size of \(descriptor.fileSizeBytes) bytes."
            ),
            LocalModelEvidence(
                kind: .sourceReported,
                code: "catalog.capability.tool_calling",
                detail: "\(descriptor.source) reports tool-calling capability as \(descriptor.toolCalling.rawValue)."
            ),
            LocalModelEvidence(
                kind: .sourceReported,
                code: "catalog.capability.structured_output",
                detail: "\(descriptor.source) reports structured-output capability as \(descriptor.structuredOutput.rawValue)."
            ),
        ]

        if let quantization = descriptor.quantization {
            evidence.append(.init(
                kind: .sourceReported,
                code: "catalog.quantization",
                detail: "\(descriptor.source) reports quantization \(quantization)."
            ))
        }

        if let contextWindowTokens = descriptor.contextWindowTokens {
            evidence.append(.init(
                kind: .sourceReported,
                code: "catalog.context_window",
                detail: "\(descriptor.source) reports a \(contextWindowTokens)-token context window."
            ))
        }

        if let estimatedPeakMemoryBytes = descriptor.estimatedPeakMemoryBytes {
            evidence.append(.init(
                kind: .sourceReported,
                code: "catalog.memory_estimate",
                detail: "\(descriptor.source) provides an estimated peak memory requirement of \(estimatedPeakMemoryBytes) bytes."
            ))
        }

        return evidence
    }
}

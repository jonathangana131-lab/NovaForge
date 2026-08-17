import Foundation

/// Content-free timing telemetry for one local inference request.
///
/// NovaForge uses these measurements to decide whether an optimization actually
/// improves end-to-end latency on the current device. No prompt, generated text,
/// token ids, file paths, or other user content are stored in this structure.
public struct LlamaPerformanceSnapshot: Equatable, Sendable {
    public enum Completion: String, Equatable, Sendable {
        case completed
        case cancelled
        case failed
    }

    public let runtimeReason: String
    public let prefillSeconds: Double
    public let timeToFirstTokenSeconds: Double?
    public let decodeSeconds: Double
    public let generatedTokenCount: Int
    public let decodeTokensPerSecond: Double
    public let completion: Completion

    public init(
        runtimeReason: String,
        prefillSeconds: Double,
        timeToFirstTokenSeconds: Double?,
        decodeSeconds: Double,
        generatedTokenCount: Int,
        decodeTokensPerSecond: Double,
        completion: Completion
    ) {
        self.runtimeReason = runtimeReason
        self.prefillSeconds = max(0, prefillSeconds)
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds.map { max(0, $0) }
        self.decodeSeconds = max(0, decodeSeconds)
        self.generatedTokenCount = max(0, generatedTokenCount)
        self.decodeTokensPerSecond = max(0, decodeTokensPerSecond)
        self.completion = completion
    }
}

/// A small, backend-neutral promotion gate for experimental decode modes.
///
/// MTP, n-gram drafting, an ANE-resident draft model, or a future sparse target
/// must beat measured autoregressive throughput before NovaForge keeps the mode
/// enabled. This intentionally does not know how a backend implements drafting.
public struct LlamaAdaptiveInferenceGovernor: Equatable, Sendable {
    public enum Selection: Equatable, Sendable {
        case baseline
        case candidate
    }

    public struct Candidate: Equatable, Sendable {
        public let samples: Int
        public let averageTokensPerSecond: Double
        public let averageAcceptanceRate: Double?
        public let residentBytes: UInt64

        public init(
            samples: Int,
            averageTokensPerSecond: Double,
            averageAcceptanceRate: Double?,
            residentBytes: UInt64
        ) {
            self.samples = samples
            self.averageTokensPerSecond = averageTokensPerSecond
            self.averageAcceptanceRate = averageAcceptanceRate
            self.residentBytes = residentBytes
        }
    }

    /// Require repeated evidence and a meaningful win so noisy one-off samples
    /// do not thrash memory by repeatedly loading/unloading a draft model.
    public static func shouldPromote(
        candidate: Candidate,
        baselineTokensPerSecond: Double,
        availableResidentBytes: UInt64,
        minimumSamples: Int = 3,
        minimumRelativeSpeedup: Double = 1.05,
        minimumAcceptanceRate: Double = 0.50
    ) -> Bool {
        passes(
            candidate: candidate,
            baselineTokensPerSecond: baselineTokensPerSecond,
            availableResidentBytes: availableResidentBytes,
            minimumSamples: minimumSamples,
            minimumRelativeSpeedup: minimumRelativeSpeedup,
            minimumAcceptanceRate: minimumAcceptanceRate
        )
    }

    /// A resident candidate uses a looser retention threshold than a cold
    /// candidate uses for promotion. That hysteresis is intentional: repeatedly
    /// evicting/reloading a draft working set can cost more than a tiny measured
    /// throughput dip. Hard memory and acceptance gates still win immediately.
    public static func shouldRetainResidentCandidate(
        candidate: Candidate,
        baselineTokensPerSecond: Double,
        availableResidentBytes: UInt64,
        minimumSamples: Int = 2,
        minimumRelativeSpeedup: Double = 0.98,
        minimumAcceptanceRate: Double = 0.45
    ) -> Bool {
        passes(
            candidate: candidate,
            baselineTokensPerSecond: baselineTokensPerSecond,
            availableResidentBytes: availableResidentBytes,
            minimumSamples: minimumSamples,
            minimumRelativeSpeedup: minimumRelativeSpeedup,
            minimumAcceptanceRate: minimumAcceptanceRate
        )
    }

    /// One backend-neutral decision point for future speculative engines.
    /// `candidateIsResident` is about actual working-set residency, not whether
    /// the mode was merely selected in UI settings.
    public static func select(
        candidate: Candidate,
        baselineTokensPerSecond: Double,
        availableResidentBytes: UInt64,
        candidateIsResident: Bool
    ) -> Selection {
        let accepted = candidateIsResident
            ? shouldRetainResidentCandidate(
                candidate: candidate,
                baselineTokensPerSecond: baselineTokensPerSecond,
                availableResidentBytes: availableResidentBytes
            )
            : shouldPromote(
                candidate: candidate,
                baselineTokensPerSecond: baselineTokensPerSecond,
                availableResidentBytes: availableResidentBytes
            )
        return accepted ? .candidate : .baseline
    }

    private static func passes(
        candidate: Candidate,
        baselineTokensPerSecond: Double,
        availableResidentBytes: UInt64,
        minimumSamples: Int,
        minimumRelativeSpeedup: Double,
        minimumAcceptanceRate: Double
    ) -> Bool {
        guard candidate.samples >= minimumSamples,
              minimumSamples > 0,
              baselineTokensPerSecond.isFinite,
              baselineTokensPerSecond > 0,
              minimumRelativeSpeedup.isFinite,
              minimumRelativeSpeedup > 0,
              candidate.averageTokensPerSecond.isFinite,
              candidate.averageTokensPerSecond >= baselineTokensPerSecond * minimumRelativeSpeedup,
              candidate.residentBytes <= availableResidentBytes
        else { return false }

        if let acceptance = candidate.averageAcceptanceRate {
            guard acceptance.isFinite,
                  acceptance >= minimumAcceptanceRate,
                  acceptance <= 1 else { return false }
        }
        return true
    }
}

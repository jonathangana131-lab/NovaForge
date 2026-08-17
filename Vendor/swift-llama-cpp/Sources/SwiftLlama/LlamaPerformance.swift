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
        guard candidate.samples >= minimumSamples,
              baselineTokensPerSecond.isFinite,
              baselineTokensPerSecond > 0,
              candidate.averageTokensPerSecond.isFinite,
              candidate.averageTokensPerSecond >= baselineTokensPerSecond * minimumRelativeSpeedup,
              candidate.residentBytes <= availableResidentBytes
        else { return false }

        if let acceptance = candidate.averageAcceptanceRate {
            guard acceptance.isFinite,
                  acceptance >= minimumAcceptanceRate else { return false }
        }
        return true
    }
}

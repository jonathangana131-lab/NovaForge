import Testing
@testable import SwiftLlama

struct LlamaPerformanceTests {
    @Test("Speculative candidate needs repeated measured speedup")
    func promotionNeedsRealSpeedup() {
        let candidate = LlamaAdaptiveInferenceGovernor.Candidate(
            samples: 3,
            averageTokensPerSecond: 10.6,
            averageAcceptanceRate: 0.72,
            residentBytes: 256 * 1_024 * 1_024
        )
        #expect(LlamaAdaptiveInferenceGovernor.shouldPromote(
            candidate: candidate,
            baselineTokensPerSecond: 10,
            availableResidentBytes: 512 * 1_024 * 1_024
        ))
    }

    @Test("Speculation does not promote from one noisy sample")
    func noPromotionFromNoise() {
        let candidate = LlamaAdaptiveInferenceGovernor.Candidate(
            samples: 1,
            averageTokensPerSecond: 14,
            averageAcceptanceRate: 0.90,
            residentBytes: 64 * 1_024 * 1_024
        )
        #expect(!LlamaAdaptiveInferenceGovernor.shouldPromote(
            candidate: candidate,
            baselineTokensPerSecond: 10,
            availableResidentBytes: 512 * 1_024 * 1_024
        ))
    }

    @Test("Low acceptance or memory pressure rejects speculative mode")
    func memoryAndAcceptanceAreHardGates() {
        let lowAcceptance = LlamaAdaptiveInferenceGovernor.Candidate(
            samples: 5,
            averageTokensPerSecond: 13,
            averageAcceptanceRate: 0.35,
            residentBytes: 128 * 1_024 * 1_024
        )
        #expect(!LlamaAdaptiveInferenceGovernor.shouldPromote(
            candidate: lowAcceptance,
            baselineTokensPerSecond: 10,
            availableResidentBytes: 512 * 1_024 * 1_024
        ))

        let tooLarge = LlamaAdaptiveInferenceGovernor.Candidate(
            samples: 5,
            averageTokensPerSecond: 13,
            averageAcceptanceRate: 0.80,
            residentBytes: 768 * 1_024 * 1_024
        )
        #expect(!LlamaAdaptiveInferenceGovernor.shouldPromote(
            candidate: tooLarge,
            baselineTokensPerSecond: 10,
            availableResidentBytes: 512 * 1_024 * 1_024
        ))
    }

    @Test("Performance snapshot clamps invalid negative durations")
    func snapshotClampsDurations() {
        let snapshot = LlamaPerformanceSnapshot(
            runtimeReason: "test",
            prefillSeconds: -1,
            timeToFirstTokenSeconds: -2,
            decodeSeconds: -3,
            generatedTokenCount: -4,
            decodeTokensPerSecond: -5,
            completion: .failed
        )
        #expect(snapshot.prefillSeconds == 0)
        #expect(snapshot.timeToFirstTokenSeconds == 0)
        #expect(snapshot.decodeSeconds == 0)
        #expect(snapshot.generatedTokenCount == 0)
        #expect(snapshot.decodeTokensPerSecond == 0)
    }
}

import Foundation
import Testing
@testable import SwiftLlama

struct LlamaServiceConcurrencyTests {
    @Test("Overlapping replacement requests keep only newest generation authority")
    func overlappingReplacementRequestsKeepNewestAuthority() async throws {
        let engine = ControlledServiceEngine(holdFirstGeneration: true)
        let service = LlamaService(
            engine: engine,
            config: .init(batchSize: 16, maxTokenCount: 64, useGPU: false)
        )

        let initialStream = try await service.streamCompletion(
            of: messages("initial"),
            samplingConfig: sampling(seed: 1)
        )
        let initialConsumer = Task<Void, Error> {
            for try await _ in initialStream {}
        }

        #expect(await waitUntil { await engine.generationCallCount == 1 })

        let staleReplacement = Task {
            try await service.streamCompletion(
                of: messages("stale"),
                samplingConfig: sampling(seed: 2)
            )
        }
        #expect(await waitUntil { await service.requestStartCountForTesting >= 2 })
        #expect(await waitUntil { await engine.firstGenerationCancellationObserved })

        let newestReplacement = Task {
            try await service.streamCompletion(
                of: messages("newest"),
                samplingConfig: sampling(seed: 3)
            )
        }
        #expect(await waitUntil { await service.requestStartCountForTesting >= 3 })

        // Both replacement requests are now waiting for the same captured generation.
        // Releasing it exercises actor reentrancy: the stale request must fail before it
        // can clear ownership or mutate prompt/sampler state, while the newest proceeds.
        await engine.releaseFirstGeneration()
        try await initialConsumer.value

        switch await staleReplacement.result {
        case .failure(let error):
            #expect(error is CancellationError)
        case .success:
            Issue.record("Stale replacement unexpectedly reached generation setup")
        }

        let newestStream = try await newestReplacement.value
        #expect(await engine.initializedPrompts == ["initial", "newest"])
        #expect(await engine.samplingSeeds == [1, 3])

        let newestConsumer = Task<Void, Error> {
            for try await _ in newestStream {}
        }
        #expect(await waitUntil { await engine.generationCallCount >= 2 })

        await service.stopCompletion()
        try await newestConsumer.value

        #expect(await engine.secondGenerationCancellationObserved)
        #expect(!(await engine.secondGenerationCompletedNaturally))
    }

    @Test("Stop invalidates a pending setup before sampler or generation mutation")
    func stopInvalidatesPendingSetup() async throws {
        let engine = ControlledServiceEngine(blockedInitializationPrompt: "pending")
        let service = LlamaService(
            engine: engine,
            config: .init(batchSize: 16, maxTokenCount: 64, useGPU: false)
        )

        let pending = Task {
            try await service.streamCompletion(
                of: messages("pending"),
                samplingConfig: sampling(seed: 9)
            )
        }

        #expect(await waitUntil { await engine.blockedInitializationIsWaiting })
        await service.stopCompletion()
        await engine.releaseBlockedInitialization()

        switch await pending.result {
        case .failure(let error):
            #expect(error is CancellationError)
        case .success:
            Issue.record("Stop did not invalidate the pending stream setup")
        }

        #expect(await engine.samplingSeeds.isEmpty)
        #expect(await engine.generationCallCount == 0)
    }

    private func messages(_ label: String) -> [LlamaChatMessage] {
        [LlamaChatMessage(role: .user, content: label)]
    }

    private func sampling(seed: UInt32) -> LlamaSamplingConfig {
        LlamaSamplingConfig(temperature: 0.1, seed: seed)
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if await predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

private actor ControlledServiceEngine: LlamaServiceEngine {
    private let holdFirstGeneration: Bool
    private let blockedInitializationPrompt: String?
    private var firstGenerationRelease: CheckedContinuation<Void, Never>?
    private var blockedInitializationRelease: CheckedContinuation<Void, Never>?

    private(set) var initializedPrompts: [String] = []
    private(set) var samplingSeeds: [UInt32] = []
    private(set) var generationCallCount = 0
    private(set) var firstGenerationCancellationObserved = false
    private(set) var secondGenerationCancellationObserved = false
    private(set) var secondGenerationCompletedNaturally = false
    private(set) var blockedInitializationIsWaiting = false

    init(
        holdFirstGeneration: Bool = false,
        blockedInitializationPrompt: String? = nil
    ) {
        self.holdFirstGeneration = holdFirstGeneration
        self.blockedInitializationPrompt = blockedInitializationPrompt
    }

    func initializeCompletion(
        messages: [LlamaChatMessage],
        addAssistant: Bool?
    ) async throws {
        let prompt = messages.last?.content ?? ""
        initializedPrompts.append(prompt)

        if prompt == blockedInitializationPrompt {
            blockedInitializationIsWaiting = true
            await withCheckedContinuation { continuation in
                blockedInitializationRelease = continuation
            }
            blockedInitializationIsWaiting = false
        }
    }

    func updateSamplingConfig(_ config: LlamaSamplingConfig) async throws {
        samplingSeeds.append(config.seed)
    }

    func hasGenerationCapacity() async -> Bool {
        true
    }

    func generateNextToken() async throws -> NextToken {
        generationCallCount += 1
        let call = generationCallCount

        if call == 1, holdFirstGeneration {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    firstGenerationRelease = continuation
                }
            } onCancel: {
                Task { await self.markFirstGenerationCancelled() }
            }
            return .endOfString
        }

        do {
            // A bounded natural completion keeps the regression from hanging if Stop loses
            // ownership. Correct behavior cancels this sleep and records cancellation.
            try await Task.sleep(nanoseconds: 500_000_000)
            secondGenerationCompletedNaturally = true
            return .endOfString
        } catch is CancellationError {
            secondGenerationCancellationObserved = true
            throw CancellationError()
        }
    }

    func releaseFirstGeneration() {
        firstGenerationRelease?.resume()
        firstGenerationRelease = nil
    }

    func releaseBlockedInitialization() {
        blockedInitializationRelease?.resume()
        blockedInitializationRelease = nil
    }

    private func markFirstGenerationCancelled() {
        firstGenerationCancellationObserved = true
    }
}

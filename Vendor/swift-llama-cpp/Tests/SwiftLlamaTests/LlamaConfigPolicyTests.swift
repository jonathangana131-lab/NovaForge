import Testing
@testable import SwiftLlama

struct LlamaConfigPolicyTests {
    @Test("Default local runtime keeps weights file-backed and fast KV")
    func defaultRuntimePolicy() {
        let config = LlamaConfig(batchSize: 64, maxTokenCount: 2_048)

        #expect(config.modelLoadMode == .mmap)
        #expect(config.keyCacheType == .f16)
        #expect(config.valueCacheType == .f16)
        #expect(config.flashAttentionMode == .automatic)
        #expect(config.offloadKQV)
        #expect(config.allowLowMemoryFallback)
    }

    @Test("Runtime sanitizes zero-sized allocation requests")
    func allocationBounds() {
        let config = LlamaConfig(batchSize: 0, maxTokenCount: 0)

        #expect(config.batchSize == 1)
        #expect(config.maxTokenCount == 256)
    }

    @Test("Actual context size clamps executable token ceiling")
    func actualContextSizeClampsExecutableContext() {
        let profile = LlamaConfig(
            batchSize: 64,
            maxTokenCount: 4_096
        ).requestedAllocationProfile

        #expect(profile.reconciledContextTokens(actualContextTokens: 2_048, trainedContextTokens: 8_192) == 2_048)
        #expect(profile.reconciledContextTokens(actualContextTokens: 8_192, trainedContextTokens: 2_048) == 2_048)
        #expect(profile.reconciledContextTokens(actualContextTokens: 8_192, trainedContextTokens: 16_384) == 4_096)
        #expect(profile.reconciledContextTokens(actualContextTokens: 0, trainedContextTokens: 8_192) == nil)
        #expect(profile.reconciledContextTokens(actualContextTokens: 4_096, trainedContextTokens: 0) == nil)
        #expect(profile.reconciledContextTokens(actualContextTokens: 4_096, trainedContextTokens: -1) == nil)
    }

    @Test("Executable context reserves room for generation bookkeeping")
    func executableContextRejectsTinyActualContext() {
        let profile = LlamaContextAllocationProfile(
            contextTokens: 4,
            batchTokens: 1,
            keyCacheType: .f16,
            valueCacheType: .f16
        )

        #expect(profile.reconciledContextTokens(actualContextTokens: 4, trainedContextTokens: 4) == nil)
    }

    @Test("Actual context batch clamps executable Swift batch")
    func actualContextBatchClampsExecutableBatch() {
        let profile = LlamaConfig(
            batchSize: 1_024,
            maxTokenCount: 256
        ).requestedAllocationProfile

        #expect(profile.batchTokens == 1_024)
        #expect(profile.reconciledBatchTokens(actualContextBatch: 256) == 256)
        #expect(profile.reconciledBatchTokens(actualContextBatch: 2_048) == 1_024)
        #expect(profile.reconciledBatchTokens(actualContextBatch: 0) == nil)
    }

    @Test("Executable batch rejects sizes outside Swift batch representation")
    func executableBatchRejectsInt32Overflow() {
        let profile = LlamaContextAllocationProfile(
            contextTokens: UInt32.max,
            batchTokens: UInt32.max,
            keyCacheType: .f16,
            valueCacheType: .f16
        )

        #expect(profile.reconciledBatchTokens(actualContextBatch: UInt32.max) == nil)
        #expect(profile.reconciledBatchTokens(actualContextBatch: UInt32(Int32.max)) == UInt32(Int32.max))
    }

    @Test("Explicit memory rescue policy remains opt-out")
    func explicitPolicyOverrides() {
        let config = LlamaConfig(
            batchSize: 16,
            maxTokenCount: 768,
            modelLoadMode: .automatic,
            keyCacheType: .q8_0,
            valueCacheType: .q4_0,
            flashAttentionMode: .disabled,
            offloadKQV: false,
            allowLowMemoryFallback: false
        )

        #expect(config.modelLoadMode == .automatic)
        #expect(config.keyCacheType == .q8_0)
        #expect(config.valueCacheType == .q4_0)
        #expect(config.flashAttentionMode == .disabled)
        #expect(!config.offloadKQV)
        #expect(!config.allowLowMemoryFallback)
    }

    @Test("Fast rescue returns to F16 even for a quantized request")
    func fastRescueUsesF16CompatibilityProfile() {
        let config = LlamaConfig(
            batchSize: 16,
            maxTokenCount: 768,
            keyCacheType: .q4_0,
            valueCacheType: .q8_0
        )

        let requested = config.requestedAllocationProfile
        let fastRescue = config.fastLowMemoryAllocationProfile

        #expect(requested.keyCacheType == .q4_0)
        #expect(requested.valueCacheType == .q8_0)
        #expect(fastRescue != requested)
        #expect(fastRescue.contextTokens == 768)
        #expect(fastRescue.batchTokens == 16)
        #expect(fastRescue.keyCacheType == .f16)
        #expect(fastRescue.valueCacheType == .f16)
    }

    @Test("Rescue profiles bound allocation size and reserve Q8 for deep rescue")
    func rescueProfileBounds() {
        let config = LlamaConfig(
            batchSize: 128,
            maxTokenCount: 4_096,
            keyCacheType: .q4_0,
            valueCacheType: .q4_0
        )

        let fastRescue = config.fastLowMemoryAllocationProfile
        let deepRescue = config.deepLowMemoryAllocationProfile

        #expect(fastRescue.contextTokens == 1_024)
        #expect(fastRescue.batchTokens == 32)
        #expect(fastRescue.keyCacheType == .f16)
        #expect(fastRescue.valueCacheType == .f16)

        #expect(deepRescue.contextTokens == 768)
        #expect(deepRescue.batchTokens == 16)
        #expect(deepRescue.keyCacheType == .q8_0)
        #expect(deepRescue.valueCacheType == .q8_0)
    }
}

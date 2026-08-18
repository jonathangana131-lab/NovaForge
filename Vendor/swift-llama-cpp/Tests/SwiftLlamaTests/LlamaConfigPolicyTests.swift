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

    @Test("Token piece buffer grows to llama.cpp requested size")
    func tokenPieceBufferGrowth() {
        #expect(LlamaModel.nextTokenPieceBufferSize(for: -128, currentSize: 64) == 128)
        #expect(LlamaModel.nextTokenPieceBufferSize(for: 12, currentSize: 64) == nil)
        #expect(LlamaModel.nextTokenPieceBufferSize(for: -64, currentSize: 64) == nil)
        #expect(LlamaModel.nextTokenPieceBufferSize(for: -128, currentSize: 0) == nil)
    }
}

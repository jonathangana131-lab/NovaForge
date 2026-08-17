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
}

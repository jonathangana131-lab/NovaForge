import Testing
@testable import SwiftLlama

@Suite("Persistent prefix session policy")
struct LlamaPersistentSessionPolicyTests {
    @Test("FNV-1a cache key is deterministic")
    func deterministicFingerprint() {
        let a = LlamaService.fnv1a64("hello".utf8)
        let b = LlamaService.fnv1a64("hello".utf8)
        #expect(a == b)
        #expect(a == 0xa430d84680aabd0b)
    }

    @Test("Runtime/model fingerprint inputs are sensitive to changes")
    func fingerprintChangesWithInput() {
        let base = LlamaService.fnv1a64("qwen38.gguf|9388779744|4096|q8_0".utf8)
        let changedModel = LlamaService.fnv1a64("qwen38-v2.gguf|9388779744|4096|q8_0".utf8)
        let changedContext = LlamaService.fnv1a64("qwen38.gguf|9388779744|8192|q8_0".utf8)
        #expect(base != changedModel)
        #expect(base != changedContext)
    }
}

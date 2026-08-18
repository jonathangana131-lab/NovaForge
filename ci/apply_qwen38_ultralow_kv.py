#!/usr/bin/env python3
from pathlib import Path

runtime_path = Path('AgentPad/Services/LocalModelRuntime.swift')
runtime = runtime_path.read_text()
changed = False

old_service = '''        let service = LlamaService(
            modelUrl: modelURL,
            config: .init(
                batchSize: variant.batchTokens,
                maxTokenCount: variant.contextTokens,
                useGPU: variant.useGPU,
                gpuLayerCount: variant.gpuLayerCount,
                generationThreadCount: variant.generationThreadCount,
                batchThreadCount: variant.batchThreadCount,
                yieldEveryTokenCount: 1
            )
        )
'''
new_service = '''        // A binary/ternary exact-target build exists specifically to make the
        // 27B weight traffic survivable on phone-class memory. For that class,
        // spend the saved bytes on the smallest production KV cache the current
        // llama.cpp Metal backend supports. Keep K/V symmetric so Flash
        // Attention never falls onto the mixed-precision fallback path.
        let quantization = variant.quantization.uppercased()
        let usesUltraLowBitWeights = [
            "Q1_0_G128", "Q1_0", "IQ1_S", "IQ1_M", "TQ1_0", "TQ2_0"
        ].contains(quantization)

        let service = LlamaService(
            modelUrl: modelURL,
            config: .init(
                batchSize: variant.batchTokens,
                maxTokenCount: variant.contextTokens,
                useGPU: variant.useGPU,
                gpuLayerCount: variant.gpuLayerCount,
                generationThreadCount: variant.generationThreadCount,
                batchThreadCount: variant.batchThreadCount,
                yieldEveryTokenCount: 1,
                keyCacheType: usesUltraLowBitWeights ? .q4_0 : .f16,
                valueCacheType: usesUltraLowBitWeights ? .q4_0 : .f16
            )
        )
'''
if new_service not in runtime:
    count = runtime.count(old_service)
    if count != 1:
        raise SystemExit(f'expected one LocalModelClient service config marker, found {count}')
    runtime = runtime.replace(old_service, new_service)
    changed = True

# Prefer the current upstream Q1_0 name. Q1_0_G128 is retained as a legacy
# alias because some converters still use the older filename marker even when
# the stored GGUF tensor type is the upstream 128-weight Q1_0 format.
old_markers = '''            "Q1_0_G128", "Q1_0", "IQ1_S", "TQ1_0", "IQ1_M",
'''
new_markers = '''            "Q1_0", "Q1_0_G128", "IQ1_S", "TQ1_0", "IQ1_M",
'''
if old_markers in runtime:
    runtime = runtime.replace(old_markers, new_markers, 1)
    changed = True

old_ranks = '''        case "Q1_0_G128": 0
        case "Q1_0": 1
'''
new_ranks = '''        case "Q1_0": 0
        case "Q1_0_G128": 1
'''
if old_ranks in runtime:
    runtime = runtime.replace(old_ranks, new_ranks, 1)
    changed = True

# A verified SHA/size proves file identity, not executable compatibility. Keep
# automatic discovery fail-closed when a future publisher invents a GGUF quant
# that the pinned llama.cpp runtime has not qualified.
old_manifest = '''            let quant = quantization(from: sibling.rfilename)
            let manifest = Qwen38ReleaseManifest(
'''
new_manifest = '''            let quant = quantization(from: sibling.rfilename)
            guard runtimeSupports(quant) else { return nil }
            let manifest = Qwen38ReleaseManifest(
'''
if new_manifest not in runtime:
    count = runtime.count(old_manifest)
    if count != 1:
        raise SystemExit(f'expected one release-manifest quant marker, found {count}')
    runtime = runtime.replace(old_manifest, new_manifest)
    changed = True

support_helper = '''    private static func runtimeSupports(_ quantization: String) -> Bool {
        switch quantization.uppercased() {
        case "Q1_0", "Q1_0_G128", "IQ1_S", "TQ1_0", "IQ1_M",
             "TQ2_0", "Q2_0", "UD-IQ2_XXS", "IQ2_XXS", "IQ2_XS",
             "Q2_K_XS", "Q2_K", "Q3_K_XS", "Q3_K_S", "Q3_K_M", "Q4_K_M":
            true
        default:
            false
        }
    }

'''
rank_marker = '''    private static func quantRank(_ value: String) -> Int {
'''
if support_helper not in runtime:
    count = runtime.count(rank_marker)
    if count != 1:
        raise SystemExit(f'expected one quantRank marker, found {count}')
    runtime = runtime.replace(rank_marker, support_helper + rank_marker)
    changed = True

if changed:
    runtime_path.write_text(runtime)


test_path = Path('Vendor/swift-llama-cpp/Tests/SwiftLlamaTests/LlamaRuntimeTunerTests.swift')
tests = test_path.read_text()
new_test = '''
    func testPhoneClassQ1ProfilePreservesSymmetricQ4KVWhileRemainingMapped() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-tuner-q1-\\(UUID().uuidString)-Q1_0.gguf")
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 3_900_000_000)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: url) }

        let requested = LlamaConfig(
            batchSize: 24,
            microBatchSize: 16,
            maxTokenCount: 4_096,
            useGPU: true,
            gpuLayerCount: 1,
            generationThreadCount: 2,
            batchThreadCount: 4,
            loadMode: .automatic,
            flashAttention: .automatic,
            keyCacheType: .q4_0,
            valueCacheType: .q4_0
        )
        let decision = LlamaRuntimeTuner.decide(
            modelURL: url,
            requested: requested,
            physicalMemoryBytes: 4_000_000_000
        )

        XCTAssertTrue(decision.storageBacked)
        XCTAssertEqual(decision.config.loadMode, .mmap)
        XCTAssertEqual(decision.config.keyCacheType, .q4_0)
        XCTAssertEqual(decision.config.valueCacheType, .q4_0)
        XCTAssertFalse(decision.config.useGPU)
        XCTAssertEqual(decision.config.gpuLayerCount, 0)
        XCTAssertEqual(decision.config.microBatchSize, 16)
        XCTAssertFalse(decision.config.offloadKQV)
        XCTAssertFalse(decision.config.operationOffload)
    }
'''
if 'testPhoneClassQ1ProfilePreservesSymmetricQ4KVWhileRemainingMapped' not in tests:
    marker = '\n}\n'
    if not tests.endswith(marker):
        raise SystemExit('unexpected LlamaRuntimeTunerTests.swift terminator')
    tests = tests[:-len(marker)] + new_test + marker
    test_path.write_text(tests)

print('PASS: staged Qwen 3.8 executable-quant discovery + ultra-low-bit Q4 KV policy')

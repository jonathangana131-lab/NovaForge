import XCTest
@testable import SwiftLlama

final class LlamaRuntimeTunerTests: XCTestCase {
    func testOversizedGGUFUsesMappedCompressedCPUBackedProfile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-tuner-\(UUID().uuidString).gguf")
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 9_390_000_000)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: url) }

        let requested = LlamaConfig(
            batchSize: 128,
            microBatchSize: 128,
            maxTokenCount: 8_192,
            useGPU: true,
            gpuLayerCount: 64,
            generationThreadCount: 6,
            batchThreadCount: 6,
            loadMode: .automatic,
            keyCacheType: .f16,
            valueCacheType: .f16
        )
        let decision = LlamaRuntimeTuner.decide(
            modelURL: url,
            requested: requested,
            physicalMemoryBytes: 4_000_000_000
        )

        XCTAssertTrue(decision.storageBacked)
        XCTAssertEqual(decision.config.loadMode, .mmap)
        XCTAssertEqual(decision.config.keyCacheType, .q8_0)
        XCTAssertEqual(decision.config.valueCacheType, .q8_0)
        XCTAssertFalse(decision.config.useGPU)
        XCTAssertEqual(decision.config.gpuLayerCount, 0)
        XCTAssertFalse(decision.config.offloadKQV)
        XCTAssertFalse(decision.config.operationOffload)
        XCTAssertEqual(decision.config.microBatchSize, 8)
        XCTAssertEqual(decision.config.generationThreadCount, 2)
        XCTAssertFalse(decision.config.useExtraBufferTypes)
        XCTAssertTrue(decision.reason.contains("persistent Metal residency disabled"))
    }

    func testResidentModelPreservesRequestedProfile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-tuner-small-\(UUID().uuidString).gguf")
        try Data(repeating: 0, count: 4_096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let requested = LlamaConfig(
            batchSize: 64,
            maxTokenCount: 2_048,
            useGPU: true,
            gpuLayerCount: 8,
            generationThreadCount: 2,
            batchThreadCount: 4,
            loadMode: .automatic,
            keyCacheType: .f16,
            valueCacheType: .f16
        )
        let decision = LlamaRuntimeTuner.decide(
            modelURL: url,
            requested: requested,
            physicalMemoryBytes: 4_000_000_000
        )

        XCTAssertFalse(decision.storageBacked)
        XCTAssertEqual(decision.config, requested)
    }
}

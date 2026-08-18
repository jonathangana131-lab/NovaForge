import Foundation

/// Deterministic pre-context tuning for Apple unified-memory devices.
///
/// The point is not to make every compute unit busy. Decode is usually limited
/// by bytes moved per generated token, so the tuner avoids duplicate residency
/// and oversized scratch allocations when a GGUF is larger than available RAM.
/// Exact-device benchmark results can still override these defaults at the app
/// layer; this is the safe high-throughput baseline used before such evidence
/// exists.
public enum LlamaRuntimeTuner {
    public struct Decision: Equatable, Sendable {
        public let config: LlamaConfig
        public let modelBytes: UInt64
        public let physicalMemoryBytes: UInt64
        public let storageBacked: Bool
        public let reason: String
    }

    public static func decide(
        modelURL: URL,
        requested: LlamaConfig,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Decision {
        let fileBytes = modelFileSize(modelURL)
        guard fileBytes > 0, physicalMemoryBytes > 0 else {
            return Decision(
                config: requested,
                modelBytes: fileBytes,
                physicalMemoryBytes: physicalMemoryBytes,
                storageBacked: false,
                reason: "Model or memory size unavailable; preserved requested profile."
            )
        }

        // Leave a large fraction of physical RAM to iOS, SwiftUI, the agent
        // graph, recurrent/KV state, Metal scratch and file-cache pages. A model
        // exceeding this budget must be treated as a mapped/storage-backed
        // target rather than a conventional fully-resident model.
        let residentWeightBudget = physicalMemoryBytes * 58 / 100
        let storageBacked = fileBytes > residentWeightBudget
        guard storageBacked else {
            return Decision(
                config: requested,
                modelBytes: fileBytes,
                physicalMemoryBytes: physicalMemoryBytes,
                storageBacked: false,
                reason: "GGUF fits the resident-weight budget; preserved high-throughput requested profile."
            )
        }

        let extremeOversubscription = fileBytes > physicalMemoryBytes * 2
        let microBatch = min(requested.microBatchSize, extremeOversubscription ? 8 : 16)
        let logicalBatch = min(requested.batchSize, extremeOversubscription ? 24 : 48)

        // Current llama.cpp Metal on Apple unified-memory devices can wrap
        // existing mapped host pointers in MTLStorageModeShared buffers instead
        // of making a second private copy. We still keep the initial hot set tiny:
        // touching too many mapped pages can create residency pressure even when
        // the buffer itself is zero-copy. Exact-device telemetry may promote the
        // hot set later; the baseline never jumps straight to full offload.
        let boundedGPULayers: Int32
        if requested.useGPU {
            boundedGPULayers = min(max(requested.gpuLayerCount, 1), extremeOversubscription ? 1 : 2)
        } else {
            boundedGPULayers = 0
        }
        let useBoundedMetalHotSet = boundedGPULayers > 0

        // Q8 KV is the conservative compressed default: it materially reduces
        // long-context cache pressure without assuming Q4 quality is acceptable.
        // If the caller explicitly selected Q4, preserve it for a measured
        // extreme profile instead of silently expanding the cache again.
        let keyCache: LlamaKVCacheType = requested.keyCacheType == .f16 ? .q8_0 : requested.keyCacheType
        let valueCache: LlamaKVCacheType = requested.valueCacheType == .f16 ? .q8_0 : requested.valueCacheType

        let tuned = LlamaConfig(
            batchSize: logicalBatch,
            microBatchSize: microBatch,
            maxTokenCount: requested.maxTokenCount,
            useGPU: useBoundedMetalHotSet,
            gpuLayerCount: boundedGPULayers,
            generationThreadCount: min(requested.generationThreadCount, 2),
            batchThreadCount: min(max(requested.batchThreadCount, 2), 4),
            yieldEveryTokenCount: requested.yieldEveryTokenCount,
            loadMode: .mmap,
            flashAttention: requested.flashAttention == .disabled ? .disabled : .automatic,
            keyCacheType: keyCache,
            valueCacheType: valueCache,
            // Keep K/Q/V and generic operation offload disabled for the giant
            // target baseline. The hot set is weight-only until a device receipt
            // proves that broader graph offload improves throughput without
            // crossing the memory/thermal envelope.
            offloadKQV: false,
            operationOffload: false,
            unifiedKV: requested.unifiedKV,
            recurrentStateSnapshots: requested.recurrentStateSnapshots,
            // Repacking giant mapped tensors can create exactly the transient
            // memory spike this mode exists to avoid.
            useExtraBufferTypes: false
        )

        return Decision(
            config: tuned,
            modelBytes: fileBytes,
            physicalMemoryBytes: physicalMemoryBytes,
            storageBacked: true,
            reason: extremeOversubscription
                ? "Extreme storage-backed profile: mmap + compressed KV + 1 shared-Metal hot layer + tiny micro-batches; broader offload requires a device receipt."
                : "Storage-backed profile: mmap + compressed KV + at most 2 shared-Metal hot layers; broader offload requires measured headroom."
        )
    }

    private static func modelFileSize(_ url: URL) -> UInt64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]) else {
            return 0
        }

        // Runtime residency decisions must use the GGUF's *logical* byte length.
        // APFS sparse files, clones, compression, and partially de-duplicated
        // storage can make allocated blocks dramatically smaller than the address
        // range llama.cpp must map/touch. Using allocated size first could make a
        // multi-gigabyte target look like a tiny resident model.
        if let size = values.fileSize, size > 0 {
            return UInt64(size)
        }
        if let allocated = values.totalFileAllocatedSize, allocated > 0 {
            return UInt64(allocated)
        }
        return 0
    }
}

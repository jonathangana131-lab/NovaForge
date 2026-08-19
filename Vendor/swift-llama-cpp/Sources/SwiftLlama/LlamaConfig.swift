//
//  LlamaConfig.swift
//  LlamaSwift
//
//  Created by Piotr Gorzelany on 05/11/2024.
//

/// Model-file loading policy. `automatic` keeps upstream llama.cpp defaults,
/// while `mmap` explicitly requests file-backed model weights so large GGUFs
/// can stay file-backed instead of requiring a second anonymous-memory copy.
public enum LlamaModelLoadMode: String, Equatable, Sendable {
    case automatic
    case mmap
}

/// KV-cache storage precision. F16 remains the fast compatibility baseline.
/// Quantized KV is reserved for measured or allocation-triggered rescue paths.
public enum LlamaKVCacheType: String, Equatable, Sendable {
    case f16
    case q8_0
    case q4_0
}

/// Flash Attention selection. `automatic` delegates backend capability and
/// scheduling decisions to llama.cpp.
public enum LlamaFlashAttentionMode: String, Equatable, Sendable {
    case automatic
    case disabled
    case enabled
}

/// A deterministic context-allocation attempt. Keeping the requested and rescue
/// profiles explicit prevents runtime logs/documentation from drifting away
/// from the actual KV precision and allocation bounds used by llama.cpp.
struct LlamaContextAllocationProfile: Equatable, Sendable {
    let contextTokens: UInt32
    let batchTokens: UInt32
    let keyCacheType: LlamaKVCacheType
    let valueCacheType: LlamaKVCacheType

    /// llama.cpp may normalize context parameters after construction. Execution
    /// must never use a larger logical batch than either the selected policy or
    /// the actual context reports, and Swift's batch wrapper requires Int32.
    func reconciledBatchTokens(actualContextBatch: UInt32) -> UInt32? {
        guard actualContextBatch > 0 else { return nil }
        let effective = min(batchTokens, actualContextBatch)
        guard effective > 0, effective <= UInt32(Int32.max) else { return nil }
        return effective
    }
}

public struct LlamaConfig: Equatable, Sendable {
    public let batchSize: UInt32
    public let maxTokenCount: UInt32
    public let useGPU: Bool
    public let gpuLayerCount: Int32
    public let generationThreadCount: Int32
    public let batchThreadCount: Int32
    public let yieldEveryTokenCount: Int
    public let modelLoadMode: LlamaModelLoadMode
    public let keyCacheType: LlamaKVCacheType
    public let valueCacheType: LlamaKVCacheType
    public let flashAttentionMode: LlamaFlashAttentionMode
    public let offloadKQV: Bool
    /// When the requested context cannot be allocated, allow the runtime to
    /// retry smaller/quantized contexts instead of immediately failing. The
    /// normal fast path is unchanged when its first allocation succeeds.
    public let allowLowMemoryFallback: Bool

    public init(
        batchSize: UInt32,
        maxTokenCount: UInt32,
        useGPU: Bool = true,
        gpuLayerCount: Int32 = 99,
        generationThreadCount: Int32 = 2,
        batchThreadCount: Int32 = 2,
        yieldEveryTokenCount: Int = 1,
        modelLoadMode: LlamaModelLoadMode = .mmap,
        keyCacheType: LlamaKVCacheType = .f16,
        valueCacheType: LlamaKVCacheType = .f16,
        flashAttentionMode: LlamaFlashAttentionMode = .automatic,
        offloadKQV: Bool = true,
        allowLowMemoryFallback: Bool = true
    ) {
        self.batchSize = max(1, batchSize)
        self.maxTokenCount = max(256, maxTokenCount)
        self.useGPU = useGPU
        self.gpuLayerCount = gpuLayerCount
        self.generationThreadCount = max(1, generationThreadCount)
        self.batchThreadCount = max(1, batchThreadCount)
        self.yieldEveryTokenCount = max(1, yieldEveryTokenCount)
        self.modelLoadMode = modelLoadMode
        self.keyCacheType = keyCacheType
        self.valueCacheType = valueCacheType
        self.flashAttentionMode = flashAttentionMode
        self.offloadKQV = offloadKQV
        self.allowLowMemoryFallback = allowLowMemoryFallback
    }

    var requestedAllocationProfile: LlamaContextAllocationProfile {
        LlamaContextAllocationProfile(
            contextTokens: maxTokenCount,
            batchTokens: batchSize,
            keyCacheType: keyCacheType,
            valueCacheType: valueCacheType
        )
    }

    /// First rescue tier: preserve the broadly compatible F16 KV fast path
    /// while reducing the two largest configurable context allocations.
    var fastLowMemoryAllocationProfile: LlamaContextAllocationProfile {
        LlamaContextAllocationProfile(
            contextTokens: min(maxTokenCount, 1_024),
            batchTokens: min(batchSize, 32),
            keyCacheType: .f16,
            valueCacheType: .f16
        )
    }

    /// Deep rescue tier: trade additional throughput for a smaller Q8 KV cache
    /// after both the requested and F16 fast-memory allocations fail.
    var deepLowMemoryAllocationProfile: LlamaContextAllocationProfile {
        LlamaContextAllocationProfile(
            contextTokens: min(maxTokenCount, 768),
            batchTokens: min(batchSize, 16),
            keyCacheType: .q8_0,
            valueCacheType: .q8_0
        )
    }
}

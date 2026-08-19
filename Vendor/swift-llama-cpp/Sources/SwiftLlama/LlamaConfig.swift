//
//  LlamaConfig.swift
//  LlamaSwift
//
//  Created by Piotr Gorzelany on 05/11/2024.
//

/// Stable Swift-side model loading choices. Keeping the C enum out of the
/// public configuration makes the wrapper easier to evolve across llama.cpp
/// releases while still exposing the loading modes that matter on iOS.
public enum LlamaModelLoadMode: String, Equatable, Sendable {
    case automatic
    case mmap
    case directIO
}

/// KV cache precision is one of the highest-leverage memory controls for
/// long-running agents. Q8 is the conservative compressed mode; Q4 is
/// intentionally opt-in until exact-device quality/performance is measured.
public enum LlamaKVCacheType: String, Equatable, Sendable {
    case f16
    case q8_0
    case q4_0
}

public enum LlamaFlashAttentionMode: String, Equatable, Sendable {
    case automatic
    case disabled
    case enabled
}

public struct LlamaConfig: Equatable, Sendable {
    public let batchSize: UInt32
    public let microBatchSize: UInt32
    public let maxTokenCount: UInt32
    public let useGPU: Bool
    public let gpuLayerCount: Int32
    public let generationThreadCount: Int32
    public let batchThreadCount: Int32
    public let yieldEveryTokenCount: Int
    public let loadMode: LlamaModelLoadMode
    public let flashAttention: LlamaFlashAttentionMode
    public let keyCacheType: LlamaKVCacheType
    public let valueCacheType: LlamaKVCacheType
    public let offloadKQV: Bool
    public let operationOffload: Bool
    public let unifiedKV: Bool
    public let recurrentStateSnapshots: UInt32
    public let useExtraBufferTypes: Bool

    public init(
        batchSize: UInt32,
        microBatchSize: UInt32? = nil,
        maxTokenCount: UInt32,
        useGPU: Bool = true,
        gpuLayerCount: Int32 = 99,
        generationThreadCount: Int32 = 2,
        batchThreadCount: Int32 = 2,
        yieldEveryTokenCount: Int = 1,
        loadMode: LlamaModelLoadMode = .automatic,
        flashAttention: LlamaFlashAttentionMode = .automatic,
        keyCacheType: LlamaKVCacheType = .f16,
        valueCacheType: LlamaKVCacheType = .f16,
        offloadKQV: Bool = true,
        operationOffload: Bool = true,
        unifiedKV: Bool = true,
        recurrentStateSnapshots: UInt32 = 0,
        useExtraBufferTypes: Bool = true
    ) {
        self.batchSize = max(1, batchSize)
        self.microBatchSize = max(1, min(microBatchSize ?? batchSize, batchSize))
        self.maxTokenCount = max(64, maxTokenCount)
        self.useGPU = useGPU
        self.gpuLayerCount = useGPU ? gpuLayerCount : 0
        self.generationThreadCount = max(1, generationThreadCount)
        self.batchThreadCount = max(1, batchThreadCount)
        self.yieldEveryTokenCount = max(1, yieldEveryTokenCount)
        self.loadMode = loadMode
        self.flashAttention = flashAttention
        self.keyCacheType = keyCacheType
        self.valueCacheType = valueCacheType
        self.offloadKQV = offloadKQV
        self.operationOffload = operationOffload
        self.unifiedKV = unifiedKV
        self.recurrentStateSnapshots = recurrentStateSnapshots
        self.useExtraBufferTypes = useExtraBufferTypes
    }
}

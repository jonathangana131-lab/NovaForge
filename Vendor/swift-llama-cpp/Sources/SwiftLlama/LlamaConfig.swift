import llama

//
//  LlamaConfig.swift
//  LlamaSwift
//
//  Created by Piotr Gorzelany on 05/11/2024.
//

public enum LlamaComputeMode: String, Equatable, Sendable {
    case cpu
    case metalPartial
    case metalFull
}

public enum LlamaKVCacheType: String, Equatable, Sendable {
    case f16
    case q8_0
    case bf16
}

extension LlamaKVCacheType {
    var ggmlType: ggml_type {
        switch self {
        case .f16: GGML_TYPE_F16
        case .q8_0: GGML_TYPE_Q8_0
        case .bf16: GGML_TYPE_BF16
        }
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
    public let computeMode: LlamaComputeMode
    public let maxOutputTokenCount: UInt32
    public let reducedMemoryMode: Bool
    public let reusePromptPrefix: Bool
    public let kvCacheType: LlamaKVCacheType
    public let flashAttention: Bool
    public let outOfCoreResidentBudgetBytes: UInt64

    public init(
        batchSize: UInt32,
        maxTokenCount: UInt32,
        useGPU: Bool = true,
        gpuLayerCount: Int32 = 99,
        generationThreadCount: Int32 = 2,
        batchThreadCount: Int32 = 2,
        yieldEveryTokenCount: Int = 1,
        computeMode: LlamaComputeMode? = nil,
        maxOutputTokenCount: UInt32 = 1_024,
        reducedMemoryMode: Bool = false,
        reusePromptPrefix: Bool = true,
        kvCacheType: LlamaKVCacheType = .f16,
        flashAttention: Bool = true,
        outOfCoreResidentBudgetBytes: UInt64 = 0
    ) {
        self.batchSize = max(1, batchSize)
        self.maxTokenCount = max(1, maxTokenCount)
        self.useGPU = useGPU
        self.gpuLayerCount = gpuLayerCount
        self.generationThreadCount = max(1, generationThreadCount)
        self.batchThreadCount = max(1, batchThreadCount)
        self.yieldEveryTokenCount = max(1, yieldEveryTokenCount)
        self.computeMode = computeMode ?? (useGPU ? .metalPartial : .cpu)
        self.maxOutputTokenCount = max(1, maxOutputTokenCount)
        self.reducedMemoryMode = reducedMemoryMode
        self.reusePromptPrefix = reusePromptPrefix
        self.kvCacheType = kvCacheType
        self.flashAttention = flashAttention
        self.outOfCoreResidentBudgetBytes = outOfCoreResidentBudgetBytes
    }
}

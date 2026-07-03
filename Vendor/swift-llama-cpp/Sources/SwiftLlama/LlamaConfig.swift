//
//  LlamaConfig.swift
//  LlamaSwift
//
//  Created by Piotr Gorzelany on 05/11/2024.
//

public struct LlamaConfig: Equatable, Sendable {
    public let batchSize: UInt32
    public let maxTokenCount: UInt32
    public let useGPU: Bool
    public let gpuLayerCount: Int32
    public let generationThreadCount: Int32
    public let batchThreadCount: Int32
    public let yieldEveryTokenCount: Int

    public init(
        batchSize: UInt32,
        maxTokenCount: UInt32,
        useGPU: Bool = true,
        gpuLayerCount: Int32 = 99,
        generationThreadCount: Int32 = 2,
        batchThreadCount: Int32 = 2,
        yieldEveryTokenCount: Int = 1
    ) {
        self.batchSize = batchSize
        self.maxTokenCount = maxTokenCount
        self.useGPU = useGPU
        self.gpuLayerCount = gpuLayerCount
        self.generationThreadCount = max(1, generationThreadCount)
        self.batchThreadCount = max(1, batchThreadCount)
        self.yieldEveryTokenCount = max(1, yieldEveryTokenCount)
    }
}

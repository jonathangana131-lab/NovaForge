import Testing
@testable import SwiftLlama

struct LlamaBatchTests {
    @Test("Empty batch logits marking is a safe no-op")
    func emptyBatchLogitsNoOp() {
        let batch = LlamaBatch(initialSize: 4)

        batch.setLastTokenLogits(true)

        #expect(batch.size == 0)
    }

    @Test("A full final prompt batch is retained for logits")
    func fullFinalPromptBatchIsNotFlushedEarly() {
        #expect(!LlamaBatch.shouldFlushPromptBatch(
            currentSize: 64,
            capacity: 64,
            tokenIndex: 63,
            tokenCount: 64
        ))

        #expect(LlamaBatch.shouldFlushPromptBatch(
            currentSize: 64,
            capacity: 64,
            tokenIndex: 63,
            tokenCount: 65
        ))

        #expect(!LlamaBatch.shouldFlushPromptBatch(
            currentSize: 64,
            capacity: 64,
            tokenIndex: 127,
            tokenCount: 128
        ))
    }

    @Test("Prompt batch flushing rejects partial and invalid profiles")
    func promptBatchFlushBounds() {
        #expect(!LlamaBatch.shouldFlushPromptBatch(
            currentSize: 63,
            capacity: 64,
            tokenIndex: 62,
            tokenCount: 65
        ))
        #expect(!LlamaBatch.shouldFlushPromptBatch(
            currentSize: 64,
            capacity: 0,
            tokenIndex: 63,
            tokenCount: 65
        ))
        #expect(!LlamaBatch.shouldFlushPromptBatch(
            currentSize: 64,
            capacity: UInt32(Int32.max) + 1,
            tokenIndex: 63,
            tokenCount: 65
        ))
        #expect(!LlamaBatch.shouldFlushPromptBatch(
            currentSize: 64,
            capacity: 64,
            tokenIndex: -1,
            tokenCount: 65
        ))
    }
}

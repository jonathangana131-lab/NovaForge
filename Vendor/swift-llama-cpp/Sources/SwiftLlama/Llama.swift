import Foundation
import llama

enum NextToken {
    case token(String)
    case endOfString
}

final actor Llama {
    private let model: LlamaModel
    let context: LlamaContext
    private var batch: LlamaBatch
    private var sampler: LlamaSampler!

    // Configuration

    private let config: LlamaConfig
    private let effectiveBatchSize: UInt32
    let maxTokenCount: UInt32
    /// Tracks the current position in the token sequence during decoding.
    var currentTokenPosition: Int32 = 0
    var processedTokens: [llama_token] = []

    init(modelPath: String, config: LlamaConfig) throws {
        self.config = config
        llama_backend_init()
        var modelParams = llama_model_default_params()

        modelParams.n_gpu_layers = config.useGPU ? config.gpuLayerCount : 0
        switch config.modelLoadMode {
        case .automatic:
            modelParams.load_mode = LLAMA_LOAD_MODE_AUTO
        case .mmap:
            modelParams.load_mode = LLAMA_LOAD_MODE_MMAP
        }

        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        print("Running on simulator, force use n_gpu_layers = 0")
        #endif

        let model = LlamaModel(path: modelPath, parameters: modelParams)
        guard let model else {
            print("Could not load model at \(modelPath)")
            throw LlamaError.couldNotInitializeContext
        }

        print("Using \(config.generationThreadCount) generation threads, \(config.batchThreadCount) batch threads, \(modelParams.n_gpu_layers) GPU layers")

        func cacheType(_ type: LlamaKVCacheType) -> ggml_type {
            switch type {
            case .f16: GGML_TYPE_F16
            case .q8_0: GGML_TYPE_Q8_0
            case .q4_0: GGML_TYPE_Q4_0
            }
        }

        func contextParameters(
            contextTokens: UInt32,
            batchTokens: UInt32,
            keyType: LlamaKVCacheType,
            valueType: LlamaKVCacheType
        ) -> llama_context_params {
            var params = llama_context_default_params()
            params.n_ctx = contextTokens
            params.n_threads = config.generationThreadCount
            params.n_threads_batch = config.batchThreadCount
            params.n_batch = batchTokens
            params.n_ubatch = batchTokens
            params.offload_kqv = config.offloadKQV
            params.type_k = cacheType(keyType)
            params.type_v = cacheType(valueType)

            switch config.flashAttentionMode {
            case .automatic:
                params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
            case .disabled:
                params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED
            case .enabled:
                params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
            }
            return params
        }

        func makeContext(
            contextTokens: UInt32,
            batchTokens: UInt32,
            keyType: LlamaKVCacheType,
            valueType: LlamaKVCacheType
        ) -> LlamaContext? {
            let params = contextParameters(
                contextTokens: contextTokens,
                batchTokens: batchTokens,
                keyType: keyType,
                valueType: valueType
            )
            return LlamaContext(model: model, parameters: params)
        }

        var selectedContextTokens = config.maxTokenCount
        var selectedBatchTokens = config.batchSize
        var selectedProfile = "requested"
        var selectedContext = makeContext(
            contextTokens: selectedContextTokens,
            batchTokens: selectedBatchTokens,
            keyType: config.keyCacheType,
            valueType: config.valueCacheType
        )

        if selectedContext == nil, config.allowLowMemoryFallback {
            // First rescue tier preserves F16 KV speed and simply reduces the
            // allocation surfaces most likely to fail on 4 GB-class phones.
            let reducedContext = min(config.maxTokenCount, 1_024)
            let reducedBatch = min(config.batchSize, 32)
            if reducedContext != selectedContextTokens || reducedBatch != selectedBatchTokens {
                print("Context allocation failed; retrying fast low-memory profile (ctx=\(reducedContext), batch=\(reducedBatch), F16 KV)")
                selectedContext = makeContext(
                    contextTokens: reducedContext,
                    batchTokens: reducedBatch,
                    keyType: config.keyCacheType,
                    valueType: config.valueCacheType
                )
                if selectedContext != nil {
                    selectedContextTokens = reducedContext
                    selectedBatchTokens = reducedBatch
                    selectedProfile = "fast-memory-rescue"
                }
            }

            // Deep rescue only runs after both requested and reduced fast
            // allocations fail. Q8 KV can trade throughput for a much smaller
            // cache, so it is intentionally failure-triggered rather than the
            // universal default on Apple GPUs.
            if selectedContext == nil {
                let rescueContext = min(config.maxTokenCount, 768)
                let rescueBatch = min(config.batchSize, 16)
                print("Fast context allocation still failed; retrying deep low-memory profile (ctx=\(rescueContext), batch=\(rescueBatch), Q8 KV)")
                selectedContext = makeContext(
                    contextTokens: rescueContext,
                    batchTokens: rescueBatch,
                    keyType: .q8_0,
                    valueType: .q8_0
                )
                if selectedContext != nil {
                    selectedContextTokens = rescueContext
                    selectedBatchTokens = rescueBatch
                    selectedProfile = "quantized-memory-rescue"
                }
            }
        }

        guard let context = selectedContext else {
            print("Could not load context after all configured allocation tiers")
            throw LlamaError.couldNotInitializeContext
        }

        print("Selected llama context profile: \(selectedProfile), ctx=\(selectedContextTokens), batch=\(selectedBatchTokens)")
        self.maxTokenCount = min(UInt32(model.trainedContextSize()), selectedContextTokens)
        self.effectiveBatchSize = selectedBatchTokens
        self.model = context.model
        self.context = context
        self.batch = .init(initialSize: Int32(selectedBatchTokens))
    }

    deinit {
        llama_backend_free()
    }

    // Expose some backend/system utilities for convenience
    /// Return system info string from the backend.
    static func printSystemInfo() -> String {
        guard let c = llama_print_system_info() else { return "" }
        return String(cString: c)
    }

    /// Expose the underlying context to trusted callers (tests / advanced users).
    /// Access is actor-isolated; callers must `await`.
    func contextHandle() -> LlamaContext { context }

    // MARK: - Testing & Introspection helpers (actor-safe)

    func getLastLogits() -> [Float]? { context.lastLogits() }
    func getEmbeddings() -> [Float]? { context.embeddings(at: -1) }
    func enableEmbeddingsOutput(_ enabled: Bool) { context.setEmbeddingsOutput(enabled) }
    func saveStateData() -> Data { context.saveState() }
    func loadStateData(_ data: Data) -> Bool { context.loadState(data) }
    func setThreads(nThreads: Int32, nThreadsBatch: Int32) { context.setThreads(nThreads: nThreads, nThreadsBatch: nThreadsBatch) }
    func getThreads() -> (Int32, Int32) { (context.nThreads(), context.nThreadsBatch()) }
    func kvMinPosition() -> Int32 { context.memory.minPosition(for: 0) }
    func kvMaxPosition() -> Int32 { context.memory.maxPosition(for: 0) }
    func clearKV() { context.clearKVCache() }

    /// Return the full processed token id sequence (prompt + generated).
    func getProcessedTokenIds() -> [llama_token] { processedTokens }

    func initializeCompletion(messages: [LlamaChatMessage], addAssistant: Bool? = nil) throws {
        let formattedPrompt = model.applyChatTemplate(to: messages, addAssistant: addAssistant)
        try initializeCompletion(text: formattedPrompt)
    }

    private func initializeCompletion(text: String) throws {
        print("attempting to complete \"\(text)\"")

        let tokenList = model.tokenize(text: text, addBos: model.shouldAddBos(), special: true)
        guard tokenList.count < maxTokenCount - 4 else {
            throw LlamaError.contextSizeLimitExeeded
        }

        if tokenList.starts(with: processedTokens) {
            print("### Using cached processing")
            try processPrompt(tokens: Array(tokenList[processedTokens.count...]), startIndex: processedTokens.count)
        } else {
            // Check if we can optimize by only clearing from the divergence point
            let divergenceIndex = findDivergenceIndex(newTokenList: tokenList, processedTokens: processedTokens)

            if divergenceIndex > 0 && shouldUsePartialOptimization(divergenceIndex: divergenceIndex, totalProcessed: processedTokens.count) {
                print("### Using partial optimization from position \(divergenceIndex)")
                do {
                    try optimizedReprocessing(newTokenList: tokenList, divergenceIndex: divergenceIndex)
                } catch {
                    print("Partial optimization failed, falling back to full reprocessing")
                    clear()
                    try processPrompt(tokens: tokenList, startIndex: 0)
                }
            } else {
                print("### Full reprocessing required")
                clear()
                try processPrompt(tokens: tokenList, startIndex: 0)
            }
        }
    }

    /// Find the index where the two token lists diverge
    private func findDivergenceIndex(newTokenList: [llama_token], processedTokens: [llama_token]) -> Int {
        let minLength = min(newTokenList.count, processedTokens.count)
        for i in 0..<minLength {
            if newTokenList[i] != processedTokens[i] {
                return i
            }
        }
        return minLength
    }

    /// Decide whether to use partial optimization based on the divergence point
    private func shouldUsePartialOptimization(divergenceIndex: Int, totalProcessed: Int) -> Bool {
        guard divergenceIndex > 0 && totalProcessed >= 10 else { return false }
        let matchPercentage = Double(divergenceIndex) / Double(totalProcessed)
        return matchPercentage >= 0.5
    }

    /// Optimized reprocessing that only clears cache from the divergence point onward
    private func optimizedReprocessing(newTokenList: [llama_token], divergenceIndex: Int) throws {
        context.clearKVCacheFromPosition(Int32(divergenceIndex))
        processedTokens = Array(processedTokens[0..<divergenceIndex])
        currentTokenPosition = Int32(divergenceIndex)
        let tokensToProcess = Array(newTokenList[divergenceIndex...])
        try processPrompt(tokens: tokensToProcess, startIndex: divergenceIndex)
    }

    func generateNextToken() throws -> NextToken {
        if currentTokenPosition >= Int32(maxTokenCount) {
            return .endOfString
        }
        let newTokenId = sampler.sample(context: context)

        if model.isEogToken(newTokenId) || currentTokenPosition >= Int32(maxTokenCount) {
            return .endOfString
        }

        batch.reset()
        batch.addToken(newTokenId, at: currentTokenPosition, logits: true)
        processedTokens.append(newTokenId)

        currentTokenPosition += 1
        try context.decode(batch: batch)

        return .token(model.piece(from: newTokenId))
    }

    func updateSamplingConfig(_ config: LlamaSamplingConfig) throws {
        self.sampler = try .init(config: config, model: model)
    }

    private func clear() {
        context.clearKVCache()
        processedTokens = []
        batch = .init(initialSize: Int32(effectiveBatchSize))
    }

    private func processBatch() throws {
        do {
            try context.decode(batch: batch)
        } catch {
            print("llama_decode() failed")
            throw LlamaError.decodingError
        }
    }

    private func processPrompt(tokens: [llama_token], startIndex: Int) throws {
        guard !tokens.isEmpty else { return }
        batch.reset()

        for i in 0..<tokens.count {
            let tokenPosition = startIndex + i
            let tokenId = tokens[i]
            batch.addToken(tokenId, at: Int32(tokenPosition), logits: false)
            processedTokens.append(tokenId)
            if batch.size == effectiveBatchSize {
                try processBatch()
                batch.reset()
            }
        }

        batch.setLastTokenLogits(true)
        try processBatch()
        currentTokenPosition = Int32(processedTokens.count)
    }
}

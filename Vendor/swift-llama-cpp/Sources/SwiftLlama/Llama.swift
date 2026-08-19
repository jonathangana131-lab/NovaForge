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
    let maxTokenCount: UInt32
    /// Tracks the current position in the token sequence during decoding.
    var currentTokenPosition: Int32 = 0
    var processedTokens: [llama_token] = []

    init(modelPath: String, config: LlamaConfig) throws {
        self.config = config
        llama_backend_init()
        var modelParams = llama_model_default_params()

        modelParams.n_gpu_layers = config.useGPU ? config.gpuLayerCount : 0
        modelParams.load_mode = Self.loadMode(config.loadMode)
        modelParams.use_extra_bufts = config.useExtraBufferTypes
        // MTP is a separate speculative context with different recurrent-state
        // requirements. Never silently load it into the ordinary target context.
        modelParams.load_mtp = false

        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        print("Running on simulator, force use n_gpu_layers = 0")
        #endif

        let model = LlamaModel(path: modelPath, parameters: modelParams)
        guard let model else {
            print("Could not load model at \(modelPath)")
            throw LlamaError.couldNotInitializeContext
        }

        print(
            "Using \(config.generationThreadCount) generation threads, " +
            "\(config.batchThreadCount) batch threads, \(modelParams.n_gpu_layers) GPU layers, " +
            "load=\(config.loadMode.rawValue), kv=\(config.keyCacheType.rawValue)/\(config.valueCacheType.rawValue)"
        )

        var contextParam = llama_context_default_params()
        contextParam.n_ctx = config.maxTokenCount
        contextParam.n_threads = config.generationThreadCount
        contextParam.n_threads_batch = config.batchThreadCount
        contextParam.n_batch = config.batchSize
        contextParam.n_ubatch = config.microBatchSize
        contextParam.n_rs_seq = config.recurrentStateSnapshots
        contextParam.flash_attn_type = Self.flashAttention(config.flashAttention)
        contextParam.type_k = Self.cacheType(config.keyCacheType)
        contextParam.type_v = Self.cacheType(config.valueCacheType)
        contextParam.offload_kqv = config.useGPU && config.offloadKQV
        contextParam.op_offload = config.useGPU && config.operationOffload
        contextParam.kv_unified = config.unifiedKV

        let context = LlamaContext(model: model, parameters: contextParam)
        guard let context else {
            print("Could not load context!")
            throw LlamaError.couldNotInitializeContext
        }

        self.maxTokenCount = min(UInt32(model.trainedContextSize()), config.maxTokenCount)
        self.model = context.model
        self.context = context
        self.batch = .init(initialSize: Int32(config.batchSize))
    }

    deinit {
        llama_backend_free()
    }

    private static func loadMode(_ mode: LlamaModelLoadMode) -> llama_load_mode {
        switch mode {
        case .automatic: LLAMA_LOAD_MODE_AUTO
        case .mmap: LLAMA_LOAD_MODE_MMAP
        case .directIO: LLAMA_LOAD_MODE_DIRECT_IO
        }
    }

    private static func flashAttention(_ mode: LlamaFlashAttentionMode) -> llama_flash_attn_type {
        switch mode {
        case .automatic: LLAMA_FLASH_ATTN_TYPE_AUTO
        case .disabled: LLAMA_FLASH_ATTN_TYPE_DISABLED
        case .enabled: LLAMA_FLASH_ATTN_TYPE_ENABLED
        }
    }

    private static func cacheType(_ type: LlamaKVCacheType) -> ggml_type {
        switch type {
        case .f16: GGML_TYPE_F16
        case .q8_0: GGML_TYPE_Q8_0
        case .q4_0: GGML_TYPE_Q4_0
        }
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
    func persistentStateSizeBytes() -> Int { context.stateSize() }

    /// Restore a llama.cpp session only when its saved token stream is a proven
    /// prefix of the exact prompt about to run. A mismatched or stale session is
    /// immediately cleared, so persistence can only improve TTFT—not alter the
    /// model's logical context.
    func restoreSessionIfPrefix(
        from url: URL,
        messages: [LlamaChatMessage],
        addAssistant: Bool? = nil
    ) throws -> Bool {
        let formattedPrompt = model.applyChatTemplate(to: messages, addAssistant: addAssistant)
        let tokenList = model.tokenize(text: formattedPrompt, addBos: model.shouldAddBos(), special: true)
        guard tokenList.count < maxTokenCount - 4 else {
            throw LlamaError.contextSizeLimitExeeded
        }

        clear()
        guard let loaded = context.loadSession(
            from: url.path(percentEncoded: false),
            capacity: Int(maxTokenCount)
        ), loaded.count > 0,
           loaded.count == loaded.tokens.count,
           tokenList.starts(with: loaded.tokens)
        else {
            clear()
            return false
        }

        processedTokens = loaded.tokens
        currentTokenPosition = Int32(loaded.count)
        batch = .init(initialSize: Int32(config.batchSize))

        let suffix = Array(tokenList.dropFirst(loaded.count))
        if !suffix.isEmpty {
            try processPrompt(tokens: suffix, startIndex: loaded.count)
        }
        return true
    }

    func saveSession(to url: URL) -> Bool {
        guard !processedTokens.isEmpty else { return false }
        return context.saveSession(
            to: url.path(percentEncoded: false),
            tokens: processedTokens
        )
    }
    func setThreads(nThreads: Int32, nThreadsBatch: Int32) { context.setThreads(nThreads: nThreads, nThreadsBatch: nThreadsBatch) }
    func getThreads() -> (Int32, Int32) { (context.nThreads(), context.nThreadsBatch()) }
    func kvMinPosition() -> Int32 { context.memory.minPosition(for: 0) }
    func kvMaxPosition() -> Int32 { context.memory.maxPosition(for: 0) }
    func clearKV() { context.clearKVCache() }

    /// Return the full processed token id sequence (prompt + generated).
    func getProcessedTokenIds() -> [llama_token] { processedTokens }

    func modelIdentitySnapshot() -> LlamaModelIdentitySnapshot {
        model.identitySnapshot()
    }

    func initializeCompletion(messages: [LlamaChatMessage], addAssistant: Bool? = nil) throws {
        let formattedPrompt = model.applyChatTemplate(to: messages, addAssistant: addAssistant)
        try initializeCompletion(text: formattedPrompt)
    }

    private func initializeCompletion(text: String) throws {
        let tokenList = model.tokenize(text: text, addBos: model.shouldAddBos(), special: true)
        guard tokenList.count < maxTokenCount - 4 else {
            throw LlamaError.contextSizeLimitExeeded
        }

        if tokenList.starts(with: processedTokens) {
            let suffix = Array(tokenList.dropFirst(processedTokens.count))
            if !suffix.isEmpty {
                try processPrompt(tokens: suffix, startIndex: processedTokens.count)
            }
            return
        }

        // Rewind only the divergent suffix. Long-running agents deliberately
        // keep the system/developer prefix byte-stable, so this is the normal
        // fast path after the first turn rather than an exceptional shortcut.
        let divergenceIndex = findDivergenceIndex(
            newTokenList: tokenList,
            processedTokens: processedTokens
        )
        if shouldUsePartialOptimization(
            divergenceIndex: divergenceIndex,
            newTokenCount: tokenList.count,
            totalProcessed: processedTokens.count
        ) {
            do {
                try optimizedReprocessing(
                    newTokenList: tokenList,
                    divergenceIndex: divergenceIndex
                )
                return
            } catch {
                // Recurrent/hybrid models may reject some suffix rewinds. Fall
                // back to a correctness-first full prefill instead of carrying
                // a corrupted state forward.
                print("Partial prompt reuse failed; rebuilding the prompt state: \(error)")
            }
        }

        clear()
        try processPrompt(tokens: tokenList, startIndex: 0)
    }

    /// Find the index where the two token lists diverge.
    private func findDivergenceIndex(
        newTokenList: [llama_token],
        processedTokens: [llama_token]
    ) -> Int {
        let minLength = min(newTokenList.count, processedTokens.count)
        for index in 0..<minLength where newTokenList[index] != processedTokens[index] {
            return index
        }
        return minLength
    }

    /// Prefix reuse is worthwhile once it saves a meaningful prefill. Using a
    /// fixed minimum instead of a percentage lets a large immutable agent
    /// prefix remain cached even when the volatile project tail grows huge.
    private func shouldUsePartialOptimization(
        divergenceIndex: Int,
        newTokenCount: Int,
        totalProcessed: Int
    ) -> Bool {
        guard divergenceIndex >= 32,
              divergenceIndex < newTokenCount,
              totalProcessed >= 32 else { return false }
        return true
    }

    /// Optimized reprocessing that only clears cache/state from divergence.
    private func optimizedReprocessing(
        newTokenList: [llama_token],
        divergenceIndex: Int
    ) throws {
        context.clearKVCacheFromPosition(Int32(divergenceIndex))
        processedTokens = Array(processedTokens.prefix(divergenceIndex))
        currentTokenPosition = Int32(divergenceIndex)
        try processPrompt(
            tokens: Array(newTokenList.dropFirst(divergenceIndex)),
            startIndex: divergenceIndex
        )
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
        currentTokenPosition = 0
        batch = .init(initialSize: Int32(config.batchSize))
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
            if batch.size == config.batchSize {
                try processBatch()
                batch.reset()
            }
        }

        batch.setLastTokenLogits(true)
        try processBatch()
        currentTokenPosition = Int32(processedTokens.count)
    }
}

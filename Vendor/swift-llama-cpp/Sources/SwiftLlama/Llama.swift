import Foundation
import llama

enum NextToken {
    case token(String)
    case endOfString
}

final actor Llama {
    private let backendLease: LlamaBackendLease
    private let model: LlamaModel
    let context: LlamaContext
    private var batch: LlamaBatch
    private var sampler: LlamaSampler!

    // Configuration

    private let config: LlamaConfig
    let maxTokenCount: UInt32
    let maxOutputTokenCount: UInt32
    private var generationStartTokenPosition: Int32 = 0
    /// Tracks the current position in the token sequence during decoding.
    var currentTokenPosition: Int32 = 0
    var processedTokens: [llama_token] = []

    init(modelPath: String, config: LlamaConfig) throws {
        self.config = config
        let backendLease = LlamaBackend.acquire()
        var model_params = llama_model_default_params()
        let outOfCoreCoordinator = LlamaOutOfCoreCoordinator.make(
            modelPath: modelPath,
            residentBudgetBytes: config.outOfCoreResidentBudgetBytes
        )
        if outOfCoreCoordinator != nil {
            #if targetEnvironment(simulator)
            // The pinned Intel-compatible simulator archive predates the
            // load_mode enum but exposes the equivalent mmap switch.
            model_params.use_mmap = true
            #else
            model_params.load_mode = LLAMA_LOAD_MODE_MMAP
            #endif
        }
        let selection = LlamaBackend.select(
            config.computeMode,
            gpuLayerCount: config.gpuLayerCount
        )
        model_params.n_gpu_layers = selection.gpuLayerCount

        let model = LlamaModel(path: modelPath, parameters: model_params)
        guard let model else {
            print("Could not load model at \(modelPath)")
            throw LlamaError.couldNotInitializeContext
        }

        print("Compute: \(selection.effective.rawValue), \(selection.reason), \(model_params.n_gpu_layers) GPU layers")

        let contextCap: UInt32 = config.reducedMemoryMode ? 8_192 : 32_768
        let effectiveContextCount = min(
            UInt32(model.trainedContextSize()),
            config.maxTokenCount,
            contextCap
        )
        var contextParam = llama_context_default_params()
        contextParam.n_ctx = effectiveContextCount
        contextParam.n_threads = config.generationThreadCount
        contextParam.n_threads_batch = config.batchThreadCount
        contextParam.n_batch = config.batchSize
        contextParam.n_ubatch = config.batchSize
        contextParam.offload_kqv = selection.effective != .cpu
        contextParam.type_k = config.kvCacheType.ggmlType
        contextParam.type_v = config.kvCacheType.ggmlType
        #if targetEnvironment(simulator)
        contextParam.flash_attn = config.flashAttention &&
            selection.effective != .cpu
        #else
        contextParam.flash_attn_type = config.flashAttention &&
            selection.effective != .cpu
            ? LLAMA_FLASH_ATTN_TYPE_ENABLED
            : LLAMA_FLASH_ATTN_TYPE_DISABLED
        #endif

        let context = LlamaContext(
            model: model,
            parameters: contextParam,
            outOfCoreCoordinator: outOfCoreCoordinator
        )
        guard let context else {
            print("Could not load context!")
            throw LlamaError.couldNotInitializeContext
        }


        self.maxTokenCount = effectiveContextCount
        self.maxOutputTokenCount = min(
            config.maxOutputTokenCount,
            effectiveContextCount
        )
        self.backendLease = backendLease
        self.model = context.model
        self.context = context
        self.batch = .init(initialSize: Int32(config.batchSize))
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
        let promptLimit = maxTokenCount > 4 ? maxTokenCount - 4 : 1
        guard UInt32(tokenList.count) < promptLimit else {
            throw LlamaError.contextSizeLimitExeeded
        }

        if config.reusePromptPrefix && tokenList.starts(with: processedTokens) {
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
        generationStartTokenPosition = currentTokenPosition
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
        // Only use partial optimization if:
        // 1. We have a significant amount of processed tokens (at least 10)
        // 2. The divergence is not too early (at least 50% of tokens match)
        // 3. The divergence is not at the very beginning
        
        guard divergenceIndex > 0 && totalProcessed >= 10 else { return false }
        
        let matchPercentage = Double(divergenceIndex) / Double(totalProcessed)
        return matchPercentage >= 0.5 // At least 50% of tokens match
    }
    
    /// Optimized reprocessing that only clears cache from the divergence point
    private func optimizedReprocessing(newTokenList: [llama_token], divergenceIndex: Int) throws {
        // If the new prompt exactly matches the prompt prefix of a previous
        // completion, divergenceIndex is the end of newTokenList. Replaying an
        // empty suffix leaves no prompt logits to sample from and can produce
        // an immediate empty completion. Back up one prompt token so llama.cpp
        // recomputes valid logits while retaining the rest of the KV prefix.
        let replayIndex = min(
            divergenceIndex,
            max(0, newTokenList.count - 1)
        )

        // Clear KV cache from the replay point onward.
        context.clearKVCacheFromPosition(Int32(replayIndex))

        // Update our internal state
        processedTokens = Array(processedTokens[0..<replayIndex])
        currentTokenPosition = Int32(replayIndex)

        // Process only the tokens from the replay point onward.
        let tokensToProcess = Array(newTokenList[replayIndex...])
        try processPrompt(tokens: tokensToProcess, startIndex: replayIndex)
    }

    func generateNextToken() throws -> NextToken {
        // Stop before sampling if we've reached the context limit to avoid mutating sampler state
        if !canGenerateMore() {
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

    func canGenerateMore() -> Bool {
        currentTokenPosition < Int32(maxTokenCount) &&
            currentTokenPosition - generationStartTokenPosition <
            Int32(maxOutputTokenCount)
    }

    func updateSamplingConfig(_ config: LlamaSamplingConfig) throws {
        self.sampler = try .init(config: config, model: model)
    }

    private func clear() {
        context.clearKVCache()
        processedTokens = []
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

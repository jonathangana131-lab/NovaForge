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

        func contextParameters(for profile: LlamaContextAllocationProfile) -> llama_context_params {
            var params = llama_context_default_params()
            params.n_ctx = profile.contextTokens
            params.n_threads = config.generationThreadCount
            params.n_threads_batch = config.batchThreadCount
            params.n_batch = profile.batchTokens
            params.n_ubatch = profile.batchTokens
            params.offload_kqv = config.offloadKQV
            params.type_k = cacheType(profile.keyCacheType)
            params.type_v = cacheType(profile.valueCacheType)

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

        func makeContext(for profile: LlamaContextAllocationProfile) -> LlamaContext? {
            LlamaContext(model: model, parameters: contextParameters(for: profile))
        }

        let requestedProfile = config.requestedAllocationProfile
        let fastRescueProfile = config.fastLowMemoryAllocationProfile
        let deepRescueProfile = config.deepLowMemoryAllocationProfile

        var selectedProfile = requestedProfile
        var selectedProfileName = "requested"
        var selectedContext = makeContext(for: requestedProfile)

        if selectedContext == nil, config.allowLowMemoryFallback {
            // The first rescue tier is an explicit F16 compatibility profile,
            // not merely a smaller copy of a caller-requested Q4/Q8 profile.
            // That matters when allocation failed because a backend/cache-type
            // combination is unsupported rather than because only size is high.
            if fastRescueProfile != requestedProfile {
                print("Context allocation failed; retrying fast low-memory profile (ctx=\(fastRescueProfile.contextTokens), batch=\(fastRescueProfile.batchTokens), F16 KV)")
                selectedContext = makeContext(for: fastRescueProfile)
                if selectedContext != nil {
                    selectedProfile = fastRescueProfile
                    selectedProfileName = "fast-memory-rescue"
                }
            }

            // Deep rescue only runs after both requested and distinct fast
            // allocations fail. Avoid repeating an allocation profile that has
            // already failed, while retaining Q8 as the final compact KV tier.
            if selectedContext == nil,
               deepRescueProfile != requestedProfile,
               deepRescueProfile != fastRescueProfile {
                print("Fast context allocation still failed; retrying deep low-memory profile (ctx=\(deepRescueProfile.contextTokens), batch=\(deepRescueProfile.batchTokens), Q8 KV)")
                selectedContext = makeContext(for: deepRescueProfile)
                if selectedContext != nil {
                    selectedProfile = deepRescueProfile
                    selectedProfileName = "quantized-memory-rescue"
                }
            }
        }

        guard let context = selectedContext else {
            print("Could not load context after all distinct configured allocation tiers")
            throw LlamaError.couldNotInitializeContext
        }
        guard let effectiveBatchSize = selectedProfile.reconciledBatchTokens(
            actualContextBatch: context.batchSize()
        ) else {
            print("llama.cpp returned an invalid effective batch size")
            throw LlamaError.couldNotInitializeContext
        }

        print("Selected llama context profile: \(selectedProfileName), requestedCtx=\(selectedProfile.contextTokens), actualCtx=\(context.contextSize()), requestedBatch=\(selectedProfile.batchTokens), actualBatch=\(context.batchSize()), effectiveBatch=\(effectiveBatchSize), keyKV=\(selectedProfile.keyCacheType.rawValue), valueKV=\(selectedProfile.valueCacheType.rawValue)")
        self.maxTokenCount = min(UInt32(model.trainedContextSize()), selectedProfile.contextTokens)
        self.effectiveBatchSize = effectiveBatchSize
        self.model = context.model
        self.context = context
        self.batch = .init(initialSize: Int32(effectiveBatchSize))
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
            if LlamaBatch.shouldFlushPromptBatch(
                currentSize: batch.size,
                capacity: effectiveBatchSize,
                tokenIndex: i,
                tokenCount: tokens.count
            ) {
                try processBatch()
                batch.reset()
            }
            processedTokens.append(tokenId)
        }

        batch.setLastTokenLogits(true)
        try processBatch()
        currentTokenPosition = Int32(processedTokens.count)
    }
}

import Foundation
import Metal
import llama

/// Production GGUF runtime. Dense 27B decode is memory-bandwidth bound, so this runtime prioritizes
/// mmap, prefix reuse, bounded KV/context, dynamic Metal residency, and sustained thermal behavior.
actor LlamaRuntime {
    enum Profile: String, Sendable {
        case maximumMetal
        case balanced
        case extreme27B

        var context: UInt32 {
            switch self {
            case .maximumMetal: 8_192
            case .balanced: 6_144
            case .extreme27B: 4_096
            }
        }

        var batch: UInt32 {
            switch self {
            case .maximumMetal: 512
            case .balanced: 384
            case .extreme27B: 192
            }
        }

        var ubatch: UInt32 {
            switch self {
            case .maximumMetal: 256
            case .balanced: 192
            case .extreme27B: 96
            }
        }
    }

    struct Metrics: Sendable, Hashable {
        var tokensPerSecond: Double
        var timeToFirstTokenMS: Double
        var outputTokens: Int
        var promptTokens: Int
        var cachedPrefixTokens: Int
        var contextCapacity: Int
        var residentMemoryMB: Double
        var backend: String
    }

    enum RuntimeError: LocalizedError {
        case modelLoad
        case contextCreate
        case tokenize
        case decode(Int32)
        case noModel
        case promptTooLong(Int, Int)

        var errorDescription: String? {
            switch self {
            case .modelLoad:
                "llama.cpp could not load this GGUF. It may be unsupported, corrupt, or too large for the current device."
            case .contextCreate:
                "llama.cpp could not allocate an inference context. Close memory-heavy apps or use a smaller quant."
            case .tokenize:
                "The model tokenizer failed."
            case .decode(let code):
                "llama.cpp decode failed (\(code))."
            case .noModel:
                "Load a local GGUF first."
            case .promptTooLong(let tokens, let capacity):
                "The compacted prompt is still too large (\(tokens) / \(capacity) tokens)."
            }
        }
    }

    enum Event: Sendable {
        case text(String)
        case metrics(Metrics)
    }

    private struct ModelFacts {
        var bytes: UInt64
        var layers: Int32
        var nextNLayers: Int32
    }

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var cachedPrompt: [llama_token] = []
    private var profile: Profile = .balanced
    private var cancelled = false
    private var modelName = ""
    private var activeGPULayers: Int32 = 0
    private var nextNLayers: Int32 = 0
    private var baseDecodeThreads = 4
    private var baseBatchThreads = 6

    init() { llama_backend_init() }

    func isLoaded() -> Bool { model != nil && context != nil }

    func load(modelURL: URL, profile: Profile) throws {
        unload()
        cancelled = false
        self.profile = profile

        let facts = try inspect(modelURL)
        let gpuLayers = selectGPULayers(facts: facts, profile: profile)

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = gpuLayers
        modelParams.load_mode = LLAMA_LOAD_MODE_MMAP
        modelParams.use_extra_bufts = profile != .extreme27B
        modelParams.no_host = false
        modelParams.no_alloc = false
        modelParams.load_mtp = false

        guard let loaded = llama_model_load_from_file(modelURL.path, modelParams) else {
            throw RuntimeError.modelLoad
        }
        model = loaded
        vocab = llama_model_get_vocab(loaded)
        activeGPULayers = gpuLayers
        nextNLayers = facts.nextNLayers

        let cores = ProcessInfo.processInfo.processorCount
        baseDecodeThreads = Swift.max(2, Swift.min(4, cores - 2))
        baseBatchThreads = Swift.max(baseDecodeThreads, Swift.min(6, cores))

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = profile.context
        contextParams.n_batch = profile.batch
        contextParams.n_ubatch = profile.ubatch
        contextParams.n_seq_max = 1
        contextParams.n_outputs_max = 1
        contextParams.n_outputs_max_per_seq = 1
        contextParams.n_threads = Int32(baseDecodeThreads)
        contextParams.n_threads_batch = Int32(baseBatchThreads)
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        contextParams.offload_kqv = true
        contextParams.op_offload = true
        contextParams.swa_full = false
        contextParams.kv_unified = true
        contextParams.no_perf = false

        guard let created = llama_init_from_model(loaded, contextParams) else {
            llama_model_free(loaded)
            model = nil
            vocab = nil
            throw RuntimeError.contextCreate
        }
        context = created
        llama_set_n_threads(created, Int32(baseDecodeThreads), Int32(baseBatchThreads))

        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.92, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.25))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))
        sampler = chain

        cachedPrompt.removeAll(keepingCapacity: false)
        modelName = modelURL.deletingPathExtension().lastPathComponent
    }

    func unload() {
        if let sampler { llama_sampler_free(sampler) }
        sampler = nil
        if let context { llama_free(context) }
        context = nil
        if let model { llama_model_free(model) }
        model = nil
        vocab = nil
        cachedPrompt.removeAll(keepingCapacity: false)
        modelName = ""
        activeGPULayers = 0
        nextNLayers = 0
    }

    func cancel() { cancelled = true }

    func stream(prompt: String, maxTokens: Int = 900) throws -> AsyncThrowingStream<Event, Error> {
        guard isLoaded() else { throw RuntimeError.noModel }
        cancelled = false
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try self.generate(prompt: prompt, maxTokens: maxTokens, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func generate(
        prompt: String,
        maxTokens: Int,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) throws {
        guard let context, let vocab, let sampler else { throw RuntimeError.noModel }

        applyThermalThreadBudget()
        let clock = ContinuousClock()
        let requestStart = clock.now
        let formatted = formattedPrompt(prompt)
        let promptTokens = try tokenize(formatted)
        let capacity = Int(llama_n_ctx(context))
        guard promptTokens.count < capacity - 64 else {
            throw RuntimeError.promptTooLong(promptTokens.count, capacity)
        }

        let allowedOutput = Swift.min(maxTokens, Swift.max(32, capacity - promptTokens.count - 16))
        let lcp = longestCommonPrefix(cachedPrompt, promptTokens)

        if lcp < cachedPrompt.count {
            _ = llama_memory_seq_rm(llama_get_memory(context), 0, Int32(lcp), -1)
            llama_sampler_reset(sampler)
        }

        let suffix = Array(promptTokens.dropFirst(lcp))
        if !suffix.isEmpty {
            let chunkSize = profile == .extreme27B ? 64 : 192
            var offset = 0
            while offset < suffix.count {
                if cancelled { return }
                let end = Swift.min(offset + chunkSize, suffix.count)
                try decode(tokens: Array(suffix[offset..<end]), startPosition: lcp + offset)
                offset = end
            }
        }
        cachedPrompt = promptTokens

        let generationStart = clock.now
        var firstTokenMS = 0.0
        var generated = 0
        var position = promptTokens.count
        var utf8Bytes = Data()

        while generated < allowedOutput && !cancelled {
            if generated > 0 && generated.isMultiple(of: 16) { applyThermalThreadBudget() }

            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            llama_sampler_accept(sampler, token)
            utf8Bytes.append(contentsOf: tokenBytes(token))

            if let text = String(data: utf8Bytes, encoding: .utf8), !text.isEmpty {
                if generated == 0 {
                    firstTokenMS = seconds(requestStart.duration(to: clock.now)) * 1_000
                }
                continuation.yield(.text(text))
                utf8Bytes.removeAll(keepingCapacity: true)
            }

            try decode(tokens: [token], startPosition: position)
            cachedPrompt.append(token)
            position += 1
            generated += 1

            if generated.isMultiple(of: 12) {
                continuation.yield(.metrics(makeMetrics(
                    clock: clock,
                    generationStart: generationStart,
                    firstMS: firstTokenMS,
                    output: generated,
                    prompt: promptTokens.count,
                    cached: lcp,
                    capacity: capacity
                )))
            }
        }

        if !utf8Bytes.isEmpty, let tail = String(data: utf8Bytes, encoding: .utf8), !tail.isEmpty {
            continuation.yield(.text(tail))
        }

        continuation.yield(.metrics(makeMetrics(
            clock: clock,
            generationStart: generationStart,
            firstMS: firstTokenMS,
            output: generated,
            prompt: promptTokens.count,
            cached: lcp,
            capacity: capacity
        )))
    }

    private func inspect(_ url: URL) throws -> ModelFacts {
        var params = llama_model_default_params()
        params.n_gpu_layers = 0
        params.no_alloc = true
        params.load_mode = LLAMA_LOAD_MODE_MMAP
        guard let probe = llama_model_load_from_file(url.path, params) else { throw RuntimeError.modelLoad }
        defer { llama_model_free(probe) }
        return ModelFacts(
            bytes: llama_model_size(probe),
            layers: llama_model_n_layer(probe),
            nextNLayers: llama_model_n_layer_nextn(probe)
        )
    }

    private func selectGPULayers(facts: ModelFacts, profile: Profile) -> Int32 {
        guard llama_supports_gpu_offload(), let device = MTLCreateSystemDefaultDevice() else { return 0 }
        if profile == .maximumMetal { return 999 }

        let totalLayers = Swift.max(1, Int(facts.layers))
        let modelMiB = Double(facts.bytes) / 1_048_576.0
        let averageLayerMiB = Swift.max(1.0, modelMiB / Double(totalLayers))
        let workingSetMiB = Double(device.recommendedMaxWorkingSetSize) / 1_048_576.0
        let reserveMiB = profile == .extreme27B ? 1_450.0 : 900.0
        let usableMiB = Swift.max(192.0, workingSetMiB - reserveMiB)
        var layers = Int(floor(usableMiB / averageLayerMiB))
        layers = Swift.max(0, Swift.min(totalLayers, layers))
        if profile == .extreme27B { layers = Swift.min(layers, 18) }
        return Int32(layers)
    }

    private func applyThermalThreadBudget() {
        guard let context else { return }
        let guardEnabled = UserDefaults.standard.object(forKey: "TriInfer.thermalGuard") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "TriInfer.thermalGuard")

        var decode = baseDecodeThreads
        var batch = baseBatchThreads
        if guardEnabled {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal:
                break
            case .fair:
                decode = Swift.max(2, decode - 1)
                batch = Swift.max(decode, batch - 1)
            case .serious:
                decode = 2
                batch = Swift.max(2, Swift.min(4, batch))
            case .critical:
                decode = 1
                batch = 2
            @unknown default:
                break
            }
        }
        llama_set_n_threads(context, Int32(decode), Int32(batch))
    }

    private func formattedPrompt(_ prompt: String) -> String {
        let fastNoThink = UserDefaults.standard.object(forKey: "TriInfer.fastNoThink") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "TriInfer.fastNoThink")
        let suffix = fastNoThink ? "\n/no_think" : ""
        return """
        <|im_start|>system
        You are TriInfer Code, a local autonomous coding agent. Follow the supplied tool/state contract exactly.<|im_end|>
        <|im_start|>user
        \(prompt)\(suffix)<|im_end|>
        <|im_start|>assistant
        """
    }

    private func decode(tokens: [llama_token], startPosition: Int) throws {
        guard let context else { throw RuntimeError.noModel }
        var batch = llama_batch_init(Int32(Swift.max(tokens.count, 1)), 0, 1)
        defer { llama_batch_free(batch) }

        for (index, token) in tokens.enumerated() {
            let i = Int(batch.n_tokens)
            batch.token[i] = token
            batch.pos[i] = Int32(startPosition + index)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = index == tokens.count - 1 ? 1 : 0
            batch.n_tokens += 1
        }

        let code = llama_decode(context, batch)
        guard code == 0 else { throw RuntimeError.decode(code) }
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        guard let vocab else { throw RuntimeError.noModel }
        let byteCount = text.utf8.count
        var capacity = Swift.max(64, byteCount / 2 + 64)

        for _ in 0..<6 {
            var output = Array(repeating: llama_token(0), count: capacity)
            let count = output.withUnsafeMutableBufferPointer { buffer in
                text.withCString { chars in
                    llama_tokenize(vocab, chars, Int32(byteCount), buffer.baseAddress, Int32(buffer.count), true, true)
                }
            }
            if count >= 0 { return Array(output.prefix(Int(count))) }
            capacity = Swift.max(capacity * 2, Int(-count) + 16)
        }
        throw RuntimeError.tokenize
    }

    private func tokenBytes(_ token: llama_token) -> Data {
        guard let vocab else { return Data() }
        var buffer = Array(repeating: CChar(0), count: 32)
        var count = buffer.withUnsafeMutableBufferPointer {
            llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, false)
        }
        if count < 0 {
            buffer = Array(repeating: CChar(0), count: Int(-count) + 1)
            count = buffer.withUnsafeMutableBufferPointer {
                llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, false)
            }
        }
        guard count > 0 else { return Data() }
        return buffer.withUnsafeBytes { Data($0.prefix(Int(count))) }
    }

    private func longestCommonPrefix(_ a: [llama_token], _ b: [llama_token]) -> Int {
        var index = 0
        while index < a.count && index < b.count && a[index] == b[index] { index += 1 }
        return index
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func makeMetrics(
        clock: ContinuousClock,
        generationStart: ContinuousClock.Instant,
        firstMS: Double,
        output: Int,
        prompt: Int,
        cached: Int,
        capacity: Int
    ) -> Metrics {
        let elapsed = Swift.max(0.001, seconds(generationStart.duration(to: clock.now)))
        let metalMiB: Double
        if let device = MTLCreateSystemDefaultDevice() {
            metalMiB = Double(device.currentAllocatedSize) / 1_048_576.0
        } else {
            metalMiB = 0
        }
        let mtp = nextNLayers > 0 ? " • NextN-capable" : ""
        return .init(
            tokensPerSecond: Double(output) / elapsed,
            timeToFirstTokenMS: firstMS,
            outputTokens: output,
            promptTokens: prompt,
            cachedPrefixTokens: cached,
            contextCapacity: capacity,
            residentMemoryMB: metalMiB,
            backend: "llama.cpp b10456 • mmap • Metal \(activeGPULayers)L + CPU • \(profile.rawValue)\(mtp) • \(modelName)"
        )
    }
}

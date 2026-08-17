import Foundation
import Metal
import llama

actor LlamaRuntime {
    enum Profile: String, Sendable {
        case maximumMetal, balanced, extreme27B
        var context: Int32 { switch self { case .maximumMetal: 4096; case .balanced: 3072; case .extreme27B: 2048 } }
        var gpuLayers: Int32 { switch self { case .maximumMetal: 999; case .balanced: 28; case .extreme27B: 8 } }
        var batch: UInt32 { switch self { case .maximumMetal: 512; case .balanced: 384; case .extreme27B: 256 } }
    }

    struct Metrics: Sendable, Hashable {
        var tokensPerSecond: Double
        var timeToFirstTokenMS: Double
        var outputTokens: Int
        var promptTokens: Int
        var cachedPrefixTokens: Int
        var backend: String
    }

    enum RuntimeError: LocalizedError {
        case modelLoad, contextCreate, tokenize, decode(Int32), noModel
        var errorDescription: String? {
            switch self {
            case .modelLoad: "llama.cpp could not load this GGUF."
            case .contextCreate: "llama.cpp could not allocate an inference context. Try a smaller context or quant."
            case .tokenize: "Tokenizer failed for this model."
            case .decode(let code): "llama.cpp decode failed (\(code))."
            case .noModel: "Load a local GGUF first."
            }
        }
    }

    enum Event: Sendable {
        case text(String)
        case metrics(Metrics)
    }

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var cachedPrompt: [llama_token] = []
    private var profile: Profile = .balanced
    private var cancelled = false
    private var modelName = ""

    init() { llama_backend_init() }

    func isLoaded() -> Bool { model != nil && context != nil }

    func load(modelURL: URL, profile: Profile) throws {
        unload()
        cancelled = false
        self.profile = profile
        var mp = llama_model_default_params()
        mp.n_gpu_layers = profile.gpuLayers
        guard let loadedModel = llama_model_load_from_file(modelURL.path, mp) else { throw RuntimeError.modelLoad }
        model = loadedModel
        vocab = llama_model_get_vocab(loadedModel)

        let processorCount = ProcessInfo.processInfo.processorCount
        let decodeThreads = max(2, min(4, processorCount - 1))
        let batchThreads = max(decodeThreads, min(8, processorCount))
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(profile.context)
        cp.n_batch = profile.batch
        cp.n_ubatch = min(profile.batch, 256)
        cp.n_threads = Int32(decodeThreads)
        cp.n_threads_batch = Int32(batchThreads)
        cp.offload_kqv = true
        cp.op_offload = true
        cp.no_perf = false
        guard let created = llama_init_from_model(loadedModel, cp) else {
            llama_model_free(loadedModel); model = nil; vocab = nil
            throw RuntimeError.contextCreate
        }
        context = created
        llama_set_n_threads(created, Int32(decodeThreads), Int32(batchThreads))

        let sp = llama_sampler_chain_default_params()
        let chain = llama_sampler_chain_init(sp)
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.25))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.92, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))
        sampler = chain
        cachedPrompt = []
        modelName = modelURL.deletingPathExtension().lastPathComponent
        warmupIfSmall()
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
    }

    func cancel() { cancelled = true }

    func stream(prompt: String, maxTokens: Int = 900) throws -> AsyncThrowingStream<Event, Error> {
        guard model != nil, context != nil, vocab != nil, sampler != nil else { throw RuntimeError.noModel }
        cancelled = false
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.generate(prompt: prompt, maxTokens: maxTokens, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func generate(prompt: String, maxTokens: Int, continuation: AsyncThrowingStream<Event, Error>.Continuation) throws {
        guard let context, let vocab, let sampler else { throw RuntimeError.noModel }
        let promptTokens = try tokenize(prompt)
        let lcp = longestCommonPrefix(cachedPrompt, promptTokens)
        let memory = llama_get_memory(context)
        if lcp < cachedPrompt.count {
            _ = llama_memory_seq_rm(memory, 0, llama_pos(lcp), -1)
            llama_sampler_reset(sampler)
        }
        let suffix = Array(promptTokens.dropFirst(lcp))
        if !suffix.isEmpty { try decode(tokens: suffix, startPosition: lcp, logitsLastOnly: true) }
        cachedPrompt = promptTokens

        let start = ContinuousClock.now
        var firstTokenMS = 0.0
        var generated = 0
        var utf8Buffer: [CChar] = []
        var position = promptTokens.count

        while generated < maxTokens && !cancelled {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            llama_sampler_accept(sampler, token)
            let piece = tokenPiece(token)
            utf8Buffer.append(contentsOf: piece)
            if let text = String(validatingUTF8: utf8Buffer + [0]), !text.isEmpty {
                if generated == 0 {
                    let elapsed = start.duration(to: .now)
                    firstTokenMS = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                }
                continuation.yield(.text(text))
                utf8Buffer.removeAll(keepingCapacity: true)
            }
            try decode(tokens: [token], startPosition: position, logitsLastOnly: true)
            cachedPrompt.append(token)
            position += 1
            generated += 1
            if generated % 12 == 0 {
                continuation.yield(.metrics(metrics(start: start, firstTokenMS: firstTokenMS, output: generated, prompt: promptTokens.count, cached: lcp)))
            }
        }
        if !utf8Buffer.isEmpty, let tail = String(validatingUTF8: utf8Buffer + [0]), !tail.isEmpty { continuation.yield(.text(tail)) }
        continuation.yield(.metrics(metrics(start: start, firstTokenMS: firstTokenMS, output: generated, prompt: promptTokens.count, cached: lcp)))
    }

    private func decode(tokens: [llama_token], startPosition: Int, logitsLastOnly: Bool) throws {
        guard let context else { throw RuntimeError.noModel }
        var batch = llama_batch_init(Int32(max(tokens.count, 1)), 0, 1)
        defer { llama_batch_free(batch) }
        for (index, token) in tokens.enumerated() {
            let i = Int(batch.n_tokens)
            batch.token[i] = token
            batch.pos[i] = llama_pos(startPosition + index)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = (!logitsLastOnly || index == tokens.count - 1) ? 1 : 0
            batch.n_tokens += 1
        }
        let code = llama_decode(context, batch)
        guard code == 0 else { throw RuntimeError.decode(code) }
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        guard let vocab else { throw RuntimeError.noModel }
        let bytes = text.utf8.count
        var capacity = max(32, bytes + 8)
        while capacity < max(bytes * 2 + 64, 128) {
            var output = Array(repeating: llama_token(0), count: capacity)
            let count: Int32 = text.withCString { ptr in
                llama_tokenize(vocab, ptr, Int32(bytes), &output, Int32(output.count), true, true)
            }
            if count >= 0 { return Array(output.prefix(Int(count))) }
            capacity = max(capacity * 2, Int(-count) + 8)
        }
        throw RuntimeError.tokenize
    }

    private func tokenPiece(_ token: llama_token) -> [CChar] {
        guard let vocab else { return [] }
        var buffer = Array(repeating: CChar(0), count: 32)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = Array(repeating: CChar(0), count: Int(-count) + 1)
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return count > 0 ? Array(buffer.prefix(Int(count))) : []
    }

    private func longestCommonPrefix(_ a: [llama_token], _ b: [llama_token]) -> Int {
        var i = 0
        while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
        return i
    }

    private func metrics(start: ContinuousClock.Instant, firstTokenMS: Double, output: Int, prompt: Int, cached: Int) -> Metrics {
        let elapsed = start.duration(to: .now)
        let seconds = max(0.001, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        return .init(tokensPerSecond: Double(output) / seconds, timeToFirstTokenMS: firstTokenMS, outputTokens: output, promptTokens: prompt, cachedPrefixTokens: cached, backend: "llama.cpp • Metal/CPU • \(profile.rawValue) • \(modelName)")
    }

    private func warmupIfSmall() {
        guard profile != .extreme27B, let context else { return }
        var token = llama_token(0)
        var batch = llama_batch_get_one(&token, 1)
        _ = llama_decode(context, batch)
        llama_memory_clear(llama_get_memory(context), false)
        cachedPrompt.removeAll()
    }
}

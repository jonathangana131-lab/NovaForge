import Foundation
import llama

actor LlamaRuntime {
    enum Profile: String, Sendable {
        case maximumMetal, balanced, extreme27B
        var context: UInt32 { 4096 }
        var gpuLayers: Int32 { switch self { case .maximumMetal: 999; case .balanced: 28; case .extreme27B: 8 } }
        var batch: UInt32 { switch self { case .maximumMetal: 512; case .balanced: 384; case .extreme27B: 256 } }
    }
    struct Metrics: Sendable, Hashable { var tokensPerSecond: Double; var timeToFirstTokenMS: Double; var outputTokens: Int; var promptTokens: Int; var cachedPrefixTokens: Int; var backend: String }
    enum RuntimeError: LocalizedError {
        case modelLoad, contextCreate, tokenize, decode(Int32), noModel
        var errorDescription: String? { switch self { case .modelLoad: "llama.cpp could not load this GGUF."; case .contextCreate: "llama.cpp could not allocate an inference context. Try a smaller quant or close other apps."; case .tokenize: "Tokenizer failed for this model."; case .decode(let code): "llama.cpp decode failed (\(code))."; case .noModel: "Load a local GGUF first." } }
    }
    enum Event: Sendable { case text(String), metrics(Metrics) }

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
        unload(); cancelled = false; self.profile = profile
        var mp = llama_model_default_params(); mp.n_gpu_layers = profile.gpuLayers; mp.use_extra_bufts = false
        guard let loaded = llama_model_load_from_file(modelURL.path, mp) else { throw RuntimeError.modelLoad }
        model = loaded; vocab = llama_model_get_vocab(loaded)
        let cores = ProcessInfo.processInfo.processorCount
        let decodeThreads = max(2, min(4, cores - 1)); let batchThreads = max(decodeThreads, min(8, cores))
        var cp = llama_context_default_params(); cp.n_ctx = profile.context; cp.n_batch = profile.batch; cp.n_ubatch = min(profile.batch, 256); cp.n_threads = Int32(decodeThreads); cp.n_threads_batch = Int32(batchThreads); cp.offload_kqv = true; cp.op_offload = true; cp.no_perf = false
        guard let created = llama_init_from_model(loaded, cp) else { llama_model_free(loaded); model = nil; vocab = nil; throw RuntimeError.contextCreate }
        context = created; llama_set_n_threads(created, Int32(decodeThreads), Int32(batchThreads))
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()); llama_sampler_chain_add(chain, llama_sampler_init_temp(0.25)); llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.92, 1)); llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))
        sampler = chain; cachedPrompt.removeAll(keepingCapacity: false); modelName = modelURL.deletingPathExtension().lastPathComponent
    }

    func unload() { if let sampler { llama_sampler_free(sampler) }; sampler = nil; if let context { llama_free(context) }; context = nil; if let model { llama_model_free(model) }; model = nil; vocab = nil; cachedPrompt.removeAll(); modelName = "" }
    func cancel() { cancelled = true }

    func stream(prompt: String, maxTokens: Int = 900) throws -> AsyncThrowingStream<Event, Error> {
        guard isLoaded() else { throw RuntimeError.noModel }; cancelled = false
        return AsyncThrowingStream { continuation in Task { do { try self.generate(prompt: prompt, maxTokens: maxTokens, continuation: continuation); continuation.finish() } catch { continuation.finish(throwing: error) } } }
    }

    private func generate(prompt: String, maxTokens: Int, continuation: AsyncThrowingStream<Event, Error>.Continuation) throws {
        guard let context, let vocab, let sampler else { throw RuntimeError.noModel }
        let promptTokens = try tokenize(prompt); let hardLimit = Int(llama_n_ctx(context)); guard promptTokens.count < hardLimit - 64 else { throw RuntimeError.contextCreate }
        let allowedOutput = min(maxTokens, max(32, hardLimit - promptTokens.count - 8)); let lcp = longestCommonPrefix(cachedPrompt, promptTokens)
        if lcp < cachedPrompt.count { _ = llama_memory_seq_rm(llama_get_memory(context), 0, Int32(lcp), -1); llama_sampler_reset(sampler) }
        let suffix = Array(promptTokens.dropFirst(lcp)); if !suffix.isEmpty { try decode(tokens: suffix, startPosition: lcp) }; cachedPrompt = promptTokens
        let clock = ContinuousClock(); let start = clock.now; var firstMS = 0.0, generated = 0, position = promptTokens.count; var utf8Bytes = Data()
        while generated < allowedOutput && !cancelled {
            let token = llama_sampler_sample(sampler, context, -1); if llama_vocab_is_eog(vocab, token) { break }; llama_sampler_accept(sampler, token); utf8Bytes.append(contentsOf: tokenBytes(token))
            if let text = String(data: utf8Bytes, encoding: .utf8), !text.isEmpty { if generated == 0 { firstMS = seconds(start.duration(to: clock.now)) * 1000 }; continuation.yield(.text(text)); utf8Bytes.removeAll(keepingCapacity: true) }
            try decode(tokens: [token], startPosition: position); cachedPrompt.append(token); position += 1; generated += 1
            if generated % 12 == 0 { continuation.yield(.metrics(metrics(clock: clock, start: start, firstMS: firstMS, output: generated, prompt: promptTokens.count, cached: lcp))) }
        }
        if !utf8Bytes.isEmpty, let tail = String(data: utf8Bytes, encoding: .utf8), !tail.isEmpty { continuation.yield(.text(tail)) }
        continuation.yield(.metrics(metrics(clock: clock, start: start, firstMS: firstMS, output: generated, prompt: promptTokens.count, cached: lcp)))
    }

    private func decode(tokens: [llama_token], startPosition: Int) throws {
        guard let context else { throw RuntimeError.noModel }; var batch = llama_batch_init(Int32(max(tokens.count, 1)), 0, 1); defer { llama_batch_free(batch) }
        for (index, token) in tokens.enumerated() { let i = Int(batch.n_tokens); batch.token[i] = token; batch.pos[i] = Int32(startPosition + index); batch.n_seq_id[i] = 1; batch.seq_id[i]![0] = 0; batch.logits[i] = index == tokens.count - 1 ? 1 : 0; batch.n_tokens += 1 }
        let code = llama_decode(context, batch); guard code == 0 else { throw RuntimeError.decode(code) }
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        guard let vocab else { throw RuntimeError.noModel }; let byteCount = text.utf8.count; var capacity = max(64, byteCount / 2 + 32)
        for _ in 0..<5 { var output = Array(repeating: llama_token(0), count: capacity); let count = output.withUnsafeMutableBufferPointer { buffer in text.withCString { chars in llama_tokenize(vocab, chars, Int32(byteCount), buffer.baseAddress, Int32(buffer.count), true, true) } }; if count >= 0 { return Array(output.prefix(Int(count))) }; capacity = max(capacity * 2, Int(-count) + 8) }
        throw RuntimeError.tokenize
    }

    private func tokenBytes(_ token: llama_token) -> Data {
        guard let vocab else { return Data() }; var buffer = Array(repeating: CChar(0), count: 32); var count = buffer.withUnsafeMutableBufferPointer { llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, false) }
        if count < 0 { buffer = Array(repeating: CChar(0), count: Int(-count) + 1); count = buffer.withUnsafeMutableBufferPointer { llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, false) } }
        guard count > 0 else { return Data() }; return buffer.withUnsafeBytes { Data($0.prefix(Int(count))) }
    }

    private func longestCommonPrefix(_ a: [llama_token], _ b: [llama_token]) -> Int { var i = 0; while i < a.count && i < b.count && a[i] == b[i] { i += 1 }; return i }
    private func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
    private func metrics(clock: ContinuousClock, start: ContinuousClock.Instant, firstMS: Double, output: Int, prompt: Int, cached: Int) -> Metrics { let elapsed = max(0.001, seconds(start.duration(to: clock.now))); return .init(tokensPerSecond: Double(output)/elapsed, timeToFirstTokenMS: firstMS, outputTokens: output, promptTokens: prompt, cachedPrefixTokens: cached, backend: "llama.cpp • Metal/CPU • \(profile.rawValue) • \(modelName)") }
}

import CoreML
import CoreMLLLM
import Foundation

/// Optional Neural Engine coprocessor for context retrieval. It intentionally uses the small
/// 128-d Matryoshka embedding instead of keeping another chat LLM resident beside the 27B target.
/// The target decode remains llama.cpp/Metal; ANE work is reserved for semantic memory ranking.
actor ANESemanticAccelerator {
    struct Document: Hashable, Sendable {
        let id: String
        let text: String
    }

    struct Status: Hashable, Sendable {
        var installed: Bool
        var loaded: Bool
        var label: String
        var cacheCount: Int
    }

    enum AcceleratorError: LocalizedError {
        case notBootstrapped
        case notInstalled

        var errorDescription: String? {
            switch self {
            case .notBootstrapped: "The ANE context accelerator has not been initialized yet."
            case .notInstalled: "Install the ANE context accelerator from Models first."
            }
        }
    }

    private let fm = FileManager.default
    private var modelsDirectory: URL?
    private var cacheURL: URL?
    private var engine: EmbeddingGemma?
    private var vectors: [String: [Float]] = [:]
    private let dimension = 128

    func bootstrap() async throws {
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("ANEModels", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = directory; try? mutable.setResourceValues(values)
        modelsDirectory = directory
        cacheURL = support.appendingPathComponent("AgentState/ane-semantic-v1.json")
        loadVectorCache()

        if isBundleInstalled() {
            let bundle = directory.appendingPathComponent("embeddinggemma-300m", isDirectory: true)
            engine = try? await EmbeddingGemma.load(bundleURL: bundle, computeUnits: .cpuAndNeuralEngine)
        }
    }

    func status() -> Status {
        let installed = isBundleInstalled()
        return .init(
            installed: installed,
            loaded: engine != nil,
            label: engine != nil ? "ANE semantic memory ready" : installed ? "ANE model installed" : "Optional • ~330 MB download",
            cacheCount: vectors.count
        )
    }

    /// Downloads the public EmbeddingGemma Core ML bundle and pins its execution preference to
    /// CPU+NeuralEngine. The package validates every required bundle file before returning.
    func install() async throws {
        guard let modelsDirectory else { throw AcceleratorError.notBootstrapped }
        engine = try await EmbeddingGemma.downloadAndLoad(
            modelsDir: modelsDirectory,
            computeUnits: .cpuAndNeuralEngine
        )
    }

    func unload() {
        engine = nil
    }

    /// Reranks an already-small deterministic candidate set. Lexical/structural filtering still
    /// happens first, so the ANE never wastes time embedding the entire project on every turn.
    func rerank(query: String, documents: [Document], limit: Int) throws -> [Document] {
        guard let engine else { return Array(documents.prefix(limit)) }
        guard !documents.isEmpty else { return [] }

        let queryVector = try engine.encode(text: query, task: .retrievalQuery, dim: dimension)
        var scored: [(Document, Float)] = []
        scored.reserveCapacity(documents.count)

        var cacheChanged = false
        for document in documents {
            let key = cacheKey(id: document.id, text: document.text)
            let vector: [Float]
            if let cached = vectors[key] {
                vector = cached
            } else {
                vector = try engine.encode(text: document.text, task: .retrievalDocument, dim: dimension)
                vectors[key] = vector
                cacheChanged = true
            }
            scored.append((document, dot(queryVector, vector)))
        }

        if cacheChanged {
            pruneVectorCache()
            persistVectorCache()
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.id < rhs.0.id
            }
            .prefix(max(1, limit))
            .map(\.0)
    }

    private func isBundleInstalled() -> Bool {
        guard let modelsDirectory else { return false }
        let bundle = modelsDirectory.appendingPathComponent("embeddinggemma-300m", isDirectory: true)
        return fm.fileExists(atPath: bundle.appendingPathComponent("encoder.mlmodelc/model.mil").path)
            && fm.fileExists(atPath: bundle.appendingPathComponent("hf_model/tokenizer.json").path)
    }

    private func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let count = min(lhs.count, rhs.count)
        var value: Float = 0
        for index in 0..<count { value += lhs[index] * rhs[index] }
        return value
    }

    private func cacheKey(id: String, text: String) -> String {
        id + ":" + String(fnv1a(text), radix: 16)
    }

    private func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    private func loadVectorCache() {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: [Float]].self, from: data) else { return }
        vectors = decoded
    }

    private func persistVectorCache() {
        guard let cacheURL else { return }
        try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(vectors) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func pruneVectorCache() {
        // 1,200 × 128 Float32 ≈ 600 KB raw vector payload. JSON is larger, but still tiny compared
        // with one transformer KV cache and bounded for multi-hour sessions.
        guard vectors.count > 1_200 else { return }
        let keep = vectors.keys.sorted().suffix(1_000)
        let allowed = Set(keep)
        vectors = vectors.filter { allowed.contains($0.key) }
    }
}

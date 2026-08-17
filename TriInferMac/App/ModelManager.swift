import Foundation

actor ModelManager {
    struct InstalledModel: Identifiable, Hashable, Sendable {
        var id: String { url.path }
        let name: String
        let url: URL
        let size: Int64
        let modified: Date
    }

    struct Candidate: Identifiable, Hashable, Sendable {
        var id: String { downloadURL.absoluteString }
        let repository: String
        let filename: String
        let downloadURL: URL
        let size: Int64?
        let quant: String
        var displayName: String { filename.replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive) }
    }

    struct StateSnapshot: Sendable {
        let installed: [InstalledModel]
        let loadedName: String?
    }

    enum ModelError: LocalizedError {
        case invalidGGUF, noCandidates, insufficientStorage(Int64), badHTTP(Int)
        var errorDescription: String? {
            switch self {
            case .invalidGGUF: "The file is not a valid GGUF model."
            case .noCandidates: "No compatible Qwen3.8-27B GGUF was found right now."
            case .insufficientStorage(let bytes): "Not enough free storage. Need about \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
            case .badHTTP(let status): "Model server returned HTTP \(status)."
            }
        }
    }

    private let fm = FileManager.default
    private var directory: URL!
    private var loaded: String?

    func bootstrap() throws {
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        directory = support.appendingPathComponent("Models", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = directory!; try? mutable.setResourceValues(values)
        loaded = UserDefaults.standard.string(forKey: "TriInfer.loadedModelName")
    }

    func stateSnapshot() -> StateSnapshot { .init(installed: (try? installedModels()) ?? [], loadedName: loaded) }

    func installedModels() throws -> [InstalledModel] {
        guard let directory else { return [] }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]).compactMap { url in
            guard url.pathExtension.lowercased() == "gguf" else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { return nil }
            return InstalledModel(name: url.deletingPathExtension().lastPathComponent, url: url, size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.modified > $1.modified }
    }

    func profile(for model: InstalledModel) -> LlamaRuntime.Profile {
        let gb = Double(model.size) / 1_073_741_824
        if gb > 6.0 { return .extreme27B }
        if gb > 3.0 { return .balanced }
        return .maximumMetal
    }

    func markLoaded(_ model: InstalledModel) {
        loaded = model.name
        UserDefaults.standard.set(model.name, forKey: "TriInfer.loadedModelName")
    }

    func delete(_ model: InstalledModel) throws {
        try fm.removeItem(at: model.url)
        if loaded == model.name {
            loaded = nil
            UserDefaults.standard.removeObject(forKey: "TriInfer.loadedModelName")
        }
    }

    func importGGUF(from source: URL) throws -> InstalledModel {
        guard try validateGGUF(source) else { throw ModelError.invalidGGUF }
        let destination = uniqueDestination(source.lastPathComponent)
        if source.startAccessingSecurityScopedResource() {
            defer { source.stopAccessingSecurityScopedResource() }
        }
        try fm.copyItem(at: source, to: destination)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = destination; try? mutable.setResourceValues(values)
        let attrs = try fm.attributesOfItem(atPath: destination.path)
        return .init(name: destination.deletingPathExtension().lastPathComponent, url: destination, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0, modified: Date())
    }

    func discoverQwen38_27B() async throws -> [Candidate] {
        let searches = ["Qwen3.8 27B GGUF", "Qwen3.8-27B GGUF", "Qwen 3.8 27B GGUF"]
        var repos: [String] = []
        for query in searches {
            var components = URLComponents(string: "https://huggingface.co/api/models")!
            components.queryItems = [.init(name: "search", value: query), .init(name: "limit", value: "18"), .init(name: "full", value: "true")]
            let (data, response) = try await URLSession.shared.data(from: components.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let objects = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            for object in objects {
                if let id = object["id"] as? String, id.lowercased().contains("qwen"), !repos.contains(id) { repos.append(id) }
            }
            if repos.count >= 8 { break }
        }
        var candidates: [Candidate] = []
        for repo in repos.prefix(10) {
            let encoded = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
            let url = URL(string: "https://huggingface.co/api/models/\(encoded)?blobs=true")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let siblings = object["siblings"] as? [[String: Any]] else { continue }
            for sibling in siblings {
                guard let filename = sibling["rfilename"] as? String, filename.lowercased().hasSuffix(".gguf") else { continue }
                if filename.contains("00001-of-") || filename.lowercased().contains("mmproj") { continue }
                let lower = filename.lowercased()
                guard lower.contains("27b") || repo.lowercased().contains("27b") else { continue }
                guard let download = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename)?download=true") else { continue }
                let size = (sibling["size"] as? NSNumber)?.int64Value
                candidates.append(.init(repository: repo, filename: filename, downloadURL: download, size: size, quant: quantLabel(filename)))
            }
        }
        guard !candidates.isEmpty else { throw ModelError.noCandidates }
        return candidates.sorted { lhs, rhs in score(lhs) < score(rhs) }
    }

    func destination(for candidate: Candidate) throws -> URL {
        if let size = candidate.size { try ensureStorage(bytes: size + 768_000_000) }
        return uniqueDestination(candidate.filename)
    }

    func finalizeDownload(tempURL: URL, candidate: Candidate) throws -> InstalledModel {
        guard try validateGGUF(tempURL) else { throw ModelError.invalidGGUF }
        let destination = try destination(for: candidate)
        try fm.moveItem(at: tempURL, to: destination)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = destination; try? mutable.setResourceValues(values)
        let attrs = try fm.attributesOfItem(atPath: destination.path)
        return .init(name: destination.deletingPathExtension().lastPathComponent, url: destination, size: (attrs[.size] as? NSNumber)?.int64Value ?? 0, modified: Date())
    }

    func validateGGUF(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let header = try handle.read(upToCount: 4) ?? Data()
        return header == Data([0x47, 0x47, 0x55, 0x46])
    }

    private func ensureStorage(bytes: Int64) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        if available < bytes { throw ModelError.insufficientStorage(bytes - available) }
    }

    private func uniqueDestination(_ filename: String) -> URL {
        let sanitized = filename.replacingOccurrences(of: "/", with: "_")
        var url = directory.appendingPathComponent(sanitized)
        if !fm.fileExists(atPath: url.path) { return url }
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var i = 2
        while fm.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(stem)-\(i).\(ext)"); i += 1
        }
        return url
    }

    private func quantLabel(_ name: String) -> String {
        let upper = name.uppercased()
        for token in ["IQ1_S", "IQ1_M", "IQ2_XXS", "IQ2_XS", "IQ2_S", "IQ2_M", "Q2_K", "Q3_K_S", "Q3_K_M", "Q4_K_M"] where upper.contains(token) { return token }
        return "GGUF"
    }

    private func score(_ item: Candidate) -> Int64 {
        let rank: Int64
        switch item.quant { case "IQ1_S": rank = 0; case "IQ1_M": rank = 1; case "IQ2_XXS": rank = 2; case "IQ2_XS": rank = 3; case "IQ2_S": rank = 4; case "IQ2_M": rank = 5; case "Q2_K": rank = 6; default: rank = 20 }
        return rank * 100_000_000_000 + (item.size ?? Int64.max / 8)
    }
}

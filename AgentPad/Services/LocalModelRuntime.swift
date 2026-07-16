import CryptoKit
import Foundation
import Observation

#if canImport(SwiftLlama)
import SwiftLlama
#endif

struct LocalModelVariant: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let shortName: String
    let quantization: String
    let filename: String
    let downloadURL: URL
    let expectedBytes: Int64
    let expectedSHA256: String
    let minimumPhysicalMemoryBytes: UInt64
    let recommendedFreeDiskBytes: Int64
    let contextTokens: UInt32
    let batchTokens: UInt32
    let maxNewTokens: Int
    let maxGenerationSeconds: Int
    let useGPU: Bool
    let gpuLayerCount: Int32
    let generationThreadCount: Int32
    let batchThreadCount: Int32
    let isIPhone12SafeDefault: Bool
    let details: String

    var expectedSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
    }

    var executionLabel: String {
        useGPU ? "Metal GPU" : "CPU"
    }
}

enum LocalModelCatalog {
    /// Official, tool-template-capable coding checkpoint. VibeThinker was
    /// intentionally removed from the local-agent catalog because its own
    /// model card says it was not trained for tool calling or agent work.
    static let repository = "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF"
    static let verifiedRevision = "f86cb2c1fa58255f8052cc32aeede1b7482d4361"

    static let all: [LocalModelVariant] = [
        .init(
            id: "Qwen/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M",
            displayName: "Qwen Coder 1.5B — iPhone 12",
            shortName: "Qwen Coder Q4",
            quantization: "Q4_K_M",
            filename: "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf",
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/\(verifiedRevision)/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf?download=true")!,
            expectedBytes: 1_117_320_768,
            expectedSHA256: "cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046",
            minimumPhysicalMemoryBytes: 3_000_000_000,
            recommendedFreeDiskBytes: 1_800_000_000,
            contextTokens: 2_048,
            batchTokens: 64,
            maxNewTokens: 256,
            maxGenerationSeconds: 35,
            useGPU: true,
            gpuLayerCount: 4,
            generationThreadCount: 1,
            batchThreadCount: 1,
            isIPhone12SafeDefault: true,
            details: "Default for iPhone 12. This official instruction-tuned coding checkpoint is smaller than the former 3B Q2 model, includes Qwen's tool-call template, and runs behind NovaForge's constrained action grammar, schema validation, approvals, and sandbox."
        ),
        .init(
            id: "Qwen/Qwen2.5-Coder-1.5B-Instruct-Q3_K_M",
            displayName: "Qwen Coder 1.5B — Low Memory",
            shortName: "Qwen Coder Q3",
            quantization: "Q3_K_M",
            filename: "qwen2.5-coder-1.5b-instruct-q3_k_m.gguf",
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/\(verifiedRevision)/qwen2.5-coder-1.5b-instruct-q3_k_m.gguf?download=true")!,
            expectedBytes: 924_456_000,
            expectedSHA256: "d281a3a0010df03c8a0e3ffebd7f9444a95244fb518f132c5475e4b48d9adb5e",
            minimumPhysicalMemoryBytes: 2_800_000_000,
            recommendedFreeDiskBytes: 1_500_000_000,
            contextTokens: 1_536,
            batchTokens: 48,
            maxNewTokens: 224,
            maxGenerationSeconds: 35,
            useGPU: true,
            gpuLayerCount: 3,
            generationThreadCount: 1,
            batchThreadCount: 1,
            isIPhone12SafeDefault: false,
            details: "A smaller fallback for devices under memory pressure. It keeps the same tool-trained Qwen checkpoint and the same constrained NovaForge agent boundary at a modest quality tradeoff."
        ),
        .init(
            id: "Qwen/Qwen2.5-Coder-1.5B-Instruct-Q2_K",
            displayName: "Qwen Coder 1.5B — Minimum Memory",
            shortName: "Qwen Coder Q2",
            quantization: "Q2_K",
            filename: "qwen2.5-coder-1.5b-instruct-q2_k.gguf",
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/\(verifiedRevision)/qwen2.5-coder-1.5b-instruct-q2_k.gguf?download=true")!,
            expectedBytes: 752_880_192,
            expectedSHA256: "3ec56d48cc5acdb93c4323f0d01a3b5db0c73c54fe71831199223720d37f6fcd",
            minimumPhysicalMemoryBytes: 2_500_000_000,
            recommendedFreeDiskBytes: 1_250_000_000,
            contextTokens: 1_536,
            batchTokens: 48,
            maxNewTokens: 192,
            maxGenerationSeconds: 35,
            useGPU: true,
            gpuLayerCount: 2,
            generationThreadCount: 1,
            batchThreadCount: 1,
            isIPhone12SafeDefault: false,
            details: "Smallest supported emergency fallback. Tool selection remains grammar constrained, but code quality is lower than the recommended Q4 model."
        )
    ]

    static var defaultVariant: LocalModelVariant {
        safestVariant()
    }

    static func variant(for id: String) -> LocalModelVariant? {
        all.first { $0.id == id }
    }

    static func safestVariant(forPhysicalMemory physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> LocalModelVariant {
        all.first { $0.isIPhone12SafeDefault && physicalMemory >= $0.minimumPhysicalMemoryBytes }
            ?? all.first { physicalMemory >= $0.minimumPhysicalMemoryBytes }
            ?? all.last!
    }

    static func compatibilityMessage(
        for variant: LocalModelVariant,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> String? {
        if physicalMemory < variant.minimumPhysicalMemoryBytes {
            let needed = ByteCountFormatter.string(fromByteCount: Int64(variant.minimumPhysicalMemoryBytes), countStyle: .memory)
            let current = ByteCountFormatter.string(fromByteCount: Int64(physicalMemory), countStyle: .memory)
            return "\(variant.shortName) needs about \(needed) RAM. This device reports \(current). Use Qwen Coder Q3 or Q2."
        }

        return nil
    }

    static func modelDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("LocalModels", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func fileURL(for variant: LocalModelVariant) throws -> URL {
        try modelDirectory().appendingPathComponent(variant.filename)
    }
}

enum LocalModelStatus: Equatable {
    case missing
    case checking
    case partial
    case downloading
    case ready
    case incompatible(String)
    case failed(String)

    var title: String {
        switch self {
        case .missing: "Not Downloaded"
        case .checking: "Checking"
        case .partial: "Paused"
        case .downloading: "Downloading"
        case .ready: "Ready"
        case .incompatible: "Needs Attention"
        case .failed: "Failed"
        }
    }
}

struct LocalModelDownloadProgress: Sendable {
    let receivedBytes: Int64
    let totalBytes: Int64

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }
}

struct LocalModelBenchmarkResult: Equatable, Sendable {
    let modelName: String
    let timeToFirstToken: TimeInterval
    let totalDuration: TimeInterval
    let generatedCharacters: Int

    /// Rough token estimate — llama.cpp doesn't surface counts through this
    /// path, and honest ≈ beats fabricated precision.
    var estimatedTokens: Int { max(1, Int(Double(generatedCharacters) / 3.8)) }

    var tokensPerSecond: Double {
        let generation = max(totalDuration - timeToFirstToken, 0.05)
        return Double(estimatedTokens) / generation
    }
}

enum LocalModelRuntimeError: LocalizedError {
    case modelNotDownloaded(String)
    case runtimeUnavailable
    case incompatibleDevice(String)
    case downloadFailed(String)
    case invalidAgentDecision
    case invalidAgentDecisionOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let name):
            "\(name) is not downloaded yet. Open Settings, choose Local, and download the model first."
        case .runtimeUnavailable:
            "The local llama.cpp runtime is not linked in this build yet."
        case .incompatibleDevice(let message):
            message
        case .downloadFailed(let message):
            message
        case .invalidAgentDecision, .invalidAgentDecisionOutput:
            "The local model could not produce a valid constrained agent decision. Nothing was executed."
        }
    }
}

@MainActor
@Observable
final class LocalModelManager {
    var selectedVariantID = LocalModelCatalog.defaultVariant.id {
        didSet { refreshStatus() }
    }
    private(set) var status: LocalModelStatus = .checking
    private(set) var progress = LocalModelDownloadProgress(receivedBytes: 0, totalBytes: LocalModelCatalog.defaultVariant.expectedBytes)
    private(set) var downloadedBytes: Int64 = 0
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    #if DEBUG || targetEnvironment(simulator)
    @ObservationIgnored private var debugStatusOverride: (variantID: String, status: LocalModelStatus, receivedBytes: Int64?)?
    #endif

    var selectedVariant: LocalModelVariant {
        LocalModelCatalog.variant(for: selectedVariantID) ?? LocalModelCatalog.defaultVariant
    }

    var isDownloaded: Bool {
        if case .ready = status { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = status { return true }
        return false
    }

    var isPartial: Bool {
        if case .partial = status { return true }
        return false
    }

    var compatibilityMessage: String? {
        compatibilityMessage(for: selectedVariant)
    }

    init() {
        refreshStatus()
    }

    deinit {
        downloadTask?.cancel()
        statusTask?.cancel()
    }

    @discardableResult
    func select(_ variant: LocalModelVariant) -> Bool {
        if isDownloading && selectedVariantID != variant.id {
            return false
        }
        if selectedVariantID == variant.id {
            return true
        }
        #if DEBUG || targetEnvironment(simulator)
        debugStatusOverride = nil
        #endif
        selectedVariantID = variant.id
        return true
    }

    func refreshStatus() {
        let variant = selectedVariant
        if isDownloading { return }

        #if DEBUG || targetEnvironment(simulator)
        if let debugStatusOverride, debugStatusOverride.variantID == variant.id {
            statusTask?.cancel()
            statusTask = nil
            applyDebugStatusOverride(debugStatusOverride, for: variant)
            return
        }
        #endif

        statusTask?.cancel()
        progress = .init(receivedBytes: 0, totalBytes: variant.expectedBytes)
        status = .checking

        statusTask = Task(priority: .utility) { [weak self, variant] in
            let result = await Task.detached(priority: .utility) {
                await LocalModelStatusProbe.probe(variant: variant)
            }.value
            await MainActor.run {
                guard let self, self.selectedVariantID == variant.id, !Task.isCancelled else { return }
                self.downloadedBytes = result.downloadedBytes
                self.progress = result.progress
                self.status = result.status
                self.statusTask = nil
            }
        }
    }

    func downloadSelected() {
        let variant = selectedVariant
        guard !isDownloading else { return }
        if let message = compatibilityMessage(for: variant) {
            status = .incompatible(message)
            return
        }

        #if DEBUG || targetEnvironment(simulator)
        debugStatusOverride = nil
        #endif
        status = .downloading
        let existingBytes = (try? LocalModelCatalog.fileURL(for: variant))
            .flatMap { fileSize(at: LocalModelDownloader.temporaryURL(for: $0)) }
            ?? 0
        downloadedBytes = existingBytes
        progress = .init(receivedBytes: existingBytes, totalBytes: variant.expectedBytes)
        downloadTask?.cancel()
        downloadTask = Task(priority: .utility) { [weak self, variant] in
            do {
                let outputURL = try LocalModelCatalog.fileURL(for: variant)
                try await LocalModelDownloader.download(variant: variant, destination: outputURL) { progress in
                    await MainActor.run {
                        guard self?.selectedVariantID == variant.id else { return }
                        self?.progress = progress
                        self?.downloadedBytes = progress.receivedBytes
                    }
                }
                await MainActor.run {
                    guard self?.selectedVariantID == variant.id else {
                        self?.downloadTask = nil
                        return
                    }
                    self?.downloadedBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value ?? variant.expectedBytes
                    self?.status = .ready
                    self?.downloadTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.downloadTask = nil
                    self?.refreshStatus()
                }
            } catch {
                await MainActor.run {
                    self?.downloadTask = nil
                    self?.refreshStatus()
                    if case .partial = self?.status {
                        return
                    }
                    self?.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        refreshStatus()
    }

    #if DEBUG || targetEnvironment(simulator)
    func debugOverrideStatusForUITest(_ status: LocalModelStatus, receivedBytes: Int64? = nil) {
        downloadTask?.cancel()
        statusTask?.cancel()
        downloadTask = nil
        statusTask = nil
        let override = (variantID: selectedVariant.id, status: status, receivedBytes: receivedBytes)
        debugStatusOverride = override
        applyDebugStatusOverride(override, for: selectedVariant)
    }

    private func applyDebugStatusOverride(
        _ override: (variantID: String, status: LocalModelStatus, receivedBytes: Int64?),
        for variant: LocalModelVariant
    ) {
        guard override.variantID == variant.id else { return }
        let bytes = override.receivedBytes ?? variant.expectedBytes
        downloadedBytes = bytes
        progress = .init(receivedBytes: bytes, totalBytes: variant.expectedBytes)
        status = override.status
    }
    #endif

    func deleteSelectedModel() {
        let variant = selectedVariant
        downloadTask?.cancel()
        statusTask?.cancel()
        #if DEBUG || targetEnvironment(simulator)
        debugStatusOverride = nil
        #endif
        status = .checking
        Task(priority: .utility) { [weak self, variant] in
            let deleteError = await Task.detached(priority: .utility) { () -> String? in
                do {
                    let url = try LocalModelCatalog.fileURL(for: variant)
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    let partialURL = LocalModelDownloader.temporaryURL(for: url)
                    if FileManager.default.fileExists(atPath: partialURL.path) {
                        try FileManager.default.removeItem(at: partialURL)
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            await LocalModelArtifactVerifier.shared.invalidate(
                variantID: variant.id
            )
            await MainActor.run {
                guard self?.selectedVariantID == variant.id else { return }
                if let deleteError {
                    self?.status = .failed("Could not delete \(variant.shortName): \(deleteError)")
                } else {
                    self?.refreshStatus()
                }
            }
        }
    }

    func localFileURL(
        for variant: LocalModelVariant? = nil
    ) async throws -> URL {
        let variant = variant ?? selectedVariant
        return try await LocalModelArtifactVerifier.shared.verifiedURL(
            for: variant
        )
    }

    private func compatibilityMessage(for variant: LocalModelVariant) -> String? {
        if let message = LocalModelCatalog.compatibilityMessage(for: variant) {
            return message
        }

        if let available = availableDiskBytes(), available < variant.recommendedFreeDiskBytes {
            let needed = ByteCountFormatter.string(fromByteCount: variant.recommendedFreeDiskBytes, countStyle: .file)
            let current = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Free up storage before downloading. \(variant.shortName) wants about \(needed) free; this device reports \(current)."
        }

        return nil
    }

    private func availableDiskBytes() -> Int64? {
        do {
            let directory = try LocalModelCatalog.modelDirectory()
            let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage.map { Int64($0) }
        } catch {
            return nil
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

private struct LocalModelStatusProbeResult: Sendable {
    let status: LocalModelStatus
    let progress: LocalModelDownloadProgress
    let downloadedBytes: Int64
}

private enum LocalModelStatusProbe {
    static func probe(
        variant: LocalModelVariant
    ) async -> LocalModelStatusProbeResult {
        let emptyProgress = LocalModelDownloadProgress(receivedBytes: 0, totalBytes: variant.expectedBytes)
        if let message = compatibilityMessage(for: variant) {
            return .init(status: .incompatible(message), progress: emptyProgress, downloadedBytes: 0)
        }

        do {
            let url = try LocalModelCatalog.fileURL(for: variant)
            let partialURL = LocalModelDownloader.temporaryURL(for: url)
            if let size = fileSize(at: url),
               size == LocalModelDownloader.minimumCompleteBytes(for: variant)
            {
                _ = try await LocalModelArtifactVerifier.shared.verifiedURL(
                    for: variant
                )
                return .init(
                    status: .ready,
                    progress: .init(receivedBytes: size, totalBytes: max(size, variant.expectedBytes)),
                    downloadedBytes: size
                )
            } else if fileSize(at: url) != nil {
                let preservedSize = LocalModelDownloader.preserveLargestPartialDownload(finalURL: url, partialURL: partialURL)
                if preservedSize > 0 {
                    return .init(
                        status: .partial,
                        progress: .init(receivedBytes: preservedSize, totalBytes: variant.expectedBytes),
                        downloadedBytes: preservedSize
                    )
                }
            } else if let partialSize = fileSize(at: partialURL), partialSize > 0 {
                return .init(
                    status: .partial,
                    progress: .init(receivedBytes: partialSize, totalBytes: variant.expectedBytes),
                    downloadedBytes: partialSize
                )
            }
            return .init(status: .missing, progress: emptyProgress, downloadedBytes: 0)
        } catch {
            return .init(status: .failed(error.localizedDescription), progress: emptyProgress, downloadedBytes: 0)
        }
    }

    private static func compatibilityMessage(for variant: LocalModelVariant) -> String? {
        if let message = LocalModelCatalog.compatibilityMessage(for: variant) { return message }
        if let available = availableDiskBytes(), available < variant.recommendedFreeDiskBytes {
            let needed = ByteCountFormatter.string(fromByteCount: variant.recommendedFreeDiskBytes, countStyle: .file)
            let current = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Free up storage before downloading. \(variant.shortName) wants about \(needed) free; this device reports \(current)."
        }
        return nil
    }

    private static func availableDiskBytes() -> Int64? {
        do {
            let directory = try LocalModelCatalog.modelDirectory()
            let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage.map { Int64($0) }
        } catch {
            return nil
        }
    }

    private static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

enum LocalModelDownloader {
    enum PartialPreparation: Equatable, Sendable {
        case promoted(receivedBytes: Int64)
        case resume(startingBytes: Int64)
    }

    static func temporaryURL(for destination: URL) -> URL {
        destination.appendingPathExtension("download")
    }

    static func minimumCompleteBytes(for variant: LocalModelVariant) -> Int64 {
        variant.expectedBytes
    }

    static func preserveLargestPartialDownload(finalURL: URL, partialURL: URL) -> Int64 {
        let finalSize = fileSize(at: finalURL)
        let partialSize = fileSize(at: partialURL)

        guard finalSize > 0 else {
            return partialSize
        }

        guard finalSize > partialSize else {
            try? FileManager.default.removeItem(at: finalURL)
            return partialSize
        }

        try? FileManager.default.removeItem(at: partialURL)
        do {
            try FileManager.default.moveItem(at: finalURL, to: partialURL)
            return finalSize
        } catch {
            return max(fileSize(at: partialURL), fileSize(at: finalURL), finalSize)
        }
    }

    static func download(
        variant: LocalModelVariant,
        destination: URL,
        progress: @escaping @Sendable (LocalModelDownloadProgress) async -> Void
    ) async throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = temporaryURL(for: destination)
        let preparation = try await prepareExistingPartial(
            variant: variant,
            destination: destination
        )
        let startingBytes: Int64
        switch preparation {
        case let .promoted(receivedBytes):
            await progress(.init(
                receivedBytes: receivedBytes,
                totalBytes: variant.expectedBytes
            ))
            return
        case let .resume(bytes):
            startingBytes = bytes
        }

        var request = URLRequest(url: variant.downloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if startingBytes > 0 {
            request.setValue("bytes=\(startingBytes)-", forHTTPHeaderField: "Range")
        }

        let transfer = LocalModelDownloadTransfer(
            request: request,
            partialURL: temporaryURL,
            startingBytes: startingBytes,
            expectedBytes: variant.expectedBytes,
            progress: progress
        )
        let totalBytes = try await withTaskCancellationHandler {
            try await transfer.start()
        } onCancel: {
            transfer.cancel()
        }
        try Task.checkCancellation()
        let received = fileSize(at: temporaryURL)
        await progress(.init(receivedBytes: received, totalBytes: max(received, totalBytes)))

        if totalBytes > 0, received < totalBytes {
            throw LocalModelRuntimeError.downloadFailed("Download stopped early at \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)). Tap Resume to continue.")
        }

        try validateCompleteDownload(variant: variant, receivedBytes: received)
        try validateSHA256(variant: variant, fileURL: temporaryURL)

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        await LocalModelArtifactVerifier.shared.recordVerified(
            variant: variant,
            fileURL: destination
        )
        await progress(.init(receivedBytes: received, totalBytes: max(received, totalBytes)))
    }

    /// Resolves the crash-at-100% edge before issuing any network request. A
    /// complete verified partial is promoted immediately. A same-size corrupt
    /// partial is discarded and restarted from byte zero; cancellation never
    /// deletes resumable data.
    static func prepareExistingPartial(
        variant: LocalModelVariant,
        destination: URL
    ) async throws -> PartialPreparation {
        let partialURL = temporaryURL(for: destination)
        let existingBytes = fileSize(at: partialURL)
        guard existingBytes > 0 else {
            return .resume(startingBytes: 0)
        }
        guard existingBytes <= variant.expectedBytes else {
            try FileManager.default.removeItem(at: partialURL)
            return .resume(startingBytes: 0)
        }
        guard existingBytes == variant.expectedBytes else {
            return .resume(startingBytes: existingBytes)
        }

        do {
            try validateSHA256(variant: variant, fileURL: partialURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LocalModelRuntimeError {
            guard case .downloadFailed = error else { throw error }
            try FileManager.default.removeItem(at: partialURL)
            await LocalModelArtifactVerifier.shared.invalidate(
                variantID: variant.id
            )
            return .resume(startingBytes: 0)
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partialURL, to: destination)
        await LocalModelArtifactVerifier.shared.recordVerified(
            variant: variant,
            fileURL: destination
        )
        return .promoted(receivedBytes: existingBytes)
    }

    static func validateCompleteDownload(variant: LocalModelVariant, receivedBytes: Int64) throws {
        let expectedBytes = variant.expectedBytes
        guard receivedBytes == expectedBytes else {
            let receivedLabel = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
            let expectedLabel = ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
            throw LocalModelRuntimeError.downloadFailed("\(variant.shortName) is incomplete (\(receivedLabel) of \(expectedLabel)). Tap Resume to continue.")
        }
    }

    static func validateSHA256(
        variant: LocalModelVariant,
        fileURL: URL
    ) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == variant.expectedSHA256 else {
            throw LocalModelRuntimeError.downloadFailed(
                "\(variant.shortName) did not pass its integrity check. Delete the download and try again."
            )
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// Process-wide proof that the bytes loaded by llama.cpp match the catalog's
/// immutable digest. The fingerprint cache prevents re-hashing a 1+ GB model
/// on every provider turn while still invalidating when the file changes.
actor LocalModelArtifactVerifier {
    static let shared = LocalModelArtifactVerifier()

    private struct Fingerprint: Equatable, Sendable {
        let byteCount: Int64
        let modificationTime: TimeInterval
    }

    private var verified: [String: Fingerprint] = [:]
    private var inFlight: [String: Task<(URL, Fingerprint), any Error>] = [:]

    func verifiedURL(for variant: LocalModelVariant) async throws -> URL {
        let fileURL = try LocalModelCatalog.fileURL(for: variant)
        let fingerprint = try Self.fingerprint(
            fileURL: fileURL,
            variant: variant
        )
        if verified[variant.id] == fingerprint {
            return fileURL
        }
        if let task = inFlight[variant.id] {
            let (url, observed) = try await task.value
            verified[variant.id] = observed
            return url
        }

        let task = Task.detached(priority: .utility) {
            try LocalModelDownloader.validateSHA256(
                variant: variant,
                fileURL: fileURL
            )
            let after = try Self.fingerprint(
                fileURL: fileURL,
                variant: variant
            )
            guard after == fingerprint else {
                throw LocalModelRuntimeError.downloadFailed(
                    "\(variant.shortName) changed during its integrity check. Try again."
                )
            }
            return (fileURL, after)
        }
        inFlight[variant.id] = task
        do {
            let (url, observed) = try await task.value
            inFlight[variant.id] = nil
            verified[variant.id] = observed
            return url
        } catch {
            inFlight[variant.id] = nil
            verified[variant.id] = nil
            throw error
        }
    }

    func recordVerified(variant: LocalModelVariant, fileURL: URL) {
        guard let fingerprint = try? Self.fingerprint(
            fileURL: fileURL,
            variant: variant
        ) else {
            verified[variant.id] = nil
            return
        }
        verified[variant.id] = fingerprint
    }

    func invalidate(variantID: String) {
        inFlight[variantID]?.cancel()
        inFlight[variantID] = nil
        verified[variantID] = nil
    }

    private static func fingerprint(
        fileURL: URL,
        variant: LocalModelVariant
    ) throws -> Fingerprint {
        let values = try fileURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? 0) == variant.expectedBytes,
              let modified = values.contentModificationDate else {
            throw LocalModelRuntimeError.modelNotDownloaded(
                variant.displayName
            )
        }
        return Fingerprint(
            byteCount: variant.expectedBytes,
            modificationTime: modified.timeIntervalSinceReferenceDate
        )
    }
}

/// A single resumable transfer. URLSession delivers bounded Data chunks on a
/// private serial delegate queue, so the model is persisted incrementally and
/// cancellation leaves a usable `.download` file instead of losing a 1+ GB
/// temporary system download.
private final class LocalModelDownloadTransfer: NSObject, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private let request: URLRequest
    private let partialURL: URL
    private let initialStartingBytes: Int64
    private let expectedBytes: Int64
    private let progress: @Sendable (LocalModelDownloadProgress) async -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int64, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var receivedBytes: Int64
    private var totalBytes: Int64
    private var lastReportedBytes: Int64
    private var didFinish = false

    init(
        request: URLRequest,
        partialURL: URL,
        startingBytes: Int64,
        expectedBytes: Int64,
        progress: @escaping @Sendable (LocalModelDownloadProgress) async -> Void
    ) {
        self.request = request
        self.partialURL = partialURL
        initialStartingBytes = startingBytes
        self.expectedBytes = expectedBytes
        self.progress = progress
        receivedBytes = startingBytes
        totalBytes = expectedBytes
        lastReportedBytes = startingBytes
    }

    func start() async throws -> Int64 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 60 * 60 * 4
            configuration.waitsForConnectivity = true
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: Self.serialDelegateQueue()
            )
            let task = session.dataTask(with: request)
            self.session = session
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode)
            else {
                throw LocalModelRuntimeError.downloadFailed(
                    "The local model host returned an invalid response."
                )
            }

            let resumesExisting = initialStartingBytes > 0 && http.statusCode == 206
            if resumesExisting {
                guard Self.contentRangeStart(http) == initialStartingBytes else {
                    throw LocalModelRuntimeError.downloadFailed(
                        "The model host returned an invalid resume range. Tap Resume to retry."
                    )
                }
            } else {
                try? FileManager.default.removeItem(at: partialURL)
                receivedBytes = 0
                lastReportedBytes = 0
            }

            if !FileManager.default.fileExists(atPath: partialURL.path) {
                guard FileManager.default.createFile(
                    atPath: partialURL.path,
                    contents: nil
                ) else {
                    throw LocalModelRuntimeError.downloadFailed(
                        "NovaForge could not create the local model download file."
                    )
                }
            }
            let handle = try FileHandle(forWritingTo: partialURL)
            try handle.seekToEnd()
            self.handle = handle
            totalBytes = Self.totalBytes(
                from: http,
                startingBytes: receivedBytes,
                fallback: expectedBytes
            )
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        do {
            try handle?.write(contentsOf: data)
            receivedBytes += Int64(data.count)
            if receivedBytes - lastReportedBytes >= 1_024 * 1_024 ||
                receivedBytes >= totalBytes
            {
                lastReportedBytes = receivedBytes
                let snapshot = LocalModelDownloadProgress(
                    receivedBytes: receivedBytes,
                    totalBytes: max(totalBytes, receivedBytes)
                )
                Task(priority: .utility) { [progress] in
                    await progress(snapshot)
                }
            }
        } catch {
            dataTask.cancel()
            finish(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(throwing: CancellationError())
            } else {
                finish(throwing: error)
            }
        } else {
            finish(returning: totalBytes)
        }
    }

    private func finish(returning value: Int64) {
        finish(.success(value))
    }

    private func finish(throwing error: any Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Int64, any Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        self.task = nil
        lock.unlock()

        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    private static func serialDelegateQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "com.joey.NovaForge.local-model-download"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }

    private static func contentRangeStart(_ response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let rangePart = value.split(separator: " ").last?.split(separator: "/").first,
              let startPart = rangePart.split(separator: "-").first
        else { return nil }
        return Int64(startPart)
    }

    private static func totalBytes(
        from response: HTTPURLResponse,
        startingBytes: Int64,
        fallback: Int64
    ) -> Int64 {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let totalText = contentRange.split(separator: "/").last,
           let total = Int64(totalText) {
            return total
        }
        if response.expectedContentLength > 0 {
            return response.expectedContentLength + startingBytes
        }
        return fallback
    }
}

/// A single process-wide generation lease prevents two workspaces from
/// loading or driving llama.cpp concurrently on memory-constrained phones.
/// Waiting is cancellation-aware and does not cancel the current owner's run.
private actor LocalModelInferenceGate {
    static let shared = LocalModelInferenceGate()
    private var isHeld = false

    func acquire() async throws {
        while isHeld {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        isHeld = true
    }

    func release() {
        isHeld = false
    }
}

actor LocalModelClient: AgentLocalModelInferenceStreaming,
    AgentLocalModelActionPlanning,
    AgentLocalModelArtifactVerifying
{
    static let shared = LocalModelClient()

    #if canImport(SwiftLlama)
    private var services: [String: LlamaService] = [:]
    #endif

    func stop(model: String) async {
        #if canImport(SwiftLlama)
        let variant = LocalModelCatalog.variant(for: model) ?? LocalModelCatalog.defaultVariant
        if let service = services[variant.id] {
            await service.stopCompletion()
        }
        #endif
    }

    func verifyLocalModelArtifact(modelID: String) async throws {
        guard let variant = LocalModelCatalog.variant(for: modelID) else {
            throw LocalModelRuntimeError.modelNotDownloaded(modelID)
        }
        _ = try await LocalModelArtifactVerifier.shared.verifiedURL(
            for: variant
        )
    }

    /// Runs the tool-trained checkpoint behind the exact GBNF bound into
    /// `LocalToolsAuthority`. The model may choose one action, but it cannot
    /// invent a tool name or argument shape; the transport validates the
    /// decoded decision again before publishing a canonical tool call.
    func decideLocalAgentTurn(
        request: AgentLocalModelInferenceRequest,
        completedToolCallCount: Int
    ) async throws -> LocalAgentModelDecision {
        try await LocalModelInferenceGate.shared.acquire()
        do {
            let decision = try await performLocalAgentDecision(
                request: request,
                completedToolCallCount: completedToolCallCount
            )
            await LocalModelInferenceGate.shared.release()
            return decision
        } catch {
            await LocalModelInferenceGate.shared.release()
            throw error
        }
    }

    private func performLocalAgentDecision(
        request: AgentLocalModelInferenceRequest,
        completedToolCallCount: Int
    ) async throws -> LocalAgentModelDecision {
        guard let variant = LocalModelCatalog.variant(for: request.modelID),
              completedToolCallCount >= 0,
              completedToolCallCount <
                LocalAgentModelGrammar.maximumModelPlannedToolCalls
        else { throw LocalModelRuntimeError.invalidAgentDecision }
        if let message = LocalModelCatalog.compatibilityMessage(for: variant) {
            throw LocalModelRuntimeError.incompatibleDevice(message)
        }

        let modelURL = try await LocalModelArtifactVerifier.shared
            .verifiedURL(for: variant)

        #if canImport(SwiftLlama)
        let service = services[variant.id] ?? LlamaService(
            modelUrl: modelURL,
            config: .init(
                batchSize: variant.batchTokens,
                maxTokenCount: variant.contextTokens,
                useGPU: variant.useGPU,
                gpuLayerCount: variant.gpuLayerCount,
                generationThreadCount: variant.generationThreadCount,
                batchThreadCount: variant.batchThreadCount,
                yieldEveryTokenCount: 1
            )
        )
        services[variant.id] = service

        let latestUserIndex = request.messages.lastIndex(where: {
            $0.role == .user
        })
        let latestUser = latestUserIndex.map {
            request.messages[$0].content
        } ?? ""
        let recentContext = latestUserIndex.map { index in
            Self.boundedPlannerTranscript(
                Array(request.messages.dropFirst(index + 1))
            )
        } ?? ""
        let contextLine = recentContext.isEmpty
            ? ""
            : "\nRecent validated actions and results:\n\(recentContext)"
        let messages: [LlamaChatMessage] = [
            .init(
                role: .system,
                content: LocalAgentModelGrammar.routerPrompt
            ),
            .init(
                role: .user,
                content: "Request: \(Self.boundedPlannerText(latestUser, limit: 600))\(contextLine)\nCompleted actions: \(completedToolCallCount)"
            ),
        ]
        let sampling = LlamaSamplingConfig(
            temperature: 0,
            seed: 42,
            topP: 1,
            topK: 8,
            grammarConfig: LlamaGrammarConfig(
                grammar: LocalAgentModelGrammar.gbnf,
                grammarRoot: "root"
            ),
            repetitionPenaltyConfig: nil
        )
        let stream = try await service.streamCompletion(
            of: messages,
            samplingConfig: sampling
        )
        let decoder = JSONDecoder()
        let startedAt = ContinuousClock.now
        let maximumTokens = min(192, variant.maxNewTokens)
        var output = ""
        var tokenCount = 0

        do {
            for try await token in stream {
                try Task.checkCancellation()
                output += token
                tokenCount += 1
                if let data = output.data(using: .utf8),
                   let decision = try? decoder.decode(
                       LocalAgentModelDecision.self,
                       from: data
                   ) {
                    await service.stopCompletion()
                    return decision
                }
                if tokenCount >= maximumTokens ||
                    startedAt.duration(to: .now) >= .seconds(60)
                {
                    await service.stopCompletion()
                    break
                }
            }
        } catch is CancellationError {
            await service.stopCompletion()
            throw CancellationError()
        } catch {
            await service.stopCompletion()
            throw error
        }

        guard let data = output.data(using: .utf8),
              let decision = try? decoder.decode(
                  LocalAgentModelDecision.self,
                  from: data
              ) else {
            throw LocalModelRuntimeError.invalidAgentDecisionOutput(
                Self.boundedPlannerText(output, limit: 1_500)
            )
        }
        return decision
        #else
        throw LocalModelRuntimeError.runtimeUnavailable
        #endif
    }

    private static func boundedPlannerText(
        _ value: String,
        limit: Int
    ) -> String {
        let compact = value
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit))
    }

    private static func boundedPlannerTranscript(
        _ messages: [AgentLocalModelInferenceMessage]
    ) -> String {
        var remaining = 1_100
        var lines: [String] = []
        for message in messages.suffix(6) {
            guard remaining > 0 else { break }
            let prefix = message.role == .assistant ? "assistant" : message.role.rawValue
            let available = max(0, remaining - prefix.count - 2)
            guard available > 0 else { break }
            let text = boundedPlannerText(
                message.content,
                limit: min(available, 500)
            )
            let line = "\(prefix): \(text)"
            lines.append(line)
            remaining -= line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    /// Canonical V2 text stream. The existing `streamingResponse` method below
    /// remains untouched for V1 parity and rollback until the V2 route ships.
    func stream(
        request: AgentLocalModelInferenceRequest,
        onEvent: @escaping @Sendable (AgentLocalModelInferenceEvent) async throws -> Void
    ) async throws {
        try await LocalModelInferenceGate.shared.acquire()
        do {
            try await performStream(request: request, onEvent: onEvent)
            await LocalModelInferenceGate.shared.release()
        } catch {
            await LocalModelInferenceGate.shared.release()
            throw error
        }
    }

    private func performStream(
        request: AgentLocalModelInferenceRequest,
        onEvent: @escaping @Sendable (AgentLocalModelInferenceEvent) async throws -> Void
    ) async throws {
        guard let variant = LocalModelCatalog.variant(for: request.modelID),
              request.maximumOutputTokens > 0,
              request.maximumOutputTokens <= UInt64(variant.maxNewTokens),
              request.temperature.isFinite,
              (0 ... 2).contains(request.temperature),
              !request.messages.isEmpty
        else { throw LocalModelRuntimeError.runtimeUnavailable }
        if let message = LocalModelCatalog.compatibilityMessage(for: variant) {
            throw LocalModelRuntimeError.incompatibleDevice(message)
        }

        let modelURL = try await LocalModelArtifactVerifier.shared
            .verifiedURL(for: variant)

        #if canImport(SwiftLlama)
        let service = services[variant.id] ?? LlamaService(
            modelUrl: modelURL,
            config: .init(
                batchSize: variant.batchTokens,
                maxTokenCount: variant.contextTokens,
                useGPU: variant.useGPU,
                gpuLayerCount: variant.gpuLayerCount,
                generationThreadCount: variant.generationThreadCount,
                batchThreadCount: variant.batchThreadCount,
                yieldEveryTokenCount: 1
            )
        )
        services[variant.id] = service

        let llamaMessages = request.messages.map { message in
            let role: LlamaChatMessage.Role = switch message.role {
            case .system, .developer: .system
            case .user: .user
            case .assistant: .assistant
            }
            return LlamaChatMessage(role: role, content: message.content)
        }
        let sampling = LlamaSamplingConfig(
            temperature: CFloat(request.temperature),
            seed: 42,
            topP: 0.72,
            topK: 12,
            repetitionPenaltyConfig: LlamaRepetitionPenaltyConfig(
                lastN: 48,
                repeatPenalty: 1.22,
                freqPenalty: 0.08
            )
        )
        let stream = try await service.streamCompletion(
            of: llamaMessages,
            samplingConfig: sampling
        )
        var generatedTokenCount: UInt64 = 0
        var lastChunkWasEmpty = false
        var suppressingHiddenReasoning = false
        var stoppedEarly = false
        var finishReason: AgentLocalModelInferenceFinishReason = .completed
        let generationStartedAt = ContinuousClock.now

        do {
            for try await token in stream {
                try Task.checkCancellation()
                generatedTokenCount += 1
                lastChunkWasEmpty = token.isEmpty

                if Self.isObviouslyUnstableToken(
                    token,
                    after: Int(clamping: generatedTokenCount)
                ) {
                    stoppedEarly = true
                    finishReason = .length
                    await service.stopCompletion()
                    break
                }

                let visibleToken = Self.visibleLocalToken(
                    from: token,
                    suppressingHiddenReasoning: &suppressingHiddenReasoning
                )
                if !visibleToken.isEmpty {
                    try await onEvent(.text(visibleToken))
                }

                if !token.isEmpty,
                   (generatedTokenCount >= request.maximumOutputTokens ||
                    generationStartedAt.duration(to: .now) >=
                    .seconds(variant.maxGenerationSeconds)) {
                    stoppedEarly = true
                    finishReason = .length
                    await service.stopCompletion()
                    break
                }
            }
        } catch is CancellationError {
            await service.stopCompletion()
            throw CancellationError()
        } catch {
            await service.stopCompletion()
            throw error
        }

        // SwiftLlama emits one String per generated llama token, followed by
        // one empty EOS flush. Remove only that known natural-terminal flush;
        // early stops do not receive it.
        if !stoppedEarly, lastChunkWasEmpty, generatedTokenCount > 0 {
            generatedTokenCount -= 1
        }
        try Task.checkCancellation()
        try await onEvent(.usage(generatedTokenCount: generatedTokenCount))
        try await onEvent(.completed(reason: finishReason))
        #else
        throw LocalModelRuntimeError.runtimeUnavailable
        #endif
    }

    func stop(request: AgentLocalModelInferenceRequest) async {
        await stop(model: request.modelID)
    }

    func streamingResponse(
        messages: [ProviderMessageInput],
        model: String,
        temperature: Double,
        customSystemPrompt: String?,
        workspaceSummary: String,
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ProviderResponse {
        try await LocalModelInferenceGate.shared.acquire()
        do {
            let response = try await performStreamingResponse(
                messages: messages,
                model: model,
                temperature: temperature,
                customSystemPrompt: customSystemPrompt,
                workspaceSummary: workspaceSummary,
                onContentBatch: onContentBatch
            )
            await LocalModelInferenceGate.shared.release()
            return response
        } catch {
            await LocalModelInferenceGate.shared.release()
            throw error
        }
    }

    private func performStreamingResponse(
        messages: [ProviderMessageInput],
        model: String,
        temperature: Double,
        customSystemPrompt: String?,
        workspaceSummary: String,
        onContentBatch: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ProviderResponse {
        let variant = LocalModelCatalog.variant(for: model) ?? LocalModelCatalog.defaultVariant
        if let message = LocalModelCatalog.compatibilityMessage(for: variant) {
            throw LocalModelRuntimeError.incompatibleDevice(message)
        }

        let modelURL = try await LocalModelArtifactVerifier.shared
            .verifiedURL(for: variant)

        #if canImport(SwiftLlama)
        let service = services[variant.id] ?? LlamaService(
            modelUrl: modelURL,
            config: .init(
                batchSize: variant.batchTokens,
                maxTokenCount: variant.contextTokens,
                useGPU: variant.useGPU,
                gpuLayerCount: variant.gpuLayerCount,
                generationThreadCount: variant.generationThreadCount,
                batchThreadCount: variant.batchThreadCount,
                yieldEveryTokenCount: 1
            )
        )
        services[variant.id] = service

        let systemPrompt = localSystemPrompt(customSystemPrompt: customSystemPrompt, workspaceSummary: workspaceSummary)
        let sanitizedTranscript = ProviderMessageSanitizer.sanitize(systemPrompt: systemPrompt, history: messages)
        let llamaMessages = localMessages(from: sanitizedTranscript.messages)
        let sampling = LlamaSamplingConfig(
            temperature: 0.05,
            seed: 42,
            topP: 0.72,
            topK: 12,
            repetitionPenaltyConfig: LlamaRepetitionPenaltyConfig(lastN: 48, repeatPenalty: 1.22, freqPenalty: 0.08)
        )

        let stream = try await service.streamCompletion(of: llamaMessages, samplingConfig: sampling)
        var output = ""
        var generatedTokenCount = 0
        var pending = ""
        var suppressingHiddenReasoning = false
        var stoppedForUnstableOutput = false
        var lastDelivery = ContinuousClock.now
        let generationStartedAt = ContinuousClock.now

        do {
            for try await token in stream {
                try Task.checkCancellation()
                output += token
                generatedTokenCount += 1

                if Self.isObviouslyUnstableToken(token, after: generatedTokenCount) ||
                    (generatedTokenCount >= 4 && Self.looksLikeUnstableLiveOutput(output)) ||
                    (suppressingHiddenReasoning && generatedTokenCount >= 10 && pending.isEmpty) {
                    stoppedForUnstableOutput = true
                    pending.removeAll(keepingCapacity: true)
                    await service.stopCompletion()
                    break
                }

                let visibleToken = Self.visibleLocalToken(
                    from: token,
                    suppressingHiddenReasoning: &suppressingHiddenReasoning
                )
                if !visibleToken.isEmpty {
                    pending += visibleToken
                }

                let elapsed = lastDelivery.duration(to: .now)
                if !pending.isEmpty,
                   elapsed >= .milliseconds(180) || pending.count >= 180 || pending.contains("\n\n") {
                    await onContentBatch(pending)
                    pending.removeAll(keepingCapacity: true)
                    lastDelivery = .now
                }

                let generationElapsed = generationStartedAt.duration(to: .now)
                if generatedTokenCount >= variant.maxNewTokens ||
                    (generatedTokenCount > 0 && generationElapsed >= .seconds(variant.maxGenerationSeconds)) {
                    await service.stopCompletion()
                    break
                }
            }
        } catch is CancellationError {
            await service.stopCompletion()
            throw CancellationError()
        }

        if !pending.isEmpty {
            await onContentBatch(pending)
        }

        let cleanedOutput = stoppedForUnstableOutput
            ? "Local output became unstable, so NovaForge stopped it safely."
            : Self.cleanLocalOutput(output)
        let message = ChatCompletionsResponse.Choice.Message(
            role: "assistant",
            content: cleanedOutput.isEmpty ? nil : cleanedOutput,
            tool_calls: nil
        )
        return ProviderResponse(message: message, roleLog: sanitizedTranscript.roleLog)
        #else
        throw LocalModelRuntimeError.runtimeUnavailable
        #endif
    }

    private func localSystemPrompt(customSystemPrompt: String?, workspaceSummary: String) -> String {
        let styleNote = customSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customLine = styleNote.map { "\nStyle preference: \(String($0.prefix(140)))" } ?? ""

        return """
        You are NovaForge Local on iPhone.
        Reply in plain English, max 4 short sentences.
        Do not greet, restate the request, or narrate obvious preparation.
        No hidden reasoning. No code blocks unless asked. No XML, JSON, logs, numbered dumps, or tool-call text.
        If you are unsure, say one short helpful sentence and stop.
        Native NovaForge code handles simple local file, search, command, and artifact actions before your reply.
        You should answer only short offline questions. Do not invent tool calls or pretend to edit files yourself.
        \(customLine)

        Workspace files:
        \(workspaceSummary)
        """
    }

    #if canImport(SwiftLlama)
    private func localMessages(from messages: [ProviderChatMessage]) -> [LlamaChatMessage] {
        let system = messages.last(where: { $0.role == "system" })
        let latestUser = messages.last { message in
            guard message.role == "user" else { return false }
            guard let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return false }
            return !Self.isBoilerplateLocalWelcome(content)
        }

        return ([system, latestUser].compactMap { $0 }).map { message in
            switch message.role {
            case "system":
                return LlamaChatMessage(role: .system, content: message.content ?? "")
            default:
                let content = String((message.content ?? "").prefix(420))
                return LlamaChatMessage(role: .user, content: content)
            }
        }
    }
    #endif

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func isBoilerplateLocalWelcome(_ content: String) -> Bool {
        let lower = content.lowercased()
        return lower.contains("fresh novaforge session ready") ||
            lower.contains("novaforge is ready. existing chats") ||
            lower.contains("tell me what to build, inspect")
    }

    private static func visibleLocalToken(
        from token: String,
        suppressingHiddenReasoning: inout Bool
    ) -> String {
        var text = token
        var visible = ""

        while !text.isEmpty {
            if suppressingHiddenReasoning {
                guard let end = text.range(of: "</think>", options: .caseInsensitive) else {
                    return visible
                }
                text = String(text[end.upperBound...])
                suppressingHiddenReasoning = false
                continue
            }

            guard let start = text.range(of: "<think", options: .caseInsensitive) else {
                visible += text
                break
            }

            visible += String(text[..<start.lowerBound])
            if let end = text.range(
                of: "</think>",
                options: .caseInsensitive,
                range: start.lowerBound..<text.endIndex
            ) {
                text = String(text[end.upperBound...])
            } else {
                suppressingHiddenReasoning = true
                break
            }
        }

        for marker in ["<tool_call", "<tool_response", "Tool call:", "tool_call:"] {
            if let range = visible.range(of: marker, options: .caseInsensitive) {
                visible = String(visible[..<range.lowerBound])
            }
        }

        return visible
    }

    private static func cleanLocalOutput(_ output: String) -> String {
        var text = output

        let removalPatterns = [
            #"<think>.*?</think>"#,
            #"<tool_call>.*?</tool_call>"#,
            #"<tool_response>.*?</tool_response>"#
        ]

        for pattern in removalPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }

        let stopMarkers = ["<tool_call", "<tool_response", "Tool call:", "tool_call:"]
        for marker in stopMarkers {
            if let range = text.range(of: marker, options: [.caseInsensitive]) {
                text = String(text[..<range.lowerBound])
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeLowQualityLocalOutput(trimmed) {
            return "Local output became unstable, so NovaForge stopped it safely."
        }

        guard !trimmed.isEmpty else {
            return "I’m ready locally. Ask a shorter prompt, or switch to a cloud agent mode for real workspace tool work."
        }
        return trimmed
    }

    private static func looksLikeUnstableLiveOutput(_ text: String) -> Bool {
        let sample = String(text.suffix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sample.count >= 24 else { return false }
        if sample.range(of: "<tool_call", options: .caseInsensitive) != nil { return true }
        if sample.range(of: "<tool_response", options: .caseInsensitive) != nil { return true }
        if sample.localizedCaseInsensitiveContains("assistantassistant") { return true }

        let scalars = sample.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let punctuationNoise = sample.filter { "{}[]<>\\/|=_".contains($0) }.count

        if digits >= 8, digits > max(letters, 10) { return true }
        if punctuationNoise > max(14, sample.count / 3) { return true }
        if sample.range(of: #"(?:\d[\s,.;:_-]*){8,}"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func isObviouslyUnstableToken(_ token: String, after generatedTokenCount: Int) -> Bool {
        guard generatedTokenCount >= 3 else { return false }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }

        let scalars = trimmed.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let symbolNoise = trimmed.filter { "{}[]<>\\/|=_#`".contains($0) }.count

        if letters == 0, digits >= 2 { return true }
        if symbolNoise >= 3, symbolNoise >= letters + digits { return true }
        return false
    }

    private static func looksLikeLowQualityLocalOutput(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let scalars = text.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        let punctuationNoise = text.filter { "{}[]<>\\/|=_".contains($0) }.count

        if text.count >= 12, letters == 0 { return true }
        if digits > max(18, letters * 2) { return true }
        if punctuationNoise > max(12, text.count / 4) { return true }
        if text.localizedCaseInsensitiveContains("assistantassistant") { return true }
        return false
    }

    static func extractToolCalls(from output: String) -> (content: String, toolCalls: [APIToolCall]) {
        guard let regex = try? NSRegularExpression(
            pattern: #"<tool_call>\s*(\{.*?\})\s*</tool_call>"#,
            options: [.dotMatchesLineSeparators]
        ) else {
            return (output.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }

        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let matches = regex.matches(in: output, range: range)
        let toolCalls = matches.enumerated().compactMap { index, match -> APIToolCall? in
            guard match.numberOfRanges > 1,
                  let jsonRange = Range(match.range(at: 1), in: output) else { return nil }
            return decodeToolCallJSON(String(output[jsonRange]), index: index)
        }

        let content = regex
            .stringByReplacingMatches(in: output, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (content, toolCalls)
    }

    private static func decodeToolCallJSON(_ json: String, index: Int) -> APIToolCall? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else { return nil }

        guard let argumentsData = normalizedArgumentsData(from: object["arguments"]) else {
            return nil
        }

        let argumentsJSON = String(data: argumentsData, encoding: .utf8) ?? "{}"
        return APIToolCall(
            id: "local-tool-\(index)-\(UUID().uuidString.prefix(8))",
            type: "function",
            function: APIFunctionCall(name: name, arguments: argumentsJSON)
        )
    }

    private static func normalizedArgumentsData(from value: Any?) -> Data? {
        guard let value else { return nil }

        let data: Data
        if let argumentsString = value as? String {
            guard let stringData = argumentsString.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: stringData, options: [.fragmentsAllowed]) else {
                return nil
            }
            do {
                try ToolCallArgumentValidator.validateFlatArgumentObject(
                    decoded,
                    sourceDescription: "local model response"
                )
            } catch {
                return nil
            }
            guard JSONSerialization.isValidJSONObject(decoded) else { return nil }
            data = (try? JSONSerialization.data(withJSONObject: decoded, options: [.sortedKeys])) ?? Data()
        } else {
            guard JSONSerialization.isValidJSONObject(value),
                  let objectData = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let decoded = try? JSONSerialization.jsonObject(with: objectData, options: [.fragmentsAllowed]) else {
                return nil
            }
            do {
                try ToolCallArgumentValidator.validateFlatArgumentObject(
                    decoded,
                    sourceDescription: "local model response"
                )
            } catch {
                return nil
            }
            data = objectData
        }

        return data.isEmpty ? nil : data
    }
}

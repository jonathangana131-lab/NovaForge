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
    static let repository = "prithivMLmods/VibeThinker-3B-GGUF"

    static let all: [LocalModelVariant] = [
        .init(
            id: "WeiboAI/VibeThinker-3B-Q2_K",
            displayName: "VibeThinker-3B iPhone 12",
            shortName: "VibeThinker Q2",
            quantization: "Q2_K",
            filename: "VibeThinker-3B.Q2_K.gguf",
            downloadURL: URL(string: "https://huggingface.co/prithivMLmods/VibeThinker-3B-GGUF/resolve/main/VibeThinker-3B.Q2_K.gguf?download=true")!,
            expectedBytes: 1_274_755_776,
            minimumPhysicalMemoryBytes: 3_000_000_000,
            recommendedFreeDiskBytes: 2_000_000_000,
            contextTokens: 256,
            batchTokens: 8,
            maxNewTokens: 24,
            maxGenerationSeconds: 8,
            useGPU: true,
            gpuLayerCount: 2,
            generationThreadCount: 1,
            batchThreadCount: 1,
            isIPhone12SafeDefault: true,
            details: "Default for iPhone 12. Lower quantization, tiny context, one worker thread, and very limited Metal offload keep the UI responsive."
        ),
        .init(
            id: "WeiboAI/VibeThinker-3B-Q3_K_M",
            displayName: "VibeThinker-3B Higher Quality",
            shortName: "VibeThinker Q3",
            quantization: "Q3_K_M",
            filename: "VibeThinker-3B.Q3_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/prithivMLmods/VibeThinker-3B-GGUF/resolve/main/VibeThinker-3B.Q3_K_M.gguf?download=true")!,
            expectedBytes: 1_590_475_456,
            minimumPhysicalMemoryBytes: 4_800_000_000,
            recommendedFreeDiskBytes: 2_400_000_000,
            contextTokens: 512,
            batchTokens: 24,
            maxNewTokens: 80,
            maxGenerationSeconds: 28,
            useGPU: true,
            gpuLayerCount: 4,
            generationThreadCount: 1,
            batchThreadCount: 1,
            isIPhone12SafeDefault: false,
            details: "Sharper output, but the iPhone 12/iOS 27 beta path can freeze under this memory pressure."
        ),
        .init(
            id: "WeiboAI/VibeThinker-3B-Q4_K_S",
            displayName: "VibeThinker-3B Balanced",
            shortName: "VibeThinker Q4S",
            quantization: "Q4_K_S",
            filename: "VibeThinker-3B.Q4_K_S.gguf",
            downloadURL: URL(string: "https://huggingface.co/prithivMLmods/VibeThinker-3B-GGUF/resolve/main/VibeThinker-3B.Q4_K_S.gguf?download=true")!,
            expectedBytes: 1_830_000_000,
            minimumPhysicalMemoryBytes: 5_000_000_000,
            recommendedFreeDiskBytes: 2_800_000_000,
            contextTokens: 3_072,
            batchTokens: 192,
            maxNewTokens: 640,
            maxGenerationSeconds: 60,
            useGPU: true,
            gpuLayerCount: 99,
            generationThreadCount: 2,
            batchThreadCount: 3,
            isIPhone12SafeDefault: false,
            details: "Better quality, intended for newer devices with more memory headroom."
        ),
        .init(
            id: "WeiboAI/VibeThinker-3B-Q4_K_M",
            displayName: "VibeThinker-3B Quality",
            shortName: "VibeThinker Q4M",
            quantization: "Q4_K_M",
            filename: "VibeThinker-3B.Q4_K_M.gguf",
            downloadURL: URL(string: "https://huggingface.co/prithivMLmods/VibeThinker-3B-GGUF/resolve/main/VibeThinker-3B.Q4_K_M.gguf?download=true")!,
            expectedBytes: 1_930_000_000,
            minimumPhysicalMemoryBytes: 5_500_000_000,
            recommendedFreeDiskBytes: 3_000_000_000,
            contextTokens: 3_072,
            batchTokens: 192,
            maxNewTokens: 640,
            maxGenerationSeconds: 60,
            useGPU: true,
            gpuLayerCount: 99,
            generationThreadCount: 2,
            batchThreadCount: 3,
            isIPhone12SafeDefault: false,
            details: "Highest local quality option here. Not the safe default for iPhone 12."
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
            ?? all[0]
    }

    static func compatibilityMessage(
        for variant: LocalModelVariant,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> String? {
        if physicalMemory < variant.minimumPhysicalMemoryBytes {
            let needed = ByteCountFormatter.string(fromByteCount: Int64(variant.minimumPhysicalMemoryBytes), countStyle: .memory)
            let current = ByteCountFormatter.string(fromByteCount: Int64(physicalMemory), countStyle: .memory)
            return "\(variant.shortName) needs about \(needed) RAM. This device reports \(current). Use VibeThinker Q2 for iPhone 12."
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
                LocalModelStatusProbe.probe(variant: variant)
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

    func localFileURL(for variant: LocalModelVariant? = nil) throws -> URL {
        let variant = variant ?? selectedVariant
        let url = try LocalModelCatalog.fileURL(for: variant)
        guard let size = fileSize(at: url), size >= LocalModelDownloader.minimumCompleteBytes(for: variant) else {
            throw LocalModelRuntimeError.modelNotDownloaded(variant.displayName)
        }
        return url
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
    static func probe(variant: LocalModelVariant) -> LocalModelStatusProbeResult {
        let emptyProgress = LocalModelDownloadProgress(receivedBytes: 0, totalBytes: variant.expectedBytes)
        if let message = compatibilityMessage(for: variant) {
            return .init(status: .incompatible(message), progress: emptyProgress, downloadedBytes: 0)
        }

        do {
            let url = try LocalModelCatalog.fileURL(for: variant)
            let partialURL = LocalModelDownloader.temporaryURL(for: url)
            if let size = fileSize(at: url), size >= LocalModelDownloader.minimumCompleteBytes(for: variant) {
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
    static func temporaryURL(for destination: URL) -> URL {
        destination.appendingPathExtension("download")
    }

    static func minimumCompleteBytes(for variant: LocalModelVariant) -> Int64 {
        Int64(Double(variant.expectedBytes) * 0.98)
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
        var startingBytes = fileSize(at: temporaryURL)

        var request = URLRequest(url: variant.downloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if startingBytes > 0 {
            request.setValue("bytes=\(startingBytes)-", forHTTPHeaderField: "Range")
        }

        let (downloadedURL, response) = try await URLSession.shared.download(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalModelRuntimeError.downloadFailed("Hugging Face returned an invalid response for \(variant.filename).")
        }

        if startingBytes > 0, http.statusCode == 206 {
            if !FileManager.default.fileExists(atPath: temporaryURL.path) {
                FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
            }
            try appendFile(downloadedURL, to: temporaryURL)
        } else {
            try? FileManager.default.removeItem(at: temporaryURL)
            try FileManager.default.moveItem(at: downloadedURL, to: temporaryURL)
            startingBytes = 0
        }

        let totalBytes = totalBytes(from: http, startingBytes: startingBytes, fallback: variant.expectedBytes)
        let received = fileSize(at: temporaryURL)
        await progress(.init(receivedBytes: received, totalBytes: max(received, totalBytes)))

        if totalBytes > 0, received < totalBytes {
            throw LocalModelRuntimeError.downloadFailed("Download stopped early at \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)). Tap Resume to continue.")
        }

        try validateCompleteDownload(variant: variant, receivedBytes: received)

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        await progress(.init(receivedBytes: received, totalBytes: max(received, totalBytes)))
    }

    static func validateCompleteDownload(variant: LocalModelVariant, receivedBytes: Int64) throws {
        let minimumBytes = minimumCompleteBytes(for: variant)
        guard receivedBytes >= minimumBytes else {
            let receivedLabel = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
            let minimumLabel = ByteCountFormatter.string(fromByteCount: minimumBytes, countStyle: .file)
            throw LocalModelRuntimeError.downloadFailed("Download stopped before \(variant.shortName) reached the minimum usable size (\(receivedLabel) of at least \(minimumLabel)). Tap Resume to continue.")
        }
    }

    private static func appendFile(_ source: URL, to destination: URL) throws {
        let readHandle = try FileHandle(forReadingFrom: source)
        defer { try? readHandle.close() }
        let writeHandle = try FileHandle(forWritingTo: destination)
        defer { try? writeHandle.close() }
        try writeHandle.seekToEnd()

        while true {
            try Task.checkCancellation()
            let chunk = try readHandle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try writeHandle.write(contentsOf: chunk)
        }
    }

    private static func totalBytes(from response: HTTPURLResponse, startingBytes: Int64, fallback: Int64) -> Int64 {
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

    private static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}

actor LocalModelClient {
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

    func streamingResponse(
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

        let modelURL = try LocalModelCatalog.fileURL(for: variant)
        guard fileSize(at: modelURL) >= LocalModelDownloader.minimumCompleteBytes(for: variant) else {
            throw LocalModelRuntimeError.modelNotDownloaded(variant.displayName)
        }

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
                   elapsed >= .milliseconds(520) || pending.count >= 260 || pending.contains("\n\n") {
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

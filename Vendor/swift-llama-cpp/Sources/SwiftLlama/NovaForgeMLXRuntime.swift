import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Experimental MLX lane for NovaForge pre-2.0.
///
/// This intentionally lives beside the existing llama.cpp adapter so the app can
/// keep a proven GGUF rollback path while the MLX lane is qualified on physical
/// devices. The initial target is the A14/4-GB class: keep the model small, keep
/// context bounded, and compress the KV cache instead of chasing giant context.
public enum NovaForgeMLXProfile: String, CaseIterable, Sendable {
    /// Best quality/RAM balance we currently want to qualify on iPhone 12.
    case nanbeige42Coder3Bit

    /// Emergency low-memory fallback when the 3-bit profile cannot be admitted.
    case nanbeige42Coder2Bit

    public var repositoryID: String {
        switch self {
        case .nanbeige42Coder3Bit:
            return "MercuriusDream/Nanbeige4.2-3B-mlx-3bit"
        case .nanbeige42Coder2Bit:
            return "MercuriusDream/Nanbeige4.2-3B-mlx-2bit"
        }
    }

    public var displayName: String {
        switch self {
        case .nanbeige42Coder3Bit:
            return "Nanbeige 4.2 3B · MLX 3-bit"
        case .nanbeige42Coder2Bit:
            return "Nanbeige 4.2 3B · MLX 2-bit"
        }
    }

    /// Published weight-only size, rounded up. This is not a peak-RAM claim.
    public var approximateWeightBytes: UInt64 {
        switch self {
        case .nanbeige42Coder3Bit:
            return 1_825_000_000
        case .nanbeige42Coder2Bit:
            return 1_300_000_000
        }
    }

    /// Keep the live window intentionally small on A14. Project capsules and
    /// retrieval should carry long-lived project state instead of a giant KV cache.
    public var maximumKVSize: Int { 2_048 }

    /// Aug-10-2026 MLX Swift LM recommends turbo8v3 as the default asymmetric
    /// TurboQuant balance. It keeps keys near-lossless while compressing values.
    public var kvScheme: String { "turbo8v3" }

    public var maximumNewTokens: Int {
        switch self {
        case .nanbeige42Coder3Bit:
            return 384
        case .nanbeige42Coder2Bit:
            return 320
        }
    }
}

public struct NovaForgeMLXGenerationOptions: Sendable {
    public var maximumTokens: Int
    public var temperature: Float
    public var topP: Float

    public init(
        maximumTokens: Int = 320,
        temperature: Float = 0.15,
        topP: Float = 0.95
    ) {
        self.maximumTokens = maximumTokens
        self.temperature = temperature
        self.topP = topP
    }
}

public struct NovaForgeMLXRuntimeSnapshot: Equatable, Sendable {
    public let loadedProfile: NovaForgeMLXProfile?
    public let isGenerating: Bool

    public init(loadedProfile: NovaForgeMLXProfile?, isGenerating: Bool) {
        self.loadedProfile = loadedProfile
        self.isGenerating = isGenerating
    }
}

public enum NovaForgeMLXRuntimeError: Error, Equatable, Sendable {
    case generationAlreadyInProgress
    case runtimeBusy
    case invalidMaximumTokens
    case invalidRepositoryID(String)
    case modelNotCached(String)
}

/// Actor-isolated lease state that stays held across async model loading and
/// streaming callbacks. Swift actors are reentrant at `await` points, so actor
/// isolation alone does not prevent `warm()` or `unload()` from entering while
/// a generation is suspended.
enum NovaForgeMLXRuntimeOperation: Equatable, Sendable {
    case warm
    case generation
}

struct NovaForgeMLXRuntimeOperationGate: Sendable {
    private(set) var activeOperation: NovaForgeMLXRuntimeOperation?

    var isGenerating: Bool {
        activeOperation == .generation
    }

    mutating func begin(_ operation: NovaForgeMLXRuntimeOperation) throws {
        guard activeOperation == nil else {
            if operation == .generation, activeOperation == .generation {
                throw NovaForgeMLXRuntimeError.generationAlreadyInProgress
            }
            throw NovaForgeMLXRuntimeError.runtimeBusy
        }
        activeOperation = operation
    }

    mutating func end(_ operation: NovaForgeMLXRuntimeOperation) {
        precondition(activeOperation == operation)
        activeOperation = nil
    }

    func requireIdle() throws {
        guard activeOperation == nil else {
            throw NovaForgeMLXRuntimeError.runtimeBusy
        }
    }
}

/// A cache-only MLX downloader used during inference.
///
/// The normal Hugging Face bridge is intentionally *not* used here because its
/// `download` implementation may contact the Hub when a snapshot is missing.
/// NovaForge Local Only must fail closed instead of turning an inference request
/// into implicit network traffic after relaunch. Model installation/warming is a
/// separate, explicit action and is allowed to use the network.
private struct NovaForgeCachedHubDownloader: Downloader {
    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else {
            throw NovaForgeMLXRuntimeError.invalidRepositoryID(id)
        }

        let cache = HubCache.default
        let requestedRevision = revision ?? "main"
        let commit = cache.resolveRevision(
            repo: repo,
            kind: .model,
            ref: requestedRevision
        ) ?? requestedRevision
        let snapshot = try cache.snapshotPath(
            repo: repo,
            kind: .model,
            commitHash: commit
        )

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: snapshot.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw NovaForgeMLXRuntimeError.modelNotCached(id)
        }

        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        progressHandler(progress)
        return snapshot
    }
}

/// Serializes MLX access for the local NovaForge agent lane.
///
/// `ChatSession` itself documents that it is not thread-safe. The operation
/// lease remains held across actor suspension points so model loading, warming,
/// generation, and unload cannot mutate the same MLX container concurrently.
public actor NovaForgeMLXRuntime {
    public static let shared = NovaForgeMLXRuntime()

    private var loadedProfile: NovaForgeMLXProfile?
    private var modelContainer: ModelContainer?
    private var operationGate = NovaForgeMLXRuntimeOperationGate()

    public init() {}

    public func snapshot() -> NovaForgeMLXRuntimeSnapshot {
        NovaForgeMLXRuntimeSnapshot(
            loadedProfile: loadedProfile,
            isGenerating: operationGate.isGenerating
        )
    }

    /// Returns whether Hugging Face's local cache currently resolves a snapshot for
    /// the profile. This is intentionally local filesystem/cache inspection only.
    public func isCached(profile: NovaForgeMLXProfile) -> Bool {
        Self.cachedSnapshotURL(profile: profile) != nil
    }

    /// Explicit install/warm path. This is the only path in this adapter that is
    /// allowed to use Hugging Face networking. Once warm succeeds, normal
    /// generation can be reconstructed from the local snapshot with zero Hub I/O.
    public func warm(profile: NovaForgeMLXProfile) async throws {
        try operationGate.begin(.warm)
        defer { operationGate.end(.warm) }
        _ = try await container(for: profile, networkPolicy: .installationAllowed)
    }

    /// Releases NovaForge's strong references. MLX may reclaim backing resources
    /// asynchronously after this returns. A suspended warm/generation owns the
    /// container until its operation lease ends, so unload fails closed while busy.
    public func unload() throws {
        try operationGate.requireIdle()
        modelContainer = nil
        loadedProfile = nil
    }

    /// Run one coding turn while preserving streaming backpressure at the app seam.
    ///
    /// The app supplies the native tool/result transcript in `prompt`; tool
    /// authorization remains in NovaForge's AgentTools boundary. This adapter does
    /// not execute filesystem or shell actions itself.
    ///
    /// If the model is not already resident, this path loads *only* from the local
    /// Hugging Face snapshot. Missing bytes fail closed with `modelNotCached`.
    public func generate(
        profile: NovaForgeMLXProfile = .nanbeige42Coder3Bit,
        instructions: String = NovaForgeMLXRuntime.defaultCoderInstructions,
        prompt: String,
        options: NovaForgeMLXGenerationOptions = .init(),
        onText: @escaping @Sendable (String) async throws -> Void
    ) async throws {
        try operationGate.begin(.generation)
        defer { operationGate.end(.generation) }

        guard options.maximumTokens > 0 else {
            throw NovaForgeMLXRuntimeError.invalidMaximumTokens
        }

        let container = try await container(for: profile, networkPolicy: .cacheOnly)
        let parameters = GenerateParameters(
            maxTokens: min(options.maximumTokens, profile.maximumNewTokens),
            maxKVSize: profile.maximumKVSize,
            kvScheme: profile.kvScheme,
            temperature: options.temperature,
            topP: options.topP,
            topK: 40,
            minP: 0.0,
            repetitionPenalty: 1.04,
            repetitionContextSize: 64
        )
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: parameters
        )

        for try await chunk in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            try await onText(chunk)
        }
    }

    public static let defaultCoderInstructions = """
    You are NovaForge Local Coder, a compact on-device coding agent. Be concise,
    inspect the project evidence provided by NovaForge, make the smallest correct
    change, preserve existing architecture, and never invent successful tool or
    build results. When NovaForge provides tool results, use them as ground truth.
    Prefer targeted patches over rewriting unrelated files.
    """

    private enum NetworkPolicy {
        case installationAllowed
        case cacheOnly
    }

    private func container(
        for profile: NovaForgeMLXProfile,
        networkPolicy: NetworkPolicy
    ) async throws -> ModelContainer {
        if loadedProfile == profile, let modelContainer {
            return modelContainer
        }

        // Drop the previous model before loading another one; retaining two local
        // models simultaneously is the wrong tradeoff on 4-GB devices.
        modelContainer = nil
        loadedProfile = nil

        let configuration = ModelConfiguration(id: profile.repositoryID)
        let downloader: any Downloader
        switch networkPolicy {
        case .installationAllowed:
            downloader = #hubDownloader()
        case .cacheOnly:
            guard Self.cachedSnapshotURL(profile: profile) != nil else {
                throw NovaForgeMLXRuntimeError.modelNotCached(profile.repositoryID)
            }
            downloader = NovaForgeCachedHubDownloader()
        }

        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: downloader,
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration
        )
        modelContainer = loaded
        loadedProfile = profile
        return loaded
    }

    private static func cachedSnapshotURL(profile: NovaForgeMLXProfile) -> URL? {
        guard let repo = Repo.ID(rawValue: profile.repositoryID) else {
            return nil
        }

        let cache = HubCache.default
        guard let commit = cache.resolveRevision(
            repo: repo,
            kind: .model,
            ref: "main"
        ), let snapshot = try? cache.snapshotPath(
            repo: repo,
            kind: .model,
            commitHash: commit
        ) else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: snapshot.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }
        return snapshot
    }
}

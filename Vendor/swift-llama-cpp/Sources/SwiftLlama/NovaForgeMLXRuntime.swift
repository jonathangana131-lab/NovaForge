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
    case invalidMaximumTokens
}

/// Serializes MLX access for the local NovaForge agent lane.
///
/// `ChatSession` itself documents that it is not thread-safe. Keeping the model
/// and active session behind one actor also prevents two local generations from
/// competing for the A14 GPU and memory at the same time.
public actor NovaForgeMLXRuntime {
    public static let shared = NovaForgeMLXRuntime()

    private var loadedProfile: NovaForgeMLXProfile?
    private var modelContainer: ModelContainer?
    private var isGenerating = false

    public init() {}

    public func snapshot() -> NovaForgeMLXRuntimeSnapshot {
        NovaForgeMLXRuntimeSnapshot(
            loadedProfile: loadedProfile,
            isGenerating: isGenerating
        )
    }

    /// Downloads/loads the selected MLX checkpoint and keeps its weights warm.
    /// The Hugging Face integration reuses its on-device cache on later launches.
    public func warm(profile: NovaForgeMLXProfile) async throws {
        _ = try await container(for: profile)
    }

    /// Releases NovaForge's strong references. MLX may reclaim backing resources
    /// asynchronously after this returns.
    public func unload() {
        modelContainer = nil
        loadedProfile = nil
    }

    /// Run one coding turn while preserving streaming backpressure at the app seam.
    ///
    /// The app supplies the native tool/result transcript in `prompt`; tool
    /// authorization remains in NovaForge's AgentTools boundary. This adapter does
    /// not execute filesystem or shell actions itself.
    public func generate(
        profile: NovaForgeMLXProfile = .nanbeige42Coder3Bit,
        instructions: String = NovaForgeMLXRuntime.defaultCoderInstructions,
        prompt: String,
        options: NovaForgeMLXGenerationOptions = .init(),
        onText: @escaping @Sendable (String) async throws -> Void
    ) async throws {
        guard !isGenerating else {
            throw NovaForgeMLXRuntimeError.generationAlreadyInProgress
        }
        guard options.maximumTokens > 0 else {
            throw NovaForgeMLXRuntimeError.invalidMaximumTokens
        }

        isGenerating = true
        defer { isGenerating = false }

        let container = try await container(for: profile)
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

    private func container(for profile: NovaForgeMLXProfile) async throws -> ModelContainer {
        if loadedProfile == profile, let modelContainer {
            return modelContainer
        }

        // Drop the previous model before loading another one; retaining two local
        // models simultaneously is the wrong tradeoff on 4-GB devices.
        modelContainer = nil
        loadedProfile = nil

        let configuration = ModelConfiguration(id: profile.repositoryID)
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration
        )
        modelContainer = loaded
        loadedProfile = profile
        return loaded
    }
}

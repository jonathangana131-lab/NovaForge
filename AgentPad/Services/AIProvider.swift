import Foundation
import SwiftUI

enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case local
    case openAI
    case openAICodex
    case openRouter
    case openCodeZen
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: "Local"
        case .openAI: "OpenAI"
        case .openAICodex: "OpenAI Codex"
        case .openRouter: "OpenRouter"
        case .openCodeZen: "OpenCode Zen"
        case .custom: "Custom"
        }
    }

    var shortName: String {
        switch self {
        case .local: "Local"
        case .openAI: "OpenAI"
        case .openAICodex: "Codex"
        case .openRouter: "Router"
        case .openCodeZen: "Zen"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .local: "cpu.fill"
        case .openAI: "sparkles"
        case .openAICodex: "terminal.fill"
        case .openRouter: "point.3.connected.trianglepath.dotted"
        case .openCodeZen: "bolt.horizontal.circle"
        case .custom: "link"
        }
    }

    var tint: Color {
        switch self {
        case .local: AgentPalette.green
        case .openAI: AgentPalette.blue
        case .openAICodex: AgentPalette.indigo
        case .openRouter: AgentPalette.cyan
        case .openCodeZen: AgentPalette.cyan
        case .custom: AgentPalette.rose
        }
    }

    var defaultModel: String {
        modelOptions.first ?? ""
    }

    var apiKeyAccount: String {
        switch self {
        case .openAICodex:
            // Codex-compatible model IDs currently route through OpenAI-compatible
            // API infrastructure, so reuse the saved OpenAI key instead of making
            // users paste the same credential into a second slot.
            "api_key_openAI"
        default:
            "api_key_\(rawValue)"
        }
    }

    var credentialDisplayName: String {
        switch self {
        case .openAICodex:
            "OpenAI"
        default:
            displayName
        }
    }

    var credentialHelpText: String {
        switch self {
        case .openAICodex:
            "Uses your OpenAI API key for Codex-compatible model IDs. ChatGPT/Codex subscription tokens are not exposed to iOS apps."
        case .openAI:
            "Uses your OpenAI API key for hosted GPT models."
        case .openRouter:
            "Uses your OpenRouter key to browse and call many hosted models."
        case .openCodeZen:
            "Uses your OpenCode Zen key for coding-agent tuned models."
        case .custom:
            "Uses the key expected by your OpenAI-compatible endpoint."
        case .local:
            "No key needed. Local runs stay on-device after the model is downloaded."
        }
    }

    var missingCredentialMessage: String {
        switch self {
        case .openAICodex:
            "OpenAI API key needed for Codex IDs. ChatGPT subscriptions are not available to iOS apps."
        case .openAI:
            "Add an OpenAI API key in Settings before sending with this provider."
        case .openRouter:
            "Add an OpenRouter API key in Settings before sending with this provider."
        case .custom:
            "Add the API key for your custom OpenAI-compatible endpoint in Settings before sending."
        default:
            "Add a \(credentialDisplayName) API key in Settings before sending with this provider."
        }
    }

    var defaultChatCompletionsURL: String {
        switch self {
        case .local:
            ""
        case .openAI, .openAICodex:
            "https://api.openai.com/v1/chat/completions"
        case .openRouter:
            "https://openrouter.ai/api/v1/chat/completions"
        case .openCodeZen:
            "https://opencode.ai/zen/v1/chat/completions"
        case .custom:
            ""
        }
    }

    var modelsURL: URL? {
        switch self {
        case .local:
            nil
        case .openAI, .openAICodex:
            URL(string: "https://api.openai.com/v1/models")
        case .openRouter:
            URL(string: "https://openrouter.ai/api/v1/models")
        case .openCodeZen:
            URL(string: "https://opencode.ai/zen/v1/models")
        case .custom:
            nil
        }
    }

    var modelOptions: [String] {
        switch self {
        case .local:
            [
                "WeiboAI/VibeThinker-3B-Q2_K",
                "WeiboAI/VibeThinker-3B-Q3_K_M",
                "WeiboAI/VibeThinker-3B-Q4_K_S",
                "WeiboAI/VibeThinker-3B-Q4_K_M"
            ]
        case .openAI:
            [
                "gpt-5.5",
                "gpt-5.4",
                "gpt-5.1",
                "gpt-5",
                "gpt-4.1",
                "gpt-4.1-mini",
                "gpt-4o",
                "gpt-4o-mini",
                "o4-mini",
                "o3",
                "o3-mini"
            ]
        case .openAICodex:
            [
                "gpt-5.1-codex",
                "gpt-5-codex",
                "codex-mini-latest"
            ]
        case .openRouter:
            [
                "openai/gpt-5.5",
                "anthropic/claude-sonnet-4.5",
                "google/gemini-3-pro",
                "x-ai/grok-4.1",
                "moonshotai/kimi-k2.5"
            ]
        case .openCodeZen:
            [
                "kimi-k2.6",
                "glm-5.1",
                "minimax-m2.7",
                "grok-build-0.1",
                "deepseek-v4-flash-free"
            ]
        case .custom:
            ["llama-3.3-70b", "qwen3-coder", "local-model"]
        }
    }

    var subtitle: String {
        switch self {
        case .local:
            "On-device VibeThinker"
        case .openAI:
            "Native OpenAI key"
        case .openAICodex:
            "OpenAI key for Codex-compatible IDs"
        case .openRouter:
            "One key, many hosted models"
        case .openCodeZen:
            "Coding-agent tuned Zen models"
        case .custom:
            "Any OpenAI-compatible endpoint"
        }
    }
}

struct ProviderConfiguration: Equatable, Sendable {
    let provider: AIProvider
    let modelID: String
    let apiKey: String
    let customChatCompletionsURL: String

    var chatCompletionsURL: URL? {
        let raw = provider == .custom ? normalizedCustomChatCompletionsURL : provider.defaultChatCompletionsURL
        return URL(string: raw)
    }

    var modelsURL: URL? {
        if let providerModelsURL = provider.modelsURL {
            return providerModelsURL
        }
        guard provider == .custom else { return nil }
        let trimmed = normalizedCustomChatCompletionsURL
        guard trimmed.hasSuffix("/chat/completions") else { return nil }
        return URL(string: String(trimmed.dropLast("/chat/completions".count)) + "/models")
    }

    var modelCapabilities: ProviderModelCapabilities {
        ProviderModelCapabilities(provider: provider, modelID: modelID)
    }

    private var normalizedCustomChatCompletionsURL: String {
        var trimmed = customChatCompletionsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix("/chat/completions") {
            return trimmed
        }
        if trimmed.hasSuffix("/v1") {
            return trimmed + "/chat/completions"
        }
        return trimmed
    }
}

struct ProviderModelCapabilities: Equatable, Sendable {
    let requiresReasoningContentForToolContinuation: Bool

    init(provider: AIProvider, modelID: String) {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        requiresReasoningContentForToolContinuation = provider == .openCodeZen &&
            normalizedModelID.hasPrefix("deepseek-v4-")
    }
}

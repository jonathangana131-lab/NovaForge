import AgentProviders
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UIKit

enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    static let exactGPT56SolModelID = "gpt-5.6-sol"
    static let exactGPT56TerraModelID = "gpt-5.6-terra"
    static let exactGPT56LunaModelID = "gpt-5.6-luna"

    case local
    case openAI
    case openAICodex
    case openRouter
    case openCodeZen
    case custom

    /// Routes with complete canonical AgentSystem support. Legacy generic
    /// endpoints remain decodable so saved settings can be recovered, but the
    /// product must not offer a choice that is guaranteed to fail at send.
    static let agentRuntimeProviders: [AIProvider] = [
        .openCodeZen, .local, .openAICodex, .openAI,
    ]

    /// Providers that may be selected for a new phone run. The legacy
    /// ChatGPT/Codex route remains decodable for durable recovery, but it is
    /// intentionally absent here because ChatGPT subscriptions and the public
    /// developer API are separate products and the private backend is not a
    /// stable app integration contract.
    static let userSelectableProviders: [AIProvider] = [
        .openCodeZen, .local, .openAI,
    ]

    var supportsAgentRuntime: Bool {
        Self.agentRuntimeProviders.contains(self)
    }

    var isUserSelectable: Bool {
        Self.userSelectableProviders.contains(self)
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: "Local"
        case .openAI: "OpenAI"
        case .openAICodex: "ChatGPT"
        case .openRouter: "OpenRouter"
        case .openCodeZen: "OpenCode Zen"
        case .custom: "Custom"
        }
    }

    var shortName: String {
        switch self {
        case .local: "Local"
        case .openAI: "OpenAI"
        case .openAICodex: "ChatGPT"
        case .openRouter: "Router"
        case .openCodeZen: "Zen"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .local: "cpu.fill"
        case .openAI: "key.fill"
        case .openAICodex: "sparkles"
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
            "oauth_openai_codex_access_token"
        default:
            "api_key_\(rawValue)"
        }
    }

    var credentialDisplayName: String {
        switch self {
        case .openAICodex:
            "ChatGPT"
        default:
            displayName
        }
    }

    var credentialHelpText: String {
        switch self {
        case .openAICodex:
            "Sign in with ChatGPT to use supported GPT models with the usage included in an eligible subscription. Tokens stay in the iOS Keychain."
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
            "Sign in with ChatGPT in Control before sending with this provider."
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
        case .openAI:
            "https://api.openai.com/v1/chat/completions"
        case .openAICodex:
            "https://chatgpt.com/backend-api/codex/responses"
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
            return nil
        case .openAI:
            return URL(string: "https://api.openai.com/v1/models")
        case .openAICodex:
            var components = URLComponents(
                string: "https://chatgpt.com/backend-api/codex/models"
            )
            components?.queryItems = [
                URLQueryItem(
                    name: "client_version",
                    value: Self.chatGPTClientVersion
                ),
            ]
            return components?.url
        case .openRouter:
            return URL(string: "https://openrouter.ai/api/v1/models")
        case .openCodeZen:
            return URL(string: "https://opencode.ai/zen/v1/models")
        case .custom:
            return nil
        }
    }

    var modelOptions: [String] {
        switch self {
        case .local:
            LocalModelCatalog.all.map(\.id)
        case .openAI:
            [
                "gpt-5",
                "gpt-5.1",
                "gpt-5-mini",
                "gpt-5-nano",
                "gpt-4.1",
                "gpt-4.1-mini",
                "gpt-4.1-nano",
                "o4-mini",
                "o3",
                "o3-mini",
                "gpt-4o",
                "gpt-4o-mini"
            ]
        case .openAICodex:
            [
                Self.exactGPT56SolModelID,
                Self.exactGPT56TerraModelID,
                Self.exactGPT56LunaModelID,
                "gpt-5.5",
                "gpt-5.4",
                "gpt-5.4-mini",
                "gpt-5.3-codex-spark",
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
                "mimo-v2.5-free",
                "laguna-s-2.1-free",
                "ling-3.0-flash-free",
                "north-mini-code-free",
                "nemotron-3-ultra-free",
                "deepseek-v4-flash-free",
                "big-pickle",
                "kimi-k2.7-code",
                "kimi-k2.6",
                "kimi-k2.5",
                "glm-5.2",
                "glm-5.1",
                "glm-5",
                "minimax-m3",
                "minimax-m2.7",
                "minimax-m2.5",
                "deepseek-v4-pro",
                "deepseek-v4-flash",
                "grok-build-0.1",
                "grok-4.5",
            ]
        case .custom:
            ["llama-3.3-70b", "qwen3-coder", "local-model"]
        }
    }

    var subtitle: String {
        switch self {
        case .local:
            "On-device Qwen Coder agent"
        case .openAI:
            "Native OpenAI key"
        case .openAICodex:
            "GPT models with ChatGPT subscription"
        case .openRouter:
            "One key, many hosted models"
        case .openCodeZen:
            "Free and paid coding-agent models"
        case .custom:
            "Any OpenAI-compatible endpoint"
        }
    }

    func modelDisplayName(_ modelID: String) -> String {
        switch modelID.lowercased() {
        case Self.exactGPT56SolModelID: "GPT-5.6 Sol"
        case Self.exactGPT56TerraModelID: "GPT-5.6 Terra"
        case Self.exactGPT56LunaModelID: "GPT-5.6 Luna"
        case "gpt-5.5": "GPT-5.5"
        case "gpt-5.4": "GPT-5.4"
        case "gpt-5.4-mini": "GPT-5.4 Mini"
        case "gpt-5.3-codex-spark": "GPT-5.3 Codex Spark"
        default: modelID
        }
    }

    func modelDetail(_ modelID: String) -> String? {
        switch modelID.lowercased() {
        case Self.exactGPT56SolModelID:
            "Flagship · complex coding and reasoning"
        case Self.exactGPT56TerraModelID:
            "Balanced intelligence and cost"
        case Self.exactGPT56LunaModelID:
            "Cost-sensitive, high-volume work"
        case "gpt-5.5":
            "Frontier coding, research, and agent work"
        case "gpt-5.4":
            "Deep coding and reasoning"
        case "gpt-5.4-mini":
            "Faster everyday agent work"
        case "gpt-5.3-codex-spark":
            "Fast Codex coding model"
        default:
            nil
        }
    }

    func fallbackReasoningEfforts(_ modelID: String) -> [String] {
        guard self == .openAICodex, modelOptions.contains(modelID) else {
            return []
        }
        if modelID.lowercased().hasPrefix("gpt-5.6") {
            return ["none", "low", "medium", "high", "xhigh", "max"]
        }
        return ["low", "medium", "high", "xhigh"]
    }

    /// Zen's explicitly suffixed free routes are currently served without an
    /// Authorization header. Omitting a stale saved key is important: Zen
    /// rejects an invalid bearer token even when the same free model accepts
    /// an anonymous request. Paid Zen routes and every other hosted provider
    /// remain credential-gated.
    func requiresCredential(for modelID: String) -> Bool {
        switch self {
        case .local:
            false
        case .openCodeZen:
            !modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().hasSuffix("-free")
        case .openAI, .openAICodex, .openRouter, .custom:
            true
        }
    }

    func visibleModelIdentity(_ modelID: String) -> String {
        // Picker equality must preserve the exact wire identity. Treating a
        // family alias or differently-cased value as `gpt-5.6-sol` can make
        // the UI show a valid selection that the request factory will reject.
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func requiresExplicitGPT56ModelSelection(_ modelID: String) -> Bool {
        guard self == .openAICodex else { return false }
        let normalized = modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "gpt-5.6" || normalized.hasPrefix("gpt-5.6-")
    }

    static func normalizedChatGPTClientVersion(_ rawValue: String?) -> String {
        guard let rawValue else { return "1.0.0" }
        let parts = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return "1.0.0" }

        var normalized: [String] = []
        for part in parts.prefix(3) {
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = UInt16(digits) else {
                return "1.0.0"
            }
            normalized.append(String(value))
        }
        while normalized.count < 3 { normalized.append("0") }
        return normalized.joined(separator: ".")
    }

    private static var chatGPTClientVersion: String {
        normalizedChatGPTClientVersion(
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
        )
    }
}

struct ProviderConfiguration: Equatable, Sendable {
    let provider: AIProvider
    let modelID: String
    let apiKey: String
    let customChatCompletionsURL: String

    var chatCompletionsURL: URL? {
        let raw = provider == .custom ? normalizedCustomChatCompletionsURL : provider.defaultChatCompletionsURL
        return Self.validatedProviderURL(raw)
    }

    var modelsURL: URL? {
        if let providerModelsURL = provider.modelsURL {
            return Self.validatedProviderURL(providerModelsURL.absoluteString)
        }
        guard provider == .custom else { return nil }
        let trimmed = normalizedCustomChatCompletionsURL
        guard trimmed.hasSuffix("/chat/completions") else { return nil }
        return Self.validatedProviderURL(String(trimmed.dropLast("/chat/completions".count)) + "/models")
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

    private static func validatedProviderURL(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            return nil
        }
        return url
    }
}

/// One process-wide, live provider catalog. Control and Forge read the same
/// snapshot so a model never appears selectable in one surface but missing in
/// the other. Static app-owned options remain the fail-closed offline fallback.
@MainActor
@Observable
final class ProviderModelCatalogStore {
    static let shared = ProviderModelCatalogStore()

    private(set) var entriesByProvider: [AIProvider: [ProviderModelCatalogEntry]] = [:]
    private(set) var loadingProviders: Set<AIProvider> = []
    private(set) var errorsByProvider: [AIProvider: String] = [:]

    private let keychain = KeychainStore()

    private init() {}

    func entries(for provider: AIProvider) -> [ProviderModelCatalogEntry] {
        visibleEntries(
            entriesByProvider[provider]
                ?? provider.modelOptions.map {
                ProviderModelCatalogEntry(
                    id: $0,
                    displayName: provider.modelDisplayName($0),
                    supportedReasoningEfforts: provider.fallbackReasoningEfforts($0)
                )
            },
            provider: provider
        )
    }

    func hasLiveCatalog(for provider: AIProvider) -> Bool {
        entriesByProvider[provider] != nil
    }

    func entry(
        for provider: AIProvider,
        modelID: String
    ) -> ProviderModelCatalogEntry? {
        let visibleIdentity = provider.visibleModelIdentity(modelID)
        return entries(for: provider).first(where: { $0.id == modelID })
            ?? entries(for: provider).first(where: {
                provider.visibleModelIdentity($0.id) == visibleIdentity
            })
    }

    func displayName(
        for provider: AIProvider,
        modelID: String
    ) -> String {
        entry(for: provider, modelID: modelID)?.displayName
            ?? provider.modelDisplayName(modelID)
    }

    func clear(provider: AIProvider) {
        entriesByProvider[provider] = nil
        loadingProviders.remove(provider)
        errorsByProvider[provider] = nil
    }

    func models(for provider: AIProvider) -> [String] {
        entries(for: provider).map(\.id)
    }

    func supportedReasoningEfforts(
        provider: AIProvider,
        modelID: String
    ) -> [ProviderReasoningEffort] {
        entry(for: provider, modelID: modelID)?
            .supportedReasoningEfforts.compactMap(ProviderReasoningEffort.init(rawValue:)) ?? []
    }

    func refresh(
        provider: AIProvider,
        customChatCompletionsURL: String = ""
    ) async {
        guard provider != .local, !loadingProviders.contains(provider) else {
            return
        }
        let credential = (try? keychain.read(provider.apiKeyAccount)) ?? ""
        guard provider == .openCodeZen || !credential.isEmpty else {
            errorsByProvider[provider] = provider.missingCredentialMessage
            return
        }

        loadingProviders.insert(provider)
        errorsByProvider[provider] = nil
        defer { loadingProviders.remove(provider) }
        do {
            let loaded = try await AIProviderClient(
                configuration: ProviderConfiguration(
                    provider: provider,
                    modelID: provider.defaultModel,
                    apiKey: credential,
                    customChatCompletionsURL: customChatCompletionsURL
                )
            ).modelCatalog()
            try Task.checkCancellation()
            let loadedByID = loaded.reduce(
                into: [String: ProviderModelCatalogEntry](),
                { result, entry in result[entry.id] = entry }
            )
            let compatible = provider.modelOptions.compactMap { loadedByID[$0] }
            guard !compatible.isEmpty else {
                errorsByProvider[provider] = "No verified NovaForge model is available for this account. Refresh the catalog or choose Zen Free."
                return
            }
            entriesByProvider[provider] = visibleEntries(
                compatible,
                provider: provider
            )
        } catch is CancellationError {
            return
        } catch {
            errorsByProvider[provider] = "Could not refresh the live \(provider.displayName) model catalog."
        }
    }

    private func visibleEntries(
        _ entries: [ProviderModelCatalogEntry],
        provider: AIProvider
    ) -> [ProviderModelCatalogEntry] {
        var result: [ProviderModelCatalogEntry] = []
        var positions: [String: Int] = [:]
        for entry in entries {
            let identity = provider.visibleModelIdentity(entry.id)
            if let position = positions[identity] {
                if entry.id.lowercased() == identity { result[position] = entry }
                continue
            }
            positions[identity] = result.count
            result.append(entry)
        }
        return result
    }
}

enum AgentOrchestrationMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard
    case ultra
    case ultraCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .ultra: "Ultra"
        case .ultraCode: "UltraCode"
        }
    }

    var shortTitle: String {
        switch self {
        case .standard: "Think"
        case .ultra: "Ultra"
        case .ultraCode: "UltraCode"
        }
    }

    var detail: String {
        switch self {
        case .standard:
            "One focused agent in the current workspace."
        case .ultra:
            "Maximum reasoning with parallel research and review agents."
        case .ultraCode:
            "Maximum reasoning, isolated coding workspaces, verification, and an integrating lead agent."
        }
    }

    var symbol: String {
        switch self {
        case .standard: "brain.head.profile"
        case .ultra: "sparkles"
        case .ultraCode: "point.3.filled.connected.trianglepath.dotted"
        }
    }
}

extension ProviderReasoningEffort {
    var title: String {
        switch self {
        case .none: "Instant"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        }
    }

    var compactTitle: String {
        switch self {
        case .none: "Fast"
        case .xhigh: "XHigh"
        default: title
        }
    }

    var detail: String {
        switch self {
        case .none: "Fastest answer with no extended reasoning budget."
        case .low: "Quick work with a small reasoning budget."
        case .medium: "Balanced reasoning for everyday agent tasks."
        case .high: "Deeper analysis for difficult work."
        case .xhigh: "Extended reasoning for complex plans and debugging."
        case .max: "The largest available reasoning budget."
        }
    }
}

@MainActor
@Observable
final class AgentRunPreferenceStore {
    static let shared = AgentRunPreferenceStore()

    static let effortKey = "novaforge.agent.reasoning-effort.v1"
    static let orchestrationKey = "novaforge.agent.orchestration-mode.v1"

    var reasoningEffort: ProviderReasoningEffort {
        didSet { defaults.set(reasoningEffort.rawValue, forKey: Self.effortKey) }
    }
    var orchestrationMode: AgentOrchestrationMode {
        didSet { defaults.set(orchestrationMode.rawValue, forKey: Self.orchestrationKey) }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedEffort = ProviderReasoningEffort(
            rawValue: defaults.string(forKey: Self.effortKey) ?? ""
        ) ?? .medium
        let storedMode = AgentOrchestrationMode(
            rawValue: defaults.string(forKey: Self.orchestrationKey) ?? ""
        ) ?? .standard
        if storedMode == .ultra {
            reasoningEffort = .xhigh
            orchestrationMode = .standard
            defaults.set(
                ProviderReasoningEffort.xhigh.rawValue,
                forKey: Self.effortKey
            )
            defaults.set(
                AgentOrchestrationMode.standard.rawValue,
                forKey: Self.orchestrationKey
            )
        } else {
            reasoningEffort = storedEffort
            orchestrationMode = storedMode
        }
    }

    func effectiveReasoningEffort(
        provider: AIProvider,
        modelID: String,
        catalog: ProviderModelCatalogStore = .shared
    ) -> ProviderReasoningEffort? {
        guard provider == .openAICodex else { return nil }
        let desired: ProviderReasoningEffort = orchestrationMode == .standard
            ? reasoningEffort : .max
        let supported = catalog.supportedReasoningEfforts(
            provider: provider,
            modelID: modelID
        )
        guard !supported.isEmpty else { return desired }
        if supported.contains(desired) { return desired }
        return supported.filter { $0 <= desired }.last ?? supported.first
    }
}

enum OpenAICodexAuthState: Equatable, Sendable {
    case signedOut
    case requestingCode
    case awaitingApproval(code: String, expiresAt: Date)
    case exchanging
    case signedIn(accountID: String?)
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .requestingCode, .awaitingApproval, .exchanging: true
        case .signedOut, .signedIn, .failed: false
        }
    }
}

private enum OpenAICodexAuthLifecycleError: Error, Sendable {
    case rejectedAccessToken
}

/// Injectable edges around the ChatGPT device-auth lifecycle. Production uses
/// the real OAuth client and Keychain, while unit tests can deterministically
/// suspend individual stages without making network or Security.framework
/// calls.
@MainActor
struct OpenAICodexAuthDependencies {
    var readCredential: @MainActor (String) throws -> String?
    var saveCredential: @MainActor (String, String) throws -> Void
    var deleteCredential: @MainActor (String) throws -> Void
    var requestDeviceCode:
        @MainActor () async throws -> OpenAICodexDeviceCode
    var waitForApproval: @MainActor (
        OpenAICodexDeviceCode
    ) async throws -> OpenAICodexApprovalExchange
    var exchange: @MainActor (
        OpenAICodexApprovalExchange
    ) async throws -> OpenAICodexOAuthTokens
    var refresh:
        @MainActor (String) async throws -> OpenAICodexOAuthTokens
    var copyUserCode: @MainActor (String) -> Void
    var clearModelCatalog: @MainActor () -> Void
    var now: @MainActor () -> Date

    static var live: Self {
        let keychain = KeychainStore()
        return Self(
            readCredential: { try keychain.read($0) },
            saveCredential: { value, account in
                try keychain.save(value, account: account)
            },
            deleteCredential: { try keychain.delete($0) },
            requestDeviceCode: {
                try await OpenAICodexOAuthClient.requestDeviceCode()
            },
            waitForApproval: {
                try await OpenAICodexOAuthClient.waitForApproval($0)
            },
            exchange: {
                try await OpenAICodexOAuthClient.exchange($0)
            },
            refresh: {
                try await OpenAICodexOAuthClient.refresh(refreshToken: $0)
            },
            copyUserCode: { UIPasteboard.general.string = $0 },
            clearModelCatalog: {
                ProviderModelCatalogStore.shared.clear(provider: .openAICodex)
            },
            now: Date.init
        )
    }
}

@MainActor
@Observable
final class OpenAICodexAuthManager {
    static let shared = OpenAICodexAuthManager()

    // These are immutable Keychain identifiers, not actor-owned state. They
    // are also needed by the nonisolated production composition path that
    // resolves a run before handing UI state back to the main actor.
    nonisolated static let accessTokenAccount =
        "oauth_openai_codex_access_token"
    nonisolated static let refreshTokenAccount =
        "oauth_openai_codex_refresh_token"
    nonisolated static let idTokenAccount = "oauth_openai_codex_id_token"
    nonisolated static let accountIDAccount = "oauth_openai_codex_account_id"
    private static let authenticationFailureMessage =
        "ChatGPT rejected this session. Sign in again before retrying."
    static let verificationURL: URL = {
        var components = URLComponents(
            string: "https://auth.openai.com/codex/device"
        )!
        // Force a fresh credential entry. The cached-account chooser can
        // become inert in mobile Safari; prompt=login is forwarded by the
        // device route and avoids trapping the user on that stale page.
        components.queryItems = [
            URLQueryItem(name: "prompt", value: "login"),
            URLQueryItem(name: "max_age", value: "0"),
        ]
        return components.url!
    }()

    private(set) var state: OpenAICodexAuthState = .signedOut
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var operationGeneration: UInt64 = 0
    @ObservationIgnored private var activeOperationID: UInt64?
    @ObservationIgnored private var readyAccessTokenDigest: Data?
    @ObservationIgnored private var rejectedAccessTokenDigest: Data?
    @ObservationIgnored private let dependencies: OpenAICodexAuthDependencies
    #if DEBUG || targetEnvironment(simulator)
    @ObservationIgnored private var deviceCodeFixtureActive = false
    #endif

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var userCode: String? {
        guard case let .awaitingApproval(code, _) = state else { return nil }
        return code
    }

    init(
        dependencies: OpenAICodexAuthDependencies = .live,
        refreshStoredStatusOnInit: Bool = true
    ) {
        self.dependencies = dependencies
        if refreshStoredStatusOnInit {
            refreshStoredStatus()
        }
    }

    deinit {
        loginTask?.cancel()
    }

    func refreshStoredStatus() {
        #if DEBUG || targetEnvironment(simulator)
        guard !deviceCodeFixtureActive else { return }
        #endif
        // A live device-login or token-refresh operation owns the state until
        // it finishes. Re-reading storage mid-operation could otherwise make
        // a foreground notification overwrite its progress.
        guard activeOperationID == nil else { return }
        guard let accessToken = try? dependencies.readCredential(
            Self.accessTokenAccount
        ),
              !accessToken.isEmpty
        else {
            readyAccessTokenDigest = nil
            state = .signedOut
            return
        }
        let accessTokenDigest = Self.credentialDigest(accessToken)
        if rejectedAccessTokenDigest == accessTokenDigest {
            readyAccessTokenDigest = nil
            try? dependencies.deleteCredential(Self.accessTokenAccount)
            state = .failed(Self.authenticationFailureMessage)
            return
        }
        let claims = Self.jwtClaims(accessToken)
        if let expiration = claims.expiration,
           expiration <= dependencies.now().addingTimeInterval(90)
        {
            readyAccessTokenDigest = nil
            if let refreshToken = try? dependencies.readCredential(
                Self.refreshTokenAccount
            ), !refreshToken.isEmpty {
                refresh(refreshToken: refreshToken)
            } else {
                // An expired access token is not a usable credential. Keeping
                // it in Keychain is harmless, but presenting it as connected
                // lets the composer start a run that can only receive a 401.
                state = .signedOut
            }
            return
        }
        let idToken = try? dependencies.readCredential(Self.idTokenAccount)
        let savedAccountID = try? dependencies.readCredential(
            Self.accountIDAccount
        )
        readyAccessTokenDigest = accessTokenDigest
        state = .signedIn(
            accountID: idToken.flatMap { Self.jwtClaims($0).accountID }
                ?? claims.accountID
                ?? savedAccountID
                ?? nil
        )
    }

    /// Called when Safari hands the foreground back to NovaForge. A live
    /// login task resumes its foreground-aware poll by itself; an interrupted
    /// attempt re-reads the Keychain so a successfully committed token can
    /// recover without asking the user to authorize a second time.
    func applicationDidBecomeActive() {
        // Do not let a foreground notification erase a device code that the
        // user still needs to enter. A live attempt normally owns loginTask,
        // while previews and UI-test fixtures intentionally model the same
        // awaiting-approval state without a polling task.
        guard loginTask == nil, !state.isWorking else { return }
        refreshStoredStatus()
    }

    /// Revalidates the saved subscription credential immediately before an
    /// agent run. If the access token is near expiry, this waits for the
    /// bounded refresh already owned by this manager instead of allowing the
    /// provider transport to race it with a stale bearer token.
    func prepareCredentialForRun() async -> Bool {
        #if DEBUG || targetEnvironment(simulator)
        guard !deviceCodeFixtureActive else { return false }
        #endif
        if state.isWorking {
            guard case .exchanging = state, let loginTask else {
                return false
            }
            await loginTask.value
            return isSignedIn
        }

        refreshStoredStatus()
        if case .exchanging = state, let loginTask {
            await loginTask.value
        }
        return isSignedIn
    }

    func startLogin() {
        #if DEBUG || targetEnvironment(simulator)
        deviceCodeFixtureActive = false
        #endif
        let operationID = beginOperation()
        // An explicit retry is always a new device-login operation. In
        // particular, do not call refreshStoredStatus() from `.failed`: that
        // method may start a token refresh which the device-login task would
        // immediately replace, allowing both operations to persist.
        dependencies.clearModelCatalog()
        readyAccessTokenDigest = nil
        state = .requestingCode
        loginTask = Task { [weak self] in
            await self?.performDeviceLogin(operationID: operationID)
        }
    }

    func openVerificationPage() {
        if let userCode {
            dependencies.copyUserCode(userCode)
        }
        // Device authorization has no callback. Full Safari avoids the inert
        // cached-account chooser seen in the embedded authentication sheet.
        UIApplication.shared.open(Self.verificationURL)
    }

    func cancelLogin() {
        #if DEBUG || targetEnvironment(simulator)
        deviceCodeFixtureActive = false
        #endif
        invalidateActiveOperation()
        if !isSignedIn { state = .signedOut }
    }

    func signOut() {
        cancelLogin()
        try? dependencies.deleteCredential(Self.accessTokenAccount)
        try? dependencies.deleteCredential(Self.refreshTokenAccount)
        try? dependencies.deleteCredential(Self.idTokenAccount)
        try? dependencies.deleteCredential(Self.accountIDAccount)
        dependencies.clearModelCatalog()
        readyAccessTokenDigest = nil
        rejectedAccessTokenDigest = nil
        state = .signedOut
    }

    /// A provider request received an HTTP 401 for the currently usable
    /// ChatGPT session. Remove the access-token commit marker and immediately
    /// make the composer treat the session as unavailable. This deliberately
    /// does not replay the failed request; the user can start a fresh login,
    /// and a later run is a new, bounded operation.
    func invalidateAfterAuthenticationFailure(
        rejectedAccessToken: String
    ) {
        // Bind the callback to the exact credential that received the 401. A
        // late response from an older in-flight request must never delete a
        // token committed by a newer login. The token is compared only in
        // memory and is never interpolated into state, logs, or errors.
        let rejectedDigest = Self.credentialDigest(rejectedAccessToken)
        let shouldDeleteStoredToken: Bool
        do {
            let storedAccessToken = try dependencies.readCredential(
                Self.accessTokenAccount
            )
            if let storedAccessToken {
                guard storedAccessToken == rejectedAccessToken else { return }
                shouldDeleteStoredToken = true
            } else {
                guard readyAccessTokenDigest == rejectedDigest else { return }
                shouldDeleteStoredToken = false
            }
        } catch {
            // Fail closed for the in-memory ready credential, but never issue
            // a blind delete when Keychain could not prove which token is now
            // stored. A newer login may already have replaced it.
            guard readyAccessTokenDigest == rejectedDigest else { return }
            shouldDeleteStoredToken = false
        }
        rejectedAccessTokenDigest = rejectedDigest
        readyAccessTokenDigest = nil
        if shouldDeleteStoredToken {
            try? dependencies.deleteCredential(Self.accessTokenAccount)
        }
        dependencies.clearModelCatalog()
        // If a new login or bounded refresh is already active, leave its state
        // and operation identity untouched. It can commit a replacement token
        // normally; failure already transitions that operation to `.failed`.
        if activeOperationID == nil {
            state = .failed(Self.authenticationFailureMessage)
        }
    }

    #if DEBUG || targetEnvironment(simulator)
    func installDeviceCodeFixture(_ code: String) {
        invalidateActiveOperation()
        deviceCodeFixtureActive = true
        state = .awaitingApproval(
            code: code,
            expiresAt: dependencies.now().addingTimeInterval(15 * 60)
        )
        dependencies.copyUserCode(code)
    }
    #endif

    private func refresh(refreshToken: String) {
        guard activeOperationID == nil else { return }
        let operationID = beginOperation()
        state = .exchanging
        loginTask = Task { [weak self] in
            await self?.performRefresh(
                refreshToken: refreshToken,
                operationID: operationID
            )
        }
    }

    private func performDeviceLogin(operationID: UInt64) async {
        do {
            let code = try await dependencies.requestDeviceCode()
            try requireCurrentOperation(operationID)
            state = .awaitingApproval(
                code: code.userCode,
                expiresAt: dependencies.now().addingTimeInterval(15 * 60)
            )
            // The browser covers NovaForge on iPhone, so make the code
            // available before the user chooses to leave this screen.
            dependencies.copyUserCode(code.userCode)
            let exchange = try await dependencies.waitForApproval(code)
            try requireCurrentOperation(operationID)
            state = .exchanging
            let tokens = try await dependencies.exchange(exchange)
            try requireCurrentOperation(operationID)
            try persist(tokens, operationID: operationID)
            try requireCurrentOperation(operationID)
            state = .signedIn(accountID: Self.accountID(in: tokens))
        } catch is CancellationError {
            if isCurrentOperation(operationID), !isSignedIn {
                state = .signedOut
            }
        } catch {
            if isCurrentOperation(operationID) {
                state = .failed(Self.safeMessage(error))
            }
        }
        finishOperation(operationID)
    }

    private func performRefresh(
        refreshToken: String,
        operationID: UInt64
    ) async {
        do {
            let tokens = try await dependencies.refresh(refreshToken)
            try requireCurrentOperation(operationID)
            try persist(tokens, operationID: operationID)
            try requireCurrentOperation(operationID)
            state = .signedIn(accountID: Self.accountID(in: tokens))
        } catch is CancellationError {
            if isCurrentOperation(operationID), !isSignedIn {
                state = .signedOut
            }
        } catch {
            if isCurrentOperation(operationID) {
                state = .failed(Self.safeMessage(error))
            }
        }
        finishOperation(operationID)
    }

    private func persist(
        _ tokens: OpenAICodexOAuthTokens,
        operationID: UInt64
    ) throws {
        try requireCurrentOperation(operationID)
        let accessTokenDigest = Self.credentialDigest(tokens.accessToken)
        guard rejectedAccessTokenDigest != accessTokenDigest else {
            throw OpenAICodexAuthLifecycleError.rejectedAccessToken
        }
        // Supporting values are written first and the access token is the
        // commit marker. This prevents a refresh/account write failure from
        // leaving a newly issued access token looking like a completed login.
        if let idToken = tokens.idToken, !idToken.isEmpty {
            try dependencies.saveCredential(idToken, Self.idTokenAccount)
        }
        if let refreshToken = tokens.refreshToken, !refreshToken.isEmpty {
            try dependencies.saveCredential(
                refreshToken,
                Self.refreshTokenAccount
            )
        }
        if let accountID = Self.accountID(in: tokens),
           !accountID.isEmpty
        {
            try dependencies.saveCredential(accountID, Self.accountIDAccount)
        }
        try dependencies.saveCredential(
            tokens.accessToken,
            Self.accessTokenAccount
        )
        guard try dependencies.readCredential(Self.accessTokenAccount)
            == tokens.accessToken
        else { throw KeychainError.invalidValue }
        readyAccessTokenDigest = accessTokenDigest
        rejectedAccessTokenDigest = nil
    }

    private func beginOperation() -> UInt64 {
        let previousTask = loginTask
        operationGeneration &+= 1
        let operationID = operationGeneration
        activeOperationID = operationID
        loginTask = nil
        previousTask?.cancel()
        return operationID
    }

    private func invalidateActiveOperation() {
        let previousTask = loginTask
        operationGeneration &+= 1
        activeOperationID = nil
        loginTask = nil
        previousTask?.cancel()
    }

    private func isCurrentOperation(_ operationID: UInt64) -> Bool {
        activeOperationID == operationID
    }

    private func requireCurrentOperation(_ operationID: UInt64) throws {
        try Task.checkCancellation()
        guard isCurrentOperation(operationID) else {
            throw CancellationError()
        }
    }

    private func finishOperation(_ operationID: UInt64) {
        guard isCurrentOperation(operationID) else { return }
        activeOperationID = nil
        loginTask = nil
    }

    private static func accountID(
        in tokens: OpenAICodexOAuthTokens
    ) -> String? {
        tokens.idToken.flatMap { jwtClaims($0).accountID }
            ?? jwtClaims(tokens.accessToken).accountID
    }

    private static func credentialDigest(_ credential: String) -> Data {
        Data(SHA256.hash(data: Data(credential.utf8)))
    }

    private static func jwtClaims(
        _ token: String
    ) -> (accountID: String?, expiration: Date?) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return (nil, nil) }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return (nil, nil) }
        let auth = object["https://api.openai.com/auth"] as? [String: Any]
        let accountID = auth?["chatgpt_account_id"] as? String
        let expiration = (object["exp"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return (accountID, expiration)
    }

    private static func safeMessage(_ error: any Error) -> String {
        if error is OpenAICodexAuthLifecycleError {
            return authenticationFailureMessage
        }
        if let error = error as? OpenAICodexOAuthError {
            return error.errorDescription ?? "ChatGPT sign-in failed."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .timedOut, .internationalRoamingOff, .dataNotAllowed:
                return "The connection changed while returning from ChatGPT. Keep NovaForge open and try once more."
            default:
                break
            }
        }
        if error is KeychainError {
            return "ChatGPT approved the sign-in, but iOS could not save it securely. Keep the iPhone unlocked and try once more."
        }
        return "ChatGPT sign-in could not finish. Try again."
    }
}

struct OpenAICodexDeviceCode: Sendable {
    let userCode: String
    let deviceAuthID: String
    let interval: Duration
}

struct OpenAICodexApprovalExchange: Sendable {
    let authorizationCode: String
    let codeVerifier: String
    let codeChallenge: String
}

struct OpenAICodexOAuthTokens: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
}

private enum OpenAICodexOAuthError: LocalizedError, Sendable {
    case invalidResponse
    case rateLimited
    case timedOut
    case authorizationFailed
    case serviceRejected(stage: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "OpenAI returned an invalid sign-in response."
        case .rateLimited:
            "OpenAI is temporarily limiting sign-ins. Wait a minute and try again."
        case .timedOut:
            "The sign-in code expired. Start a new sign-in."
        case .authorizationFailed:
            "ChatGPT did not approve this sign-in. Try again."
        case let .serviceRejected(stage, status):
            "OpenAI could not finish \(stage) (HTTP \(status)). Try again in a moment."
        }
    }
}

/// Pure validation for OpenAI's device-auth payloads. Keeping wire parsing
/// separate from URLSession makes response-shape regressions fast to test and
/// keeps them distinct from browser handoff or connectivity failures.
enum OpenAICodexOAuthWire {
    static func deviceCode(from data: Data) throws -> OpenAICodexDeviceCode {
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              let userCode = object["user_code"] as? String
                ?? object["usercode"] as? String,
              let deviceAuthID = object["device_auth_id"] as? String,
              isSafeToken(userCode, maximumBytes: 128),
              isSafeToken(deviceAuthID, maximumBytes: 1_024)
        else { throw OpenAICodexOAuthError.invalidResponse }
        let intervalSeconds: Int
        if let number = object["interval"] as? NSNumber {
            intervalSeconds = number.intValue
        } else if let text = object["interval"] as? String {
            intervalSeconds = Int(text) ?? 5
        } else {
            intervalSeconds = 5
        }
        return OpenAICodexDeviceCode(
            userCode: userCode,
            deviceAuthID: deviceAuthID,
            interval: .seconds(max(3, min(intervalSeconds, 30)))
        )
    }

    static func approvalExchange(
        from data: Data
    ) throws -> OpenAICodexApprovalExchange {
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              let authorizationCode = object["authorization_code"] as? String,
              let codeVerifier = object["code_verifier"] as? String,
              let codeChallenge = object["code_challenge"] as? String,
              isSafeToken(authorizationCode, maximumBytes: 4_096),
              isSafeToken(codeVerifier, maximumBytes: 1_024),
              isSafeToken(codeChallenge, maximumBytes: 1_024)
        else { throw OpenAICodexOAuthError.authorizationFailed }
        return OpenAICodexApprovalExchange(
            authorizationCode: authorizationCode,
            codeVerifier: codeVerifier,
            codeChallenge: codeChallenge
        )
    }

    static func tokens(from data: Data) throws -> OpenAICodexOAuthTokens {
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              let accessToken = object["access_token"] as? String,
              isSafeToken(
                accessToken,
                maximumBytes: KeychainStore.maximumSecretBytes
              )
        else { throw OpenAICodexOAuthError.invalidResponse }
        let refreshToken = object["refresh_token"] as? String
        let idToken = object["id_token"] as? String
        if let refreshToken,
           !isSafeToken(
            refreshToken,
            maximumBytes: KeychainStore.maximumSecretBytes
           )
        {
            throw OpenAICodexOAuthError.invalidResponse
        }
        if let idToken,
           !isSafeToken(
            idToken,
            maximumBytes: KeychainStore.maximumSecretBytes
           )
        {
            throw OpenAICodexOAuthError.invalidResponse
        }
        return OpenAICodexOAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken
        )
    }

    private static func isSafeToken(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes &&
            value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) &&
                    !CharacterSet.newlines.contains($0)
            }
    }
}

@MainActor
private enum OpenAICodexOAuthClient {
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let issuer = URL(string: "https://auth.openai.com")!
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()

    static func requestDeviceCode() async throws -> OpenAICodexDeviceCode {
        let body = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
        ])
        let (data, response) = try await request(
            path: "/api/accounts/deviceauth/usercode",
            contentType: "application/json",
            body: body
        )
        if response.statusCode == 429 { throw OpenAICodexOAuthError.rateLimited }
        guard response.statusCode == 200 else {
            throw OpenAICodexOAuthError.serviceRejected(
                stage: "ChatGPT sign-in setup",
                status: response.statusCode
            )
        }
        return try OpenAICodexOAuthWire.deviceCode(from: data)
    }

    static func waitForApproval(
        _ code: OpenAICodexDeviceCode
    ) async throws -> OpenAICodexApprovalExchange {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15 * 60))
        while clock.now < deadline {
            try Task.checkCancellation()
            if UIApplication.shared.applicationState != .active {
                // Opening the verification page moves NovaForge to the
                // background. Avoid starting an ephemeral foreground request
                // that iOS will suspend halfway through; it resumes instantly
                // when the user returns from Safari.
                try await Task.sleep(for: .milliseconds(250))
                continue
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": code.deviceAuthID,
                "user_code": code.userCode,
            ])
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await request(
                    path: "/api/accounts/deviceauth/token",
                    contentType: "application/json",
                    body: body
                )
            } catch let error as URLError where isRetryableTransport(error) {
                try await Task.sleep(for: code.interval)
                continue
            }
            if response.statusCode == 403 || response.statusCode == 404 {
                try await Task.sleep(for: code.interval)
                continue
            }
            if response.statusCode == 429 {
                throw OpenAICodexOAuthError.rateLimited
            }
            guard response.statusCode == 200 else {
                throw OpenAICodexOAuthError.serviceRejected(
                    stage: "ChatGPT approval",
                    status: response.statusCode
                )
            }
            return try OpenAICodexOAuthWire.approvalExchange(from: data)
        }
        throw OpenAICodexOAuthError.timedOut
    }

    static func exchange(
        _ exchange: OpenAICodexApprovalExchange
    ) async throws -> OpenAICodexOAuthTokens {
        try await waitUntilApplicationIsActive()
        return try await tokenRequest([
            "grant_type": "authorization_code",
            "code": exchange.authorizationCode,
            "redirect_uri": "https://auth.openai.com/deviceauth/callback",
            "client_id": clientID,
            "code_verifier": exchange.codeVerifier,
        ])
    }

    static func refresh(
        refreshToken: String
    ) async throws -> OpenAICodexOAuthTokens {
        return try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    private static func tokenRequest(
        _ form: [String: String]
    ) async throws -> OpenAICodexOAuthTokens {
        let body = form.sorted { $0.key < $1.key }.map { key, value in
            Self.formEncode(key) + "=" + Self.formEncode(value)
        }.joined(separator: "&").data(using: .utf8) ?? Data()
        let (data, response) = try await request(
            path: "/oauth/token",
            contentType: "application/x-www-form-urlencoded",
            body: body
        )
        if response.statusCode == 429 { throw OpenAICodexOAuthError.rateLimited }
        guard response.statusCode == 200 else {
            throw OpenAICodexOAuthError.serviceRejected(
                stage: "ChatGPT token exchange",
                status: response.statusCode
            )
        }
        return try OpenAICodexOAuthWire.tokens(from: data)
    }

    private static func request(
        path: String,
        contentType: String,
        body: Data
    ) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: issuer)?.absoluteURL,
              url.scheme == "https", url.host == "auth.openai.com",
              url.user == nil, url.password == nil, url.query == nil,
              url.fragment == nil
        else { throw OpenAICodexOAuthError.invalidResponse }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 25
        )
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, rawResponse) = try await session.data(for: request)
        guard data.count <= 128 * 1_024,
              let response = rawResponse as? HTTPURLResponse,
              response.url?.scheme == "https",
              response.url?.host == "auth.openai.com"
        else { throw OpenAICodexOAuthError.invalidResponse }
        return (data, response)
    }

    private static func waitUntilApplicationIsActive() async throws {
        while UIApplication.shared.applicationState != .active {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func isRetryableTransport(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
             .networkConnectionLost, .dnsLookupFailed,
             .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed:
            true
        case .cancelled:
            false
        default:
            false
        }
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

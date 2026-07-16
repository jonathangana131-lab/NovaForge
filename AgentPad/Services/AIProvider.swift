import AgentProviders
import Foundation
import Observation
import SwiftUI
import UIKit

enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
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

    var supportsAgentRuntime: Bool {
        Self.agentRuntimeProviders.contains(self)
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
            nil
        case .openAI:
            URL(string: "https://api.openai.com/v1/models")
        case .openAICodex:
            URL(string: "https://chatgpt.com/backend-api/codex/models")
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
            LocalModelCatalog.all.map(\.id)
        case .openAI:
            [
                "gpt-5.5",
                "gpt-5.4",
                "gpt-5.4-mini",
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
                "gpt-5.6-sol",
                "gpt-5.6",
                "gpt-5.6-terra",
                "gpt-5.6-luna",
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
        entriesByProvider[provider]
            ?? provider.modelOptions.map { ProviderModelCatalogEntry(id: $0) }
    }

    func models(for provider: AIProvider) -> [String] {
        entries(for: provider).map(\.id)
    }

    func supportedReasoningEfforts(
        provider: AIProvider,
        modelID: String
    ) -> [ProviderReasoningEffort] {
        entries(for: provider).first(where: { $0.id == modelID })?
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
            let allowed = Set(provider.modelOptions)
            let compatible = loaded.filter { allowed.contains($0.id) }
            guard !compatible.isEmpty else {
                errorsByProvider[provider] = "No currently supported NovaForge agent model was returned."
                return
            }
            entriesByProvider[provider] = compatible
        } catch is CancellationError {
            return
        } catch {
            errorsByProvider[provider] = "Could not refresh the live \(provider.displayName) model catalog."
        }
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
        reasoningEffort = ProviderReasoningEffort(
            rawValue: defaults.string(forKey: Self.effortKey) ?? ""
        ) ?? .medium
        orchestrationMode = AgentOrchestrationMode(
            rawValue: defaults.string(forKey: Self.orchestrationKey) ?? ""
        ) ?? .standard
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

@MainActor
@Observable
final class OpenAICodexAuthManager {
    static let shared = OpenAICodexAuthManager()

    static let accessTokenAccount = "oauth_openai_codex_access_token"
    static let refreshTokenAccount = "oauth_openai_codex_refresh_token"
    static let accountIDAccount = "oauth_openai_codex_account_id"
    static let verificationURL = URL(
        string: "https://auth.openai.com/codex/device"
    )!

    private(set) var state: OpenAICodexAuthState = .signedOut
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private let keychain = KeychainStore()

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var userCode: String? {
        guard case let .awaitingApproval(code, _) = state else { return nil }
        return code
    }

    private init() {
        refreshStoredStatus()
    }

    deinit {
        loginTask?.cancel()
    }

    func refreshStoredStatus() {
        guard let accessToken = try? keychain.read(Self.accessTokenAccount),
              !accessToken.isEmpty
        else {
            state = .signedOut
            return
        }
        let claims = Self.jwtClaims(accessToken)
        if let expiration = claims.expiration,
           expiration <= Date().addingTimeInterval(90),
           let refreshToken = try? keychain.read(Self.refreshTokenAccount),
           !refreshToken.isEmpty
        {
            refresh(refreshToken: refreshToken)
            return
        }
        let savedAccountID = try? keychain.read(Self.accountIDAccount)
        state = .signedIn(accountID: claims.accountID ?? savedAccountID ?? nil)
    }

    func startLogin() {
        loginTask?.cancel()
        state = .requestingCode
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let code = try await OpenAICodexOAuthClient.requestDeviceCode()
                try Task.checkCancellation()
                state = .awaitingApproval(
                    code: code.userCode,
                    expiresAt: Date().addingTimeInterval(15 * 60)
                )
                await UIApplication.shared.open(Self.verificationURL)
                let exchange = try await OpenAICodexOAuthClient
                    .waitForApproval(code)
                try Task.checkCancellation()
                state = .exchanging
                let tokens = try await OpenAICodexOAuthClient
                    .exchange(exchange)
                try persist(tokens)
                state = .signedIn(
                    accountID: Self.jwtClaims(tokens.accessToken).accountID
                )
            } catch is CancellationError {
                if !isSignedIn { state = .signedOut }
            } catch {
                state = .failed(Self.safeMessage(error))
            }
            loginTask = nil
        }
    }

    func openVerificationPage() {
        UIApplication.shared.open(Self.verificationURL)
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        if !isSignedIn { state = .signedOut }
    }

    func signOut() {
        cancelLogin()
        try? keychain.delete(Self.accessTokenAccount)
        try? keychain.delete(Self.refreshTokenAccount)
        try? keychain.delete(Self.accountIDAccount)
        state = .signedOut
    }

    private func refresh(refreshToken: String) {
        guard loginTask == nil else { return }
        state = .exchanging
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tokens = try await OpenAICodexOAuthClient.refresh(
                    refreshToken: refreshToken
                )
                try persist(tokens)
                state = .signedIn(
                    accountID: Self.jwtClaims(tokens.accessToken).accountID
                )
            } catch {
                state = .failed(Self.safeMessage(error))
            }
            loginTask = nil
        }
    }

    private func persist(_ tokens: OpenAICodexOAuthTokens) throws {
        try keychain.save(tokens.accessToken, account: Self.accessTokenAccount)
        if let refreshToken = tokens.refreshToken, !refreshToken.isEmpty {
            try keychain.save(
                refreshToken,
                account: Self.refreshTokenAccount
            )
        }
        if let accountID = Self.jwtClaims(tokens.accessToken).accountID,
           !accountID.isEmpty
        {
            try keychain.save(accountID, account: Self.accountIDAccount)
        }
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
        if let error = error as? OpenAICodexOAuthError {
            return error.errorDescription ?? "ChatGPT sign-in failed."
        }
        return "ChatGPT sign-in could not finish. Try again."
    }
}

private struct OpenAICodexDeviceCode: Sendable {
    let userCode: String
    let deviceAuthID: String
    let interval: Duration
}

private struct OpenAICodexApprovalExchange: Sendable {
    let authorizationCode: String
    let codeVerifier: String
}

private struct OpenAICodexOAuthTokens: Sendable {
    let accessToken: String
    let refreshToken: String?
}

private enum OpenAICodexOAuthError: LocalizedError, Sendable {
    case invalidResponse
    case rateLimited
    case timedOut
    case authorizationFailed

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
        }
    }
}

private enum OpenAICodexOAuthClient {
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let issuer = URL(string: "https://auth.openai.com")!

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
        guard response.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let userCode = object["user_code"] as? String,
              let deviceAuthID = object["device_auth_id"] as? String,
              Self.isSafeToken(userCode, maximumBytes: 128),
              Self.isSafeToken(deviceAuthID, maximumBytes: 1_024)
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

    static func waitForApproval(
        _ code: OpenAICodexDeviceCode
    ) async throws -> OpenAICodexApprovalExchange {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15 * 60))
        while clock.now < deadline {
            try await Task.sleep(for: code.interval)
            try Task.checkCancellation()
            let body = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": code.deviceAuthID,
                "user_code": code.userCode,
            ])
            let (data, response) = try await request(
                path: "/api/accounts/deviceauth/token",
                contentType: "application/json",
                body: body
            )
            if response.statusCode == 403 || response.statusCode == 404 {
                continue
            }
            if response.statusCode == 429 {
                throw OpenAICodexOAuthError.rateLimited
            }
            guard response.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let authorizationCode = object["authorization_code"]
                    as? String,
                  let codeVerifier = object["code_verifier"] as? String,
                  isSafeToken(authorizationCode, maximumBytes: 4_096),
                  isSafeToken(codeVerifier, maximumBytes: 1_024)
            else { throw OpenAICodexOAuthError.authorizationFailed }
            return OpenAICodexApprovalExchange(
                authorizationCode: authorizationCode,
                codeVerifier: codeVerifier
            )
        }
        throw OpenAICodexOAuthError.timedOut
    }

    static func exchange(
        _ exchange: OpenAICodexApprovalExchange
    ) async throws -> OpenAICodexOAuthTokens {
        try await tokenRequest([
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
        try await tokenRequest([
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
        guard response.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let accessToken = object["access_token"] as? String,
              isSafeToken(accessToken, maximumBytes: 4_096)
        else { throw OpenAICodexOAuthError.authorizationFailed }
        let refreshToken = object["refresh_token"] as? String
        if let refreshToken,
           !isSafeToken(refreshToken, maximumBytes: 4_096)
        {
            throw OpenAICodexOAuthError.invalidResponse
        }
        return OpenAICodexOAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken
        )
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NovaForge/1.0 iOS", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, rawResponse) = try await session.data(for: request)
        guard data.count <= 128 * 1_024,
              let response = rawResponse as? HTTPURLResponse,
              response.url == url
        else { throw OpenAICodexOAuthError.invalidResponse }
        return (data, response)
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

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, content: str) -> None:
    (ROOT / path).write_text(content, encoding="utf-8")


def replace_once(path: str, old: str, new: str) -> None:
    content = read(path)
    count = content.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected exactly one match, found {count}: {old[:100]!r}")
    write(path, content.replace(old, new, 1))


AI_PROVIDER = "AgentPad/Services/AIProvider.swift"
MODELS = "AgentPad/Models/Models.swift"
FAILURES = "Packages/AgentHarnessKit/Sources/AgentProviders/ProviderFailures.swift"
APP_TESTS = "AgentPadTests/AgentSystemFreshRunRequestFactoryTests.swift"
PROVIDER_TESTS = "Packages/AgentHarnessKit/Tests/AgentProviderContractTests/ProviderAdapterContractTests.swift"

# Keep the legacy ChatGPT/Codex route available for durable recovery and its
# existing contract tests, but stop presenting a private backend as a normal
# phone provider. Fresh user choices are public API routes plus on-device AI.
replace_once(
    AI_PROVIDER,
    '''    static let agentRuntimeProviders: [AIProvider] = [
        .openCodeZen, .local, .openAICodex, .openAI,
    ]

    var supportsAgentRuntime: Bool {
        Self.agentRuntimeProviders.contains(self)
    }
''',
    '''    static let agentRuntimeProviders: [AIProvider] = [
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
'''
)

# Remove speculative/future OpenAI IDs from the public Chat Completions picker.
# The first selection is a documented stable alias; /v1/models narrows this
# list further for the exact API key before the user selects a model.
replace_once(
    AI_PROVIDER,
    '''        case .openAI:
            [
                Self.exactGPT56SolModelID,
                Self.exactGPT56TerraModelID,
                Self.exactGPT56LunaModelID,
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
''',
    '''        case .openAI:
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
'''
)

# Keep the anonymous free fallback current so NovaForge has a no-key route on
# a fresh phone even when OpenAI API billing/model access is unavailable.
replace_once(
    AI_PROVIDER,
    '''            [
                "mimo-v2.5-free",
                "north-mini-code-free",
''',
    '''            [
                "mimo-v2.5-free",
                "laguna-s-2.1-free",
                "ling-3.0-flash-free",
                "north-mini-code-free",
'''
)

# GPT-5.6 provenance pinning belongs only to the legacy private Codex route.
# A stale public-API GPT-5.6 selection must repair to a verified public model
# instead of remaining selected and producing another 4xx response.
replace_once(
    AI_PROVIDER,
    '''        guard self == .openAI || self == .openAICodex else { return false }
''',
    '''        guard self == .openAICodex else { return false }
'''
)

# Preserve the app-owned preference order while intersecting it with the
# provider's live /models response. This also prevents a provider-controlled
# ordering change from silently changing NovaForge's default selection.
replace_once(
    AI_PROVIDER,
    '''            let allowed = Set(provider.modelOptions)
            let compatible = loaded.filter { allowed.contains($0.id) }
            guard !compatible.isEmpty else {
                errorsByProvider[provider] = "No currently supported NovaForge agent model was returned."
                return
            }
''',
    '''            let loadedByID = loaded.reduce(
                into: [String: ProviderModelCatalogEntry](),
                { result, entry in result[entry.id] = entry }
            )
            let compatible = provider.modelOptions.compactMap { loadedByID[$0] }
            guard !compatible.isEmpty else {
                errorsByProvider[provider] = "No verified NovaForge model is available for this account. Refresh the catalog or choose Zen Free."
                return
            }
'''
)

# Existing installs that were left on the private ChatGPT route are migrated
# to the working anonymous Zen route during normal launch/settings repair.
replace_once(
    MODELS,
    '''        let selectedProvider = AIProvider(rawValue: providerRawValue ?? "")
            ?? .local
''',
    '''        let decodedProvider = AIProvider(rawValue: providerRawValue ?? "")
        let selectedProvider = decodedProvider.flatMap {
            $0.isUserSelectable ? $0 : nil
        } ?? .openCodeZen
'''
)

# Every provider/model picker must use the public phone list. Fail if the
# expected old symbol was not used anywhere so this migration cannot silently
# become a no-op after a future refactor.
view_replacements = 0
for view_path in (ROOT / "AgentPad/Views").glob("*.swift"):
    content = view_path.read_text(encoding="utf-8")
    count = content.count("AIProvider.agentRuntimeProviders")
    if count:
        content = content.replace(
            "AIProvider.agentRuntimeProviders",
            "AIProvider.userSelectableProviders",
        )
        view_path.write_text(content, encoding="utf-8")
        view_replacements += count
if view_replacements < 1:
    raise RuntimeError("No provider picker used AIProvider.agentRuntimeProviders")

# Make thrown provider failures display their safe public explanation through
# localizedDescription instead of an enum/module error code on iPhone.
replace_once(
    FAILURES,
    '''public struct ProviderFailure: Error, Codable, Equatable, Sendable {
''',
    '''public struct ProviderFailure: LocalizedError, Codable, Equatable, Sendable {
'''
)
replace_once(
    FAILURES,
    '''    public var retryableOnSameRoute: Bool {
''',
    '''    public var errorDescription: String? { publicMessage }

    public var retryableOnSameRoute: Bool {
'''
)
replace_once(
    FAILURES,
    '''            publicMessage: stableCode == "provider_payment_required"
                ? "The provider needs billing or credits to be configured for this model."
                : publicMessage(for: category),
''',
    '''            publicMessage: httpPublicMessage(
                statusCode: statusCode,
                category: category,
                stableCode: stableCode
            ),
'''
)
replace_once(
    FAILURES,
    '''    private static func publicMessage(for category: ProviderFailureCategory) -> String {
''',
    '''    private static func httpPublicMessage(
        statusCode: Int,
        category: ProviderFailureCategory,
        stableCode: String
    ) -> String {
        if stableCode == "provider_context_limit" {
            return "This conversation is too large for the selected model. Start a new chat or use a larger-context model."
        }
        if stableCode == "provider_content_filtered" {
            return "The provider blocked this response. Reword the request and try again."
        }
        switch statusCode {
        case 400, 404, 405, 409, 413, 422:
            return "The selected model or request format is not available on this provider. Refresh models in Control or choose Zen Free."
        case 401:
            return "The saved provider key or login was rejected. Reconnect it in Control, then retry."
        case 402:
            return "This provider needs API billing or credits. Add API credit or choose Zen Free in Control."
        case 403:
            return "This account does not have access to the selected model. Refresh models or choose Zen Free in Control."
        case 408, 504:
            return "The provider took too long to answer. Retry once or choose another model."
        case 429:
            return "The provider is rate limiting this account. Wait a moment or choose Zen Free in Control."
        case 500 ... 599:
            return "The provider is temporarily unavailable. Retry shortly or choose another provider."
        default:
            return publicMessage(for: category)
        }
    }

    private static func publicMessage(for category: ProviderFailureCategory) -> String {
'''
)

# App-level regression coverage for the exact phone failure class: no private
# provider in fresh-run UI, no speculative OpenAI default, and deterministic
# migration of an old ChatGPT/gpt-5.5 selection to a free working route.
replace_once(
    APP_TESTS,
    '''final class AgentSystemFreshRunRequestFactoryTests: XCTestCase {
''',
    '''final class AgentSystemFreshRunRequestFactoryTests: XCTestCase {
    func testPhoneProviderCatalogUsesPublicVerifiedDefaults() {
        XCTAssertEqual(
            AIProvider.userSelectableProviders,
            [.openCodeZen, .local, .openAI]
        )
        XCTAssertFalse(
            AIProvider.userSelectableProviders.contains(.openAICodex)
        )
        XCTAssertEqual(AIProvider.openAI.defaultModel, "gpt-5")
        XCTAssertFalse(AIProvider.openAI.modelOptions.contains("gpt-5.5"))
        XCTAssertTrue(
            AIProvider.openCodeZen.modelOptions.contains("mimo-v2.5-free")
        )
    }

    func testLegacyChatGPTSelectionRepairsToFreeZenOnPhone() {
        let settings = AgentSettings(
            provider: .openAICodex,
            modelID: "gpt-5.5"
        )

        XCTAssertTrue(settings.repairStaleModelSelection())
        XCTAssertEqual(settings.providerRawValue, AIProvider.openCodeZen.rawValue)
        XCTAssertEqual(settings.modelID, AIProvider.openCodeZen.defaultModel)
    }
'''
)

# The public OpenAI reasoning test must follow the new supported list.
replace_once(
    APP_TESTS,
    '''            "o4-mini",
            "gpt-5.5",
            AIProvider.exactGPT56SolModelID,
''',
    '''            "o4-mini",
            "gpt-5",
'''
)

# Package-level proof that any UI path using localizedDescription receives the
# safe actionable message rather than a ProviderFailure error code.
replace_once(
    PROVIDER_TESTS,
    '''final class ProviderAdapterContractTests: XCTestCase {
''',
    '''final class ProviderAdapterContractTests: XCTestCase {
    func testProviderFailuresExposeActionableLocalizedDescriptions() {
        let providerID = ProviderID(rawValue: "fixture-provider")
        let adapterID = ProviderAdapterID(rawValue: "fixture-adapter")

        let unavailableModel = ProviderFailureMapper.httpFailure(
            statusCode: 404,
            providerID: providerID,
            adapterID: adapterID
        )
        XCTAssertEqual(
            unavailableModel.localizedDescription,
            unavailableModel.publicMessage
        )
        XCTAssertTrue(unavailableModel.publicMessage.contains("Zen Free"))

        let rejectedCredential = ProviderFailureMapper.httpFailure(
            statusCode: 401,
            providerID: providerID,
            adapterID: adapterID
        )
        XCTAssertTrue(rejectedCredential.publicMessage.contains("Reconnect"))

        let billing = ProviderFailureMapper.httpFailure(
            statusCode: 402,
            providerID: providerID,
            adapterID: adapterID
        )
        XCTAssertTrue(billing.publicMessage.contains("billing"))
    }
'''
)

print(f"Applied provider reliability changes; updated {view_replacements} provider-picker reference(s).")

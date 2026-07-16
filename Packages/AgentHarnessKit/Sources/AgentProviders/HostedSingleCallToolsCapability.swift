import CryptoKit
import Foundation

/// Frozen route evidence for a package-owned OpenAI adapter that may carry one
/// strict typed tool call at a time. This capability authorizes provider wire
/// shape only. It contains no registry, executor, credential, approval, or
/// mutation authority; the app transport must still bind the exact canonical
/// tool definitions and `AgentEngine` must route effects through policy.
public struct HostedSingleCallToolsRouteSnapshot:
    Codable,
    Equatable,
    Sendable
{
    public let providerID: ProviderID
    public let modelID: ProviderModelID
    public let adapterID: ProviderAdapterID
    public let dialect: ProviderAdapterDialect
    public let requestPath: String
    public let capabilities: ProviderModelCapabilities
    public let deployment: ProviderDeployment
    public let provenance: ProviderRouteProvenance
    public let maximumToolDefinitions: UInt32
    public let maximumToolCallsPerTurn: UInt32
    public let parallelToolDispatchEnabled: Bool
    public let descriptorSHA256: String
}

/// Opaque wire authority minted only by `TrustedHostedProviderCatalog` after
/// revalidating its package-owned route. It cannot be constructed or upgraded
/// from text-only/read-only authority by app code.
public struct HostedSingleCallToolsProviderCapability: Equatable, Sendable {
    public let snapshot: HostedSingleCallToolsRouteSnapshot

    init(snapshot: HostedSingleCallToolsRouteSnapshot) {
        self.snapshot = snapshot
    }
}

public enum HostedSingleCallToolsCapabilityError:
    Error,
    Equatable,
    Sendable
{
    case blankRouteIdentity
    case invalidRouteIdentity
    case invalidRequestPath
    case unexpectedProvider(ProviderID)
    case unexpectedAdapter(ProviderAdapterID)
    case unexpectedDialect(ProviderAdapterDialect)
    case untrustedDeployment(ProviderDeployment)
    case untrustedProvenance(ProviderRouteProvenance)
    case requiredCapabilityMissing(ProviderCapability)
    case parallelToolCapabilityPresent
    case nonTextCapabilityPresent(ProviderCapability)
    case dialectCapabilityMismatch(ProviderCapability)
    case invalidTokenLimits
    case invalidToolDefinitionLimit(UInt32)
    case invalidToolCallLimit(UInt32)
}

extension ProviderAdapterDescriptor {
    func validatedHostedSingleCallToolsSnapshot(
        expectedDeployment: ProviderDeployment,
        expectedProvenance: ProviderRouteProvenance
    ) throws -> HostedSingleCallToolsRouteSnapshot {
        let route = route
        let identities = [
            route.providerID.rawValue,
            route.modelID.rawValue,
            route.adapterID.rawValue,
        ]
        guard identities.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw HostedSingleCallToolsCapabilityError.blankRouteIdentity
        }
        guard identities.allSatisfy(Self.isSafeSingleCallRouteIdentity) else {
            throw HostedSingleCallToolsCapabilityError.invalidRouteIdentity
        }
        guard Self.isSafeSingleCallProviderPath(requestPath) else {
            throw HostedSingleCallToolsCapabilityError.invalidRequestPath
        }
        guard route.deployment == expectedDeployment,
              route.deployment == .hostedService
        else {
            throw HostedSingleCallToolsCapabilityError.untrustedDeployment(
                route.deployment
            )
        }
        guard route.provenance == expectedProvenance,
              route.provenance != .callerConfigured
        else {
            throw HostedSingleCallToolsCapabilityError.untrustedProvenance(
                route.provenance
            )
        }

        let expectedAdapter: ProviderAdapterID
        let expectedProvider: ProviderID
        let expectedDialect: ProviderAdapterDialect
        let expectedPath: String
        switch expectedProvenance {
        case .builtInOpenAIChatCompletions:
            expectedProvider = ProviderID(rawValue: "openai")
            expectedAdapter = ProviderAdapterID(
                rawValue: "openai-chat-completions"
            )
            expectedDialect = .openAIChatCompletions
            expectedPath = "/v1/chat/completions"
        case .builtInOpenAIResponses:
            expectedProvider = ProviderID(rawValue: "openai")
            expectedAdapter = ProviderAdapterID(rawValue: "openai-responses")
            expectedDialect = .openAIResponses
            expectedPath = "/v1/responses"
        case .builtInOpenAICodexResponses:
            expectedProvider = ProviderID(rawValue: "openai-codex")
            expectedAdapter = ProviderAdapterID(
                rawValue: "openai-codex-responses"
            )
            expectedDialect = .openAIResponses
            expectedPath = "/codex/responses"
        case .builtInOpenCodeZenChatCompletions:
            expectedProvider = ProviderID(rawValue: "opencode-zen")
            expectedAdapter = ProviderAdapterID(
                rawValue: "opencode-zen-chat-completions"
            )
            expectedDialect = .openAIChatCompletions
            expectedPath = "/zen/v1/chat/completions"
        case .builtInLocalModel, .callerConfigured:
            throw HostedSingleCallToolsCapabilityError.untrustedProvenance(
                expectedProvenance
            )
        }
        guard route.providerID == expectedProvider else {
            throw HostedSingleCallToolsCapabilityError.unexpectedProvider(
                route.providerID
            )
        }
        guard route.adapterID == expectedAdapter else {
            throw HostedSingleCallToolsCapabilityError.unexpectedAdapter(
                route.adapterID
            )
        }
        guard dialect == expectedDialect else {
            throw HostedSingleCallToolsCapabilityError.unexpectedDialect(
                dialect
            )
        }
        guard requestPath == expectedPath else {
            throw HostedSingleCallToolsCapabilityError.invalidRequestPath
        }

        for required in [
            ProviderCapability.cancellation,
            .streaming,
            .usageStreaming,
            .tools,
            .typedToolArguments,
            .strictToolSchema,
        ] where !route.capabilities.features.contains(required) {
            throw HostedSingleCallToolsCapabilityError
                .requiredCapabilityMissing(required)
        }
        guard !route.capabilities.features.contains(.parallelToolCalls) else {
            throw HostedSingleCallToolsCapabilityError
                .parallelToolCapabilityPresent
        }
        for forbidden in [
            ProviderCapability.imageInput,
            .structuredContent,
        ] where route.capabilities.features.contains(forbidden) {
            throw HostedSingleCallToolsCapabilityError
                .nonTextCapabilityPresent(forbidden)
        }
        if dialect != .openAIResponses,
           route.capabilities.features.contains(.responseContinuation)
        {
            throw HostedSingleCallToolsCapabilityError
                .dialectCapabilityMismatch(.responseContinuation)
        }
        if dialect != .openAIResponses,
           route.capabilities.features.contains(.reasoning)
        {
            throw HostedSingleCallToolsCapabilityError
                .dialectCapabilityMismatch(.reasoning)
        }
        guard route.capabilities.contextWindowTokens > 0,
              route.capabilities.maximumOutputTokens > 0,
              route.capabilities.maximumOutputTokens <=
                route.capabilities.contextWindowTokens
        else {
            throw HostedSingleCallToolsCapabilityError.invalidTokenLimits
        }
        guard route.capabilities.maximumToolDefinitions == 20 else {
            throw HostedSingleCallToolsCapabilityError
                .invalidToolDefinitionLimit(
                    route.capabilities.maximumToolDefinitions
                )
        }
        guard route.capabilities.maximumToolCallsPerTurn == 1 else {
            throw HostedSingleCallToolsCapabilityError.invalidToolCallLimit(
                route.capabilities.maximumToolCallsPerTurn
            )
        }

        let material = HostedSingleCallToolsDescriptorMaterial(
            scheme: "novaforge-hosted-single-call-tools-provider-v1",
            providerID: route.providerID,
            modelID: route.modelID,
            adapterID: route.adapterID,
            dialect: dialect,
            requestPath: requestPath,
            capabilities: route.capabilities,
            deployment: route.deployment,
            provenance: route.provenance,
            maximumToolDefinitions:
                route.capabilities.maximumToolDefinitions,
            maximumToolCallsPerTurn:
                route.capabilities.maximumToolCallsPerTurn,
            parallelToolDispatchEnabled: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(material))
            .map { String(format: "%02x", $0) }
            .joined()
        return HostedSingleCallToolsRouteSnapshot(
            providerID: route.providerID,
            modelID: route.modelID,
            adapterID: route.adapterID,
            dialect: dialect,
            requestPath: requestPath,
            capabilities: route.capabilities,
            deployment: route.deployment,
            provenance: route.provenance,
            maximumToolDefinitions:
                route.capabilities.maximumToolDefinitions,
            maximumToolCallsPerTurn:
                route.capabilities.maximumToolCallsPerTurn,
            parallelToolDispatchEnabled: false,
            descriptorSHA256: "sha256:" + digest
        )
    }

    private static func isSafeSingleCallRouteIdentity(
        _ value: String
    ) -> Bool {
        value.utf8.count <= 512 && value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.controlCharacters.contains(scalar) &&
                scalar.properties.generalCategory != .format
        }
    }

    private static func isSafeSingleCallProviderPath(
        _ value: String
    ) -> Bool {
        value.hasPrefix("/") && !value.hasPrefix("//") &&
            !value.contains("://") && !value.contains("@") &&
            !value.contains("?") && !value.contains("#") &&
            !value.contains("\\") && value.utf8.count <= 2_048 &&
            value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                    !CharacterSet.controlCharacters.contains(scalar) &&
                    scalar.properties.generalCategory != .format
            }
    }
}

private struct HostedSingleCallToolsDescriptorMaterial: Codable {
    let scheme: String
    let providerID: ProviderID
    let modelID: ProviderModelID
    let adapterID: ProviderAdapterID
    let dialect: ProviderAdapterDialect
    let requestPath: String
    let capabilities: ProviderModelCapabilities
    let deployment: ProviderDeployment
    let provenance: ProviderRouteProvenance
    let maximumToolDefinitions: UInt32
    let maximumToolCallsPerTurn: UInt32
    let parallelToolDispatchEnabled: Bool
}

public extension ProviderModelCapabilities {
    static let hostedChatSingleCallToolsBaseline =
        ProviderModelCapabilities(
            features: ProviderCapabilitySet([
                .cancellation,
                .promptCaching,
                .streaming,
                .strictToolSchema,
                .temperature,
                .tools,
                .typedToolArguments,
                .usageStreaming,
            ]),
            contextWindowTokens: 128_000,
            maximumOutputTokens: 16_384,
            maximumToolDefinitions: 20,
            maximumToolCallsPerTurn: 1
        )

    static let hostedResponsesSingleCallToolsBaseline =
        ProviderModelCapabilities(
            features: ProviderCapabilitySet([
                .cancellation,
                .promptCaching,
                .reasoning,
                .responseContinuation,
                .streaming,
                .strictToolSchema,
                .temperature,
                .tools,
                .typedToolArguments,
                .usageStreaming,
            ]),
            contextWindowTokens: 128_000,
            maximumOutputTokens: 16_384,
            maximumToolDefinitions: 20,
            maximumToolCallsPerTurn: 1
        )
}

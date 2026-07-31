import CryptoKit
import Foundation

/// Frozen, data-only evidence for one package-owned OpenAI route that may
/// expose a bounded set of strict read-only tools. The snapshot intentionally
/// carries no transport, credentials, executor, or mutation authority.
public struct HostedReadOnlyToolsRouteSnapshot: Codable, Equatable, Sendable {
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

/// Opaque authority minted only by `TrustedHostedProviderCatalog` after the
/// exact built-in OpenAI descriptor has been revalidated. This is deliberately
/// a different capability from `HostedTextOnlyProviderCapability`: neither can
/// be implicitly upgraded into the other.
public struct HostedReadOnlyToolsProviderCapability: Equatable, Sendable {
    public let snapshot: HostedReadOnlyToolsRouteSnapshot

    init(snapshot: HostedReadOnlyToolsRouteSnapshot) {
        self.snapshot = snapshot
    }
}

public enum HostedReadOnlyToolsCapabilityError: Error, Equatable, Sendable {
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
    func validatedHostedReadOnlyToolsSnapshot(
        expectedDeployment: ProviderDeployment,
        expectedProvenance: ProviderRouteProvenance
    ) throws -> HostedReadOnlyToolsRouteSnapshot {
        let route = route
        let identities = [
            route.providerID.rawValue,
            route.modelID.rawValue,
            route.adapterID.rawValue,
        ]
        guard identities.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw HostedReadOnlyToolsCapabilityError.blankRouteIdentity
        }
        guard identities.allSatisfy(Self.isSafeRouteIdentity) else {
            throw HostedReadOnlyToolsCapabilityError.invalidRouteIdentity
        }
        guard Self.isSafeRelativeProviderPath(requestPath) else {
            throw HostedReadOnlyToolsCapabilityError.invalidRequestPath
        }
        guard route.providerID == ProviderID(rawValue: "openai") else {
            throw HostedReadOnlyToolsCapabilityError.unexpectedProvider(route.providerID)
        }
        guard route.deployment == expectedDeployment,
              route.deployment == .hostedService else {
            throw HostedReadOnlyToolsCapabilityError.untrustedDeployment(route.deployment)
        }
        guard route.provenance == expectedProvenance,
              route.provenance != .callerConfigured else {
            throw HostedReadOnlyToolsCapabilityError.untrustedProvenance(route.provenance)
        }

        let expectedAdapter: ProviderAdapterID
        let expectedDialect: ProviderAdapterDialect
        let expectedPath: String
        switch expectedProvenance {
        case .builtInOpenAIChatCompletions:
            expectedAdapter = ProviderAdapterID(rawValue: "openai-chat-completions")
            expectedDialect = .openAIChatCompletions
            expectedPath = "/v1/chat/completions"
        case .builtInOpenAIResponses:
            expectedAdapter = ProviderAdapterID(rawValue: "openai-responses")
            expectedDialect = .openAIResponses
            expectedPath = "/v1/responses"
        case .builtInOpenAICodexResponses,
             .builtInOpenCodeZenChatCompletions, .builtInLocalModel,
             .callerConfigured:
            throw HostedReadOnlyToolsCapabilityError.untrustedProvenance(expectedProvenance)
        }
        guard route.adapterID == expectedAdapter else {
            throw HostedReadOnlyToolsCapabilityError.unexpectedAdapter(route.adapterID)
        }
        guard dialect == expectedDialect else {
            throw HostedReadOnlyToolsCapabilityError.unexpectedDialect(dialect)
        }
        guard requestPath == expectedPath else {
            throw HostedReadOnlyToolsCapabilityError.invalidRequestPath
        }

        for required in [
            ProviderCapability.cancellation,
            .streaming,
            .usageStreaming,
            .tools,
            .typedToolArguments,
            .strictToolSchema,
        ] where !route.capabilities.features.contains(required) {
            throw HostedReadOnlyToolsCapabilityError.requiredCapabilityMissing(required)
        }
        guard !route.capabilities.features.contains(.parallelToolCalls) else {
            throw HostedReadOnlyToolsCapabilityError.parallelToolCapabilityPresent
        }
        for forbidden in [
            ProviderCapability.imageInput,
            .reasoning,
            .structuredContent,
        ] where route.capabilities.features.contains(forbidden) {
            throw HostedReadOnlyToolsCapabilityError.nonTextCapabilityPresent(forbidden)
        }
        if dialect != .openAIResponses,
           route.capabilities.features.contains(.responseContinuation) {
            throw HostedReadOnlyToolsCapabilityError.dialectCapabilityMismatch(
                .responseContinuation
            )
        }
        guard route.capabilities.contextWindowTokens > 0,
              route.capabilities.maximumOutputTokens > 0,
              route.capabilities.maximumOutputTokens <= route.capabilities.contextWindowTokens else {
            throw HostedReadOnlyToolsCapabilityError.invalidTokenLimits
        }
        guard (1...128).contains(route.capabilities.maximumToolDefinitions) else {
            throw HostedReadOnlyToolsCapabilityError.invalidToolDefinitionLimit(
                route.capabilities.maximumToolDefinitions
            )
        }
        guard route.capabilities.maximumToolCallsPerTurn == 1 else {
            throw HostedReadOnlyToolsCapabilityError.invalidToolCallLimit(
                route.capabilities.maximumToolCallsPerTurn
            )
        }

        let material = HostedReadOnlyToolsDescriptorMaterial(
            scheme: "novaforge-hosted-read-only-tools-provider-v1",
            providerID: route.providerID,
            modelID: route.modelID,
            adapterID: route.adapterID,
            dialect: dialect,
            requestPath: requestPath,
            capabilities: route.capabilities,
            deployment: route.deployment,
            provenance: route.provenance,
            maximumToolDefinitions: route.capabilities.maximumToolDefinitions,
            maximumToolCallsPerTurn: route.capabilities.maximumToolCallsPerTurn,
            parallelToolDispatchEnabled: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(material))
            .map { String(format: "%02x", $0) }
            .joined()
        return HostedReadOnlyToolsRouteSnapshot(
            providerID: route.providerID,
            modelID: route.modelID,
            adapterID: route.adapterID,
            dialect: dialect,
            requestPath: requestPath,
            capabilities: route.capabilities,
            deployment: route.deployment,
            provenance: route.provenance,
            maximumToolDefinitions: route.capabilities.maximumToolDefinitions,
            maximumToolCallsPerTurn: route.capabilities.maximumToolCallsPerTurn,
            parallelToolDispatchEnabled: false,
            descriptorSHA256: "sha256:" + digest
        )
    }

    private static func isSafeRouteIdentity(_ value: String) -> Bool {
        value.utf8.count <= 512 && value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.controlCharacters.contains(scalar) &&
                scalar.properties.generalCategory != .format
        }
    }

    private static func isSafeRelativeProviderPath(_ value: String) -> Bool {
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

private struct HostedReadOnlyToolsDescriptorMaterial: Codable {
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
    static let hostedChatReadOnlyToolsCanaryBaseline = ProviderModelCapabilities(
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
        maximumToolDefinitions: 12,
        maximumToolCallsPerTurn: 1
    )

    static let hostedResponsesReadOnlyToolsCanaryBaseline = ProviderModelCapabilities(
        features: ProviderCapabilitySet([
            .cancellation,
            .promptCaching,
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
        maximumToolDefinitions: 12,
        maximumToolCallsPerTurn: 1
    )
}

import CryptoKit
import Foundation

public struct HostedTextOnlyRouteSnapshot: Codable, Equatable, Sendable {
    public let providerID: ProviderID
    public let modelID: ProviderModelID
    public let adapterID: ProviderAdapterID
    public let dialect: ProviderAdapterDialect
    public let requestPath: String
    public let capabilities: ProviderModelCapabilities
    public let deployment: ProviderDeployment
    public let provenance: ProviderRouteProvenance
    public let toolDispatchDisabled: Bool
    public let descriptorSHA256: String
}

/// Opaque authority proving that a descriptor from a trusted provider catalog
/// was revalidated as hosted, streaming text-only, and incapable of tool dispatch.
/// The token deliberately stores no adapter, transport, credentials, or closure.
public struct HostedTextOnlyProviderCapability: Equatable, Sendable {
    public let snapshot: HostedTextOnlyRouteSnapshot

    init(snapshot: HostedTextOnlyRouteSnapshot) {
        self.snapshot = snapshot
    }
}

public enum HostedTextOnlyCapabilityError: Error, Equatable, Sendable {
    case blankRouteIdentity
    case invalidRequestPath
    case untrustedDeployment(ProviderDeployment)
    case untrustedProvenance(ProviderRouteProvenance)
    case requiredCapabilityMissing(ProviderCapability)
    case toolCapabilityPresent(ProviderCapability)
    case nonTextCapabilityPresent(ProviderCapability)
    case dialectCapabilityMismatch(ProviderCapability)
    case nonzeroToolLimit(UInt32)
}

extension ProviderAdapterDescriptor {
    func validatedHostedTextOnlySnapshot(
        expectedDeployment: ProviderDeployment,
        expectedProvenance: ProviderRouteProvenance
    ) throws -> HostedTextOnlyRouteSnapshot {
        let route = route
        guard !route.providerID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !route.modelID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !route.adapterID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw HostedTextOnlyCapabilityError.blankRouteIdentity }
        guard requestPath.hasPrefix("/"), !requestPath.hasPrefix("//"),
              !requestPath.contains("://"), !requestPath.contains("@"),
              !requestPath.contains("?"), !requestPath.contains("#"),
              !requestPath.contains("\\"), requestPath.utf8.count <= 2_048,
              requestPath.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                      !CharacterSet.controlCharacters.contains(scalar) &&
                      scalar.properties.generalCategory != .format
              })
        else { throw HostedTextOnlyCapabilityError.invalidRequestPath }
        guard route.deployment == expectedDeployment,
              route.deployment == .hostedService
        else {
            throw HostedTextOnlyCapabilityError.untrustedDeployment(
                route.deployment
            )
        }
        guard route.provenance == expectedProvenance,
              route.provenance != .callerConfigured
        else {
            throw HostedTextOnlyCapabilityError.untrustedProvenance(
                route.provenance
            )
        }

        for required in [
            ProviderCapability.cancellation,
            .streaming,
            .usageStreaming,
        ] where !route.capabilities.features.contains(required) {
            throw HostedTextOnlyCapabilityError.requiredCapabilityMissing(required)
        }
        for forbidden in [
            ProviderCapability.tools,
            .typedToolArguments,
            .parallelToolCalls,
            .strictToolSchema,
        ] where route.capabilities.features.contains(forbidden) {
            throw HostedTextOnlyCapabilityError.toolCapabilityPresent(forbidden)
        }
        for forbidden in [
            ProviderCapability.imageInput,
            .reasoning,
            .structuredContent,
        ] where route.capabilities.features.contains(forbidden) {
            throw HostedTextOnlyCapabilityError.nonTextCapabilityPresent(forbidden)
        }
        if dialect != .openAIResponses,
           route.capabilities.features.contains(.responseContinuation) {
            throw HostedTextOnlyCapabilityError.dialectCapabilityMismatch(
                .responseContinuation
            )
        }
        guard route.capabilities.maximumToolDefinitions == 0 else {
            throw HostedTextOnlyCapabilityError.nonzeroToolLimit(
                route.capabilities.maximumToolDefinitions
            )
        }
        guard route.capabilities.maximumToolCallsPerTurn == 0 else {
            throw HostedTextOnlyCapabilityError.nonzeroToolLimit(
                route.capabilities.maximumToolCallsPerTurn
            )
        }

        let material = HostedTextOnlyDescriptorMaterial(
            scheme: "novaforge-hosted-text-only-provider-v1",
            providerID: route.providerID,
            modelID: route.modelID,
            adapterID: route.adapterID,
            dialect: dialect,
            requestPath: requestPath,
            capabilities: route.capabilities,
            deployment: route.deployment,
            provenance: route.provenance,
            toolDispatchDisabled: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(material))
            .map { String(format: "%02x", $0) }
            .joined()
        return HostedTextOnlyRouteSnapshot(
            providerID: route.providerID,
            modelID: route.modelID,
            adapterID: route.adapterID,
            dialect: dialect,
            requestPath: requestPath,
            capabilities: route.capabilities,
            deployment: route.deployment,
            provenance: route.provenance,
            toolDispatchDisabled: true,
            descriptorSHA256: "sha256:" + digest
        )
    }
}

private struct HostedTextOnlyDescriptorMaterial: Codable {
    let scheme: String
    let providerID: ProviderID
    let modelID: ProviderModelID
    let adapterID: ProviderAdapterID
    let dialect: ProviderAdapterDialect
    let requestPath: String
    let capabilities: ProviderModelCapabilities
    let deployment: ProviderDeployment
    let provenance: ProviderRouteProvenance
    let toolDispatchDisabled: Bool
}

public extension ProviderModelCapabilities {
    static let hostedChatTextOnlyBaseline = ProviderModelCapabilities(
        features: ProviderCapabilitySet([
            .cancellation,
            .promptCaching,
            .streaming,
            .temperature,
            .usageStreaming,
        ]),
        contextWindowTokens: 128_000,
        maximumOutputTokens: 16_384,
        maximumToolDefinitions: 0,
        maximumToolCallsPerTurn: 0
    )

    static let hostedResponsesTextOnlyBaseline = ProviderModelCapabilities(
        features: ProviderCapabilitySet([
            .cancellation,
            .promptCaching,
            .responseContinuation,
            .streaming,
            .temperature,
            .usageStreaming,
        ]),
        contextWindowTokens: 128_000,
        maximumOutputTokens: 16_384,
        maximumToolDefinitions: 0,
        maximumToolCallsPerTurn: 0
    )

    /// Compatibility alias for persisted canary fixtures. New code chooses a
    /// dialect-specific baseline so Chat never claims Responses continuation.
    static let hostedTextOnlyBaseline = hostedResponsesTextOnlyBaseline
}

import AgentDomain
import AgentTools
import CryptoKit
import Foundation

public enum LocalModelAttestedBinding: String, Equatable, Sendable {
    case modelArtifactSHA256
    case tokenizerSHA256
    case promptTemplateSHA256
    case contextConfigurationSHA256
    case grammarSHA256
    case grammarCompilerID
    case grammarCompilerVersion
    case canonicalToolRegistrySHA256
    case toolDefinitionCount
    case modelID
    case adapterID
    case contextWindowTokens
    case maximumOutputTokens
    case maximumToolCallsPerTurn
    case parallelToolCalls
}

public enum LocalModelTrustedRouteBinding: String, Equatable, Sendable {
    case providerID
    case modelID
    case adapterID
    case dialect
    case requestPath
    case capabilities
    case deployment
    case provenance
}

public enum LocalModelSingleCallToolsError: Error, Equatable, Sendable {
    case invalidDigest(LocalModelAttestedBinding)
    case invalidIdentity(LocalModelAttestedBinding)
    case invalidContextWindow
    case invalidOutputLimit
    case invalidToolDefinitionCount
    case invalidToolCallLimit
    case parallelToolCallsForbidden
    case bindingMismatch(LocalModelAttestedBinding)
    case registryEncodingFailed
    case trustedRouteMismatch(LocalModelTrustedRouteBinding)
    case unknownAdapter(ProviderAdapterID)
    case authorityUnavailable
    case snapshotMismatch
}

/// Data-only output from the app's artifact verifier. Construction validates
/// shape only: the app must hash the exact model/tokenizer/template/context/
/// grammar bytes from its trusted artifact source before creating this value.
/// It contains no path, credential, transport, registry, or tool authority.
public struct LocalModelArtifactVerification: Equatable, Sendable {
    public let modelArtifactSHA256: String
    public let tokenizerSHA256: String
    public let promptTemplateSHA256: String
    public let contextConfigurationSHA256: String
    public let grammarSHA256: String
    public let grammarCompilerID: String
    public let grammarCompilerVersion: String

    public init(
        modelArtifactSHA256: String,
        tokenizerSHA256: String,
        promptTemplateSHA256: String,
        contextConfigurationSHA256: String,
        grammarSHA256: String,
        grammarCompilerID: String,
        grammarCompilerVersion: String
    ) throws {
        let digests: [(LocalModelAttestedBinding, String)] = [
            (.modelArtifactSHA256, modelArtifactSHA256),
            (.tokenizerSHA256, tokenizerSHA256),
            (.promptTemplateSHA256, promptTemplateSHA256),
            (.contextConfigurationSHA256, contextConfigurationSHA256),
            (.grammarSHA256, grammarSHA256),
        ]
        for (binding, digest) in digests
        where !LocalModelSingleCallValidation.isSHA256(digest) {
            throw LocalModelSingleCallToolsError.invalidDigest(binding)
        }
        guard LocalModelSingleCallValidation.isSafeCompilerIdentity(
            grammarCompilerID
        ) else {
            throw LocalModelSingleCallToolsError.invalidIdentity(
                .grammarCompilerID
            )
        }
        guard LocalModelSingleCallValidation.isSafeCompilerIdentity(
            grammarCompilerVersion
        ) else {
            throw LocalModelSingleCallToolsError.invalidIdentity(
                .grammarCompilerVersion
            )
        }
        self.modelArtifactSHA256 = modelArtifactSHA256
        self.tokenizerSHA256 = tokenizerSHA256
        self.promptTemplateSHA256 = promptTemplateSHA256
        self.contextConfigurationSHA256 = contextConfigurationSHA256
        self.grammarSHA256 = grammarSHA256
        self.grammarCompilerID = grammarCompilerID
        self.grammarCompilerVersion = grammarCompilerVersion
    }
}

/// Immutable manifest binding one compiled grammar to one exact local route
/// and one exact canonical ToolRegistry provider-definition array. It is not
/// Codable, so decoding persisted strings cannot bypass its validating init.
public struct LocalModelSingleCallToolsAttestation: Equatable, Sendable {
    public let modelArtifactSHA256: String
    public let tokenizerSHA256: String
    public let promptTemplateSHA256: String
    public let contextConfigurationSHA256: String
    public let grammarSHA256: String
    public let grammarCompilerID: String
    public let grammarCompilerVersion: String
    public let canonicalToolRegistrySHA256: String
    public let toolDefinitionCount: UInt32
    public let modelID: ProviderModelID
    public let adapterID: ProviderAdapterID
    public let contextWindowTokens: UInt64
    public let maximumOutputTokens: UInt64
    public let maximumToolCallsPerTurn: UInt32
    public let supportsParallelToolCalls: Bool
    public let attestationSHA256: String

    public init(
        modelArtifactSHA256: String,
        tokenizerSHA256: String,
        promptTemplateSHA256: String,
        contextConfigurationSHA256: String,
        grammarSHA256: String,
        grammarCompilerID: String,
        grammarCompilerVersion: String,
        canonicalToolRegistrySHA256: String,
        toolDefinitionCount: UInt32,
        modelID: ProviderModelID,
        adapterID: ProviderAdapterID,
        contextWindowTokens: UInt64,
        maximumOutputTokens: UInt64,
        maximumToolCallsPerTurn: UInt32 = 1,
        supportsParallelToolCalls: Bool = false
    ) throws {
        let digests: [(LocalModelAttestedBinding, String)] = [
            (.modelArtifactSHA256, modelArtifactSHA256),
            (.tokenizerSHA256, tokenizerSHA256),
            (.promptTemplateSHA256, promptTemplateSHA256),
            (.contextConfigurationSHA256, contextConfigurationSHA256),
            (.grammarSHA256, grammarSHA256),
            (.canonicalToolRegistrySHA256, canonicalToolRegistrySHA256),
        ]
        for (binding, digest) in digests
        where !LocalModelSingleCallValidation.isSHA256(digest) {
            throw LocalModelSingleCallToolsError.invalidDigest(binding)
        }
        guard LocalModelSingleCallValidation.isSafeCompilerIdentity(
            grammarCompilerID
        ) else {
            throw LocalModelSingleCallToolsError.invalidIdentity(
                .grammarCompilerID
            )
        }
        guard LocalModelSingleCallValidation.isSafeCompilerIdentity(
            grammarCompilerVersion
        ) else {
            throw LocalModelSingleCallToolsError.invalidIdentity(
                .grammarCompilerVersion
            )
        }
        guard LocalModelSingleCallValidation.isSafeRouteIdentity(
            modelID.rawValue,
            allowsNamespaceSeparator: true
        ) else {
            throw LocalModelSingleCallToolsError.invalidIdentity(.modelID)
        }
        guard LocalModelSingleCallValidation.isSafeRouteIdentity(
            adapterID.rawValue,
            allowsNamespaceSeparator: false
        ) else {
            throw LocalModelSingleCallToolsError.invalidIdentity(.adapterID)
        }
        guard contextWindowTokens > 0,
              contextWindowTokens <= 1_048_576 else {
            throw LocalModelSingleCallToolsError.invalidContextWindow
        }
        guard maximumOutputTokens > 0,
              maximumOutputTokens <= contextWindowTokens else {
            throw LocalModelSingleCallToolsError.invalidOutputLimit
        }
        guard (1 ... 128).contains(toolDefinitionCount) else {
            throw LocalModelSingleCallToolsError.invalidToolDefinitionCount
        }
        guard maximumToolCallsPerTurn == 1 else {
            throw LocalModelSingleCallToolsError.invalidToolCallLimit
        }
        guard !supportsParallelToolCalls else {
            throw LocalModelSingleCallToolsError.parallelToolCallsForbidden
        }

        self.modelArtifactSHA256 = modelArtifactSHA256
        self.tokenizerSHA256 = tokenizerSHA256
        self.promptTemplateSHA256 = promptTemplateSHA256
        self.contextConfigurationSHA256 = contextConfigurationSHA256
        self.grammarSHA256 = grammarSHA256
        self.grammarCompilerID = grammarCompilerID
        self.grammarCompilerVersion = grammarCompilerVersion
        self.canonicalToolRegistrySHA256 = canonicalToolRegistrySHA256
        self.toolDefinitionCount = toolDefinitionCount
        self.modelID = modelID
        self.adapterID = adapterID
        self.contextWindowTokens = contextWindowTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.maximumToolCallsPerTurn = maximumToolCallsPerTurn
        self.supportsParallelToolCalls = supportsParallelToolCalls
        attestationSHA256 = try LocalModelSingleCallValidation.sha256(
            LocalModelSingleCallAttestationMaterial(
                scheme: "novaforge-local-single-call-attestation-v1",
                modelArtifactSHA256: modelArtifactSHA256,
                tokenizerSHA256: tokenizerSHA256,
                promptTemplateSHA256: promptTemplateSHA256,
                contextConfigurationSHA256: contextConfigurationSHA256,
                grammarSHA256: grammarSHA256,
                grammarCompilerID: grammarCompilerID,
                grammarCompilerVersion: grammarCompilerVersion,
                canonicalToolRegistrySHA256: canonicalToolRegistrySHA256,
                toolDefinitionCount: toolDefinitionCount,
                modelID: modelID,
                adapterID: adapterID,
                contextWindowTokens: contextWindowTokens,
                maximumOutputTokens: maximumOutputTokens,
                maximumToolCallsPerTurn: maximumToolCallsPerTurn,
                supportsParallelToolCalls: supportsParallelToolCalls
            )
        )
    }

    func validateIntegrity() throws {
        let expected = try LocalModelSingleCallValidation.sha256(
            LocalModelSingleCallAttestationMaterial(
                scheme: "novaforge-local-single-call-attestation-v1",
                modelArtifactSHA256: modelArtifactSHA256,
                tokenizerSHA256: tokenizerSHA256,
                promptTemplateSHA256: promptTemplateSHA256,
                contextConfigurationSHA256: contextConfigurationSHA256,
                grammarSHA256: grammarSHA256,
                grammarCompilerID: grammarCompilerID,
                grammarCompilerVersion: grammarCompilerVersion,
                canonicalToolRegistrySHA256: canonicalToolRegistrySHA256,
                toolDefinitionCount: toolDefinitionCount,
                modelID: modelID,
                adapterID: adapterID,
                contextWindowTokens: contextWindowTokens,
                maximumOutputTokens: maximumOutputTokens,
                maximumToolCallsPerTurn: maximumToolCallsPerTurn,
                supportsParallelToolCalls: supportsParallelToolCalls
            )
        )
        guard expected == attestationSHA256 else {
            throw LocalModelSingleCallToolsError.snapshotMismatch
        }
    }
}

public struct LocalModelCanonicalToolRegistryBinding: Equatable, Sendable {
    public let providerDefinitionsSHA256: String
    public let toolDefinitionCount: UInt32

    init(providerDefinitionsSHA256: String, toolDefinitionCount: UInt32) {
        self.providerDefinitionsSHA256 = providerDefinitionsSHA256
        self.toolDefinitionCount = toolDefinitionCount
    }
}

/// Frozen evidence for one package-owned on-device grammar route. It carries
/// provider wire authority only, never an executor, registry, artifact path,
/// model bytes, credential, approval, or mutation authority.
public struct LocalModelSingleCallToolsRouteSnapshot: Equatable, Sendable {
    public let providerID: ProviderID
    public let modelID: ProviderModelID
    public let adapterID: ProviderAdapterID
    public let dialect: ProviderAdapterDialect
    public let requestPath: String
    public let capabilities: ProviderModelCapabilities
    public let deployment: ProviderDeployment
    public let provenance: ProviderRouteProvenance
    public let attestation: LocalModelSingleCallToolsAttestation
    public let orderedProviderDefinitionsSHA256: String
    public let maximumToolDefinitions: UInt32
    public let maximumToolCallsPerTurn: UInt32
    public let parallelToolDispatchEnabled: Bool
    public let descriptorSHA256: String
}

/// Opaque local tool-wire authority. Only TrustedLocalProviderCatalog can mint
/// it after artifact, compiler, route, registry, order, count, and limit checks.
public struct LocalModelSingleCallToolsProviderCapability:
    Equatable,
    Sendable
{
    public let snapshot: LocalModelSingleCallToolsRouteSnapshot

    init(snapshot: LocalModelSingleCallToolsRouteSnapshot) {
        self.snapshot = snapshot
    }
}

public extension TrustedLocalProviderCatalog {
    static func canonicalToolRegistryBinding(
        for registry: ToolRegistry
    ) throws -> LocalModelCanonicalToolRegistryBinding {
        let definitions = registry.providerDefinitions()
        guard let count = UInt32(exactly: definitions.count),
              (1 ... 128).contains(count) else {
            throw LocalModelSingleCallToolsError.invalidToolDefinitionCount
        }
        let data: Data
        do {
            data = try registry.providerDefinitionsData()
        } catch {
            throw LocalModelSingleCallToolsError.registryEncodingFailed
        }
        return LocalModelCanonicalToolRegistryBinding(
            providerDefinitionsSHA256:
                LocalModelSingleCallValidation.sha256(data),
            toolDefinitionCount: count
        )
    }

    static func grammarConstrainedSingleCall(
        modelID: ProviderModelID,
        adapterID: ProviderAdapterID = .init(
            rawValue: "novaforge-local-llama"
        ),
        contextWindowTokens: UInt64,
        maximumOutputTokens: UInt64,
        verifiedArtifacts: LocalModelArtifactVerification,
        attestation: LocalModelSingleCallToolsAttestation,
        toolRegistry: ToolRegistry
    ) throws -> Self {
        try attestation.validateIntegrity()
        let observed: [(LocalModelAttestedBinding, String, String)] = [
            (
                .modelArtifactSHA256,
                verifiedArtifacts.modelArtifactSHA256,
                attestation.modelArtifactSHA256
            ),
            (
                .tokenizerSHA256,
                verifiedArtifacts.tokenizerSHA256,
                attestation.tokenizerSHA256
            ),
            (
                .promptTemplateSHA256,
                verifiedArtifacts.promptTemplateSHA256,
                attestation.promptTemplateSHA256
            ),
            (
                .contextConfigurationSHA256,
                verifiedArtifacts.contextConfigurationSHA256,
                attestation.contextConfigurationSHA256
            ),
            (
                .grammarSHA256,
                verifiedArtifacts.grammarSHA256,
                attestation.grammarSHA256
            ),
            (
                .grammarCompilerID,
                verifiedArtifacts.grammarCompilerID,
                attestation.grammarCompilerID
            ),
            (
                .grammarCompilerVersion,
                verifiedArtifacts.grammarCompilerVersion,
                attestation.grammarCompilerVersion
            ),
        ]
        for (binding, actual, expected) in observed where actual != expected {
            throw LocalModelSingleCallToolsError.bindingMismatch(binding)
        }
        guard modelID == attestation.modelID else {
            throw LocalModelSingleCallToolsError.bindingMismatch(.modelID)
        }
        guard adapterID == attestation.adapterID else {
            throw LocalModelSingleCallToolsError.bindingMismatch(.adapterID)
        }
        guard contextWindowTokens == attestation.contextWindowTokens else {
            throw LocalModelSingleCallToolsError.bindingMismatch(
                .contextWindowTokens
            )
        }
        guard maximumOutputTokens == attestation.maximumOutputTokens else {
            throw LocalModelSingleCallToolsError.bindingMismatch(
                .maximumOutputTokens
            )
        }
        guard attestation.maximumToolCallsPerTurn == 1 else {
            throw LocalModelSingleCallToolsError.bindingMismatch(
                .maximumToolCallsPerTurn
            )
        }
        guard !attestation.supportsParallelToolCalls else {
            throw LocalModelSingleCallToolsError.bindingMismatch(
                .parallelToolCalls
            )
        }

        let registryBinding = try canonicalToolRegistryBinding(
            for: toolRegistry
        )
        guard registryBinding.toolDefinitionCount ==
                attestation.toolDefinitionCount else {
            throw LocalModelSingleCallToolsError.bindingMismatch(
                .toolDefinitionCount
            )
        }
        guard registryBinding.providerDefinitionsSHA256 ==
                attestation.canonicalToolRegistrySHA256 else {
            throw LocalModelSingleCallToolsError.bindingMismatch(
                .canonicalToolRegistrySHA256
            )
        }

        let providerDefinitions = localProviderDefinitions(
            for: toolRegistry
        )
        let unorderedDigest = try LocalModelGrammarAttestation
            .canonicalToolCatalogSHA256(for: providerDefinitions)
        let orderedDigest = try LocalModelGrammarAttestation
            .canonicalOrderedToolCatalogSHA256(for: providerDefinitions)
        let compilerIdentity = attestation.grammarCompilerID + ":" +
            attestation.grammarCompilerVersion
        let adapter = try LocalModelAdapter(configuration: .init(
            adapterID: adapterID,
            modelID: modelID,
            contextWindowTokens: contextWindowTokens,
            maximumOutputTokens: maximumOutputTokens,
            toolMode: .grammarConstrained(.init(
                grammarSHA256: attestation.grammarSHA256,
                toolCatalogSHA256: unorderedDigest,
                orderedToolCatalogSHA256: orderedDigest,
                toolDefinitionCount: attestation.toolDefinitionCount,
                compilerID: compilerIdentity,
                maximumToolCallsPerTurn: 1,
                supportsParallelToolCalls: false
            ))
        ))
        let snapshot = try adapter.descriptor
            .validatedLocalModelSingleCallToolsSnapshot(
                attestation: attestation,
                orderedProviderDefinitionsSHA256: orderedDigest
            )
        return Self(
            adapter: adapter,
            singleCallToolsSnapshot: snapshot
        )
    }

    func localSingleCallToolsCapability(
        adapterID: ProviderAdapterID
    ) throws -> LocalModelSingleCallToolsProviderCapability {
        guard adapter.descriptor.route.adapterID == adapterID else {
            throw LocalModelSingleCallToolsError.unknownAdapter(adapterID)
        }
        guard let expected = singleCallToolsSnapshot else {
            throw LocalModelSingleCallToolsError.authorityUnavailable
        }
        let actual = try adapter.descriptor
            .validatedLocalModelSingleCallToolsSnapshot(
                attestation: expected.attestation,
                orderedProviderDefinitionsSHA256:
                    expected.orderedProviderDefinitionsSHA256
            )
        guard actual == expected else {
            throw LocalModelSingleCallToolsError.snapshotMismatch
        }
        return LocalModelSingleCallToolsProviderCapability(snapshot: actual)
    }

    private static func localProviderDefinitions(
        for registry: ToolRegistry
    ) -> [ProviderToolDefinition] {
        registry.providerDefinitions().map { definition in
            ProviderToolDefinition(
                name: definition.function.name,
                description: definition.function.description,
                parameters: definition.function.parameters,
                strict: definition.function.strict
            )
        }
    }
}

extension ProviderAdapterDescriptor {
    func validatedLocalModelSingleCallToolsSnapshot(
        attestation: LocalModelSingleCallToolsAttestation,
        orderedProviderDefinitionsSHA256: String
    ) throws -> LocalModelSingleCallToolsRouteSnapshot {
        try attestation.validateIntegrity()
        guard route.providerID == ProviderID(rawValue: "novaforge-local") else {
            throw LocalModelSingleCallToolsError.trustedRouteMismatch(
                .providerID
            )
        }
        guard route.modelID == attestation.modelID else {
            throw LocalModelSingleCallToolsError.trustedRouteMismatch(.modelID)
        }
        guard route.adapterID == attestation.adapterID else {
            throw LocalModelSingleCallToolsError.trustedRouteMismatch(
                .adapterID
            )
        }
        guard dialect == .openAICompatibleChat else {
            throw LocalModelSingleCallToolsError.trustedRouteMismatch(.dialect)
        }
        guard requestPath == "/v1/local/chat/completions" else {
            throw LocalModelSingleCallToolsError.trustedRouteMismatch(
                .requestPath
            )
        }
        guard route.deployment == .onDevice else {
            throw LocalModelSingleCallToolsError.trustedRouteMismatch(
                .deployment
            )
        }
        guard route.provenance == .builtInLocalModel else {
            throw LocalModelSingleCallToolsError.trustedRouteMismatch(
                .provenance
            )
        }
        let expectedCapabilities = ProviderModelCapabilities(
            features: ProviderCapabilitySet([
                .cancellation,
                .streaming,
                .strictToolSchema,
                .temperature,
                .tools,
                .typedToolArguments,
                .usageStreaming,
            ]),
            contextWindowTokens: attestation.contextWindowTokens,
            maximumOutputTokens: attestation.maximumOutputTokens,
            maximumToolDefinitions: attestation.toolDefinitionCount,
            maximumToolCallsPerTurn: 1
        )
        guard route.capabilities == expectedCapabilities,
              !route.capabilities.features.contains(.parallelToolCalls) else {
            throw LocalModelSingleCallToolsError.trustedRouteMismatch(
                .capabilities
            )
        }

        let material = LocalModelSingleCallDescriptorMaterial(
            scheme: "novaforge-local-single-call-provider-v1",
            providerID: route.providerID,
            modelID: route.modelID,
            adapterID: route.adapterID,
            dialect: dialect,
            requestPath: requestPath,
            capabilities: route.capabilities,
            deployment: route.deployment,
            provenance: route.provenance,
            attestationSHA256: attestation.attestationSHA256,
            canonicalToolRegistrySHA256:
                attestation.canonicalToolRegistrySHA256,
            orderedProviderDefinitionsSHA256:
                orderedProviderDefinitionsSHA256,
            maximumToolDefinitions: attestation.toolDefinitionCount,
            maximumToolCallsPerTurn: 1,
            parallelToolDispatchEnabled: false
        )
        return LocalModelSingleCallToolsRouteSnapshot(
            providerID: route.providerID,
            modelID: route.modelID,
            adapterID: route.adapterID,
            dialect: dialect,
            requestPath: requestPath,
            capabilities: route.capabilities,
            deployment: route.deployment,
            provenance: route.provenance,
            attestation: attestation,
            orderedProviderDefinitionsSHA256:
                orderedProviderDefinitionsSHA256,
            maximumToolDefinitions: attestation.toolDefinitionCount,
            maximumToolCallsPerTurn: 1,
            parallelToolDispatchEnabled: false,
            descriptorSHA256:
                try LocalModelSingleCallValidation.sha256(material)
        )
    }
}

private enum LocalModelSingleCallValidation {
    static func isSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 71,
              value.hasPrefix("sha256:") else {
            return false
        }
        return value.utf8.dropFirst(7).allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }

    static func isSafeCompilerIdentity(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) ||
                (97 ... 122).contains($0) || [45, 46, 58, 95].contains($0)
        }
    }

    static func isSafeRouteIdentity(
        _ value: String,
        allowsNamespaceSeparator: Bool
    ) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty,
              bytes.count <= 256,
              !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.contains(".."),
              !value.contains("://"),
              !value.contains("\\"),
              !value.contains("@") else {
            return false
        }
        return bytes.allSatisfy { byte in
            (48 ... 57).contains(byte) || (65 ... 90).contains(byte) ||
                (97 ... 122).contains(byte) ||
                [43, 45, 46, 58, 95].contains(byte) ||
                (allowsNamespaceSeparator && byte == 47)
        }
    }

    static func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sha256<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(value))
    }
}

private struct LocalModelSingleCallAttestationMaterial: Encodable {
    let scheme: String
    let modelArtifactSHA256: String
    let tokenizerSHA256: String
    let promptTemplateSHA256: String
    let contextConfigurationSHA256: String
    let grammarSHA256: String
    let grammarCompilerID: String
    let grammarCompilerVersion: String
    let canonicalToolRegistrySHA256: String
    let toolDefinitionCount: UInt32
    let modelID: ProviderModelID
    let adapterID: ProviderAdapterID
    let contextWindowTokens: UInt64
    let maximumOutputTokens: UInt64
    let maximumToolCallsPerTurn: UInt32
    let supportsParallelToolCalls: Bool
}

private struct LocalModelSingleCallDescriptorMaterial: Encodable {
    let scheme: String
    let providerID: ProviderID
    let modelID: ProviderModelID
    let adapterID: ProviderAdapterID
    let dialect: ProviderAdapterDialect
    let requestPath: String
    let capabilities: ProviderModelCapabilities
    let deployment: ProviderDeployment
    let provenance: ProviderRouteProvenance
    let attestationSHA256: String
    let canonicalToolRegistrySHA256: String
    let orderedProviderDefinitionsSHA256: String
    let maximumToolDefinitions: UInt32
    let maximumToolCallsPerTurn: UInt32
    let parallelToolDispatchEnabled: Bool
}

import AgentProviders
import AgentTools
import CryptoKit
import Foundation

enum AgentProductionProviderLane: String, Codable, Equatable, Sendable {
    case hostedOpenAIChatCompletions
    case hostedOpenAICodexResponses
    case hostedOpenCodeZenChatCompletions
    case localTextOnly
    case localSingleCallTools
}

enum AgentProductionProviderGatewayError: Error, Equatable, Sendable {
    case invalidHostedCredential
    case unavailableLocalModel(ProviderModelID)
    case selectionLaneMismatch(
        expected: AgentProductionProviderLane,
        actual: AgentProductionProviderLane
    )
    case selectionDescriptorMismatch
    case hostedAuthorityMismatch
    case localAuthorityMismatch
    case bundleSelectionMismatch
    case freshRunPlanRouteMismatch
}

/// Immutable route identity persisted or selected before an engine is built.
///
/// `declaredDescriptor` is evidence to validate, never authority. Composition
/// reconstructs the package-owned catalog from `modelID` and requires exact
/// descriptor equality before retaining any provider gateway.
struct AgentProductionProviderRouteSelection:
    Codable,
    Equatable,
    Sendable
{
    let lane: AgentProductionProviderLane
    let modelID: ProviderModelID
    let declaredDescriptor: ProviderAdapterDescriptor

    init(
        lane: AgentProductionProviderLane,
        modelID: ProviderModelID,
        declaredDescriptor: ProviderAdapterDescriptor
    ) {
        self.lane = lane
        self.modelID = modelID
        self.declaredDescriptor = declaredDescriptor
    }

    static func hostedOpenAIChatCompletions(
        modelID: ProviderModelID
    ) throws -> Self {
        let authority = try HostedAuthority(modelID: modelID)
        return Self(
            lane: .hostedOpenAIChatCompletions,
            modelID: modelID,
            declaredDescriptor: authority.descriptor
        )
    }

    static func localTextOnly(
        modelID: ProviderModelID
    ) throws -> Self {
        let authority = try LocalAuthority(modelID: modelID)
        return Self(
            lane: .localTextOnly,
            modelID: modelID,
            declaredDescriptor: authority.descriptor
        )
    }

    static func localSingleCallTools(
        modelID: ProviderModelID
    ) throws -> Self {
        let authority = try LocalToolsAuthority(modelID: modelID)
        return Self(
            lane: .localSingleCallTools,
            modelID: modelID,
            declaredDescriptor: authority.descriptor
        )
    }

    static func hostedOpenCodeZenChatCompletions(
        modelID: ProviderModelID
    ) throws -> Self {
        let authority = try OpenCodeZenAuthority(modelID: modelID)
        return Self(
            lane: .hostedOpenCodeZenChatCompletions,
            modelID: modelID,
            declaredDescriptor: authority.descriptor
        )
    }

    static func hostedOpenAICodexResponses(
        modelID: ProviderModelID
    ) throws -> Self {
        let authority = try OpenAICodexAuthority(modelID: modelID)
        return Self(
            lane: .hostedOpenAICodexResponses,
            modelID: modelID,
            declaredDescriptor: authority.descriptor
        )
    }
}

/// One exact provider route plus its gateway for an `AgentSystem` engine
/// factory. The bundle exposes no credential, endpoint, mutable route list, or
/// transport. An engine factory must present the same frozen selection before
/// it can obtain the gateway.
struct AgentProductionProviderGatewayBundle: Sendable {
    let selection: AgentProductionProviderRouteSelection
    let descriptor: ProviderAdapterDescriptor
    let adapterID: ProviderAdapterID

    var route: ProviderRoute { descriptor.route }

    private let gateway: ModelGateway

    fileprivate init(
        selection: AgentProductionProviderRouteSelection,
        descriptor: ProviderAdapterDescriptor,
        gateway: ModelGateway
    ) {
        self.selection = selection
        self.descriptor = descriptor
        adapterID = descriptor.route.adapterID
        self.gateway = gateway
    }

    func modelGateway(
        for expectedSelection: AgentProductionProviderRouteSelection
    ) throws -> ModelGateway {
        guard expectedSelection == selection,
              descriptor == selection.declaredDescriptor,
              adapterID == selection.declaredDescriptor.route.adapterID,
              route.modelID == selection.modelID
        else {
            throw AgentProductionProviderGatewayError
                .bundleSelectionMismatch
        }
        return gateway
    }

    /// Production engine-factory entry point. A route persisted in the fresh
    /// run plan cannot be silently substituted with this bundle's route.
    func modelGateway(
        for expectedSelection: AgentProductionProviderRouteSelection,
        freshRunPlan: AgentSystemFreshRunPlan
    ) throws -> ModelGateway {
        guard freshRunPlan.providerRoute == route else {
            throw AgentProductionProviderGatewayError
                .freshRunPlanRouteMismatch
        }
        return try modelGateway(for: expectedSelection)
    }
}

/// Fail-closed construction for the two production provider lanes currently
/// proven by the app. Hosted tools use only OpenAI Chat Completions with the
/// package's single-call capability. Local generation remains text-only until
/// a model/tokenizer/template/compiler/grammar/tool-catalog attestation exists.
enum AgentProductionProviderGatewayFactory {
    static func localSingleCallTools(
        modelID: ProviderModelID,
        workspace: SandboxWorkspace
    ) throws -> AgentProductionProviderGatewayBundle {
        try localSingleCallTools(
            selection: .localSingleCallTools(modelID: modelID),
            workspace: workspace
        )
    }

    static func localSingleCallTools(
        selection: AgentProductionProviderRouteSelection,
        workspace: SandboxWorkspace
    ) throws -> AgentProductionProviderGatewayBundle {
        let authority = try LocalToolsAuthority(modelID: selection.modelID)
        return try localSingleCallTools(
            selection: selection,
            authority: authority,
            transport: AgentLocalModelProviderTransport(
                inference: LocalModelClient.shared,
                singleCallToolsCapability: authority.capability,
                toolRegistry: authority.toolRegistry,
                workspace: workspace
            )
        )
    }

    static func localSingleCallTools(
        selection: AgentProductionProviderRouteSelection,
        workspace: SandboxWorkspace,
        inference: any AgentLocalModelInferenceStreaming
    ) throws -> AgentProductionProviderGatewayBundle {
        let authority = try LocalToolsAuthority(modelID: selection.modelID)
        return try localSingleCallTools(
            selection: selection,
            authority: authority,
            transport: AgentLocalModelProviderTransport(
                inference: inference,
                singleCallToolsCapability: authority.capability,
                toolRegistry: authority.toolRegistry,
                workspace: workspace
            )
        )
    }

    private static func localSingleCallTools(
        selection: AgentProductionProviderRouteSelection,
        authority: LocalToolsAuthority,
        transport: AgentLocalModelProviderTransport
    ) throws -> AgentProductionProviderGatewayBundle {
        guard selection.lane == .localSingleCallTools else {
            throw AgentProductionProviderGatewayError.selectionLaneMismatch(
                expected: .localSingleCallTools,
                actual: selection.lane
            )
        }
        guard selection.declaredDescriptor == authority.descriptor else {
            throw AgentProductionProviderGatewayError
                .selectionDescriptorMismatch
        }
        let router = try AgentProviderTransportRouter(bindings: [
            .init(descriptor: authority.descriptor, transport: transport),
        ])
        return AgentProductionProviderGatewayBundle(
            selection: selection,
            descriptor: authority.descriptor,
            gateway: ModelGateway(
                catalog: authority.catalog,
                transport: router
            )
        )
    }

    static func hostedOpenAICodexResponses(
        modelID: ProviderModelID,
        credential: String
    ) throws -> AgentProductionProviderGatewayBundle {
        try hostedOpenAICodexResponses(
            selection: .hostedOpenAICodexResponses(modelID: modelID),
            credential: credential
        )
    }

    static func hostedOpenAICodexResponses(
        selection: AgentProductionProviderRouteSelection,
        credential: String
    ) throws -> AgentProductionProviderGatewayBundle {
        guard selection.lane == .hostedOpenAICodexResponses else {
            throw AgentProductionProviderGatewayError.selectionLaneMismatch(
                expected: .hostedOpenAICodexResponses,
                actual: selection.lane
            )
        }
        try validateHostedCredential(credential)
        let authority = try OpenAICodexAuthority(modelID: selection.modelID)
        guard selection.declaredDescriptor == authority.descriptor else {
            throw AgentProductionProviderGatewayError
                .selectionDescriptorMismatch
        }
        let transport = AgentHostedProviderTransport(
            credential: credential,
            singleCallToolsCapability: authority.capability
        )
        let router = try AgentProviderTransportRouter(bindings: [
            .init(descriptor: authority.descriptor, transport: transport),
        ])
        return AgentProductionProviderGatewayBundle(
            selection: selection,
            descriptor: authority.descriptor,
            gateway: ModelGateway(
                catalog: authority.catalog,
                transport: router
            )
        )
    }

    static func hostedOpenCodeZenChatCompletions(
        modelID: ProviderModelID,
        credential: String
    ) throws -> AgentProductionProviderGatewayBundle {
        try hostedOpenCodeZenChatCompletions(
            selection: .hostedOpenCodeZenChatCompletions(modelID: modelID),
            credential: credential
        )
    }

    static func hostedOpenCodeZenChatCompletions(
        selection: AgentProductionProviderRouteSelection,
        credential: String
    ) throws -> AgentProductionProviderGatewayBundle {
        guard selection.lane == .hostedOpenCodeZenChatCompletions else {
            throw AgentProductionProviderGatewayError.selectionLaneMismatch(
                expected: .hostedOpenCodeZenChatCompletions,
                actual: selection.lane
            )
        }
        try validateHostedCredential(credential)
        let authority = try OpenCodeZenAuthority(modelID: selection.modelID)
        guard selection.declaredDescriptor == authority.descriptor else {
            throw AgentProductionProviderGatewayError
                .selectionDescriptorMismatch
        }
        let transport = AgentHostedProviderTransport(
            credential: credential,
            singleCallToolsCapability: authority.capability
        )
        let router = try AgentProviderTransportRouter(bindings: [
            .init(descriptor: authority.descriptor, transport: transport),
        ])
        return AgentProductionProviderGatewayBundle(
            selection: selection,
            descriptor: authority.descriptor,
            gateway: ModelGateway(
                catalog: authority.catalog,
                transport: router
            )
        )
    }

    static func hostedOpenAIChatCompletions(
        modelID: ProviderModelID,
        credential: String
    ) throws -> AgentProductionProviderGatewayBundle {
        try hostedOpenAIChatCompletions(
            selection: .hostedOpenAIChatCompletions(modelID: modelID),
            credential: credential
        )
    }

    static func hostedOpenAIChatCompletions(
        selection: AgentProductionProviderRouteSelection,
        credential: String
    ) throws -> AgentProductionProviderGatewayBundle {
        guard selection.lane == .hostedOpenAIChatCompletions else {
            throw AgentProductionProviderGatewayError.selectionLaneMismatch(
                expected: .hostedOpenAIChatCompletions,
                actual: selection.lane
            )
        }
        try validateHostedCredential(credential)

        let authority = try HostedAuthority(modelID: selection.modelID)
        guard selection.declaredDescriptor == authority.descriptor else {
            throw AgentProductionProviderGatewayError
                .selectionDescriptorMismatch
        }

        // The credential is handed directly to the sealed transport and is
        // neither copied into the bundle nor included in an error value.
        let transport = AgentHostedProviderTransport(
            credential: credential,
            singleCallToolsCapability: authority.capability
        )
        let router = try AgentProviderTransportRouter(bindings: [
            .init(
                descriptor: authority.descriptor,
                transport: transport
            ),
        ])
        return AgentProductionProviderGatewayBundle(
            selection: selection,
            descriptor: authority.descriptor,
            gateway: ModelGateway(
                catalog: authority.catalog,
                transport: router
            )
        )
    }

    #if DEBUG
    /// Canonical-route test seam used only by simulator/UI-test launch
    /// fixtures. The trusted catalog, descriptor, model, and engine remain
    /// production-owned; only the sealed network transport is substituted.
    static func debugHostedOpenAIChatCompletions(
        selection: AgentProductionProviderRouteSelection,
        transport: any ProviderTransport
    ) throws -> AgentProductionProviderGatewayBundle {
        guard selection.lane == .hostedOpenAIChatCompletions else {
            throw AgentProductionProviderGatewayError.selectionLaneMismatch(
                expected: .hostedOpenAIChatCompletions,
                actual: selection.lane
            )
        }
        let authority = try HostedAuthority(modelID: selection.modelID)
        guard selection.declaredDescriptor == authority.descriptor else {
            throw AgentProductionProviderGatewayError
                .selectionDescriptorMismatch
        }
        let router = try AgentProviderTransportRouter(bindings: [
            .init(descriptor: authority.descriptor, transport: transport),
        ])
        return AgentProductionProviderGatewayBundle(
            selection: selection,
            descriptor: authority.descriptor,
            gateway: ModelGateway(
                catalog: authority.catalog,
                transport: router
            )
        )
    }
    #endif

    static func localTextOnly(
        modelID: ProviderModelID
    ) throws -> AgentProductionProviderGatewayBundle {
        try localTextOnly(selection: .localTextOnly(modelID: modelID))
    }

    static func localTextOnly(
        selection: AgentProductionProviderRouteSelection
    ) throws -> AgentProductionProviderGatewayBundle {
        try localTextOnly(
            selection: selection,
            transport: AgentLocalModelProviderTransport()
        )
    }

    static func localTextOnly(
        selection: AgentProductionProviderRouteSelection,
        inference: any AgentLocalModelInferenceStreaming
    ) throws -> AgentProductionProviderGatewayBundle {
        try localTextOnly(
            selection: selection,
            transport: AgentLocalModelProviderTransport(inference: inference)
        )
    }

    private static func localTextOnly(
        selection: AgentProductionProviderRouteSelection,
        transport: AgentLocalModelProviderTransport
    ) throws -> AgentProductionProviderGatewayBundle {
        guard selection.lane == .localTextOnly else {
            throw AgentProductionProviderGatewayError.selectionLaneMismatch(
                expected: .localTextOnly,
                actual: selection.lane
            )
        }

        let authority = try LocalAuthority(modelID: selection.modelID)
        guard selection.declaredDescriptor == authority.descriptor else {
            throw AgentProductionProviderGatewayError
                .selectionDescriptorMismatch
        }
        let router = try AgentProviderTransportRouter(bindings: [
            .init(
                descriptor: authority.descriptor,
                transport: transport
            ),
        ])
        return AgentProductionProviderGatewayBundle(
            selection: selection,
            descriptor: authority.descriptor,
            gateway: ModelGateway(
                catalog: authority.catalog,
                transport: router
            )
        )
    }

    private static func validateHostedCredential(
        _ credential: String
    ) throws {
        guard (1 ... 4_096).contains(credential.utf8.count),
              credential.unicodeScalars.allSatisfy({
                  (0x21 ... 0x7e).contains($0.value)
              })
        else {
            throw AgentProductionProviderGatewayError
                .invalidHostedCredential
        }
    }
}

private struct OpenAICodexAuthority: Sendable {
    let catalog: ProviderAdapterCatalog
    let descriptor: ProviderAdapterDescriptor
    let capability: HostedSingleCallToolsProviderCapability

    init(modelID: ProviderModelID) throws {
        let trusted = TrustedHostedProviderCatalog.openAICodexResponses(
            model: modelID,
            capabilities: .hostedResponsesSingleCallToolsBaseline
        )
        let catalog = try trusted.providerCatalog()
        let adapterID = trusted.adapterID
        let descriptor = try catalog.adapter(id: adapterID).descriptor
        let capability = try trusted.hostedSingleCallToolsCapability(
            adapterID: adapterID
        )
        let snapshot = capability.snapshot
        let route = descriptor.route
        guard route.providerID == ProviderID(rawValue: "openai-codex"),
              route.modelID == modelID,
              route.adapterID == ProviderAdapterID(
                  rawValue: "openai-codex-responses"
              ),
              route.capabilities == .hostedResponsesSingleCallToolsBaseline,
              route.deployment == .hostedService,
              route.provenance == .builtInOpenAICodexResponses,
              descriptor.dialect == .openAIResponses,
              descriptor.requestPath == "/codex/responses",
              snapshot.providerID == route.providerID,
              snapshot.modelID == route.modelID,
              snapshot.adapterID == route.adapterID,
              snapshot.capabilities == route.capabilities,
              snapshot.deployment == route.deployment,
              snapshot.provenance == route.provenance,
              snapshot.maximumToolDefinitions == 20,
              snapshot.maximumToolCallsPerTurn == 1,
              !snapshot.parallelToolDispatchEnabled
        else {
            throw AgentProductionProviderGatewayError
                .hostedAuthorityMismatch
        }
        self.catalog = catalog
        self.descriptor = descriptor
        self.capability = capability
    }
}

private struct OpenCodeZenAuthority: Sendable {
    let catalog: ProviderAdapterCatalog
    let descriptor: ProviderAdapterDescriptor
    let capability: HostedSingleCallToolsProviderCapability

    init(modelID: ProviderModelID) throws {
        let trusted = TrustedHostedProviderCatalog
            .openCodeZenChatCompletions(
                model: modelID,
                capabilities: .hostedChatSingleCallToolsBaseline
            )
        let catalog = try trusted.providerCatalog()
        let adapterID = trusted.adapterID
        let descriptor = try catalog.adapter(id: adapterID).descriptor
        let capability = try trusted.hostedSingleCallToolsCapability(
            adapterID: adapterID
        )
        let snapshot = capability.snapshot
        let route = descriptor.route
        guard route.providerID == ProviderID(rawValue: "opencode-zen"),
              route.modelID == modelID,
              route.adapterID == ProviderAdapterID(
                  rawValue: "opencode-zen-chat-completions"
              ),
              route.capabilities == .hostedChatSingleCallToolsBaseline,
              route.deployment == .hostedService,
              route.provenance == .builtInOpenCodeZenChatCompletions,
              descriptor.dialect == .openAIChatCompletions,
              descriptor.requestPath == "/zen/v1/chat/completions",
              snapshot.providerID == route.providerID,
              snapshot.modelID == route.modelID,
              snapshot.adapterID == route.adapterID,
              snapshot.capabilities == route.capabilities,
              snapshot.deployment == route.deployment,
              snapshot.provenance == route.provenance,
              snapshot.maximumToolDefinitions == 20,
              snapshot.maximumToolCallsPerTurn == 1,
              !snapshot.parallelToolDispatchEnabled
        else {
            throw AgentProductionProviderGatewayError
                .hostedAuthorityMismatch
        }
        self.catalog = catalog
        self.descriptor = descriptor
        self.capability = capability
    }
}

private struct HostedAuthority: Sendable {
    let catalog: ProviderAdapterCatalog
    let descriptor: ProviderAdapterDescriptor
    let capability: HostedSingleCallToolsProviderCapability

    init(modelID: ProviderModelID) throws {
        let trusted = TrustedHostedProviderCatalog.openAIChatCompletions(
            model: modelID,
            capabilities: .hostedChatSingleCallToolsBaseline
        )
        let catalog = try trusted.providerCatalog()
        let adapterID = trusted.adapterID
        let descriptor = try catalog.adapter(id: adapterID).descriptor
        let capability = try trusted.hostedSingleCallToolsCapability(
            adapterID: adapterID
        )
        let snapshot = capability.snapshot
        let route = descriptor.route

        guard modelID == route.modelID,
              route.providerID == ProviderID(rawValue: "openai"),
              route.adapterID == ProviderAdapterID(
                  rawValue: "openai-chat-completions"
              ),
              route.capabilities == .hostedChatSingleCallToolsBaseline,
              route.deployment == .hostedService,
              route.provenance == .builtInOpenAIChatCompletions,
              descriptor.dialect == .openAIChatCompletions,
              descriptor.requestPath == "/v1/chat/completions",
              !route.capabilities.features.contains(.responseContinuation),
              !route.capabilities.features.contains(.parallelToolCalls),
              snapshot.providerID == route.providerID,
              snapshot.modelID == route.modelID,
              snapshot.adapterID == route.adapterID,
              snapshot.dialect == descriptor.dialect,
              snapshot.requestPath == descriptor.requestPath,
              snapshot.capabilities == route.capabilities,
              snapshot.deployment == route.deployment,
              snapshot.provenance == route.provenance,
              snapshot.maximumToolDefinitions == 20,
              snapshot.maximumToolCallsPerTurn == 1,
              !snapshot.parallelToolDispatchEnabled,
              Self.isCanonicalSHA256(snapshot.descriptorSHA256)
        else {
            throw AgentProductionProviderGatewayError
                .hostedAuthorityMismatch
        }

        self.catalog = catalog
        self.descriptor = descriptor
        self.capability = capability
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 71 && value.hasPrefix("sha256:") &&
            value.utf8.dropFirst(7).allSatisfy { byte in
                (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
            }
    }
}

private struct LocalAuthority: Sendable {
    let catalog: ProviderAdapterCatalog
    let descriptor: ProviderAdapterDescriptor

    init(modelID: ProviderModelID) throws {
        guard let variant = LocalModelCatalog.variant(
            for: modelID.rawValue
        ) else {
            throw AgentProductionProviderGatewayError
                .unavailableLocalModel(modelID)
        }
        let contextWindowTokens = UInt64(variant.contextTokens)
        guard let maximumOutputTokens = UInt64(
            exactly: variant.maxNewTokens
        ) else {
            throw AgentProductionProviderGatewayError
                .localAuthorityMismatch
        }
        let trusted = try TrustedLocalProviderCatalog.textOnly(
            modelID: modelID,
            contextWindowTokens: contextWindowTokens,
            maximumOutputTokens: maximumOutputTokens
        )
        let catalog = try trusted.providerCatalog()
        let descriptor = try catalog.adapter(
            id: trusted.adapterID
        ).descriptor
        let route = descriptor.route
        let expectedCapabilities = ProviderModelCapabilities(
            features: ProviderCapabilitySet([
                .cancellation,
                .streaming,
                .temperature,
                .usageStreaming,
            ]),
            contextWindowTokens: contextWindowTokens,
            maximumOutputTokens: maximumOutputTokens,
            maximumToolDefinitions: 0,
            maximumToolCallsPerTurn: 0
        )

        guard route.providerID == ProviderID(
                  rawValue: "novaforge-local"
              ),
              route.modelID == modelID,
              route.adapterID == ProviderAdapterID(
                  rawValue: "novaforge-local-llama"
              ),
              route.capabilities == expectedCapabilities,
              !route.capabilities.features.contains(.tools),
              !route.capabilities.features.contains(.typedToolArguments),
              !route.capabilities.features.contains(.strictToolSchema),
              route.capabilities.maximumToolDefinitions == 0,
              route.capabilities.maximumToolCallsPerTurn == 0,
              route.deployment == .onDevice,
              route.provenance == .builtInLocalModel,
              descriptor.dialect == .openAICompatibleChat,
              descriptor.requestPath == "/v1/local/chat/completions"
        else {
            throw AgentProductionProviderGatewayError
                .localAuthorityMismatch
        }

        self.catalog = catalog
        self.descriptor = descriptor
    }
}

/// Package-validated authority for the deterministic on-device agent lane.
/// The GGUF embeds its tokenizer; the route binds that exact verified artifact,
/// the prompt/context contract, the deterministic planner grammar, and the
/// compact canonical registry before any local tool call can be emitted.
struct LocalToolsAuthority: Sendable {
    let catalog: ProviderAdapterCatalog
    let descriptor: ProviderAdapterDescriptor
    let capability: LocalModelSingleCallToolsProviderCapability
    let toolRegistry: ToolRegistry

    init(modelID: ProviderModelID) throws {
        guard let variant = LocalModelCatalog.variant(for: modelID.rawValue),
              let maximumOutputTokens = UInt64(exactly: variant.maxNewTokens)
        else {
            throw AgentProductionProviderGatewayError
                .unavailableLocalModel(modelID)
        }
        let contextWindowTokens = UInt64(variant.contextTokens)
        let registry = try SandboxToolCatalog.localAgentRegistry()
        let registryBinding = try TrustedLocalProviderCatalog
            .canonicalToolRegistryBinding(for: registry)
        let modelDigest = "sha256:\(variant.expectedSHA256)"
        let promptDigest = Self.digest(LocalAgentModelGrammar.routerPrompt)
        let contextDigest = Self.digest(
            "model=\(variant.id)\ncontext=\(variant.contextTokens)\noutput=\(variant.maxNewTokens)\nbatch=\(variant.batchTokens)\n"
        )
        let grammarDigest = Self.digest(LocalAgentModelGrammar.gbnf)
        let verification = try LocalModelArtifactVerification(
            modelArtifactSHA256: modelDigest,
            // Qwen's tokenizer and tool-call chat template are embedded in the
            // exact verified GGUF.
            tokenizerSHA256: modelDigest,
            promptTemplateSHA256: promptDigest,
            contextConfigurationSHA256: contextDigest,
            grammarSHA256: grammarDigest,
            grammarCompilerID: LocalAgentModelGrammar.compilerID,
            grammarCompilerVersion: LocalAgentModelGrammar.compilerVersion
        )
        let adapterID = ProviderAdapterID(rawValue: "novaforge-local-llama")
        let attestation = try LocalModelSingleCallToolsAttestation(
            modelArtifactSHA256: verification.modelArtifactSHA256,
            tokenizerSHA256: verification.tokenizerSHA256,
            promptTemplateSHA256: verification.promptTemplateSHA256,
            contextConfigurationSHA256:
                verification.contextConfigurationSHA256,
            grammarSHA256: verification.grammarSHA256,
            grammarCompilerID: verification.grammarCompilerID,
            grammarCompilerVersion: verification.grammarCompilerVersion,
            canonicalToolRegistrySHA256:
                registryBinding.providerDefinitionsSHA256,
            toolDefinitionCount: registryBinding.toolDefinitionCount,
            modelID: modelID,
            adapterID: adapterID,
            contextWindowTokens: contextWindowTokens,
            maximumOutputTokens: maximumOutputTokens
        )
        let trusted = try TrustedLocalProviderCatalog
            .grammarConstrainedSingleCall(
                modelID: modelID,
                adapterID: adapterID,
                contextWindowTokens: contextWindowTokens,
                maximumOutputTokens: maximumOutputTokens,
                verifiedArtifacts: verification,
                attestation: attestation,
                toolRegistry: registry
            )
        let catalog = try trusted.providerCatalog()
        let descriptor = try catalog.adapter(id: adapterID).descriptor
        let capability = try trusted.localSingleCallToolsCapability(
            adapterID: adapterID
        )
        let route = descriptor.route
        let snapshot = capability.snapshot
        guard route.providerID == ProviderID(rawValue: "novaforge-local"),
              route.modelID == modelID,
              route.adapterID == adapterID,
              route.deployment == .onDevice,
              route.provenance == .builtInLocalModel,
              descriptor.dialect == .openAICompatibleChat,
              descriptor.requestPath == "/v1/local/chat/completions",
              route.capabilities.features.contains(.tools),
              route.capabilities.features.contains(.typedToolArguments),
              route.capabilities.features.contains(.strictToolSchema),
              !route.capabilities.features.contains(.parallelToolCalls),
              snapshot.maximumToolDefinitions ==
                registryBinding.toolDefinitionCount,
              snapshot.maximumToolCallsPerTurn == 1,
              !snapshot.parallelToolDispatchEnabled,
              snapshot.attestation == attestation
        else {
            throw AgentProductionProviderGatewayError.localAuthorityMismatch
        }
        self.catalog = catalog
        self.descriptor = descriptor
        self.capability = capability
        toolRegistry = registry
    }

    private static func digest(_ value: String) -> String {
        let bytes = SHA256.hash(data: Data(value.utf8))
        return "sha256:" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

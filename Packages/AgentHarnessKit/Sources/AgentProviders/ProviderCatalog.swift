import Foundation

public enum ProviderCatalogFailure: Error, Equatable, Sendable {
    case duplicateAdapter(ProviderAdapterID)
    case unknownAdapter(ProviderAdapterID)
    case noCompatibleRoute(ProviderCapabilitySet)
}

/// Immutable provider registry and deterministic capability negotiation.
public struct ProviderAdapterCatalog: Sendable {
    private let orderedIDs: [ProviderAdapterID]
    private let adapters: [ProviderAdapterID: any ProviderAdapter]

    public init(_ adapters: [any ProviderAdapter]) throws {
        var orderedIDs: [ProviderAdapterID] = []
        var indexed: [ProviderAdapterID: any ProviderAdapter] = [:]
        for adapter in adapters {
            let id = adapter.descriptor.route.adapterID
            guard indexed[id] == nil else {
                throw ProviderCatalogFailure.duplicateAdapter(id)
            }
            orderedIDs.append(id)
            indexed[id] = adapter
        }
        self.orderedIDs = orderedIDs
        self.adapters = indexed
    }

    public func adapter(id: ProviderAdapterID) throws -> any ProviderAdapter {
        guard let adapter = adapters[id] else {
            throw ProviderCatalogFailure.unknownAdapter(id)
        }
        return adapter
    }

    /// Returns every compatible adapter in caller preference order, followed
    /// by remaining compatible catalog routes in registration order.
    public func negotiate(
        preferredAdapterIDs: [ProviderAdapterID],
        requiredCapabilities: ProviderCapabilitySet
    ) throws -> [any ProviderAdapter] {
        try negotiate(
            preferredAdapterIDs: preferredAdapterIDs,
            requirements: ProviderCapabilityRequirements(features: requiredCapabilities)
        )
    }

    public func negotiate(
        preferredAdapterIDs: [ProviderAdapterID],
        requirements: ProviderCapabilityRequirements
    ) throws -> [any ProviderAdapter] {
        var result: [any ProviderAdapter] = []
        var seen: Set<ProviderAdapterID> = []
        let candidates = preferredAdapterIDs + orderedIDs
        for id in candidates where seen.insert(id).inserted {
            guard let adapter = adapters[id] else {
                if preferredAdapterIDs.contains(id) {
                    throw ProviderCatalogFailure.unknownAdapter(id)
                }
                continue
            }
            if adapter.descriptor.route.capabilities.supports(requirements) {
                result.append(adapter)
            }
        }
        guard !result.isEmpty else {
            throw ProviderCatalogFailure.noCompatibleRoute(requirements.features)
        }
        return result
    }
}

/// Package-sealed provenance for hosted routes that may mint canary authority.
/// A caller-created `ProviderAdapterCatalog` remains useful for negotiation and
/// dispatch, but deliberately cannot be upgraded into this type.
public struct TrustedHostedProviderCatalog: Sendable {
    private let adapter: any ProviderAdapter
    private let authority: TrustedHostedRouteAuthority

    private init(
        adapter: any ProviderAdapter,
        authority: TrustedHostedRouteAuthority
    ) {
        self.adapter = adapter
        self.authority = authority
    }

    public static func openAIChatCompletions(
        model: ProviderModelID,
        capabilities: ProviderModelCapabilities = .hostedChatTextOnlyBaseline
    ) -> Self {
        Self(
            adapter: OpenAIChatCompletionsAdapter(
                model: model,
                capabilities: capabilities
            ),
            authority: .builtInOpenAIChatCompletions
        )
    }

    public static func openAIResponses(
        model: ProviderModelID,
        capabilities: ProviderModelCapabilities = .hostedResponsesTextOnlyBaseline
    ) -> Self {
        Self(
            adapter: OpenAIResponsesAdapter(
                model: model,
                capabilities: capabilities
            ),
            authority: .builtInOpenAIResponses
        )
    }

    public static func openCodeZenChatCompletions(
        model: ProviderModelID,
        capabilities: ProviderModelCapabilities = .hostedChatTextOnlyBaseline
    ) -> Self {
        Self(
            adapter: OpenCodeZenChatCompletionsAdapter(
                model: model,
                capabilities: capabilities
            ),
            authority: .builtInOpenCodeZenChatCompletions
        )
    }

    public static func openAICodexResponses(
        model: ProviderModelID,
        capabilities: ProviderModelCapabilities = .hostedResponsesTextOnlyBaseline
    ) -> Self {
        Self(
            adapter: OpenAICodexResponsesAdapter(
                model: model,
                capabilities: capabilities
            ),
            authority: .builtInOpenAICodexResponses
        )
    }

    /// Produces the ordinary dispatch catalog for the exact trusted adapter.
    /// The returned value does not itself retain capability-minting authority.
    public func providerCatalog() throws -> ProviderAdapterCatalog {
        try ProviderAdapterCatalog([adapter])
    }

    /// Mints a non-dispatching capability only after revalidating the exact
    /// package-owned hosted route and its text-only, zero-tool feature floor.
    public func hostedTextOnlyCapability(
        adapterID: ProviderAdapterID
    ) throws -> HostedTextOnlyProviderCapability {
        guard adapter.descriptor.route.adapterID == adapterID else {
            throw ProviderCatalogFailure.unknownAdapter(adapterID)
        }
        return HostedTextOnlyProviderCapability(
            snapshot: try adapter.descriptor.validatedHostedTextOnlySnapshot(
                expectedDeployment: .hostedService,
                expectedProvenance: authority.provenance
            )
        )
    }

    /// Mints authority for a bounded, single-call, non-parallel read-tool
    /// route. This is separate from text-only authority and revalidates the
    /// package-owned OpenAI identity, provenance, dialect, path, and strict
    /// typed-tool capability floor at the minting boundary.
    public func hostedReadOnlyToolsCapability(
        adapterID: ProviderAdapterID
    ) throws -> HostedReadOnlyToolsProviderCapability {
        guard adapter.descriptor.route.adapterID == adapterID else {
            throw ProviderCatalogFailure.unknownAdapter(adapterID)
        }
        return HostedReadOnlyToolsProviderCapability(
            snapshot: try adapter.descriptor.validatedHostedReadOnlyToolsSnapshot(
                expectedDeployment: .hostedService,
                expectedProvenance: authority.provenance
            )
        )
    }

    /// Mints wire authority for the production canonical tool registry. The
    /// capability is deliberately limited to one strict typed call per turn;
    /// the app transport must still compare every definition to its frozen
    /// registry and the engine remains the only route to policy/effects.
    public func hostedSingleCallToolsCapability(
        adapterID: ProviderAdapterID
    ) throws -> HostedSingleCallToolsProviderCapability {
        guard adapter.descriptor.route.adapterID == adapterID else {
            throw ProviderCatalogFailure.unknownAdapter(adapterID)
        }
        return HostedSingleCallToolsProviderCapability(
            snapshot:
                try adapter.descriptor
                    .validatedHostedSingleCallToolsSnapshot(
                        expectedDeployment: .hostedService,
                        expectedProvenance: authority.provenance
                    )
        )
    }

    public var adapterID: ProviderAdapterID {
        adapter.descriptor.route.adapterID
    }
}

/// Package-sealed source for trusted on-device routes. Text-only construction
/// remains conservative; grammar tools require the separately attested factory
/// that binds verified artifacts, compiler, route, limits, and ToolRegistry.
public struct TrustedLocalProviderCatalog: Sendable {
    let adapter: LocalModelAdapter
    let singleCallToolsSnapshot: LocalModelSingleCallToolsRouteSnapshot?

    init(
        adapter: LocalModelAdapter,
        singleCallToolsSnapshot: LocalModelSingleCallToolsRouteSnapshot?
    ) {
        self.adapter = adapter
        self.singleCallToolsSnapshot = singleCallToolsSnapshot
    }

    public static func textOnly(
        modelID: ProviderModelID,
        adapterID: ProviderAdapterID = .init(rawValue: "novaforge-local-llama"),
        contextWindowTokens: UInt64 = ProviderModelCapabilities.localTextBaseline.contextWindowTokens,
        maximumOutputTokens: UInt64 = ProviderModelCapabilities.localTextBaseline.maximumOutputTokens
    ) throws -> Self {
        Self(
            adapter: try LocalModelAdapter(configuration: .init(
                adapterID: adapterID,
                modelID: modelID,
                contextWindowTokens: contextWindowTokens,
                maximumOutputTokens: maximumOutputTokens,
                toolMode: .textOnly
            )),
            singleCallToolsSnapshot: nil
        )
    }

    public func providerCatalog() throws -> ProviderAdapterCatalog {
        try ProviderAdapterCatalog([adapter])
    }

    public var adapterID: ProviderAdapterID {
        adapter.descriptor.route.adapterID
    }

    public var descriptor: ProviderAdapterDescriptor {
        adapter.descriptor
    }
}

private enum TrustedHostedRouteAuthority: Sendable {
    case builtInOpenAIChatCompletions
    case builtInOpenAIResponses
    case builtInOpenAICodexResponses
    case builtInOpenCodeZenChatCompletions

    var provenance: ProviderRouteProvenance {
        switch self {
        case .builtInOpenAIChatCompletions:
            .builtInOpenAIChatCompletions
        case .builtInOpenAIResponses:
            .builtInOpenAIResponses
        case .builtInOpenAICodexResponses:
            .builtInOpenAICodexResponses
        case .builtInOpenCodeZenChatCompletions:
            .builtInOpenCodeZenChatCompletions
        }
    }
}

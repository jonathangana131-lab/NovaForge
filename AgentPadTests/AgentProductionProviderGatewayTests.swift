import AgentProviders
import AgentTools
import XCTest
@testable import NovaForge

final class AgentProductionProviderGatewayTests: XCTestCase {
    func testHostedCompositionIsExactChatSingleCallToolsAuthority()
        throws
    {
        let modelID = ProviderModelID(rawValue: "gpt-5.2")
        let selection = try AgentProductionProviderRouteSelection
            .hostedOpenAIChatCompletions(modelID: modelID)
        let bundle = try AgentProductionProviderGatewayFactory
            .hostedOpenAIChatCompletions(
                selection: selection,
                credential: "sk-test-composition-only"
            )

        XCTAssertEqual(bundle.selection, selection)
        XCTAssertEqual(bundle.descriptor, selection.declaredDescriptor)
        XCTAssertEqual(bundle.adapterID.rawValue, "openai-chat-completions")
        XCTAssertEqual(bundle.route.providerID.rawValue, "openai")
        XCTAssertEqual(bundle.route.modelID, modelID)
        XCTAssertEqual(bundle.route.deployment, .hostedService)
        XCTAssertEqual(
            bundle.route.provenance,
            .builtInOpenAIChatCompletions
        )
        XCTAssertEqual(bundle.descriptor.dialect, .openAIChatCompletions)
        XCTAssertEqual(
            bundle.descriptor.requestPath,
            "/v1/chat/completions"
        )
        XCTAssertEqual(
            bundle.route.capabilities,
            .hostedChatSingleCallToolsBaseline
        )
        XCTAssertTrue(bundle.route.capabilities.features.contains(.tools))
        XCTAssertTrue(
            bundle.route.capabilities.features.contains(.typedToolArguments)
        )
        XCTAssertTrue(
            bundle.route.capabilities.features.contains(.strictToolSchema)
        )
        XCTAssertFalse(
            bundle.route.capabilities.features.contains(.parallelToolCalls)
        )
        XCTAssertFalse(
            bundle.route.capabilities.features.contains(.responseContinuation)
        )
        XCTAssertEqual(bundle.route.capabilities.maximumToolDefinitions, 20)
        XCTAssertEqual(bundle.route.capabilities.maximumToolCallsPerTurn, 1)
        _ = try bundle.modelGateway(for: selection)
    }

    func testLocalCompositionUsesShippedVariantLimitsAndIsTextOnly()
        throws
    {
        let variant = LocalModelCatalog.all[0]
        let modelID = ProviderModelID(rawValue: variant.id)
        let selection = try AgentProductionProviderRouteSelection
            .localTextOnly(modelID: modelID)
        let bundle = try AgentProductionProviderGatewayFactory.localTextOnly(
            selection: selection
        )

        XCTAssertEqual(bundle.selection, selection)
        XCTAssertEqual(bundle.adapterID.rawValue, "novaforge-local-llama")
        XCTAssertEqual(bundle.route.providerID.rawValue, "novaforge-local")
        XCTAssertEqual(bundle.route.modelID, modelID)
        XCTAssertEqual(bundle.route.deployment, .onDevice)
        XCTAssertEqual(bundle.route.provenance, .builtInLocalModel)
        XCTAssertEqual(bundle.descriptor.dialect, .openAICompatibleChat)
        XCTAssertEqual(
            bundle.descriptor.requestPath,
            "/v1/local/chat/completions"
        )
        XCTAssertEqual(
            bundle.route.capabilities.contextWindowTokens,
            UInt64(variant.contextTokens)
        )
        XCTAssertEqual(
            bundle.route.capabilities.maximumOutputTokens,
            UInt64(variant.maxNewTokens)
        )
        XCTAssertFalse(bundle.route.capabilities.features.contains(.tools))
        XCTAssertFalse(
            bundle.route.capabilities.features.contains(.typedToolArguments)
        )
        XCTAssertFalse(
            bundle.route.capabilities.features.contains(.strictToolSchema)
        )
        XCTAssertEqual(bundle.route.capabilities.maximumToolDefinitions, 0)
        XCTAssertEqual(bundle.route.capabilities.maximumToolCallsPerTurn, 0)
        _ = try bundle.modelGateway(for: selection)
    }

    func testLocalAgentCompositionBindsCompactAttestedToolAuthority()
        throws
    {
        let variant = LocalModelCatalog.all[0]
        let modelID = ProviderModelID(rawValue: variant.id)
        let selection = try AgentProductionProviderRouteSelection
            .localSingleCallTools(modelID: modelID)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NovaForgeLocalGateway-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try AgentProductionProviderGatewayFactory
            .localSingleCallTools(
                selection: selection,
                workspace: SandboxWorkspace(rootURL: root)
            )

        XCTAssertEqual(bundle.selection, selection)
        XCTAssertEqual(bundle.route.deployment, .onDevice)
        XCTAssertEqual(bundle.route.provenance, .builtInLocalModel)
        XCTAssertTrue(bundle.route.capabilities.features.contains(.tools))
        XCTAssertTrue(bundle.route.capabilities.features.contains(
            .typedToolArguments
        ))
        XCTAssertTrue(bundle.route.capabilities.features.contains(
            .strictToolSchema
        ))
        XCTAssertFalse(bundle.route.capabilities.features.contains(
            .parallelToolCalls
        ))
        XCTAssertEqual(
            bundle.route.capabilities.maximumToolDefinitions,
            UInt32(SandboxToolCatalog.localAgentTools.count)
        )
        XCTAssertEqual(
            bundle.route.capabilities.maximumToolCallsPerTurn,
            1
        )
        _ = try bundle.modelGateway(for: selection)
    }

    func testHostedCompositionRejectsEmptyWhitespaceAndNonASCIISecrets()
        throws
    {
        let selection = try AgentProductionProviderRouteSelection
            .hostedOpenAIChatCompletions(
                modelID: ProviderModelID(rawValue: "gpt-5.2")
            )
        for credential in ["", " ", "line\nbreak", "sk-emoji-🔑"] {
            XCTAssertThrowsError(
                try AgentProductionProviderGatewayFactory
                    .hostedOpenAIChatCompletions(
                        selection: selection,
                        credential: credential
                    )
            ) { error in
                XCTAssertEqual(
                    error as? AgentProductionProviderGatewayError,
                    .invalidHostedCredential
                )
            }
        }
    }

    func testHostedCompositionRejectsWrongModelAdapterAndRouteEvidence()
        throws
    {
        let modelID = ProviderModelID(rawValue: "gpt-5.2")
        let trusted = try AgentProductionProviderRouteSelection
            .hostedOpenAIChatCompletions(modelID: modelID)
        let descriptor = trusted.declaredDescriptor
        let wrongModel = replacing(
            descriptor,
            modelID: ProviderModelID(rawValue: "gpt-hostile")
        )
        let wrongAdapter = replacing(
            descriptor,
            adapterID: ProviderAdapterID(rawValue: "openai-responses")
        )
        let wrongPath = replacing(
            descriptor,
            requestPath: "/v1/responses"
        )
        let wrongDialect = replacing(
            descriptor,
            dialect: .openAIResponses
        )
        let wrongRoute = replacing(
            descriptor,
            deployment: .callerManaged,
            provenance: .callerConfigured
        )

        for hostileDescriptor in [
            wrongModel,
            wrongAdapter,
            wrongPath,
            wrongDialect,
            wrongRoute,
        ] {
            let selection = AgentProductionProviderRouteSelection(
                lane: .hostedOpenAIChatCompletions,
                modelID: modelID,
                declaredDescriptor: hostileDescriptor
            )
            XCTAssertThrowsError(
                try AgentProductionProviderGatewayFactory
                    .hostedOpenAIChatCompletions(
                        selection: selection,
                        credential: "sk-test-composition-only"
                    )
            ) { error in
                XCTAssertEqual(
                    error as? AgentProductionProviderGatewayError,
                    .selectionDescriptorMismatch
                )
            }
        }
    }

    func testLocalCompositionRejectsWrongModelAdapterAndToolCapability()
        throws
    {
        let modelID = ProviderModelID(rawValue: LocalModelCatalog.all[0].id)
        let trusted = try AgentProductionProviderRouteSelection
            .localTextOnly(modelID: modelID)
        let descriptor = trusted.declaredDescriptor
        let wrongModel = replacing(
            descriptor,
            modelID: ProviderModelID(rawValue: LocalModelCatalog.all[1].id)
        )
        let wrongAdapter = replacing(
            descriptor,
            adapterID: ProviderAdapterID(
                rawValue: "openai-chat-completions"
            )
        )
        let toolsCapabilities = ProviderModelCapabilities(
            features: ProviderCapabilitySet([
                .cancellation,
                .streaming,
                .strictToolSchema,
                .temperature,
                .tools,
                .typedToolArguments,
                .usageStreaming,
            ]),
            contextWindowTokens: descriptor.route.capabilities
                .contextWindowTokens,
            maximumOutputTokens: descriptor.route.capabilities
                .maximumOutputTokens,
            maximumToolDefinitions: 20,
            maximumToolCallsPerTurn: 1
        )
        let fakeTools = replacing(
            descriptor,
            capabilities: toolsCapabilities
        )

        for hostileDescriptor in [wrongModel, wrongAdapter, fakeTools] {
            let selection = AgentProductionProviderRouteSelection(
                lane: .localTextOnly,
                modelID: modelID,
                declaredDescriptor: hostileDescriptor
            )
            XCTAssertThrowsError(
                try AgentProductionProviderGatewayFactory.localTextOnly(
                    selection: selection
                )
            ) { error in
                XCTAssertEqual(
                    error as? AgentProductionProviderGatewayError,
                    .selectionDescriptorMismatch
                )
            }
        }
    }

    func testMismatchedRouteSelectionAndBundleSelectionFailClosed()
        throws
    {
        let hosted = try AgentProductionProviderRouteSelection
            .hostedOpenAIChatCompletions(
                modelID: ProviderModelID(rawValue: "gpt-5.2")
            )
        let local = try AgentProductionProviderRouteSelection.localTextOnly(
            modelID: ProviderModelID(rawValue: LocalModelCatalog.all[0].id)
        )

        XCTAssertThrowsError(
            try AgentProductionProviderGatewayFactory
                .hostedOpenAIChatCompletions(
                    selection: local,
                    credential: "sk-test-composition-only"
                )
        ) { error in
            XCTAssertEqual(
                error as? AgentProductionProviderGatewayError,
                .selectionLaneMismatch(
                    expected: .hostedOpenAIChatCompletions,
                    actual: .localTextOnly
                )
            )
        }
        XCTAssertThrowsError(
            try AgentProductionProviderGatewayFactory.localTextOnly(
                selection: hosted
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentProductionProviderGatewayError,
                .selectionLaneMismatch(
                    expected: .localTextOnly,
                    actual: .hostedOpenAIChatCompletions
                )
            )
        }

        let bundle = try AgentProductionProviderGatewayFactory
            .hostedOpenAIChatCompletions(
                selection: hosted,
                credential: "sk-test-composition-only"
            )
        XCTAssertThrowsError(try bundle.modelGateway(for: local)) { error in
            XCTAssertEqual(
                error as? AgentProductionProviderGatewayError,
                .bundleSelectionMismatch
            )
        }
    }

    func testFreshRunPlanMustCarryTheBundlesExactRoute() throws {
        let selection = try AgentProductionProviderRouteSelection
            .hostedOpenAIChatCompletions(
                modelID: ProviderModelID(rawValue: "gpt-5.2")
            )
        let bundle = try AgentProductionProviderGatewayFactory
            .hostedOpenAIChatCompletions(
                selection: selection,
                credential: "sk-test-composition-only"
            )
        let exactPlan = freshRunPlan(route: bundle.route)
        _ = try bundle.modelGateway(
            for: selection,
            freshRunPlan: exactPlan
        )

        let wrongRoute = replacing(
            bundle.descriptor,
            modelID: ProviderModelID(rawValue: "gpt-hostile")
        ).route
        XCTAssertThrowsError(
            try bundle.modelGateway(
                for: selection,
                freshRunPlan: freshRunPlan(route: wrongRoute)
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentProductionProviderGatewayError,
                .freshRunPlanRouteMismatch
            )
        }
    }

    func testHostedAndLocalGatewaysRejectCrossRouting() async throws {
        let hostedSelection = try AgentProductionProviderRouteSelection
            .hostedOpenAIChatCompletions(
                modelID: ProviderModelID(rawValue: "gpt-5.2")
            )
        let localSelection = try AgentProductionProviderRouteSelection
            .localTextOnly(
                modelID: ProviderModelID(
                    rawValue: LocalModelCatalog.all[0].id
                )
            )
        let hostedBundle = try AgentProductionProviderGatewayFactory
            .hostedOpenAIChatCompletions(
                selection: hostedSelection,
                credential: "sk-test-composition-only"
            )
        let localBundle = try AgentProductionProviderGatewayFactory
            .localTextOnly(selection: localSelection)
        let hostedGateway = try hostedBundle.modelGateway(
            for: hostedSelection
        )
        let localGateway = try localBundle.modelGateway(for: localSelection)
        let requirements = ProviderCapabilityRequirements(
            features: ProviderCapabilitySet([.streaming])
        )

        do {
            _ = try await hostedGateway.negotiateRoutes(
                preferredAdapterIDs: [localBundle.adapterID],
                requirements: requirements
            )
            XCTFail("Hosted gateway accepted a local adapter")
        } catch {
            XCTAssertEqual(
                error as? ProviderCatalogFailure,
                .unknownAdapter(localBundle.adapterID)
            )
        }
        do {
            _ = try await localGateway.negotiateRoutes(
                preferredAdapterIDs: [hostedBundle.adapterID],
                requirements: requirements
            )
            XCTFail("Local gateway accepted a hosted adapter")
        } catch {
            XCTAssertEqual(
                error as? ProviderCatalogFailure,
                .unknownAdapter(hostedBundle.adapterID)
            )
        }
    }

    func testUnavailableLocalModelCannotBecomeATrustedRoute() {
        let modelID = ProviderModelID(rawValue: "unknown/local-model")
        XCTAssertThrowsError(
            try AgentProductionProviderRouteSelection.localTextOnly(
                modelID: modelID
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentProductionProviderGatewayError,
                .unavailableLocalModel(modelID)
            )
        }
    }

    func testRouteSelectionRoundTripsWithoutCredentialMaterial()
        throws
    {
        let selection = try AgentProductionProviderRouteSelection
            .hostedOpenAIChatCompletions(
                modelID: ProviderModelID(rawValue: "gpt-5.2")
            )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(selection)
        XCTAssertEqual(
            try JSONDecoder().decode(
                AgentProductionProviderRouteSelection.self,
                from: encoded
            ),
            selection
        )
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("credential"))
        XCTAssertFalse(text.contains("sk-"))
        XCTAssertFalse(text.contains("api.openai.com"))
        XCTAssertFalse(text.contains("/v1/responses"))
    }
}

private func replacing(
    _ descriptor: ProviderAdapterDescriptor,
    modelID: ProviderModelID? = nil,
    adapterID: ProviderAdapterID? = nil,
    capabilities: ProviderModelCapabilities? = nil,
    deployment: ProviderDeployment? = nil,
    provenance: ProviderRouteProvenance? = nil,
    dialect: ProviderAdapterDialect? = nil,
    requestPath: String? = nil
) -> ProviderAdapterDescriptor {
    ProviderAdapterDescriptor(
        route: ProviderRoute(
            providerID: descriptor.route.providerID,
            modelID: modelID ?? descriptor.route.modelID,
            adapterID: adapterID ?? descriptor.route.adapterID,
            capabilities: capabilities ?? descriptor.route.capabilities,
            deployment: deployment ?? descriptor.route.deployment,
            provenance: provenance ?? descriptor.route.provenance
        ),
        dialect: dialect ?? descriptor.dialect,
        requestPath: requestPath ?? descriptor.requestPath
    )
}

private func freshRunPlan(
    route: ProviderRoute
) -> AgentSystemFreshRunPlan {
    AgentSystemFreshRunPlan(
        providerRoute: route,
        providerOptions: ProviderGenerationOptions(
            maximumOutputTokens: min(
                1_024,
                route.capabilities.maximumOutputTokens
            ),
            temperature: 0,
            parallelToolCalls: false,
            toolChoice: route.capabilities.features.contains(.tools)
                ? .auto
                : .none
        ),
        systemInstruction: nil,
        developerInstruction: nil,
        toolLocalities: [:],
        policyVersion: "test-policy-v1",
        contextPreparationVersion: "test-context-v1"
    )
}

import AgentDomain
@testable import AgentProviders
import XCTest

final class HostedReadOnlyToolsCapabilityTests: XCTestCase {
    func testTrustedChatAndResponsesCatalogsMintSeparateBoundedCapabilities() throws {
        let chat = TrustedHostedProviderCatalog.openAIChatCompletions(
            model: ProviderModelID(rawValue: "chat-read-model"),
            capabilities: .hostedChatReadOnlyToolsCanaryBaseline
        )
        let chatCapability = try chat.hostedReadOnlyToolsCapability(
            adapterID: chat.adapterID
        )
        XCTAssertEqual(chatCapability.snapshot.providerID.rawValue, "openai")
        XCTAssertEqual(chatCapability.snapshot.dialect, .openAIChatCompletions)
        XCTAssertEqual(chatCapability.snapshot.requestPath, "/v1/chat/completions")
        XCTAssertEqual(chatCapability.snapshot.maximumToolDefinitions, 12)
        XCTAssertEqual(chatCapability.snapshot.maximumToolCallsPerTurn, 1)
        XCTAssertFalse(chatCapability.snapshot.parallelToolDispatchEnabled)
        XCTAssertTrue(chatCapability.snapshot.descriptorSHA256.hasPrefix("sha256:"))

        let responses = TrustedHostedProviderCatalog.openAIResponses(
            model: ProviderModelID(rawValue: "responses-read-model"),
            capabilities: .hostedResponsesReadOnlyToolsCanaryBaseline
        )
        let responsesCapability = try responses.hostedReadOnlyToolsCapability(
            adapterID: responses.adapterID
        )
        XCTAssertEqual(responsesCapability.snapshot.dialect, .openAIResponses)
        XCTAssertEqual(responsesCapability.snapshot.requestPath, "/v1/responses")
        XCTAssertTrue(
            responsesCapability.snapshot.capabilities.features.contains(.responseContinuation)
        )
        XCTAssertNotEqual(
            chatCapability.snapshot.descriptorSHA256,
            responsesCapability.snapshot.descriptorSHA256
        )
    }

    func testReadToolAndTextOnlyCapabilitiesCannotBeInterchanged() throws {
        let readCatalog = TrustedHostedProviderCatalog.openAIResponses(
            model: ProviderModelID(rawValue: "read-model"),
            capabilities: .hostedResponsesReadOnlyToolsCanaryBaseline
        )
        XCTAssertThrowsError(try readCatalog.hostedTextOnlyCapability(
            adapterID: readCatalog.adapterID
        )) { error in
            XCTAssertEqual(
                error as? HostedTextOnlyCapabilityError,
                .toolCapabilityPresent(.tools)
            )
        }

        let textCatalog = TrustedHostedProviderCatalog.openAIResponses(
            model: ProviderModelID(rawValue: "text-model"),
            capabilities: .hostedResponsesTextOnlyBaseline
        )
        XCTAssertThrowsError(try textCatalog.hostedReadOnlyToolsCapability(
            adapterID: textCatalog.adapterID
        )) { error in
            XCTAssertEqual(
                error as? HostedReadOnlyToolsCapabilityError,
                .requiredCapabilityMissing(.tools)
            )
        }
    }

    func testMintRejectsParallelAndNonSingleCallRoutes() throws {
        let parallel = capabilities(
            extraFeatures: [.parallelToolCalls],
            maximumToolCallsPerTurn: 1
        )
        let parallelCatalog = TrustedHostedProviderCatalog.openAIResponses(
            model: ProviderModelID(rawValue: "parallel-model"),
            capabilities: parallel
        )
        XCTAssertThrowsError(try parallelCatalog.hostedReadOnlyToolsCapability(
            adapterID: parallelCatalog.adapterID
        )) { error in
            XCTAssertEqual(
                error as? HostedReadOnlyToolsCapabilityError,
                .parallelToolCapabilityPresent
            )
        }

        for callLimit: UInt32 in [0, 2, 128] {
            let catalog = TrustedHostedProviderCatalog.openAIResponses(
                model: ProviderModelID(rawValue: "calls-\(callLimit)"),
                capabilities: capabilities(maximumToolCallsPerTurn: callLimit)
            )
            XCTAssertThrowsError(try catalog.hostedReadOnlyToolsCapability(
                adapterID: catalog.adapterID
            )) { error in
                XCTAssertEqual(
                    error as? HostedReadOnlyToolsCapabilityError,
                    .invalidToolCallLimit(callLimit)
                )
            }
        }
    }

    func testMintRejectsMissingStrictTypedCapabilityAndUnsafeLimits() throws {
        for missing: ProviderCapability in [.tools, .typedToolArguments, .strictToolSchema] {
            let catalog = TrustedHostedProviderCatalog.openAIResponses(
                model: ProviderModelID(rawValue: "missing-\(missing.rawValue)"),
                capabilities: capabilities(removing: missing)
            )
            XCTAssertThrowsError(try catalog.hostedReadOnlyToolsCapability(
                adapterID: catalog.adapterID
            )) { error in
                XCTAssertEqual(
                    error as? HostedReadOnlyToolsCapabilityError,
                    .requiredCapabilityMissing(missing)
                )
            }
        }

        for definitionLimit: UInt32 in [0, 129] {
            let catalog = TrustedHostedProviderCatalog.openAIResponses(
                model: ProviderModelID(rawValue: "definitions-\(definitionLimit)"),
                capabilities: capabilities(maximumToolDefinitions: definitionLimit)
            )
            XCTAssertThrowsError(try catalog.hostedReadOnlyToolsCapability(
                adapterID: catalog.adapterID
            )) { error in
                XCTAssertEqual(
                    error as? HostedReadOnlyToolsCapabilityError,
                    .invalidToolDefinitionLimit(definitionLimit)
                )
            }
        }
    }

    func testValidatorRejectsCallerConfiguredSpoofsAndRouteIdentityMismatches() throws {
        let callerSpoof = ProviderAdapterDescriptor(
            route: ProviderRoute(
                providerID: ProviderID(rawValue: "openai"),
                modelID: ProviderModelID(rawValue: "spoof"),
                adapterID: ProviderAdapterID(rawValue: "openai-responses"),
                capabilities: .hostedResponsesReadOnlyToolsCanaryBaseline,
                deployment: .callerManaged,
                provenance: .callerConfigured
            ),
            dialect: .openAIResponses,
            requestPath: "/v1/responses"
        )
        XCTAssertThrowsError(try callerSpoof.validatedHostedReadOnlyToolsSnapshot(
            expectedDeployment: .hostedService,
            expectedProvenance: .builtInOpenAIResponses
        )) { error in
            XCTAssertEqual(
                error as? HostedReadOnlyToolsCapabilityError,
                .untrustedDeployment(.callerManaged)
            )
        }

        let wrongPath = descriptor(requestPath: "/v1/chat/completions")
        XCTAssertThrowsError(try wrongPath.validatedHostedReadOnlyToolsSnapshot(
            expectedDeployment: .hostedService,
            expectedProvenance: .builtInOpenAIResponses
        )) { error in
            XCTAssertEqual(error as? HostedReadOnlyToolsCapabilityError, .invalidRequestPath)
        }

        let wrongProvider = descriptor(providerID: "lookalike-openai")
        XCTAssertThrowsError(try wrongProvider.validatedHostedReadOnlyToolsSnapshot(
            expectedDeployment: .hostedService,
            expectedProvenance: .builtInOpenAIResponses
        )) { error in
            XCTAssertEqual(
                error as? HostedReadOnlyToolsCapabilityError,
                .unexpectedProvider(ProviderID(rawValue: "lookalike-openai"))
            )
        }
    }

    func testChatCannotClaimResponsesContinuationOrNonTextModalities() throws {
        let continuation = ProviderModelCapabilities(
            features: ProviderModelCapabilities
                .hostedResponsesReadOnlyToolsCanaryBaseline.features,
            contextWindowTokens: 8_192,
            maximumOutputTokens: 1_024,
            maximumToolDefinitions: 12,
            maximumToolCallsPerTurn: 1
        )
        let chat = TrustedHostedProviderCatalog.openAIChatCompletions(
            model: ProviderModelID(rawValue: "lying-chat"),
            capabilities: continuation
        )
        XCTAssertThrowsError(try chat.hostedReadOnlyToolsCapability(
            adapterID: chat.adapterID
        )) { error in
            XCTAssertEqual(
                error as? HostedReadOnlyToolsCapabilityError,
                .dialectCapabilityMismatch(.responseContinuation)
            )
        }

        let reasoning = TrustedHostedProviderCatalog.openAIResponses(
            model: ProviderModelID(rawValue: "reasoning-read"),
            capabilities: capabilities(extraFeatures: [.reasoning])
        )
        XCTAssertThrowsError(try reasoning.hostedReadOnlyToolsCapability(
            adapterID: reasoning.adapterID
        )) { error in
            XCTAssertEqual(
                error as? HostedReadOnlyToolsCapabilityError,
                .nonTextCapabilityPresent(.reasoning)
            )
        }
    }
}

private func capabilities(
    removing: ProviderCapability? = nil,
    extraFeatures: [ProviderCapability] = [],
    maximumToolDefinitions: UInt32 = 12,
    maximumToolCallsPerTurn: UInt32 = 1
) -> ProviderModelCapabilities {
    var features = ProviderModelCapabilities
        .hostedResponsesReadOnlyToolsCanaryBaseline.features.values
    if let removing {
        features.removeAll { $0 == removing }
    }
    features.append(contentsOf: extraFeatures)
    return ProviderModelCapabilities(
        features: ProviderCapabilitySet(features),
        contextWindowTokens: 128_000,
        maximumOutputTokens: 16_384,
        maximumToolDefinitions: maximumToolDefinitions,
        maximumToolCallsPerTurn: maximumToolCallsPerTurn
    )
}

private func descriptor(
    providerID: String = "openai",
    requestPath: String = "/v1/responses"
) -> ProviderAdapterDescriptor {
    ProviderAdapterDescriptor(
        route: ProviderRoute(
            providerID: ProviderID(rawValue: providerID),
            modelID: ProviderModelID(rawValue: "descriptor-model"),
            adapterID: ProviderAdapterID(rawValue: "openai-responses"),
            capabilities: .hostedResponsesReadOnlyToolsCanaryBaseline,
            deployment: .hostedService,
            provenance: .builtInOpenAIResponses
        ),
        dialect: .openAIResponses,
        requestPath: requestPath
    )
}

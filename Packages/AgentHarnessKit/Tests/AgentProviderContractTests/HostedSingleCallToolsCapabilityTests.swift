import AgentDomain
@testable import AgentProviders
import XCTest

final class HostedSingleCallToolsCapabilityTests: XCTestCase {
    func testTrustedRoutesMintDistinctSingleCallToolAuthority() throws {
        let chat = TrustedHostedProviderCatalog.openAIChatCompletions(
            model: .init(rawValue: "chat-tools-model"),
            capabilities: .hostedChatSingleCallToolsBaseline
        )
        let chatCapability = try chat.hostedSingleCallToolsCapability(
            adapterID: chat.adapterID
        )
        XCTAssertEqual(chatCapability.snapshot.providerID.rawValue, "openai")
        XCTAssertEqual(
            chatCapability.snapshot.dialect,
            .openAIChatCompletions
        )
        XCTAssertEqual(chatCapability.snapshot.maximumToolDefinitions, 20)
        XCTAssertEqual(chatCapability.snapshot.maximumToolCallsPerTurn, 1)
        XCTAssertFalse(
            chatCapability.snapshot.parallelToolDispatchEnabled
        )
        XCTAssertTrue(
            chatCapability.snapshot.descriptorSHA256.hasPrefix("sha256:")
        )

        let responses = TrustedHostedProviderCatalog.openAIResponses(
            model: .init(rawValue: "responses-tools-model"),
            capabilities: .hostedResponsesSingleCallToolsBaseline
        )
        let responsesCapability =
            try responses.hostedSingleCallToolsCapability(
                adapterID: responses.adapterID
            )
        XCTAssertEqual(
            responsesCapability.snapshot.dialect,
            .openAIResponses
        )
        XCTAssertTrue(
            responsesCapability.snapshot.capabilities.features.contains(
                .responseContinuation
            )
        )
        XCTAssertNotEqual(
            chatCapability.snapshot.descriptorSHA256,
            responsesCapability.snapshot.descriptorSHA256
        )
    }

    func testProductionAuthorityCannotBeMintedFromNarrowOrTextRoutes() throws {
        let full = TrustedHostedProviderCatalog.openAIChatCompletions(
            model: .init(rawValue: "full-tools-model"),
            capabilities: .hostedChatSingleCallToolsBaseline
        )
        XCTAssertThrowsError(try full.hostedTextOnlyCapability(
            adapterID: full.adapterID
        ))

        let readOnly = TrustedHostedProviderCatalog.openAIChatCompletions(
            model: .init(rawValue: "read-tools-model"),
            capabilities: .hostedChatReadOnlyToolsCanaryBaseline
        )
        XCTAssertThrowsError(try readOnly.hostedSingleCallToolsCapability(
            adapterID: readOnly.adapterID
        )) { error in
            XCTAssertEqual(
                error as? HostedSingleCallToolsCapabilityError,
                .invalidToolDefinitionLimit(12)
            )
        }
    }

    func testMintRejectsParallelMissingStrictAndNonSingleCallRoutes() {
        let invalidRoutes: [(ProviderModelCapabilities, HostedSingleCallToolsCapabilityError)] = [
            (
                capabilities(extraFeatures: [.parallelToolCalls]),
                .parallelToolCapabilityPresent
            ),
            (
                capabilities(removing: .strictToolSchema),
                .requiredCapabilityMissing(.strictToolSchema)
            ),
            (
                capabilities(maximumToolCallsPerTurn: 2),
                .invalidToolCallLimit(2)
            ),
            (
                capabilities(maximumToolDefinitions: 19),
                .invalidToolDefinitionLimit(19)
            ),
        ]
        for (index, fixture) in invalidRoutes.enumerated() {
            let catalog = TrustedHostedProviderCatalog
                .openAIChatCompletions(
                    model: .init(rawValue: "invalid-tools-\(index)"),
                    capabilities: fixture.0
                )
            XCTAssertThrowsError(
                try catalog.hostedSingleCallToolsCapability(
                    adapterID: catalog.adapterID
                )
            ) { error in
                XCTAssertEqual(
                    error as? HostedSingleCallToolsCapabilityError,
                    fixture.1
                )
            }
        }
    }

    func testValidatorRejectsCallerConfiguredRoute() {
        let descriptor = ProviderAdapterDescriptor(
            route: ProviderRoute(
                providerID: .init(rawValue: "openai"),
                modelID: .init(rawValue: "spoof"),
                adapterID: .init(rawValue: "openai-chat-completions"),
                capabilities: .hostedChatSingleCallToolsBaseline,
                deployment: .callerManaged,
                provenance: .callerConfigured
            ),
            dialect: .openAIChatCompletions,
            requestPath: "/v1/chat/completions"
        )
        XCTAssertThrowsError(
            try descriptor.validatedHostedSingleCallToolsSnapshot(
                expectedDeployment: .hostedService,
                expectedProvenance: .builtInOpenAIChatCompletions
            )
        ) { error in
            XCTAssertEqual(
                error as? HostedSingleCallToolsCapabilityError,
                .untrustedDeployment(.callerManaged)
            )
        }
    }
}

private func capabilities(
    removing: ProviderCapability? = nil,
    extraFeatures: [ProviderCapability] = [],
    maximumToolDefinitions: UInt32 = 20,
    maximumToolCallsPerTurn: UInt32 = 1
) -> ProviderModelCapabilities {
    var features = ProviderModelCapabilities
        .hostedChatSingleCallToolsBaseline.features.values
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

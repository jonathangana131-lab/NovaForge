@testable import AgentProviders
import XCTest

final class ProviderRouteProfileTests: XCTestCase {
    func testProfileRejectsEndpointPathThatDisagreesWithAdapterDescriptor() throws {
        let descriptor = OpenAIResponsesAdapter(
            model: ProviderModelID(rawValue: "fixture-responses")
        ).descriptor

        XCTAssertThrowsError(
            try makeProfile(
                descriptor: descriptor,
                endpointPath: "/v1/chat/completions"
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderRouteProfileValidationError,
                .descriptorPathMismatch(
                    descriptorPath: "/v1/responses",
                    profilePath: "/v1/chat/completions"
                )
            )
        }
    }

    func testLiveCatalogCanOnlyIntersectKnownSelectableProfiles() throws {
        let provider = ProviderID(rawValue: "opencode-zen")
        let supportedModel = ProviderModelID(rawValue: "supported-chat-model")
        let experimentalModel = ProviderModelID(rawValue: "experimental-chat-model")
        let unknownLiveModel = ProviderModelID(rawValue: "unknown-live-model")

        let supported = try makeProfile(
            descriptor: OpenCodeZenChatCompletionsAdapter(model: supportedModel).descriptor,
            supportState: .supported
        )
        let experimental = try makeProfile(
            descriptor: OpenCodeZenChatCompletionsAdapter(model: experimentalModel).descriptor,
            supportState: .experimental
        )
        let registry = try ProviderRouteRegistry([supported, experimental])

        XCTAssertEqual(
            registry.availableProfiles(
                providerID: provider,
                liveModelIDs: [supportedModel, experimentalModel, unknownLiveModel]
            ).map(\.key.modelID),
            [supportedModel]
        )
        XCTAssertEqual(
            registry.availableProfiles(
                providerID: provider,
                liveModelIDs: [supportedModel, experimentalModel, unknownLiveModel],
                allowExperimental: true
            ).map(\.key.modelID),
            [supportedModel, experimentalModel]
        )
        XCTAssertEqual(
            registry.supportState(providerID: provider, modelID: unknownLiveModel),
            .unverified
        )
        XCTAssertThrowsError(
            try registry.resolve(providerID: provider, modelID: unknownLiveModel)
        ) { error in
            XCTAssertEqual(
                error as? ProviderRouteRegistryFailure,
                .unknownRoute(.init(providerID: provider, modelID: unknownLiveModel))
            )
        }
    }

    func testNonOrdinarySupportStatesNeverBecomeSelectableThroughExperimentalOptIn() throws {
        let states: [ProviderProductSupportState] = [
            .legacy,
            .broken,
            .unverified,
            .removedDoNotOffer,
        ]

        for (index, state) in states.enumerated() {
            let model = ProviderModelID(rawValue: "blocked-\(index)")
            let profile = try makeProfile(
                descriptor: OpenAIChatCompletionsAdapter(model: model).descriptor,
                supportState: state
            )
            let registry = try ProviderRouteRegistry([profile])

            XCTAssertThrowsError(
                try registry.resolve(
                    providerID: ProviderID(rawValue: "openai"),
                    modelID: model,
                    allowExperimental: true
                )
            ) { error in
                XCTAssertEqual(
                    error as? ProviderRouteRegistryFailure,
                    .unavailableSupportState(profile.key, state)
                )
            }
        }
    }

    func testRuntimeDescriptorVerificationFailsClosedOnDialectOrPathDrift() throws {
        let model = ProviderModelID(rawValue: "same-model")
        let accepted = try makeProfile(
            descriptor: OpenAIChatCompletionsAdapter(model: model).descriptor
        )
        let registry = try ProviderRouteRegistry([accepted])

        let driftedDescriptor = ProviderAdapterDescriptor(
            route: accepted.descriptor.route,
            dialect: .openAIResponses,
            requestPath: "/v1/responses"
        )

        XCTAssertThrowsError(try registry.profile(matching: driftedDescriptor)) { error in
            XCTAssertEqual(
                error as? ProviderRouteRegistryFailure,
                .descriptorDrift(accepted.key)
            )
        }
    }

    func testReceiptProjectionPersistsExactWireAndSupportIdentity() throws {
        let model = ProviderModelID(rawValue: "receipt-model")
        let descriptor = OpenAIResponsesAdapter(model: model).descriptor
        let profile = try makeProfile(
            descriptor: descriptor,
            authorityID: "public-openai-api",
            authenticationMode: .apiKeyBearer,
            requestSerializerID: .openAIResponses,
            streamParserID: .openAIResponses,
            replayPolicy: .responsesContinuationItems,
            supportState: .supported,
            revision: "routes-2026-08-07"
        )

        let receipt = profile.receiptProjection
        XCTAssertEqual(receipt.providerID, ProviderID(rawValue: "openai"))
        XCTAssertEqual(receipt.modelID, model)
        XCTAssertEqual(receipt.adapterID, ProviderAdapterID(rawValue: "openai-responses"))
        XCTAssertEqual(receipt.dialect, .openAIResponses)
        XCTAssertEqual(receipt.endpointAuthorityID, "public-openai-api")
        XCTAssertEqual(receipt.requestPath, "/v1/responses")
        XCTAssertEqual(receipt.authenticationMode, .apiKeyBearer)
        XCTAssertEqual(receipt.requestSerializerID, .openAIResponses)
        XCTAssertEqual(receipt.streamParserID, .openAIResponses)
        XCTAssertEqual(receipt.replayPolicy, .responsesContinuationItems)
        XCTAssertEqual(receipt.supportState, .supported)
        XCTAssertEqual(receipt.supportRevision, "routes-2026-08-07")
    }

    func testReceiptRecoveryRejectsSupportRevisionDrift() throws {
        let descriptor = OpenAIChatCompletionsAdapter(
            model: ProviderModelID(rawValue: "revision-model")
        ).descriptor
        let accepted = try makeProfile(descriptor: descriptor, revision: "r1")
        let changed = try makeProfile(descriptor: descriptor, revision: "r2")
        let registry = try ProviderRouteRegistry([changed])

        XCTAssertThrowsError(try registry.profile(matching: accepted.receiptProjection)) { error in
            XCTAssertEqual(
                error as? ProviderRouteRegistryFailure,
                .receiptDrift(accepted.key)
            )
        }
    }

    func testDuplicateProviderModelRouteIsRejectedEvenIfDialectDiffers() throws {
        let model = ProviderModelID(rawValue: "duplicate-model")
        let first = try makeProfile(
            descriptor: OpenAIChatCompletionsAdapter(model: model).descriptor
        )
        let secondDescriptor = ProviderAdapterDescriptor(
            route: first.descriptor.route,
            dialect: .openAIResponses,
            requestPath: "/v1/responses"
        )
        let second = try makeProfile(
            descriptor: secondDescriptor,
            endpointPath: "/v1/responses",
            requestSerializerID: .openAIResponses,
            streamParserID: .openAIResponses
        )

        XCTAssertThrowsError(try ProviderRouteRegistry([first, second])) { error in
            XCTAssertEqual(
                error as? ProviderRouteRegistryFailure,
                .duplicateRoute(first.key)
            )
        }
    }

    private func makeProfile(
        descriptor: ProviderAdapterDescriptor,
        authorityID: String = "fixture-origin",
        endpointPath: String? = nil,
        authenticationMode: ProviderAuthenticationMode = .apiKeyBearer,
        requestSerializerID: ProviderRequestSerializerID = .openAIChatCompletions,
        streamParserID: ProviderStreamParserID = .openAIChatCompletions,
        replayPolicy: ProviderReplayPolicy = .none,
        supportState: ProviderProductSupportState = .supported,
        revision: String = "fixture-r1"
    ) throws -> ProviderRouteProfile {
        try ProviderRouteProfile(
            descriptor: descriptor,
            endpoint: ProviderEndpointAuthority(
                authorityID: authorityID,
                relativePath: endpointPath ?? descriptor.requestPath
            ),
            authenticationMode: authenticationMode,
            requestSerializerID: requestSerializerID,
            streamParserID: streamParserID,
            replayPolicy: replayPolicy,
            retryBehavior: .transientSameRoute,
            cancellationBehavior: .cooperativeTransportAbort,
            supportState: supportState,
            evidence: ProviderRouteEvidence(
                catalogSourceID: "fixture-catalog",
                healthSourceID: "fixture-health",
                revision: revision
            )
        )
    }
}

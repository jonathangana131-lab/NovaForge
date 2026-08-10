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
        XCTAssertEqual(receipt.dataHandlingPolicyID, "fixture-standard-hosted")
        XCTAssertEqual(receipt.dataHandlingClassification, .standardHosted)
        XCTAssertFalse(receipt.dataHandlingRequiresPreUseDisclosure)
        XCTAssertEqual(receipt.dataHandlingSourceID, "fixture-privacy-source")
        XCTAssertEqual(receipt.dataHandlingVerifiedAtISO8601, "2026-08-07T00:00:00Z")
        XCTAssertEqual(receipt.requestSerializerID, .openAIResponses)
        XCTAssertEqual(receipt.streamParserID, .openAIResponses)
        XCTAssertEqual(receipt.replayPolicy, .responsesContinuationItems)
        XCTAssertEqual(receipt.supportState, .supported)
        XCTAssertEqual(receipt.supportRevision, "routes-2026-08-07")
    }

    func testSerializerAndParserIdentityAreDerivedFromExecutableDescriptor() throws {
        let responses = try makeProfile(
            descriptor: OpenAIResponsesAdapter(model: .init(rawValue: "responses-codec")).descriptor
        )
        XCTAssertEqual(responses.requestSerializerID, .openAIResponses)
        XCTAssertEqual(responses.streamParserID, .openAIResponses)

        let chat = try makeProfile(
            descriptor: OpenAIChatCompletionsAdapter(model: .init(rawValue: "chat-codec")).descriptor
        )
        XCTAssertEqual(chat.requestSerializerID, .openAIChatCompletions)
        XCTAssertEqual(chat.streamParserID, .openAIChatCompletions)
    }

    func testSupportedRouteRejectsUnverifiedAuthOrDataHandling() throws {
        let descriptor = OpenAIChatCompletionsAdapter(
            model: ProviderModelID(rawValue: "support-truth")
        ).descriptor

        XCTAssertThrowsError(
            try makeProfile(
                descriptor: descriptor,
                authenticationMode: .unverified
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderRouteProfileValidationError,
                .supportedRouteHasUnverifiedAuthentication
            )
        }

        XCTAssertThrowsError(
            try makeProfile(
                descriptor: descriptor,
                dataHandling: ProviderDataHandlingPolicy(
                    policyID: "unknown-policy",
                    classification: .unverified,
                    requiresPreUseDisclosure: true,
                    sourceID: "fixture-privacy-source",
                    verifiedAtISO8601: "2026-08-07T00:00:00Z"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderRouteProfileValidationError,
                .supportedRouteHasUnverifiedDataHandling
            )
        }
    }

    func testLocalRouteRequiresLocalAuthAndOnDeviceDataHandling() throws {
        let localDescriptor = ProviderAdapterDescriptor(
            route: ProviderRoute(
                providerID: ProviderID(rawValue: "novaforge-local"),
                modelID: ProviderModelID(rawValue: "fixture-local"),
                adapterID: ProviderAdapterID(rawValue: "local-fixture"),
                capabilities: .openAICompatibleBaseline,
                deployment: .onDevice,
                provenance: .builtInLocalModel
            ),
            dialect: .openAICompatibleChat,
            requestPath: "/v1/local/chat/completions"
        )

        XCTAssertThrowsError(try makeProfile(descriptor: localDescriptor)) { error in
            XCTAssertEqual(
                error as? ProviderRouteProfileValidationError,
                .localRouteAuthenticationMismatch
            )
        }

        let local = try makeProfile(
            descriptor: localDescriptor,
            authenticationMode: .local,
            dataHandling: ProviderDataHandlingPolicy(
                policyID: "local-on-device",
                classification: .onDeviceOnly,
                requiresPreUseDisclosure: false,
                sourceID: "novaforge-local-runtime",
                verifiedAtISO8601: "2026-08-07T00:00:00Z"
            )
        )
        XCTAssertEqual(local.authenticationMode, .local)
        XCTAssertEqual(local.dataHandling.classification, .onDeviceOnly)
        XCTAssertEqual(local.streamParserID, .localNative)
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
            endpointPath: "/v1/responses"
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
        dataHandling: ProviderDataHandlingPolicy = ProviderDataHandlingPolicy(
            policyID: "fixture-standard-hosted",
            classification: .standardHosted,
            requiresPreUseDisclosure: false,
            sourceID: "fixture-privacy-source",
            verifiedAtISO8601: "2026-08-07T00:00:00Z"
        ),
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
            dataHandling: dataHandling,
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

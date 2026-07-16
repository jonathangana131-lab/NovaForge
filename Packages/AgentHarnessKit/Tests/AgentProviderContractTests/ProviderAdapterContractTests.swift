import AgentDomain
@testable import AgentProviders
import Foundation
import XCTest

final class ProviderAdapterContractTests: XCTestCase {
    func testGoldenChatAndResponsesRequestsPreserveMultiRoundTranscript() throws {
        let request = canonicalRequest()

        let chat = OpenAIChatCompletionsAdapter(model: .init(rawValue: "fixture-model"))
        let chatEncoded = try chat.encode(request)
        XCTAssertEqual(chatEncoded.relativePath, "/v1/chat/completions")
        XCTAssertEqual(
            try canonicalData(chatEncoded.body),
            try canonicalData(loadJSON("expected_chat_request"))
        )

        let responses = OpenAIResponsesAdapter(model: .init(rawValue: "fixture-model"))
        let responsesEncoded = try responses.encode(request)
        XCTAssertEqual(responsesEncoded.relativePath, "/v1/responses")
        XCTAssertEqual(
            try canonicalData(responsesEncoded.body),
            try canonicalData(loadJSON("expected_responses_request"))
        )

        XCTAssertTrue(request.requiredCapabilities.contains(.tools))
        XCTAssertTrue(request.requiredCapabilities.contains(.typedToolArguments))
        XCTAssertTrue(request.requiredCapabilities.contains(.strictToolSchema))
        XCTAssertTrue(request.requiredCapabilities.contains(.parallelToolCalls))
        XCTAssertTrue(request.requiredCapabilities.contains(.usageStreaming))
    }

    func testTextGoldenFixture() throws {
        try assertStreamFixture("chat_text")
    }

    func testOpenCodeZenUsesOpenAICompatibleMaximumTokenField() throws {
        let model = ProviderModelID(rawValue: "mimo-v2.5-free")
        let adapter = OpenCodeZenChatCompletionsAdapter(
            model: model,
            capabilities: .hostedChatSingleCallToolsBaseline
        )
        let request = CanonicalProviderRequest(
            requestID: "zen-maximum-output",
            model: model,
            messages: [.init(role: .user, content: [.text("Hello")])],
            options: .init(
                maximumOutputTokens: 128,
                temperature: 0,
                parallelToolCalls: false,
                toolChoice: .auto
            )
        )

        let encoded = try adapter.encode(request)
        let body = try XCTUnwrap(encoded.body.providerTestObject)

        XCTAssertEqual(encoded.relativePath, "/zen/v1/chat/completions")
        XCTAssertEqual(body["max_tokens"], .number(.unsignedInteger(128)))
        XCTAssertNil(body["max_completion_tokens"])
    }

    func testSingleToolGoldenFixturePreservesTypedArgumentsAndUsage() throws {
        try assertStreamFixture("responses_single_tool")
    }

    func testParallelToolGoldenFixtureKeepsIndependentCallBuffers() throws {
        try assertStreamFixture("chat_parallel_tools")
    }

    func testReasoningSummaryGoldenFixtureDoesNotExposeUnscopedOutput() throws {
        try assertStreamFixture("responses_reasoning_summary")
    }

    func testCancellationGoldenFixtureIsTerminalAndAttemptScoped() throws {
        try assertStreamFixture("responses_cancelled")
    }

    func testMultiRoundToolGoldenCreatesFreshAttemptScopePerRound() throws {
        let fixture: StreamFixture = try loadFixture("responses_multi_round_tools")
        let adapter = try makeAdapter(dialect: fixture.dialect)
        let rounds = try XCTUnwrap(fixture.rounds)
        XCTAssertEqual(rounds.count, 2)

        var allScopes: [ProviderAttemptScope] = []
        for (index, round) in rounds.enumerated() {
            let scope = ProviderAttemptScope(
                requestID: "multi-round-request",
                attemptID: .init(rawValue: "round-\(index + 1)")
            )
            let events = try adapter.translateStream(
                try round.frames.map { try $0.wireFrame },
                scope: scope,
                request: streamRequest(for: "responses_multi_round_tools")
            )
            XCTAssertEqual(try events.map(eventSignature), round.expected)
            XCTAssertTrue(events.allSatisfy { $0.scope == scope })
            XCTAssertEqual(events.map(\.sequence), Array(0 ..< UInt64(events.count)))
            allScopes.append(contentsOf: events.map(\.scope))
        }
        XCTAssertEqual(Set(allScopes).count, 2)
    }

    func testMalformedStreamFixtureFailsClosedWithStableSanitizedCode() throws {
        let fixture: StreamFixture = try loadFixture("responses_malformed_stream")
        let adapter = try makeAdapter(dialect: fixture.dialect)
        let scope = ProviderAttemptScope(requestID: "malformed", attemptID: .init(rawValue: "attempt-1"))

        XCTAssertThrowsError(
            try adapter.translateStream(
                try XCTUnwrap(fixture.frames).map { try $0.wireFrame },
                scope: scope,
                request: streamRequest(for: "responses_malformed_stream")
            )
        ) { error in
            guard let failure = error as? ProviderFailure else {
                return XCTFail("Expected ProviderFailure, got \(error)")
            }
            XCTAssertEqual(failure.category, .malformedEvent)
            XCTAssertEqual(failure.code, fixture.expectedFailureCode)
            XCTAssertFalse(failure.publicMessage.contains("{"))
        }
    }

    func testCapabilityNegotiationSkipsIncompatiblePreferredRoute() throws {
        let limited = ProviderModelCapabilities(
            features: ProviderCapabilitySet([.streaming]),
            contextWindowTokens: 8_192,
            maximumOutputTokens: 1_024
        )
        let limitedAdapter = OpenAICompatibleAdapter(configuration: .init(
            providerID: .init(rawValue: "limited"),
            adapterID: .init(rawValue: "limited-chat"),
            modelID: .init(rawValue: "limited-model"),
            capabilities: limited
        ))
        let fullAdapter = OpenAIResponsesAdapter(model: .init(rawValue: "fixture-model"))
        let catalog = try ProviderAdapterCatalog([limitedAdapter, fullAdapter])

        let negotiated = try catalog.negotiate(
            preferredAdapterIDs: [.init(rawValue: "limited-chat"), .init(rawValue: "openai-responses")],
            requiredCapabilities: canonicalRequest().requiredCapabilities
        )
        XCTAssertEqual(negotiated.map { $0.descriptor.route.adapterID.rawValue }, ["openai-responses"])

        XCTAssertThrowsError(try ProviderAdapterCatalog([fullAdapter, fullAdapter])) { error in
            XCTAssertEqual(
                error as? ProviderCatalogFailure,
                .duplicateAdapter(.init(rawValue: "openai-responses"))
            )
        }
    }

    func testHTTP402MapsToStableBillingSetupFailure() {
        let failure = ProviderFailureMapper.httpFailure(
            statusCode: 402,
            providerID: .init(rawValue: "opencode-zen"),
            adapterID: .init(rawValue: "opencode-zen-chat-completions")
        )

        XCTAssertEqual(failure.category, .authorization)
        XCTAssertEqual(failure.code, "provider_payment_required")
        XCTAssertEqual(failure.statusCode, 402)
        XCTAssertTrue(failure.publicMessage.contains("billing or credits"))
        XCTAssertFalse(failure.retryableOnSameRoute)
    }

    func testCapabilityNegotiationHonorsContextAndOutputLimits() throws {
        let small = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "small-model"),
            capabilities: .init(
                features: ProviderModelCapabilities.openAIChatBaseline.features,
                contextWindowTokens: 8_192,
                maximumOutputTokens: 1_024
            )
        )
        let large = OpenAIResponsesAdapter(model: .init(rawValue: "large-model"))
        let catalog = try ProviderAdapterCatalog([small, large])
        let request = CanonicalProviderRequest(
            requestID: "large-context",
            model: .init(rawValue: "small-model"),
            messages: [.init(role: .user, content: [.text("Large context")])],
            options: .init(
                maximumOutputTokens: 4_096,
                minimumContextWindowTokens: 64_000
            )
        )

        let negotiated = try catalog.negotiate(
            preferredAdapterIDs: [
                .init(rawValue: "openai-chat-completions"),
                .init(rawValue: "openai-responses"),
            ],
            requirements: request.capabilityRequirements
        )
        XCTAssertEqual(negotiated.map { $0.descriptor.route.modelID.rawValue }, ["large-model"])

        XCTAssertThrowsError(try small.encode(request)) { error in
            XCTAssertEqual((error as? ProviderFailure)?.code, "provider_context_window_too_small")
        }
    }

    func testGenericOpenAICompatibleRouteRejectsCredentialBearingAbsoluteEndpoint() throws {
        let adapter = OpenAICompatibleAdapter(configuration: .init(
            providerID: .init(rawValue: "custom"),
            adapterID: .init(rawValue: "custom-chat"),
            modelID: .init(rawValue: "fixture-model"),
            requestPath: "https://example.invalid/v1/chat/completions"
        ))
        XCTAssertThrowsError(try adapter.encode(canonicalRequest())) { error in
            XCTAssertEqual((error as? ProviderFailure)?.code, "provider_endpoint_path_not_relative")
        }
    }

    func testAdvertisedCapabilitiesMatchEncodedOptionsAndContinuation() throws {
        let chat = OpenAIChatCompletionsAdapter(model: .init(rawValue: "fixture-model"))
        XCTAssertTrue(chat.descriptor.route.capabilities.features.contains(.temperature))
        XCTAssertTrue(chat.descriptor.route.capabilities.features.contains(.promptCaching))
        XCTAssertFalse(chat.descriptor.route.capabilities.features.contains(.reasoning))
        XCTAssertFalse(chat.descriptor.route.capabilities.features.contains(.responseContinuation))

        let responses = OpenAIResponsesAdapter(model: .init(rawValue: "fixture-model"))
        XCTAssertTrue(responses.descriptor.route.capabilities.features.contains(.reasoning))
        XCTAssertTrue(responses.descriptor.route.capabilities.features.contains(.responseContinuation))
        XCTAssertTrue(responses.descriptor.route.capabilities.features.contains(.imageInput))
        XCTAssertTrue(responses.descriptor.route.capabilities.features.contains(.strictToolSchema))

        let request = CanonicalProviderRequest(
            requestID: "continuation-fixture",
            model: .init(rawValue: "fixture-model"),
            messages: [.init(role: .user, content: [.text("Continue")])],
            options: .init(
                temperature: 0.5,
                reasoningSummary: true,
                reasoningEffort: .max,
                promptCacheKey: "project-prefix-v1",
                previousResponseID: "resp_previous"
            )
        )
        XCTAssertTrue(request.requiredCapabilities.contains(.temperature))
        XCTAssertTrue(request.requiredCapabilities.contains(.reasoning))
        XCTAssertTrue(request.requiredCapabilities.contains(.promptCaching))
        XCTAssertTrue(request.requiredCapabilities.contains(.responseContinuation))

        let encoded = try responses.encode(request)
        let body = try XCTUnwrap(encoded.body.providerTestObject)
        XCTAssertEqual(body["temperature"], .number(.floatingPoint(0.5)))
        XCTAssertEqual(body["prompt_cache_key"], .string("project-prefix-v1"))
        XCTAssertEqual(body["previous_response_id"], .string("resp_previous"))
        XCTAssertEqual(
            body["reasoning"],
            .object([
                "effort": .string("max"),
                "summary": .string("auto"),
            ])
        )

        XCTAssertThrowsError(try chat.encode(request)) { error in
            XCTAssertEqual((error as? ProviderFailure)?.code, "provider_unsupported_capability")
        }

        let compatible = OpenAICompatibleAdapter(configuration: .init(
            providerID: .init(rawValue: "generic"),
            adapterID: .init(rawValue: "generic-chat"),
            modelID: .init(rawValue: "fixture-model")
        ))
        XCTAssertFalse(compatible.descriptor.route.capabilities.features.contains(.promptCaching))
        XCTAssertFalse(compatible.descriptor.route.capabilities.features.contains(.reasoning))
        XCTAssertFalse(compatible.descriptor.route.capabilities.features.contains(.responseContinuation))
        XCTAssertFalse(compatible.descriptor.route.capabilities.features.contains(.strictToolSchema))
    }

    private func assertStreamFixture(_ name: String) throws {
        let fixture: StreamFixture = try loadFixture(name)
        let adapter = try makeAdapter(dialect: fixture.dialect)
        let scope = ProviderAttemptScope(requestID: name, attemptID: .init(rawValue: "attempt-1"))
        let frames = try XCTUnwrap(fixture.frames).map { try $0.wireFrame }
        let events = try adapter.translateStream(
            frames,
            scope: scope,
            request: streamRequest(for: name)
        )

        XCTAssertEqual(try events.map(eventSignature), try XCTUnwrap(fixture.expected))
        XCTAssertTrue(events.allSatisfy { $0.scope == scope })
        XCTAssertEqual(events.map(\.sequence), Array(0 ..< UInt64(events.count)))
    }

    private func makeAdapter(dialect: String) throws -> any ProviderAdapter {
        switch dialect {
        case "chat":
            return OpenAIChatCompletionsAdapter(model: .init(rawValue: "fixture-model"))
        case "responses":
            return OpenAIResponsesAdapter(model: .init(rawValue: "fixture-model"))
        default:
            throw FixtureFailure.invalidDialect(dialect)
        }
    }

    private func streamRequest(for fixture: String) -> CanonicalProviderRequest {
        let tools: [ProviderToolDefinition]
        let options: ProviderGenerationOptions
        switch fixture {
        case "responses_single_tool", "responses_malformed_stream":
            tools = [writeFileTool]
            options = .init()
        case "chat_parallel_tools":
            tools = [readFileTool]
            options = .init(parallelToolCalls: true)
        case "responses_multi_round_tools":
            tools = [readFileTool]
            options = .init()
        case "responses_reasoning_summary":
            tools = []
            options = .init(reasoningSummary: true)
        default:
            tools = []
            options = .init()
        }
        return CanonicalProviderRequest(
            requestID: fixture,
            model: .init(rawValue: "fixture-model"),
            messages: [.init(role: .user, content: [.text("Fixture")])],
            tools: tools,
            options: options
        )
    }

    private var readFileTool: ProviderToolDefinition {
        ProviderToolDefinition(
            name: "read_file",
            description: "Read a file",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("path")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    private var writeFileTool: ProviderToolDefinition {
        ProviderToolDefinition(
            name: "write_file",
            description: "Write a file",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "replace": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("path"), .string("replace")]),
                "additionalProperties": .bool(false),
            ])
        )
    }

    private func canonicalRequest() -> CanonicalProviderRequest {
        CanonicalProviderRequest(
            requestID: "fixture-request",
            model: .init(rawValue: "fixture-model"),
            messages: [
                .init(role: .system, content: [.text("Be exact.")]),
                .init(role: .user, content: [.text("Update notes.")]),
                .init(role: .assistant, content: [
                    .toolCall(.init(
                        callID: "call-old",
                        name: "read_file",
                        arguments: .object(["path": .string("notes.md")])
                    )),
                ]),
                .init(
                    role: .tool,
                    content: [.structured(.object([
                        "lines": .number(.integer(1)),
                        "text": .string("hello"),
                    ]))],
                    toolCallID: "call-old",
                    name: "read_file"
                ),
            ],
            tools: [
                .init(
                    name: "write_file",
                    description: "Write a file",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object(["type": .string("string")]),
                            "replace": .object(["type": .string("boolean")]),
                        ]),
                        "required": .array([.string("path"), .string("replace")]),
                        "additionalProperties": .bool(false),
                    ])
                ),
            ],
            options: .init(
                maximumOutputTokens: 128,
                temperature: 0.25,
                parallelToolCalls: true,
                toolChoice: .named("write_file")
            ),
            metadata: .object(["trace": .string("fixture")])
        )
    }
}

final class ModelGatewayContractTests: XCTestCase {
    func testFailedAttemptCannotContaminateRetryFixture() async throws {
        let fixture: RetryFixture = try loadFixture("retry_contamination")
        let transport = FixtureTransport(attempts: try fixture.attempts.map { try $0.transportAttempt })
        let adapter = OpenAIChatCompletionsAdapter(model: .init(rawValue: "fixture-model"))
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )

        let result = try await gateway.generate(.init(
            request: simpleRequest(),
            preferredAdapterIDs: [.init(rawValue: "openai-chat-completions")],
            recoveryPolicy: .init(
                maximumAttemptsPerRoute: 2,
                maximumFallbacks: 0,
                baseBackoffMilliseconds: 0,
                maximumBackoffMilliseconds: 0,
                jitterBasisPoints: 0
            ),
            deterministicSeed: 42
        ))

        let committedText = result.events.compactMap { envelope -> String? in
            if case let .textDelta(delta) = envelope.event { delta.text } else { nil }
        }.joined()
        XCTAssertEqual(committedText, fixture.expectedCommittedText)
        XCTAssertFalse(committedText.contains(fixture.forbiddenCommittedText))
        XCTAssertEqual(result.attempts.count, 2)
        XCTAssertFalse(result.attempts[0].committed)
        XCTAssertTrue(result.attempts[1].committed)
        XCTAssertNotEqual(result.attempts[0].scope, result.committedScope)
        XCTAssertTrue(result.events.allSatisfy { $0.scope == result.committedScope })
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testLiveRetryStreamMarksPoisonScopeDiscardedAndCleanScopeCommitted() async throws {
        let fixture: RetryFixture = try loadFixture("retry_contamination")
        let transport = FixtureTransport(attempts: try fixture.attempts.map { try $0.transportAttempt })
        let adapter = OpenAIChatCompletionsAdapter(model: .init(rawValue: "fixture-model"))
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )
        let live = await gateway.stream(.init(
            request: simpleRequest(),
            preferredAdapterIDs: [.init(rawValue: "openai-chat-completions")],
            recoveryPolicy: .init(
                maximumAttemptsPerRoute: 2,
                maximumFallbacks: 0,
                baseBackoffMilliseconds: 0,
                maximumBackoffMilliseconds: 0,
                jitterBasisPoints: 0
            ),
            deterministicSeed: 42
        ))

        var textByScope: [ProviderAttemptScope: String] = [:]
        var discarded: Set<ProviderAttemptScope> = []
        var committed: ProviderAttemptScope?
        var sawRetryBoundary = false
        for try await event in live {
            switch event {
            case let .provisional(envelope):
                if case let .textDelta(delta) = envelope.event {
                    textByScope[envelope.scope, default: ""].append(delta.text)
                }
            case let .attemptDiscarded(record):
                discarded.insert(record.scope)
            case .retryScheduled:
                sawRetryBoundary = true
            case let .attemptCommitted(commit):
                committed = commit.record.scope
            case .attemptStarted, .fallbackScheduled:
                break
            }
        }

        let committedScope = try XCTUnwrap(committed)
        XCTAssertEqual(textByScope[committedScope], fixture.expectedCommittedText)
        XCTAssertTrue(discarded.allSatisfy {
            textByScope[$0]?.contains(fixture.forbiddenCommittedText) == true
        })
        XCTAssertFalse(discarded.contains(committedScope))
        XCTAssertTrue(sawRetryBoundary)
    }

    func testFallbackIsForbiddenAfterAppliedEffectFixture() async throws {
        let fixture: FallbackGuardFixture = try loadFixture("fallback_effect_guard")
        let outcome = await guardedFailure(
            safety: .init(outputCommitState: .none, toolDispatchState: .mutatingConfirmed)
        )
        XCTAssertEqual(outcome.failure?.stopReason.rawValue, fixture.expectedEffectStop)
        XCTAssertEqual(outcome.calls, fixture.expectedTransportCalls)
    }

    func testRetryAndFallbackAreForbiddenAfterCommittedOutputFixture() async throws {
        let fixture: FallbackGuardFixture = try loadFixture("fallback_effect_guard")
        let outcome = await guardedFailure(
            safety: .init(outputCommitState: .committed, toolDispatchState: .none)
        )
        XCTAssertEqual(outcome.failure?.stopReason.rawValue, fixture.expectedOutputStop)
        XCTAssertEqual(outcome.calls, fixture.expectedTransportCalls)
    }

    func testUncommittedTransportFailureFallsBackFromCanonicalTranscript() async throws {
        let primary = OpenAIChatCompletionsAdapter(model: .init(rawValue: "fixture-model"))
        let fallback = OpenAICompatibleAdapter(configuration: .init(
            providerID: .init(rawValue: "fallback"),
            adapterID: .init(rawValue: "fallback-chat"),
            modelID: .init(rawValue: "fixture-fallback-model")
        ))
        let frames: [ProviderWireFrame] = [
            .json(.object([
                "id": .string("fallback-response"),
                "model": .string("fixture-fallback-model"),
                "choices": .array([.object([
                    "index": .number(.integer(0)),
                    "delta": .object(["content": .string("fallback-ok")]),
                    "finish_reason": .null,
                ])]),
            ])),
            .json(.object([
                "id": .string("fallback-response"),
                "model": .string("fixture-fallback-model"),
                "choices": .array([.object([
                    "index": .number(.integer(0)),
                    "delta": .object([:]),
                    "finish_reason": .string("stop"),
                ])]),
            ])),
            .done,
        ]
        let transport = FixtureTransport(attempts: [
            .init(frames: [], failure: "transport"),
            .init(frames: frames, failure: nil),
        ])
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([primary, fallback]),
            transport: transport
        )

        let result = try await gateway.generate(.init(
            request: simpleRequest(),
            preferredAdapterIDs: [
                .init(rawValue: "openai-chat-completions"),
                .init(rawValue: "fallback-chat"),
            ],
            recoveryPolicy: .init(
                maximumAttemptsPerRoute: 1,
                maximumFallbacks: 1,
                baseBackoffMilliseconds: 0,
                maximumBackoffMilliseconds: 0,
                jitterBasisPoints: 0
            ),
            deterministicSeed: 77
        ))

        XCTAssertEqual(result.route.adapterID.rawValue, "fallback-chat")
        XCTAssertEqual(result.attempts.count, 2)
        XCTAssertEqual(result.events.compactMap { envelope -> String? in
            if case let .textDelta(delta) = envelope.event { delta.text } else { nil }
        }.joined(), "fallback-ok")
    }

    func testRecoveryPlannerRequiresCapabilitiesOnEveryFallbackCandidate() {
        let current = route(provider: "primary", adapter: "primary", features: [.streaming, .tools])
        let incompatible = route(provider: "fallback", adapter: "fallback", features: [.streaming])
        let failure = ProviderFailureMapper.httpFailure(
            statusCode: 503,
            providerID: current.providerID,
            adapterID: current.adapterID
        )
        let decision = ProviderRecoveryPlanner.decide(
            context: .init(
                currentRoute: current,
                fallbackRoutes: [incompatible],
                requiredCapabilities: ProviderCapabilitySet([.streaming, .tools]),
                attemptOnCurrentRoute: 1,
                fallbacksAlreadyUsed: 0,
                failure: failure,
                toolDispatchState: .none,
                deterministicSeed: 1
            ),
            policy: .init(maximumAttemptsPerRoute: 1, maximumFallbacks: 1)
        )
        XCTAssertEqual(decision, .stop(.noCompatibleFallback))
    }

    private func guardedFailure(
        safety: ProviderReplaySafety
    ) async -> (failure: ProviderGatewayFailure?, calls: Int) {
        let primary = OpenAIChatCompletionsAdapter(model: .init(rawValue: "fixture-model"))
        let fallback = OpenAICompatibleAdapter(configuration: .init(
            providerID: .init(rawValue: "fallback"),
            adapterID: .init(rawValue: "fallback-chat"),
            modelID: .init(rawValue: "fixture-fallback-model")
        ))
        let transport = FixtureTransport(attempts: [
            .init(frames: [], failure: "transport"),
            .init(frames: [], failure: nil),
        ])
        do {
            let gateway = ModelGateway(
                catalog: try ProviderAdapterCatalog([primary, fallback]),
                transport: transport
            )
            _ = try await gateway.generate(.init(
                request: simpleRequest(),
                preferredAdapterIDs: [
                    .init(rawValue: "openai-chat-completions"),
                    .init(rawValue: "fallback-chat"),
                ],
                recoveryPolicy: .init(
                    maximumAttemptsPerRoute: 1,
                    maximumFallbacks: 1,
                    baseBackoffMilliseconds: 0,
                    maximumBackoffMilliseconds: 0,
                    jitterBasisPoints: 0
                ),
                replaySafety: safety,
                deterministicSeed: 9
            ))
            return (nil, await transport.callCount())
        } catch let failure as ProviderGatewayFailure {
            return (failure, await transport.callCount())
        } catch {
            XCTFail("Unexpected error: \(error)")
            return (nil, await transport.callCount())
        }
    }

    private func simpleRequest() -> CanonicalProviderRequest {
        CanonicalProviderRequest(
            requestID: "gateway-fixture",
            model: .init(rawValue: "fixture-model"),
            messages: [.init(role: .user, content: [.text("Hello")])]
        )
    }

    private func route(
        provider: String,
        adapter: String,
        features: [ProviderCapability]
    ) -> ProviderRoute {
        ProviderRoute(
            providerID: .init(rawValue: provider),
            modelID: .init(rawValue: "model"),
            adapterID: .init(rawValue: adapter),
            capabilities: .init(
                features: ProviderCapabilitySet(features),
                contextWindowTokens: 8_192,
                maximumOutputTokens: 1_024
            ),
            deployment: .callerManaged,
            provenance: .callerConfigured
        )
    }
}

private actor FixtureTransport: ProviderTransport {
    private let attempts: [TransportAttempt]
    private var index = 0

    init(attempts: [TransportAttempt]) {
        self.attempts = attempts
    }

    func stream(
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        guard attempts.indices.contains(index) else {
            throw ProviderFailureMapper.transportFailure(
                providerID: descriptor.route.providerID,
                adapterID: descriptor.route.adapterID
            )
        }
        let attempt = attempts[index]
        index += 1
        return AsyncThrowingStream { continuation in
            for frame in attempt.frames { continuation.yield(frame) }
            if attempt.failure == "transport" {
                continuation.finish(throwing: ProviderFailureMapper.transportFailure(
                    providerID: descriptor.route.providerID,
                    adapterID: descriptor.route.adapterID
                ))
            } else {
                continuation.finish()
            }
        }
    }

    func callCount() -> Int { index }
}

private struct TransportAttempt: Sendable {
    let frames: [ProviderWireFrame]
    let failure: String?
}

private struct StreamFixture: Decodable {
    let dialect: String
    let frames: [FixtureFrame]?
    let rounds: [FixtureRound]?
    let expected: [String]?
    let expectedFailureCode: String?
}

private struct FixtureRound: Decodable {
    let frames: [FixtureFrame]
    let expected: [String]
}

private struct FixtureFrame: Decodable, Sendable {
    let kind: String
    let value: JSONValue?
    let reason: String?

    var wireFrame: ProviderWireFrame {
        get throws {
            switch kind {
            case "json":
                guard let value else { throw FixtureFailure.missingJSONValue }
                return .json(value)
            case "done":
                return .done
            case "cancelled":
                return .cancelled(reason: reason)
            default:
                throw FixtureFailure.invalidFrameKind(kind)
            }
        }
    }
}

private struct RetryFixture: Decodable {
    let attempts: [RetryAttemptFixture]
    let expectedCommittedText: String
    let forbiddenCommittedText: String
}

private struct RetryAttemptFixture: Decodable {
    let frames: [FixtureFrame]
    let failure: String?

    var transportAttempt: TransportAttempt {
        get throws { TransportAttempt(frames: try frames.map { try $0.wireFrame }, failure: failure) }
    }
}

private struct FallbackGuardFixture: Decodable {
    let primaryFailure: String
    let expectedEffectStop: String
    let expectedOutputStop: String
    let expectedTransportCalls: Int
}

private enum FixtureFailure: Error {
    case invalidDialect(String)
    case invalidFrameKind(String)
    case missingJSONValue
    case missingFixture(String)
}

private func loadFixture<T: Decodable>(_ name: String) throws -> T {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
        throw FixtureFailure.missingFixture(name)
    }
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

private func loadJSON(_ name: String) throws -> JSONValue {
    try loadFixture(name)
}

private func canonicalData(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private extension JSONValue {
    var providerTestObject: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}

private func eventSignature(_ envelope: ProviderAttemptEvent) throws -> String {
    switch envelope.event {
    case let .responseStarted(value):
        return "started|\(value.responseID)|\(value.model.rawValue)"
    case let .textDelta(value):
        return "text|\(value.outputIndex)|\(value.text)"
    case let .reasoningDelta(value):
        return "reasoning|\(value.outputIndex)|\(value.text)"
    case let .toolCallStarted(value):
        return "toolStarted|\(value.outputIndex)|\(value.itemID ?? "-")|\(value.callID)|\(value.name)"
    case let .toolCallArgumentsDelta(value):
        return "toolDelta|\(value.outputIndex)|\(value.callID)|\(value.fragment)"
    case let .toolCallCompleted(value):
        let arguments = String(decoding: try canonicalData(value.arguments), as: UTF8.self)
        return "toolCompleted|\(value.outputIndex)|\(value.itemID ?? "-")|\(value.callID)|\(value.name)|\(arguments)"
    case let .usage(value):
        return "usage|\(value.inputTokens)|\(value.cachedInputTokens)|\(value.outputTokens)|\(value.reasoningTokens)"
    case let .responseCompleted(value):
        return "completed|\(value.responseID)|\(value.finishReason.rawValue)"
    case let .cancelled(value):
        return "cancelled|\(value.responseID ?? "-")|\(value.reason ?? "-")"
    }
}

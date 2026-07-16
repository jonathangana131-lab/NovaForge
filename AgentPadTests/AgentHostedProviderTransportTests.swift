import AgentDomain
import AgentProviders
import AgentTools
import Dispatch
import Foundation
import XCTest
@testable import NovaForge

final class AgentHostedProviderTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        HostedTransportURLProtocolRegistry.shared.reset()
    }

    override func tearDown() {
        HostedTransportURLProtocolRegistry.shared.reset()
        super.tearDown()
    }

    func testCanonicalChatGatewayDispatchesAfterBarrierAndValidatesRealisticSSE() async throws {
        installSSE(chatIntegrationSSE())
        let fixture = try makeGatewayFixture(
            dialect: .openAIChatCompletions,
            requestID: "chat-integration"
        )

        let stream = await fixture.gateway.streamAttempt(fixture.invocation)
        let events = try await collectAttemptEvents(stream)

        assertSuccessfulAttempt(
            events,
            scope: fixture.scope,
            responseID: "chatcmpl-canary",
            responseModel: versionedModel
        )
        let dispatches = await fixture.barrier.snapshot()
        XCTAssertEqual(dispatches.count, 1)
        XCTAssertEqual(dispatches.first?.scope, fixture.scope)
        XCTAssertEqual(dispatches.first?.route, fixture.descriptor.route)
        XCTAssertEqual(dispatches.first?.method, .post)
        XCTAssertEqual(dispatches.first?.relativePath, "/v1/chat/completions")
        let requestCountsAtDispatch = await fixture.barrier.requestCountsAtDispatch()
        XCTAssertEqual(requestCountsAtDispatch, [0])
        assertSingleCredentialedRequest(
            credential: fixture.credential,
            path: "/v1/chat/completions"
        )
        try assertAdapterEnvelope(dialect: .openAIChatCompletions)
    }

    func testCanonicalReadToolsAuthorityDispatchesExactFrozenCatalog() async throws {
        installSSE(chatIntegrationSSE())
        let fixture = try makeReadToolsGatewayFixture(
            requestID: "chat-read-tools-integration"
        )

        let events = try await collectAttemptEvents(
            await fixture.gateway.streamAttempt(fixture.invocation)
        )
        assertSuccessfulAttempt(
            events,
            scope: fixture.scope,
            responseID: "chatcmpl-canary",
            responseModel: versionedModel
        )
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
        let request = try XCTUnwrap(
            HostedTransportURLProtocolRegistry.shared.requests.last
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual((object["tools"] as? [Any])?.count, 12)
        XCTAssertEqual(object["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(object["tool_choice"] as? String, "auto")
    }

    func testReadToolsAuthorityRejectsSchemaSpoofBeforeHTTP() async throws {
        let fixture = try makeReadToolsGatewayFixture(
            requestID: "chat-read-tools-schema-spoof",
            mutateTools: { tools in
                let first = tools[0]
                tools[0] = AgentProviders.ProviderToolDefinition(
                    name: first.name,
                    description: "Caller-spoofed read contract",
                    parameters: first.parameters,
                    strict: first.strict
                )
            }
        )

        do {
            for try await _ in await fixture.gateway.streamAttempt(
                fixture.invocation
            ) {}
            XCTFail("A caller-spoofed tool contract unexpectedly dispatched")
        } catch {
            // The transport maps the app-private rejection to a closed
            // provider failure; caller schema text never reaches HTTP.
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 0)
    }

    func testReadToolsAuthorityAcceptsOnePairedRawProviderCallID() async throws {
        installSSE(chatIntegrationSSE())
        let rawCallID = "call_raw_provider_123"
        let fixture = try makeReadToolsGatewayFixture(
            requestID: "chat-read-tools-follow-up",
            messages: [
                .init(role: .system, content: [.text("Inspect only.")]),
                .init(role: .user, content: [.text("Read note.txt")]),
                .init(role: .assistant, content: [.toolCall(.init(
                    callID: rawCallID,
                    name: "read_file",
                    arguments: .object(["path": .string("note.txt")])
                ))]),
                .init(
                    role: .tool,
                    content: [.text("bounded output")],
                    toolCallID: rawCallID
                ),
            ]
        )

        _ = try await collectAttemptEvents(
            await fixture.gateway.streamAttempt(fixture.invocation)
        )
        let request = try XCTUnwrap(
            HostedTransportURLProtocolRegistry.shared.requests.last
        )
        let body = try XCTUnwrap(request.httpBody)
        let encoded = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(encoded.contains(rawCallID))
        XCTAssertTrue(encoded.contains("tool_call_id"))
        XCTAssertTrue(encoded.contains("tool_calls"))
    }

    func testCanonicalSingleCallToolsAuthorityDispatchesExactFullRegistry()
        async throws
    {
        installSSE(chatIntegrationSSE())
        let fixture = try makeSingleCallToolsGatewayFixture(
            requestID: "chat-canonical-tools-integration"
        )

        _ = try await collectAttemptEvents(
            await fixture.gateway.streamAttempt(fixture.invocation)
        )
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
        let request = try XCTUnwrap(
            HostedTransportURLProtocolRegistry.shared.requests.last
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { definition in
            (definition["function"] as? [String: Any])?["name"] as? String
        })
        XCTAssertEqual(tools.count, 20)
        XCTAssertEqual(names.count, 20)
        XCTAssertTrue(names.contains("read_file"))
        XCTAssertTrue(names.contains("write_file"))
        XCTAssertTrue(names.contains("run_command"))
        XCTAssertEqual(object["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(object["tool_choice"] as? String, "auto")
    }

    func testOpenCodeZenFreeModelDispatchesThroughItsPinnedCanonicalRoute()
        async throws
    {
        let model = "mimo-v2.5-free"
        installSSE(chatIntegrationSSE(
            responseID: "chatcmpl-zen-free",
            model: model
        ))
        let fixture = try makeZenSingleCallToolsGatewayFixture(
            requestID: "zen-free-canonical-tools",
            model: model
        )

        _ = try await collectAttemptEvents(
            await fixture.gateway.streamAttempt(fixture.invocation)
        )

        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
        let request = try XCTUnwrap(
            HostedTransportURLProtocolRegistry.shared.requests.first
        )
        XCTAssertEqual(request.url?.absoluteString,
                       "https://opencode.ai/zen/v1/chat/completions")
        XCTAssertTrue(fixture.credential.isEmpty)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, model)
        XCTAssertEqual((object["tools"] as? [Any])?.count, 20)
        XCTAssertEqual(object["max_tokens"] as? Int, 4_096)
        XCTAssertNil(object["max_completion_tokens"])
        XCTAssertEqual(object["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(object["tool_choice"] as? String, "auto")
    }

    func testOpenCodeZenPaidModelRejectsMissingCredentialBeforeHTTP()
        async throws
    {
        let fixture = try makeZenSingleCallToolsGatewayFixture(
            requestID: "zen-paid-missing-credential",
            model: "glm-5.1",
            credential: ""
        )

        do {
            _ = try await collectAttemptEvents(
                await fixture.gateway.streamAttempt(fixture.invocation)
            )
            XCTFail("A paid Zen route dispatched without a credential")
        } catch {
            // Expected: the transport rejects the empty credential before
            // opening the network boundary.
        }

        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 0)
    }

    func testSingleCallToolsAuthorityRejectsAnyDefinitionSpoofBeforeHTTP()
        async throws
    {
        let fixture = try makeSingleCallToolsGatewayFixture(
            requestID: "chat-canonical-tools-schema-spoof",
            mutateTools: { tools in
                guard let index = tools.firstIndex(where: {
                    $0.name == "write_file"
                }) else {
                    XCTFail("Canonical write_file definition is missing")
                    return
                }
                let original = tools[index]
                tools[index] = AgentProviders.ProviderToolDefinition(
                    name: original.name,
                    description: "Caller widened mutation contract",
                    parameters: original.parameters,
                    strict: original.strict
                )
            }
        )

        do {
            for try await _ in await fixture.gateway.streamAttempt(
                fixture.invocation
            ) {}
            XCTFail("A caller-spoofed mutation definition dispatched")
        } catch {
            // Closed provider failure is expected; no request may reach HTTP.
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 0)
    }

    func testSingleCallToolsAuthorityAcceptsPairedMutationHistory()
        async throws
    {
        installSSE(chatIntegrationSSE())
        let rawCallID = "call_mutation_provider_123"
        let fixture = try makeSingleCallToolsGatewayFixture(
            requestID: "chat-canonical-tools-follow-up",
            messages: [
                .init(role: .system, content: [.text("Use policy tools.")]),
                .init(role: .user, content: [.text("Create note.txt")]),
                .init(role: .assistant, content: [.toolCall(.init(
                    callID: rawCallID,
                    name: "write_file",
                    arguments: .object([
                        "contents": .string("hello"),
                        "path": .string("note.txt"),
                    ])
                ))]),
                .init(
                    role: .tool,
                    content: [.text("policy-bound receipt")],
                    toolCallID: rawCallID
                ),
            ]
        )

        _ = try await collectAttemptEvents(
            await fixture.gateway.streamAttempt(fixture.invocation)
        )
        let request = try XCTUnwrap(
            HostedTransportURLProtocolRegistry.shared.requests.last
        )
        let encoded = String(
            decoding: try XCTUnwrap(request.httpBody),
            as: UTF8.self
        )
        XCTAssertTrue(encoded.contains(rawCallID))
        XCTAssertTrue(encoded.contains("write_file"))
        XCTAssertTrue(encoded.contains("policy-bound receipt"))
    }

    func testReadOnlyTransportCannotWidenAFullRegistryRoute() async throws {
        let fixture = try makeFullCatalogWithReadOnlyTransportFixture(
            requestID: "read-authority-full-registry-spoof"
        )

        do {
            for try await _ in await fixture.gateway.streamAttempt(
                fixture.invocation
            ) {}
            XCTFail("Read-only transport unexpectedly accepted full registry")
        } catch {
            // The read transport requires its exact 12-definition snapshot.
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 0)
    }

    func testCanonicalResponsesGatewayDispatchesAfterBarrierAndCompletesAtEOF() async throws {
        installSSE(responsesIntegrationSSE())
        let fixture = try makeGatewayFixture(
            dialect: .openAIResponses,
            requestID: "responses-integration"
        )

        let stream = await fixture.gateway.streamAttempt(fixture.invocation)
        let events = try await collectAttemptEvents(stream)

        assertSuccessfulAttempt(
            events,
            scope: fixture.scope,
            responseID: "resp-canary",
            responseModel: versionedModel
        )
        let dispatches = await fixture.barrier.snapshot()
        XCTAssertEqual(dispatches.count, 1)
        XCTAssertEqual(dispatches.first?.scope, fixture.scope)
        XCTAssertEqual(dispatches.first?.route, fixture.descriptor.route)
        XCTAssertEqual(dispatches.first?.method, .post)
        XCTAssertEqual(dispatches.first?.relativePath, "/v1/responses")
        let requestCountsAtDispatch = await fixture.barrier.requestCountsAtDispatch()
        XCTAssertEqual(requestCountsAtDispatch, [0])
        assertSingleCredentialedRequest(
            credential: fixture.credential,
            path: "/v1/responses"
        )
        try assertAdapterEnvelope(dialect: .openAIResponses)
    }

    func testResponsesTransportCompletesAtEOFWithoutDoneSentinel() async throws {
        let completion = responsesCompletionJSON(responseID: "resp-eof")
        installSSE("data: \(completion)\n\n")
        let fixture = try makeFixture(dialect: .openAIResponses)

        let frames = try await collect(try await fixture.openStream())

        XCTAssertEqual(frames, [.json(try decodeJSON(completion))])
        assertSingleCredentialedRequest(
            credential: fixture.credential,
            path: fixture.descriptor.requestPath
        )
    }

    func testResponsesRejectsChatDoneSentinelAfterSemanticCompletion() async throws {
        let completion = responsesCompletionJSON(responseID: "resp-done")
        installSSE("data: \(completion)\n\ndata: [DONE]\n\n")
        let fixture = try makeFixture(dialect: .openAIResponses)

        await assertTransportError(.malformedSSE) {
            _ = try await collect(try await fixture.openStream())
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testChatDoneIsYieldedButTransportDrainsThroughEOF() async throws {
        let event = chatIdentityJSON(responseID: "chat-drain")
        installSSE(
            "data: \(event)\n\n" +
                "data: [DONE]\n\n" +
                ": legal trailing heartbeat proves EOF was drained\n\n"
        )
        let fixture = try makeFixture(dialect: .openAIChatCompletions)

        let frames = try await collect(try await fixture.openStream())

        XCTAssertEqual(frames, [.json(try decodeJSON(event)), .done])
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testChatEOFWithoutDoneSentinelFailsClosed() async throws {
        installSSE("data: \(chatIdentityJSON(responseID: "chat-no-done"))\n\n")
        let fixture = try makeFixture(dialect: .openAIChatCompletions)

        await assertTransportError(.chatStreamEndedWithoutDone) {
            _ = try await collect(try await fixture.openStream())
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testDataFrameAfterDoneFailsClosed() async throws {
        installSSE(
            "data: [DONE]\n\n" +
                "data: \(chatIdentityJSON(responseID: "illegal-trailer"))\n\n"
        )
        let fixture = try makeFixture(dialect: .openAIChatCompletions)

        await assertTransportError(.malformedSSE) {
            _ = try await collect(try await fixture.openStream())
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testChatEnvelopeRejectsToolImageAndExtraMessageShapesBeforeHTTP() async throws {
        let invalidMessages: [JSONValue] = [
            .object([
                "role": .string("tool"),
                "content": .string("tool result"),
            ]),
            .object([
                "role": .string("user"),
                "content": .array([.object([
                    "type": .string("image_url"),
                    "image_url": .string("https://example.invalid/image.png"),
                ])]),
            ]),
            .object([
                "role": .string("assistant"),
                "content": .string("dispatch"),
                "tool_calls": .array([]),
            ]),
        ]
        let fixture = try makeFixture(
            dialect: .openAIChatCompletions,
            requestID: "chat-envelope"
        )

        for message in invalidMessages {
            var body = validChatBody()
            body["messages"] = .array([message])
            let request = ProviderEncodedRequest(
                relativePath: fixture.descriptor.requestPath,
                body: .object(body)
            )
            await assertTransportError(.invalidRequestEnvelope) {
                _ = try await fixture.openStream(request: request)
            }
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 0)
    }

    func testResponsesEnvelopeRejectsContinuationAndBuiltInToolHistoryBeforeHTTP() async throws {
        let fixture = try makeFixture(
            dialect: .openAIResponses,
            requestID: "responses-envelope"
        )
        var continuationBody = validResponsesBody()
        continuationBody["previous_response_id"] = .string("resp-prior")
        await assertTransportError(.invalidRequestEnvelope) {
            _ = try await fixture.openStream(request: .init(
                relativePath: fixture.descriptor.requestPath,
                body: .object(continuationBody)
            ))
        }

        let forbiddenTypes = [
            "function_call_output",
            "web_search_call",
            "computer_call",
        ]
        for type in forbiddenTypes {
            var body = validResponsesBody()
            body["input"] = .array([.object([
                "type": .string(type),
                "call_id": .string("call-1"),
                "output": .string("untrusted history"),
            ])])
            await assertTransportError(.invalidRequestEnvelope) {
                _ = try await fixture.openStream(request: .init(
                    relativePath: fixture.descriptor.requestPath,
                    body: .object(body)
                ))
            }
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 0)
    }

    func testCredentialCannotAppearAnywhereInTextOnlyEnvelope() async throws {
        let fixture = try makeFixture(
            dialect: .openAIChatCompletions,
            requestID: "credential-envelope"
        )
        var body = validChatBody()
        body["messages"] = .array([.object([
            "role": .string("user"),
            "content": .string("prefix-\(fixture.credential)-suffix"),
        ])])

        await assertTransportError(.credentialPresentInRequestBody) {
            _ = try await fixture.openStream(request: .init(
                relativePath: fixture.descriptor.requestPath,
                body: .object(body)
            ))
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 0)
    }

    func testFullCredentialEchoInAnyJSONKeyOrStringIsRejectedBeforeYield() async throws {
        let keyFixture = try makeFixture(
            dialect: .openAIChatCompletions,
            requestID: "credential-response-key"
        )
        let keyEcho = "{\"id\":\"chat-credential-key\",\"model\":\"\(baseModel)\"," +
            "\"\(keyFixture.credential)\":\"hostile\",\"choices\":[]}"
        installSSE("data: \(keyEcho)\n\ndata: [DONE]\n\n")
        let keyFrames = await collectExpectingCredentialEchoRejection(
            try await keyFixture.openStream(),
            credential: keyFixture.credential
        )
        XCTAssertTrue(keyFrames.isEmpty)

        let valueFixture = try makeFixture(
            dialect: .openAIResponses,
            requestID: "credential-response-value"
        )
        let valueEcho = "{\"type\":\"response.created\",\"response\":{" +
            "\"id\":\"resp-credential-value\",\"model\":\"\(baseModel)\"," +
            "\"metadata\":{\"echo\":\"\(valueFixture.credential)\"}}}"
        installSSE("data: \(valueEcho)\n\n")
        let valueFrames = await collectExpectingCredentialEchoRejection(
            try await valueFixture.openStream(),
            credential: valueFixture.credential
        )
        XCTAssertTrue(valueFrames.isEmpty)
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 2)
    }

    func testChatCredentialSplitIntoSingleCharacterDeltasNeverYieldsCompletingFrame() async throws {
        let signal = ProducerTerminationSignal()
        let fixture = try makeFixture(
            dialect: .openAIChatCompletions,
            requestID: "credential-chat-character-split",
            producerDidTerminate: { signal.fire() }
        )
        let fragments = fixture.credential.map(String.init)
        let responseID = "chat-credential-character-split"
        let payload = fragments.map { fragment in
            "data: \(chatTextDeltaJSON(responseID: responseID, text: fragment))\n\n"
        }.joined() +
            "data: \(chatTextDeltaJSON(responseID: responseID, text: "must-not-yield"))\n\n" +
            "data: [DONE]\n\n"
        installSSE(payload)

        let frames = await collectExpectingCredentialEchoRejection(
            try await fixture.openStream(),
            credential: fixture.credential
        )

        XCTAssertEqual(frames.count, fragments.count - 1)
        XCTAssertFalse(frames.contains(.done))
        XCTAssertEqual(
            frames.last,
            .json(try decodeJSON(chatTextDeltaJSON(
                responseID: responseID,
                text: fragments[fragments.count - 2]
            )))
        )
        let producerTerminated = await signal.wait(timeout: 2)
        XCTAssertTrue(producerTerminated)
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testResponsesCredentialSplitAcrossOutputTextDeltasNeverYieldsCompletingFrame() async throws {
        let fixture = try makeFixture(
            dialect: .openAIResponses,
            requestID: "credential-responses-split"
        )
        let responseID = "resp-credential-split"
        let fragments = [
            String(fixture.credential.prefix(7)),
            String(fixture.credential.dropFirst(7).prefix(9)),
            String(fixture.credential.dropFirst(16)),
        ]
        let payload = "data: \(responsesCreatedJSON(responseID: responseID))\n\n" +
            fragments.map { fragment in
                "data: \(responsesTextDeltaJSON(responseID: responseID, text: fragment))\n\n"
            }.joined() +
            "data: \(responsesCompletionJSON(responseID: responseID, text: "must-not-yield"))\n\n"
        installSSE(payload)

        let frames = await collectExpectingCredentialEchoRejection(
            try await fixture.openStream(),
            credential: fixture.credential
        )

        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.first, .json(try decodeJSON(
            responsesCreatedJSON(responseID: responseID)
        )))
        XCTAssertEqual(frames.last, .json(try decodeJSON(
            responsesTextDeltaJSON(responseID: responseID, text: fragments[1])
        )))
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testCredentialPrefixOnlyAndOrdinarySplitTextRemainAllowed() async throws {
        let fixture = try makeFixture(
            dialect: .openAIChatCompletions,
            requestID: "credential-prefix-only"
        )
        let responseID = "chat-credential-prefix-only"
        let prefix = String(fixture.credential.dropLast())
        let payload = "data: \(chatTextDeltaJSON(responseID: responseID, text: prefix))\n\n" +
            "data: \(chatTextDeltaJSON(responseID: responseID, text: " ordinary"))\n\n" +
            "data: \(chatTextDeltaJSON(responseID: responseID, text: " split text"))\n\n" +
            "data: [DONE]\n\n"
        installSSE(payload)

        let frames = try await collect(try await fixture.openStream())

        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames.last, .done)
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testCredentialLikeButDifferentSingleCharacterSplitTextRemainsAllowed() async throws {
        let fixture = try makeFixture(
            dialect: .openAIChatCompletions,
            requestID: "credential-near-match"
        )
        let responseID = "chat-credential-near-match"
        let nearMatch = String(fixture.credential.dropLast()) + "X"
        let payload = nearMatch.map(String.init).map { fragment in
            "data: \(chatTextDeltaJSON(responseID: responseID, text: fragment))\n\n"
        }.joined() + "data: [DONE]\n\n"
        installSSE(payload)

        let frames = try await collect(try await fixture.openStream())

        XCTAssertEqual(frames.count, nearMatch.count + 1)
        XCTAssertEqual(frames.last, .done)
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testAttemptScopeRequiresExactCanonicalPositiveUIntSuffix() async throws {
        let completion = responsesCompletionJSON(responseID: "resp-scope")
        installSSE("data: \(completion)\n\n")
        let fixture = try makeFixture(
            dialect: .openAIResponses,
            requestID: "scope-rule"
        )
        let invalidScopes = [
            ProviderAttemptScope(
                requestID: "scope-rule",
                attemptID: .init(rawValue: "attempt-1")
            ),
            ProviderAttemptScope(
                requestID: "scope-rule",
                attemptID: .init(rawValue: "scope-rule:provider-attempt:0")
            ),
            ProviderAttemptScope(
                requestID: "scope-rule",
                attemptID: .init(rawValue: "scope-rule:provider-attempt:01")
            ),
            ProviderAttemptScope(
                requestID: "scope-rule",
                attemptID: .init(rawValue: "scope-rule:provider-attempt:+1")
            ),
            ProviderAttemptScope(
                requestID: "scope-rule",
                attemptID: .init(rawValue: "scope-rule:provider-attempt:18446744073709551616")
            ),
            ProviderAttemptScope(
                requestID: "scope rule",
                attemptID: .init(rawValue: "scope rule:provider-attempt:1")
            ),
            ProviderAttemptScope(
                requestID: "scope-rule",
                attemptID: .init(rawValue: "scope-rule:provider-attempt:1\u{200D}")
            ),
        ]

        for scope in invalidScopes {
            await assertTransportError(.invalidAttemptScope) {
                _ = try await fixture.openStream(scope: scope)
            }
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 0)

        let validScope = ProviderAttemptScope(
            requestID: "scope-rule",
            attemptID: .init(rawValue: "scope-rule:provider-attempt:42")
        )
        _ = try await collect(try await fixture.openStream(scope: validScope))
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testWireIdentityRejectsUnsafeOversizedAndUnrelatedValues() async throws {
        let cases: [(ProviderAdapterDialect, String)] = [
            (
                .openAIChatCompletions,
                "data: \(chatIdentityJSON(responseID: "chat bad"))\n\ndata: [DONE]\n\n"
            ),
            (
                .openAIChatCompletions,
                "data: \(chatIdentityJSON(responseID: "chat\u{200D}format"))\n\ndata: [DONE]\n\n"
            ),
            (
                .openAIResponses,
                "data: \(responsesCreatedJSON(responseID: String(repeating: "r", count: 513)))\n\n"
            ),
            (
                .openAIChatCompletions,
                "data: \(chatIdentityJSON(responseID: "chat-model", model: "other-model"))\n\ndata: [DONE]\n\n"
            ),
            (
                .openAIResponses,
                "data: \(responsesCreatedJSON(responseID: "resp-date", model: "gpt-4.1-mini-2025-99-99"))\n\n"
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            installSSE(testCase.1)
            let fixture = try makeFixture(
                dialect: testCase.0,
                requestID: "wire-identity-\(index)"
            )
            await assertTransportError(.invalidWireIdentity) {
                _ = try await collect(try await fixture.openStream())
            }
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, cases.count)

        let chainedIdentity = chatIdentityJSON(
            responseID: "chat-chained",
            model: versionedModel + "-2026-01-01"
        )
        installSSE("data: \(chainedIdentity)\n\ndata: [DONE]\n\n")
        let versionedFixture = try makeFixture(
            dialect: .openAIChatCompletions,
            requestID: "wire-version-chain",
            model: versionedModel
        )
        await assertTransportError(.invalidWireIdentity) {
            _ = try await collect(try await versionedFixture.openStream())
        }
        XCTAssertEqual(
            HostedTransportURLProtocolRegistry.shared.requestCount,
            cases.count + 1
        )
    }

    func testWireIdentityCannotChangeAcrossChatOrResponsesFrames() async throws {
        installSSE(
            "data: \(chatIdentityJSON(responseID: "chat-a"))\n\n" +
                "data: \(chatIdentityJSON(responseID: "chat-b"))\n\n" +
                "data: [DONE]\n\n"
        )
        let chat = try makeFixture(
            dialect: .openAIChatCompletions,
            requestID: "chat-identity-change"
        )
        await assertTransportError(.invalidWireIdentity) {
            _ = try await collect(try await chat.openStream())
        }

        installSSE(
            "data: \(responsesCreatedJSON(responseID: "resp-a"))\n\n" +
                "data: \(responsesCompletionJSON(responseID: "resp-b"))\n\n"
        )
        let responses = try makeFixture(
            dialect: .openAIResponses,
            requestID: "responses-identity-change"
        )
        await assertTransportError(.invalidWireIdentity) {
            _ = try await collect(try await responses.openStream())
        }

        installSSE(
            "data: \(chatIdentityJSON(responseID: "chat-model-stable"))\n\n" +
                "data: \(chatIdentityJSON(responseID: "chat-model-stable", model: versionedModel))\n\n" +
                "data: [DONE]\n\n"
        )
        let chatModel = try makeFixture(
            dialect: .openAIChatCompletions,
            requestID: "chat-model-change"
        )
        await assertTransportError(.invalidWireIdentity) {
            _ = try await collect(try await chatModel.openStream())
        }

        let changedModelCompletion = responsesCompletionJSON(
            responseID: "resp-model-stable",
            model: versionedModel
        )
        installSSE(
            "data: \(responsesCreatedJSON(responseID: "resp-model-stable"))\n\n" +
                "data: \(changedModelCompletion)\n\n"
        )
        let responsesModel = try makeFixture(
            dialect: .openAIResponses,
            requestID: "responses-model-change"
        )
        await assertTransportError(.invalidWireIdentity) {
            _ = try await collect(try await responsesModel.openStream())
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 4)
    }

    func testBufferOverflowUsesProducerTerminationSignalAndFailsClosed() async throws {
        let signal = ProducerTerminationSignal()
        let events = "data: \(responsesCreatedJSON(responseID: "resp-backpressure"))\n\n" +
            (0 ..< 7)
            .map { index in
                "data: \(responsesProgressJSON(responseID: "resp-backpressure", marker: index))\n\n"
            }
            .joined()
        installSSE(events)
        let fixture = try makeFixture(
            dialect: .openAIResponses,
            requestID: "backpressure",
            limits: testLimits(maximumBufferedWireFrames: 1),
            producerDidTerminate: { signal.fire() }
        )

        let stream = try await fixture.openStream()
        let producerTerminated = await signal.wait(timeout: 2)
        XCTAssertTrue(producerTerminated)
        await assertTransportError(.consumerBackpressureExceeded) {
            _ = try await collect(stream)
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testRejectsContentTypePrefixCollision() async throws {
        HostedTransportURLProtocolRegistry.shared.install(.init(
            statusCode: 200,
            headers: ["Content-Type": "text/event-streaming"],
            chunks: []
        ))
        let fixture = try makeFixture(
            dialect: .openAIResponses,
            requestID: "mime-prefix"
        )

        await assertTransportError(.invalidContentType) {
            _ = try await collect(try await fixture.openStream())
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testRedirectDelegateRejectsCredentialedProposalWithoutStartingNetwork() throws {
        let origin = try XCTUnwrap(URL(string: "https://127.0.0.1:9/origin"))
        let destination = try XCTUnwrap(URL(string: "https://127.0.0.1:10/credential-sink"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: origin,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": destination.absoluteString]
        ))
        var proposed = URLRequest(url: destination)
        proposed.httpMethod = "POST"
        proposed.setValue("Bearer should-never-dispatch", forHTTPHeaderField: "Authorization")

        // Creating a data task is inert until resume(). Calling the delegate
        // method directly exercises the exact production callback with no
        // protocol loader and therefore no path to either loopback endpoint.
        let session = URLSession(configuration: .ephemeral)
        let suspendedTask = session.dataTask(with: URLRequest(url: origin))
        XCTAssertEqual(suspendedTask.state, .suspended)
        defer {
            suspendedTask.cancel()
            session.invalidateAndCancel()
        }
        let decision = LockedRedirectDecisionRecorder()
        HostedProviderNoRedirectDelegate.shared.urlSession(
            session,
            task: suspendedTask,
            willPerformHTTPRedirection: response,
            newRequest: proposed,
            completionHandler: { decision.record($0) }
        )

        XCTAssertEqual(decision.callCount, 1)
        XCTAssertNil(decision.followedRequest)
        XCTAssertEqual(suspendedTask.state, .suspended)
        XCTAssertEqual(
            proposed.value(forHTTPHeaderField: "Authorization"),
            "Bearer should-never-dispatch"
        )
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 0)
    }

    func testHTTPFailureIsSanitizedAndErrorBodyConsumptionIsBounded() async throws {
        let consumption = LockedIntRecorder()
        HostedTransportURLProtocolRegistry.shared.install(.init(
            statusCode: 401,
            headers: ["Content-Type": "application/json"],
            chunks: [Data(String(repeating: "raw-secret-provider-body", count: 64).utf8)]
        ))
        let fixture = try makeFixture(
            dialect: .openAIResponses,
            requestID: "http-failure",
            limits: testLimits(maximumHTTPErrorBodyBytes: 4),
            httpErrorBodyDidConsume: { consumption.record($0) }
        )

        do {
            _ = try await collect(try await fixture.openStream())
            XCTFail("Expected an authentication failure")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.category, .authentication)
            XCTAssertEqual(failure.statusCode, 401)
            XCTAssertFalse(failure.publicMessage.contains("raw-secret-provider-body"))
            XCTAssertFalse(failure.code.contains(fixture.credential))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(consumption.value, 4)
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testInjectedProviderFailureCodeAndMessageAreRemappedToFixedTransportFailure() async throws {
        let fixture = try makeFixture(
            dialect: .openAIResponses,
            requestID: "injected-provider-failure"
        )
        let hostileMarker = "caller-controlled-\(fixture.credential)"
        HostedTransportURLProtocolRegistry.shared.install(.init(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: [],
            terminalFailure: ProviderFailure(
                category: .authentication,
                code: hostileMarker,
                publicMessage: hostileMarker,
                providerID: fixture.descriptor.route.providerID,
                adapterID: fixture.descriptor.route.adapterID,
                statusCode: 401
            )
        ))

        do {
            _ = try await collect(try await fixture.openStream())
            XCTFail("Expected a fixed transport failure")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.category, .transport)
            XCTAssertEqual(failure.code, "provider_transport_failed")
            XCTAssertEqual(failure.providerID, fixture.descriptor.route.providerID)
            XCTAssertEqual(failure.adapterID, fixture.descriptor.route.adapterID)
            XCTAssertNil(failure.statusCode)
            XCTAssertFalse(failure.code.contains(hostileMarker))
            XCTAssertFalse(failure.publicMessage.contains(hostileMarker))
            XCTAssertFalse(failure.publicMessage.contains(fixture.credential))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testGenerationOptionsRequireTrustedNumericShapesAndRangesBeforeHTTP() async throws {
        let fixture = try makeFixture(
            dialect: .openAIChatCompletions,
            requestID: "generation-options"
        )
        let maximum = fixture.descriptor.route.capabilities.maximumOutputTokens
        var invalidBodies: [[String: JSONValue]] = []

        var signedMaximum = validChatBody()
        signedMaximum["max_completion_tokens"] = .number(.integer(1))
        invalidBodies.append(signedMaximum)

        var fractionalMaximum = validChatBody()
        fractionalMaximum["max_completion_tokens"] = .number(.floatingPoint(1.5))
        invalidBodies.append(fractionalMaximum)

        var oversizedMaximum = validChatBody()
        oversizedMaximum["max_completion_tokens"] = .number(.unsignedInteger(maximum + 1))
        invalidBodies.append(oversizedMaximum)

        var integerTemperature = validChatBody()
        integerTemperature["temperature"] = .number(.integer(1))
        invalidBodies.append(integerTemperature)

        var highTemperature = validChatBody()
        highTemperature["temperature"] = .number(.floatingPoint(2.000_001))
        invalidBodies.append(highTemperature)

        var nonfiniteTemperature = validChatBody()
        nonfiniteTemperature["temperature"] = .number(.floatingPoint(.nan))
        invalidBodies.append(nonfiniteTemperature)

        for body in invalidBodies {
            await assertTransportError(.invalidRequestEnvelope) {
                _ = try await fixture.openStream(request: .init(
                    relativePath: fixture.descriptor.requestPath,
                    body: .object(body)
                ))
            }
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 0)

        var acceptedBody = validChatBody()
        acceptedBody["max_completion_tokens"] = .number(.unsignedInteger(maximum))
        acceptedBody["temperature"] = .number(.floatingPoint(2))
        installSSE(
            "data: \(chatIdentityJSON(responseID: "chat-options"))\n\n" +
                "data: [DONE]\n\n"
        )
        _ = try await collect(try await fixture.openStream(request: .init(
            relativePath: fixture.descriptor.requestPath,
            body: .object(acceptedBody)
        )))
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)

        let responsesFixture = try makeFixture(
            dialect: .openAIResponses,
            requestID: "responses-generation-options"
        )
        var signedResponsesMaximum = validResponsesBody()
        signedResponsesMaximum["max_output_tokens"] = .number(.integer(1))
        await assertTransportError(.invalidRequestEnvelope) {
            _ = try await responsesFixture.openStream(request: .init(
                relativePath: responsesFixture.descriptor.requestPath,
                body: .object(signedResponsesMaximum)
            ))
        }
        var unknownReasoning = validResponsesBody()
        unknownReasoning["reasoning"] = .object([
            "effort": .string("infinite"),
            "summary": .string("auto"),
        ])
        await assertTransportError(.invalidRequestEnvelope) {
            _ = try await responsesFixture.openStream(request: .init(
                relativePath: responsesFixture.descriptor.requestPath,
                body: .object(unknownReasoning)
            ))
        }
        var injectedReasoning = validResponsesBody()
        injectedReasoning["reasoning"] = .object([
            "effort": .string("max"),
            "hidden_prompt": .string("unsafe"),
        ])
        await assertTransportError(.invalidRequestEnvelope) {
            _ = try await responsesFixture.openStream(request: .init(
                relativePath: responsesFixture.descriptor.requestPath,
                body: .object(injectedReasoning)
            ))
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testRequestStructureDepthAndNodeLimitsRunBeforeRecursiveScans() async throws {
        let depthFixture = try makeFixture(
            dialect: .openAIResponses,
            requestID: "request-depth",
            limits: testLimits(maximumRequestJSONDepth: 6)
        )
        var nested: JSONValue = .string("leaf")
        for index in 0 ..< 8 {
            nested = .object(["level-\(index)": nested])
        }
        var deepBody = validResponsesBody()
        deepBody["metadata"] = .object(["nested": nested])
        await assertTransportError(.requestStructureTooComplex) {
            _ = try await depthFixture.openStream(request: .init(
                relativePath: depthFixture.descriptor.requestPath,
                body: .object(deepBody)
            ))
        }

        let nodeFixture = try makeFixture(
            dialect: .openAIResponses,
            requestID: "request-nodes",
            limits: testLimits(maximumRequestJSONNodes: 16)
        )
        var wideBody = validResponsesBody()
        wideBody["metadata"] = .object([
            "wide": .array((0 ..< 32).map { .number(.integer(Int64($0))) }),
        ])
        await assertTransportError(.requestStructureTooComplex) {
            _ = try await nodeFixture.openStream(request: .init(
                relativePath: nodeFixture.descriptor.requestPath,
                body: .object(wideBody)
            ))
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 0)
    }

    func testRequestBodyLimitUsesExactEncodedBoundaryBeforeHTTP() async throws {
        let encodedBody = try encoded(validResponsesBody())
        let exact = testLimits(maximumRequestBodyBytes: encodedBody.count)
        let below = testLimits(maximumRequestBodyBytes: encodedBody.count - 1)
        let completion = responsesCompletionJSON(responseID: "resp-body-limit")
        installSSE("data: \(completion)\n\n")

        let accepted = try makeFixture(
            dialect: .openAIResponses,
            requestID: "body-limit-exact",
            limits: exact
        )
        _ = try await collect(try await accepted.openStream())

        let rejected = try makeFixture(
            dialect: .openAIResponses,
            requestID: "body-limit-below",
            limits: below
        )
        await assertTransportError(.requestBodyTooLarge) {
            _ = try await rejected.openStream()
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testSSELineEventFrameAndTotalStreamLimitsFailDeterministically() async throws {
        let limitCases: [(AgentHostedProviderTransport.Limits, String, AgentHostedProviderTransportError)] = [
            (
                testLimits(maximumSSELineBytes: 16),
                "data: \(String(repeating: "x", count: 32))\n",
                .lineTooLarge
            ),
            (
                testLimits(maximumSSEEventBytes: 8),
                "data: {\"type\":\"response.created\"}\n\n",
                .eventTooLarge
            ),
            (
                testLimits(maximumFrameCount: 1),
                "data: \(responsesCreatedJSON(responseID: "resp-frame"))\n\n" +
                    "data: \(responsesProgressJSON(responseID: "resp-frame", marker: 1))\n\n",
                .frameLimitExceeded
            ),
            (
                testLimits(maximumStreamBytes: 8),
                ":123456789\n\n",
                .streamTooLarge
            ),
        ]

        for (index, limitCase) in limitCases.enumerated() {
            installSSE(limitCase.1)
            let fixture = try makeFixture(
                dialect: .openAIResponses,
                requestID: "limit-\(index)",
                limits: limitCase.0
            )
            await assertTransportError(limitCase.2) {
                _ = try await collect(try await fixture.openStream())
            }
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, limitCases.count)
    }

    func testDuplicateAttemptScopeNeverMakesSecondRequest() async throws {
        let completion = responsesCompletionJSON(responseID: "resp-duplicate")
        installSSE("data: \(completion)\n\n")
        let fixture = try makeFixture(
            dialect: .openAIResponses,
            requestID: "duplicate"
        )
        _ = try await collect(try await fixture.openStream())

        await assertTransportError(.duplicateAttemptScope) {
            _ = try await fixture.openStream()
        }
        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    func testConsumerCancellationStopsTheSingleURLLoad() async throws {
        HostedTransportURLProtocolRegistry.shared.install(.init(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: [],
            finishes: false
        ))
        let fixture = try makeFixture(
            dialect: .openAIResponses,
            requestID: "cancel"
        )
        let stream = try await fixture.openStream()
        let consumer = Task {
            do {
                _ = try await collect(stream)
            } catch {
                // Cancellation can surface as either sequence termination or
                // the transport's sanitized provider cancellation.
            }
        }

        try await waitUntilRequestCount(1)
        consumer.cancel()
        _ = await consumer.result
        try await waitUntilStopCount(1)

        XCTAssertEqual(HostedTransportURLProtocolRegistry.shared.requestCount, 1)
    }

    private func assertSuccessfulAttempt(
        _ events: [ProviderAttemptEvent],
        scope: ProviderAttemptScope,
        responseID: String,
        responseModel: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            events.map(\.scope),
            Array(repeating: scope, count: 4),
            file: file,
            line: line
        )
        // ProviderStreamSession's public contract is zero-based and contiguous;
        // the package contract tests assert this same 0..<count sequence.
        XCTAssertEqual(
            events.map(\.sequence),
            Array(0 ..< UInt64(events.count)),
            file: file,
            line: line
        )
        XCTAssertEqual(events.map(\.event), [
            .responseStarted(.init(
                responseID: responseID,
                model: .init(rawValue: responseModel)
            )),
            .textDelta(.init(outputIndex: 0, text: "Hello")),
            .usage(.init(inputTokens: 2, outputTokens: 1)),
            .responseCompleted(.init(
                responseID: responseID,
                finishReason: .completed
            )),
        ], file: file, line: line)
    }

    private func assertSingleCredentialedRequest(
        credential: String,
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let requests = HostedTransportURLProtocolRegistry.shared.requests
        XCTAssertEqual(requests.count, 1, file: file, line: line)
        guard let request = requests.first else { return }
        XCTAssertEqual(request.url?.scheme, "https", file: file, line: line)
        XCTAssertEqual(request.url?.host, "api.openai.com", file: file, line: line)
        XCTAssertEqual(request.url?.path, path, file: file, line: line)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(credential)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            "text/event-stream",
            file: file,
            line: line
        )
        XCTAssertNil(
            request.httpBody?.range(of: Data(credential.utf8)),
            file: file,
            line: line
        )
    }

    private func assertAdapterEnvelope(
        dialect: ProviderAdapterDialect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let request = try XCTUnwrap(
            HostedTransportURLProtocolRegistry.shared.requests.first,
            file: file,
            line: line
        )
        let data = try XCTUnwrap(request.httpBody, file: file, line: line)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case let .object(body) = value else {
            XCTFail("Expected an encoded object envelope", file: file, line: line)
            return
        }
        XCTAssertEqual(body["model"], .string(baseModel), file: file, line: line)
        XCTAssertEqual(body["stream"], .bool(true), file: file, line: line)
        XCTAssertEqual(body["metadata"], .object([:]), file: file, line: line)
        XCTAssertNil(body["tools"], file: file, line: line)
        XCTAssertNil(body["tool_choice"], file: file, line: line)
        XCTAssertNil(body["previous_response_id"], file: file, line: line)
        switch dialect {
        case .openAIChatCompletions:
            XCTAssertEqual(
                body["stream_options"],
                .object(["include_usage": .bool(true)]),
                file: file,
                line: line
            )
            guard let messagesValue = body["messages"],
                  case let .array(messages) = messagesValue
            else {
                XCTFail("Expected canonical Chat messages", file: file, line: line)
                return
            }
            XCTAssertEqual(messages.count, 2, file: file, line: line)
        case .openAIResponses:
            guard let inputValue = body["input"],
                  case let .array(input) = inputValue
            else {
                XCTFail("Expected canonical Responses input", file: file, line: line)
                return
            }
            XCTAssertEqual(input.count, 2, file: file, line: line)
        case .openAICompatibleChat:
            XCTFail("Caller-compatible routes are forbidden", file: file, line: line)
        }
    }

    private func assertTransportError(
        _ expected: AgentHostedProviderTransportError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as AgentHostedProviderTransportError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func collectExpectingCredentialEchoRejection(
        _ stream: AsyncThrowingStream<ProviderWireFrame, any Error>,
        credential: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [ProviderWireFrame] {
        var frames: [ProviderWireFrame] = []
        do {
            for try await frame in stream { frames.append(frame) }
            XCTFail("Expected response credential rejection", file: file, line: line)
        } catch let error as AgentHostedProviderTransportError {
            XCTAssertEqual(
                error,
                .credentialPresentInProviderResponse,
                file: file,
                line: line
            )
            XCTAssertFalse(
                error.localizedDescription.contains(credential),
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
        return frames
    }

    private func waitUntilRequestCount(_ count: Int) async throws {
        for _ in 0 ..< 100 where HostedTransportURLProtocolRegistry.shared.requestCount < count {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThanOrEqual(HostedTransportURLProtocolRegistry.shared.requestCount, count)
    }

    private func waitUntilStopCount(_ count: Int) async throws {
        for _ in 0 ..< 100 where HostedTransportURLProtocolRegistry.shared.stopCount < count {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertGreaterThanOrEqual(HostedTransportURLProtocolRegistry.shared.stopCount, count)
    }
}

private let baseModel = "gpt-4.1-mini"
private let versionedModel = "gpt-4.1-mini-2025-04-14"

private struct HostedTransportFixture {
    let transport: AgentHostedProviderTransport
    let request: ProviderEncodedRequest
    let descriptor: ProviderAdapterDescriptor
    let scope: ProviderAttemptScope
    let credential: String

    func openStream(
        request replacementRequest: ProviderEncodedRequest? = nil,
        scope replacementScope: ProviderAttemptScope? = nil
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        try await transport.stream(
            request: replacementRequest ?? request,
            descriptor: descriptor,
            scope: replacementScope ?? scope
        )
    }
}

private struct HostedGatewayFixture {
    let gateway: ModelGateway
    let invocation: ProviderSingleAttemptInvocation
    let barrier: DurableRecordingDispatchBarrier
    let descriptor: ProviderAdapterDescriptor
    let scope: ProviderAttemptScope
    let credential: String
}

private struct TrustedHostedMaterial {
    let catalog: TrustedHostedProviderCatalog
    let capability: HostedTextOnlyProviderCapability
    let descriptor: ProviderAdapterDescriptor
}

private func makeFixture(
    dialect: ProviderAdapterDialect,
    requestID: String = UUID().uuidString.lowercased(),
    model: String = baseModel,
    limits: AgentHostedProviderTransport.Limits = testLimits(),
    producerDidTerminate: (@Sendable () -> Void)? = nil,
    httpErrorBodyDidConsume: (@Sendable (Int) -> Void)? = nil
) throws -> HostedTransportFixture {
    let material = try makeTrustedMaterial(dialect: dialect, model: model)
    let credential = "sk-test-only-hosted-credential"
    let body: JSONValue
    switch dialect {
    case .openAIChatCompletions:
        body = .object(validChatBody(model: model))
    case .openAIResponses:
        body = .object(validResponsesBody(model: model))
    case .openAICompatibleChat:
        fatalError("The hosted canary deliberately rejects caller-compatible routes")
    }

    return HostedTransportFixture(
        transport: AgentHostedProviderTransport(
            credential: credential,
            capability: material.capability,
            session: makeHostedTransportTestSession(),
            limits: limits,
            producerDidTerminate: producerDidTerminate,
            httpErrorBodyDidConsume: httpErrorBodyDidConsume
        ),
        request: ProviderEncodedRequest(
            relativePath: material.descriptor.requestPath,
            body: body
        ),
        descriptor: material.descriptor,
        scope: ProviderAttemptScope(
            requestID: requestID,
            attemptID: .init(rawValue: "\(requestID):provider-attempt:1")
        ),
        credential: credential
    )
}

private func makeGatewayFixture(
    dialect: ProviderAdapterDialect,
    requestID: String
) throws -> HostedGatewayFixture {
    let material = try makeTrustedMaterial(dialect: dialect)
    let credential = "sk-test-only-hosted-credential"
    let transport = AgentHostedProviderTransport(
        credential: credential,
        capability: material.capability,
        session: makeHostedTransportTestSession(),
        limits: testLimits()
    )
    let gateway = ModelGateway(
        catalog: try material.catalog.providerCatalog(),
        transport: transport
    )
    let scope = ProviderAttemptScope(
        requestID: requestID,
        attemptID: .init(rawValue: "\(requestID):provider-attempt:1")
    )
    let barrier = DurableRecordingDispatchBarrier()
    let request = CanonicalProviderRequest(
        requestID: requestID,
        model: .init(rawValue: baseModel),
        messages: [
            .init(role: .system, content: [.text("Be concise.")]),
            .init(role: .user, content: [.text("Say hello.")]),
        ],
        options: .init(toolChoice: .none)
    )
    return HostedGatewayFixture(
        gateway: gateway,
        invocation: ProviderSingleAttemptInvocation(
            request: request,
            adapterID: material.catalog.adapterID,
            scope: scope,
            barrier: barrier
        ),
        barrier: barrier,
        descriptor: material.descriptor,
        scope: scope,
        credential: credential
    )
}

private func makeReadToolsGatewayFixture(
    requestID: String,
    messages: [ProviderMessage]? = nil,
    mutateTools: ((inout [AgentProviders.ProviderToolDefinition]) -> Void)? = nil
) throws -> HostedGatewayFixture {
    let model = ProviderModelID(rawValue: baseModel)
    let catalog = TrustedHostedProviderCatalog.openAIChatCompletions(
        model: model,
        capabilities: .hostedChatReadOnlyToolsCanaryBaseline
    )
    let capability = try catalog.hostedReadOnlyToolsCapability(
        adapterID: catalog.adapterID
    )
    let adapter = try catalog.providerCatalog().adapter(id: catalog.adapterID)
    let credential = "sk-test-only-hosted-credential"
    let transport = AgentHostedProviderTransport(
        credential: credential,
        readOnlyToolsCapability: capability,
        session: makeHostedTransportTestSession(),
        limits: testLimits()
    )
    let gateway = ModelGateway(
        catalog: try catalog.providerCatalog(),
        transport: transport
    )
    let scope = ProviderAttemptScope(
        requestID: requestID,
        attemptID: .init(rawValue: "\(requestID):provider-attempt:1")
    )
    let barrier = DurableRecordingDispatchBarrier()
    var tools = SandboxToolCatalog.all.map(\.descriptor).filter {
        $0.effectClass == .readOnlyLocal
    }.map {
        AgentHostedReadOnlyCanaryCoordinator.providerDefinition(for: $0)
    }
    mutateTools?(&tools)
    let request = CanonicalProviderRequest(
        requestID: requestID,
        model: model,
        messages: messages ?? [
            .init(role: .system, content: [.text("Inspect only.")]),
            .init(role: .user, content: [.text("Read the workspace.")]),
        ],
        tools: tools,
        options: .init(
            maximumOutputTokens: 4_096,
            temperature: 0,
            parallelToolCalls: false,
            toolChoice: .auto
        )
    )
    return HostedGatewayFixture(
        gateway: gateway,
        invocation: ProviderSingleAttemptInvocation(
            request: request,
            adapterID: catalog.adapterID,
            scope: scope,
            barrier: barrier
        ),
        barrier: barrier,
        descriptor: adapter.descriptor,
        scope: scope,
        credential: credential
    )
}

private func makeSingleCallToolsGatewayFixture(
    requestID: String,
    messages: [ProviderMessage]? = nil,
    mutateTools: ((inout [AgentProviders.ProviderToolDefinition]) -> Void)? = nil
) throws -> HostedGatewayFixture {
    let model = ProviderModelID(rawValue: baseModel)
    let catalog = TrustedHostedProviderCatalog.openAIChatCompletions(
        model: model,
        capabilities: .hostedChatSingleCallToolsBaseline
    )
    let capability = try catalog.hostedSingleCallToolsCapability(
        adapterID: catalog.adapterID
    )
    let adapter = try catalog.providerCatalog().adapter(id: catalog.adapterID)
    let credential = "sk-test-only-hosted-credential"
    let transport = AgentHostedProviderTransport(
        credential: credential,
        singleCallToolsCapability: capability,
        session: makeHostedTransportTestSession(),
        limits: testLimits()
    )
    let gateway = ModelGateway(
        catalog: try catalog.providerCatalog(),
        transport: transport
    )
    let scope = ProviderAttemptScope(
        requestID: requestID,
        attemptID: .init(rawValue: "\(requestID):provider-attempt:1")
    )
    let barrier = DurableRecordingDispatchBarrier()
    var tools = SandboxToolCatalog.all.map(\.descriptor).map {
        AgentHostedReadOnlyCanaryCoordinator.providerDefinition(for: $0)
    }
    mutateTools?(&tools)
    let request = CanonicalProviderRequest(
        requestID: requestID,
        model: model,
        messages: messages ?? [
            .init(role: .system, content: [.text("Use canonical tools.")]),
            .init(role: .user, content: [.text("Complete the task.")]),
        ],
        tools: tools,
        options: .init(
            maximumOutputTokens: 4_096,
            temperature: 0,
            parallelToolCalls: false,
            toolChoice: .auto
        )
    )
    return HostedGatewayFixture(
        gateway: gateway,
        invocation: ProviderSingleAttemptInvocation(
            request: request,
            adapterID: catalog.adapterID,
            scope: scope,
            barrier: barrier
        ),
        barrier: barrier,
        descriptor: adapter.descriptor,
        scope: scope,
        credential: credential
    )
}

private func makeZenSingleCallToolsGatewayFixture(
    requestID: String,
    model: String,
    credential: String = ""
) throws -> HostedGatewayFixture {
    let modelID = ProviderModelID(rawValue: model)
    let catalog = TrustedHostedProviderCatalog.openCodeZenChatCompletions(
        model: modelID,
        capabilities: .hostedChatSingleCallToolsBaseline
    )
    let capability = try catalog.hostedSingleCallToolsCapability(
        adapterID: catalog.adapterID
    )
    let adapter = try catalog.providerCatalog().adapter(id: catalog.adapterID)
    let transport = AgentHostedProviderTransport(
        credential: credential,
        singleCallToolsCapability: capability,
        session: makeHostedTransportTestSession(),
        limits: testLimits()
    )
    let gateway = ModelGateway(
        catalog: try catalog.providerCatalog(),
        transport: transport
    )
    let scope = ProviderAttemptScope(
        requestID: requestID,
        attemptID: .init(rawValue: "\(requestID):provider-attempt:1")
    )
    let barrier = DurableRecordingDispatchBarrier()
    let tools = SandboxToolCatalog.all.map(\.descriptor).map {
        AgentHostedReadOnlyCanaryCoordinator.providerDefinition(for: $0)
    }
    let request = CanonicalProviderRequest(
        requestID: requestID,
        model: modelID,
        messages: [
            .init(role: .system, content: [.text("Use canonical tools.")]),
            .init(role: .user, content: [.text("Complete the task.")]),
        ],
        tools: tools,
        options: .init(
            maximumOutputTokens: 4_096,
            temperature: 0,
            parallelToolCalls: false,
            toolChoice: .auto
        )
    )
    return HostedGatewayFixture(
        gateway: gateway,
        invocation: ProviderSingleAttemptInvocation(
            request: request,
            adapterID: catalog.adapterID,
            scope: scope,
            barrier: barrier
        ),
        barrier: barrier,
        descriptor: adapter.descriptor,
        scope: scope,
        credential: credential
    )
}

private func makeFullCatalogWithReadOnlyTransportFixture(
    requestID: String
) throws -> HostedGatewayFixture {
    let model = ProviderModelID(rawValue: baseModel)
    let catalog = TrustedHostedProviderCatalog.openAIChatCompletions(
        model: model,
        capabilities: .hostedChatSingleCallToolsBaseline
    )
    // Route capability alone does not carry a tool registry. The app-side
    // read transport must still reject the 20-definition descriptor.
    let narrowCapability = try catalog.hostedReadOnlyToolsCapability(
        adapterID: catalog.adapterID
    )
    let adapter = try catalog.providerCatalog().adapter(id: catalog.adapterID)
    let credential = "sk-test-only-hosted-credential"
    let transport = AgentHostedProviderTransport(
        credential: credential,
        readOnlyToolsCapability: narrowCapability,
        session: makeHostedTransportTestSession(),
        limits: testLimits()
    )
    let gateway = ModelGateway(
        catalog: try catalog.providerCatalog(),
        transport: transport
    )
    let scope = ProviderAttemptScope(
        requestID: requestID,
        attemptID: .init(rawValue: "\(requestID):provider-attempt:1")
    )
    let barrier = DurableRecordingDispatchBarrier()
    let tools = SandboxToolCatalog.all.map(\.descriptor).map {
        AgentHostedReadOnlyCanaryCoordinator.providerDefinition(for: $0)
    }
    let request = CanonicalProviderRequest(
        requestID: requestID,
        model: model,
        messages: [
            .init(role: .system, content: [.text("Use tools.")]),
            .init(role: .user, content: [.text("Complete the task.")]),
        ],
        tools: tools,
        options: .init(
            maximumOutputTokens: 4_096,
            temperature: 0,
            parallelToolCalls: false,
            toolChoice: .auto
        )
    )
    return HostedGatewayFixture(
        gateway: gateway,
        invocation: ProviderSingleAttemptInvocation(
            request: request,
            adapterID: catalog.adapterID,
            scope: scope,
            barrier: barrier
        ),
        barrier: barrier,
        descriptor: adapter.descriptor,
        scope: scope,
        credential: credential
    )
}

private func makeTrustedMaterial(
    dialect: ProviderAdapterDialect,
    model: String = baseModel
) throws -> TrustedHostedMaterial {
    let modelID = ProviderModelID(rawValue: model)
    let catalog: TrustedHostedProviderCatalog
    switch dialect {
    case .openAIChatCompletions:
        catalog = .openAIChatCompletions(model: modelID)
    case .openAIResponses:
        catalog = .openAIResponses(model: modelID)
    case .openAICompatibleChat:
        fatalError("The hosted canary deliberately rejects caller-compatible routes")
    }
    let capability = try catalog.hostedTextOnlyCapability(adapterID: catalog.adapterID)
    let adapter = try catalog.providerCatalog().adapter(id: catalog.adapterID)
    return TrustedHostedMaterial(
        catalog: catalog,
        capability: capability,
        descriptor: adapter.descriptor
    )
}

private func validChatBody(model: String = baseModel) -> [String: JSONValue] {
    [
        "model": .string(model),
        "messages": .array([.object([
            "role": .string("user"),
            "content": .string("Hello"),
        ])]),
        "stream": .bool(true),
        "stream_options": .object(["include_usage": .bool(true)]),
        "metadata": .object([:]),
    ]
}

private func validResponsesBody(model: String = baseModel) -> [String: JSONValue] {
    [
        "model": .string(model),
        "input": .array([.object([
            "type": .string("message"),
            "role": .string("user"),
            "content": .array([.object([
                "type": .string("input_text"),
                "text": .string("Hello"),
            ])]),
        ])]),
        "stream": .bool(true),
        "metadata": .object([:]),
    ]
}

private func testLimits(
    maximumRequestBodyBytes: Int = 128 * 1_024,
    maximumRequestJSONDepth: Int = 32,
    maximumRequestJSONNodes: Int = 4_096,
    maximumHTTPErrorBodyBytes: Int = 1_024,
    maximumSSELineBytes: Int = 16 * 1_024,
    maximumSSEEventBytes: Int = 32 * 1_024,
    maximumFrameCount: Int = 128,
    maximumStreamBytes: Int = 256 * 1_024,
    maximumBufferedWireFrames: Int = 32
) -> AgentHostedProviderTransport.Limits {
    .init(
        maximumRequestBodyBytes: maximumRequestBodyBytes,
        maximumRequestJSONDepth: maximumRequestJSONDepth,
        maximumRequestJSONNodes: maximumRequestJSONNodes,
        maximumHTTPErrorBodyBytes: maximumHTTPErrorBodyBytes,
        maximumSSELineBytes: maximumSSELineBytes,
        maximumSSEEventBytes: maximumSSEEventBytes,
        maximumFrameCount: maximumFrameCount,
        maximumStreamBytes: maximumStreamBytes,
        maximumBufferedWireFrames: maximumBufferedWireFrames
    )
}

private func makeHostedTransportTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HostedTransportURLProtocol.self]
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 2
    configuration.timeoutIntervalForResource = 2
    return URLSession(configuration: configuration)
}

private func collect(
    _ stream: AsyncThrowingStream<ProviderWireFrame, any Error>
) async throws -> [ProviderWireFrame] {
    var frames: [ProviderWireFrame] = []
    for try await frame in stream { frames.append(frame) }
    return frames
}

private func collectAttemptEvents(
    _ stream: AsyncThrowingStream<ProviderAttemptEvent, any Error>
) async throws -> [ProviderAttemptEvent] {
    var events: [ProviderAttemptEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private func encoded(_ body: [String: JSONValue]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(JSONValue.object(body))
}

private func decodeJSON(_ string: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
}

private func installSSE(_ payload: String) {
    HostedTransportURLProtocolRegistry.shared.install(.init(
        statusCode: 200,
        headers: ["Content-Type": "Text/Event-Stream; charset=utf-8"],
        chunks: [Data(payload.utf8)]
    ))
}

private func chatIdentityJSON(
    responseID: String,
    model: String = baseModel
) -> String {
    "{\"id\":\"\(responseID)\",\"model\":\"\(model)\"}"
}

private func chatTextDeltaJSON(
    responseID: String,
    text: String,
    model: String = baseModel
) -> String {
    "{\"id\":\"\(responseID)\",\"model\":\"\(model)\"," +
        "\"choices\":[{\"index\":0,\"delta\":{" +
        "\"role\":\"assistant\",\"content\":\"\(text)\"}," +
        "\"finish_reason\":null}]}"
}

private func responsesCreatedJSON(
    responseID: String,
    model: String = baseModel
) -> String {
    "{\"type\":\"response.created\",\"response\":{\"id\":\"\(responseID)\",\"model\":\"\(model)\"}}"
}

private func responsesProgressJSON(
    responseID: String,
    marker: Int
) -> String {
    "{\"type\":\"response.in_progress\",\"response_id\":\"\(responseID)\",\"marker\":\(marker)}"
}

private func responsesTextDeltaJSON(
    responseID: String,
    text: String,
    outputIndex: Int = 0,
    contentIndex: Int = 0
) -> String {
    "{\"type\":\"response.output_text.delta\"," +
        "\"response_id\":\"\(responseID)\",\"output_index\":\(outputIndex)," +
        "\"content_index\":\(contentIndex),\"delta\":\"\(text)\"}"
}

private func responsesCompletionJSON(
    responseID: String,
    model: String = baseModel,
    text: String = "Hello"
) -> String {
    "{\"type\":\"response.completed\",\"response\":{" +
        "\"id\":\"\(responseID)\",\"model\":\"\(model)\",\"status\":\"completed\"," +
        "\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{" +
        "\"type\":\"output_text\",\"text\":\"\(text)\"}]}]," +
        "\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}}"
}

private func chatIntegrationSSE(
    responseID: String = "chatcmpl-canary",
    model: String = versionedModel
) -> String {
    let first = "{\"id\":\"\(responseID)\",\"object\":\"chat.completion.chunk\"," +
        "\"created\":1750000000,\"model\":\"\(model)\"," +
        "\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hello\"}," +
        "\"finish_reason\":null}],\"usage\":null}"
    let finished = "{\"id\":\"\(responseID)\",\"object\":\"chat.completion.chunk\"," +
        "\"created\":1750000000,\"model\":\"\(model)\"," +
        "\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":null}"
    let usage = "{\"id\":\"\(responseID)\",\"object\":\"chat.completion.chunk\"," +
        "\"created\":1750000000,\"model\":\"\(model)\"," +
        "\"choices\":[],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1}}"
    return "data: \(first)\n\ndata: \(finished)\n\ndata: \(usage)\n\ndata: [DONE]\n\n"
}

private func responsesIntegrationSSE() -> String {
    let created = responsesCreatedJSON(
        responseID: "resp-canary",
        model: versionedModel
    )
    let delta = "{\"type\":\"response.output_text.delta\",\"response_id\":\"resp-canary\"," +
        "\"output_index\":0,\"content_index\":0,\"delta\":\"Hello\"}"
    let done = "{\"type\":\"response.output_text.done\",\"response_id\":\"resp-canary\"," +
        "\"output_index\":0,\"content_index\":0,\"text\":\"Hello\"}"
    let completed = responsesCompletionJSON(
        responseID: "resp-canary",
        model: versionedModel
    )
    return "data: \(created)\n\ndata: \(delta)\n\ndata: \(done)\n\ndata: \(completed)\n\n"
}

private actor DurableRecordingDispatchBarrier: ProviderAttemptDispatchBarrier {
    private var dispatches: [ProviderAttemptDispatch] = []
    private var requestCounts: [Int] = []

    func beforeDispatch(_ attempt: ProviderAttemptDispatch) async throws {
        requestCounts.append(HostedTransportURLProtocolRegistry.shared.requestCount)
        dispatches.append(attempt)
    }

    func snapshot() -> [ProviderAttemptDispatch] {
        dispatches
    }

    func requestCountsAtDispatch() -> [Int] {
        requestCounts
    }
}

private final class ProducerTerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var didFire = false
    private var waiter: CheckedContinuation<Bool, Never>?

    func fire() {
        lock.lock()
        didFire = true
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(returning: true)
    }

    func wait(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didFire {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            waiter = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.expireWaiter()
            }
        }
    }

    private func expireWaiter() {
        lock.lock()
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(returning: false)
    }
}

private final class LockedIntRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(_ value: Int) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private final class LockedRedirectDecisionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCallCount = 0
    private var recordedRequest: URLRequest?

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCallCount
    }

    var followedRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequest
    }

    func record(_ request: URLRequest?) {
        lock.lock()
        recordedCallCount += 1
        recordedRequest = request
        lock.unlock()
    }
}

private struct HostedTransportURLProtocolPlan: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let chunks: [Data]
    let finishes: Bool
    let terminalFailure: (any Error & Sendable)?

    init(
        statusCode: Int,
        headers: [String: String],
        chunks: [Data],
        finishes: Bool = true,
        terminalFailure: (any Error & Sendable)? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.chunks = chunks
        self.finishes = finishes
        self.terminalFailure = terminalFailure
    }
}

private final class HostedTransportURLProtocolRegistry: @unchecked Sendable {
    static let shared = HostedTransportURLProtocolRegistry()

    private let lock = NSLock()
    private var plan: HostedTransportURLProtocolPlan?
    private var recordedRequests: [URLRequest] = []
    private var recordedStopCount = 0

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    var requestCount: Int { requests.count }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedStopCount
    }

    func install(_ plan: HostedTransportURLProtocolPlan) {
        lock.lock()
        self.plan = plan
        lock.unlock()
    }

    func begin(_ request: URLRequest) -> HostedTransportURLProtocolPlan? {
        let capturedRequest = Self.capturingBody(from: request)
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(capturedRequest)
        return plan
    }

    /// Darwin commonly hands URLProtocol an upload stream even when the
    /// caller set `httpBody`. This recorder owns the stubbed request, so it can
    /// consume that in-memory stream and normalize the snapshot back to Data
    /// without affecting any real network transfer.
    private static func capturingBody(from request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }

        stream.open()
        defer { stream.close() }
        var body = Data()
        let bufferCapacity = 4_096
        var buffer = [UInt8](repeating: 0, count: bufferCapacity)
        while true {
            let count = stream.read(&buffer, maxLength: bufferCapacity)
            guard count >= 0 else { return request }
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }

        var captured = request
        captured.httpBodyStream = nil
        captured.httpBody = body
        return captured
    }

    func recordStop() {
        lock.lock()
        recordedStopCount += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        plan = nil
        recordedRequests.removeAll(keepingCapacity: false)
        recordedStopCount = 0
        lock.unlock()
    }
}

private final class HostedTransportURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let plan = HostedTransportURLProtocolRegistry.shared.begin(request),
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: plan.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: plan.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in plan.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if let terminalFailure = plan.terminalFailure {
            client?.urlProtocol(self, didFailWithError: terminalFailure)
            return
        }
        if plan.finishes {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        HostedTransportURLProtocolRegistry.shared.recordStop()
    }
}

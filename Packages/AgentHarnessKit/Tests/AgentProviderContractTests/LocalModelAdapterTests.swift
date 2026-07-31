import AgentDomain
@testable import AgentProviders
import XCTest

final class LocalModelAdapterTests: XCTestCase {
    func testLocalAdapterIsOnDeviceAndEncodesCanonicalRequestWithoutRemoteAuthority() throws {
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "qwen-local")
        ))
        let descriptor = adapter.descriptor

        XCTAssertEqual(descriptor.route.providerID.rawValue, "novaforge-local")
        XCTAssertEqual(descriptor.route.adapterID.rawValue, "novaforge-local-llama")
        XCTAssertEqual(descriptor.route.deployment, .onDevice)
        XCTAssertEqual(descriptor.route.provenance, .builtInLocalModel)
        XCTAssertEqual(descriptor.requestPath, "/v1/local/chat/completions")
        XCTAssertTrue(descriptor.route.capabilities.features.contains(.streaming))
        XCTAssertTrue(descriptor.route.capabilities.features.contains(.cancellation))
        XCTAssertFalse(descriptor.route.capabilities.features.contains(.tools))
        XCTAssertEqual(descriptor.route.capabilities.maximumToolCallsPerTurn, 0)

        let encoded = try adapter.encode(textRequest(model: "qwen-local"))
        XCTAssertEqual(encoded.relativePath, "/v1/local/chat/completions")
        let body = try XCTUnwrap(encoded.body.localTestObject)
        XCTAssertEqual(body["model"], .string("qwen-local"))
        XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertNil(body["base_url"])
        XCTAssertNil(body["authorization"])
        XCTAssertNil(body["api_key"])
    }

    func testLocalWireSessionProducesOrdinaryAttemptScopedCanonicalTextAndUsage() throws {
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "qwen-local")
        ))
        let scope = ProviderAttemptScope(
            requestID: "local-request",
            attemptID: .init(rawValue: "local-attempt-1")
        )
        var local = try LocalModelWireSession(
            responseID: "local-response-1",
            descriptor: adapter.descriptor
        )
        var frames: [ProviderWireFrame] = [try local.begin()]
        frames.append(try XCTUnwrap(local.text("hello ")))
        frames.append(try XCTUnwrap(local.text("offline")))
        frames.append(try local.usage(.init(
            inputTokens: 12,
            cachedInputTokens: 2,
            outputTokens: 3
        )))
        frames.append(contentsOf: try local.complete(.completed))

        let events = try adapter.translateStream(
            frames,
            scope: scope,
            request: textRequest(model: "qwen-local")
        )
        XCTAssertTrue(events.allSatisfy { $0.scope == scope })
        XCTAssertEqual(events.map(\.sequence), Array(0 ..< UInt64(events.count)))
        XCTAssertEqual(events.compactMap { event -> String? in
            if case let .textDelta(delta) = event.event { delta.text } else { nil }
        }.joined(), "hello offline")
        XCTAssertEqual(events.compactMap { event -> ProviderUsage? in
            if case let .usage(usage) = event.event { usage } else { nil }
        }, [.init(inputTokens: 12, cachedInputTokens: 2, outputTokens: 3)])
        XCTAssertEqual(events.last?.event, .responseCompleted(.init(
            responseID: "local-response-1",
            finishReason: .completed
        )))
    }

    func testGrammarConstrainedLocalToolCallUsesSameTypedToolEvents() throws {
        let tool = ProviderToolDefinition(
            name: "write_file",
            description: "Write one file",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "replace": .object(["type": .string("boolean")]),
                    "line": .object(["type": .string("integer")]),
                ]),
                "required": .array([
                    .string("path"), .string("replace"), .string("line"),
                ]),
                "additionalProperties": .bool(false),
            ])
        )
        let attestation = LocalModelGrammarAttestation(
            grammarSHA256: "sha256:" + String(repeating: "a", count: 64),
            toolCatalogSHA256: try LocalModelGrammarAttestation
                .canonicalToolCatalogSHA256(for: [tool]),
            toolDefinitionCount: 1,
            compilerID: "novaforge-grammar-v1",
            maximumToolCallsPerTurn: 8
        )
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "hermes-local"),
            contextWindowTokens: 8_192,
            maximumOutputTokens: 1_024,
            toolMode: .grammarConstrained(attestation)
        ))
        XCTAssertTrue(adapter.descriptor.route.capabilities.features.contains(.tools))
        XCTAssertTrue(adapter.descriptor.route.capabilities.features.contains(.typedToolArguments))
        XCTAssertTrue(adapter.descriptor.route.capabilities.features.contains(.strictToolSchema))
        XCTAssertFalse(adapter.descriptor.route.capabilities.features.contains(.parallelToolCalls))
        XCTAssertEqual(adapter.descriptor.route.capabilities.maximumToolCallsPerTurn, 1)
        let scope = ProviderAttemptScope(
            requestID: "local-tool-request",
            attemptID: .init(rawValue: "local-tool-attempt")
        )
        let request = CanonicalProviderRequest(
            requestID: scope.requestID,
            model: .init(rawValue: "hermes-local"),
            messages: [.init(role: .user, content: [.text("Write it")])],
            tools: [tool],
            options: .init(toolChoice: .required)
        )
        _ = try adapter.encode(request)
        var local = try LocalModelWireSession(
            responseID: "local-tool-response",
            descriptor: adapter.descriptor
        )
        let arguments: JSONValue = .object([
            "path": .string("Notes/today.md"),
            "replace": .bool(false),
            "line": .number(.integer(7)),
        ])
        var frames: [ProviderWireFrame] = [try local.begin()]
        frames.append(try local.toolCall(
            outputIndex: 0,
            callID: "local-call-1",
            name: "write_file",
            arguments: arguments
        ))
        frames.append(try local.usage(.init(inputTokens: 40, outputTokens: 18)))
        frames.append(contentsOf: try local.complete(.toolCalls))

        var parser = ProviderStreamSession(
            descriptor: adapter.descriptor,
            scope: scope,
            request: request
        )
        var events: [ProviderAttemptEvent] = []
        for frame in frames { events.append(contentsOf: try parser.receive(frame)) }
        events.append(contentsOf: try parser.finish())
        let completed = try XCTUnwrap(events.compactMap { event -> ProviderToolCallCompletion? in
            if case let .toolCallCompleted(call) = event.event { call } else { nil }
        }.first)
        XCTAssertEqual(completed.callID, "local-call-1")
        XCTAssertEqual(completed.name, "write_file")
        XCTAssertEqual(completed.arguments, arguments)
        XCTAssertEqual(events.last?.event, .responseCompleted(.init(
            responseID: "local-tool-response",
            finishReason: .toolCalls
        )))
    }

    func testLocalTextRouteCannotNegotiateToolRequest() throws {
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "qwen-local")
        ))
        let catalog = try ProviderAdapterCatalog([adapter])
        let request = CanonicalProviderRequest(
            requestID: "tool-request",
            model: .init(rawValue: "qwen-local"),
            messages: [.init(role: .user, content: [.text("write it")])],
            tools: [.init(
                name: "write_file",
                description: "Write a file",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "additionalProperties": .bool(false),
                ])
            )]
        )

        XCTAssertThrowsError(try catalog.negotiate(
            preferredAdapterIDs: [adapter.descriptor.route.adapterID],
            requirements: request.capabilityRequirements
        )) { error in
            XCTAssertEqual(
                error as? ProviderCatalogFailure,
                .noCompatibleRoute(request.requiredCapabilities)
            )
        }
        XCTAssertThrowsError(try adapter.encode(request)) { error in
            XCTAssertEqual((error as? ProviderFailure)?.code, "provider_unsupported_capability")
        }
    }

    func testLocalToolCapabilitiesRequireValidatedGrammarAttestation() {
        let invalidAttestation = LocalModelGrammarAttestation(
            grammarSHA256: "sha256:not-a-digest",
            toolCatalogSHA256: "sha256:" + String(repeating: "b", count: 64),
            compilerID: "novaforge-grammar-v1",
            maximumToolCallsPerTurn: 8
        )
        XCTAssertThrowsError(try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model"),
            toolMode: .grammarConstrained(invalidAttestation)
        ))) { error in
            XCTAssertEqual(
                error as? LocalModelAdapterConfigurationError,
                .invalidAttestationDigest
            )
        }

        let validAttestation = LocalModelGrammarAttestation(
            grammarSHA256: "sha256:" + String(repeating: "a", count: 64),
            toolCatalogSHA256: "sha256:" + String(repeating: "b", count: 64),
            compilerID: "novaforge-grammar-v1",
            maximumToolCallsPerTurn: 0
        )
        XCTAssertThrowsError(try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model"),
            toolMode: .grammarConstrained(validAttestation)
        ))) { error in
            XCTAssertEqual(
                error as? LocalModelAdapterConfigurationError,
                .invalidToolLimit
            )
        }

        let invalidParallel = LocalModelGrammarAttestation(
            grammarSHA256: "sha256:" + String(repeating: "a", count: 64),
            toolCatalogSHA256: "sha256:" + String(repeating: "b", count: 64),
            compilerID: "novaforge-grammar-v1",
            maximumToolCallsPerTurn: 1,
            supportsParallelToolCalls: true
        )
        XCTAssertThrowsError(try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model"),
            toolMode: .grammarConstrained(invalidParallel)
        ))) { error in
            XCTAssertEqual(
                error as? LocalModelAdapterConfigurationError,
                .invalidParallelToolLimit
            )
        }

        let unicodeDigest = LocalModelGrammarAttestation(
            grammarSHA256: "sha256:" + String(repeating: "١", count: 32),
            toolCatalogSHA256: "sha256:" + String(repeating: "b", count: 64),
            compilerID: "novaforge-grammar-v1",
            maximumToolCallsPerTurn: 1
        )
        XCTAssertThrowsError(try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model"),
            toolMode: .grammarConstrained(unicodeDigest)
        ))) { error in
            XCTAssertEqual(
                error as? LocalModelAdapterConfigurationError,
                .invalidAttestationDigest
            )
        }
    }

    func testLocalWireSessionFailsClosedOnOrderingAndToolIdentityReuse() throws {
        let attestation = LocalModelGrammarAttestation(
            grammarSHA256: "sha256:" + String(repeating: "a", count: 64),
            toolCatalogSHA256: "sha256:" + String(repeating: "b", count: 64),
            compilerID: "novaforge-grammar-v1",
            maximumToolCallsPerTurn: 2
        )
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model"),
            toolMode: .grammarConstrained(attestation)
        ))
        var local = try LocalModelWireSession(
            responseID: "local-response",
            descriptor: adapter.descriptor
        )
        XCTAssertThrowsError(try local.text("too early")) { error in
            XCTAssertEqual(error as? LocalModelWireSessionError, .eventBeforeStart)
        }
        _ = try local.begin()
        XCTAssertThrowsError(try local.begin()) { error in
            XCTAssertEqual(error as? LocalModelWireSessionError, .duplicateStart)
        }
        _ = try local.toolCall(
            outputIndex: 0,
            callID: "call-1",
            name: "read_file",
            arguments: .object(["path": .string("a")])
        )
        XCTAssertThrowsError(try local.toolCall(
            outputIndex: 0,
            callID: "call-2",
            name: "read_file",
            arguments: .object(["path": .string("b")])
        )) { error in
            XCTAssertEqual(error as? LocalModelWireSessionError, .duplicateToolOutputIndex(0))
        }
        _ = try local.usage(.zero)
        _ = try local.complete(.toolCalls)
        XCTAssertThrowsError(try local.usage(.zero)) { error in
            XCTAssertEqual(error as? LocalModelWireSessionError, .eventAfterTerminal)
        }
    }

    func testTextOnlyWireSessionRejectsUnexpectedToolOutput() throws {
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model")
        ))
        var local = try LocalModelWireSession(
            responseID: "text-only-response",
            descriptor: adapter.descriptor
        )
        _ = try local.begin()

        XCTAssertThrowsError(try local.toolCall(
            outputIndex: 0,
            callID: "unexpected-call",
            name: "write_file",
            arguments: .object(["path": .string("a")])
        )) { error in
            XCTAssertEqual(error as? LocalModelWireSessionError, .toolModeDisabled)
        }
    }

    func testNonParallelLocalRouteRejectsSecondDistinctToolCall() throws {
        let attestation = LocalModelGrammarAttestation(
            grammarSHA256: "sha256:" + String(repeating: "a", count: 64),
            toolCatalogSHA256: "sha256:" + String(repeating: "b", count: 64),
            compilerID: "novaforge-grammar-v1",
            maximumToolCallsPerTurn: 8,
            supportsParallelToolCalls: false
        )
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model"),
            toolMode: .grammarConstrained(attestation)
        ))
        var local = try LocalModelWireSession(
            responseID: "nonparallel-response",
            descriptor: adapter.descriptor
        )
        _ = try local.begin()
        _ = try local.toolCall(
            outputIndex: 0,
            callID: "call-1",
            name: "read_file",
            arguments: .object(["path": .string("a")])
        )

        XCTAssertThrowsError(try local.toolCall(
            outputIndex: 1,
            callID: "call-2",
            name: "read_file",
            arguments: .object(["path": .string("b")])
        )) { error in
            XCTAssertEqual(
                error as? LocalModelWireSessionError,
                .parallelToolCallsDisabled
            )
        }
    }

    func testParallelLocalRouteHonorsAttestedToolLimit() throws {
        let attestation = LocalModelGrammarAttestation(
            grammarSHA256: "sha256:" + String(repeating: "a", count: 64),
            toolCatalogSHA256: "sha256:" + String(repeating: "b", count: 64),
            compilerID: "novaforge-grammar-v1",
            maximumToolCallsPerTurn: 2,
            supportsParallelToolCalls: true
        )
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model"),
            toolMode: .grammarConstrained(attestation)
        ))
        XCTAssertTrue(
            adapter.descriptor.route.capabilities.features.contains(.parallelToolCalls)
        )
        XCTAssertEqual(adapter.descriptor.route.capabilities.maximumToolCallsPerTurn, 2)
        var local = try LocalModelWireSession(
            responseID: "parallel-response",
            descriptor: adapter.descriptor
        )
        _ = try local.begin()
        for index in 0 ..< 2 {
            _ = try local.toolCall(
                outputIndex: index,
                callID: "call-\(index)",
                name: "read_file",
                arguments: .object(["path": .string("\(index)")])
            )
        }
        XCTAssertThrowsError(try local.toolCall(
            outputIndex: 2,
            callID: "call-2",
            name: "read_file",
            arguments: .object(["path": .string("2")])
        )) { error in
            XCTAssertEqual(
                error as? LocalModelWireSessionError,
                .toolLimitExceeded(2)
            )
        }
    }

    func testLocalCompletionRequiresExactlyOneUsageReport() throws {
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model")
        ))
        var local = try LocalModelWireSession(
            responseID: "usage-response",
            descriptor: adapter.descriptor
        )
        _ = try local.begin()
        _ = try XCTUnwrap(local.text("hello"))
        XCTAssertThrowsError(try local.complete(.completed)) { error in
            XCTAssertEqual(error as? LocalModelWireSessionError, .missingUsage)
        }
        _ = try local.usage(.init(inputTokens: 3, outputTokens: 1))
        XCTAssertThrowsError(try local.text("too late")) { error in
            XCTAssertEqual(error as? LocalModelWireSessionError, .outputAfterUsage)
        }
        XCTAssertThrowsError(try local.usage(.init(inputTokens: 3, outputTokens: 1))) { error in
            XCTAssertEqual(error as? LocalModelWireSessionError, .duplicateUsage)
        }
        _ = try local.complete(.completed)
    }

    func testLocalCompletionRejectsUnknownFinishReason() throws {
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model")
        ))
        var local = try LocalModelWireSession(
            responseID: "unknown-finish-response",
            descriptor: adapter.descriptor
        )
        _ = try local.begin()
        _ = try local.usage(.zero)

        XCTAssertThrowsError(try local.complete(.unknown)) { error in
            XCTAssertEqual(error as? LocalModelWireSessionError, .finishReasonMismatch)
        }
    }

    func testLocalCancellationUsesCanonicalAttemptScopedTerminalEvent() throws {
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model")
        ))
        let scope = ProviderAttemptScope(
            requestID: "cancel-request",
            attemptID: .init(rawValue: "cancel-attempt")
        )
        var local = try LocalModelWireSession(
            responseID: "cancel-response",
            descriptor: adapter.descriptor
        )
        let frames: [ProviderWireFrame] = [
            try local.begin(),
            try XCTUnwrap(local.text("discard me")),
            try local.cancel(reason: .thermalPressure),
        ]

        let events = try adapter.translateStream(
            frames,
            scope: scope,
            request: textRequest(model: "local-model")
        )
        XCTAssertTrue(events.allSatisfy { $0.scope == scope })
        XCTAssertEqual(events.last?.event, .cancelled(.init(
            responseID: "cancel-response",
            reason: LocalModelCancellationReason.thermalPressure.rawValue
        )))
        XCTAssertThrowsError(try local.complete(.cancelled)) { error in
            XCTAssertEqual(error as? LocalModelWireSessionError, .eventAfterTerminal)
        }
    }

    func testLocalAdapterRunsThroughModelGatewayCommitBoundary() async throws {
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "qwen-local")
        ))
        let transport = LocalFixtureTransport(modelID: .init(rawValue: "qwen-local"))
        let gateway = ModelGateway(
            catalog: try ProviderAdapterCatalog([adapter]),
            transport: transport
        )

        let result = try await gateway.generate(.init(
            request: textRequest(model: "qwen-local"),
            preferredAdapterIDs: [adapter.descriptor.route.adapterID],
            recoveryPolicy: .init(
                maximumAttemptsPerRoute: 1,
                maximumFallbacks: 0,
                baseBackoffMilliseconds: 0,
                maximumBackoffMilliseconds: 0,
                jitterBasisPoints: 0
            ),
            deterministicSeed: 4
        ))

        XCTAssertEqual(result.route.deployment, .onDevice)
        XCTAssertEqual(result.route.provenance, .builtInLocalModel)
        XCTAssertEqual(result.attempts.count, 1)
        XCTAssertTrue(result.attempts[0].committed)
        XCTAssertEqual(result.events.compactMap { event -> String? in
            if case let .textDelta(delta) = event.event { delta.text } else { nil }
        }.joined(), "local-ok")
        let callCount = await transport.calls()
        XCTAssertEqual(callCount, 1)
    }

    func testTrustedLocalCatalogMintsOnlyConservativeTextRoute() throws {
        let trusted = try TrustedLocalProviderCatalog.textOnly(
            modelID: .init(rawValue: "trusted-local")
        )
        let descriptor = trusted.descriptor
        XCTAssertEqual(descriptor.route.provenance, .builtInLocalModel)
        XCTAssertEqual(descriptor.route.deployment, .onDevice)
        XCTAssertFalse(descriptor.route.capabilities.features.contains(.tools))
        XCTAssertEqual(descriptor.route.capabilities.maximumToolDefinitions, 0)
        XCTAssertEqual(descriptor.route.capabilities.maximumToolCallsPerTurn, 0)
        let catalog = try trusted.providerCatalog()
        XCTAssertEqual(
            try catalog.adapter(id: trusted.adapterID).descriptor,
            descriptor
        )
    }

    func testExactAdapterRejectsParallelRequestWhenCallCapacityIsOne() throws {
        let capabilities = ProviderModelCapabilities(
            features: ProviderCapabilitySet([
                .cancellation,
                .parallelToolCalls,
                .streaming,
                .strictToolSchema,
                .tools,
                .typedToolArguments,
                .usageStreaming,
            ]),
            contextWindowTokens: 8_192,
            maximumOutputTokens: 1_024,
            maximumToolDefinitions: 2,
            maximumToolCallsPerTurn: 1
        )
        let adapter = OpenAIChatCompletionsAdapter(
            model: .init(rawValue: "parallel-capacity-model"),
            capabilities: capabilities
        )
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
        let request = CanonicalProviderRequest(
            requestID: "parallel-capacity-request",
            model: .init(rawValue: "parallel-capacity-model"),
            messages: [.init(role: .user, content: [.text("Run both")])],
            tools: [
                .init(name: "first", description: "First", parameters: schema),
                .init(name: "second", description: "Second", parameters: schema),
            ],
            options: .init(parallelToolCalls: true)
        )

        XCTAssertThrowsError(try adapter.encode(request)) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_tool_call_limit_insufficient"
            )
        }
    }

    func testNonparallelRouteAcceptsManyDefinitionsButOnlyOneEmittedCall() throws {
        let tools = ["read_file", "list_files", "search_text"].map { name in
            ProviderToolDefinition(
                name: name,
                description: name,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "required": .array([]),
                    "additionalProperties": .bool(false),
                ])
            )
        }
        let catalogDigest = try LocalModelGrammarAttestation
            .canonicalToolCatalogSHA256(for: tools)
        let attestation = LocalModelGrammarAttestation(
            grammarSHA256: "sha256:" + String(repeating: "a", count: 64),
            toolCatalogSHA256: catalogDigest,
            toolDefinitionCount: 3,
            compilerID: "novaforge-grammar-v1",
            maximumToolCallsPerTurn: 8,
            supportsParallelToolCalls: false
        )
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model"),
            toolMode: .grammarConstrained(attestation)
        ))
        let request = CanonicalProviderRequest(
            requestID: "definition-catalog-request",
            model: .init(rawValue: "local-model"),
            messages: [.init(role: .user, content: [.text("Choose one")])],
            tools: tools
        )

        XCTAssertEqual(request.capabilityRequirements.minimumToolDefinitions, 3)
        XCTAssertEqual(request.capabilityRequirements.minimumToolCallsPerTurn, 1)
        XCTAssertEqual(adapter.descriptor.route.capabilities.maximumToolDefinitions, 3)
        XCTAssertEqual(adapter.descriptor.route.capabilities.maximumToolCallsPerTurn, 1)
        XCTAssertNoThrow(try adapter.encode(request))

        let wrongDigest = LocalModelGrammarAttestation(
            grammarSHA256: "sha256:" + String(repeating: "a", count: 64),
            toolCatalogSHA256: "sha256:" + String(repeating: "b", count: 64),
            toolDefinitionCount: 3,
            compilerID: "novaforge-grammar-v1",
            maximumToolCallsPerTurn: 1
        )
        let wrongDigestAdapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model"),
            toolMode: .grammarConstrained(wrongDigest)
        ))
        XCTAssertThrowsError(try wrongDigestAdapter.encode(request)) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_local_tool_catalog_digest_mismatch"
            )
        }

        let wrongCount = LocalModelGrammarAttestation(
            grammarSHA256: "sha256:" + String(repeating: "a", count: 64),
            toolCatalogSHA256: catalogDigest,
            toolDefinitionCount: 4,
            compilerID: "novaforge-grammar-v1",
            maximumToolCallsPerTurn: 1
        )
        let wrongCountAdapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model"),
            toolMode: .grammarConstrained(wrongCount)
        ))
        XCTAssertThrowsError(try wrongCountAdapter.encode(request)) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_local_tool_catalog_count_mismatch"
            )
        }
    }

    func testCanonicalParserRejectsRawToolOutputOnTextOnlyLocalRoute() throws {
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model")
        ))
        let request = textRequest(model: "local-model")
        var session = ProviderStreamSession(
            descriptor: adapter.descriptor,
            scope: .init(
                requestID: request.requestID,
                attemptID: .init(rawValue: "attempt-1")
            ),
            request: request
        )
        let frame: ProviderWireFrame = .json(.object([
            "id": .string("raw-tool-response"),
            "model": .string("local-model"),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object([
                    "tool_calls": .array([.object([
                        "index": .number(.integer(0)),
                        "id": .string("raw-call"),
                        "function": .object([
                            "name": .string("write_file"),
                            "arguments": .string("{}"),
                        ]),
                    ])]),
                ]),
                "finish_reason": .null,
            ])]),
        ]))

        XCTAssertThrowsError(try session.receive(frame)) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_tool_output_not_supported"
            )
        }
    }

    func testCanonicalLocalParserRejectsDuplicateUsageAndOutputAfterUsage() throws {
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model")
        ))
        let request = textRequest(model: "local-model")
        let scope = ProviderAttemptScope(
            requestID: request.requestID,
            attemptID: .init(rawValue: "attempt-1")
        )
        var duplicateSession = ProviderStreamSession(
            descriptor: adapter.descriptor,
            scope: scope,
            request: request
        )
        _ = try duplicateSession.receive(localStartFrame())
        _ = try duplicateSession.receive(localUsageFrame())
        XCTAssertThrowsError(try duplicateSession.receive(localUsageFrame())) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_usage_reported_more_than_once"
            )
        }

        var outputSession = ProviderStreamSession(
            descriptor: adapter.descriptor,
            scope: scope,
            request: request
        )
        _ = try outputSession.receive(localStartFrame())
        _ = try outputSession.receive(localUsageFrame())
        XCTAssertThrowsError(try outputSession.receive(.json(.object([
            "id": .string("raw-local-response"),
            "model": .string("local-model"),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object(["content": .string("too late")]),
                "finish_reason": .null,
            ])]),
        ])))) { error in
            XCTAssertEqual((error as? ProviderFailure)?.code, "provider_output_after_usage")
        }
    }

    func testCanonicalLocalParserRejectsModelMismatchAndUnknownFinish() throws {
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model")
        ))
        let request = textRequest(model: "local-model")
        let scope = ProviderAttemptScope(
            requestID: request.requestID,
            attemptID: .init(rawValue: "attempt-1")
        )
        var modelSession = ProviderStreamSession(
            descriptor: adapter.descriptor,
            scope: scope,
            request: request
        )
        XCTAssertThrowsError(try modelSession.receive(.json(.object([
            "id": .string("raw-local-response"),
            "model": .string("different-model"),
            "choices": .array([]),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_local_response_identity_invalid"
            )
        }

        var finishSession = ProviderStreamSession(
            descriptor: adapter.descriptor,
            scope: scope,
            request: request
        )
        XCTAssertThrowsError(try finishSession.receive(.json(.object([
            "id": .string("raw-local-response"),
            "model": .string("local-model"),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object([:]),
                "finish_reason": .string("future_reason"),
            ])]),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_local_finish_reason_invalid"
            )
        }
    }

    func testRequestBoundParserRejectsToolArgumentsOutsideSchema() throws {
        let attestation = LocalModelGrammarAttestation(
            grammarSHA256: "sha256:" + String(repeating: "a", count: 64),
            toolCatalogSHA256: "sha256:" + String(repeating: "b", count: 64),
            compilerID: "novaforge-grammar-v1",
            maximumToolCallsPerTurn: 1
        )
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model"),
            toolMode: .grammarConstrained(attestation)
        ))
        let request = CanonicalProviderRequest(
            requestID: "schema-request",
            model: .init(rawValue: "local-model"),
            messages: [.init(role: .user, content: [.text("Read")])],
            tools: [.init(
                name: "read_file",
                description: "Read",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("path")]),
                    "additionalProperties": .bool(false),
                ])
            )]
        )
        var session = ProviderStreamSession(
            descriptor: adapter.descriptor,
            scope: .init(
                requestID: request.requestID,
                attemptID: .init(rawValue: "attempt-1")
            ),
            request: request
        )
        XCTAssertThrowsError(try session.receive(.json(.object([
            "id": .string("schema-response"),
            "model": .string("local-model"),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object([
                    "tool_calls": .array([.object([
                        "index": .number(.integer(0)),
                        "id": .string("schema-call"),
                        "function": .object([
                            "name": .string("read_file"),
                            "arguments": .string("{\"path\":7}"),
                        ]),
                    ])]),
                ]),
                "finish_reason": .string("tool_calls"),
            ])]),
        ])))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_tool_arguments_schema_mismatch"
            )
        }
    }

    func testLocalToolSerializationFailureDoesNotConsumeIdentity() throws {
        let attestation = LocalModelGrammarAttestation(
            grammarSHA256: "sha256:" + String(repeating: "a", count: 64),
            toolCatalogSHA256: "sha256:" + String(repeating: "b", count: 64),
            compilerID: "novaforge-grammar-v1",
            maximumToolCallsPerTurn: 1
        )
        let adapter = try LocalModelAdapter(configuration: .init(
            modelID: .init(rawValue: "local-model"),
            toolMode: .grammarConstrained(attestation)
        ))
        var local = try LocalModelWireSession(
            responseID: "exception-safe-response",
            descriptor: adapter.descriptor
        )
        _ = try local.begin()
        XCTAssertThrowsError(try local.toolCall(
            outputIndex: 0,
            callID: "call-1",
            name: "read_file",
            arguments: .object(["value": .number(.floatingPoint(.nan))])
        ))
        XCTAssertNoThrow(try local.toolCall(
            outputIndex: 0,
            callID: "call-1",
            name: "read_file",
            arguments: .object(["value": .number(.integer(1))])
        ))
    }

    private func localStartFrame() -> ProviderWireFrame {
        .json(.object([
            "id": .string("raw-local-response"),
            "model": .string("local-model"),
            "choices": .array([]),
        ]))
    }

    private func localUsageFrame() -> ProviderWireFrame {
        .json(.object([
            "id": .string("raw-local-response"),
            "model": .string("local-model"),
            "choices": .array([]),
            "usage": .object([
                "prompt_tokens": .number(.integer(4)),
                "completion_tokens": .number(.integer(2)),
            ]),
        ]))
    }

    private func textRequest(model: String) -> CanonicalProviderRequest {
        CanonicalProviderRequest(
            requestID: "local-text-request",
            model: .init(rawValue: model),
            messages: [.init(role: .user, content: [.text("Hello offline")])],
            options: .init(maximumOutputTokens: 128, temperature: 0.1)
        )
    }
}

private actor LocalFixtureTransport: ProviderTransport {
    private let modelID: ProviderModelID
    private var callCount = 0

    init(modelID: ProviderModelID) {
        self.modelID = modelID
    }

    func stream(
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        callCount += 1
        XCTAssertEqual(descriptor.route.deployment, .onDevice)
        XCTAssertEqual(descriptor.route.modelID, modelID)
        XCTAssertEqual(request.relativePath, "/v1/local/chat/completions")
        var local = try LocalModelWireSession(
            responseID: "local-gateway-response",
            descriptor: descriptor
        )
        var frames: [ProviderWireFrame] = [try local.begin()]
        frames.append(try XCTUnwrap(local.text("local-ok")))
        frames.append(try local.usage(.init(inputTokens: 8, outputTokens: 2)))
        frames.append(contentsOf: try local.complete(.completed))
        return AsyncThrowingStream { continuation in
            for frame in frames {
                continuation.yield(frame)
            }
            continuation.finish()
        }
    }

    func calls() -> Int { callCount }
}

private extension JSONValue {
    var localTestObject: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}

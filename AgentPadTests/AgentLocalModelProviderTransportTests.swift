import AgentDomain
import AgentProviders
import AgentTools
import XCTest
@testable import NovaForge

final class AgentLocalModelProviderTransportTests: XCTestCase {
    func testAttestedLocalAgentEmitsSchemaValidatedFileActionWithoutInference()
        async throws
    {
        let variant = LocalModelCatalog.all[0]
        let modelID = ProviderModelID(rawValue: variant.id)
        let authority = try LocalToolsAuthority(modelID: modelID)
        let adapter = try authority.catalog.adapter(
            id: authority.descriptor.route.adapterID
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NovaForgeLocalTools-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SandboxWorkspace(rootURL: root)
        let inference = ScriptedLocalModelInference(scripts: [])
        let transport = AgentLocalModelProviderTransport(
            inference: inference,
            singleCallToolsCapability: authority.capability,
            toolRegistry: authority.toolRegistry,
            workspace: workspace
        )
        let tools = authority.toolRegistry.providerDefinitions().map {
            AgentProviders.ProviderToolDefinition(
                name: $0.function.name,
                description: $0.function.description,
                parameters: $0.function.parameters,
                strict: $0.function.strict
            )
        }
        let canonical = CanonicalProviderRequest(
            requestID: "local-tools-create",
            model: modelID,
            messages: [
                .init(
                    role: .user,
                    content: [.text("create file notes/hello.txt with hi")]
                ),
            ],
            tools: tools,
            options: .init(
                maximumOutputTokens: 32,
                temperature: 0.05,
                parallelToolCalls: false,
                toolChoice: .auto
            )
        )
        let encoded = try adapter.encode(canonical)
        let scope = ProviderAttemptScope(
            requestID: canonical.requestID,
            attemptID: .init(rawValue: "local-tools-create:attempt:1")
        )

        let frames = try await collect(try await transport.stream(
            request: encoded,
            descriptor: authority.descriptor,
            scope: scope
        ))

        let call = try XCTUnwrap(extractToolCall(from: frames))
        XCTAssertEqual(call.name, "write_file")
        XCTAssertTrue(call.arguments.contains("notes/hello.txt"))
        XCTAssertEqual(extractFinishReason(from: frames), "tool_calls")
        let inferenceCallCount = await inference.callCount()
        XCTAssertEqual(inferenceCallCount, 0)
    }

    func testUnfamiliarLocalRequestUsesGrammarPlannerAndPublishesOnlyValidatedTool()
        async throws
    {
        let authority = try LocalToolsAuthority(
            modelID: .init(rawValue: LocalModelCatalog.defaultVariant.id)
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeLocalGrammar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let inference = ScriptedLocalModelInference(
            scripts: [],
            decisions: [.init(
                action: "replace_text",
                path: "site.css",
                value: "color: blue",
                replacement: "color: teal",
                response: "I’ll update the color after you approve the edit."
            )]
        )
        let transport = AgentLocalModelProviderTransport(
            inference: inference,
            singleCallToolsCapability: authority.capability,
            toolRegistry: authority.toolRegistry,
            workspace: SandboxWorkspace(rootURL: root)
        )
        let request = try makeLocalAgentRequest(
            prompt: "Make the primary color in site.css feel calmer.",
            requestID: "local-grammar-edit",
            authority: authority
        )

        let frames = try await collect(try await transport.stream(
            request: request.encoded,
            descriptor: authority.descriptor,
            scope: request.scope
        ))

        let call = try XCTUnwrap(extractToolCall(from: frames))
        XCTAssertEqual(call.name, "replace_text")
        XCTAssertTrue(call.arguments.contains("site.css"))
        XCTAssertEqual(extractFinishReason(from: frames), "tool_calls")
        let decisionCalls = await inference.decisionCallCount()
        let textCalls = await inference.callCount()
        XCTAssertEqual(decisionCalls, 1)
        XCTAssertEqual(textCalls, 0)
    }

    func testCanonicalRunMetadataIsValidatedWithoutEnteringTheModelPrompt()
        async throws
    {
        let authority = try LocalToolsAuthority(
            modelID: .init(rawValue: LocalModelCatalog.defaultVariant.id)
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeLocalMetadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let inference = ScriptedLocalModelInference(
            scripts: [],
            decisions: [.init(
                action: "respond",
                response: "Four comes after three."
            )]
        )
        let transport = AgentLocalModelProviderTransport(
            inference: inference,
            singleCallToolsCapability: authority.capability,
            toolRegistry: authority.toolRegistry,
            workspace: SandboxWorkspace(rootURL: root)
        )
        let runID = UUID().uuidString
        let sequence: UInt64 = 3
        let requestID = "novaforge:\(runID):provider-turn:\(sequence)"
        let request = try makeLocalAgentRequest(
            prompt: "What number comes after three?",
            requestID: requestID,
            authority: authority,
            metadata: .object([
                "scheme": .string("novaforge_agent_context_v1"),
                "run_id": .string(runID),
                "conversation_id": .string(UUID().uuidString),
                "workspace_id": .string(UUID().uuidString),
                "execution_node_id": .string(UUID().uuidString),
                "event_sequence": .string(String(sequence)),
                "provider_id": .string("novaforge-local"),
                "item_count": .string("1"),
                "tool_count": .string(
                    String(authority.toolRegistry.descriptors.count)
                ),
            ])
        )

        let frames = try await collect(try await transport.stream(
            request: request.encoded,
            descriptor: authority.descriptor,
            scope: request.scope
        ))

        XCTAssertEqual(extractText(from: frames), "Four comes after three.")
        let decisionCallCount = await inference.decisionCallCount()
        XCTAssertEqual(decisionCallCount, 1)
    }

    func testUnfamiliarConversationalRequestUsesConstrainedRespondDecision()
        async throws
    {
        let authority = try LocalToolsAuthority(
            modelID: .init(rawValue: LocalModelCatalog.defaultVariant.id)
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeLocalRespond-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let inference = ScriptedLocalModelInference(
            scripts: [],
            decisions: [.init(
                action: "respond",
                path: "",
                value: "",
                replacement: "",
                response: "A closure stores behavior together with captured values."
            )]
        )
        let transport = AgentLocalModelProviderTransport(
            inference: inference,
            singleCallToolsCapability: authority.capability,
            toolRegistry: authority.toolRegistry,
            workspace: SandboxWorkspace(rootURL: root)
        )
        let request = try makeLocalAgentRequest(
            prompt: "Explain a Swift closure in one sentence.",
            requestID: "local-grammar-respond",
            authority: authority
        )

        let frames = try await collect(try await transport.stream(
            request: request.encoded,
            descriptor: authority.descriptor,
            scope: request.scope
        ))

        XCTAssertNil(extractToolCall(from: frames))
        XCTAssertEqual(
            extractText(from: frames),
            "A closure stores behavior together with captured values."
        )
        XCTAssertEqual(extractFinishReason(from: frames), "stop")
        let decisionCalls = await inference.decisionCallCount()
        let textCalls = await inference.callCount()
        XCTAssertEqual(decisionCalls, 1)
        XCTAssertEqual(textCalls, 0)
    }

    func testRejectedDeterministicWriteStopsWithoutLaterCallsOrFalseSuccess()
        async throws
    {
        let authority = try LocalToolsAuthority(
            modelID: .init(rawValue: LocalModelCatalog.defaultVariant.id)
        )
        let inference = ScriptedLocalModelInference(scripts: [])
        let workspace = SandboxWorkspace(rootURL: FileManager.default
            .temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let transport = AgentLocalModelProviderTransport(
            inference: inference,
            singleCallToolsCapability: authority.capability,
            toolRegistry: authority.toolRegistry,
            workspace: workspace
        )
        let exchange = try toolExchange(
            name: "write_file",
            providerCallID: "write-1",
            arguments: .object([
                "path": .string("game.html"),
                "contents": .string("<html></html>"),
            ]),
            status: .failed,
            output: .object(["status": .string("approval_rejected")]),
            error: .init(
                category: .authorization,
                code: "approval_rejected",
                publicMessage: "The tool request was not approved.",
                retryable: false
            )
        )
        let request = try makeLocalAgentRequest(
            prompt: "Build a snake game",
            requestID: "local-rejected-plan",
            authority: authority,
            trailingMessages: exchange
        )

        let frames = try await collect(try await transport.stream(
            request: request.encoded,
            descriptor: authority.descriptor,
            scope: request.scope
        ))

        XCTAssertNil(extractToolCall(from: frames))
        XCTAssertTrue(extractText(from: frames).contains("not approved"))
        XCTAssertFalse(extractText(from: frames).contains("Game ready"))
        let decisionCallCount = await inference.decisionCallCount()
        XCTAssertEqual(decisionCallCount, 0)
    }

    func testCanonicalToolResultWithoutOptionalNameCompletesLocalTurn()
        async throws
    {
        let authority = try LocalToolsAuthority(
            modelID: .init(rawValue: LocalModelCatalog.defaultVariant.id)
        )
        let inference = ScriptedLocalModelInference(scripts: [])
        let workspace = SandboxWorkspace(rootURL: FileManager.default
            .temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let transport = AgentLocalModelProviderTransport(
            inference: inference,
            singleCallToolsCapability: authority.capability,
            toolRegistry: authority.toolRegistry,
            workspace: workspace
        )
        let exchange = try toolExchange(
            name: "write_file",
            providerCallID: "write-canonical-1",
            arguments: .object([
                "path": .string("notes/hello.txt"),
                "contents": .string("hi"),
            ]),
            status: .succeeded,
            output: .object(["status": .string("committed")]),
            includeToolName: false
        )
        let request = try makeLocalAgentRequest(
            prompt: "create file notes/hello.txt with hi",
            requestID: "local-canonical-tool-result",
            authority: authority,
            trailingMessages: exchange
        )

        let frames = try await collect(try await transport.stream(
            request: request.encoded,
            descriptor: authority.descriptor,
            scope: request.scope
        ))

        XCTAssertNil(extractToolCall(from: frames))
        XCTAssertEqual(extractFinishReason(from: frames), "stop")
        XCTAssertFalse(extractText(from: frames).isEmpty)
        let inferenceCallCount = await inference.callCount()
        XCTAssertEqual(inferenceCallCount, 0)
    }

    func testFailedMiddleDeterministicStepStopsBeforeRemainingProofCall()
        async throws
    {
        let authority = try LocalToolsAuthority(
            modelID: .init(rawValue: LocalModelCatalog.defaultVariant.id)
        )
        let inference = ScriptedLocalModelInference(scripts: [])
        let workspace = SandboxWorkspace(rootURL: FileManager.default
            .temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let transport = AgentLocalModelProviderTransport(
            inference: inference,
            singleCallToolsCapability: authority.capability,
            toolRegistry: authority.toolRegistry,
            workspace: workspace
        )
        let write = try toolExchange(
            name: "write_file",
            providerCallID: "write-1",
            arguments: .object([
                "path": .string("game.html"),
                "contents": .string("<html></html>"),
            ]),
            status: .succeeded,
            output: .object(["path": .string("game.html")])
        )
        let validation = try toolExchange(
            name: "validate_html_file",
            providerCallID: "validate-1",
            arguments: .object([
                "path": .string("game.html"),
                "profile": .string("game"),
            ]),
            status: .failed,
            output: .object(["status": .string("failed")]),
            error: .init(
                category: .tool,
                code: "validation_failed",
                publicMessage: "The artifact did not validate.",
                retryable: true
            )
        )
        let request = try makeLocalAgentRequest(
            prompt: "Build a snake game",
            requestID: "local-failed-middle",
            authority: authority,
            trailingMessages: write + validation
        )

        let frames = try await collect(try await transport.stream(
            request: request.encoded,
            descriptor: authority.descriptor,
            scope: request.scope
        ))

        XCTAssertNil(extractToolCall(from: frames))
        XCTAssertTrue(extractText(from: frames).contains("validate_html_file"))
        XCTAssertTrue(extractText(from: frames).contains("failed"))
        XCTAssertFalse(extractText(from: frames).contains("Game ready"))
    }

    func testModelPlannerReceivesRecentToolNameArgumentsAndDiscoveredPath()
        async throws
    {
        let authority = try LocalToolsAuthority(
            modelID: .init(rawValue: LocalModelCatalog.defaultVariant.id)
        )
        let inference = ScriptedLocalModelInference(
            scripts: [],
            decisions: [.init(
                action: "respond",
                path: "",
                value: "",
                replacement: "",
                response: "I found the file and can inspect the matching range next."
            )]
        )
        let workspace = SandboxWorkspace(rootURL: FileManager.default
            .temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let transport = AgentLocalModelProviderTransport(
            inference: inference,
            singleCallToolsCapability: authority.capability,
            toolRegistry: authority.toolRegistry,
            workspace: workspace
        )
        let search = try toolExchange(
            name: "search_text",
            providerCallID: "search-1",
            arguments: .object([
                "query": .string("needle"),
                "path": .string("Sources"),
            ]),
            status: .succeeded,
            output: .object([
                "matches": .array([
                    .string("Sources/Feature Widget.swift:845: needle"),
                ]),
            ])
        )
        let request = try makeLocalAgentRequest(
            prompt: "Continue carefully from the discovered match.",
            requestID: "local-context-carry",
            authority: authority,
            trailingMessages: search
        )

        _ = try await collect(try await transport.stream(
            request: request.encoded,
            descriptor: authority.descriptor,
            scope: request.scope
        ))

        let decisionRequests = await inference.decisionRequests()
        let decisionRequest = try XCTUnwrap(decisionRequests.first)
        let context = decisionRequest.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(context.contains("search_text"), context)
        XCTAssertTrue(context.contains("Sources/Feature Widget.swift"), context)
        XCTAssertTrue(context.contains("needle"), context)
    }

    func testCanonicalTextStreamUsesExactModelAndHonestUsage() async throws {
        let fixture = try makeLocalTransportFixture(requestID: "local-success")
        let inference = ScriptedLocalModelInference(scripts: [.events([
            .text("hello "),
            .text("offline"),
            .usage(generatedTokenCount: 2),
            .completed(reason: .completed),
        ])])
        let transport = AgentLocalModelProviderTransport(inference: inference)

        let frames = try await collect(try await transport.stream(
            request: fixture.encoded,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope
        ))

        XCTAssertEqual(extractText(from: frames), "hello offline")
        XCTAssertEqual(extractUsage(from: frames), .init(
            inputTokens: 34,
            outputTokens: 2
        ))
        XCTAssertEqual(frames.count, 6)
        XCTAssertEqual(extractFinishReason(from: frames), "stop")
        XCTAssertTrue(frames.contains(.done))
        XCTAssertEqual(frames.last, .done)
        let calls = await inference.requests()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].scope, fixture.scope)
        XCTAssertEqual(calls[0].modelID, LocalModelCatalog.all[0].id)
        XCTAssertEqual(calls[0].messages, [
            .init(role: .user, content: "Hi"),
        ])
        XCTAssertEqual(calls[0].temperature, 0.2)
        XCTAssertEqual(calls[0].maximumOutputTokens, 8)
        let stopRequests = await inference.stopRequests()
        XCTAssertEqual(stopRequests, [])
    }

    func testDescriptorMustBeExactBuiltInCatalogRoute() async throws {
        let fixture = try makeLocalTransportFixture(requestID: "descriptor")
        let inference = ScriptedLocalModelInference(scripts: [])
        let transport = AgentLocalModelProviderTransport(inference: inference)
        let descriptor = fixture.adapter.descriptor

        let hosted = ProviderAdapterDescriptor(
            route: .init(
                providerID: descriptor.route.providerID,
                modelID: descriptor.route.modelID,
                adapterID: descriptor.route.adapterID,
                capabilities: descriptor.route.capabilities,
                deployment: .hostedService,
                provenance: descriptor.route.provenance
            ),
            dialect: descriptor.dialect,
            requestPath: descriptor.requestPath
        )
        await assertStartRejected(
            transport,
            request: fixture.encoded,
            descriptor: hosted,
            scope: fixture.scope,
            expected: .invalidDescriptor
        )

        let inflated = ProviderAdapterDescriptor(
            route: .init(
                providerID: descriptor.route.providerID,
                modelID: descriptor.route.modelID,
                adapterID: descriptor.route.adapterID,
                capabilities: .localTextBaseline,
                deployment: descriptor.route.deployment,
                provenance: descriptor.route.provenance
            ),
            dialect: descriptor.dialect,
            requestPath: descriptor.requestPath
        )
        await assertStartRejected(
            transport,
            request: fixture.encoded,
            descriptor: inflated,
            scope: fixture.scope,
            expected: .invalidDescriptor
        )

        let unknownModel = ProviderAdapterDescriptor(
            route: .init(
                providerID: descriptor.route.providerID,
                modelID: .init(rawValue: "unknown-local-model"),
                adapterID: descriptor.route.adapterID,
                capabilities: descriptor.route.capabilities,
                deployment: descriptor.route.deployment,
                provenance: descriptor.route.provenance
            ),
            dialect: descriptor.dialect,
            requestPath: descriptor.requestPath
        )
        await assertStartRejected(
            transport,
            request: fixture.encoded,
            descriptor: unknownModel,
            scope: fixture.scope,
            expected: .invalidDescriptor
        )
        let callCount = await inference.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testPathAndBodyModelMismatchFailBeforeInference() async throws {
        let fixture = try makeLocalTransportFixture(requestID: "path-model")
        let inference = ScriptedLocalModelInference(scripts: [])
        let transport = AgentLocalModelProviderTransport(inference: inference)

        let remotePath = ProviderEncodedRequest(
            relativePath: "https://example.invalid/v1/chat/completions",
            body: fixture.encoded.body
        )
        await assertStartRejected(
            transport,
            request: remotePath,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope,
            expected: .invalidRequestEnvelope
        )

        let mismatchedModel = replacingBody(fixture.encoded) {
            $0["model"] = .string(LocalModelCatalog.all[1].id)
        }
        await assertStartRejected(
            transport,
            request: mismatchedModel,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope,
            expected: .requestModelMismatch
        )
        let callCount = await inference.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testToolsImagesStructuredContentAndToolHistoryCannotBeSmuggled() async throws {
        let fixture = try makeLocalTransportFixture(requestID: "smuggling")
        let inference = ScriptedLocalModelInference(scripts: [])
        let transport = AgentLocalModelProviderTransport(inference: inference)

        let tools = replacingBody(fixture.encoded) {
            $0["tools"] = .array([])
        }
        await assertStartRejected(
            transport,
            request: tools,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope,
            expected: .invalidRequestEnvelope
        )

        let parallelTools = replacingBody(fixture.encoded) {
            $0["parallel_tool_calls"] = .bool(true)
        }
        await assertStartRejected(
            transport,
            request: parallelTools,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope,
            expected: .invalidRequestEnvelope
        )

        let toolHistory = replacingFirstMessage(fixture.encoded) {
            $0["tool_calls"] = .array([])
        }
        await assertStartRejected(
            transport,
            request: toolHistory,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope,
            expected: .invalidRequestEnvelope
        )

        let image = replacingFirstMessage(fixture.encoded) {
            $0["content"] = .array([.object([
                "type": .string("image_url"),
                "image_url": .object(["url": .string("data:image/png;base64,AAAA")]),
            ])])
        }
        await assertStartRejected(
            transport,
            request: image,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope,
            expected: .invalidRequestEnvelope
        )

        let structured = replacingFirstMessage(fixture.encoded) {
            $0["content"] = .array([.object([
                "type": .string("json"),
                "json": .object(["action": .string("write_file")]),
            ])])
        }
        await assertStartRejected(
            transport,
            request: structured,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope,
            expected: .invalidRequestEnvelope
        )
        let callCount = await inference.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testCredentialURLAndMetadataAuthorityAreRejectedWithoutEcho() async throws {
        let fixture = try makeLocalTransportFixture(requestID: "no-secrets")
        let inference = ScriptedLocalModelInference(scripts: [])
        let transport = AgentLocalModelProviderTransport(inference: inference)
        let secret = "sk-local-must-never-escape"

        for key in ["api_key", "authorization", "base_url"] {
            let poisoned = replacingBody(fixture.encoded) {
                $0[key] = .string(key == "base_url" ? "https://evil.invalid" : secret)
            }
            do {
                _ = try await transport.stream(
                    request: poisoned,
                    descriptor: fixture.adapter.descriptor,
                    scope: fixture.scopeWithAttempt("secret-\(key)")
                )
                XCTFail("Expected \(key) to be rejected")
            } catch {
                XCTAssertEqual(
                    error as? AgentLocalModelProviderTransportError,
                    .invalidRequestEnvelope
                )
                XCTAssertFalse(String(describing: error).contains(secret))
                XCTAssertFalse(String(describing: error).contains("evil.invalid"))
            }
        }

        let metadata = replacingBody(fixture.encoded) {
            $0["metadata"] = .object(["authorization": .string(secret)])
        }
        await assertStartRejected(
            transport,
            request: metadata,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scopeWithAttempt("secret-metadata"),
            expected: .invalidRequestEnvelope
        )
        let callCount = await inference.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testConservativeInputBoundFailsBeforeModelDispatch() async throws {
        let fixture = try makeLocalTransportFixture(requestID: "input-bound")
        let inference = ScriptedLocalModelInference(scripts: [])
        let transport = AgentLocalModelProviderTransport(inference: inference)
        let variant = LocalModelCatalog.all[0]
        let oversized = replacingFirstMessage(fixture.encoded) {
            $0["content"] = .string(String(
                repeating: "a",
                count: Int(variant.contextTokens)
            ))
        }

        await assertStartRejected(
            transport,
            request: oversized,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope,
            expected: .inputLimitExceeded
        )
        let callCount = await inference.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testMissingDuplicateAndInvalidUsageFailClosed() async throws {
        try await assertStreamFailure(
            script: .events([
                .text("x"),
                .completed(reason: .completed),
            ]),
            expected: .missingUsage,
            requestID: "missing-usage"
        )
        try await assertStreamFailure(
            script: .events([
                .usage(generatedTokenCount: 1),
                .usage(generatedTokenCount: 1),
            ]),
            expected: .duplicateUsage,
            requestID: "duplicate-usage"
        )
        try await assertStreamFailure(
            script: .events([
                .text("x"),
                .usage(generatedTokenCount: 0),
            ]),
            expected: .invalidUsage,
            requestID: "zero-usage"
        )
        try await assertStreamFailure(
            script: .events([
                .usage(generatedTokenCount: 9),
            ]),
            expected: .invalidUsage,
            requestID: "excess-usage"
        )
        try await assertStreamFailure(
            script: .events([
                .usage(generatedTokenCount: 1),
            ]),
            expected: .missingCompletion,
            requestID: "missing-completion"
        )
    }

    func testDuplicateCompletionAndLateOutputFailClosed() async throws {
        try await assertStreamFailure(
            script: .events([
                .usage(generatedTokenCount: 1),
                .completed(reason: .completed),
                .completed(reason: .completed),
            ]),
            expected: .duplicateCompletion,
            requestID: "duplicate-completion"
        )
        try await assertStreamFailure(
            script: .events([
                .usage(generatedTokenCount: 1),
                .completed(reason: .completed),
                .text("late"),
            ]),
            expected: .eventAfterCompletion,
            requestID: "late-output"
        )
        try await assertStreamFailure(
            script: .events([
                .usage(generatedTokenCount: 1),
                .text("late"),
            ]),
            expected: .outputAfterUsage,
            requestID: "output-after-usage"
        )
    }

    func testCancellationEmitsCanonicalCancellationAndStopsExactAttemptOnce() async throws {
        let fixture = try makeLocalTransportFixture(requestID: "cancel")
        let inference = ScriptedLocalModelInference(scripts: [.cancelled])
        let transport = AgentLocalModelProviderTransport(inference: inference)

        let frames = try await collect(try await transport.stream(
            request: fixture.encoded,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope
        ))

        XCTAssertEqual(frames.last, .cancelled(reason: "userRequested"))
        let stoppedScopes = (await inference.stopRequests()).map(\.scope)
        let callCount = await inference.callCount()
        XCTAssertEqual(stoppedScopes, [fixture.scope])
        XCTAssertEqual(callCount, 1)
    }

    func testConsumerBackpressureStopsInferenceAndFailsInsteadOfDroppingText() async throws {
        let fixture = try makeLocalTransportFixture(requestID: "backpressure")
        let inference = ScriptedLocalModelInference(scripts: [.events(
            Array(repeating: .text("x"), count: 256) + [
                .usage(generatedTokenCount: 8),
                .completed(reason: .completed),
            ]
        )])
        let transport = AgentLocalModelProviderTransport(inference: inference)
        let stream = try await transport.stream(
            request: fixture.encoded,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope
        )

        for _ in 0 ..< 10_000 {
            if (await inference.stopRequests()).count == 1 { break }
            await Task.yield()
        }
        do {
            _ = try await collect(stream)
            XCTFail("Expected bounded-buffer backpressure failure")
        } catch {
            XCTAssertEqual(
                error as? AgentLocalModelProviderTransportError,
                .consumerBackpressureExceeded
            )
        }
        let callCount = await inference.callCount()
        let stopCount = (await inference.stopRequests()).count
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    func testAttemptScopesAreSingleUseBusyModelsDoNotCrossAndResponseIDsDiffer() async throws {
        let first = try makeLocalTransportFixture(requestID: "isolation")
        let inference = ScriptedLocalModelInference(scripts: [
            .waitThenEvents(successEvents("first")),
            .events(successEvents("second")),
        ])
        let transport = AgentLocalModelProviderTransport(inference: inference)
        let firstStream = try await transport.stream(
            request: first.encoded,
            descriptor: first.adapter.descriptor,
            scope: first.scope
        )

        await assertStartRejected(
            transport,
            request: first.encoded,
            descriptor: first.adapter.descriptor,
            scope: first.scopeWithAttempt("busy-attempt"),
            expected: .modelBusy
        )
        await inference.releaseWaitingScripts()
        let firstFrames = try await collect(firstStream)

        await assertStartRejected(
            transport,
            request: first.encoded,
            descriptor: first.adapter.descriptor,
            scope: first.scope,
            expected: .scopeAlreadyConsumed
        )

        let secondScope = first.scopeWithAttempt("attempt-2")
        let secondFrames = try await collect(try await transport.stream(
            request: first.encoded,
            descriptor: first.adapter.descriptor,
            scope: secondScope
        ))
        XCTAssertEqual(extractText(from: firstFrames), "first")
        XCTAssertEqual(extractText(from: secondFrames), "second")
        XCTAssertNotEqual(
            extractResponseID(from: firstFrames),
            extractResponseID(from: secondFrames)
        )
        let observedScopes = (await inference.requests()).map(\.scope)
        XCTAssertEqual(observedScopes, [first.scope, secondScope])
    }

    func testConsumedScopeRegistryIsLifetimeBoundedAndFailsClosedWithoutEviction() async throws {
        let fixture = try makeLocalTransportFixture(requestID: "registry-bound")
        let inference = ScriptedLocalModelInference(scripts: [
            .events(successEvents("first")),
        ])
        let transport = AgentLocalModelProviderTransport(
            inference: inference,
            maximumConsumedScopes: 1
        )
        _ = try await collect(try await transport.stream(
            request: fixture.encoded,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope
        ))

        await assertStartRejected(
            transport,
            request: fixture.encoded,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scopeWithAttempt("capacity-attempt"),
            expected: .attemptRegistryCapacityExceeded
        )
        await assertStartRejected(
            transport,
            request: fixture.encoded,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope,
            expected: .scopeAlreadyConsumed
        )
        let callCount = await inference.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testInferenceFailureIsNotRetriedAndDoesNotLeakUnderlyingSecret() async throws {
        let fixture = try makeLocalTransportFixture(requestID: "failure")
        let secret = "private-local-prompt-secret"
        let inference = ScriptedLocalModelInference(scripts: [.failure(secret)])
        let transport = AgentLocalModelProviderTransport(inference: inference)
        let stream = try await transport.stream(
            request: fixture.encoded,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope
        )

        do {
            _ = try await collect(stream)
            XCTFail("Expected sanitized inference failure")
        } catch {
            XCTAssertEqual(
                error as? AgentLocalModelProviderTransportError,
                .inferenceFailed
            )
            XCTAssertFalse(String(describing: error).contains(secret))
        }
        let callCount = await inference.callCount()
        let stoppedScopes = (await inference.stopRequests()).map(\.scope)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(stoppedScopes, [fixture.scope])
    }

    private func assertStreamFailure(
        script: ScriptedLocalModelInference.Script,
        expected: AgentLocalModelProviderTransportError,
        requestID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try makeLocalTransportFixture(requestID: requestID)
        let inference = ScriptedLocalModelInference(scripts: [script])
        let transport = AgentLocalModelProviderTransport(inference: inference)
        let stream = try await transport.stream(
            request: fixture.encoded,
            descriptor: fixture.adapter.descriptor,
            scope: fixture.scope
        )
        do {
            _ = try await collect(stream)
            XCTFail("Expected stream failure \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? AgentLocalModelProviderTransportError,
                expected,
                file: file,
                line: line
            )
        }
        let callCount = await inference.callCount()
        let stopCount = (await inference.stopRequests()).count
        XCTAssertEqual(callCount, 1, file: file, line: line)
        XCTAssertEqual(stopCount, 1, file: file, line: line)
    }

    private func makeLocalAgentRequest(
        prompt: String,
        requestID: String,
        authority: LocalToolsAuthority,
        trailingMessages: [ProviderMessage] = [],
        metadata: JSONValue = .object([:])
    ) throws -> (encoded: ProviderEncodedRequest, scope: ProviderAttemptScope) {
        let adapter = try authority.catalog.adapter(
            id: authority.descriptor.route.adapterID
        )
        let tools = authority.toolRegistry.providerDefinitions().map {
            AgentProviders.ProviderToolDefinition(
                name: $0.function.name,
                description: $0.function.description,
                parameters: $0.function.parameters,
                strict: $0.function.strict
            )
        }
        let canonical = CanonicalProviderRequest(
            requestID: requestID,
            model: authority.descriptor.route.modelID,
            messages: [.init(role: .user, content: [.text(prompt)])]
                + trailingMessages,
            tools: tools,
            options: .init(
                maximumOutputTokens: 96,
                temperature: 0,
                parallelToolCalls: false,
                toolChoice: .auto
            ),
            metadata: metadata
        )
        return (
            try adapter.encode(canonical),
            .init(
                requestID: requestID,
                attemptID: .init(rawValue: "\(requestID):attempt:1")
            )
        )
    }

    private func toolExchange(
        name: String,
        providerCallID: String,
        arguments: JSONValue,
        status: ToolResultStatus,
        output: JSONValue,
        error: AgentErrorInfo? = nil,
        includeToolName: Bool = true
    ) throws -> [ProviderMessage] {
        let result = ToolResult(
            modelItemID: .init(rawValue: UUID()),
            callID: .init(rawValue: UUID()),
            status: status,
            output: output,
            error: error
        )
        let data = try JSONEncoder().encode(
            LocalTransportTestToolResultEnvelope(
                kind: "tool_result",
                body: result
            )
        )
        let resultText = try XCTUnwrap(String(data: data, encoding: .utf8))
        return [
            .init(
                role: .assistant,
                content: [.toolCall(.init(
                    callID: providerCallID,
                    name: name,
                    arguments: arguments
                ))]
            ),
            .init(
                role: .tool,
                content: [.text(resultText)],
                toolCallID: providerCallID,
                name: includeToolName ? name : nil
            ),
        ]
    }

    private func assertStartRejected(
        _ transport: AgentLocalModelProviderTransport,
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope,
        expected: AgentLocalModelProviderTransportError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await transport.stream(
                request: request,
                descriptor: descriptor,
                scope: scope
            )
            XCTFail("Expected start failure \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? AgentLocalModelProviderTransportError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

private struct LocalTransportFixture {
    let adapter: LocalModelAdapter
    let encoded: ProviderEncodedRequest
    let scope: ProviderAttemptScope

    func scopeWithAttempt(_ attemptID: String) -> ProviderAttemptScope {
        .init(requestID: scope.requestID, attemptID: .init(rawValue: attemptID))
    }
}

private struct LocalTransportTestToolResultEnvelope: Encodable {
    let kind: String
    let body: ToolResult
}

private func makeLocalTransportFixture(requestID: String) throws -> LocalTransportFixture {
    let variant = LocalModelCatalog.all[0]
    let adapter = try LocalModelAdapter(configuration: .init(
        modelID: .init(rawValue: variant.id),
        contextWindowTokens: UInt64(variant.contextTokens),
        maximumOutputTokens: UInt64(variant.maxNewTokens),
        toolMode: .textOnly
    ))
    let canonical = CanonicalProviderRequest(
        requestID: requestID,
        model: adapter.descriptor.route.modelID,
        messages: [.init(role: .user, content: [.text("Hi")])],
        options: .init(
            maximumOutputTokens: 8,
            temperature: 0.2,
            parallelToolCalls: false,
            toolChoice: .none
        )
    )
    return LocalTransportFixture(
        adapter: adapter,
        encoded: try adapter.encode(canonical),
        scope: .init(
            requestID: requestID,
            attemptID: .init(rawValue: "\(requestID):provider-attempt:1")
        )
    )
}

private actor ScriptedLocalModelInference: AgentLocalModelInferenceStreaming,
    AgentLocalModelActionPlanning
{
    enum Script: Sendable {
        case events([AgentLocalModelInferenceEvent])
        case waitThenEvents([AgentLocalModelInferenceEvent])
        case cancelled
        case failure(String)
    }

    private var remainingScripts: [Script]
    private var remainingDecisions: [LocalAgentModelDecision]
    private var observedRequests: [AgentLocalModelInferenceRequest] = []
    private var observedDecisionRequests: [AgentLocalModelInferenceRequest] = []
    private var observedStops: [AgentLocalModelInferenceRequest] = []
    private var waitingScriptsReleased = false

    init(
        scripts: [Script],
        decisions: [LocalAgentModelDecision] = []
    ) {
        remainingScripts = scripts
        remainingDecisions = decisions
    }

    func decideLocalAgentTurn(
        request: AgentLocalModelInferenceRequest,
        completedToolCallCount: Int
    ) async throws -> LocalAgentModelDecision {
        observedDecisionRequests.append(request)
        guard completedToolCallCount >= 0,
              !remainingDecisions.isEmpty else {
            throw ScriptedLocalModelInferenceFailure.unexpectedCall
        }
        return remainingDecisions.removeFirst()
    }

    func stream(
        request: AgentLocalModelInferenceRequest,
        onEvent: @escaping @Sendable (AgentLocalModelInferenceEvent) async throws -> Void
    ) async throws {
        observedRequests.append(request)
        guard !remainingScripts.isEmpty else {
            throw ScriptedLocalModelInferenceFailure.unexpectedCall
        }
        let script = remainingScripts.removeFirst()
        switch script {
        case let .events(events):
            for event in events { try await onEvent(event) }
        case let .waitThenEvents(events):
            while !waitingScriptsReleased {
                try await Task.sleep(for: .milliseconds(1))
            }
            for event in events { try await onEvent(event) }
        case .cancelled:
            throw CancellationError()
        case let .failure(secret):
            throw ScriptedLocalModelInferenceFailure.secret(secret)
        }
    }

    func stop(request: AgentLocalModelInferenceRequest) async {
        observedStops.append(request)
    }

    func requests() -> [AgentLocalModelInferenceRequest] { observedRequests }
    func stopRequests() -> [AgentLocalModelInferenceRequest] { observedStops }
    func callCount() -> Int { observedRequests.count }
    func decisionCallCount() -> Int { observedDecisionRequests.count }
    func decisionRequests() -> [AgentLocalModelInferenceRequest] {
        observedDecisionRequests
    }

    func releaseWaitingScripts() {
        waitingScriptsReleased = true
    }
}

private enum ScriptedLocalModelInferenceFailure: Error, Sendable {
    case unexpectedCall
    case secret(String)
}

private func successEvents(_ text: String) -> [AgentLocalModelInferenceEvent] {
    [
        .text(text),
        .usage(generatedTokenCount: 1),
        .completed(reason: .completed),
    ]
}

private func collect(
    _ stream: AsyncThrowingStream<ProviderWireFrame, any Error>
) async throws -> [ProviderWireFrame] {
    var frames: [ProviderWireFrame] = []
    for try await frame in stream { frames.append(frame) }
    return frames
}

private func replacingBody(
    _ request: ProviderEncodedRequest,
    mutate: (inout [String: JSONValue]) -> Void
) -> ProviderEncodedRequest {
    guard case let .object(original) = request.body else {
        fatalError("Local fixture body must be an object")
    }
    var body = original
    mutate(&body)
    return ProviderEncodedRequest(
        method: request.method,
        relativePath: request.relativePath,
        body: .object(body)
    )
}

private func replacingFirstMessage(
    _ request: ProviderEncodedRequest,
    mutate: (inout [String: JSONValue]) -> Void
) -> ProviderEncodedRequest {
    replacingBody(request) { body in
        guard let rawMessages = body["messages"],
              case var .array(messages) = rawMessages,
              !messages.isEmpty,
              case var .object(first) = messages[0]
        else { fatalError("Local fixture message must be an object") }
        mutate(&first)
        messages[0] = .object(first)
        body["messages"] = .array(messages)
    }
}

private func extractText(from frames: [ProviderWireFrame]) -> String {
    frames.compactMap { frame -> String? in
        guard case let .json(.object(body)) = frame,
              let rawChoices = body["choices"],
              case let .array(choices) = rawChoices,
              let first = choices.first,
              case let .object(choice) = first,
              let rawDelta = choice["delta"],
              case let .object(delta) = rawDelta,
              let rawContent = delta["content"],
              case let .string(content) = rawContent
        else { return nil }
        return content
    }.joined()
}

private func extractToolCall(
    from frames: [ProviderWireFrame]
) -> (name: String, arguments: String)? {
    for frame in frames {
        guard case let .json(.object(body)) = frame,
              let rawChoices = body["choices"],
              case let .array(choices) = rawChoices,
              let first = choices.first,
              case let .object(choice) = first,
              let rawDelta = choice["delta"],
              case let .object(delta) = rawDelta,
              let rawCalls = delta["tool_calls"],
              case let .array(calls) = rawCalls,
              let firstCall = calls.first,
              case let .object(call) = firstCall,
              let rawFunction = call["function"],
              case let .object(function) = rawFunction,
              let rawName = function["name"],
              case let .string(name) = rawName,
              let rawArguments = function["arguments"],
              case let .string(arguments) = rawArguments
        else { continue }
        return (name, arguments)
    }
    return nil
}

private func extractUsage(from frames: [ProviderWireFrame]) -> ProviderUsage? {
    for frame in frames {
        guard case let .json(.object(body)) = frame,
              let rawUsage = body["usage"],
              case let .object(usage) = rawUsage,
              let rawInput = usage["prompt_tokens"],
              let rawOutput = usage["completion_tokens"],
              let input = unsignedInteger(rawInput),
              let output = unsignedInteger(rawOutput)
        else { continue }
        return ProviderUsage(inputTokens: input, outputTokens: output)
    }
    return nil
}

private func extractResponseID(from frames: [ProviderWireFrame]) -> String? {
    for frame in frames {
        guard case let .json(.object(body)) = frame,
              let rawID = body["id"],
              case let .string(id) = rawID
        else { continue }
        return id
    }
    return nil
}

private func extractFinishReason(from frames: [ProviderWireFrame]) -> String? {
    for frame in frames {
        guard case let .json(.object(body)) = frame,
              let rawChoices = body["choices"],
              case let .array(choices) = rawChoices,
              let first = choices.first,
              case let .object(choice) = first,
              let rawReason = choice["finish_reason"],
              case let .string(reason) = rawReason
        else { continue }
        return reason
    }
    return nil
}

private func unsignedInteger(_ value: JSONValue) -> UInt64? {
    guard case let .number(number) = value else { return nil }
    switch number {
    case let .unsignedInteger(value): return value
    case let .integer(value) where value >= 0: return UInt64(value)
    case .integer, .floatingPoint: return nil
    }
}

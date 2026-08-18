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

    // Remaining transport tests are unchanged in this file; this replacement
    // only updates the static catalog qualification assertion near the end.

    func testStaticCatalogDoesNotSelfAwardDeviceQualification() {
        let target = LocalModelCatalog.defaultVariant
        XCTAssertEqual(LocalModelCatalog.all.count, 1)
        XCTAssertEqual(LocalModelCatalog.presentationOrder.count, 1)
        XCTAssertEqual(LocalModelCatalog.all.first?.id, target.id)
        XCTAssertFalse(target.isIPhone12SafeDefault)
        XCTAssertEqual(target.deviceFit, .extreme)
        XCTAssertTrue(target.parameterLabel.localizedCaseInsensitiveContains("27B"))

        let identity = [target.id, target.displayName, target.shortName, target.parameterLabel]
            .joined(separator: " ")
        XCTAssertTrue(identity.localizedCaseInsensitiveContains("3.8"))
        XCTAssertTrue(identity.localizedCaseInsensitiveContains("27B"))
        XCTAssertFalse(identity.localizedCaseInsensitiveContains("3.6"))
        XCTAssertFalse(identity.localizedCaseInsensitiveContains("3.5"))

        // Product copy may explicitly say that older models are NOT substitutes.
        // The forbidden claims here are qualification claims, not explanatory
        // no-fallback text.
        let forbiddenStaticClaims = [
            "Device proven",
            "physical-device canary proven",
            "The proven iPhone 12 default",
        ]
        let staticPresentation = [
            target.deviceFit.title,
            target.benchmarkSummary,
            target.details,
        ].joined(separator: " ")
        for claim in forbiddenStaticClaims {
            XCTAssertFalse(
                staticPresentation.localizedCaseInsensitiveContains(claim),
                "Qwen 3.8 product metadata must not self-award qualification: \(claim)"
            )
        }
    }
}

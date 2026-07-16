import Foundation
import XCTest

final class OpenAIClientStreamingTests: XCTestCase {
    func testDecodesValidContentStreamEndingInDone() async throws {
        let message = try await StreamingResponseDecoder.decode(
            lines: [
                sseContent("Hello"),
                sseContent(" world"),
                "data: [DONE]"
            ]
        )

        XCTAssertEqual(message.role, "assistant")
        XCTAssertEqual(message.content, "Hello world")
        XCTAssertNil(message.tool_calls)
    }

    func testDecodesSplitStreamedToolCallArguments() async throws {
        let message = try await StreamingResponseDecoder.decode(lines: [
            sseToolCall(id: "call_1", type: "function", name: "write_file", arguments: "{\"path\":"),
            sseToolCall(arguments: "\"index.html\",\"contents\":\"hi\"}"),
            "data: [DONE]"
        ])

        let tool = try XCTUnwrap(message.tool_calls?.first)
        XCTAssertEqual(tool.id, "call_1")
        XCTAssertEqual(tool.function.name, "write_file")
        XCTAssertEqual(tool.function.arguments, "{\"path\":\"index.html\",\"contents\":\"hi\"}")
    }

    func testMalformedAfterUsableContentThrowsInsteadOfSavingPartialOutput() async throws {
        await XCTAssertThrowsAsyncError(
            try await StreamingResponseDecoder.decode(lines: [
                self.sseContent("partial"),
                "data: {not-json}",
                "data: [DONE]"
            ])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("malformed data after a partial response"))
        }
    }

    func testMissingDoneThrows() async throws {
        await XCTAssertThrowsAsyncError(
            try await StreamingResponseDecoder.decode(lines: [self.sseContent("partial")])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("completion marker"))
        }
    }

    func testIncompleteToolArgumentsThrowBeforeToolsRun() async throws {
        await XCTAssertThrowsAsyncError(
            try await StreamingResponseDecoder.decode(lines: [
                self.sseToolCall(id: "call_1", type: "function", name: "write_file", arguments: "{\"path\":\"index.html\""),
                "data: [DONE]"
            ])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("incomplete tool-call arguments"))
        }
    }

    func testStreamedToolArgumentsMustBeJSONObject() async throws {
        await XCTAssertThrowsAsyncError(
            try await StreamingResponseDecoder.decode(lines: [
                self.sseToolCall(id: "call_array", type: "function", name: "write_file", arguments: "[\"index.html\"]"),
                "data: [DONE]"
            ])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a JSON object"))
        }

        await XCTAssertThrowsAsyncError(
            try await StreamingResponseDecoder.decode(lines: [
                self.sseToolCall(id: "call_scalar", type: "function", name: "write_file", arguments: "123"),
                "data: [DONE]"
            ])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a JSON object"))
        }
    }

    func testNonStreamingToolArgumentsMustBeJSONObject() throws {
        let arrayCall = APIToolCall(
            id: "call_array",
            type: "function",
            function: APIFunctionCall(name: "write_file", arguments: "[\"index.html\"]")
        )
        XCTAssertThrowsError(
            try ToolCallArgumentValidator.validate([arrayCall], sourceDescription: "provider response")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a JSON object"))
        }

        let nestedArrayCall = APIToolCall(
            id: "call_nested_array",
            type: "function",
            function: APIFunctionCall(name: "write_file", arguments: "{\"path\":\"index.html\",\"contents\":[\"hi\"]}")
        )
        XCTAssertThrowsError(
            try ToolCallArgumentValidator.validate([nestedArrayCall], sourceDescription: "provider response")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("nested arrays or objects"))
        }

        let nestedObjectCall = APIToolCall(
            id: "call_nested_object",
            type: "function",
            function: APIFunctionCall(name: "replace_text", arguments: "{\"path\":\"index.html\",\"new\":{\"text\":\"hi\"}}")
        )
        XCTAssertThrowsError(
            try ToolCallArgumentValidator.validate([nestedObjectCall], sourceDescription: "provider response")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("nested arrays or objects"))
        }

        let objectCall = APIToolCall(
            id: "call_object",
            type: "function",
            function: APIFunctionCall(name: "write_file", arguments: "{\"path\":\"index.html\",\"contents\":\"hi\"}")
        )
        XCTAssertNoThrow(
            try ToolCallArgumentValidator.validate([objectCall], sourceDescription: "provider response")
        )
    }

    func testKeepaliveAndBlankLinesAreIgnored() async throws {
        let message = try await StreamingResponseDecoder.decode(lines: [
            "",
            ": keepalive",
            "event: ping",
            sseContent("ok"),
            "data: [DONE]"
        ])

        XCTAssertEqual(message.content, "ok")
    }

    func testLocalModelToolCallsRejectNestedArgumentsInsteadOfStringifyingThem() {
        let output = """
        I will inspect one file.
        <tool_call>{"name":"write_file","arguments":{"path":"index.html","contents":["hi"]}}</tool_call>
        <tool_call>{"name":"read_file","arguments":{"path":"README.md"}}</tool_call>
        done
        """

        let result = LocalModelClient.extractToolCalls(from: output)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.function.name, "read_file")
        XCTAssertEqual(result.toolCalls.first?.function.arguments, "{\"path\":\"README.md\"}")
        XCTAssertFalse(result.content.contains("<tool_call>"))
    }

    func testLocalModelToolCallsRejectMalformedOrMissingArgumentsInsteadOfDefaultingToEmptyObject() {
        let output = """
        <tool_call>{"name":"write_file","arguments":"not-json"}</tool_call>
        <tool_call>{"name":"write_file","arguments":"[]"}</tool_call>
        <tool_call>{"name":"workspace_summary"}</tool_call>
        <tool_call>{"name":"read_file","arguments":"{\\"path\\":\\"README.md\\"}"}</tool_call>
        """

        let result = LocalModelClient.extractToolCalls(from: output)

        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.function.name, "read_file")
        XCTAssertEqual(result.toolCalls.first?.function.arguments, "{\"path\":\"README.md\"}")
    }

    func testRejectsOverBudgetStreamedContentBeforeSavingPartialOutput() async throws {
        let oversized = String(repeating: "x", count: 270_000)
        await XCTAssertThrowsAsyncError(
            try await StreamingResponseDecoder.decode(lines: [
                self.sseContent(oversized),
                "data: [DONE]"
            ])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("streamed text limit"))
        }
    }

    func testRejectsOverBudgetStreamedToolArgumentsBeforeToolsRun() async throws {
        let oversizedArguments = "{\"path\":\"index.html\",\"contents\":\"" + String(repeating: "x", count: 530_000) + "\"}"
        await XCTAssertThrowsAsyncError(
            try await StreamingResponseDecoder.decode(lines: [
                self.sseToolCall(id: "call_huge", type: "function", name: "write_file", arguments: oversizedArguments),
                "data: [DONE]"
            ])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("streamed tool-call argument limit"))
        }
    }

    func testCustomProviderEndpointRequiresHTTPHostAndNoInlineCredentials() {
        let missingScheme = ProviderConfiguration(
            provider: .custom,
            modelID: "model",
            apiKey: "test-key",
            customChatCompletionsURL: "localhost:11434/v1"
        )
        XCTAssertNil(missingScheme.chatCompletionsURL)
        XCTAssertNil(missingScheme.modelsURL)

        let fileURL = ProviderConfiguration(
            provider: .custom,
            modelID: "model",
            apiKey: "test-key",
            customChatCompletionsURL: "file:///tmp/provider.json"
        )
        XCTAssertNil(fileURL.chatCompletionsURL)
        XCTAssertNil(fileURL.modelsURL)

        let inlineCredentialURL = ProviderConfiguration(
            provider: .custom,
            modelID: "model",
            apiKey: "test-key",
            customChatCompletionsURL: "https://secret@example.com/v1"
        )
        XCTAssertNil(inlineCredentialURL.chatCompletionsURL)
        XCTAssertNil(inlineCredentialURL.modelsURL)

        let localhost = ProviderConfiguration(
            provider: .custom,
            modelID: "model",
            apiKey: "test-key",
            customChatCompletionsURL: "http://localhost:11434/v1/"
        )
        XCTAssertEqual(localhost.chatCompletionsURL?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(localhost.modelsURL?.absoluteString, "http://localhost:11434/v1/models")
    }

    func testProviderFailureMessagesAreRedactedAndCapped() {
        let raw = "Authorization: Bearer sk-testsecret1234567890\n" +
            "api_key=another-secret-value\n" +
            String(repeating: "provider html body ", count: 400)

        let message = OpenAIError.providerFailureMessage(rawText: raw, fallback: "fallback")

        XCTAssertLessThanOrEqual(message.count, 1_450)
        XCTAssertTrue(message.contains("NovaForge shortened this provider error"))
        XCTAssertFalse(message.contains("sk-testsecret1234567890"))
        XCTAssertFalse(message.contains("another-secret-value"))
        XCTAssertTrue(message.contains("redacted"))
    }

    func testProviderFailureMessageUsesFallbackForEmptyBodies() {
        XCTAssertEqual(
            OpenAIError.providerFailureMessage(rawText: "  \n\t", fallback: "Unknown provider error"),
            "Unknown provider error"
        )
    }

    func testChatGPTModelCatalogParsesCurrentShapeAndReasoningOrder() throws {
        let data = Data(#"""
        {
          "models": [
            {
              "slug": "gpt-5.5",
              "display_name": "GPT-5.5",
              "supported_reasoning_levels": [
                {"effort":"low"},
                {"effort":"medium"},
                {"effort":"high"},
                {"effort":"xhigh"}
              ]
            },
            {"slug":"gpt-4o"},
            {"slug":"gpt-5.3-codex-spark"},
            {"slug":"codex-auto-review"}
          ]
        }
        """#.utf8)

        let catalog = try ProviderModelCatalogParser.parse(
            data,
            provider: .openAICodex
        )

        XCTAssertEqual(catalog.map(\.id), ["gpt-5.5", "gpt-5.3-codex-spark"])
        XCTAssertEqual(catalog.first?.displayName, "GPT-5.5")
        XCTAssertEqual(
            catalog.first?.supportedReasoningEfforts,
            ["low", "medium", "high", "xhigh"]
        )
    }

    @MainActor
    func testChatGPTFallbackCatalogUsesCurrentFamilyWithoutLegacyProductNames() {
        let store = ProviderModelCatalogStore.shared
        store.clear(provider: .openAICodex)
        defer { store.clear(provider: .openAICodex) }
        let entries = store.entries(for: .openAICodex)
        XCTAssertEqual(
            entries.map(\.id),
            ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex-spark"]
        )
        XCTAssertEqual(entries.first?.displayName, "GPT-5.5")
        XCTAssertEqual(
            entries.first?.supportedReasoningEfforts,
            ["low", "medium", "high", "xhigh"]
        )
        XCTAssertEqual(
            store.displayName(
                for: .openAICodex,
                modelID: "gpt-5.3-codex-spark"
            ),
            "GPT-5.3 Codex Spark"
        )
    }

    func testChatGPTCatalogURLCarriesSemanticClientVersion() throws {
        let configuration = ProviderConfiguration(
            provider: .openAICodex,
            modelID: AIProvider.openAICodex.defaultModel,
            apiKey: "token",
            customChatCompletionsURL: ""
        )
        let components = try XCTUnwrap(configuration.modelsURL).appendingPathComponent("")
        let query = try XCTUnwrap(
            URLComponents(
                url: components,
                resolvingAgainstBaseURL: false
            )
        ).queryItems
        let version = try XCTUnwrap(
            query?.first(where: { $0.name == "client_version" })?.value
        )

        XCTAssertTrue(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil)
        XCTAssertEqual(AIProvider.normalizedChatGPTClientVersion("1.0"), "1.0.0")
        XCTAssertEqual(AIProvider.normalizedChatGPTClientVersion("2.4.7-beta"), "2.4.7")
        XCTAssertEqual(AIProvider.normalizedChatGPTClientVersion("bad"), "1.0.0")
    }

    func testOpenAIModelCatalogParsesDataShapeAndRejectsUnsafeIDs() throws {
        let data = Data(#"""
        {
          "data": [
            {"id":"gpt-5.4"},
            {"id":"gpt-5.4\u0000leak"},
            {"id":"gpt 5 unsafe"},
            {"id":"gpt-5.4"}
          ]
        }
        """#.utf8)

        let catalog = try ProviderModelCatalogParser.parse(data, provider: .openAI)

        XCTAssertEqual(catalog.map(\.id), ["gpt-5.4"])
    }

    private func sseContent(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "data: {\"choices\":[{\"delta\":{\"content\":\"\(escaped)\"}}]}"
    }

    private func sseToolCall(
        index: Int = 0,
        id: String? = nil,
        type: String? = nil,
        name: String? = nil,
        arguments: String? = nil
    ) -> String {
        var function: [String: String] = [:]
        if let name { function["name"] = name }
        if let arguments { function["arguments"] = arguments }

        var toolCall: [String: Any] = ["index": index]
        if let id { toolCall["id"] = id }
        if let type { toolCall["type"] = type }
        if !function.isEmpty { toolCall["function"] = function }

        let root: [String: Any] = [
            "choices": [[
                "delta": [
                    "tool_calls": [toolCall]
                ]
            ]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return "data: " + String(data: data, encoding: .utf8)!
    }
}

private func XCTAssertThrowsAsyncError<T>(
    _ expression: @autoclosure @escaping () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

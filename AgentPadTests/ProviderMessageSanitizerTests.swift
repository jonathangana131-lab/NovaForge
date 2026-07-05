import XCTest

final class ProviderMessageSanitizerTests: XCTestCase {
    func testNormalUserAndAssistantMessagesPass() {
        let transcript = ProviderMessageSanitizer.sanitize(systemPrompt: "system", history: [
            input(.user, "Build a page"),
            input(.assistant, "Done")
        ])

        XCTAssertEqual(transcript.messages.map(\.role), ["system", "user", "assistant"])
        XCTAssertTrue(transcript.droppedMessages.isEmpty)
        XCTAssertTrue(ProviderMessageSanitizer.validate(transcript.messages).isEmpty)
    }

    func testToolMessageWithoutPreviousAssistantToolCallsIsRemoved() {
        let transcript = ProviderMessageSanitizer.sanitize(systemPrompt: "system", history: [
            input(.user, "Create a file"),
            input(.tool, "Wrote index.html", toolCallID: "orphan")
        ])

        XCTAssertEqual(transcript.messages.map(\.role), ["system", "user"])
        XCTAssertEqual(transcript.droppedMessages.count, 1)
        XCTAssertTrue(ProviderMessageSanitizer.validate(transcript.messages).isEmpty)
    }

    func testAssistantToolCallsFollowedByMatchingToolMessagesPasses() {
        let call = toolCall(id: "call_1", name: "write_file")
        let transcript = ProviderMessageSanitizer.sanitize(systemPrompt: "system", history: [
            input(.user, "Create a file"),
            input(.assistant, "", toolCalls: [call]),
            input(.tool, "Wrote index.html", toolCallID: "call_1")
        ])

        XCTAssertEqual(transcript.messages.map(\.role), ["system", "user", "assistant", "tool"])
        XCTAssertEqual(transcript.messages.last?.toolCallID, "call_1")
        XCTAssertTrue(transcript.droppedMessages.isEmpty)
        XCTAssertTrue(ProviderMessageSanitizer.validate(transcript.messages).isEmpty)
    }

    func testAssistantToolCallReasoningSurvivesProviderSanitization() throws {
        let call = toolCall(id: "call_1", name: "make_directory")
        let transcript = ProviderMessageSanitizer.sanitize(systemPrompt: "system", history: [
            input(.user, "Create a folder"),
            input(.assistant, "", toolCalls: [call], reasoningContent: "I should create the requested folder."),
            input(.tool, "Created TaskManager", toolCallID: "call_1")
        ])

        let assistant = try XCTUnwrap(transcript.messages.first { $0.role == "assistant" })
        XCTAssertEqual(assistant.reasoningContent, "I should create the requested folder.")
        XCTAssertEqual(assistant.chatCompletionsMessage.reasoning_content, "I should create the requested folder.")
        XCTAssertTrue(ProviderMessageSanitizer.validate(transcript.messages).isEmpty)
    }

    func testSecondPromptAfterToolRunKeepsProviderPayloadValid() {
        let call = toolCall(id: "call_1", name: "write_file")
        let transcript = ProviderMessageSanitizer.sanitize(systemPrompt: "system", history: [
            input(.user, "Create a file"),
            input(.assistant, "", toolCalls: [call]),
            input(.tool, "Wrote index.html", toolCallID: "call_1"),
            input(.assistant, "Created it."),
            input(.user, "Make it better.")
        ])

        XCTAssertEqual(transcript.messages.map(\.role), ["system", "user", "assistant", "tool", "assistant", "user"])
        XCTAssertTrue(ProviderMessageSanitizer.validate(transcript.messages).isEmpty)
    }

    func testNewChatStartsWithCleanProviderHistory() {
        let transcript = ProviderMessageSanitizer.sanitize(systemPrompt: "system", history: [])

        XCTAssertEqual(transcript.messages.map(\.role), ["system"])
        XCTAssertTrue(transcript.droppedMessages.isEmpty)
        XCTAssertEqual(transcript.roleLog, "system")
    }

    func testLongToolOutputIsCompactedButExchangeStaysValid() {
        let call = toolCall(id: "call_big", name: "read_file")
        let hugeOutput = "START-" + String(repeating: "line of generated output\n", count: 900) + "-END"

        let transcript = ProviderMessageSanitizer.sanitize(systemPrompt: "system", history: [
            input(.user, "Inspect a giant file"),
            input(.assistant, "", toolCalls: [call]),
            input(.tool, hugeOutput, toolCallID: "call_big")
        ])

        XCTAssertEqual(transcript.messages.map(\.role), ["system", "user", "assistant", "tool"])
        let toolContent = transcript.messages.last?.content ?? ""
        XCTAssertLessThan(toolContent.count, hugeOutput.count)
        XCTAssertTrue(toolContent.contains("START-"))
        XCTAssertTrue(toolContent.contains("-END"))
        XCTAssertTrue(toolContent.contains("NovaForge compacted this tool result"))
        XCTAssertTrue(ProviderMessageSanitizer.validate(transcript.messages).isEmpty)
    }

    func testHugeWriteFileArgumentsAreCompactedForProviderHistory() throws {
        let hugeHTML = "<html>" + String(repeating: "<section>Generated game markup</section>", count: 600) + "</html>"
        let argsData = try JSONSerialization.data(withJSONObject: [
            "path": "public/game.html",
            "contents": hugeHTML
        ], options: [.sortedKeys])
        let args = try XCTUnwrap(String(data: argsData, encoding: .utf8))
        let call = APIToolCall(
            id: "call_write",
            type: "function",
            function: APIFunctionCall(name: "write_file", arguments: args)
        )

        let transcript = ProviderMessageSanitizer.sanitize(systemPrompt: "system", history: [
            input(.user, "Write a big web game"),
            input(.assistant, "", toolCalls: [call]),
            input(.tool, "Wrote public/game.html", toolCallID: "call_write")
        ])

        let assistantToolCall = try XCTUnwrap(transcript.messages.first { $0.role == "assistant" }?.toolCalls?.first)
        let compactedArguments = assistantToolCall.function.arguments
        XCTAssertLessThan(compactedArguments.count, args.count)
        let compactedData = try XCTUnwrap(compactedArguments.data(using: .utf8))
        let compactedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: compactedData) as? [String: Any])
        XCTAssertEqual(compactedObject["path"] as? String, "public/game.html")
        let contentPreview = compactedObject["contents"] as? String ?? compactedObject["preview"] as? String ?? ""
        XCTAssertTrue(contentPreview.contains("NovaForge compacted this write_file.contents argument") || compactedObject["__novaforge_compacted_arguments"] != nil)
        XCTAssertTrue(ProviderMessageSanitizer.validate(transcript.messages).isEmpty)
    }

    func testHugeCommandArgumentsAreCompactedInsteadOfPreservedVerbatim() throws {
        let hugeCommand = "python3 - <<'PY'\n" + String(repeating: "print('large generated payload')\n", count: 700) + "PY"
        let argsData = try JSONSerialization.data(withJSONObject: [
            "command": hugeCommand,
            "cwd": "/workspace"
        ], options: [.sortedKeys])
        let args = try XCTUnwrap(String(data: argsData, encoding: .utf8))
        let call = APIToolCall(
            id: "call_command",
            type: "function",
            function: APIFunctionCall(name: "run_command", arguments: args)
        )

        let transcript = ProviderMessageSanitizer.sanitize(systemPrompt: "system", history: [
            input(.user, "Run a generated script"),
            input(.assistant, "", toolCalls: [call]),
            input(.tool, "Command finished", toolCallID: "call_command")
        ])

        let assistantToolCall = try XCTUnwrap(transcript.messages.first { $0.role == "assistant" }?.toolCalls?.first)
        let compactedArguments = assistantToolCall.function.arguments
        XCTAssertLessThan(compactedArguments.count, 4_000)
        XCTAssertLessThan(compactedArguments.count, args.count)
        XCTAssertTrue(compactedArguments.contains("NovaForge compacted this run_command.command argument") || compactedArguments.contains("__novaforge_compacted_arguments"))
        XCTAssertTrue(ProviderMessageSanitizer.validate(transcript.messages).isEmpty)
    }

    func testMultipleToolCallsRemainValidWhenArgumentsAreCompacted() throws {
        let bigPatch = String(repeating: "replacement text ", count: 900)
        let patchArgs = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: [
            "path": "Sources/App.swift",
            "old_string": "old",
            "new_string": bigPatch
        ], options: [.sortedKeys]), encoding: .utf8))
        let readArgs = "{\"path\":\"Sources/App.swift\"}"
        let calls = [
            APIToolCall(id: "call_patch", type: "function", function: APIFunctionCall(name: "patch", arguments: patchArgs)),
            APIToolCall(id: "call_read", type: "function", function: APIFunctionCall(name: "read_file", arguments: readArgs))
        ]

        let transcript = ProviderMessageSanitizer.sanitize(systemPrompt: "system", history: [
            input(.user, "Patch and then inspect a file"),
            input(.assistant, "", toolCalls: calls),
            input(.tool, "Patched Sources/App.swift", toolCallID: "call_patch"),
            input(.tool, "1|import SwiftUI", toolCallID: "call_read")
        ])

        XCTAssertEqual(transcript.messages.map(\.role), ["system", "user", "assistant", "tool", "tool"])
        let assistantCalls = try XCTUnwrap(transcript.messages.first { $0.role == "assistant" }?.toolCalls)
        XCTAssertEqual(assistantCalls.map(\.id), ["call_patch", "call_read"])
        XCTAssertLessThan(assistantCalls[0].function.arguments.count, patchArgs.count)
        XCTAssertEqual(assistantCalls[1].function.arguments, readArgs)
        XCTAssertTrue(ProviderMessageSanitizer.validate(transcript.messages).isEmpty)
    }

    func testLongUserAndAssistantMessagesAreBudgetedForProvider() {
        let longUser = "USER-START " + String(repeating: "describe every generated file ", count: 900) + " USER-END"
        let longAssistant = "ASSISTANT-START " + String(repeating: "implementation detail ", count: 900) + " ASSISTANT-END"

        let transcript = ProviderMessageSanitizer.sanitize(systemPrompt: "system", history: [
            input(.user, longUser),
            input(.assistant, longAssistant)
        ])

        let userContent = transcript.messages.first { $0.role == "user" }?.content ?? ""
        let assistantContent = transcript.messages.first { $0.role == "assistant" }?.content ?? ""
        XCTAssertLessThan(userContent.count, longUser.count)
        XCTAssertLessThan(assistantContent.count, longAssistant.count)
        XCTAssertTrue(userContent.contains("USER-START"))
        XCTAssertTrue(userContent.contains("USER-END"))
        XCTAssertTrue(assistantContent.contains("ASSISTANT-START"))
        XCTAssertTrue(assistantContent.contains("ASSISTANT-END"))
        XCTAssertTrue(ProviderMessageSanitizer.validate(transcript.messages).isEmpty)
    }

    private func input(
        _ role: ChatRole,
        _ content: String,
        toolCallID: String? = nil,
        toolCalls: [APIToolCall] = [],
        reasoningContent: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ProviderMessageInput {
        ProviderMessageInput(
            id: UUID(),
            role: role,
            content: content,
            createdAt: Date().addingTimeInterval(Double(line)),
            toolCallID: toolCallID,
            toolCalls: toolCalls,
            reasoningContent: reasoningContent
        )
    }

    private func toolCall(id: String, name: String) -> APIToolCall {
        APIToolCall(
            id: id,
            type: "function",
            function: APIFunctionCall(name: name, arguments: "{\"path\":\"index.html\",\"contents\":\"hi\"}")
        )
    }
}

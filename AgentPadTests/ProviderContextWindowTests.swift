import XCTest

final class ProviderContextWindowTests: XCTestCase {
    func testPreparedHostedTranscriptUsesOneSharedSystemPromptBoundary() throws {
        let user = message(.user, "Inspect the project", offset: 0)
        let prepared = try ProviderContextWindow.prepareHostedTranscript(
            history: [user],
            customSystemPrompt: nil,
            workspaceSummary: "file: Sources/App.swift"
        )

        XCTAssertEqual(prepared.messages.map(\.role), ["system", "user"])
        XCTAssertTrue(
            prepared.messages[0].content?.contains(
                "Current workspace files:\nfile: Sources/App.swift"
            ) == true
        )
        XCTAssertEqual(prepared.messages[1].content, "Inspect the project")
        XCTAssertTrue(ProviderMessageSanitizer.validate(prepared.messages).isEmpty)
    }

    func testPreparedHostedTranscriptPreservesExactCustomPrompt() throws {
        let prepared = try ProviderContextWindow.prepareHostedTranscript(
            history: [message(.user, "Hello", offset: 0)],
            customSystemPrompt: "  Use this exact custom prompt.  ",
            workspaceSummary: "must not be interpolated"
        )

        XCTAssertEqual(
            prepared.messages.first?.content,
            "  Use this exact custom prompt.  "
        )
        XCTAssertFalse(
            prepared.messages.first?.content?.contains(
                "must not be interpolated"
            ) == true
        )
    }

    func testSelectKeepsLatestUserWithinSmallBudget() {
        let oldUser = message(.user, "old request", offset: 0)
        let oldReply = message(.assistant, String(repeating: "x", count: 2_000), offset: 1)
        let latestUser = message(.user, "current request", offset: 2)

        let selected = ProviderContextWindow.select(
            [oldUser, oldReply, latestUser],
            budget: .init(maximumEstimatedTokens: 80, maximumMessages: 3)
        )

        XCTAssertTrue(selected.contains(where: { $0.id == latestUser.id }))
        XCTAssertFalse(selected.contains(where: { $0.id == oldReply.id }))
        XCTAssertFalse(selected.contains(where: { $0.id == oldUser.id }))
    }

    func testSelectKeepsToolExchangeAtomic() {
        let user = message(.user, "inspect it", offset: 0)
        let call = APIToolCall(
            id: "call-1",
            type: "function",
            function: APIFunctionCall(name: "read_file", arguments: #"{"path":"index.html"}"#)
        )
        let assistant = ProviderMessageInput(
            id: UUID(),
            role: .assistant,
            content: "",
            createdAt: Date(timeIntervalSince1970: 1),
            toolCallID: nil,
            toolCalls: [call]
        )
        let tool = ProviderMessageInput(
            id: UUID(),
            role: .tool,
            content: "file contents",
            createdAt: Date(timeIntervalSince1970: 2),
            toolCallID: call.id,
            toolCalls: []
        )

        let selected = ProviderContextWindow.select(
            [user, assistant, tool],
            budget: .init(maximumEstimatedTokens: 200, maximumMessages: 3)
        )

        XCTAssertEqual(selected.map(\.id), [user.id, assistant.id, tool.id])
    }

    func testSelectHonorsMessageCapAndOrdering() {
        let messages = (0..<8).map { message(.assistant, "reply \($0)", offset: TimeInterval($0)) }

        let selected = ProviderContextWindow.select(
            messages,
            budget: .init(maximumEstimatedTokens: 2_000, maximumMessages: 3)
        )

        XCTAssertEqual(selected.count, 3)
        XCTAssertEqual(selected.map(\.content), ["reply 5", "reply 6", "reply 7"])
    }

    func testSelectDropsOrphanToolResults() {
        let user = message(.user, "current request", offset: 0)
        let orphan = ProviderMessageInput(
            id: UUID(),
            role: .tool,
            content: "result without its tool-call envelope",
            createdAt: Date(timeIntervalSince1970: 1),
            toolCallID: "missing-call",
            toolCalls: []
        )

        let selected = ProviderContextWindow.select(
            [user, orphan],
            budget: .init(maximumEstimatedTokens: 2_000, maximumMessages: 4)
        )

        XCTAssertEqual(selected.map(\.id), [user.id])
    }

    func testSelectDropsIncompleteToolCallEnvelope() {
        let user = message(.user, "current request", offset: 0)
        let firstCall = APIToolCall(
            id: "call-1",
            type: "function",
            function: APIFunctionCall(name: "read_file", arguments: #"{"path":"a.txt"}"#)
        )
        let missingCall = APIToolCall(
            id: "call-2",
            type: "function",
            function: APIFunctionCall(name: "read_file", arguments: #"{"path":"b.txt"}"#)
        )
        let incompleteAssistant = ProviderMessageInput(
            id: UUID(),
            role: .assistant,
            content: "",
            createdAt: Date(timeIntervalSince1970: 1),
            toolCallID: nil,
            toolCalls: [firstCall, missingCall]
        )
        let onlyResult = ProviderMessageInput(
            id: UUID(),
            role: .tool,
            content: "a",
            createdAt: Date(timeIntervalSince1970: 2),
            toolCallID: firstCall.id,
            toolCalls: []
        )

        let selected = ProviderContextWindow.select(
            [user, incompleteAssistant, onlyResult],
            budget: .init(maximumEstimatedTokens: 2_000, maximumMessages: 8)
        )

        XCTAssertEqual(selected.map(\.id), [user.id])
    }

    func testEstimateUsesProviderCompactionCaps() {
        let huge = message(.tool, String(repeating: "z", count: 100_000), offset: 0)
        XCTAssertLessThan(ProviderContextWindow.estimatedTokenCount([huge]), 2_000)
    }

    func testOversizedLatestUserIsCompactedOnlyInProviderCopy() {
        let originalContent = String(repeating: "head-detail ", count: 600) + "TAIL-PROOF"
        let latestUser = message(.user, originalContent, offset: 0)
        let budget = ProviderContextWindow.Budget(maximumEstimatedTokens: 80, maximumMessages: 4)

        let selected = ProviderContextWindow.select([latestUser], budget: budget)

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected[0].id, latestUser.id)
        XCTAssertLessThan(selected[0].content.count, originalContent.count)
        XCTAssertTrue(selected[0].content.hasPrefix("head-detail"))
        XCTAssertTrue(selected[0].content.hasSuffix("TAIL-PROOF"))
        XCTAssertLessThanOrEqual(ProviderContextWindow.estimatedTokenCount(selected), budget.maximumEstimatedTokens)
        XCTAssertEqual(latestUser.content, originalContent, "Context compaction must never rewrite the durable chat message.")
    }

    private func message(_ role: ChatRole, _ content: String, offset: TimeInterval) -> ProviderMessageInput {
        ProviderMessageInput(
            id: UUID(),
            role: role,
            content: content,
            createdAt: Date(timeIntervalSince1970: offset),
            toolCallID: nil,
            toolCalls: []
        )
    }
}

import AgentDomain
@testable import AgentEngine
import AgentProviders
import Foundation
import XCTest

final class AgentForgeCompactContextPreparerTests: XCTestCase {
    func testPreparedTurnCompactorRemovesOnlyUniquelyMatchedHistoricalPrefix() throws {
        let first = message(
            id: id(101),
            role: .user,
            text: String(repeating: "requirements ", count: 80),
            time: 1
        )
        let second = message(
            id: id(102),
            role: .assistant,
            text: String(repeating: "implementation ", count: 80),
            time: 2
        )
        let checkpoint = checkpoint(
            id: id(103),
            sourceIDs: [first.id, second.id],
            summary: "Accepted requirements and implementation direction.",
            time: 3
        )
        let current = message(
            id: id(104),
            role: .user,
            text: "Continue with the current request.",
            time: 4
        )
        let system = ProviderMessage(role: .system, content: [.text("system")])
        let firstProvider = ProviderMessage(
            role: .user,
            content: [.text(text(of: first))]
        )
        let secondProvider = ProviderMessage(
            role: .assistant,
            content: [.text(text(of: second))]
        )
        let checkpointProvider = ProviderMessage(
            role: .user,
            content: [.text("canonical checkpoint envelope")]
        )
        let currentProvider = ProviderMessage(
            role: .user,
            content: [.text(text(of: current))]
        )
        let prepared = try preparedTurn(
            messages: [
                system,
                firstProvider,
                secondProvider,
                checkpointProvider,
                currentProvider,
            ],
            itemIDs: [first.id, second.id, checkpoint.id, current.id]
        )

        let compacted = try AgentForgeCompactPreparedTurnCompactor.compact(
            prepared: prepared,
            modelItems: [first, second, checkpoint, current],
            projectID: "preview-project",
            missionID: "preview-run",
            protectedTailItemCount: 1,
            minimumSavingsBytes: 256
        )

        XCTAssertEqual(
            compacted.request.messages,
            [system, checkpointProvider, currentProvider]
        )
        XCTAssertEqual(compacted.itemIDs, [checkpoint.id, current.id])
        XCTAssertEqual(compacted.estimatedTokens, prepared.estimatedTokens)
        XCTAssertNotEqual(compacted.contextDigest, prepared.contextDigest)
        XCTAssertEqual(compacted.request.tools, prepared.request.tools)
        XCTAssertEqual(compacted.request.options, prepared.request.options)
        XCTAssertEqual(compacted.request.metadata, prepared.request.metadata)
    }

    func testAmbiguousProviderMessageMappingFailsClosed() throws {
        let first = message(
            id: id(111),
            role: .user,
            text: String(repeating: "same ", count: 100),
            time: 1
        )
        let checkpoint = checkpoint(
            id: id(112),
            sourceIDs: [first.id],
            summary: "summary",
            time: 2
        )
        let current = message(id: id(113), role: .user, text: "continue", time: 3)
        let repeated = ProviderMessage(
            role: .user,
            content: [.text(text(of: first))]
        )
        let prepared = try preparedTurn(
            messages: [
                repeated,
                ProviderMessage(role: .user, content: [.text("checkpoint")]),
                repeated,
                ProviderMessage(role: .user, content: [.text("continue")]),
            ],
            itemIDs: [first.id, checkpoint.id, current.id]
        )

        let compacted = try AgentForgeCompactPreparedTurnCompactor.compact(
            prepared: prepared,
            modelItems: [first, checkpoint, current],
            projectID: "preview-project",
            missionID: "preview-run",
            protectedTailItemCount: 1,
            minimumSavingsBytes: 1
        )

        XCTAssertEqual(compacted.request, prepared.request)
        XCTAssertEqual(compacted.itemIDs, prepared.itemIDs)
        XCTAssertEqual(compacted.contextDigest, prepared.contextDigest)
    }

    func testUnsafeTranscriptLeavesPreparedTurnByteForByteSemanticsUntouched() throws {
        let first = message(
            id: id(121),
            role: .user,
            text: String(repeating: "history ", count: 100),
            time: 1
        )
        let reasoning = ModelItem(
            id: id(122),
            createdAt: AgentInstant(rawValue: 2),
            payload: .reasoningSummary(ReasoningSummary(
                text: "reasoning",
                replay: .chatCompletions(ChatCompletionsReasoningReplay(
                    content: "provider-owned"
                ))
            ))
        )
        let checkpoint = checkpoint(
            id: id(123),
            sourceIDs: [first.id, reasoning.id],
            summary: "summary",
            time: 3
        )
        let current = message(id: id(124), role: .user, text: "continue", time: 4)
        let providerMessages = [
            ProviderMessage(role: .user, content: [.text(text(of: first))]),
            ProviderMessage(
                role: .assistant,
                content: [.text("reasoning")],
                reasoningReplay: .chatCompletions(ChatCompletionsReasoningReplay(
                    content: "provider-owned"
                ))
            ),
            ProviderMessage(role: .user, content: [.text("checkpoint")]),
            ProviderMessage(role: .user, content: [.text("continue")]),
        ]
        let prepared = try preparedTurn(
            messages: providerMessages,
            itemIDs: [first.id, reasoning.id, checkpoint.id, current.id]
        )

        let compacted = try AgentForgeCompactPreparedTurnCompactor.compact(
            prepared: prepared,
            modelItems: [first, reasoning, checkpoint, current],
            projectID: "preview-project",
            missionID: "preview-run",
            protectedTailItemCount: 1,
            minimumSavingsBytes: 0
        )

        XCTAssertEqual(compacted.request, prepared.request)
        XCTAssertEqual(compacted.itemIDs, prepared.itemIDs)
        XCTAssertEqual(compacted.contextDigest, prepared.contextDigest)
    }

    private func preparedTurn(
        messages: [ProviderMessage],
        itemIDs: [ModelItemID]
    ) throws -> AgentPreparedProviderTurn {
        AgentPreparedProviderTurn(
            request: CanonicalProviderRequest(
                requestID: "forge-compact-test",
                model: ProviderModelID(rawValue: "test-model"),
                messages: messages,
                tools: [],
                options: ProviderGenerationOptions(maximumOutputTokens: 512),
                metadata: .object(["test": .bool(true)])
            ),
            preferredAdapterIDs: [ProviderAdapterID(rawValue: "test-adapter")],
            itemIDs: itemIDs,
            estimatedTokens: 4_096,
            contextDigest: try AgentCanonicalSHA256Digest(
                "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            )
        )
    }

    private func message(
        id: ModelItemID,
        role: ModelRole,
        text: String,
        time: Int64
    ) -> ModelItem {
        ModelItem(
            id: id,
            createdAt: AgentInstant(rawValue: time),
            payload: .message(ModelMessage(role: role, content: [.text(text)]))
        )
    }

    private func checkpoint(
        id: ModelItemID,
        sourceIDs: [ModelItemID],
        summary: String,
        time: Int64
    ) -> ModelItem {
        ModelItem(
            id: id,
            createdAt: AgentInstant(rawValue: time),
            payload: .contextCheckpoint(ContextCheckpointReference(
                checkpointID: ContextCheckpointID(rawValue: uuid(2_000 + Int(time))),
                schemaVersion: .current,
                summary: summary,
                sourceItemIDs: sourceIDs,
                sourceDigest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            ))
        )
    }

    private func text(of item: ModelItem) -> String {
        guard case let .message(message) = item.payload,
              case let .text(value) = message.content.first
        else { return "" }
        return value
    }

    private func id(_ value: Int) -> ModelItemID {
        ModelItemID(rawValue: uuid(value))
    }

    private func uuid(_ value: Int) -> UUID {
        let suffix = String(format: "%012x", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}

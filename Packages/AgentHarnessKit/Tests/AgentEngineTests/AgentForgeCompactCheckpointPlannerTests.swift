import AgentDomain
@testable import AgentEngine
import Foundation
import XCTest

final class AgentForgeCompactCheckpointPlannerTests: XCTestCase {
    func testEligibleCheckpointCompactsOnlyHistoricalPlainTextPrefix() {
        let first = message(
            id: id(1),
            role: .user,
            text: String(repeating: "requirements ", count: 80),
            time: 1
        )
        let second = message(
            id: id(2),
            role: .assistant,
            text: String(repeating: "implementation notes ", count: 80),
            time: 2
        )
        let checkpoint = checkpoint(
            id: id(3),
            sourceIDs: [first.id, second.id],
            summary: "Accepted requirements and implementation direction are preserved.",
            time: 3
        )
        let current = message(
            id: id(4),
            role: .user,
            text: "Now continue the current turn.",
            time: 4
        )

        let plan = AgentForgeCompactCheckpointPlanner.plan(
            modelItems: [first, second, checkpoint, current],
            projectID: "preview-project",
            missionID: "preview-run",
            protectedTailItemCount: 1,
            minimumSavingsBytes: 256
        )

        XCTAssertTrue(plan.didCompact)
        XCTAssertEqual(plan.checkpointItemID, checkpoint.id)
        XCTAssertEqual(plan.compactedSourceItemIDs, [first.id, second.id])
        XCTAssertGreaterThan(plan.estimatedSavedUTF8Bytes, 256)
        XCTAssertGreaterThan(plan.capsuleRenderedUTF8Bytes, 0)
    }

    func testReasoningReplayInCoveredPrefixFailsClosed() {
        let first = message(
            id: id(11),
            role: .user,
            text: String(repeating: "history ", count: 100),
            time: 1
        )
        let reasoning = ModelItem(
            id: id(12),
            createdAt: AgentInstant(rawValue: 2),
            payload: .reasoningSummary(ReasoningSummary(
                text: "provider reasoning",
                replay: .chatCompletions(ChatCompletionsReasoningReplay(
                    content: "opaque-provider-state"
                ))
            ))
        )
        let checkpoint = checkpoint(
            id: id(13),
            sourceIDs: [first.id, reasoning.id],
            summary: "summary",
            time: 3
        )
        let current = message(
            id: id(14),
            role: .user,
            text: "continue",
            time: 4
        )

        let plan = AgentForgeCompactCheckpointPlanner.plan(
            modelItems: [first, reasoning, checkpoint, current],
            projectID: "preview-project",
            missionID: "preview-run",
            protectedTailItemCount: 1,
            minimumSavingsBytes: 0
        )

        XCTAssertFalse(plan.didCompact)
        XCTAssertEqual(plan, .none)
    }

    func testCheckpointInsideProtectedTailFailsClosed() {
        let first = message(
            id: id(21),
            role: .user,
            text: String(repeating: "old text ", count: 100),
            time: 1
        )
        let second = message(
            id: id(22),
            role: .assistant,
            text: String(repeating: "old answer ", count: 100),
            time: 2
        )
        let checkpoint = checkpoint(
            id: id(23),
            sourceIDs: [first.id, second.id],
            summary: "summary",
            time: 3
        )
        let recent = message(id: id(24), role: .user, text: "recent", time: 4)
        let current = message(id: id(25), role: .assistant, text: "current", time: 5)

        let plan = AgentForgeCompactCheckpointPlanner.plan(
            modelItems: [first, second, checkpoint, recent, current],
            projectID: "preview-project",
            missionID: "preview-run",
            protectedTailItemCount: 4,
            minimumSavingsBytes: 0
        )

        XCTAssertEqual(plan, .none)
    }

    func testCheckpointMustCoverExactHistoricalPrefix() {
        let first = message(
            id: id(31),
            role: .user,
            text: String(repeating: "first ", count: 100),
            time: 1
        )
        let second = message(
            id: id(32),
            role: .assistant,
            text: String(repeating: "second ", count: 100),
            time: 2
        )
        let checkpoint = checkpoint(
            id: id(33),
            sourceIDs: [first.id],
            summary: "partial summary",
            time: 3
        )
        let current = message(id: id(34), role: .user, text: "continue", time: 4)

        let plan = AgentForgeCompactCheckpointPlanner.plan(
            modelItems: [first, second, checkpoint, current],
            projectID: "preview-project",
            missionID: "preview-run",
            protectedTailItemCount: 1,
            minimumSavingsBytes: 0
        )

        XCTAssertEqual(plan, .none)
    }

    func testSavingsThresholdAndForgeCompactAuthorityAreFailClosed() {
        let first = message(id: id(41), role: .user, text: "short", time: 1)
        let checkpoint = checkpoint(
            id: id(42),
            sourceIDs: [first.id],
            summary: "summary that is not materially smaller",
            time: 2
        )
        let current = message(id: id(43), role: .user, text: "continue", time: 3)

        XCTAssertEqual(
            AgentForgeCompactCheckpointPlanner.plan(
                modelItems: [first, checkpoint, current],
                projectID: "preview-project",
                missionID: "preview-run",
                protectedTailItemCount: 1,
                minimumSavingsBytes: 1
            ),
            .none
        )

        let long = message(
            id: id(44),
            role: .user,
            text: String(repeating: "long history ", count: 100),
            time: 1
        )
        let validSizeCheckpoint = checkpoint(
            id: id(45),
            sourceIDs: [long.id],
            summary: "small summary",
            time: 2
        )
        XCTAssertEqual(
            AgentForgeCompactCheckpointPlanner.plan(
                modelItems: [long, validSizeCheckpoint, current],
                projectID: "",
                missionID: "preview-run",
                protectedTailItemCount: 1,
                minimumSavingsBytes: 1
            ),
            .none
        )
    }

    func testPathologicalSavingsThresholdDoesNotOverflow() {
        let first = message(
            id: id(51),
            role: .user,
            text: String(repeating: "history ", count: 100),
            time: 1
        )
        let checkpoint = checkpoint(
            id: id(52),
            sourceIDs: [first.id],
            summary: "summary",
            time: 2
        )
        let current = message(id: id(53), role: .user, text: "continue", time: 3)

        XCTAssertEqual(
            AgentForgeCompactCheckpointPlanner.plan(
                modelItems: [first, checkpoint, current],
                projectID: "preview-project",
                missionID: "preview-run",
                protectedTailItemCount: 1,
                minimumSavingsBytes: Int.max
            ),
            .none
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
                checkpointID: ContextCheckpointID(rawValue: uuid(900 + Int(time))),
                schemaVersion: .current,
                summary: summary,
                sourceItemIDs: sourceIDs,
                sourceDigest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            ))
        )
    }

    private func id(_ value: Int) -> ModelItemID {
        ModelItemID(rawValue: uuid(value))
    }

    private func uuid(_ value: Int) -> UUID {
        let suffix = String(format: "%012x", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}

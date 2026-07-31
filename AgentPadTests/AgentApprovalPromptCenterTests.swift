import AgentDomain
import AgentPolicy
import AgentTools
import Foundation
import XCTest
@testable import NovaForge

@MainActor
final class AgentApprovalPromptCenterTests: XCTestCase {
    func testConcurrentRequestsArePresentedAndResolvedInFIFOOrder() async throws {
        let center = AgentApprovalPromptCenter()
        let first = item(1)
        let second = item(2)
        let third = item(3)

        let firstTask = decisionTask(center, first)
        try await waitUntil { center.pendingItem?.requestID == first.requestID }
        let secondTask = decisionTask(center, second)
        try await waitUntil { center.queuedRequestCount == 1 }
        let thirdTask = decisionTask(center, third)
        try await waitUntil { center.queuedRequestCount == 2 }

        XCTAssertEqual(center.pendingItem, first)
        XCTAssertEqual(center.approve(requestID: first.requestID), .accepted)
        let firstDecision = try await firstTask.value
        XCTAssertEqual(firstDecision, .approved)
        XCTAssertEqual(center.pendingItem, second)

        XCTAssertEqual(center.reject(requestID: second.requestID), .accepted)
        let secondDecision = try await secondTask.value
        XCTAssertEqual(secondDecision, .rejected)
        XCTAssertEqual(center.pendingItem, third)

        XCTAssertEqual(center.approve(requestID: third.requestID), .accepted)
        let thirdDecision = try await thirdTask.value
        XCTAssertEqual(thirdDecision, .approved)
        XCTAssertNil(center.pendingItem)
        XCTAssertEqual(center.queuedRequestCount, 0)
    }

    func testMismatchedAndStaleDecisionsCannotResolveAnotherRequest() async throws {
        let center = AgentApprovalPromptCenter()
        let first = item(10)
        let second = item(11)
        let firstTask = decisionTask(center, first)
        try await waitUntil { center.pendingItem?.requestID == first.requestID }
        let secondTask = decisionTask(center, second)
        try await waitUntil { center.queuedRequestCount == 1 }

        XCTAssertEqual(
            center.approve(requestID: second.requestID),
            .requestIDMismatch(expected: first.requestID)
        )
        XCTAssertEqual(center.pendingItem, first)
        XCTAssertEqual(center.queuedRequestCount, 1)

        XCTAssertEqual(center.approve(requestID: first.requestID), .accepted)
        let firstDecision = try await firstTask.value
        XCTAssertEqual(firstDecision, .approved)
        XCTAssertEqual(center.pendingItem, second)

        XCTAssertEqual(
            center.reject(requestID: first.requestID),
            .requestIDMismatch(expected: second.requestID)
        )
        XCTAssertEqual(center.pendingItem, second)
        XCTAssertEqual(center.reject(requestID: second.requestID), .accepted)
        let secondDecision = try await secondTask.value
        XCTAssertEqual(secondDecision, .rejected)
        XCTAssertEqual(
            center.approve(requestID: second.requestID),
            .noPendingRequest
        )
    }

    func testDuplicateRequestFailsClosedWithoutReplacingOriginal() async throws {
        let center = AgentApprovalPromptCenter()
        let original = item(20)
        let firstTask = decisionTask(center, original)
        try await waitUntil {
            center.pendingItem?.requestID == original.requestID
        }
        let duplicateTask = decisionTask(center, original)

        do {
            _ = try await duplicateTask.value
            XCTFail("Duplicate durable request identity must fail closed")
        } catch let error as AgentApprovalPromptCenterError {
            XCTAssertEqual(error, .duplicateRequestID(original.requestID))
        } catch {
            XCTFail("Unexpected duplicate error: \(type(of: error))")
        }

        XCTAssertEqual(center.pendingItem, original)
        XCTAssertEqual(center.queuedRequestCount, 0)
        XCTAssertEqual(center.reject(requestID: original.requestID), .accepted)
        let firstDecision = try await firstTask.value
        XCTAssertEqual(firstDecision, .rejected)
    }

    func testCancellingFrontTaskAdvancesFIFOAndNeverResolvesSuccess() async throws {
        let center = AgentApprovalPromptCenter()
        let first = item(30)
        let second = item(31)
        let firstTask = decisionTask(center, first)
        try await waitUntil { center.pendingItem?.requestID == first.requestID }
        let secondTask = decisionTask(center, second)
        try await waitUntil { center.queuedRequestCount == 1 }

        firstTask.cancel()
        try await waitUntil {
            center.pendingItem?.requestID == second.requestID
                && center.queuedRequestCount == 0
        }
        await assertCancelled(firstTask)

        XCTAssertEqual(center.approve(requestID: second.requestID), .accepted)
        let secondDecision = try await secondTask.value
        XCTAssertEqual(secondDecision, .approved)
    }

    func testCancellingQueuedTaskDoesNotDisturbVisibleRequest() async throws {
        let center = AgentApprovalPromptCenter()
        let first = item(40)
        let second = item(41)
        let third = item(42)
        let firstTask = decisionTask(center, first)
        try await waitUntil { center.pendingItem?.requestID == first.requestID }
        let secondTask = decisionTask(center, second)
        try await waitUntil { center.queuedRequestCount == 1 }
        let thirdTask = decisionTask(center, third)
        try await waitUntil { center.queuedRequestCount == 2 }

        secondTask.cancel()
        try await waitUntil { center.queuedRequestCount == 1 }
        await assertCancelled(secondTask)
        XCTAssertEqual(center.pendingItem, first)

        XCTAssertEqual(center.approve(requestID: first.requestID), .accepted)
        let firstDecision = try await firstTask.value
        XCTAssertEqual(firstDecision, .approved)
        XCTAssertEqual(center.pendingItem, third)
        XCTAssertEqual(center.reject(requestID: third.requestID), .accepted)
        let thirdDecision = try await thirdTask.value
        XCTAssertEqual(thirdDecision, .rejected)
    }

    func testExactCancellationRejectsMismatchAndAdvancesOnMatch() async throws {
        let center = AgentApprovalPromptCenter()
        let first = item(50)
        let second = item(51)
        let firstTask = decisionTask(center, first)
        try await waitUntil { center.pendingItem?.requestID == first.requestID }
        let secondTask = decisionTask(center, second)
        try await waitUntil { center.queuedRequestCount == 1 }

        XCTAssertEqual(
            center.cancelPending(requestID: second.requestID),
            .requestIDMismatch(expected: first.requestID)
        )
        XCTAssertEqual(center.pendingItem, first)
        XCTAssertEqual(
            center.cancelPending(requestID: first.requestID),
            .cancelled
        )
        await assertCancelled(firstTask)
        XCTAssertEqual(center.pendingItem, second)

        XCTAssertEqual(center.approve(requestID: second.requestID), .accepted)
        let secondDecision = try await secondTask.value
        XCTAssertEqual(secondDecision, .approved)
        XCTAssertEqual(
            center.cancelPending(requestID: second.requestID),
            .noPendingRequest
        )
    }

    func testCancelAllResumesEveryContinuationExactlyOnce() async throws {
        let center = AgentApprovalPromptCenter()
        let tasks = (60 ... 63).map { index in
            decisionTask(center, item(index))
        }
        try await waitUntil {
            center.pendingItem != nil && center.queuedRequestCount == 3
        }

        XCTAssertEqual(center.cancelAllPending(), 4)
        XCTAssertEqual(center.cancelAllPending(), 0)
        XCTAssertNil(center.pendingItem)
        XCTAssertEqual(center.queuedRequestCount, 0)
        for task in tasks {
            await assertCancelled(task)
        }
    }

    func testOperationProjectionNeverRetainsFileReplacementSeedOrCommandContent() {
        let secret = "credential=never-retain-this"
        let operations: [AgentApprovalPromptCenter.PendingItem.OperationPreview] = [
            .init(.writeFile(WriteFileArguments(
                path: "Sources/App.swift",
                contents: secret
            ))),
            .init(.replaceText(ReplaceTextArguments(
                path: "Sources/App.swift",
                old: secret,
                new: "another-\(secret)",
                replaceAll: true
            ))),
            .init(.runCommand(RunCommandArguments(
                command: "write_file Sources/App.swift \(secret)"
            ))),
            .init(.seedWorkspace(SeedWorkspaceMutationArguments(entries: [
                SeedWorkspaceEntry(
                    path: "Sources/Seed.swift",
                    contents: secret
                ),
            ]))),
        ]

        for operation in operations {
            let reflected = String(reflecting: operation)
            XCTAssertFalse(reflected.contains(secret))
            XCTAssertFalse(reflected.contains("another-"))
            XCTAssertFalse(reflected.contains("write_file"))
        }
        XCTAssertEqual(
            operations[0],
            .writeFile(
                path: "Sources/App.swift",
                contentUTF8ByteCount: secret.utf8.count
            )
        )
        XCTAssertEqual(
            operations[2],
            .runCommand(
                commandUTF8ByteCount:
                    "write_file Sources/App.swift \(secret)".utf8.count
            )
        )
    }

    func testPathsAndLabelsAreBoundedAndStripControlAndFormatScalars() throws {
        let unsafePath = "Sources/\nSecret\u{202E}.swift"
            + String(repeating: "x", count: 800)
        let operation = AgentApprovalPromptCenter.PendingItem.OperationPreview(
            .deletePath(PathArguments(path: unsafePath))
        )
        guard case let .deletePath(path) = operation else {
            return XCTFail("Expected typed delete preview")
        }

        XCTAssertFalse(path.contains("\n"))
        XCTAssertFalse(path.contains("\u{202E}"))
        XCTAssertTrue(path.contains("\u{FFFD}"))
        XCTAssertLessThanOrEqual(path.utf8.count, 512)
        XCTAssertTrue(path.hasSuffix("\u{2026}"))

        let preview = AgentApprovalPromptCenter.PendingItem(
            requestID: requestID(70),
            runID: runID(70),
            callID: callID(70),
            workspaceID: workspaceID(70),
            origin: .files,
            toolTitle: "\n",
            toolName: "\u{202E}unsafe",
            toolVersion: String(repeating: "v", count: 200),
            effectClass: .scopedReversibleWrite,
            operation: operation,
            previewSHA256: try digest(70),
            bindingSHA256: try digest(71),
            issuedAt: AgentInstant(rawValue: 1),
            expiresAt: AgentInstant(rawValue: 2)
        )
        XCTAssertEqual(preview.toolTitle, "\u{FFFD}")
        XCTAssertFalse(preview.toolName.contains("\u{202E}"))
        XCTAssertLessThanOrEqual(preview.toolVersion.utf8.count, 80)
    }

    private func decisionTask(
        _ center: AgentApprovalPromptCenter,
        _ item: AgentApprovalPromptCenter.PendingItem
    ) -> Task<ApprovalDecision, Error> {
        Task { @MainActor in
            try await center.requestDecision(forSanitizedItem: item)
        }
    }

    private func assertCancelled(
        _ task: Task<ApprovalDecision, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation", file: file, line: line)
        } catch is CancellationError {
            return
        } catch {
            XCTFail(
                "Unexpected cancellation error: \(type(of: error))",
                file: file,
                line: line
            )
        }
    }

    private func waitUntil(
        _ predicate: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0 ..< 2_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for broker state", file: file, line: line)
        throw TestFailure.timedOut
    }

    private func item(_ seed: Int) -> AgentApprovalPromptCenter.PendingItem {
        AgentApprovalPromptCenter.PendingItem(
            requestID: requestID(seed),
            runID: runID(seed),
            callID: callID(seed),
            workspaceID: workspaceID(seed),
            origin: .agentV2,
            toolTitle: "Write file",
            toolName: "write_file",
            toolVersion: "1",
            effectClass: .scopedReversibleWrite,
            operation: .writeFile(
                path: "Sources/File\(seed).swift",
                contentUTF8ByteCount: seed
            ),
            previewSHA256: try! digest(seed),
            bindingSHA256: try! digest(seed + 100),
            issuedAt: AgentInstant(rawValue: Int64(seed)),
            expiresAt: AgentInstant(rawValue: Int64(seed + 1_000))
        )
    }

    private func requestID(_ seed: Int) -> ApprovalRequestID {
        ApprovalRequestID(rawValue: uuid(seed))
    }

    private func runID(_ seed: Int) -> RunID {
        RunID(rawValue: uuid(seed + 1_000))
    }

    private func callID(_ seed: Int) -> ToolCallID {
        ToolCallID(rawValue: uuid(seed + 2_000))
    }

    private func workspaceID(_ seed: Int) -> WorkspaceID {
        WorkspaceID(rawValue: uuid(seed + 3_000))
    }

    private func uuid(_ seed: Int) -> UUID {
        let tail = String(format: "%012x", seed)
        return UUID(uuidString: "00000000-0000-4000-8000-\(tail)")!
    }

    private func digest(_ seed: Int) throws -> SHA256Digest {
        let hexadecimal = String(format: "%064x", seed)
        return try SHA256Digest("sha256:\(hexadecimal)")
    }

    private enum TestFailure: Error {
        case timedOut
    }
}

import AgentDomain
@testable import AgentPolicy
import Foundation
import XCTest

final class WorkspaceMutationFIFOCoordinatorTests: XCTestCase {
    func testStrictFIFOOrderWithinOneWorkspace() async throws {
        let fifo = WorkspaceMutationFIFOCoordinator()
        let workspace = WorkspaceID()
        let firstLease = try await fifo.acquire(workspaceID: workspace)
        let recorder = LockedStringRecorder()

        let firstWaiter = Task {
            let lease = try await fifo.acquire(workspaceID: workspace)
            recorder.append("first-waiter")
            try await fifo.release(lease)
        }
        try await waitForWaitingCount(1, workspace: workspace, fifo: fifo)
        let secondWaiter = Task {
            let lease = try await fifo.acquire(workspaceID: workspace)
            recorder.append("second-waiter")
            try await fifo.release(lease)
        }
        try await waitForWaitingCount(2, workspace: workspace, fifo: fifo)

        try await fifo.release(firstLease)
        try await firstWaiter.value
        try await secondWaiter.value

        XCTAssertEqual(
            recorder.values,
            ["first-waiter", "second-waiter"]
        )
        let status = await fifo.status(workspaceID: workspace)
        XCTAssertFalse(status.isActive)
        XCTAssertEqual(status.waitingCount, 0)
    }

    func testCancelledMiddleWaiterIsRemovedWithoutReordering() async throws {
        let fifo = WorkspaceMutationFIFOCoordinator()
        let workspace = WorkspaceID()
        let active = try await fifo.acquire(workspaceID: workspace)
        let recorder = LockedStringRecorder()

        let head = Task {
            let lease = try await fifo.acquire(workspaceID: workspace)
            recorder.append("head")
            try await fifo.release(lease)
        }
        try await waitForWaitingCount(1, workspace: workspace, fifo: fifo)
        let middle = Task {
            do {
                let lease = try await fifo.acquire(workspaceID: workspace)
                recorder.append("middle-ran")
                try await fifo.release(lease)
            } catch is CancellationError {
                recorder.append("middle-cancelled")
            }
        }
        try await waitForWaitingCount(2, workspace: workspace, fifo: fifo)
        let tail = Task {
            let lease = try await fifo.acquire(workspaceID: workspace)
            recorder.append("tail")
            try await fifo.release(lease)
        }
        try await waitForWaitingCount(3, workspace: workspace, fifo: fifo)

        middle.cancel()
        try await waitForWaitingCount(2, workspace: workspace, fifo: fifo)
        try await fifo.release(active)
        try await head.value
        try await middle.value
        try await tail.value

        XCTAssertEqual(
            recorder.values.filter { $0 != "middle-cancelled" },
            ["head", "tail"]
        )
        XCTAssertFalse(recorder.values.contains("middle-ran"))
    }

    func testCancelledHeadWaiterAdvancesToNextWaiter() async throws {
        let fifo = WorkspaceMutationFIFOCoordinator()
        let workspace = WorkspaceID()
        let active = try await fifo.acquire(workspaceID: workspace)
        let recorder = LockedStringRecorder()

        let cancelledHead = Task {
            do {
                let lease = try await fifo.acquire(workspaceID: workspace)
                recorder.append("cancelled-head-ran")
                try await fifo.release(lease)
            } catch is CancellationError {
                recorder.append("head-cancelled")
            }
        }
        try await waitForWaitingCount(1, workspace: workspace, fifo: fifo)
        let next = Task {
            let lease = try await fifo.acquire(workspaceID: workspace)
            recorder.append("next")
            try await fifo.release(lease)
        }
        try await waitForWaitingCount(2, workspace: workspace, fifo: fifo)

        cancelledHead.cancel()
        try await waitForWaitingCount(1, workspace: workspace, fifo: fifo)
        try await fifo.release(active)
        try await cancelledHead.value
        try await next.value

        XCTAssertFalse(recorder.values.contains("cancelled-head-ran"))
        XCTAssertTrue(recorder.values.contains("next"))
    }

    func testIndependentWorkspacesHaveNoHeadOfLineBlocking() async throws {
        let fifo = WorkspaceMutationFIFOCoordinator()
        let firstWorkspace = WorkspaceID()
        let secondWorkspace = WorkspaceID()
        let firstLease = try await fifo.acquire(workspaceID: firstWorkspace)

        let secondLease = try await fifo.acquire(workspaceID: secondWorkspace)
        let firstStatus = await fifo.status(workspaceID: firstWorkspace)
        let secondStatus = await fifo.status(workspaceID: secondWorkspace)
        XCTAssertTrue(firstStatus.isActive)
        XCTAssertTrue(secondStatus.isActive)

        try await fifo.release(secondLease)
        try await fifo.release(firstLease)
    }

    private func waitForWaitingCount(
        _ expected: Int,
        workspace: WorkspaceID,
        fifo: WorkspaceMutationFIFOCoordinator
    ) async throws {
        for _ in 0..<500 {
            if await fifo.status(workspaceID: workspace).waitingCount
                == expected {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("FIFO waiting count never reached \(expected)")
    }
}

private final class LockedStringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

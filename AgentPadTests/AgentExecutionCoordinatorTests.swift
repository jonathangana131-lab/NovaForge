import XCTest

final class AgentExecutionCoordinatorTests: XCTestCase {
    func testMutationLeaseQueuesAnotherOwnerForSameWorkspace() async throws {
        let coordinator = AgentExecutionCoordinator(pollInterval: .milliseconds(10))
        let first = try await coordinator.acquireMutation(
            workspaceName: "Project Atlas",
            runID: UUID(),
            ownerDescription: "Chat run"
        )

        let waiting = Task {
            try await coordinator.acquireMutation(
                workspaceName: "project atlas",
                runID: UUID(),
                ownerDescription: "Project run"
            )
        }

        try await Task.sleep(for: .milliseconds(45))
        let whileWaiting = await coordinator.snapshot()
        XCTAssertEqual(whileWaiting.activeMutationOwnersByWorkspace["project atlas"], "Chat run")

        await coordinator.release(first)
        let second = try await waiting.value
        let afterHandoff = await coordinator.snapshot()
        XCTAssertEqual(afterHandoff.activeMutationOwnersByWorkspace["project atlas"], "Project run")
        await coordinator.release(second)
        let released = await coordinator.snapshot()
        XCTAssertFalse(released.hasActiveWork)
    }

    func testDifferentWorkspacesCanHoldMutationLeasesTogether() async throws {
        let coordinator = AgentExecutionCoordinator()
        let first = try await coordinator.acquireMutation(
            workspaceName: "Atlas",
            runID: UUID(),
            ownerDescription: "Atlas run"
        )
        let second = try await coordinator.acquireMutation(
            workspaceName: "Beacon",
            runID: UUID(),
            ownerDescription: "Beacon run"
        )

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.activeMutationOwnersByWorkspace.count, 2)
        XCTAssertEqual(snapshot.activeMutationOwnersByWorkspace["atlas"], "Atlas run")
        XCTAssertEqual(snapshot.activeMutationOwnersByWorkspace["beacon"], "Beacon run")

        await coordinator.release(first)
        await coordinator.release(second)
    }

    func testCancellingQueuedLeaseDoesNotStealActiveMutation() async throws {
        let coordinator = AgentExecutionCoordinator(pollInterval: .milliseconds(10))
        let first = try await coordinator.acquireMutation(
            workspaceName: "Atlas",
            runID: UUID(),
            ownerDescription: "First"
        )
        let waiting = Task {
            try await coordinator.acquireMutation(
                workspaceName: "Atlas",
                runID: UUID(),
                ownerDescription: "Cancelled"
            )
        }

        try await Task.sleep(for: .milliseconds(35))
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("Expected the queued acquisition to be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        let stillActive = await coordinator.snapshot()
        XCTAssertEqual(stillActive.activeMutationOwnersByWorkspace["atlas"], "First")
        await coordinator.release(first)
    }
}

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
        XCTAssertEqual(whileWaiting.queuedMutationCountsByWorkspace["project atlas"], 1)

        await coordinator.release(first)
        let second = try await waiting.value
        let afterHandoff = await coordinator.snapshot()
        XCTAssertEqual(afterHandoff.activeMutationOwnersByWorkspace["project atlas"], "Project run")
        await coordinator.release(second)
        let released = await coordinator.snapshot()
        XCTAssertFalse(released.hasActiveWork)
        XCTAssertFalse(released.hasQueuedWork)
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
        XCTAssertNil(stillActive.queuedMutationCountsByWorkspace["atlas"])
        await coordinator.release(first)
    }

    func testSameWorkspaceWaitersResumeInFIFOOrder() async throws {
        let coordinator = AgentExecutionCoordinator()
        let order = LeaseOrderRecorder()
        let first = try await coordinator.acquireMutation(
            workspaceName: "Atlas",
            runID: UUID(),
            ownerDescription: "First"
        )

        let second = Task {
            let lease = try await coordinator.acquireMutation(
                workspaceName: "Atlas",
                runID: UUID(),
                ownerDescription: "Second"
            )
            await order.append("Second")
            await coordinator.release(lease)
        }
        try await waitForQueuedMutationCount(1, workspace: "atlas", coordinator: coordinator)

        let third = Task {
            let lease = try await coordinator.acquireMutation(
                workspaceName: "Atlas",
                runID: UUID(),
                ownerDescription: "Third"
            )
            await order.append("Third")
            await coordinator.release(lease)
        }
        try await waitForQueuedMutationCount(2, workspace: "atlas", coordinator: coordinator)

        await coordinator.release(first)
        try await second.value
        try await third.value

        let recordedOrder = await order.values()
        XCTAssertEqual(recordedOrder, ["Second", "Third"])
        let settled = await coordinator.snapshot()
        XCTAssertFalse(settled.hasActiveWork)
        XCTAssertFalse(settled.hasQueuedWork)
    }

    func testLocalInferenceWaitersUseTheSameFIFOArbitration() async throws {
        let coordinator = AgentExecutionCoordinator()
        let first = try await coordinator.acquireLocalInference(
            runID: UUID(),
            ownerDescription: "First inference"
        )
        let waiting = Task {
            try await coordinator.acquireLocalInference(
                runID: UUID(),
                ownerDescription: "Second inference"
            )
        }

        try await waitForQueuedLocalInferenceCount(1, coordinator: coordinator)
        let queued = await coordinator.snapshot()
        XCTAssertEqual(queued.activeLocalInferenceOwner, "First inference")
        XCTAssertEqual(queued.queuedLocalInferenceCount, 1)

        await coordinator.release(first)
        let second = try await waiting.value
        let handedOff = await coordinator.snapshot()
        XCTAssertEqual(handedOff.activeLocalInferenceOwner, "Second inference")
        await coordinator.release(second)
    }

    func testCancellationRacingLeaseHandoffNeverStrandsResource() async throws {
        let coordinator = AgentExecutionCoordinator()

        for iteration in 0..<20 {
            let first = try await coordinator.acquireMutation(
                workspaceName: "Atlas",
                runID: UUID(),
                ownerDescription: "First \(iteration)"
            )
            let waiting = Task {
                try await coordinator.acquireMutation(
                    workspaceName: "Atlas",
                    runID: UUID(),
                    ownerDescription: "Racing \(iteration)"
                )
            }
            try await waitForQueuedMutationCount(1, workspace: "atlas", coordinator: coordinator)

            let releasing = Task {
                await coordinator.release(first)
            }
            waiting.cancel()
            await releasing.value

            do {
                let racedLease = try await waiting.value
                await coordinator.release(racedLease)
            } catch is CancellationError {
                // Cancellation may win before or immediately after the handoff.
            }

            let settled = await coordinator.snapshot()
            XCTAssertFalse(settled.hasActiveWork, "Iteration \(iteration) stranded an active lease.")
            XCTAssertFalse(settled.hasQueuedWork, "Iteration \(iteration) stranded a queued waiter.")
            if settled.hasActiveWork || settled.hasQueuedWork {
                return
            }
        }
    }

    private func waitForQueuedMutationCount(
        _ expected: Int,
        workspace: String,
        coordinator: AgentExecutionCoordinator
    ) async throws {
        for _ in 0..<200 {
            let snapshot = await coordinator.snapshot()
            if snapshot.queuedMutationCountsByWorkspace[workspace] == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for \(expected) queued mutation waiter(s) in \(workspace).")
    }

    private func waitForQueuedLocalInferenceCount(
        _ expected: Int,
        coordinator: AgentExecutionCoordinator
    ) async throws {
        for _ in 0..<200 {
            let snapshot = await coordinator.snapshot()
            if snapshot.queuedLocalInferenceCount == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for \(expected) queued inference waiter(s).")
    }
}

private actor LeaseOrderRecorder {
    private var recordedValues: [String] = []

    func append(_ value: String) {
        recordedValues.append(value)
    }

    func values() -> [String] {
        recordedValues
    }
}

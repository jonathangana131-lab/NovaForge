import SwiftData
import XCTest

final class WorkspaceMutationGatewayTests: XCTestCase {
    func testRequestUsesCanonicalHashedRootIdentityWithoutRetainingPath() throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }

        let request = try makeRequest(
            workspace: fixture.workspace,
            displayName: "   ",
            owner: "   ",
            operation: .movePath(from: " Notes/today.md ", to: "Notes/today.md")
        )

        XCTAssertEqual(request.workspaceName, "Default")
        XCTAssertEqual(request.context.ownerDescription, WorkspaceMutationSource.editor.rawValue)
        XCTAssertEqual(request.operation.targetPaths, ["Notes/today.md"])
        XCTAssertEqual(request.operation.risk, .destructiveWrite)
        XCTAssertTrue(request.workspaceIdentity.resourceKey.hasPrefix("workspace:sha256:"))
        XCTAssertEqual(request.workspaceIdentity.resourceKey.count, "workspace:sha256:".count + 64)
        XCTAssertFalse(request.workspaceIdentity.resourceKey.contains(fixture.rootURL.path))

        let groups = request.workspaceIdentity.persistentID.uuidString.split(separator: "-")
        XCTAssertEqual(groups[2].first, "8", "The deterministic identity should use UUIDv8 bits.")
        XCTAssertTrue(["8", "9", "A", "B"].contains(String(groups[3].first ?? "0")))
    }

    func testPermitRejectsCrossRootAndWrongOperationOrPath() async throws {
        let fixture = try TemporaryMutationWorkspace()
        let otherFixture = try TemporaryMutationWorkspace()
        defer {
            fixture.remove()
            otherFixture.remove()
        }
        let request = try makeRequest(
            workspace: fixture.workspace,
            owner: "Bound write",
            operation: .writeFile(path: "allowed.txt")
        )
        let gateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: RecordingWorkspaceMutationJournal()
        )

        let result = try await gateway.perform(request) { permit in
            var blocks = 0
            do {
                try otherFixture.workspace.write("allowed.txt", contents: "wrong root", permit: permit)
            } catch let error as WorkspaceMutationPermitError {
                if case .workspaceMismatch(let operationID) = error, operationID == request.id {
                    blocks += 1
                }
            }
            do {
                try fixture.workspace.append("allowed.txt", contents: "wrong operation", permit: permit)
            } catch let error as WorkspaceMutationPermitError {
                if case .operationMismatch(let operationID) = error, operationID == request.id {
                    blocks += 1
                }
            }
            do {
                try fixture.workspace.write("other.txt", contents: "wrong path", permit: permit)
            } catch let error as WorkspaceMutationPermitError {
                if case .operationMismatch(let operationID) = error, operationID == request.id {
                    blocks += 1
                }
            }
            return WorkspaceMutationEffect(summary: "blocked:\(blocks)")
        }

        XCTAssertEqual(result.effect.summary, "blocked:3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherFixture.rootURL.appendingPathComponent("allowed.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL.appendingPathComponent("allowed.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL.appendingPathComponent("other.txt").path))
    }

    func testEscapedPermitIsRevokedAfterEffectReturns() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let request = try makeRequest(
            workspace: fixture.workspace,
            owner: "Revocation",
            operation: .writeFile(path: "proof.txt")
        )
        let permitBox = LockedTestBox<WorkspaceMutationPermit>()
        let gateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: RecordingWorkspaceMutationJournal()
        )

        _ = try await gateway.perform(request) { permit in
            permitBox.store(permit)
            try fixture.workspace.write("proof.txt", contents: "durable", permit: permit)
            return WorkspaceMutationEffect(summary: "wrote proof", changedPaths: ["proof.txt"])
        }

        let escapedPermit = try XCTUnwrap(permitBox.load())
        XCTAssertThrowsError(
            try fixture.workspace.write("proof.txt", contents: "escaped", permit: escapedPermit)
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceMutationPermitError,
                .revoked(operationID: request.id)
            )
        }
        XCTAssertEqual(try fixture.workspace.read("proof.txt"), "durable")
    }

    func testCompletedReplayReturnsDurableResultWithoutRedispatch() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal()
        let gateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: journal
        )
        let request = try makeRequest(workspace: fixture.workspace, owner: "Replay")
        let dispatch = EffectDispatchProbe()

        let first = try await gateway.perform(request) { _ in
            await dispatch.record()
            return WorkspaceMutationEffect(summary: "durable result", changedPaths: ["replay.txt"])
        }
        let replay = try await gateway.perform(request) { _ in
            await dispatch.record()
            return WorkspaceMutationEffect(summary: "must not run")
        }
        let dispatchCount = await dispatch.count()

        XCTAssertEqual(first.effect.summary, "durable result")
        XCTAssertEqual(replay.effect.summary, "durable result")
        XCTAssertEqual(dispatchCount, 1)
    }

    func testAppliedReplaySettlesCompletedWithoutRedispatch() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal()
        let gateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: journal
        )
        let request = try makeRequest(workspace: fixture.workspace, owner: "Applied replay")
        try await journal.schedule(WorkspaceMutationJournalEntry(request: request))
        try await journal.transition(operationID: request.id, to: .executing)
        try await journal.transition(
            operationID: request.id,
            to: .applied,
            resultSummary: "already applied"
        )
        let dispatch = EffectDispatchProbe()

        let replay = try await gateway.perform(request) { _ in
            await dispatch.record()
            return WorkspaceMutationEffect(summary: "must not run")
        }

        let receipt = await journal.snapshot()
        let dispatchCount = await dispatch.count()
        XCTAssertEqual(replay.effect.summary, "already applied")
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertEqual(receipt.phases[request.id], .completed)
    }

    func testExistingExecutingReceiptRequiresInspectionWithoutDispatch() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal()
        let gateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: journal
        )
        let request = try makeRequest(workspace: fixture.workspace, owner: "Executing replay")
        try await journal.schedule(WorkspaceMutationJournalEntry(request: request))
        try await journal.transition(operationID: request.id, to: .executing)
        let dispatch = EffectDispatchProbe()

        do {
            _ = try await gateway.perform(request) { _ in
                await dispatch.record()
                return WorkspaceMutationEffect(summary: "must not run")
            }
            XCTFail("Expected executing replay to require inspection.")
        } catch let error as WorkspaceMutationGatewayError {
            XCTAssertEqual(
                error,
                .replayRequiresInspection(operationID: request.id, phase: .executing)
            )
        }
        let dispatchCount = await dispatch.count()
        XCTAssertEqual(dispatchCount, 0)
    }

    func testExistingInterruptedReceiptRequiresInspectionWithoutDispatch() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal()
        let gateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: journal
        )
        let request = try makeRequest(workspace: fixture.workspace, owner: "Interrupted replay")
        try await journal.schedule(WorkspaceMutationJournalEntry(request: request))
        try await journal.transition(operationID: request.id, to: .interrupted)
        let dispatch = EffectDispatchProbe()

        do {
            _ = try await gateway.perform(request) { _ in
                await dispatch.record()
                return WorkspaceMutationEffect(summary: "must not run")
            }
            XCTFail("Expected interrupted replay to require inspection.")
        } catch let error as WorkspaceMutationGatewayError {
            XCTAssertEqual(
                error,
                .replayRequiresInspection(operationID: request.id, phase: .interrupted)
            )
        }
        let dispatchCount = await dispatch.count()
        XCTAssertEqual(dispatchCount, 0)
    }

    func testScheduledReplayResumesAndDispatchesOnce() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal()
        let gateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: journal
        )
        let request = try makeRequest(workspace: fixture.workspace, owner: "Scheduled replay")
        try await journal.schedule(WorkspaceMutationJournalEntry(request: request))
        let dispatch = EffectDispatchProbe()

        let result = try await gateway.perform(request) { _ in
            await dispatch.record()
            return WorkspaceMutationEffect(summary: "resumed safely")
        }
        let dispatchCount = await dispatch.count()

        XCTAssertEqual(result.effect.summary, "resumed safely")
        XCTAssertEqual(dispatchCount, 1)
    }

    func testSameIDAcrossTwoGatewaysSerializesAndRunsEffectOnce() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal()
        let firstGateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: journal
        )
        let secondGateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: journal
        )
        let request = try makeRequest(workspace: fixture.workspace, owner: "Concurrent replay")
        let firstStarted = AsyncTestGate()
        let releaseFirst = AsyncTestGate()
        let secondStarted = AsyncTestGate()
        let dispatch = EffectDispatchProbe()

        let firstTask = Task {
            try await firstGateway.perform(request) { _ in
                await dispatch.record()
                await firstStarted.open()
                await releaseFirst.wait()
                return WorkspaceMutationEffect(summary: "single dispatch")
            }
        }
        await firstStarted.wait()

        let secondTask = Task {
            await secondStarted.open()
            return try await secondGateway.perform(request) { _ in
                await dispatch.record()
                return WorkspaceMutationEffect(summary: "must not run")
            }
        }
        await secondStarted.wait()
        await releaseFirst.open()

        let first = try await firstTask.value
        let second = try await secondTask.value
        let dispatchCount = await dispatch.count()
        XCTAssertEqual(first.effect.summary, "single dispatch")
        XCTAssertEqual(second.effect.summary, "single dispatch")
        XCTAssertEqual(dispatchCount, 1)
    }

    func testSameRootSerializesAcrossDisplayRename() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal()
        let coordinator = AgentExecutionCoordinator()
        let gateway = WorkspaceMutationGateway.testing(coordinator: coordinator, journal: journal)
        let firstStarted = AsyncTestGate()
        let releaseFirst = AsyncTestGate()
        let probe = WorkspaceMutationProbe()
        let beforeRename = try makeRequest(
            workspace: fixture.workspace,
            displayName: "Project Atlas",
            owner: "Before rename"
        )
        let afterRename = try makeRequest(
            workspace: fixture.workspace,
            displayName: "Renamed Atlas",
            owner: "After rename"
        )

        XCTAssertEqual(beforeRename.workspaceIdentity, afterRename.workspaceIdentity)

        let firstTask = Task {
            try await gateway.perform(beforeRename) { _ in
                await probe.begin("Before rename")
                await firstStarted.open()
                await releaseFirst.wait()
                await probe.finish()
                return WorkspaceMutationEffect(summary: "First complete")
            }
        }
        await firstStarted.wait()

        let secondTask = Task {
            try await gateway.perform(afterRename) { _ in
                await probe.begin("After rename")
                await probe.finish()
                return WorkspaceMutationEffect(summary: "Second complete")
            }
        }
        try await waitForQueuedMutationCount(
            1,
            resourceKey: beforeRename.workspaceIdentity.resourceKey,
            coordinator: coordinator
        )

        let queued = await coordinator.snapshot()
        XCTAssertEqual(
            queued.activeMutationOwnersByWorkspace[beforeRename.workspaceIdentity.resourceKey],
            "Before rename"
        )
        await releaseFirst.open()
        _ = try await firstTask.value
        _ = try await secondTask.value

        let probeSnapshot = await probe.snapshot()
        XCTAssertEqual(probeSnapshot.maximumConcurrentCount, 1)
        XCTAssertEqual(probeSnapshot.startedOrder, ["Before rename", "After rename"])
    }

    func testSuccessPersistsOrderedReceiptsAndCompleteLineage() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal()
        let gateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: journal
        )
        let runID = UUID()
        let projectID = UUID()
        let conversationID = UUID()
        let request = try WorkspaceMutationRequest(
            workspace: fixture.workspace,
            workspaceDisplayName: "Atlas",
            operation: .agentTool(name: "write_file", targetPaths: ["README.md"]),
            journalArgumentsJSON: #"{"path":"README.md"}"#,
            context: WorkspaceMutationContext(
                runID: runID,
                projectID: projectID,
                conversationID: conversationID,
                toolCallID: "call_write_readme",
                source: .agentTool,
                authorization: .agentApproved(toolCallID: "call_write_readme"),
                ownerDescription: "Agent write"
            )
        )

        let result = try await gateway.perform(request) { _ in
            WorkspaceMutationEffect(summary: "Wrote README.md", changedPaths: ["README.md"])
        }
        let snapshot = await journal.snapshot()
        let entry = try XCTUnwrap(snapshot.entries[request.id])

        XCTAssertEqual(snapshot.attempts, [
            .schedule,
            .phase(.executing),
            .phase(.applied),
            .phase(.completed)
        ])
        XCTAssertEqual(snapshot.phases[request.id], .completed)
        XCTAssertEqual(entry.workspaceResourceKey, request.workspaceIdentity.resourceKey)
        XCTAssertEqual(entry.workspacePersistentID, request.workspaceIdentity.persistentID)
        XCTAssertEqual(entry.runID, runID)
        XCTAssertEqual(entry.projectID, projectID)
        XCTAssertEqual(entry.conversationID, conversationID)
        XCTAssertEqual(entry.toolCallID, "call_write_readme")
        XCTAssertEqual(entry.source, .agentTool)
        XCTAssertEqual(entry.authorization, .agentApproved(toolCallID: "call_write_readme"))
        XCTAssertEqual(entry.targetPaths, ["README.md"])
        XCTAssertEqual(snapshot.resultSummaries[request.id], "Wrote README.md")
        XCTAssertEqual(result.workspaceResourceKey, request.workspaceIdentity.resourceKey)
    }

    func testEffectRunsInlineWithCallingTaskLocalContext() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let gateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: RecordingWorkspaceMutationJournal()
        )
        let request = try makeRequest(workspace: fixture.workspace, owner: "Editor")

        let result = try await MutationTaskContext.$marker.withValue("calling-task") {
            try await gateway.perform(request) { _ in
                WorkspaceMutationEffect(summary: MutationTaskContext.marker ?? "missing")
            }
        }

        XCTAssertEqual(result.effect.summary, "calling-task")
    }

    func testScheduleFailureDispatchesNothing() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal(failures: [.schedule: 1])
        let coordinator = AgentExecutionCoordinator()
        let gateway = WorkspaceMutationGateway.testing(coordinator: coordinator, journal: journal)
        let request = try makeRequest(workspace: fixture.workspace, owner: "Editor")
        let dispatch = EffectDispatchProbe()

        do {
            _ = try await gateway.perform(request) { _ in
                await dispatch.record()
                return WorkspaceMutationEffect(summary: "Must not run")
            }
            XCTFail("Expected scheduling persistence to fail.")
        } catch let error as WorkspaceMutationGatewayError {
            guard case .journalPersistenceFailed(let operationID, .scheduled, false, _) = error else {
                return XCTFail("Unexpected gateway error: \(error)")
            }
            XCTAssertEqual(operationID, request.id)
        }

        let dispatchCount = await dispatch.count()
        let coordinatorSnapshot = await coordinator.snapshot()
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertFalse(coordinatorSnapshot.hasActiveWork)
    }

    func testExecutingReceiptFailureDispatchesNothingAndReleasesLease() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal(failures: [.phase(.executing): 1])
        let coordinator = AgentExecutionCoordinator()
        let gateway = WorkspaceMutationGateway.testing(coordinator: coordinator, journal: journal)
        let request = try makeRequest(workspace: fixture.workspace, owner: "Editor")
        let dispatch = EffectDispatchProbe()

        do {
            _ = try await gateway.perform(request) { _ in
                await dispatch.record()
                return WorkspaceMutationEffect(summary: "Must not run")
            }
            XCTFail("Expected executing persistence to fail.")
        } catch let error as WorkspaceMutationGatewayError {
            guard case .journalPersistenceFailed(let operationID, .executing, false, _) = error else {
                return XCTFail("Unexpected gateway error: \(error)")
            }
            XCTAssertEqual(operationID, request.id)
        }

        let receipt = await journal.snapshot()
        XCTAssertEqual(receipt.phases[request.id], .interrupted)
        let dispatchCount = await dispatch.count()
        let coordinatorSnapshot = await coordinator.snapshot()
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertFalse(coordinatorSnapshot.hasActiveWork)
    }

    func testCancellationWhileQueuedPersistsInterruptedWithoutDispatch() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal()
        let coordinator = AgentExecutionCoordinator()
        let gateway = WorkspaceMutationGateway.testing(coordinator: coordinator, journal: journal)
        let firstStarted = AsyncTestGate()
        let releaseFirst = AsyncTestGate()
        let dispatch = EffectDispatchProbe()
        let first = try makeRequest(workspace: fixture.workspace, owner: "First")
        let cancelled = try makeRequest(workspace: fixture.workspace, owner: "Cancelled")

        let firstTask = Task {
            try await gateway.perform(first) { _ in
                await firstStarted.open()
                await releaseFirst.wait()
                return WorkspaceMutationEffect(summary: "First complete")
            }
        }
        await firstStarted.wait()
        let waitingTask = Task {
            try await gateway.perform(cancelled) { _ in
                await dispatch.record()
                return WorkspaceMutationEffect(summary: "Must not run")
            }
        }
        try await waitForQueuedMutationCount(
            1,
            resourceKey: cancelled.workspaceIdentity.resourceKey,
            coordinator: coordinator
        )
        waitingTask.cancel()

        do {
            _ = try await waitingTask.value
            XCTFail("Expected queued cancellation.")
        } catch let error as WorkspaceMutationGatewayError {
            XCTAssertEqual(error, .cancelledBeforeExecution(operationID: cancelled.id))
        }
        let cancelledReceipt = await journal.snapshot()
        let cancelledDispatchCount = await dispatch.count()
        XCTAssertEqual(cancelledReceipt.phases[cancelled.id], .interrupted)
        XCTAssertEqual(cancelledDispatchCount, 0)

        await releaseFirst.open()
        _ = try await firstTask.value
    }

    func testThrownEffectIsInterruptedAndMayHaveApplied() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal()
        let coordinator = AgentExecutionCoordinator()
        let gateway = WorkspaceMutationGateway.testing(coordinator: coordinator, journal: journal)
        let request = try makeRequest(workspace: fixture.workspace, owner: "Editor")

        do {
            _ = try await gateway.perform(request) { _ in
                throw WorkspaceMutationFixtureError.effect
            }
            XCTFail("Expected the dispatched effect to fail ambiguously.")
        } catch let error as WorkspaceMutationGatewayError {
            guard case .effectMayHaveApplied(let operationID, _) = error else {
                return XCTFail("Unexpected gateway error: \(error)")
            }
            XCTAssertEqual(operationID, request.id)
        }

        let receipt = await journal.snapshot()
        let coordinatorSnapshot = await coordinator.snapshot()
        XCTAssertEqual(receipt.phases[request.id], .interrupted)
        XCTAssertFalse(coordinatorSnapshot.hasActiveWork)
    }

    func testCancellationThrownAfterDispatchIsInterruptedAndMayHaveApplied() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal()
        let gateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: journal
        )
        let request = try makeRequest(workspace: fixture.workspace, owner: "Editor")
        let effectStarted = AsyncTestGate()

        let task = Task {
            try await gateway.perform(request) { _ in
                await effectStarted.open()
                try await Task.sleep(for: .seconds(30))
                return WorkspaceMutationEffect(summary: "Must not complete")
            }
        }
        await effectStarted.wait()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected post-dispatch cancellation to be ambiguous.")
        } catch let error as WorkspaceMutationGatewayError {
            guard case .effectMayHaveApplied(let operationID, _) = error else {
                return XCTFail("Unexpected gateway error: \(error)")
            }
            XCTAssertEqual(operationID, request.id)
        }
        let receipt = await journal.snapshot()
        XCTAssertEqual(receipt.phases[request.id], .interrupted)
    }

    func testAppliedReceiptFailureSettlesInterruptedAndReturnsDurableError() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal(failures: [.phase(.applied): 1])
        let gateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: journal
        )
        let request = try makeRequest(workspace: fixture.workspace, owner: "Editor")

        do {
            _ = try await gateway.perform(request) { _ in
                WorkspaceMutationEffect(summary: "Effect returned success")
            }
            XCTFail("Expected applied settlement to fail.")
        } catch let error as WorkspaceMutationGatewayError {
            guard case .durableSettlementFailed(let operationID, .interrupted, _) = error else {
                return XCTFail("Unexpected gateway error: \(error)")
            }
            XCTAssertEqual(operationID, request.id)
        }
        let receipt = await journal.snapshot()
        XCTAssertEqual(receipt.phases[request.id], .interrupted)
    }

    func testAppliedAndAmbiguityReceiptFailuresReportExecutingAsLastDurablePhase() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal(failures: [
            .phase(.applied): 1,
            .phase(.interrupted): 1
        ])
        let gateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: journal
        )
        let request = try makeRequest(workspace: fixture.workspace, owner: "Editor")

        do {
            _ = try await gateway.perform(request) { _ in
                WorkspaceMutationEffect(summary: "Effect returned success")
            }
            XCTFail("Expected durable ambiguity.")
        } catch let error as WorkspaceMutationGatewayError {
            guard case .durableSettlementFailed(let operationID, .executing, _) = error else {
                return XCTFail("Unexpected gateway error: \(error)")
            }
            XCTAssertEqual(operationID, request.id)
        }
        let receipt = await journal.snapshot()
        XCTAssertEqual(receipt.phases[request.id], .executing)
    }

    func testCompletedReceiptFailureLeavesAppliedAsLastDurablePhase() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let journal = RecordingWorkspaceMutationJournal(failures: [.phase(.completed): 1])
        let gateway = WorkspaceMutationGateway.testing(
            coordinator: AgentExecutionCoordinator(),
            journal: journal
        )
        let request = try makeRequest(workspace: fixture.workspace, owner: "Editor")

        do {
            _ = try await gateway.perform(request) { _ in
                WorkspaceMutationEffect(summary: "Effect returned success")
            }
            XCTFail("Expected completion settlement to fail.")
        } catch let error as WorkspaceMutationGatewayError {
            guard case .durableSettlementFailed(let operationID, .applied, _) = error else {
                return XCTFail("Unexpected gateway error: \(error)")
            }
            XCTAssertEqual(operationID, request.id)
        }
        let receipt = await journal.snapshot()
        XCTAssertEqual(receipt.phases[request.id], .applied)
    }

    func testLeaseIsHeldUntilCompletedReceiptSettles() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let settlementEntered = AsyncTestGate()
        let releaseSettlement = AsyncTestGate()
        let journal = RecordingWorkspaceMutationJournal(
            block: .phase(.completed),
            blockEntered: settlementEntered,
            releaseBlock: releaseSettlement
        )
        let coordinator = AgentExecutionCoordinator()
        let gateway = WorkspaceMutationGateway.testing(coordinator: coordinator, journal: journal)
        let first = try makeRequest(workspace: fixture.workspace, owner: "First")
        let second = try makeRequest(workspace: fixture.workspace, owner: "Second")
        let secondDispatch = EffectDispatchProbe()

        let firstTask = Task {
            try await gateway.perform(first) { _ in
                WorkspaceMutationEffect(summary: "First effect complete")
            }
        }
        await settlementEntered.wait()

        let secondTask = Task {
            try await gateway.perform(second) { _ in
                await secondDispatch.record()
                return WorkspaceMutationEffect(summary: "Second effect complete")
            }
        }
        try await waitForQueuedMutationCount(
            1,
            resourceKey: first.workspaceIdentity.resourceKey,
            coordinator: coordinator
        )
        let blockedDispatchCount = await secondDispatch.count()
        let blockedCoordinatorSnapshot = await coordinator.snapshot()
        XCTAssertEqual(blockedDispatchCount, 0)
        XCTAssertEqual(
            blockedCoordinatorSnapshot.activeMutationOwnersByWorkspace[first.workspaceIdentity.resourceKey],
            "First"
        )

        await releaseSettlement.open()
        _ = try await firstTask.value
        _ = try await secondTask.value
        let settledDispatchCount = await secondDispatch.count()
        XCTAssertEqual(settledDispatchCount, 1)
    }

    func testSwiftDataJournalIsIdempotentMonotonicAndPreservesMetadata() async throws {
        let fixture = try TemporaryMutationWorkspace()
        defer { fixture.remove() }
        let container = try ModelContainer(
            for: Schema([ToolOperationRecord.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let journal = SwiftDataWorkspaceMutationJournal(container: container)
        let runID = UUID()
        let projectID = UUID()
        let conversationID = UUID()
        let requestedAt = Date(timeIntervalSince1970: 1_000)
        let request = try WorkspaceMutationRequest(
            workspace: fixture.workspace,
            workspaceDisplayName: "Renamed Atlas",
            operation: .movePath(from: "Draft.md", to: "README.md"),
            journalArgumentsJSON: #"{"from":"Draft.md","to":"README.md"}"#,
            context: WorkspaceMutationContext(
                runID: runID,
                projectID: projectID,
                conversationID: conversationID,
                toolCallID: "call_move",
                source: .agentTool,
                authorization: .agentPolicyApproved(toolCallID: "call_move"),
                ownerDescription: "Policy-approved move"
            ),
            requestedAt: requestedAt
        )
        let entry = WorkspaceMutationJournalEntry(request: request)

        try await journal.schedule(entry)
        try await journal.schedule(entry)
        let conflictingRequest = try WorkspaceMutationRequest(
            id: request.id,
            workspace: fixture.workspace,
            workspaceDisplayName: "Different workspace label",
            operation: request.operation,
            journalArgumentsJSON: request.journalArgumentsJSON,
            context: request.context,
            requestedAt: request.requestedAt
        )
        do {
            try await journal.schedule(WorkspaceMutationJournalEntry(request: conflictingRequest))
            XCTFail("Expected existing receipt metadata to match exactly.")
        } catch let error as WorkspaceMutationJournalError {
            XCTAssertEqual(error, .operationConflict(request.id))
        }
        let executingAt = requestedAt.addingTimeInterval(1)
        try await journal.transition(
            operationID: request.id,
            to: .executing,
            resultSummary: nil,
            errorMessage: nil,
            at: executingAt
        )
        try await journal.transition(
            operationID: request.id,
            to: .executing,
            resultSummary: nil,
            errorMessage: nil,
            at: executingAt.addingTimeInterval(50)
        )
        let storedSnapshot = try await journal.snapshot(operationID: request.id)
        let snapshot = try XCTUnwrap(storedSnapshot)

        XCTAssertEqual(snapshot.phase, .executing)
        XCTAssertEqual(snapshot.workspacePersistentID, request.workspaceIdentity.persistentID)
        XCTAssertEqual(snapshot.workspaceName, "Renamed Atlas")
        XCTAssertEqual(snapshot.operationName, "move_path")
        XCTAssertEqual(snapshot.argumentsJSON, request.journalArgumentsJSON)
        XCTAssertEqual(snapshot.argumentsHash.count, 64)
        XCTAssertEqual(snapshot.targetPaths, ["Draft.md", "README.md"])
        XCTAssertEqual(snapshot.runID, runID)
        XCTAssertEqual(snapshot.projectID, projectID)
        XCTAssertEqual(snapshot.conversationID, conversationID)
        XCTAssertEqual(snapshot.toolCallID, "call_move")
        XCTAssertEqual(snapshot.sourceRawValue, WorkspaceMutationSource.agentTool.rawValue)
        XCTAssertEqual(snapshot.authorizationKind, "agent_policy_approved")
        XCTAssertEqual(snapshot.authorizationDetail, "call_move")
        XCTAssertEqual(snapshot.ownerDescription, "Policy-approved move")
        XCTAssertEqual(snapshot.riskRawValue, WorkspaceMutationRisk.destructiveWrite.rawValue)
        XCTAssertEqual(snapshot.scheduledAt, requestedAt)
        XCTAssertEqual(snapshot.startedAt, executingAt, "Idempotent replay must not rewrite timestamps.")

        do {
            let context = ModelContext(container)
            let records = try context.fetch(FetchDescriptor<ToolOperationRecord>())
            let stored = try XCTUnwrap(records.first(where: { $0.id == request.id }))
            XCTAssertFalse(stored.argumentsJSON.contains(fixture.rootURL.path))
            XCTAssertEqual(stored.workspaceID, request.workspaceIdentity.persistentID)
        }

        let invalidRequest = try makeRequest(workspace: fixture.workspace, owner: "Invalid skip")
        try await journal.schedule(WorkspaceMutationJournalEntry(request: invalidRequest))
        do {
            try await journal.transition(
                operationID: invalidRequest.id,
                to: .completed,
                resultSummary: nil,
                errorMessage: nil,
                at: Date()
            )
            XCTFail("Expected a non-monotonic transition to fail.")
        } catch let error as WorkspaceMutationJournalError {
            XCTAssertEqual(
                error,
                .invalidTransition(
                    operationID: invalidRequest.id,
                    from: .scheduled,
                    to: .completed
                )
            )
        }
    }

    private func makeRequest(
        workspace: SandboxWorkspace,
        displayName: String? = nil,
        owner: String,
        operation: WorkspaceMutationOperation? = nil
    ) throws -> WorkspaceMutationRequest {
        try WorkspaceMutationRequest(
            workspace: workspace,
            workspaceDisplayName: displayName,
            operation: operation ?? .writeFile(path: "\(owner.lowercased()).txt"),
            context: WorkspaceMutationContext(
                source: .editor,
                authorization: .userInitiated,
                ownerDescription: owner
            )
        )
    }

    private func waitForQueuedMutationCount(
        _ expected: Int,
        resourceKey: String,
        coordinator: AgentExecutionCoordinator
    ) async throws {
        for _ in 0..<300 {
            let snapshot = await coordinator.snapshot()
            if snapshot.queuedMutationCountsByWorkspace[resourceKey] == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for \(expected) queued mutation waiter(s).")
    }
}

private enum MutationTaskContext {
    @TaskLocal static var marker: String?
}

private struct TemporaryMutationWorkspace: Sendable {
    let rootURL: URL
    let workspace: SandboxWorkspace

    init() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeGatewayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        self.rootURL = rootURL
        self.workspace = SandboxWorkspace(rootURL: rootURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class LockedTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct JournalCheckpoint: Hashable, Sendable {
    let rawValue: String

    static let schedule = JournalCheckpoint(rawValue: "schedule")

    static func phase(_ phase: ToolOperationPhase) -> JournalCheckpoint {
        JournalCheckpoint(rawValue: "phase:\(phase.rawValue)")
    }
}

private struct RecordingJournalSnapshot: Sendable {
    let entries: [UUID: WorkspaceMutationJournalEntry]
    let attempts: [JournalCheckpoint]
    let phases: [UUID: ToolOperationPhase]
    let resultSummaries: [UUID: String]
    let errorMessages: [UUID: String]
}

private actor RecordingWorkspaceMutationJournal: WorkspaceMutationJournaling {
    private var failures: [JournalCheckpoint: Int]
    private let blockedCheckpoint: JournalCheckpoint?
    private let blockEntered: AsyncTestGate?
    private let releaseBlock: AsyncTestGate?
    private var entries: [UUID: WorkspaceMutationJournalEntry] = [:]
    private var attempts: [JournalCheckpoint] = []
    private var phases: [UUID: ToolOperationPhase] = [:]
    private var resultSummaries: [UUID: String] = [:]
    private var errorMessages: [UUID: String] = [:]

    init(
        failures: [JournalCheckpoint: Int] = [:],
        block: JournalCheckpoint? = nil,
        blockEntered: AsyncTestGate? = nil,
        releaseBlock: AsyncTestGate? = nil
    ) {
        self.failures = failures
        self.blockedCheckpoint = block
        self.blockEntered = blockEntered
        self.releaseBlock = releaseBlock
    }

    func schedule(_ entry: WorkspaceMutationJournalEntry) async throws {
        let checkpoint = JournalCheckpoint.schedule
        attempts.append(checkpoint)
        try failIfRequested(checkpoint)
        if let existing = entries[entry.operationID] {
            guard existing == entry else {
                throw WorkspaceMutationJournalError.operationConflict(entry.operationID)
            }
            return
        }
        entries[entry.operationID] = entry
        phases[entry.operationID] = .scheduled
    }

    func snapshot(operationID: UUID) async throws -> WorkspaceMutationJournalSnapshot? {
        guard let entry = entries[operationID], let phase = phases[operationID] else {
            return nil
        }
        return WorkspaceMutationJournalSnapshot(
            operationID: operationID,
            phase: phase,
            workspacePersistentID: entry.workspacePersistentID,
            workspaceName: entry.workspaceName,
            operationName: entry.operationName,
            argumentsHash: "recording-journal",
            argumentsJSON: entry.argumentsJSON,
            targetPaths: entry.targetPaths,
            runID: entry.runID,
            projectID: entry.projectID,
            conversationID: entry.conversationID,
            toolCallID: entry.toolCallID,
            sourceRawValue: entry.source.rawValue,
            authorizationKind: entry.authorization.journalKind,
            authorizationDetail: entry.authorization.journalDetail,
            ownerDescription: entry.ownerDescription,
            riskRawValue: entry.risk.rawValue,
            resultSummary: resultSummaries[operationID],
            errorMessage: errorMessages[operationID],
            scheduledAt: entry.requestedAt,
            startedAt: nil,
            appliedAt: nil,
            completedAt: phase == .completed ? Date() : nil
        )
    }

    func transition(
        operationID: UUID,
        to phase: ToolOperationPhase,
        resultSummary: String?,
        errorMessage: String?,
        at _: Date
    ) async throws {
        let checkpoint = JournalCheckpoint.phase(phase)
        attempts.append(checkpoint)
        if checkpoint == blockedCheckpoint {
            await blockEntered?.open()
            await releaseBlock?.wait()
        }
        try failIfRequested(checkpoint)
        guard let current = phases[operationID] else {
            throw WorkspaceMutationJournalError.missingOperation(operationID)
        }
        if current == phase { return }
        guard Self.allows(from: current, to: phase) else {
            throw WorkspaceMutationJournalError.invalidTransition(
                operationID: operationID,
                from: current,
                to: phase
            )
        }
        phases[operationID] = phase
        if let resultSummary { resultSummaries[operationID] = resultSummary }
        if let errorMessage { errorMessages[operationID] = errorMessage }
    }

    func snapshot() -> RecordingJournalSnapshot {
        RecordingJournalSnapshot(
            entries: entries,
            attempts: attempts,
            phases: phases,
            resultSummaries: resultSummaries,
            errorMessages: errorMessages
        )
    }

    private func failIfRequested(_ checkpoint: JournalCheckpoint) throws {
        guard let count = failures[checkpoint], count > 0 else { return }
        failures[checkpoint] = count - 1
        throw WorkspaceMutationFixtureError.journal(checkpoint.rawValue)
    }

    private static func allows(
        from current: ToolOperationPhase,
        to next: ToolOperationPhase
    ) -> Bool {
        switch (current, next) {
        case (.scheduled, .executing),
             (.scheduled, .interrupted),
             (.executing, .applied),
             (.executing, .interrupted),
             (.applied, .completed):
            true
        default:
            false
        }
    }
}

private enum WorkspaceMutationFixtureError: LocalizedError, Sendable {
    case effect
    case journal(String)

    var errorDescription: String? {
        switch self {
        case .effect:
            "fixture mutation failed"
        case .journal(let checkpoint):
            "fixture journal failed at \(checkpoint)"
        }
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor EffectDispatchProbe {
    private var dispatchCount = 0

    func record() {
        dispatchCount += 1
    }

    func count() -> Int {
        dispatchCount
    }
}

private actor WorkspaceMutationProbe {
    struct Snapshot: Sendable {
        let maximumConcurrentCount: Int
        let startedOrder: [String]
    }

    private var activeCount = 0
    private var maximumConcurrentCount = 0
    private var startedOrder: [String] = []

    func begin(_ label: String) {
        activeCount += 1
        maximumConcurrentCount = max(maximumConcurrentCount, activeCount)
        startedOrder.append(label)
    }

    func finish() {
        activeCount -= 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            maximumConcurrentCount: maximumConcurrentCount,
            startedOrder: startedOrder
        )
    }
}

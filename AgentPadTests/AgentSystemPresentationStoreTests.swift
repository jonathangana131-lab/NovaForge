import AgentDomain
import AgentEngine
import Foundation
import SwiftData
import XCTest
@testable import NovaForge

final class AgentSystemLiveOutputCenterTests: XCTestCase {
    func testStrictSequencePreservesTextAndRejectsReplay() async {
        let center = AgentSystemLiveOutputCenter()
        let runID = RunID(rawValue: presentationUUID(1))
        let attemptID = AttemptID(rawValue: presentationUUID(2))

        await center.receive(delta(
            runID: runID,
            attemptID: attemptID,
            sequence: 1,
            outputIndex: 0,
            text: "A"
        ))
        await center.receive(delta(
            runID: runID,
            attemptID: attemptID,
            sequence: 2,
            outputIndex: 1,
            text: "C"
        ))
        await center.receive(delta(
            runID: runID,
            attemptID: attemptID,
            sequence: 3,
            outputIndex: 0,
            text: "B"
        ))
        await center.receive(delta(
            runID: runID,
            attemptID: attemptID,
            sequence: 2,
            outputIndex: 1,
            text: "replayed"
        ))

        let snapshot = await center.snapshot(for: runID)
        XCTAssertEqual(
            snapshot,
            AgentSystemLiveTextSnapshot(
                runID: runID,
                attemptID: attemptID,
                revision: 3,
                text: "ABC"
            )
        )
    }

    func testNewAttemptAtomicallyReplacesPriorAttemptAndClearRemovesIt()
        async
    {
        let center = AgentSystemLiveOutputCenter()
        let runID = RunID(rawValue: presentationUUID(10))
        let firstAttempt = AttemptID(rawValue: presentationUUID(11))
        let retryAttempt = AttemptID(rawValue: presentationUUID(12))

        await center.receive(delta(
            runID: runID,
            attemptID: firstAttempt,
            sequence: 8,
            outputIndex: 0,
            text: "discarded attempt"
        ))
        await center.receive(delta(
            runID: runID,
            attemptID: retryAttempt,
            sequence: 1,
            outputIndex: 0,
            text: "retry"
        ))
        await center.receive(delta(
            runID: runID,
            attemptID: retryAttempt,
            sequence: 2,
            outputIndex: 0,
            text: " won"
        ))

        let snapshot = await center.snapshot(for: runID)
        XCTAssertEqual(
            snapshot,
            AgentSystemLiveTextSnapshot(
                runID: runID,
                attemptID: retryAttempt,
                revision: 2,
                text: "retry won"
            )
        )

        await center.clear(runID: runID)
        let cleared = await center.snapshot(for: runID)
        XCTAssertNil(cleared)
    }

    func testInvalidAndOverBudgetDeltasCannotMutateBuffer() async {
        let center = AgentSystemLiveOutputCenter()
        let runID = RunID(rawValue: presentationUUID(20))
        let attemptID = AttemptID(rawValue: presentationUUID(21))

        await center.receive(delta(
            runID: runID,
            attemptID: attemptID,
            sequence: 1,
            outputIndex: -1,
            text: "negative"
        ))
        await center.receive(delta(
            runID: runID,
            attemptID: attemptID,
            sequence: 2,
            outputIndex: 0,
            text: ""
        ))
        let invalidSnapshot = await center.snapshot(for: runID)
        XCTAssertNil(invalidSnapshot)

        let nearlyFull = String(
            repeating: "x",
            count: AgentSystemLiveOutputCenter
                .maximumTextUTF8BytesPerRun - 1
        )
        await center.receive(delta(
            runID: runID,
            attemptID: attemptID,
            sequence: 3,
            outputIndex: 0,
            text: nearlyFull
        ))
        await center.receive(delta(
            runID: runID,
            attemptID: attemptID,
            sequence: 4,
            outputIndex: 0,
            text: "yz"
        ))

        var snapshot = await center.snapshot(for: runID)
        XCTAssertEqual(snapshot?.revision, 1)
        XCTAssertEqual(snapshot?.text.utf8.count, nearlyFull.utf8.count)

        // Rejection does not advance the sequence fence. The next valid delta
        // can still fill the final byte without losing ordering.
        await center.receive(delta(
            runID: runID,
            attemptID: attemptID,
            sequence: 4,
            outputIndex: 0,
            text: "z"
        ))
        snapshot = await center.snapshot(for: runID)
        XCTAssertEqual(snapshot?.revision, 2)
        XCTAssertEqual(
            snapshot?.text.utf8.count,
            AgentSystemLiveOutputCenter.maximumTextUTF8BytesPerRun
        )
    }

    func testRunRetentionEvictsOldestRunOnly() async {
        let center = AgentSystemLiveOutputCenter()
        var runIDs: [RunID] = []

        for ordinal in 0...AgentSystemLiveOutputCenter.maximumRetainedRuns {
            let runID = RunID(rawValue: presentationUUID(100 + ordinal))
            runIDs.append(runID)
            await center.receive(delta(
                runID: runID,
                attemptID: AttemptID(
                    rawValue: presentationUUID(1_000 + ordinal)
                ),
                sequence: 1,
                outputIndex: 0,
                text: "\(ordinal)"
            ))
        }

        let evicted = await center.snapshot(for: runIDs[0])
        let firstRetained = await center.snapshot(for: runIDs[1])
        let newest = await center.snapshot(for: runIDs.last!)
        XCTAssertNil(evicted)
        XCTAssertNotNil(firstRetained)
        XCTAssertEqual(
            newest?.text,
            "\(AgentSystemLiveOutputCenter.maximumRetainedRuns)"
        )
    }

    private func delta(
        runID: RunID,
        attemptID: AttemptID,
        sequence: UInt64,
        outputIndex: Int,
        text: String
    ) -> AgentLiveTextDelta {
        AgentLiveTextDelta(
            runID: runID,
            attemptID: attemptID,
            eventSequence: sequence,
            outputIndex: outputIndex,
            text: text
        )
    }
}

@MainActor
final class AgentSystemPresentationStoreTests: XCTestCase {
    func testBindRequiresReadyHostAndRejectsDifferentContainerIdentity()
        async throws
    {
        let harness = PresentationStoreHarness()
        harness.hostReady = false
        let store = AgentSystemPresentationStore(
            dependencies: harness.dependencies()
        )
        let firstContainer = try makeContainer()

        await assertStoreError(.hostNotReady) {
            try await store.bind(container: firstContainer)
        }
        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(harness.makeBoundCallCount, 0)

        harness.hostReady = true
        try await store.bind(container: firstContainer)
        XCTAssertEqual(store.phase, .ready)
        XCTAssertNil(store.globalFailure)
        XCTAssertEqual(harness.makeBoundCallCount, 1)
        XCTAssertEqual(harness.materializeCallCount, 1)

        try await store.bind(container: firstContainer)
        XCTAssertEqual(harness.makeBoundCallCount, 1)
        XCTAssertEqual(harness.materializeCallCount, 1)

        let secondContainer = try makeContainer()
        await assertStoreError(.containerIdentityConflict) {
            try await store.bind(container: secondContainer)
        }
    }

    func testBindFailureIsFiniteAndSameContainerCanRecover() async throws {
        let harness = PresentationStoreHarness()
        harness.materializeError = .materialization
        let store = AgentSystemPresentationStore(
            dependencies: harness.dependencies()
        )
        let container = try makeContainer()

        await assertStoreError(.bindFailed) {
            try await store.bind(container: container)
        }
        XCTAssertEqual(store.phase, .failed)
        XCTAssertEqual(store.globalFailure, .startupUnavailable)
        XCTAssertEqual(harness.makeBoundCallCount, 1)

        harness.materializeError = nil
        try await store.bind(container: container)
        XCTAssertEqual(store.phase, .ready)
        XCTAssertNil(store.globalFailure)
        XCTAssertEqual(harness.makeBoundCallCount, 1)
        XCTAssertEqual(harness.materializeCallCount, 2)
    }

    func testBindAttachesRecoveredRunWithExactProjectionAndLiveText()
        async throws
    {
        let harness = PresentationStoreHarness()
        let handle = harness.installRun(
            seed: 200,
            projectID: ProjectID(rawValue: presentationUUID(201)),
            conversationID: ConversationID(
                rawValue: presentationUUID(202)
            ),
            workspaceID: WorkspaceID(rawValue: presentationUUID(203)),
            phase: .running,
            activityState: .running,
            sequence: 4,
            liveText: "restored live output"
        )
        harness.registered = [handle]
        let store = AgentSystemPresentationStore(
            dependencies: harness.dependencies()
        )

        try await store.bind(container: makeContainer())

        let scope = AgentSystemPresentationScope(
            projectID: handle.identity.projectID,
            conversationID: handle.identity.conversationID
        )
        let presentation = store.presentation(for: scope)
        XCTAssertEqual(presentation.activeGroup, harness.groups[handle.runID])
        XCTAssertEqual(
            presentation.liveText,
            harness.liveSnapshots[handle.runID]
        )
        XCTAssertTrue(presentation.isWorking)
        XCTAssertTrue(presentation.blocksCommand)
        XCTAssertFalse(presentation.isSynchronizing)
        XCTAssertEqual(
            store.activePresentation(in: handle.identity.workspaceID),
            presentation
        )
        XCTAssertEqual(harness.materializeCallCount, 2)
        XCTAssertEqual(harness.loadedScopes, [
            AgentActivityProjectionScope(
                projectID: handle.identity.projectID,
                conversationID: handle.identity.conversationID,
                runID: handle.runID
            ),
        ])

        let command = try XCTUnwrap(presentation.activeGroup).cancelCommand
        harness.updateRun(
            handle,
            phase: .completed,
            activityState: .succeeded,
            sequence: 5
        )
        _ = try await store.route(command)
        let completed = store.presentation(for: scope)
        XCTAssertEqual(completed.activeGroup?.state, .succeeded)
        XCTAssertEqual(completed.liveText?.text, "restored live output")
        XCTAssertFalse(completed.blocksCommand)

        await store.acknowledgeLiveHandoff(runID: handle.runID)
        XCTAssertEqual(store.presentation(for: scope).activeGroup?.state, .succeeded)
        XCTAssertNil(store.presentation(for: scope).liveText)
    }

    func testDuplicateActiveScopeFailsClosedWithoutHidingWorkspaceOwner()
        async throws
    {
        let harness = PresentationStoreHarness()
        let projectID = ProjectID(rawValue: presentationUUID(301))
        let conversationID = ConversationID(
            rawValue: presentationUUID(302)
        )
        let first = harness.installRun(
            seed: 310,
            projectID: projectID,
            conversationID: conversationID,
            workspaceID: WorkspaceID(rawValue: presentationUUID(311)),
            phase: .running,
            activityState: .running
        )
        let second = harness.installRun(
            seed: 320,
            projectID: projectID,
            conversationID: conversationID,
            workspaceID: WorkspaceID(rawValue: presentationUUID(321)),
            phase: .running,
            activityState: .running
        )
        harness.registered = [first, second]
        let store = AgentSystemPresentationStore(
            dependencies: harness.dependencies()
        )
        try await store.bind(container: makeContainer())

        let scope = AgentSystemPresentationScope(
            projectID: projectID,
            conversationID: conversationID
        )
        let conflicted = store.presentation(for: scope)
        XCTAssertNil(conflicted.activeGroup)
        XCTAssertNil(conflicted.liveText)
        XCTAssertEqual(conflicted.failure, .conflictingActiveRuns)
        XCTAssertNotNil(store.activePresentation(in: first.identity.workspaceID))
        XCTAssertNotNil(store.activePresentation(in: second.identity.workspaceID))

        for handle in [first, second] {
            let command = try XCTUnwrap(
                harness.groups[handle.runID]
            ).cancelCommand
            harness.updateRun(
                handle,
                phase: .completed,
                activityState: .succeeded,
                sequence: 2
            )
            _ = try await store.route(command)
        }
        XCTAssertEqual(store.presentation(for: scope).activeGroup?.state, .succeeded)
        XCTAssertNil(store.presentation(for: scope).failure)
    }

    func testFailedRecoveredRunClearsProvisionalTextImmediately()
        async throws
    {
        let harness = PresentationStoreHarness()
        let handle = harness.installRun(
            seed: 350,
            projectID: nil,
            conversationID: ConversationID(
                rawValue: presentationUUID(351)
            ),
            workspaceID: WorkspaceID(rawValue: presentationUUID(352)),
            phase: .failed,
            activityState: .failed,
            liveText: "must not survive failure"
        )
        harness.registered = [handle]
        let store = AgentSystemPresentationStore(
            dependencies: harness.dependencies()
        )
        try await store.bind(container: makeContainer())

        let scope = AgentSystemPresentationScope(
            projectID: nil,
            conversationID: handle.identity.conversationID
        )
        let failed = store.presentation(for: scope)
        XCTAssertEqual(failed.activeGroup?.state, .failed)
        XCTAssertNil(failed.liveText)
        XCTAssertFalse(failed.isWorking)
        XCTAssertFalse(failed.blocksCommand)
        XCTAssertEqual(harness.clearedLiveRunIDs, [handle.runID])
    }

    func testStartMaterializesExactRunAndSuccessfulLiveTextWaitsForHandoff()
        async throws
    {
        let harness = PresentationStoreHarness()
        harness.freshRunPhase = .running
        harness.freshActivityState = .running
        harness.freshLiveText = "provisional answer"
        let store = AgentSystemPresentationStore(
            dependencies: harness.dependencies()
        )
        try await store.bind(container: makeContainer())
        let input = makeStartInput(seed: 400, workspaceName: "PresentStart")

        let disposition = await store.start(
            prompt: "Build the exact requested change.",
            conversation: input.conversation,
            project: nil,
            workspace: input.workspace,
            settings: input.settings
        )
        guard case let .accepted(runID) = disposition else {
            return XCTFail("Expected presentation start to be accepted")
        }

        let scope = AgentSystemPresentationScope(
            project: nil,
            conversation: input.conversation
        )
        let running = store.presentation(for: scope)
        let group = try XCTUnwrap(running.activeGroup)
        XCTAssertEqual(group.identity.runID, runID)
        XCTAssertEqual(running.liveText?.text, "provisional answer")
        XCTAssertFalse(running.isAccepting)
        XCTAssertFalse(running.isSynchronizing)
        XCTAssertTrue(running.isWorking)
        XCTAssertNil(running.failure)
        XCTAssertEqual(harness.startedCommands.count, 1)
        XCTAssertEqual(harness.startedPlans.count, 1)
        XCTAssertEqual(harness.materializeCallCount, 2)

        let handle = try XCTUnwrap(harness.handles[runID])
        harness.updateRun(
            handle,
            phase: .completed,
            activityState: .succeeded,
            sequence: 2
        )
        let routed = try await store.route(group.cancelCommand)
        guard case .executed = routed else {
            return XCTFail("Expected injected execution result")
        }
        XCTAssertGreaterThanOrEqual(harness.materializeCallCount, 3)
        XCTAssertTrue(harness.clearedLiveRunIDs.isEmpty)
        XCTAssertNotNil(harness.liveSnapshots[runID])

        await store.acknowledgeLiveHandoff(runID: runID)
        XCTAssertEqual(harness.clearedLiveRunIDs, [runID])
        XCTAssertNil(harness.liveSnapshots[runID])
        XCTAssertEqual(store.presentation(for: scope).activeGroup?.state, .succeeded)
        XCTAssertNil(store.presentation(for: scope).liveText)
    }

    func testAutoContinuationUsesExactParentLineageAndTypedOrigin()
        async throws
    {
        let harness = PresentationStoreHarness()
        let input = makeStartInput(
            seed: 450,
            workspaceName: "AutoLineage"
        )
        let workspaceIdentity = try WorkspaceResourceIdentity(
            workspace: input.workspace
        )
        let parent = harness.installRun(
            seed: 451,
            projectID: nil,
            conversationID: ConversationID(
                rawValue: input.conversation.id
            ),
            workspaceID: WorkspaceID(
                rawValue: workspaceIdentity.persistentID
            ),
            phase: .completed,
            activityState: .succeeded,
            prompt: "Completed parent request."
        )
        harness.registered = [parent]
        let store = AgentSystemPresentationStore(
            dependencies: harness.dependencies()
        )
        try await store.bind(container: makeContainer())

        let disposition = await store.start(
            prompt: "Automatic next step.",
            conversation: input.conversation,
            project: nil,
            workspace: input.workspace,
            settings: input.settings,
            publicRequestSummary: "Continue automatically.",
            intent: .autoContinued
        )
        guard case .accepted = disposition,
              case let .send(send) = harness.startedCommands.last?.payload
        else { return XCTFail("Expected auto-continuation acceptance") }
        XCTAssertEqual(send.context.lineage.parentRunID, parent.runID)
        XCTAssertEqual(
            send.context.lineage.rootRunID,
            parent.identity.rootRunID
        )
        XCTAssertEqual(send.context.lineage.generation, 1)
        XCTAssertEqual(harness.startedPlans.last?.origin, .autoContinue)
        XCTAssertEqual(
            harness.startedPlans.last?.publicRequestSummary,
            "Continue automatically."
        )
    }

    func testRetryReusesAcceptedPromptAndCreatesExactRetryLineage()
        async throws
    {
        let harness = PresentationStoreHarness()
        let input = makeStartInput(
            seed: 470,
            workspaceName: "RetryLineage"
        )
        let workspaceIdentity = try WorkspaceResourceIdentity(
            workspace: input.workspace
        )
        let failed = harness.installRun(
            seed: 471,
            projectID: nil,
            conversationID: ConversationID(
                rawValue: input.conversation.id
            ),
            workspaceID: WorkspaceID(
                rawValue: workspaceIdentity.persistentID
            ),
            phase: .failed,
            activityState: .failed,
            prompt: "Retry this exact accepted request."
        )
        harness.registered = [failed]
        let store = AgentSystemPresentationStore(
            dependencies: harness.dependencies()
        )
        try await store.bind(container: makeContainer())
        let group = try XCTUnwrap(harness.groups[failed.runID])
        guard case let .retry(retry) = group.retryCommand else {
            return XCTFail("Expected retry command")
        }

        let disposition = await store.retry(
            retry,
            conversation: input.conversation,
            project: nil,
            workspace: input.workspace,
            settings: input.settings
        )
        guard case .accepted = disposition,
              case let .send(send) = harness.startedCommands.last?.payload,
              case let .message(message) = send.userItem.payload,
              case let .text(prompt) = message.content.first
        else { return XCTFail("Expected retry acceptance") }
        XCTAssertEqual(prompt, "Retry this exact accepted request.")
        XCTAssertEqual(send.context.lineage.retryOfRunID, failed.runID)
        XCTAssertEqual(
            send.context.lineage.rootRunID,
            failed.identity.rootRunID
        )
        XCTAssertEqual(harness.startedPlans.last?.origin, .retry)
    }

    func testConcurrentStartRejectsSecondScopeOwningSameWorkspace()
        async throws
    {
        let harness = PresentationStoreHarness()
        harness.freshRunPhase = .completed
        harness.freshActivityState = .succeeded
        let gate = PresentationStartGate()
        harness.startGate = gate
        let store = AgentSystemPresentationStore(
            dependencies: harness.dependencies()
        )
        try await store.bind(container: makeContainer())

        let first = makeStartInput(seed: 500, workspaceName: "SharedLane")
        let second = makeStartInput(seed: 501, workspaceName: "SharedLane")
        let firstScope = AgentSystemPresentationScope(
            project: nil,
            conversation: first.conversation
        )
        let secondScope = AgentSystemPresentationScope(
            project: nil,
            conversation: second.conversation
        )

        let firstTask = Task { @MainActor in
            await store.start(
                prompt: "First",
                conversation: first.conversation,
                project: nil,
                workspace: first.workspace,
                settings: first.settings
            )
        }
        try await eventually {
            store.presentation(for: firstScope).isAccepting
        }

        let blocked = await store.start(
            prompt: "Second",
            conversation: second.conversation,
            project: nil,
            workspace: second.workspace,
            settings: second.settings
        )
        XCTAssertEqual(blocked, .busy)
        XCTAssertEqual(
            store.presentation(for: secondScope).failure,
            .workspaceBusy
        )
        XCTAssertEqual(harness.startedCommands.count, 1)

        await gate.release()
        let accepted = await firstTask.value
        XCTAssertTrue(accepted.wasAccepted)
        XCTAssertFalse(store.presentation(for: firstScope).isAccepting)
    }

    func testStartMapsRequestRuntimeAndProjectionFailuresToFiniteValues()
        async throws
    {
        let harness = PresentationStoreHarness()
        let store = AgentSystemPresentationStore(
            dependencies: harness.dependencies()
        )
        try await store.bind(container: makeContainer())
        let input = makeStartInput(seed: 600, workspaceName: "FailureLane")
        let scope = AgentSystemPresentationScope(
            project: nil,
            conversation: input.conversation
        )

        let invalid = await store.start(
            prompt: " \n\t ",
            conversation: input.conversation,
            project: nil,
            workspace: input.workspace,
            settings: input.settings
        )
        XCTAssertEqual(invalid, .rejected(.requestInvalid))
        XCTAssertEqual(
            store.presentation(for: scope).failure,
            .requestInvalid
        )
        XCTAssertTrue(harness.startedCommands.isEmpty)

        let unsupportedSettings = AgentSettings(
            provider: .custom,
            modelID: "unsupported",
            activeWorkspaceName: input.workspace.workspaceName
        )
        let unsupported = await store.start(
            prompt: "Use an unsupported provider",
            conversation: input.conversation,
            project: nil,
            workspace: input.workspace,
            settings: unsupportedSettings
        )
        XCTAssertEqual(unsupported, .rejected(.providerUnsupported))
        XCTAssertEqual(
            store.presentation(for: scope).failure,
            .providerUnsupported
        )

        harness.startError = .start
        let runtimeFailure = await store.start(
            prompt: "Valid request",
            conversation: input.conversation,
            project: nil,
            workspace: input.workspace,
            settings: input.settings
        )
        XCTAssertEqual(runtimeFailure, .rejected(.runtimeUnavailable))
        XCTAssertEqual(
            store.presentation(for: scope).failure,
            .runtimeUnavailable
        )

        harness.startError = nil
        harness.omitFreshProjection = true
        let projectionFailure = await store.start(
            prompt: "Accepted without projection",
            conversation: input.conversation,
            project: nil,
            workspace: input.workspace,
            settings: input.settings
        )
        guard case let .accepted(synchronizingRunID) = projectionFailure else {
            return XCTFail("Projection lag must not erase engine acceptance")
        }
        XCTAssertEqual(
            store.presentation(for: scope).failure,
            .projectionUnavailable
        )
        XCTAssertFalse(store.presentation(for: scope).isAccepting)
        XCTAssertTrue(store.presentation(for: scope).isSynchronizing)
        XCTAssertTrue(store.presentation(for: scope).blocksCommand)

        let competing = makeStartInput(
            seed: 601,
            workspaceName: "FailureLane"
        )
        let reservedWorkspace = await store.start(
            prompt: "Must not enter a synchronizing workspace",
            conversation: competing.conversation,
            project: nil,
            workspace: competing.workspace,
            settings: competing.settings
        )
        XCTAssertEqual(reservedWorkspace, .busy)

        let synchronizingHandle = try XCTUnwrap(
            harness.handles[synchronizingRunID]
        )
        harness.installProjection(
            for: synchronizingHandle,
            phase: .running,
            activityState: .running,
            sequence: 2
        )
        try await eventually {
            !store.presentation(for: scope).isSynchronizing
        }
        XCTAssertEqual(store.presentation(for: scope).activeGroup?.state, .running)
        XCTAssertNil(store.presentation(for: scope).failure)

        let cleanupCommand = try XCTUnwrap(
            store.presentation(for: scope).activeGroup
        ).cancelCommand
        harness.updateRun(
            synchronizingHandle,
            phase: .completed,
            activityState: .succeeded,
            sequence: 3
        )
        _ = try await store.route(cleanupCommand)
    }

    func testRouteFailurePublishesFiniteCommandFailure() async throws {
        let harness = PresentationStoreHarness()
        let handle = harness.installRun(
            seed: 700,
            projectID: nil,
            conversationID: ConversationID(
                rawValue: presentationUUID(701)
            ),
            workspaceID: WorkspaceID(rawValue: presentationUUID(702)),
            phase: .running,
            activityState: .running
        )
        harness.registered = [handle]
        harness.routeError = .route
        let store = AgentSystemPresentationStore(
            dependencies: harness.dependencies()
        )
        try await store.bind(container: makeContainer())
        let group = try XCTUnwrap(harness.groups[handle.runID])

        do {
            _ = try await store.route(group.cancelCommand)
            XCTFail("Expected route failure")
        } catch {
            XCTAssertEqual(
                error as? AgentSystemActivityCommandRouterError,
                .dispatchUnavailable
            )
        }

        let scope = AgentSystemPresentationScope(
            projectID: nil,
            conversationID: handle.identity.conversationID
        )
        XCTAssertEqual(
            store.presentation(for: scope).failure,
            .commandUnavailable
        )

        harness.routeError = nil
        harness.updateRun(
            handle,
            phase: .completed,
            activityState: .succeeded,
            sequence: 2
        )
        _ = try await store.route(group.cancelCommand)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV4.self),
            migrationPlan: NovaForgeSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func makeStartInput(
        seed: Int,
        workspaceName: String
    ) -> (
        conversation: Conversation,
        workspace: SandboxWorkspace,
        settings: AgentSettings
    ) {
        let conversation = Conversation(title: "Presentation \(seed)")
        conversation.id = presentationUUID(seed)
        let workspace = SandboxWorkspace(name: workspaceName)
        let settings = AgentSettings(
            provider: .local,
            modelID: AIProvider.local.defaultModel,
            activeWorkspaceName: workspaceName
        )
        return (conversation, workspace, settings)
    }

    private func assertStoreError(
        _ expected: AgentSystemPresentationStoreError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected store error: \(expected)")
        } catch {
            XCTAssertEqual(
                error as? AgentSystemPresentationStoreError,
                expected
            )
        }
    }

    private func eventually(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for presentation state")
        throw PresentationHarnessError.timeout
    }
}

@MainActor
private final class PresentationStoreHarness {
    var hostReady = true
    var registered: [AgentSystemRunHandle] = []
    var handles: [RunID: AgentSystemRunHandle] = [:]
    var snapshots: [RunID: AgentDomain.AgentRunState] = [:]
    var groups: [RunID: AgentActivityGroup] = [:]
    var liveSnapshots: [RunID: AgentSystemLiveTextSnapshot] = [:]

    var materializeError: PresentationHarnessError?
    var registeredError: PresentationHarnessError?
    var snapshotError: PresentationHarnessError?
    var loadError: PresentationHarnessError?
    var routeError: PresentationHarnessError?
    var startError: PresentationHarnessError?
    var omitFreshProjection = false
    var startGate: PresentationStartGate?

    var freshRunPhase: AgentRunPhase = .running
    var freshActivityState: AgentActivityState = .running
    var freshLiveText: String?
    var routeResult = AgentSystemActivityCommandResult.executed(
        kind: .cancellation,
        commandID: CommandID(rawValue: presentationUUID(9_000))
    )

    private(set) var makeBoundCallCount = 0
    private(set) var materializeCallCount = 0
    private(set) var snapshotCallCount = 0
    private(set) var startedCommands: [AgentCommand] = []
    private(set) var startedPlans: [AgentSystemFreshRunPlan] = []
    private(set) var loadedScopes: [AgentActivityProjectionScope] = []
    private(set) var routedCommands: [AgentActivityCommand] = []
    private(set) var clearedLiveRunIDs: [RunID] = []

    func dependencies() -> AgentSystemPresentationStoreDependencies {
        AgentSystemPresentationStoreDependencies(
            hostIsReady: { [weak self] in
                self?.hostReady == true
            },
            registeredHandles: { [weak self] in
                guard let self else {
                    throw PresentationHarnessError.deallocated
                }
                if let registeredError { throw registeredError }
                return registered
            },
            start: { [weak self] command, plan in
                guard let self else {
                    throw PresentationHarnessError.deallocated
                }
                return try await self.start(command: command, plan: plan)
            },
            snapshot: { [weak self] handle in
                guard let self else {
                    throw PresentationHarnessError.deallocated
                }
                self.snapshotCallCount += 1
                if let snapshotError { throw snapshotError }
                guard let state = self.snapshots[handle.runID] else {
                    throw PresentationHarnessError.missingSnapshot
                }
                return state
            },
            makeBound: { [weak self] _ in
                guard let self else {
                    return Self.deallocatedBoundDependencies()
                }
                self.makeBoundCallCount += 1
                return AgentSystemPresentationBoundDependencies(
                    materialize: { [weak self] in
                        guard let self else {
                            throw PresentationHarnessError.deallocated
                        }
                        self.materializeCallCount += 1
                        if let materializeError { throw materializeError }
                    },
                    loadGroups: { [weak self] scope in
                        guard let self else {
                            throw PresentationHarnessError.deallocated
                        }
                        self.loadedScopes.append(scope)
                        if let loadError { throw loadError }
                        guard let runID = scope.runID,
                              let group = self.groups[runID]
                        else { return [] }
                        return [group]
                    },
                    route: { [weak self] command in
                        guard let self else {
                            throw PresentationHarnessError.deallocated
                        }
                        self.routedCommands.append(command)
                        if let routeError { throw routeError }
                        return self.routeResult
                    },
                    liveSnapshot: { [weak self] runID in
                        self?.liveSnapshots[runID]
                    },
                    clearLive: { [weak self] runID in
                        guard let self else { return }
                        self.clearedLiveRunIDs.append(runID)
                        self.liveSnapshots.removeValue(forKey: runID)
                    }
                )
            }
        )
    }

    @discardableResult
    func installRun(
        seed: Int,
        projectID: ProjectID?,
        conversationID: ConversationID,
        workspaceID: WorkspaceID,
        phase: AgentRunPhase,
        activityState: AgentActivityState,
        sequence: UInt64 = 1,
        liveText: String? = nil,
        prompt: String = "Harness accepted prompt."
    ) -> AgentSystemRunHandle {
        let runID = RunID(rawValue: presentationUUID(seed))
        let context = makeContext(
            runID: runID,
            projectID: projectID,
            conversationID: conversationID,
            workspaceID: workspaceID,
            seed: seed
        )
        let handle = AgentSystemRunHandle(
            identity: AgentSystemRunIdentity(context: context),
            ownerFence: AgentEngineOwnerFence(
                runID: runID,
                ownerID: presentationUUID(seed + 1),
                generation: 1
            )
        )
        handles[runID] = handle
        snapshots[runID] = makeState(
            context: context,
            phase: phase,
            sequence: sequence,
            seed: seed,
            userItem: ModelItem(
                id: ModelItemID(
                    rawValue: presentationUUID(seed + 50_000)
                ),
                createdAt: context.acceptedAt,
                payload: .message(ModelMessage(
                    role: .user,
                    content: [.text(prompt)]
                ))
            )
        )
        groups[runID] = makeGroup(
            handle: handle,
            state: activityState,
            sequence: sequence,
            seed: seed
        )
        if let liveText {
            liveSnapshots[runID] = AgentSystemLiveTextSnapshot(
                runID: runID,
                attemptID: AttemptID(
                    rawValue: presentationUUID(seed + 2)
                ),
                revision: sequence,
                text: liveText
            )
        }
        return handle
    }

    func updateRun(
        _ handle: AgentSystemRunHandle,
        phase: AgentRunPhase,
        activityState: AgentActivityState,
        sequence: UInt64
    ) {
        guard let context = snapshots[handle.runID]?.context else {
            XCTFail("Missing context for update")
            return
        }
        snapshots[handle.runID] = makeState(
            context: context,
            phase: phase,
            sequence: sequence,
            seed: Int(sequence) + 20_000
        )
        groups[handle.runID] = makeGroup(
            handle: handle,
            state: activityState,
            sequence: sequence,
            seed: Int(sequence) + 20_000
        )
    }

    func installProjection(
        for handle: AgentSystemRunHandle,
        phase: AgentRunPhase,
        activityState: AgentActivityState,
        sequence: UInt64
    ) {
        guard let context = snapshots[handle.runID]?.context else {
            XCTFail("Missing context for projection")
            return
        }
        snapshots[handle.runID] = makeState(
            context: context,
            phase: phase,
            sequence: sequence,
            seed: Int(sequence) + 40_000
        )
        groups[handle.runID] = makeGroup(
            handle: handle,
            state: activityState,
            sequence: sequence,
            seed: Int(sequence) + 40_000
        )
        omitFreshProjection = false
    }

    private func start(
        command: AgentCommand,
        plan: AgentSystemFreshRunPlan
    ) async throws -> AgentSystemRunHandle {
        startedCommands.append(command)
        startedPlans.append(plan)
        if let startError { throw startError }
        guard case let .send(send) = command.payload else {
            throw PresentationHarnessError.invalidCommand
        }
        let context = send.context
        let runID = context.lineage.runID
        let handle = AgentSystemRunHandle(
            identity: AgentSystemRunIdentity(context: context),
            ownerFence: AgentEngineOwnerFence(
                runID: runID,
                ownerID: presentationUUID(30_000 + startedCommands.count),
                generation: 1
            )
        )
        handles[runID] = handle
        snapshots[runID] = makeState(
            context: context,
            phase: freshRunPhase,
            sequence: 1,
            seed: 31_000 + startedCommands.count,
            userItem: send.userItem
        )
        if !omitFreshProjection {
            groups[runID] = makeGroup(
                handle: handle,
                state: freshActivityState,
                sequence: 1,
                seed: 32_000 + startedCommands.count
            )
        }
        if let freshLiveText {
            liveSnapshots[runID] = AgentSystemLiveTextSnapshot(
                runID: runID,
                attemptID: AttemptID(rawValue: presentationUUID(33_000)),
                revision: 1,
                text: freshLiveText
            )
        }
        if let startGate { await startGate.wait() }
        return handle
    }

    private func makeContext(
        runID: RunID,
        projectID: ProjectID?,
        conversationID: ConversationID,
        workspaceID: WorkspaceID,
        seed: Int
    ) -> AgentRunContext {
        AgentRunContext(
            lineage: .root(runID),
            conversationID: conversationID,
            projectID: projectID,
            workspaceID: workspaceID,
            executionNodeID: ExecutionNodeID(
                rawValue: presentationUUID(seed + 3)
            ),
            engineVersion: .agentHarnessV2,
            acceptedAt: AgentInstant(rawValue: Int64(seed)),
            features: AgentFeatureSet([]),
            cancellation: CancellationLineage(
                scopeID: CancellationScopeID(
                    rawValue: presentationUUID(seed + 4)
                )
            ),
            initialBudget: AgentBudget(limits: .standard)
        )
    }

    private func makeState(
        context: AgentRunContext,
        phase: AgentRunPhase,
        sequence: UInt64,
        seed: Int,
        userItem: ModelItem? = nil
    ) -> AgentDomain.AgentRunState {
        AgentDomain.AgentRunState(
            context: context,
            phase: phase,
            lastSequence: EventSequence(rawValue: sequence),
            lastEventID: EventID(rawValue: presentationUUID(seed + 5)),
            appliedEventIDs: [
                EventID(rawValue: presentationUUID(seed + 5)),
            ],
            terminalEventID: phase.isTerminal
                ? EventID(rawValue: presentationUUID(seed + 5))
                : nil,
            modelItems: userItem.map { [$0] } ?? []
        )
    }

    private func makeGroup(
        handle: AgentSystemRunHandle,
        state: AgentActivityState,
        sequence: UInt64,
        seed: Int
    ) -> AgentActivityGroup {
        let eventID = EventID(rawValue: presentationUUID(seed + 6))
        let eventSequence = EventSequence(rawValue: sequence)
        let instant = AgentInstant(rawValue: Int64(seed))
        return AgentActivityGroup(
            identity: AgentActivityRunIdentity(
                projectID: handle.identity.projectID,
                conversationID: handle.identity.conversationID,
                workspaceID: handle.identity.workspaceID,
                runID: handle.runID,
                rootRunID: handle.identity.rootRunID
            ),
            state: state,
            summary: "Presentation \(state.rawValue)",
            span: AgentActivityEventSpan(
                firstSequence: eventSequence,
                lastSequence: eventSequence,
                startedAt: instant,
                endedAt: instant
            ),
            items: [],
            attempts: [],
            approvals: [],
            artifacts: [],
            evidence: [],
            errorMessage: state == .failed ? "Finite failure" : nil,
            replayIdentity: AgentActivityReplayIdentity(
                orderedEventIDs: [eventID],
                orderedSequences: [eventSequence]
            )
        )
    }

    private static func deallocatedBoundDependencies()
        -> AgentSystemPresentationBoundDependencies
    {
        AgentSystemPresentationBoundDependencies(
            materialize: { throw PresentationHarnessError.deallocated },
            loadGroups: { _ in
                throw PresentationHarnessError.deallocated
            },
            route: { _ in throw PresentationHarnessError.deallocated },
            liveSnapshot: { _ in nil },
            clearLive: { _ in }
        )
    }
}

private actor PresentationStartGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private enum PresentationHarnessError: Error, Equatable {
    case materialization
    case start
    case route
    case deallocated
    case invalidCommand
    case missingSnapshot
    case timeout
}

private func presentationUUID(_ value: Int) -> UUID {
    let normalized = UInt64(truncatingIfNeeded: value)
    return UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        UInt8((normalized >> 56) & 0xff),
        UInt8((normalized >> 48) & 0xff),
        UInt8((normalized >> 40) & 0xff),
        UInt8((normalized >> 32) & 0xff),
        UInt8((normalized >> 24) & 0xff),
        UInt8((normalized >> 16) & 0xff),
        UInt8((normalized >> 8) & 0xff),
        UInt8(normalized & 0xff)
    ))
}

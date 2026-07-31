import AgentDomain
import AgentEngine
import AgentProviders
import AgentTools
import Foundation
import XCTest
@testable import NovaForge

final class AgentSystemTests: XCTestCase {
    func testConcurrentSharedBootstrapJoinsOnceAndPublishesRecoveryFIFOOnlyWhenReady() async throws {
        let fixtures = [
            AgentSystemTestFixture(seed: 3),
            AgentSystemTestFixture(seed: 1),
            AgentSystemTestFixture(seed: 2),
        ]
        let gate = AgentSystemTestGate()
        let preparer = AgentSystemFakeRecoveryQueuePreparer(
            runIDs: fixtures.map(\.runID),
            gate: gate
        )
        let bank = AgentSystemFakeEngineBank(
            recoveryContexts: Dictionary(
                uniqueKeysWithValues: fixtures.map { ($0.runID, $0.context) }
            )
        )
        let system = AgentSystem()
        let compositionID = agentSystemRawUUID(900_001)
        let composition = AgentSystemProductionComposition(
            id: compositionID,
            engineFactory: bank.factory,
            recoveryQueuePreparer: preparer
        )

        await assertAgentSystemError(.startupUnconfigured) {
            try await system.start(fixtures[0].sendCommand)
        }
        await assertAgentSystemError(.startupUnconfigured) {
            try await system.recoverAcceptedRuns()
        }

        let first = Task { try await system.installAndReconcile(composition) }
        try await waitUntil { await preparer.callCount() == 1 }
        let second = Task { try await system.installAndReconcile(composition) }

        await assertAgentSystemError(
            .startupReconciliationInProgress(compositionID)
        ) {
            try await system.start(fixtures[0].sendCommand)
        }
        let buildCountWhileReconciling = await bank.buildCount()
        XCTAssertEqual(buildCountWhileReconciling, 0)

        await gate.open()
        let firstReport = try await first.value
        let secondReport = try await second.value
        XCTAssertEqual(firstReport, secondReport)
        XCTAssertEqual(firstReport.compositionID, compositionID)
        XCTAssertEqual(firstReport.recoveryFIFO, fixtures.map(\.runID))
        let prepareCount = await preparer.callCount()
        XCTAssertEqual(prepareCount, 1)

        let ignoredPreparer = AgentSystemFakeRecoveryQueuePreparer(runIDs: [])
        let ignoredComposition = AgentSystemProductionComposition(
            id: compositionID,
            engineFactory: .unavailable,
            recoveryQueuePreparer: ignoredPreparer
        )
        let thirdReport = try await system.installAndReconcile(
            ignoredComposition
        )
        XCTAssertEqual(thirdReport, firstReport)
        let ignoredPrepareCount = await ignoredPreparer.callCount()
        XCTAssertEqual(ignoredPrepareCount, 0)

        await assertAgentSystemError(
            .runAwaitingRecovery(fixtures[0].runID)
        ) {
            try await system.start(fixtures[0].sendCommand)
        }
        let buildCountBeforeRecovery = await bank.buildCount()
        XCTAssertEqual(buildCountBeforeRecovery, 0)

        let handles = try await system.recoverAcceptedRuns()
        XCTAssertEqual(handles.map(\.runID), fixtures.map(\.runID))
        let requests = await bank.requests()
        XCTAssertEqual(
            requests,
            fixtures.map { .recovery(runID: $0.runID) }
        )
        await assertAgentSystemError(.startupInstallationTooLate) {
            try await system.installAndReconcile(composition)
        }
    }

    func testConcurrentDifferentCompositionCannotReplaceReconcilingAuthorities() async throws {
        let gate = AgentSystemTestGate()
        let activePreparer = AgentSystemFakeRecoveryQueuePreparer(
            runIDs: [],
            gate: gate
        )
        let rejectedPreparer = AgentSystemFakeRecoveryQueuePreparer(runIDs: [])
        let activeBank = AgentSystemFakeEngineBank()
        let rejectedBank = AgentSystemFakeEngineBank()
        let system = AgentSystem()
        let activeID = agentSystemRawUUID(900_101)
        let rejectedID = agentSystemRawUUID(900_102)
        let active = AgentSystemProductionComposition(
            id: activeID,
            engineFactory: activeBank.factory,
            recoveryQueuePreparer: activePreparer
        )
        let rejected = AgentSystemProductionComposition(
            id: rejectedID,
            engineFactory: rejectedBank.factory,
            recoveryQueuePreparer: rejectedPreparer
        )

        let installation = Task {
            try await system.installAndReconcile(active)
        }
        try await waitUntil { await activePreparer.callCount() == 1 }
        await assertAgentSystemError(
            .startupCompositionConflict(
                active: activeID,
                requested: rejectedID
            )
        ) {
            try await system.installAndReconcile(rejected)
        }
        let rejectedPreparationCount = await rejectedPreparer.callCount()
        let activeBuildCount = await activeBank.buildCount()
        let rejectedBuildCount = await rejectedBank.buildCount()
        XCTAssertEqual(rejectedPreparationCount, 0)
        XCTAssertEqual(activeBuildCount, 0)
        XCTAssertEqual(rejectedBuildCount, 0)

        await gate.open()
        _ = try await installation.value
    }

    func testReconcilerRejectedPreterminalQueueMakesBootstrapFailedAndGatesEngines() async {
        let fixture = AgentSystemTestFixture(seed: 4)
        let preparer = AgentSystemFakeRecoveryQueuePreparer(
            runIDs: [],
            failure: .invalidPreterminalQueue
        )
        let bank = AgentSystemFakeEngineBank()
        let system = AgentSystem()
        let compositionID = agentSystemRawUUID(900_201)
        let composition = AgentSystemProductionComposition(
            id: compositionID,
            engineFactory: bank.factory,
            recoveryQueuePreparer: preparer
        )

        await assertAgentSystemError(
            .startupReconciliationFailed(compositionID)
        ) {
            try await system.installAndReconcile(composition)
        }
        await assertAgentSystemError(
            .startupReconciliationFailed(compositionID)
        ) {
            try await system.start(fixture.sendCommand)
        }
        await assertAgentSystemError(
            .startupReconciliationFailed(compositionID)
        ) {
            try await system.recoverAcceptedRuns()
        }
        await assertAgentSystemError(
            .startupReconciliationFailed(compositionID)
        ) {
            try await system.installAndReconcile(composition)
        }
        let buildCount = await bank.buildCount()
        let prepareCount = await preparer.callCount()
        XCTAssertEqual(buildCount, 0)
        XCTAssertEqual(prepareCount, 1)
    }

    func testProductionInstallAfterInjectedRuntimeHasRegisteredWorkFailsClosed() async throws {
        let fixture = AgentSystemTestFixture(seed: 5)
        let bank = AgentSystemFakeEngineBank()
        let system = AgentSystem(engineFactory: bank.factory)
        _ = try await system.start(fixture.sendCommand)

        let preparer = AgentSystemFakeRecoveryQueuePreparer(runIDs: [])
        let composition = AgentSystemProductionComposition(
            id: agentSystemRawUUID(900_301),
            engineFactory: .unavailable,
            recoveryQueuePreparer: preparer
        )
        await assertAgentSystemError(.startupInstallationTooLate) {
            try await system.installAndReconcile(composition)
        }
        let preparationCount = await preparer.callCount()
        XCTAssertEqual(preparationCount, 0)
    }

    func testConcurrentDuplicateStartBuildsAndStartsExactlyOneEngine() async throws {
        let fixture = AgentSystemTestFixture(seed: 1)
        let startGate = AgentSystemTestGate()
        let bank = AgentSystemFakeEngineBank(startGate: startGate)
        let observations = AgentSystemObservationRecorder()
        let system = AgentSystem(
            engineFactory: bank.factory,
            observer: { observations.record($0) }
        )

        let first = Task { try await system.start(fixture.sendCommand) }
        let second = Task { try await system.start(fixture.sendCommand) }
        let engine = try await bank.waitForEngine(runID: fixture.runID)
        try await waitUntil { await engine.startCallCount() == 1 }
        await startGate.open()

        let firstHandle = try await first.value
        let secondHandle = try await second.value
        let buildCount = await bank.buildCount()
        let startCount = await engine.startCallCount()
        let registered = await system.registeredHandles()
        XCTAssertEqual(firstHandle, secondHandle)
        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(registered, [firstHandle])
        XCTAssertEqual(observations.values().map(\.kind), [.accepted])
        XCTAssertEqual(firstHandle.identity, .init(context: fixture.context))
    }

    func testFreshRunPlanIsIdempotentAndCannotDriftForSameCommand()
        async throws
    {
        let fixture = AgentSystemTestFixture(seed: 7)
        let gate = AgentSystemTestGate()
        let bank = AgentSystemFakeEngineBank(startGate: gate)
        let system = AgentSystem(engineFactory: bank.factory)
        let plan = agentSystemFreshRunPlan(model: "model-a")

        let first = Task {
            try await system.start(fixture.sendCommand, plan: plan)
        }
        let second = Task {
            try await system.start(fixture.sendCommand, plan: plan)
        }
        _ = try await bank.waitForEngine(runID: fixture.runID)
        await gate.open()
        let firstHandle = try await first.value
        let secondHandle = try await second.value
        XCTAssertEqual(firstHandle, secondHandle)

        let requests = await bank.requests()
        XCTAssertEqual(requests.count, 1)
        guard case let .fresh(context, capturedCommand, capturedPlan) =
            requests[0]
        else { return XCTFail("Expected one fresh engine build") }
        XCTAssertEqual(context, fixture.context)
        XCTAssertEqual(capturedCommand, fixture.sendCommand)
        XCTAssertEqual(capturedPlan, plan)

        await assertAgentSystemError(
            .freshRunPlanCollision(fixture.sendCommand.header.commandID)
        ) {
            try await system.start(
                fixture.sendCommand,
                plan: agentSystemFreshRunPlan(model: "model-b")
            )
        }
        await assertAgentSystemError(
            .freshRunPlanCollision(fixture.sendCommand.header.commandID)
        ) {
            try await system.start(
                fixture.sendCommand,
                plan: agentSystemFreshRunPlan(
                    model: "model-a",
                    systemInstruction: "different system authority"
                )
            )
        }
        let buildCount = await bank.buildCount()
        XCTAssertEqual(buildCount, 1)
    }

    func testCommandIDCollisionAndSecondAcceptanceForRunFailClosed() async throws {
        let fixture = AgentSystemTestFixture(seed: 10)
        let bank = AgentSystemFakeEngineBank()
        let system = AgentSystem(engineFactory: bank.factory)
        _ = try await system.start(fixture.sendCommand)

        let conflictingIdentity = AgentSystemTestFixture(
            seed: 11,
            commandID: fixture.sendCommand.header.commandID
        )
        await assertAgentSystemError(
            .commandIDCollision(fixture.sendCommand.header.commandID)
        ) {
            try await system.start(conflictingIdentity.sendCommand)
        }

        let sameRunNewCommand = fixture.sendCommandReplacingCommandID(
            agentSystemTagged(9_999)
        )
        await assertAgentSystemError(.runAlreadyRegistered(fixture.runID)) {
            try await system.start(sameRunNewCommand)
        }
        let buildCount = await bank.buildCount()
        XCTAssertEqual(buildCount, 1)
    }

    func testExactIdentityAndOwnerFenceAreRequiredForEveryLookup() async throws {
        let fixture = AgentSystemTestFixture(seed: 20)
        let bank = AgentSystemFakeEngineBank()
        let system = AgentSystem(engineFactory: bank.factory)
        let handle = try await system.start(fixture.sendCommand)
        let engine = try await bank.waitForEngine(runID: fixture.runID)
        let forged = AgentSystemRunHandle(
            identity: handle.identity,
            ownerFence: AgentEngineOwnerFence(
                runID: fixture.runID,
                ownerID: handle.ownerFence.ownerID,
                generation: handle.ownerFence.generation + 1
            )
        )

        await assertAgentSystemError(.staleHandle(fixture.runID)) {
            try await system.snapshot(for: forged)
        }
        let snapshotCount = await engine.snapshotCallCount()
        XCTAssertEqual(snapshotCount, 1)

        let unknownFixture = AgentSystemTestFixture(seed: 21)
        let unknown = AgentSystemRunHandle(
            identity: .init(context: unknownFixture.context),
            ownerFence: .init(
                runID: unknownFixture.runID,
                ownerID: agentSystemRawUUID(21_999),
                generation: 1
            )
        )
        await assertAgentSystemError(.runNotRegistered(unknownFixture.runID)) {
            try await system.wait(for: unknown)
        }
    }

    func testCancelWaitsForDrainAndSuppressesLateRegressingWaitCallback() async throws {
        let fixture = AgentSystemTestFixture(seed: 30)
        let waitGate = AgentSystemTestGate()
        let cancelGate = AgentSystemTestGate()
        let bank = AgentSystemFakeEngineBank(
            waitGate: waitGate,
            cancelGate: cancelGate
        )
        let observations = AgentSystemObservationRecorder()
        let system = AgentSystem(
            engineFactory: bank.factory,
            observer: { observations.record($0) }
        )
        let handle = try await system.start(fixture.sendCommand)
        let engine = try await bank.waitForEngine(runID: fixture.runID)

        let lateWait = Task { try await system.wait(for: handle) }
        try await waitUntil { await engine.waitCallCount() == 1 }

        let cancelCommand = fixture.cancelCommand(commandSeed: 30_700)
        let cancellation = Task {
            try await system.cancel(cancelCommand, for: handle)
        }
        try await waitUntil { await engine.cancelCallCount() == 1 }
        let phaseWhileDraining = await engine.currentPhase()
        XCTAssertEqual(phaseWhileDraining, .running)

        await cancelGate.open()
        let cancelled = try await cancellation.value
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertEqual(cancelled.lastSequence, EventSequence(rawValue: 3))

        await waitGate.open()
        let lateResult = try await lateWait.value
        let cancelCount = await engine.cancelCallCount()
        let activeHandles = await system.activeHandles()
        XCTAssertEqual(lateResult.phase, .cancelled)
        XCTAssertEqual(lateResult.lastSequence, EventSequence(rawValue: 3))
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(
            observations.values().map(\.kind),
            [.accepted, .cancellationSettled]
        )
        XCTAssertEqual(activeHandles, [])
    }

    func testConcurrentDuplicateApprovalDeliveryExecutesOnce() async throws {
        let fixture = AgentSystemTestFixture(seed: 40)
        let approvalGate = AgentSystemTestGate()
        let bank = AgentSystemFakeEngineBank(approvalGate: approvalGate)
        let observations = AgentSystemObservationRecorder()
        let system = AgentSystem(
            engineFactory: bank.factory,
            observer: { observations.record($0) }
        )
        let handle = try await system.start(fixture.sendCommand)
        let engine = try await bank.waitForEngine(runID: fixture.runID)
        let approval = fixture.approvalCommand(commandSeed: 40_700)

        let first = Task {
            try await system.deliverApprovalDecision(approval, for: handle)
        }
        let second = Task {
            try await system.deliverApprovalDecision(approval, for: handle)
        }
        try await waitUntil { await engine.approvalCallCount() == 1 }
        await approvalGate.open()
        try await first.value
        try await second.value

        let approvalCount = await engine.approvalCallCount()
        XCTAssertEqual(approvalCount, 1)
        XCTAssertEqual(
            observations.values().map(\.kind),
            [.accepted, .approvalDelivered]
        )

        let collision = fixture.cancelCommand(
            commandSeed: 40_701,
            commandID: approval.header.commandID
        )
        await assertAgentSystemError(
            .commandIDCollision(approval.header.commandID)
        ) {
            try await system.cancel(collision, for: handle)
        }
    }

    func testRecoveryUsesScannerFIFOAndReusesAlreadyOwnedNonterminalRuns() async throws {
        let fixtures = [
            AgentSystemTestFixture(seed: 53),
            AgentSystemTestFixture(seed: 51),
            AgentSystemTestFixture(seed: 52),
        ]
        let scanner = AgentSystemFakeRecoveryScanner(
            runIDs: fixtures.map(\.runID)
        )
        let bank = AgentSystemFakeEngineBank(
            recoveryContexts: Dictionary(
                uniqueKeysWithValues: fixtures.map { ($0.runID, $0.context) }
            )
        )
        let observations = AgentSystemObservationRecorder()
        let system = AgentSystem(
            engineFactory: bank.factory,
            recoveryScanner: scanner,
            observer: { observations.record($0) }
        )

        let handles = try await system.recoverAcceptedRuns()
        let requests = await bank.requests()
        XCTAssertEqual(handles.map(\.runID), fixtures.map(\.runID))
        XCTAssertEqual(
            requests,
            fixtures.map { .recovery(runID: $0.runID) }
        )
        XCTAssertEqual(
            observations.values().map(\.kind),
            [.recovered, .recovered, .recovered]
        )

        let again = try await system.recoverAcceptedRuns()
        let buildCount = await bank.buildCount()
        let scanCount = await scanner.callCount()
        XCTAssertEqual(again, handles)
        XCTAssertEqual(buildCount, 3)
        XCTAssertEqual(scanCount, 2)
    }

    func testDuplicateRecoveryQueueIsRejectedWithoutSecondOwner() async throws {
        let fixture = AgentSystemTestFixture(seed: 60)
        let duplicateScanner = AgentSystemFakeRecoveryScanner(
            runIDs: [fixture.runID, fixture.runID]
        )
        let duplicateBank = AgentSystemFakeEngineBank(
            recoveryContexts: [fixture.runID: fixture.context]
        )
        let duplicateSystem = AgentSystem(
            engineFactory: duplicateBank.factory,
            recoveryScanner: duplicateScanner
        )
        await assertAgentSystemError(.invalidRecoveryQueue(fixture.runID)) {
            try await duplicateSystem.recoverAcceptedRuns()
        }
        let duplicateBuildCount = await duplicateBank.buildCount()
        XCTAssertEqual(duplicateBuildCount, 1)
    }

    func testRecoveryTimeFailSafeTerminalIsRegisteredButNotActive() async throws {
        let terminalFixture = AgentSystemTestFixture(seed: 61)
        let terminalScanner = AgentSystemFakeRecoveryScanner(
            runIDs: [terminalFixture.runID]
        )
        let terminalBank = AgentSystemFakeEngineBank(
            recoveryContexts: [terminalFixture.runID: terminalFixture.context],
            terminalRecoveryRunIDs: [terminalFixture.runID]
        )
        let terminalSystem = AgentSystem(
            engineFactory: terminalBank.factory,
            recoveryScanner: terminalScanner
        )
        let handles = try await terminalSystem.recoverAcceptedRuns()
        XCTAssertEqual(handles.map(\.runID), [terminalFixture.runID])
        let terminalHandles = await terminalSystem.registeredHandles()
        let activeHandles = await terminalSystem.activeHandles()
        XCTAssertEqual(terminalHandles, handles)
        XCTAssertEqual(activeHandles, [])

        let again = try await terminalSystem.recoverAcceptedRuns()
        let buildCount = await terminalBank.buildCount()
        XCTAssertEqual(again, handles)
        XCTAssertEqual(buildCount, 1)
    }

    func testUnavailableCompositionAndCapacityLimitsFailBeforeSecondEngine() async throws {
        let unavailable = AgentSystem(engineFactory: .unavailable)
        let fixture = AgentSystemTestFixture(seed: 70)
        await assertAgentSystemError(.productionCompositionUnavailable) {
            try await unavailable.start(fixture.sendCommand)
        }
        let unavailableHandles = await unavailable.registeredHandles()
        XCTAssertEqual(unavailableHandles, [])

        let bank = AgentSystemFakeEngineBank()
        let bounded = AgentSystem(
            engineFactory: bank.factory,
            maximumRunCount: 1,
            maximumCommandCount: 2
        )
        _ = try await bounded.start(fixture.sendCommand)
        let second = AgentSystemTestFixture(seed: 71)
        await assertAgentSystemError(.registryCapacityExceeded) {
            try await bounded.start(second.sendCommand)
        }
        let buildCount = await bank.buildCount()
        XCTAssertEqual(buildCount, 1)
    }
}

private struct AgentSystemTestFixture: Sendable {
    let context: AgentRunContext
    let sendCommand: AgentCommand

    init(seed: UInt64, commandID: CommandID? = nil) {
        let runID: RunID = agentSystemTagged(seed * 100 + 1)
        let acceptedAt = AgentInstant(rawValue: 1_000_000 + Int64(seed))
        context = AgentRunContext(
            schemaVersion: .current,
            lineage: .root(runID),
            conversationID: agentSystemTagged(seed * 100 + 2),
            projectID: agentSystemTagged(seed * 100 + 3),
            workspaceID: agentSystemTagged(seed * 100 + 4),
            executionNodeID: agentSystemTagged(seed * 100 + 5),
            engineVersion: .agentHarnessV2,
            acceptedAt: acceptedAt,
            features: AgentFeatureSet(["m9-agent-system-test"]),
            cancellation: CancellationLineage(
                scopeID: agentSystemTagged(seed * 100 + 6)
            ),
            initialBudget: AgentBudget(limits: .standard)
        )
        let userItem = ModelItem(
            id: agentSystemTagged(seed * 100 + 7),
            createdAt: acceptedAt,
            payload: .message(ModelMessage(
                role: .user,
                content: [.text("Fixture \(seed)")]
            ))
        )
        sendCommand = AgentCommand(
            header: AgentCommandHeader(
                commandID: commandID ?? agentSystemTagged(seed * 100 + 8),
                schemaVersion: .current,
                runID: runID,
                issuedAt: acceptedAt,
                correlationID: agentSystemTagged(seed * 100 + 9)
            ),
            payload: .send(SendCommand(context: context, userItem: userItem))
        )
    }

    var runID: RunID { context.lineage.runID }

    func sendCommandReplacingCommandID(_ commandID: CommandID) -> AgentCommand {
        AgentCommand(
            header: AgentCommandHeader(
                commandID: commandID,
                schemaVersion: sendCommand.header.schemaVersion,
                runID: sendCommand.header.runID,
                issuedAt: sendCommand.header.issuedAt,
                correlationID: sendCommand.header.correlationID,
                causationID: sendCommand.header.causationID
            ),
            payload: sendCommand.payload
        )
    }

    func cancelCommand(
        commandSeed: UInt64,
        commandID: CommandID? = nil
    ) -> AgentCommand {
        AgentCommand(
            header: AgentCommandHeader(
                commandID: commandID ?? agentSystemTagged(commandSeed),
                schemaVersion: .current,
                runID: runID,
                issuedAt: AgentInstant(rawValue: context.acceptedAt.rawValue + 10),
                correlationID: sendCommand.header.correlationID
            ),
            payload: .cancel(CancelCommand(reason: .userRequested))
        )
    }

    func approvalCommand(commandSeed: UInt64) -> AgentCommand {
        AgentCommand(
            header: AgentCommandHeader(
                commandID: agentSystemTagged(commandSeed),
                schemaVersion: .current,
                runID: runID,
                issuedAt: AgentInstant(rawValue: context.acceptedAt.rawValue + 20),
                correlationID: sendCommand.header.correlationID
            ),
            payload: .approvalDecision(ApprovalDecisionCommand(
                requestID: agentSystemTagged(commandSeed + 1),
                callID: agentSystemTagged(commandSeed + 2),
                decision: .approved,
                decidedAt: AgentInstant(rawValue: context.acceptedAt.rawValue + 20)
            ))
        )
    }
}

private actor AgentSystemFakeEngine: AgentSystemEngineControlling {
    private let configuredContext: AgentRunContext?
    private let startGate: AgentSystemTestGate?
    private let waitGate: AgentSystemTestGate?
    private let cancelGate: AgentSystemTestGate?
    private let approvalGate: AgentSystemTestGate?
    private let terminalOnRecovery: Bool

    private var state: AgentDomain.AgentRunState
    private var handle: AgentEngineRunHandle?
    private var starts = 0
    private var recoveries = 0
    private var waits = 0
    private var snapshots = 0
    private var cancellations = 0
    private var approvals = 0

    init(
        context: AgentRunContext?,
        startGate: AgentSystemTestGate?,
        waitGate: AgentSystemTestGate?,
        cancelGate: AgentSystemTestGate?,
        approvalGate: AgentSystemTestGate?,
        terminalOnRecovery: Bool
    ) {
        configuredContext = context
        self.startGate = startGate
        self.waitGate = waitGate
        self.cancelGate = cancelGate
        self.approvalGate = approvalGate
        self.terminalOnRecovery = terminalOnRecovery
        state = AgentDomain.AgentRunState()
    }

    func agentSystemStart(
        _ command: AgentCommand
    ) async throws -> AgentEngineRunHandle {
        starts += 1
        if let startGate { await startGate.wait() }
        guard case let .send(send) = command.payload else {
            throw AgentSystemError.invalidCommand
        }
        let engineHandle = Self.makeHandle(
            runID: send.context.lineage.runID,
            generation: 1
        )
        handle = engineHandle
        state = Self.makeState(context: send.context, phase: .running, sequence: 2)
        return engineHandle
    }

    func agentSystemRecover(
        runID: RunID
    ) async throws -> AgentEngineRunHandle {
        recoveries += 1
        guard let configuredContext, configuredContext.lineage.runID == runID else {
            throw AgentSystemError.engineIdentityMismatch(runID)
        }
        let engineHandle = Self.makeHandle(runID: runID, generation: 2)
        handle = engineHandle
        state = Self.makeState(
            context: configuredContext,
            phase: terminalOnRecovery ? .interrupted : .running,
            sequence: terminalOnRecovery ? 9 : 2
        )
        return engineHandle
    }

    func agentSystemWait(
        for handle: AgentEngineRunHandle
    ) async throws -> AgentDomain.AgentRunState {
        try require(handle)
        waits += 1
        let captured = state
        if let waitGate { await waitGate.wait() }
        return captured
    }

    func agentSystemSnapshot(
        for handle: AgentEngineRunHandle
    ) async throws -> AgentDomain.AgentRunState {
        try require(handle)
        snapshots += 1
        return state
    }

    func agentSystemCancel(
        _ command: CancelCommand,
        runID: RunID
    ) async throws -> AgentDomain.AgentRunState {
        guard handle?.runID == runID else {
            throw AgentSystemError.engineIdentityMismatch(runID)
        }
        cancellations += 1
        if let cancelGate { await cancelGate.wait() }
        state.phase = .cancelled
        state.lastSequence = EventSequence(rawValue: 3)
        return state
    }

    func agentSystemDeliverApprovalDecision(
        _ command: ApprovalDecisionCommand,
        runID: RunID
    ) async throws {
        guard handle?.runID == runID else {
            throw AgentSystemError.engineIdentityMismatch(runID)
        }
        approvals += 1
        if let approvalGate { await approvalGate.wait() }
    }

    func startCallCount() -> Int { starts }
    func recoveryCallCount() -> Int { recoveries }
    func waitCallCount() -> Int { waits }
    func snapshotCallCount() -> Int { snapshots }
    func cancelCallCount() -> Int { cancellations }
    func approvalCallCount() -> Int { approvals }
    func currentPhase() -> AgentRunPhase { state.phase }

    private func require(_ candidate: AgentEngineRunHandle) throws {
        guard handle == candidate else {
            throw AgentSystemError.staleHandle(candidate.runID)
        }
    }

    private static func makeHandle(
        runID: RunID,
        generation: UInt64
    ) -> AgentEngineRunHandle {
        AgentEngineRunHandle(
            runID: runID,
            ownerFence: AgentEngineOwnerFence(
                runID: runID,
                ownerID: agentSystemRawUUID(
                    UInt64(runID.rawValue.uuid.15) + generation * 1_000
                ),
                generation: generation
            )
        )
    }

    private static func makeState(
        context: AgentRunContext,
        phase: AgentRunPhase,
        sequence: UInt64
    ) -> AgentDomain.AgentRunState {
        AgentDomain.AgentRunState(
            schemaVersion: context.schemaVersion,
            context: context,
            phase: phase,
            lastSequence: EventSequence(rawValue: sequence),
            budget: context.initialBudget
        )
    }
}

private actor AgentSystemFakeEngineBank {
    private let startGate: AgentSystemTestGate?
    private let waitGate: AgentSystemTestGate?
    private let cancelGate: AgentSystemTestGate?
    private let approvalGate: AgentSystemTestGate?
    private let recoveryContexts: [RunID: AgentRunContext]
    private let terminalRecoveryRunIDs: Set<RunID>
    private var buildRequests: [AgentSystemEngineBuildRequest] = []
    private var engines: [RunID: AgentSystemFakeEngine] = [:]

    init(
        startGate: AgentSystemTestGate? = nil,
        waitGate: AgentSystemTestGate? = nil,
        cancelGate: AgentSystemTestGate? = nil,
        approvalGate: AgentSystemTestGate? = nil,
        recoveryContexts: [RunID: AgentRunContext] = [:],
        terminalRecoveryRunIDs: Set<RunID> = []
    ) {
        self.startGate = startGate
        self.waitGate = waitGate
        self.cancelGate = cancelGate
        self.approvalGate = approvalGate
        self.recoveryContexts = recoveryContexts
        self.terminalRecoveryRunIDs = terminalRecoveryRunIDs
    }

    nonisolated var factory: AgentSystemEngineFactory {
        AgentSystemEngineFactory(buildController: { request in
            try await self.build(request)
        })
    }

    func build(
        _ request: AgentSystemEngineBuildRequest
    ) throws -> any AgentSystemEngineControlling {
        buildRequests.append(request)
        let context: AgentRunContext?
        switch request {
        case let .fresh(freshContext, _, _): context = freshContext
        case let .recovery(runID):
            guard let recovered = recoveryContexts[runID] else {
                throw AgentSystemError.engineIdentityMismatch(runID)
            }
            context = recovered
        }
        let engine = AgentSystemFakeEngine(
            context: context,
            startGate: startGate,
            waitGate: waitGate,
            cancelGate: cancelGate,
            approvalGate: approvalGate,
            terminalOnRecovery: terminalRecoveryRunIDs.contains(request.runID)
        )
        engines[request.runID] = engine
        return engine
    }

    func waitForEngine(runID: RunID) async throws -> AgentSystemFakeEngine {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let engine = engines[runID] { return engine }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw AgentSystemTestError.timeout
    }

    func buildCount() -> Int { buildRequests.count }
    func requests() -> [AgentSystemEngineBuildRequest] { buildRequests }
}

private actor AgentSystemFakeRecoveryScanner: AgentAcceptedNonterminalRunScanning {
    private let runIDs: [RunID]
    private var calls = 0

    init(runIDs: [RunID]) { self.runIDs = runIDs }

    func acceptedNonterminalRunIDs() -> [RunID] {
        calls += 1
        return runIDs
    }

    func callCount() -> Int { calls }
}

private actor AgentSystemFakeRecoveryQueuePreparer:
    AgentRecoveryQueuePreparing
{
    private let runIDs: [RunID]
    private let gate: AgentSystemTestGate?
    private let failure: AgentSystemTestError?
    private var calls = 0

    init(
        runIDs: [RunID],
        gate: AgentSystemTestGate? = nil,
        failure: AgentSystemTestError? = nil
    ) {
        self.runIDs = runIDs
        self.gate = gate
        self.failure = failure
    }

    func prepareRecoveryQueue() async throws -> [RunID] {
        calls += 1
        if let gate { await gate.wait() }
        if let failure { throw failure }
        return runIDs
    }

    func callCount() -> Int { calls }
}

private actor AgentSystemTestGate {
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
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
    }
}

private final class AgentSystemObservationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [AgentSystemObservation] = []

    func record(_ observation: AgentSystemObservation) {
        lock.lock()
        observations.append(observation)
        lock.unlock()
    }

    func values() -> [AgentSystemObservation] {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }
}

private enum AgentSystemTestError: Error, Sendable {
    case timeout
    case invalidPreterminalQueue
}

private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw AgentSystemTestError.timeout
}

private func assertAgentSystemError<T: Sendable>(
    _ expected: AgentSystemError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected AgentSystemError", file: file, line: line)
    } catch let error as AgentSystemError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private func agentSystemRawUUID(_ value: UInt64) -> UUID {
    UUID(
        uuidString: String(
            format: "00000000-0000-0000-0000-%012llX",
            value
        )
    )!
}

private func agentSystemTagged<Tag: AgentIdentifierTag>(
    _ value: UInt64
) -> AgentIdentifier<Tag> {
    AgentIdentifier(rawValue: agentSystemRawUUID(value))
}

private func agentSystemFreshRunPlan(
    model: String,
    systemInstruction: String = "system"
) -> AgentSystemFreshRunPlan {
    AgentSystemFreshRunPlan(
        providerRoute: ProviderRoute(
            providerID: ProviderID(rawValue: "openai"),
            modelID: ProviderModelID(rawValue: model),
            adapterID: ProviderAdapterID(
                rawValue: "openai-chat-completions"
            ),
            capabilities: .hostedChatSingleCallToolsBaseline,
            deployment: .hostedService,
            provenance: .builtInOpenAIChatCompletions
        ),
        providerOptions: ProviderGenerationOptions(
            maximumOutputTokens: 4_096,
            temperature: 0,
            parallelToolCalls: false,
            toolChoice: .auto
        ),
        systemInstruction: systemInstruction,
        developerInstruction: "developer",
        toolLocalities: ["read_file": .onDevice],
        policyVersion: "agent-policy-m6-v1",
        contextPreparationVersion: "canonical-context-v1"
    )
}

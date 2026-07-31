import AgentDomain
import AgentEngine
import Foundation
import XCTest
@testable import NovaForge

final class AgentSystemActivityCommandRouterTests: XCTestCase {
    func testCancellationReloadsExactScopeAndDispatchesFactoryCommand() async throws {
        let identity = Fixture.identity(10)
        let group = Fixture.group(identity: identity, state: .running)
        let handle = Fixture.handle(identity)
        let probe = RouterProbe(groups: [identity.runID: [group]], handles: [handle])
        let router = Fixture.router(probe: probe)

        let result = try await router.route(group.cancelCommand)

        XCTAssertEqual(
            result,
            .executed(kind: .cancellation, commandID: Fixture.commandID)
        )
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.scopes, [AgentActivityProjectionScope(
            projectID: identity.projectID,
            conversationID: identity.conversationID,
            runID: identity.runID
        )])
        XCTAssertEqual(snapshot.registeredHandleReads, 1)
        XCTAssertEqual(snapshot.cancellations.count, 1)
        XCTAssertTrue(snapshot.approvals.isEmpty)
        XCTAssertEqual(snapshot.cancellations.first?.handle, handle)

        let command = try XCTUnwrap(snapshot.cancellations.first?.command)
        XCTAssertEqual(command.header.commandID, Fixture.commandID)
        XCTAssertEqual(command.header.runID, identity.runID)
        XCTAssertEqual(command.header.correlationID, Fixture.correlationID)
        XCTAssertEqual(command.header.issuedAt, Fixture.now)
        guard case let .cancel(payload) = command.payload else {
            return XCTFail("Expected a typed cancellation command")
        }
        XCTAssertEqual(payload.reason, .userRequested)
        XCTAssertTrue(payload.propagateToDescendants)
    }

    func testApprovalReloadsExactPendingRequestAndDispatchesFactoryCommand() async throws {
        let identity = Fixture.identity(20)
        let approval = Fixture.approval(identity: identity, seed: 21)
        let group = Fixture.group(
            identity: identity,
            state: .awaitingApproval,
            approvals: [approval]
        )
        let handle = Fixture.handle(identity)
        let probe = RouterProbe(groups: [identity.runID: [group]], handles: [handle])
        let router = Fixture.router(probe: probe)
        let activityCommand = approval.command(decision: .rejected)

        let result = try await router.route(activityCommand)

        XCTAssertEqual(
            result,
            .executed(kind: .approvalDecision, commandID: Fixture.commandID)
        )
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.approvals.count, 1)
        XCTAssertTrue(snapshot.cancellations.isEmpty)
        XCTAssertEqual(snapshot.approvals.first?.handle, handle)
        let command = try XCTUnwrap(snapshot.approvals.first?.command)
        XCTAssertEqual(command.header.commandID, Fixture.commandID)
        XCTAssertEqual(command.header.runID, identity.runID)
        XCTAssertEqual(command.header.correlationID, Fixture.correlationID)
        XCTAssertEqual(command.header.issuedAt, Fixture.now)
        guard case let .approvalDecision(payload) = command.payload else {
            return XCTFail("Expected a typed approval decision command")
        }
        XCTAssertEqual(payload.requestID, approval.id)
        XCTAssertEqual(payload.callID, approval.callID)
        XCTAssertEqual(payload.decision, .rejected)
        XCTAssertEqual(payload.decidedAt, Fixture.now)
        XCTAssertNil(payload.rationale)
    }

    func testDuplicateCallbacksShareOneCommandAndOneInFlightOperation() async throws {
        let identity = Fixture.identity(30)
        let group = Fixture.group(identity: identity, state: .running)
        let gate = DispatchGate()
        let probe = RouterProbe(
            groups: [identity.runID: [group]],
            handles: [Fixture.handle(identity)],
            cancellationGate: gate
        )
        let router = Fixture.router(probe: probe)

        async let first = router.route(group.cancelCommand)
        await gate.waitUntilEntered()
        async let duplicate = router.route(group.cancelCommand)
        await Task.yield()
        await gate.release()

        let firstResult = try await first
        let duplicateResult = try await duplicate
        XCTAssertEqual(firstResult, duplicateResult)
        XCTAssertEqual(
            firstResult,
            .executed(kind: .cancellation, commandID: Fixture.commandID)
        )
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.scopes.count, 1)
        XCTAssertEqual(snapshot.registeredHandleReads, 1)
        XCTAssertEqual(snapshot.cancellations.count, 1)
    }

    func testConflictingApprovalCallbacksCannotRaceTheSameRequest() async throws {
        let identity = Fixture.identity(35)
        let approval = Fixture.approval(identity: identity, seed: 36)
        let group = Fixture.group(
            identity: identity,
            state: .awaitingApproval,
            approvals: [approval]
        )
        let probe = RouterProbe(
            groups: [identity.runID: [group]],
            handles: [Fixture.handle(identity)]
        )
        let router = Fixture.router(probe: probe)

        _ = try await router.route(approval.command(decision: .approved))
        await assertRouterError(.conflictingRetainedOperation) {
            _ = try await router.route(approval.command(decision: .rejected))
        }

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.scopes.count, 1)
        XCTAssertEqual(snapshot.registeredHandleReads, 1)
        XCTAssertEqual(snapshot.approvals.count, 1)
        let dispatchedCommand = snapshot.approvals[0].command
        guard case let .approvalDecision(payload) = dispatchedCommand.payload else {
            return XCTFail("Expected an approval decision")
        }
        XCTAssertEqual(payload.decision, .approved)
    }

    func testInFlightRetentionIsBoundedAndRejectsDifferentOperation() async throws {
        let firstIdentity = Fixture.identity(40)
        let secondIdentity = Fixture.identity(50)
        let firstGroup = Fixture.group(identity: firstIdentity, state: .running)
        let secondGroup = Fixture.group(identity: secondIdentity, state: .running)
        let gate = DispatchGate()
        let probe = RouterProbe(
            groups: [
                firstIdentity.runID: [firstGroup],
                secondIdentity.runID: [secondGroup],
            ],
            handles: [
                Fixture.handle(firstIdentity),
                Fixture.handle(secondIdentity),
            ],
            cancellationGate: gate
        )
        let router = Fixture.router(
            probe: probe,
            maximumRetainedOperations: 1
        )

        async let first = router.route(firstGroup.cancelCommand)
        await gate.waitUntilEntered()
        await assertRouterError(.operationCapacityExceeded) {
            _ = try await router.route(secondGroup.cancelCommand)
        }
        async let duplicate = router.route(firstGroup.cancelCommand)
        await gate.release()

        let firstResult = try await first
        let duplicateResult = try await duplicate
        XCTAssertEqual(firstResult, duplicateResult)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.cancellations.count, 1)
        XCTAssertEqual(snapshot.scopes.count, 1)
    }

    func testProjectionCardinalityIdentityAndFreshnessFailClosed() async throws {
        let identity = Fixture.identity(60)
        let running = Fixture.group(identity: identity, state: .running)
        let handle = Fixture.handle(identity)

        let missing = RouterProbe(groups: [:], handles: [handle])
        await assertRouterError(.projectionCardinalityMismatch) {
            _ = try await Fixture.router(probe: missing).route(
                running.cancelCommand
            )
        }

        let ambiguous = RouterProbe(
            groups: [identity.runID: [running, running]],
            handles: [handle]
        )
        await assertRouterError(.projectionCardinalityMismatch) {
            _ = try await Fixture.router(probe: ambiguous).route(
                running.cancelCommand
            )
        }

        let wrongIdentity = Fixture.identity(61)
        let mismatched = RouterProbe(
            groups: [identity.runID: [Fixture.group(
                identity: wrongIdentity,
                state: .running
            )]],
            handles: [handle]
        )
        await assertRouterError(.projectionIdentityMismatch) {
            _ = try await Fixture.router(probe: mismatched).route(
                running.cancelCommand
            )
        }

        let terminal = RouterProbe(
            groups: [identity.runID: [Fixture.group(
                identity: identity,
                state: .succeeded
            )]],
            handles: [handle]
        )
        await assertRouterError(.staleActivityCommand) {
            _ = try await Fixture.router(probe: terminal).route(
                running.cancelCommand
            )
        }

        for probe in [missing, ambiguous, mismatched, terminal] {
            let snapshot = await probe.snapshot()
            XCTAssertEqual(snapshot.registeredHandleReads, 0)
            XCTAssertTrue(snapshot.cancellations.isEmpty)
            XCTAssertTrue(snapshot.approvals.isEmpty)
        }
    }

    func testEveryRegisteredHandleIdentityDimensionFailsClosed() async throws {
        let identity = Fixture.identity(70)
        let group = Fixture.group(identity: identity, state: .running)
        let wrongConversation = Fixture.identity(
            70,
            conversationID: Fixture.conversationID(171)
        )
        let wrongProject = Fixture.identity(
            70,
            projectID: Fixture.projectID(172)
        )
        let wrongWorkspace = Fixture.identity(
            70,
            workspaceID: Fixture.workspaceID(173)
        )
        let wrongFence = Fixture.handle(
            identity,
            fenceRunID: Fixture.runID(174)
        )

        let hostileHandles = [
            Fixture.handle(wrongConversation),
            Fixture.handle(wrongProject),
            Fixture.handle(wrongWorkspace),
            wrongFence,
        ]
        for hostileHandle in hostileHandles {
            let probe = RouterProbe(
                groups: [identity.runID: [group]],
                handles: [hostileHandle]
            )
            await assertRouterError(.registeredHandleIdentityMismatch) {
                _ = try await Fixture.router(probe: probe).route(
                    group.cancelCommand
                )
            }
            let snapshot = await probe.snapshot()
            XCTAssertTrue(snapshot.cancellations.isEmpty)
        }

        for handles in [[], [Fixture.handle(identity), Fixture.handle(identity)]] {
            let probe = RouterProbe(
                groups: [identity.runID: [group]],
                handles: handles
            )
            await assertRouterError(.registeredHandleCardinalityMismatch) {
                _ = try await Fixture.router(probe: probe).route(
                    group.cancelCommand
                )
            }
            let snapshot = await probe.snapshot()
            XCTAssertTrue(snapshot.cancellations.isEmpty)
        }
    }

    func testDescendantRootDispatchesOnlyWhenTrustedHandleLineageMatches() async throws {
        let runID = Fixture.runID(80)
        let identity = Fixture.identity(
            80,
            runID: runID,
            rootRunID: Fixture.runID(81)
        )
        let group = Fixture.group(identity: identity, state: .running)
        let probe = RouterProbe(
            groups: [runID: [group]],
            handles: [Fixture.handle(identity)]
        )

        _ = try await Fixture.router(probe: probe).route(
            group.cancelCommand
        )
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.cancellations.count, 1)

        let wrongRoot = Fixture.identity(
            80,
            runID: runID,
            rootRunID: Fixture.runID(82)
        )
        let hostile = RouterProbe(
            groups: [runID: [group]],
            handles: [Fixture.handle(wrongRoot)]
        )
        await assertRouterError(.registeredHandleIdentityMismatch) {
            _ = try await Fixture.router(probe: hostile).route(
                group.cancelCommand
            )
        }
        let hostileSnapshot = await hostile.snapshot()
        XCTAssertTrue(hostileSnapshot.cancellations.isEmpty)
    }

    func testDependencyFailuresCollapseToFiniteSanitizedErrors() async throws {
        let identity = Fixture.identity(90)
        let group = Fixture.group(identity: identity, state: .running)
        let handle = Fixture.handle(identity)

        let projectionFailure = RouterProbe(
            groups: [identity.runID: [group]],
            handles: [handle],
            failGroupLoad: true
        )
        await assertRouterError(.projectionUnavailable) {
            _ = try await Fixture.router(probe: projectionFailure).route(
                group.cancelCommand
            )
        }

        let registryFailure = RouterProbe(
            groups: [identity.runID: [group]],
            handles: [handle],
            failHandleRead: true
        )
        await assertRouterError(.registryUnavailable) {
            _ = try await Fixture.router(probe: registryFailure).route(
                group.cancelCommand
            )
        }

        let dispatchFailure = RouterProbe(
            groups: [identity.runID: [group]],
            handles: [handle],
            failCancellation: true
        )
        await assertRouterError(.dispatchUnavailable) {
            _ = try await Fixture.router(probe: dispatchFailure).route(
                group.cancelCommand
            )
        }
    }

    func testRetryReceiptAndArtifactAreValidatedNavigationOnlyResults() async throws {
        let identity = Fixture.identity(100)
        let attempt = Fixture.failedAttempt(seed: 101)
        let artifact = Fixture.artifact(identity: identity, seed: 102)
        let group = Fixture.group(
            identity: identity,
            state: .failed,
            attempts: [attempt],
            artifacts: [artifact]
        )
        let probe = RouterProbe(
            groups: [identity.runID: [group]],
            handles: [Fixture.handle(identity)]
        )
        let router = Fixture.router(probe: probe)

        let retryResult = try await router.route(group.retryCommand)
        XCTAssertEqual(
            retryResult,
            .navigation(.retry(AgentActivityRetryCommand(
                run: identity,
                failedAttemptID: attempt.id
            )))
        )
        let receiptResult = try await router.route(group.openReceiptCommand)
        XCTAssertEqual(
            receiptResult,
            .navigation(.receipt(AgentActivityRunCommand(run: identity)))
        )
        let artifactResult = try await router.route(artifact.openCommand)
        XCTAssertEqual(
            artifactResult,
            .navigation(.artifact(AgentActivityArtifactCommand(
                run: identity,
                artifactID: artifact.id,
                contentDigest: artifact.contentDigest
            )))
        )

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.scopes.count, 3)
        XCTAssertEqual(snapshot.registeredHandleReads, 0)
        XCTAssertTrue(snapshot.cancellations.isEmpty)
        XCTAssertTrue(snapshot.approvals.isEmpty)

        let forgedArtifact = AgentActivityCommand.openArtifact(
            AgentActivityArtifactCommand(
                run: identity,
                artifactID: artifact.id,
                contentDigest: "forged-digest"
            )
        )
        await assertRouterError(.staleActivityCommand) {
            _ = try await router.route(forgedArtifact)
        }
    }
}

private enum ProbeFailure: Error {
    case secret(String)
}

private struct RecordedDispatch: Sendable {
    let command: AgentCommand
    let handle: AgentSystemRunHandle
}

private struct RouterProbeSnapshot: Sendable {
    let scopes: [AgentActivityProjectionScope]
    let registeredHandleReads: Int
    let cancellations: [RecordedDispatch]
    let approvals: [RecordedDispatch]
}

private actor RouterProbe {
    private let groups: [RunID: [AgentActivityGroup]]
    private let handles: [AgentSystemRunHandle]
    private let cancellationGate: DispatchGate?
    private let failGroupLoad: Bool
    private let failHandleRead: Bool
    private let failCancellation: Bool
    private let failApproval: Bool
    private var scopes: [AgentActivityProjectionScope] = []
    private var registeredHandleReads = 0
    private var cancellations: [RecordedDispatch] = []
    private var approvals: [RecordedDispatch] = []

    init(
        groups: [RunID: [AgentActivityGroup]],
        handles: [AgentSystemRunHandle],
        cancellationGate: DispatchGate? = nil,
        failGroupLoad: Bool = false,
        failHandleRead: Bool = false,
        failCancellation: Bool = false,
        failApproval: Bool = false
    ) {
        self.groups = groups
        self.handles = handles
        self.cancellationGate = cancellationGate
        self.failGroupLoad = failGroupLoad
        self.failHandleRead = failHandleRead
        self.failCancellation = failCancellation
        self.failApproval = failApproval
    }

    func loadGroups(
        _ scope: AgentActivityProjectionScope
    ) throws -> [AgentActivityGroup] {
        scopes.append(scope)
        if failGroupLoad {
            throw ProbeFailure.secret("raw journal path and decode failure")
        }
        guard let runID = scope.runID else { return [] }
        return groups[runID] ?? []
    }

    func readRegisteredHandles() throws -> [AgentSystemRunHandle] {
        registeredHandleReads += 1
        if failHandleRead {
            throw ProbeFailure.secret("private engine registry details")
        }
        return handles
    }

    func dispatchCancellation(
        _ command: AgentCommand,
        handle: AgentSystemRunHandle
    ) async throws {
        cancellations.append(RecordedDispatch(command: command, handle: handle))
        if failCancellation {
            throw ProbeFailure.secret("provider credential and raw response")
        }
        if let cancellationGate {
            await cancellationGate.enterAndWait()
        }
    }

    func dispatchApproval(
        _ command: AgentCommand,
        handle: AgentSystemRunHandle
    ) throws {
        approvals.append(RecordedDispatch(command: command, handle: handle))
        if failApproval {
            throw ProbeFailure.secret("approval broker private state")
        }
    }

    func snapshot() -> RouterProbeSnapshot {
        RouterProbeSnapshot(
            scopes: scopes,
            registeredHandleReads: registeredHandleReads,
            cancellations: cancellations,
            approvals: approvals
        )
    }
}

private actor DispatchGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        released = true
        let current = waiters
        waiters.removeAll(keepingCapacity: false)
        current.forEach { $0.resume() }
    }
}

private enum Fixture {
    static let commandID = CommandID(rawValue: uuid(900))
    static let correlationID = CorrelationID(rawValue: uuid(901))
    static let now = AgentInstant(rawValue: 1_900_000_000_000)

    static func router(
        probe: RouterProbe,
        maximumRetainedOperations: Int = 64
    ) -> AgentSystemActivityCommandRouter {
        AgentSystemActivityCommandRouter(
            maximumRetainedOperations: maximumRetainedOperations,
            loadGroups: { scope in
                try await probe.loadGroups(scope)
            },
            registeredHandles: {
                try await probe.readRegisteredHandles()
            },
            dispatchCancellation: { command, handle in
                try await probe.dispatchCancellation(command, handle: handle)
            },
            dispatchApproval: { command, handle in
                try await probe.dispatchApproval(command, handle: handle)
            },
            now: { now },
            makeCommandID: { commandID },
            makeCorrelationID: { correlationID }
        )
    }

    static func identity(
        _ seed: Int,
        conversationID: ConversationID? = nil,
        projectID: ProjectID? = nil,
        workspaceID: WorkspaceID? = nil,
        runID: RunID? = nil,
        rootRunID: RunID? = nil
    ) -> AgentActivityRunIdentity {
        let resolvedRunID = runID ?? self.runID(seed + 3)
        return AgentActivityRunIdentity(
            projectID: projectID ?? self.projectID(seed + 1),
            conversationID: conversationID ?? self.conversationID(seed + 2),
            workspaceID: workspaceID ?? self.workspaceID(seed + 4),
            runID: resolvedRunID,
            rootRunID: rootRunID ?? resolvedRunID
        )
    }

    static func group(
        identity: AgentActivityRunIdentity,
        state: AgentActivityState,
        attempts: [AgentActivityAttempt] = [],
        approvals: [AgentActivityApproval] = [],
        artifacts: [AgentActivityArtifact] = []
    ) -> AgentActivityGroup {
        AgentActivityGroup(
            identity: identity,
            state: state,
            summary: "Canonical activity",
            span: span,
            items: [],
            attempts: attempts,
            approvals: approvals,
            artifacts: artifacts,
            evidence: [],
            errorMessage: state == .failed ? "Public failure" : nil,
            replayIdentity: AgentActivityReplayIdentity(
                orderedEventIDs: [EventID(rawValue: uuid(990))],
                orderedSequences: [.first]
            )
        )
    }

    static func approval(
        identity: AgentActivityRunIdentity,
        seed: Int
    ) -> AgentActivityApproval {
        AgentActivityApproval(
            id: ApprovalRequestID(rawValue: uuid(seed)),
            run: identity,
            callID: ToolCallID(rawValue: uuid(seed + 1)),
            state: .awaitingApproval,
            publicSummary: "Review this action.",
            requestedAt: now,
            resolvedAt: nil
        )
    }

    static func failedAttempt(seed: Int) -> AgentActivityAttempt {
        AgentActivityAttempt(
            id: AttemptID(rawValue: uuid(seed)),
            state: .failed,
            route: AgentActivityRoute(
                provider: "hosted",
                model: "model",
                adapter: "adapter"
            ),
            span: span,
            itemIDs: [],
            retryOfAttemptID: nil,
            nextAttemptID: nil,
            errorMessage: "Public failure"
        )
    }

    static func artifact(
        identity: AgentActivityRunIdentity,
        seed: Int
    ) -> AgentActivityArtifact {
        let artifactID = ArtifactID(rawValue: uuid(seed))
        return AgentActivityArtifact(
            id: artifactID,
            run: identity,
            equivalentArtifactIDs: [artifactID],
            contentDigest: "sha256:fixture-\(seed)",
            mediaType: "text/plain",
            displayName: "Result.txt",
            firstSequence: .first,
            sourceToolCallIDs: []
        )
    }

    static func handle(
        _ identity: AgentActivityRunIdentity,
        fenceRunID: RunID? = nil
    ) -> AgentSystemRunHandle {
        let lineage: AgentRunLineage = if identity.rootRunID == identity.runID {
            .root(identity.runID)
        } else {
            AgentRunLineage(
                runID: identity.runID,
                rootRunID: identity.rootRunID,
                parentRunID: identity.rootRunID,
                generation: 1
            )
        }
        let context = AgentRunContext(
            lineage: lineage,
            conversationID: identity.conversationID,
            projectID: identity.projectID,
            workspaceID: identity.workspaceID,
            executionNodeID: ExecutionNodeID(rawValue: uuid(950)),
            engineVersion: .agentHarnessV2,
            acceptedAt: now,
            features: AgentFeatureSet([]),
            cancellation: CancellationLineage(
                scopeID: CancellationScopeID(rawValue: uuid(951))
            ),
            initialBudget: AgentBudget(limits: .standard)
        )
        return AgentSystemRunHandle(
            identity: AgentSystemRunIdentity(context: context),
            ownerFence: AgentEngineOwnerFence(
                runID: fenceRunID ?? identity.runID,
                ownerID: uuid(952),
                generation: 1
            )
        )
    }

    static let span = AgentActivityEventSpan(
        firstSequence: .first,
        lastSequence: .first,
        startedAt: now,
        endedAt: AgentInstant(rawValue: now.rawValue + 1)
    )

    static func runID(_ seed: Int) -> RunID {
        RunID(rawValue: uuid(seed))
    }

    static func conversationID(_ seed: Int) -> ConversationID {
        ConversationID(rawValue: uuid(seed))
    }

    static func projectID(_ seed: Int) -> ProjectID {
        ProjectID(rawValue: uuid(seed))
    }

    static func workspaceID(_ seed: Int) -> WorkspaceID {
        WorkspaceID(rawValue: uuid(seed))
    }

    static func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llx", UInt64(seed))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}

private func assertRouterError(
    _ expected: AgentSystemActivityCommandRouterError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)")
    } catch let error as AgentSystemActivityCommandRouterError {
        XCTAssertEqual(error, expected)
    } catch {
        XCTFail("Expected finite router error, received \(type(of: error))")
    }
}

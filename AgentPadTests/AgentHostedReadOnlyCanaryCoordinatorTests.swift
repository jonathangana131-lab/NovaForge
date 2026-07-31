#if DEBUG
import AgentDomain
import AgentProviders
import AgentShadow
import AgentStore
import AgentTools
import Foundation
import XCTest
@testable import NovaForge

final class AgentHostedReadOnlyCanaryCoordinatorTests: XCTestCase {
    func testReadRoundCommitsInvocationBeforeLifecycleAndPreservesRawCallID() async throws {
        let fixture = try await makeReadCanaryFixture(seed: 101)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try AgentHostedReadOnlyCanaryBackend.workspaceDigest(
            fixture.workspace
        )
        let transport = ReadCanaryTransport(mode: .toolThenFinal(
            name: "read_file",
            callID: "call-read-101",
            arguments: .object(["path": .string("note.txt")])
        ), model: fixture.model)
        let coordinator = try fixture.coordinator(transport: transport)

        let result = try await coordinator.execute(
            acceptedRun: fixture.acceptance,
            request: fixture.request
        )
        XCTAssertEqual(result.finishReason, .completed)
        let after = try AgentHostedReadOnlyCanaryBackend.workspaceDigest(
            fixture.workspace
        )
        XCTAssertEqual(before, after)

        let events = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        )
        XCTAssertEqual(events.map(\.event.payload.kind), [
            .runAccepted,
            .runStarted,
            .modelRequestStarted,
            .modelResponseCommitted,
            .toolProposed,
            .toolScheduled,
            .toolStarted,
            .toolCompleted,
            .modelRequestStarted,
            .modelResponseCommitted,
        ])
        let requestStarts = events.compactMap { record -> ModelRequestStartedEvent? in
            guard case let .modelRequestStarted(value) = record.event.payload else {
                return nil
            }
            XCTAssertEqual(record.event.header.schemaVersion, .v1_1)
            return value
        }
        var ordinals: [UInt32] = []
        for started in requestStarts {
            guard case let .recordedV1_1(
                requestDigest,
                scopeReference,
                ordinal,
                recoverySeed
            ) = started.providerAttempt else {
                return XCTFail("A v1.1 read round used legacy dispatch metadata")
            }
            ordinals.append(ordinal)
            XCTAssertTrue(requestDigest.rawValue.hasPrefix("sha256:"))
            let scope = ProviderAttemptScope(
                requestID: scopeReference.requestID,
                attemptID: ProviderAttemptID(rawValue: scopeReference.attemptID)
            )
            XCTAssertEqual(
                recoverySeed,
                AgentHostedTextCanaryCoordinator.providerRecoverySeed(
                    runID: fixture.runID,
                    scope: scope,
                    ordinal: ordinal
                )
            )
        }
        XCTAssertEqual(ordinals, [1, 2])
        XCTAssertEqual(Set(ordinals).count, ordinals.count)
        XCTAssertFalse(events.contains { $0.event.payload.kind == .toolApplied })
        guard case let .modelResponseCommitted(providerCommit) =
                events[3].event.payload,
              case let .toolInvocation(invocation) =
                providerCommit.items.first?.payload else {
            return XCTFail("Expected a committed provider invocation")
        }
        XCTAssertEqual(invocation.providerCallID, "call-read-101")
        guard case let .toolScheduled(scheduled) = events[5].event.payload,
              case let .toolStarted(started) = events[6].event.payload,
              case let .toolCompleted(completed) = events[7].event.payload else {
            return XCTFail("Expected a completed read")
        }
        XCTAssertNil(scheduled.effect)
        XCTAssertNil(started.effect)
        XCTAssertNil(completed.effect)
        XCTAssertEqual(completed.result.status, .succeeded)
        XCTAssertEqual(completed.result.evidence.first?.kind, "read_only_tool_output")

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        let encodedSecond = try JSONEncoder().encode(requests[1].body)
        let secondBody = String(decoding: encodedSecond, as: UTF8.self)
        XCTAssertTrue(secondBody.contains("call-read-101"))
        XCTAssertTrue(secondBody.contains("tool_call_id"))
        XCTAssertTrue(secondBody.contains("tool_calls"))
    }

    func testWriteAliasAndParallelSpoofsFailBeforeBackendExecution() async throws {
        let hostileCalls: [(String, ReadCanaryTransport.Mode)] = [
            ("write", .toolThenFinal(
                name: "write_file",
                callID: "call-write",
                arguments: .object([
                    "path": .string("owned.txt"),
                    "contents": .string("forbidden"),
                ])
            )),
            ("alias", .toolThenFinal(
                name: "cat",
                callID: "call-alias",
                arguments: .object(["path": .string("note.txt")])
            )),
            ("parallel", .parallelTools),
        ]

        for (index, hostile) in hostileCalls.enumerated() {
            let fixture = try await makeReadCanaryFixture(
                seed: UInt64(110 + index)
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let before = try AgentHostedReadOnlyCanaryBackend.workspaceDigest(
                fixture.workspace
            )
            let backend = CountingReadBackend(output: "must not execute")
            let transport = ReadCanaryTransport(
                mode: hostile.1,
                model: fixture.model
            )
            let coordinator = try fixture.coordinator(
                transport: transport,
                backend: backend
            )
            do {
                _ = try await coordinator.execute(
                    acceptedRun: fixture.acceptance,
                    request: fixture.request
                )
                XCTFail("\(hostile.0) spoof unexpectedly executed")
            } catch {
                // The public canary boundary intentionally exposes only a
                // fixed failed-attempt category, never hostile arguments.
            }
            let backendCalls = await backend.callCount()
            XCTAssertEqual(backendCalls, 0)
            let events = try await fixture.store.events(
                for: fixture.runID,
                after: nil
            )
            XCTAssertEqual(events.last?.event.payload.kind, .modelRequestFailed)
            XCTAssertFalse(events.contains {
                $0.event.payload.kind == .toolProposed
            })
            XCTAssertEqual(
                before,
                try AgentHostedReadOnlyCanaryBackend.workspaceDigest(
                    fixture.workspace
                )
            )
        }
    }

    func testDuplicateProviderCallReplayFailsBeforeSecondExecution() async throws {
        let fixture = try await makeReadCanaryFixture(seed: 120)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let backend = CountingReadBackend(output: "bounded")
        let before = try AgentHostedReadOnlyCanaryBackend.workspaceDigest(
            fixture.workspace
        )
        let transport = ReadCanaryTransport(
            mode: .repeatedToolCall,
            model: fixture.model
        )
        let coordinator = try fixture.coordinator(
            transport: transport,
            backend: backend
        )

        do {
            _ = try await coordinator.execute(
                acceptedRun: fixture.acceptance,
                request: fixture.request
            )
            XCTFail("A replayed provider call ID unexpectedly succeeded")
        } catch {
            let backendCalls = await backend.callCount()
            XCTAssertEqual(backendCalls, 1)
        }
        let events = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        )
        XCTAssertEqual(events.last?.event.payload.kind, .modelRequestFailed)
        XCTAssertEqual(events.filter {
            $0.event.payload.kind == .toolCompleted
        }.count, 1)
        XCTAssertEqual(
            before,
            try AgentHostedReadOnlyCanaryBackend.workspaceDigest(
                fixture.workspace
            )
        )
    }

    func testCrossWorkspaceBindingAndSpoofedHostedRouteFailClosed() async throws {
        let fixture = try await makeReadCanaryFixture(seed: 130)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let otherWorkspaceID: WorkspaceID = canaryTestID(130_999)
        let transport = ReadCanaryTransport(
            mode: .toolThenFinal(
                name: "read_file",
                callID: "call-cross-workspace",
                arguments: .object(["path": .string("note.txt")])
            ),
            model: fixture.model
        )
        let coordinator = try AgentHostedReadOnlyCanaryCoordinator(
            journal: fixture.store,
            provider: fixture.provider,
            transport: transport,
            backend: fixture.backend,
            boundWorkspaceID: otherWorkspaceID
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.execute(
                acceptedRun: fixture.acceptance,
                request: fixture.request
            )
        }
        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 0)

        let outside = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("must remain private".utf8).write(to: outside)
        let before = try AgentHostedReadOnlyCanaryBackend.workspaceDigest(
            fixture.workspace
        )
        let escapingTransport = ReadCanaryTransport(
            mode: .toolThenFinal(
                name: "read_file",
                callID: "call-path-escape",
                arguments: .object([
                    "path": .string("../\(outside.lastPathComponent)"),
                ])
            ),
            model: fixture.model
        )
        let escapingCoordinator = try fixture.coordinator(
            transport: escapingTransport
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await escapingCoordinator.execute(
                acceptedRun: fixture.acceptance,
                request: fixture.request
            )
        }
        XCTAssertEqual(
            before,
            try AgentHostedReadOnlyCanaryBackend.workspaceDigest(
                fixture.workspace
            )
        )
        XCTAssertEqual(
            try String(contentsOf: outside, encoding: .utf8),
            "must remain private"
        )

        let trusted = TrustedHostedProviderCatalog.openAIChatCompletions(
            model: fixture.model,
            capabilities: .hostedChatReadOnlyToolsCanaryBaseline
        )
        let spoof = ProviderRoute(
            providerID: ProviderID(rawValue: "openai"),
            modelID: fixture.model,
            adapterID: ProviderAdapterID(rawValue: "openai-chat-completions"),
            capabilities: .hostedChatReadOnlyToolsCanaryBaseline,
            deployment: .callerManaged,
            provenance: .callerConfigured
        )
        XCTAssertThrowsError(try AgentHostedReadOnlyCanaryProvider(
            trustedCatalog: trusted,
            declaredRoute: spoof
        ))
    }

    func testCancellationAndOversizeOutputSettleExactlyWithoutToolApplied() async throws {
        let cancellationFixture = try await makeReadCanaryFixture(seed: 140)
        defer { try? FileManager.default.removeItem(at: cancellationFixture.root) }
        let waiting = ReadCanaryTransport(
            mode: .waitForCancellation,
            model: cancellationFixture.model
        )
        let cancellingCoordinator = try cancellationFixture.coordinator(
            transport: waiting
        )
        let task = Task {
            try await cancellingCoordinator.execute(
                acceptedRun: cancellationFixture.acceptance,
                request: cancellationFixture.request
            )
        }
        defer { task.cancel() }
        try await waitForReadTransportCalls(1, transport: waiting)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled read canary unexpectedly succeeded")
        } catch let error as AgentHostedReadOnlyCanaryCoordinatorError {
            guard case let .attemptFailed(info) = error else {
                return XCTFail("Unexpected cancellation error: \(error)")
            }
            XCTAssertEqual(info.category, .cancelled)
        }
        let cancelledEvents = try await cancellationFixture.store.events(
            for: cancellationFixture.runID,
            after: nil
        )
        XCTAssertEqual(cancelledEvents.last?.event.payload.kind, .modelRequestFailed)

        let oversizeFixture = try await makeReadCanaryFixture(seed: 141)
        defer { try? FileManager.default.removeItem(at: oversizeFixture.root) }
        let oversizeBefore = try AgentHostedReadOnlyCanaryBackend
            .workspaceDigest(oversizeFixture.workspace)
        let oversizeBackend = CountingReadBackend(
            output: String(
                repeating: "x",
                count: AgentHostedReadOnlyCanaryCoordinator
                    .maximumToolOutputBytes + 1
            )
        )
        let oversized = ReadCanaryTransport(
            mode: .toolThenFinal(
                name: "read_file",
                callID: "call-oversize",
                arguments: .object(["path": .string("note.txt")])
            ),
            model: oversizeFixture.model
        )
        let oversizeCoordinator = try oversizeFixture.coordinator(
            transport: oversized,
            backend: oversizeBackend
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await oversizeCoordinator.execute(
                acceptedRun: oversizeFixture.acceptance,
                request: oversizeFixture.request
            )
        }
        let oversizedEvents = try await oversizeFixture.store.events(
            for: oversizeFixture.runID,
            after: nil
        )
        XCTAssertEqual(oversizedEvents.last?.event.payload.kind, .toolCompleted)
        XCTAssertFalse(oversizedEvents.contains {
            $0.event.payload.kind == .toolApplied
        })
        XCTAssertEqual(
            oversizeBefore,
            try AgentHostedReadOnlyCanaryBackend.workspaceDigest(
                oversizeFixture.workspace
            )
        )
    }

    func testRestartResumesAfterDurableToolResultWithoutReexecutingRead() async throws {
        let fixture = try await makeReadCanaryFixture(seed: 150)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let backend = CountingReadBackend(output: "durable read output")
        let pausingJournal = CompletionPausingJournal(backing: fixture.store)
        let firstTransport = ReadCanaryTransport(
            mode: .toolThenFinal(
                name: "read_file",
                callID: "call-recovery",
                arguments: .object(["path": .string("note.txt")])
            ),
            model: fixture.model
        )
        let firstCoordinator = try AgentHostedReadOnlyCanaryCoordinator(
            journal: pausingJournal,
            provider: fixture.provider,
            transport: firstTransport,
            backend: backend,
            boundWorkspaceID: fixture.acceptance.metadata.context.workspaceID
        )
        let first = Task {
            try await firstCoordinator.execute(
                acceptedRun: fixture.acceptance,
                request: fixture.request
            )
        }
        try await waitForCompletionPause(pausingJournal)
        first.cancel()
        // The product intentionally shields the durable completion append in
        // a detached task. Release this test journal explicitly; parent-task
        // cancellation cannot and must not cancel that settlement write.
        await pausingJournal.releaseCompletion()
        do {
            _ = try await first.value
            XCTFail("Interrupted first coordinator unexpectedly completed")
        } catch {
            // The durable prefix intentionally ends at toolCompleted.
        }
        let callsBeforeRestart = await backend.callCount()
        XCTAssertEqual(callsBeforeRestart, 1)
        let prefix = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        )
        XCTAssertEqual(prefix.last?.event.payload.kind, .toolCompleted)
        let prefixAttempts = prefix.compactMap { record -> ModelRequestStartedEvent? in
            guard case let .modelRequestStarted(value) = record.event.payload else {
                return nil
            }
            return value
        }
        XCTAssertEqual(prefixAttempts.count, 1)

        let restartedTransport = ReadCanaryTransport(
            mode: .finalOnly,
            model: fixture.model
        )
        let restarted = try fixture.coordinator(
            transport: restartedTransport,
            backend: backend
        )
        let result = try await restarted.execute(
            acceptedRun: fixture.acceptance,
            request: fixture.request
        )
        XCTAssertEqual(result.finishReason, .completed)
        let callsAfterRestart = await backend.callCount()
        XCTAssertEqual(callsAfterRestart, 1)
        let events = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        )
        XCTAssertEqual(events.filter {
            $0.event.payload.kind == .toolCompleted
        }.count, 1)
        XCTAssertEqual(events.filter {
            $0.event.payload.kind == .modelRequestStarted
        }.count, 2)
        let relaunchedAttempts = events.compactMap {
            record -> ModelRequestStartedEvent? in
            guard case let .modelRequestStarted(value) = record.event.payload else {
                return nil
            }
            return value
        }
        XCTAssertEqual(
            relaunchedAttempts.first?.providerAttempt,
            prefixAttempts.first?.providerAttempt,
            "Relaunch must preserve the original recovery identity"
        )
    }

    func testWorkspaceDigestIncludesHiddenFilesAndRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NovaForgeReadDigest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let hidden = root.appendingPathComponent(".hidden")
        try Data("before".utf8).write(to: hidden)
        let workspace = NovaForge.SandboxWorkspace(rootURL: root)
        let before = try AgentHostedReadOnlyCanaryBackend.workspaceDigest(
            workspace
        )
        try Data("after".utf8).write(to: hidden)
        let after = try AgentHostedReadOnlyCanaryBackend.workspaceDigest(
            workspace
        )
        XCTAssertNotEqual(before, after)

        let link = root.appendingPathComponent("unsafe-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: hidden
        )
        XCTAssertThrowsError(
            try AgentHostedReadOnlyCanaryBackend.workspaceDigest(workspace)
        )
    }

    func testWorkspaceDigestBindsFileBoundariesAndRejectsParentSymlinkSwap() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NovaForgeReadDigestHostile-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("first", isDirectory: true)
        let second = base.appendingPathComponent("second", isDirectory: true)
        for root in [first, second] {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }
        try Data("ab".utf8).write(
            to: first.appendingPathComponent("a.txt")
        )
        try Data("c".utf8).write(
            to: first.appendingPathComponent("b.txt")
        )
        try Data("a".utf8).write(
            to: second.appendingPathComponent("a.txt")
        )
        try Data("bc".utf8).write(
            to: second.appendingPathComponent("b.txt")
        )
        let firstDigest = try AgentHostedReadOnlyCanaryBackend
            .workspaceDigest(NovaForge.SandboxWorkspace(rootURL: first))
        let secondDigest = try AgentHostedReadOnlyCanaryBackend
            .workspaceDigest(NovaForge.SandboxWorkspace(rootURL: second))
        XCTAssertNotEqual(firstDigest, secondDigest)

        let raced = base.appendingPathComponent("raced", isDirectory: true)
        let parent = raced.appendingPathComponent("parent", isDirectory: true)
        let parked = raced.appendingPathComponent(
            "parent-parked",
            isDirectory: true
        )
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try Data("inside".utf8).write(
            to: parent.appendingPathComponent("child.txt")
        )
        try Data("outside-secret".utf8).write(
            to: outside.appendingPathComponent("child.txt")
        )
        var didSwap = false
        XCTAssertThrowsError(try AgentHostedReadOnlyCanaryBackend
            .workspaceDigest(
                NovaForge.SandboxWorkspace(rootURL: raced),
                willOpenEntry: { components, name in
                    guard !didSwap,
                          components.isEmpty,
                          name == Array("parent".utf8) else { return }
                    didSwap = true
                    try FileManager.default.moveItem(at: parent, to: parked)
                    try FileManager.default.createSymbolicLink(
                        at: parent,
                        withDestinationURL: outside
                    )
                }
            ))
        XCTAssertTrue(didSwap)
        XCTAssertEqual(
            try String(contentsOf: outside.appendingPathComponent("child.txt")),
            "outside-secret"
        )
    }

    func testBackendWithholdsOutsideReadAfterSwapRestoreChangesOnlyMetadata() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NovaForgeReadExecutionRace-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("workspace", isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let parked = base.appendingPathComponent("parked", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try Data("inside-value".utf8).write(
            to: parent.appendingPathComponent("note.txt")
        )
        try Data("outside-secret-must-not-return".utf8).write(
            to: outside.appendingPathComponent("note.txt")
        )

        let probe = try ReadSwapRestoreProbe(
            root: root,
            parent: parent,
            parked: parked,
            outside: outside
        )
        let workspace = NovaForge.SandboxWorkspace(
            rootURL: root,
            readInterposition: NovaForge.SandboxReadInterposition(
                beforeContentOpen: { try probe.swapToOutside() },
                afterContentOpen: { try probe.restoreOriginal() }
            )
        )
        let identity = try NovaForge.WorkspaceResourceIdentity(
            workspace: workspace
        )
        let backend = try AgentHostedReadOnlyCanaryBackend(
            workspace: workspace,
            workspaceIdentity: identity
        )
        let before = try AgentHostedReadOnlyCanaryBackend.workspaceDigest(
            workspace
        )
        var returnedOutput: String?
        do {
            returnedOutput = try await backend.executeReadOnly(
                LegacySandboxToolRequest(
                    name: "read_file",
                    arguments: ["path": "parent/note.txt"]
                )
            )
            XCTFail("A swap-and-restored outside read unexpectedly returned")
        } catch let error as AgentHostedReadOnlyCanaryBackendError {
            XCTAssertEqual(error, .workspaceChanged)
        }
        XCTAssertNil(returnedOutput)
        XCTAssertTrue(probe.didSwapAndRestore)
        XCTAssertEqual(
            try String(
                contentsOf: parent.appendingPathComponent("note.txt"),
                encoding: .utf8
            ),
            "inside-value"
        )
        XCTAssertEqual(
            try String(
                contentsOf: outside.appendingPathComponent("note.txt"),
                encoding: .utf8
            ),
            "outside-secret-must-not-return"
        )
        let after = try AgentHostedReadOnlyCanaryBackend.workspaceDigest(
            workspace
        )
        XCTAssertNotEqual(before, after)
    }
}

private struct ReadCanaryFixture {
    let root: URL
    let workspace: NovaForge.SandboxWorkspace
    let workspaceIdentity: NovaForge.WorkspaceResourceIdentity
    let backend: AgentHostedReadOnlyCanaryBackend
    let store: InMemoryAgentEventJournal
    let acceptance: AgentRunAcceptance
    let provider: AgentHostedReadOnlyCanaryProvider
    let request: CanonicalProviderRequest
    let model: ProviderModelID

    var runID: RunID { acceptance.metadata.runID }

    func coordinator(
        transport: any ProviderTransport,
        backend customBackend: (any DeveloperReadOnlyCanaryToolBackend)? = nil
    ) throws -> AgentHostedReadOnlyCanaryCoordinator {
        try AgentHostedReadOnlyCanaryCoordinator(
            journal: store,
            provider: provider,
            transport: transport,
            backend: customBackend ?? backend,
            boundWorkspaceID: acceptance.metadata.context.workspaceID
        )
    }
}

private func makeReadCanaryFixture(seed: UInt64) async throws -> ReadCanaryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "NovaForgeReadCanary-\(seed)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    try Data("read-only fixture".utf8).write(
        to: root.appendingPathComponent("note.txt")
    )
    let workspace = NovaForge.SandboxWorkspace(rootURL: root)
    let workspaceIdentity = try NovaForge.WorkspaceResourceIdentity(
        workspace: workspace
    )
    let backend = try AgentHostedReadOnlyCanaryBackend(
        workspace: workspace,
        workspaceIdentity: workspaceIdentity
    )
    let acceptedAt = AgentInstant(rawValue: 2_200_000_000_000 + Int64(seed))
    let runID: RunID = canaryTestID(seed * 1_000 + 1)
    let context = AgentRunContext(
        schemaVersion: .v1_1,
        lineage: .root(runID),
        conversationID: canaryTestID(seed * 1_000 + 2),
        projectID: canaryTestID(seed * 1_000 + 3),
        workspaceID: WorkspaceID(rawValue: workspaceIdentity.persistentID),
        executionNodeID: canaryTestID(seed * 1_000 + 4),
        engineVersion: AgentHostedReadOnlyCanaryCoordinator.engineVersion,
        acceptedAt: acceptedAt,
        features: AgentHostedReadOnlyCanaryCoordinator.featureSet,
        cancellation: CancellationLineage(
            scopeID: canaryTestID(seed * 1_000 + 5)
        ),
        initialBudget: AgentBudget(limits: .standard)
    )
    let userItem = ModelItem(
        id: canaryTestID(seed * 1_000 + 6),
        createdAt: acceptedAt,
        payload: .message(ModelMessage(
            role: .user,
            content: [.text("Inspect note.txt")]
        ))
    )
    let eventID: EventID = canaryTestID(seed * 1_000 + 7)
    let writerID = AgentEventWriterID(runID: runID)
    let envelope = AgentEventEnvelope(
        writerID: writerID,
        writerSequence: .first,
        idempotencyKey: "read-canary-test-accept-\(seed)",
        event: AgentEvent(
            header: AgentEventHeader(
                eventID: eventID,
                schemaVersion: context.schemaVersion,
                context: context,
                sequence: .first,
                timestamp: acceptedAt,
                causationID: nil,
                correlationID: canaryTestID(seed * 1_000 + 8)
            ),
            payload: .runAccepted(RunAcceptedEvent(
                context: context,
                acceptedEngineVersion: context.engineVersion,
                initialItems: [userItem]
            ))
        )
    )
    let acceptance = AgentRunAcceptance(
        metadata: AgentRunMetadataRecord(
            context: context,
            acceptedEngineVersion: context.engineVersion,
            writerID: writerID,
            acceptanceCommandID: canaryTestID(seed * 1_000 + 9),
            acceptanceEventID: eventID
        ),
        envelope: envelope
    )
    let store = InMemoryAgentEventJournal(clock: {
        AgentInstant(rawValue: acceptedAt.rawValue + 10_000)
    })
    _ = try await store.accept(acceptance)
    let model = ProviderModelID(rawValue: "fixture-model")
    let provider = try AgentHostedReadOnlyCanaryProvider
        .openAIChatCompletions(model: model)
    let tools = SandboxToolCatalog.all.map(\.descriptor).filter {
        $0.effectClass == .readOnlyLocal
    }.map {
        AgentHostedReadOnlyCanaryCoordinator.providerDefinition(for: $0)
    }
    return ReadCanaryFixture(
        root: root,
        workspace: workspace,
        workspaceIdentity: workspaceIdentity,
        backend: backend,
        store: store,
        acceptance: acceptance,
        provider: provider,
        request: CanonicalProviderRequest(
            requestID: "read-canary-request-\(seed)",
            model: model,
            messages: [ProviderMessage(
                role: .user,
                content: [.text("Inspect note.txt")]
            )],
            tools: tools,
            options: ProviderGenerationOptions(
                maximumOutputTokens: 4_096,
                temperature: 0,
                parallelToolCalls: false,
                toolChoice: .auto
            )
        ),
        model: model
    )
}

private actor CountingReadBackend: DeveloperReadOnlyCanaryToolBackend {
    private let output: String
    private var calls = 0

    init(output: String) {
        self.output = output
    }

    func executeReadOnly(
        _ request: LegacySandboxToolRequest
    ) async throws -> String {
        _ = request
        calls += 1
        return output
    }

    func callCount() -> Int { calls }
}

private final class ReadSwapRestoreProbe: @unchecked Sendable {
    private enum State: Equatable { case ready, swapped, restored }

    private let lock = NSLock()
    private let root: URL
    private let parent: URL
    private let parked: URL
    private let outside: URL
    private let originalRootModificationDate: Date
    private let originalParentModificationDate: Date
    private var state = State.ready

    init(root: URL, parent: URL, parked: URL, outside: URL) throws {
        self.root = root
        self.parent = parent
        self.parked = parked
        self.outside = outside
        let rootAttributes = try FileManager.default.attributesOfItem(
            atPath: root.path
        )
        let parentAttributes = try FileManager.default.attributesOfItem(
            atPath: parent.path
        )
        guard let rootDate = rootAttributes[.modificationDate] as? Date,
              let parentDate = parentAttributes[.modificationDate] as? Date else {
            throw ReadSwapRestoreProbeError.missingModificationDate
        }
        originalRootModificationDate = rootDate
        originalParentModificationDate = parentDate
    }

    func swapToOutside() throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .ready else {
            throw ReadSwapRestoreProbeError.invalidState
        }
        try FileManager.default.moveItem(at: parent, to: parked)
        try FileManager.default.createSymbolicLink(
            at: parent,
            withDestinationURL: outside
        )
        state = .swapped
    }

    func restoreOriginal() throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .swapped else {
            throw ReadSwapRestoreProbeError.invalidState
        }
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: parked, to: parent)
        // Restore bytes, path identity, and mtimes. The filesystem-owned ctime
        // still records the swap, which the workspace digest must bind.
        try FileManager.default.setAttributes(
            [.modificationDate: originalParentModificationDate],
            ofItemAtPath: parent.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: originalRootModificationDate],
            ofItemAtPath: root.path
        )
        state = .restored
    }

    var didSwapAndRestore: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .restored
    }
}

private enum ReadSwapRestoreProbeError: Error {
    case missingModificationDate
    case invalidState
}

private actor ReadCanaryTransport: ProviderTransport {
    enum Mode: Sendable {
        case toolThenFinal(name: String, callID: String, arguments: JSONValue)
        case repeatedToolCall
        case parallelTools
        case finalOnly
        case waitForCancellation
    }

    private let mode: Mode
    private let model: ProviderModelID
    private var calls = 0
    private var recordedRequests: [ProviderEncodedRequest] = []

    init(mode: Mode, model: ProviderModelID) {
        self.mode = mode
        self.model = model
    }

    func stream(
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        _ = descriptor
        _ = scope
        calls += 1
        recordedRequests.append(request)
        let callNumber = calls
        let frames: [ProviderWireFrame]
        switch mode {
        case let .toolThenFinal(name, callID, arguments):
            frames = callNumber == 1
                ? readToolFrames(
                    model: model,
                    responseID: "read-tool-\(callNumber)",
                    name: name,
                    callID: callID,
                    arguments: arguments
                )
                : readFinalFrames(model: model, responseID: "read-final")
        case .repeatedToolCall:
            frames = readToolFrames(
                model: model,
                responseID: "read-replay-\(callNumber)",
                name: "read_file",
                callID: "call-replayed",
                arguments: .object(["path": .string("note.txt")])
            )
        case .parallelTools:
            frames = readParallelToolFrames(model: model)
        case .finalOnly:
            frames = readFinalFrames(model: model, responseID: "read-recovered")
        case .waitForCancellation:
            while true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        return AsyncThrowingStream { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
    }

    func callCount() -> Int { calls }
    func requests() -> [ProviderEncodedRequest] { recordedRequests }
}

private actor CompletionPausingJournal: AgentEventJournal {
    private let backing: InMemoryAgentEventJournal
    private var completionEntered = false
    private var completionReleased = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(backing: InMemoryAgentEventJournal) {
        self.backing = backing
    }

    func accept(_ acceptance: AgentRunAcceptance) async throws -> AgentJournalCommit {
        try await backing.accept(acceptance)
    }

    func append(_ envelope: AgentEventEnvelope) async throws -> AgentJournalCommit {
        let commit = try await backing.append(envelope)
        guard envelope.event.payload.kind == .toolCompleted else { return commit }
        completionEntered = true
        if !completionReleased {
            await withCheckedContinuation { continuation in
                if completionReleased {
                    continuation.resume()
                } else {
                    completionWaiters.append(continuation)
                }
            }
        }
        return commit
    }

    func metadata(for runID: RunID) async throws -> AgentRunMetadataRecord? {
        try await backing.metadata(for: runID)
    }

    func events(
        for runID: RunID,
        after sequence: EventSequence?
    ) async throws -> [StoredAgentEvent] {
        try await backing.events(for: runID, after: sequence)
    }

    func projectionBatch(
        after offset: AgentJournalOffset,
        limit: Int
    ) async throws -> AgentProjectionBatch {
        try await backing.projectionBatch(after: offset, limit: limit)
    }

    func loadCursor(
        for projectionID: AgentProjectionID
    ) async throws -> AgentProjectionCursor? {
        try await backing.loadCursor(for: projectionID)
    }

    func saveCursor(
        _ cursor: AgentProjectionCursor,
        expectedPreviousOffset: AgentJournalOffset
    ) async throws -> AgentProjectionCursorCommit {
        try await backing.saveCursor(
            cursor,
            expectedPreviousOffset: expectedPreviousOffset
        )
    }

    func didEnterCompletion() -> Bool { completionEntered }

    func releaseCompletion() {
        guard !completionReleased else { return }
        completionReleased = true
        let waiters = completionWaiters
        completionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private func waitForCompletionPause(
    _ journal: CompletionPausingJournal
) async throws {
    for _ in 0 ..< 200 {
        if await journal.didEnterCompletion() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw CanaryTransportTestError.timedOut
}

private func readToolFrames(
    model: ProviderModelID,
    responseID: String,
    name: String,
    callID: String,
    arguments: JSONValue
) -> [ProviderWireFrame] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try! encoder.encode(arguments)
    let argumentText = String(decoding: data, as: UTF8.self)
    return [
        .json(.object([
            "id": .string(responseID),
            "model": .string(model.rawValue),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "finish_reason": .null,
                "delta": .object(["tool_calls": .array([.object([
                    "index": .number(.integer(0)),
                    "id": .string(callID),
                    "function": .object([
                        "name": .string(name),
                        "arguments": .string(argumentText),
                    ]),
                ])])]),
            ])]),
        ])),
        .json(.object([
            "id": .string(responseID),
            "model": .string(model.rawValue),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object([:]),
                "finish_reason": .string("tool_calls"),
            ])]),
        ])),
        readUsageFrame(model: model, responseID: responseID),
        .done,
    ]
}

private func readParallelToolFrames(
    model: ProviderModelID
) -> [ProviderWireFrame] {
    let responseID = "read-parallel"
    return [
        .json(.object([
            "id": .string(responseID),
            "model": .string(model.rawValue),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "finish_reason": .null,
                "delta": .object(["tool_calls": .array([
                    .object([
                        "index": .number(.integer(0)),
                        "id": .string("call-a"),
                        "function": .object([
                            "name": .string("read_file"),
                            "arguments": .string(#"{"path":"note.txt"}"#),
                        ]),
                    ]),
                    .object([
                        "index": .number(.integer(1)),
                        "id": .string("call-b"),
                        "function": .object([
                            "name": .string("read_file"),
                            "arguments": .string(#"{"path":"note.txt"}"#),
                        ]),
                    ]),
                ])]),
            ])]),
        ])),
        .json(.object([
            "id": .string(responseID),
            "model": .string(model.rawValue),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object([:]),
                "finish_reason": .string("tool_calls"),
            ])]),
        ])),
        readUsageFrame(model: model, responseID: responseID),
        .done,
    ]
}

private func readFinalFrames(
    model: ProviderModelID,
    responseID: String
) -> [ProviderWireFrame] {
    [
        .json(.object([
            "id": .string(responseID),
            "model": .string(model.rawValue),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object(["content": .string("Finished safely")]),
                "finish_reason": .null,
            ])]),
        ])),
        .json(.object([
            "id": .string(responseID),
            "model": .string(model.rawValue),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object([:]),
                "finish_reason": .string("stop"),
            ])]),
        ])),
        readUsageFrame(model: model, responseID: responseID),
        .done,
    ]
}

private func readUsageFrame(
    model: ProviderModelID,
    responseID: String
) -> ProviderWireFrame {
    .json(.object([
        "id": .string(responseID),
        "model": .string(model.rawValue),
        "choices": .array([]),
        "usage": .object([
            "prompt_tokens": .number(.integer(20)),
            "completion_tokens": .number(.integer(5)),
        ]),
    ]))
}

private func waitForReadTransportCalls(
    _ expected: Int,
    transport: ReadCanaryTransport
) async throws {
    // A saturated full-suite runner can take more than one second to schedule
    // the coordinator task even though the actor itself is healthy.
    for _ in 0 ..< 2_000 {
        if await transport.callCount() >= expected { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw CanaryTransportTestError.timedOut
}

private func XCTAssertThrowsErrorAsync(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected async operation to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}


private enum CanaryTransportTestError: Error {
    case timedOut
}

private func canaryTestID<Tag: AgentIdentifierTag>(
    _ value: UInt64
) -> AgentIdentifier<Tag> {
    let suffix = String(format: "%012llX", value)
    return AgentIdentifier(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-\(suffix)"
    )!)
}
#endif

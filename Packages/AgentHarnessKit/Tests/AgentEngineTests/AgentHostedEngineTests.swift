import AgentDomain
@testable import AgentEngine
import AgentPolicy
import AgentProviders
import AgentStore
import AgentTools
import Foundation
import XCTest

final class AgentHostedEngineTests: XCTestCase {
    func testTextSuccessPersistsFreshDispatchBeforeOneTransport() async throws {
        let transport = EngineFixtureTransport(outcomes: [
            .frames(Self.textFrames("Hermes-ready")),
        ])
        let fixture = try EngineFixture(transport: transport)

        let state = try await fixture.engine.execute(fixture.command)

        XCTAssertEqual(
            state.phase,
            .completed,
            "\(String(describing: state.lastError))"
        )
        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 1)
        XCTAssertEqual(state.modelAttempts.count, 1)
        guard case let .recordedV1_1(_, scope, ordinal, seed) =
                try XCTUnwrap(state.modelAttempts.first).providerAttempt
        else { return XCTFail("Missing v1.1 attempt metadata") }
        XCTAssertEqual(scope.requestID, "engine-request")
        XCTAssertEqual(ordinal, 1)
        let expectedSeed = await fixture.identities.recoverySeed(
            runID: fixture.context.lineage.runID,
            attemptOrdinal: 1
        )
        XCTAssertEqual(seed, expectedSeed)
        let events = try await fixture.events()
        XCTAssertEqual(events.map(\.event.payload.kind), [
            .runAccepted,
            .runStarted,
            .contextPrepared,
            .modelRequestStarted,
            .modelResponseCommitted,
            .runCompleted,
        ])
        let answer = state.modelItems.compactMap { item -> String? in
            guard case let .message(message) = item.payload,
                  message.role == .assistant,
                  case let .text(text) = message.content.first
            else { return nil }
            return text
        }.last
        XCTAssertEqual(answer, "Hermes-ready")
    }

    func testLiveOutputSinkReceivesOnlyOrderedClassifiedTextDeltas() async throws {
        let transport = EngineFixtureTransport(outcomes: [
            .frames([
                Self.chatFrame(
                    delta: ["content": .string("Hermes-")],
                    finishReason: nil
                ),
                Self.chatFrame(
                    delta: ["content": .string("ready")],
                    finishReason: nil
                ),
                Self.chatFrame(delta: [:], finishReason: "stop"),
                Self.usageFrame(),
                .done,
            ]),
        ])
        let sink = RecordingLiveOutputSink()
        let fixture = try EngineFixture(
            transport: transport,
            liveOutputSink: sink
        )

        let state = try await fixture.engine.execute(fixture.command)

        XCTAssertEqual(state.phase, .completed)
        let deltas = await sink.snapshot()
        XCTAssertEqual(deltas.map(\.text), ["Hermes-", "ready"])
        XCTAssertEqual(deltas.map(\.eventSequence), [1, 2])
        XCTAssertEqual(Set(deltas.map(\.runID)), [fixture.context.lineage.runID])
        XCTAssertEqual(Set(deltas.map(\.attemptID)).count, 1)
        XCTAssertTrue(deltas.allSatisfy { $0.outputIndex == 0 })
    }

    func testMultiRoundReadToolCommitsResultBeforeSecondProviderAttempt() async throws {
        let transport = EngineFixtureTransport(outcomes: [
            .frames(Self.toolFrames(
                name: "read_file",
                callID: "provider-call-read",
                arguments: #"{"path":"README.md"}"#
            )),
            .frames(Self.textFrames("Read complete")),
        ])
        let reads = RecordingReadExecutor(output: .init(
            output: .object(["text": .string("fixture")]),
            evidence: [.init(kind: "inspected_path", digest: Self.digest(8))]
        ))
        let fixture = try EngineFixture(
            transport: transport,
            readExecutor: reads
        )

        let state = try await fixture.engine.execute(fixture.command)

        XCTAssertEqual(state.phase, .completed)
        let transportCalls = await transport.callCount()
        let readCalls = await reads.callCount()
        XCTAssertEqual(transportCalls, 2)
        XCTAssertEqual(readCalls, 1)
        XCTAssertEqual(state.modelAttempts.count, 2)
        let tool = try XCTUnwrap(state.tools.first)
        XCTAssertEqual(tool.invocation.providerCallID, "provider-call-read")
        XCTAssertEqual(tool.status, .completed)
        XCTAssertNil(tool.effectKey)
        XCTAssertNil(tool.effectReceipt)
        XCTAssertEqual(tool.result?.status, .succeeded)
        let kinds = try await fixture.events().map(\.event.payload.kind)
        let completedIndex = try XCTUnwrap(kinds.firstIndex(of: .toolCompleted))
        let secondDispatchIndex = try XCTUnwrap(
            kinds.lastIndex(of: .modelRequestStarted)
        )
        XCTAssertLessThan(completedIndex, secondDispatchIndex)
    }

    func testApprovedMutationUsesExactEffectReceiptOrdering() async throws {
        let transport = EngineFixtureTransport(outcomes: [
            .frames(Self.toolFrames(
                name: "write_file",
                callID: "provider-call-write",
                arguments: #"{"path":"note.txt","contents":"safe"}"#
            )),
            .frames(Self.textFrames("Write complete")),
        ])
        let mutation = RecordingMutationExecutor(decisionRequired: true)
        let approvals = ImmediateApprovalResolver(decision: .approved)
        let fixture = try EngineFixture(
            transport: transport,
            mutationExecutor: mutation,
            approvalResolver: approvals
        )

        let state = try await fixture.engine.execute(fixture.command)

        XCTAssertEqual(state.phase, .completed)
        let mutationApplies = await mutation.applyCount()
        XCTAssertEqual(mutationApplies, 1)
        let tool = try XCTUnwrap(state.tools.first)
        XCTAssertEqual(tool.status, .completed)
        XCTAssertNotNil(tool.effectKey)
        XCTAssertNotNil(tool.effectReceipt)
        XCTAssertEqual(tool.effectReceipt?.effectKey, tool.effectKey)
        let kinds = try await fixture.events().map(\.event.payload.kind)
        try assertOrdered([
            .toolProposed,
            .approvalRequested,
            .approvalResolved,
            .toolScheduled,
            .toolStarted,
            .toolApplied,
            .toolCompleted,
        ], in: kinds)
    }

    func testRejectedMutationHasCanonicalFailedResultAndNoEffectEvents() async throws {
        let transport = EngineFixtureTransport(outcomes: [
            .frames(Self.toolFrames(
                name: "write_file",
                callID: "provider-call-rejected",
                arguments: #"{"path":"note.txt","contents":"blocked"}"#
            )),
            .frames(Self.textFrames("Understood")),
        ])
        let mutation = RecordingMutationExecutor(decisionRequired: true)
        let fixture = try EngineFixture(
            transport: transport,
            mutationExecutor: mutation,
            approvalResolver: ImmediateApprovalResolver(decision: .rejected)
        )

        let state = try await fixture.engine.execute(fixture.command)

        let mutationApplies = await mutation.applyCount()
        XCTAssertEqual(mutationApplies, 0)
        let tool = try XCTUnwrap(state.tools.first)
        XCTAssertEqual(tool.status, .rejected)
        XCTAssertEqual(tool.result?.isCanonicalApprovalRejection, true)
        XCTAssertNil(tool.effectKey)
        XCTAssertNil(tool.effectReceipt)
        let kinds = try await fixture.events().map(\.event.payload.kind)
        XCTAssertFalse(kinds.contains(.toolScheduled))
        XCTAssertFalse(kinds.contains(.toolStarted))
        XCTAssertFalse(kinds.contains(.toolApplied))
    }

    func testTamperedMutationReceiptInterruptsWithoutAppliedOrCompleted() async throws {
        let transport = EngineFixtureTransport(outcomes: [
            .frames(Self.toolFrames(
                name: "write_file",
                callID: "provider-call-tamper",
                arguments: #"{"path":"note.txt","contents":"unsafe"}"#
            )),
        ])
        let mutation = RecordingMutationExecutor(
            decisionRequired: false,
            tamperReceiptEffectKey: true
        )
        let fixture = try EngineFixture(
            transport: transport,
            mutationExecutor: mutation
        )

        let state = try await fixture.engine.execute(fixture.command)

        XCTAssertEqual(state.phase, .interrupted)
        XCTAssertEqual(state.lastError?.code, "unsafe_recovery_boundary")
        let tool = try XCTUnwrap(state.tools.first)
        XCTAssertEqual(tool.status, .running)
        XCTAssertNil(tool.effectReceipt)
        let kinds = try await fixture.events().map(\.event.payload.kind)
        XCTAssertFalse(kinds.contains(.toolApplied))
        XCTAssertFalse(kinds.contains(.toolCompleted))
    }

    func testDispatchBarrierFailurePerformsZeroTransport() async throws {
        let backing = InMemoryAgentEventJournal(clock: { AgentInstant(rawValue: 10) })
        let journal = DispatchFailingJournal(backing: backing)
        let transport = EngineFixtureTransport(outcomes: [
            .frames(Self.textFrames("must-not-run")),
        ])
        let fixture = try EngineFixture(
            transport: transport,
            journal: journal
        )

        do {
            _ = try await fixture.engine.execute(fixture.command)
            XCTFail("Dispatch persistence failure unexpectedly completed")
        } catch let error as AgentEngineError {
            XCTAssertEqual(error, .persistence("append_failed"))
        }
        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 0)
        let events = try await backing.events(
            for: fixture.context.lineage.runID,
            after: nil
        )
        XCTAssertFalse(events.contains(where: {
            $0.event.payload.kind == .modelRequestStarted
        }))
    }

    func testRetryFallbackUsesUniquePersistedAttemptsAndOneTransportEach() async throws {
        let primary = OpenAICompatibleAdapter(configuration: .init(
            providerID: .init(rawValue: "primary"),
            adapterID: .init(rawValue: "primary-chat"),
            modelID: .init(rawValue: "fixture-model"),
            capabilities: .openAIChatBaseline
        ))
        let fallback = OpenAICompatibleAdapter(configuration: .init(
            providerID: .init(rawValue: "fallback"),
            adapterID: .init(rawValue: "fallback-chat"),
            modelID: .init(rawValue: "fixture-model"),
            capabilities: .openAIChatBaseline
        ))
        let transport = EngineFixtureTransport(outcomes: [
            .failure(.init(
                category: .transport,
                code: "fixture_transport",
                publicMessage: "Temporary failure",
                providerID: primary.descriptor.route.providerID,
                adapterID: primary.descriptor.route.adapterID
            )),
            .frames(Self.textFrames("fallback-ok")),
        ])
        let fixture = try EngineFixture(
            transport: transport,
            adapters: [primary, fallback],
            preferredAdapterIDs: [
                primary.descriptor.route.adapterID,
                fallback.descriptor.route.adapterID,
            ],
            configuration: .init(recoveryPolicy: .init(
                maximumAttemptsPerRoute: 1,
                maximumFallbacks: 1,
                baseBackoffMilliseconds: 0,
                maximumBackoffMilliseconds: 0,
                jitterBasisPoints: 0
            ))
        )

        let state = try await fixture.engine.execute(fixture.command)

        XCTAssertEqual(state.phase, .completed)
        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 2)
        let scopes = await transport.scopes()
        XCTAssertEqual(Set(scopes).count, 2)
        XCTAssertEqual(state.modelAttempts.map(\.route.adapter), [
            "primary-chat", "fallback-chat",
        ])
        let metadata = state.modelAttempts.compactMap { attempt -> (UInt32, UInt64)? in
            guard case let .recordedV1_1(_, _, ordinal, seed) =
                    attempt.providerAttempt
            else { return nil }
            return (ordinal, seed)
        }
        XCTAssertEqual(metadata.map(\.0), [1, 2])
        XCTAssertNotEqual(metadata[0].1, metadata[1].1)
        let kinds = try await fixture.events().map(\.event.payload.kind)
        try assertOrdered([
            .modelRequestFailed,
            .providerRouteChanged,
            .retryScheduled,
            .modelRequestStarted,
            .modelResponseCommitted,
        ], in: kinds)
    }

    func testRecoveryAfterAcceptanceResumesBeforeFirstProviderDispatch() async throws {
        let backing = InMemoryAgentEventJournal(
            clock: { AgentInstant(rawValue: 8_000) }
        )
        let transport = EngineFixtureTransport(outcomes: [
            .frames(Self.textFrames("recovered acceptance")),
        ])
        let fixture = try EngineFixture(
            transport: transport,
            journal: backing
        )
        try await seedJournal(fixture: fixture, payloads: [])

        let handle = try await fixture.engine.recover(
            runID: fixture.context.lineage.runID
        )
        let state = try await fixture.engine.wait(for: handle)

        XCTAssertEqual(state.phase, .completed)
        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 1)
        let records = try await fixture.events()
        let resumed = records.compactMap { record -> Bool? in
            guard case let .runStarted(start) = record.event.payload else {
                return nil
            }
            return start.resumed
        }
        XCTAssertEqual(resumed, [true])
    }

    func testRecoveryAfterProviderCommitDoesNotRedispatchTransport() async throws {
        let backing = InMemoryAgentEventJournal(
            clock: { AgentInstant(rawValue: 8_100) }
        )
        let transport = EngineFixtureTransport(outcomes: [])
        let fixture = try EngineFixture(
            transport: transport,
            journal: backing
        )
        let attemptID: AttemptID = taggedUUID(810)
        let answer = ModelItem(
            id: taggedUUID(811),
            createdAt: AgentInstant(rawValue: 8_110),
            payload: .message(.init(
                role: .assistant,
                content: [.text("already durable")]
            ))
        )
        try await seedJournal(fixture: fixture, payloads: [
            .runStarted(.init()),
            .modelRequestStarted(.init(
                attemptID: attemptID,
                route: fixtureRoute,
                providerAttempt: try fixtureAttemptMetadata(
                    ordinal: 1,
                    attemptID: attemptID
                )
            )),
            .modelResponseCommitted(.init(
                attemptID: attemptID,
                items: [answer],
                usage: .init(inputTokens: 4, outputTokens: 2),
                finishReason: .completed
            )),
        ])

        let handle = try await fixture.engine.recover(
            runID: fixture.context.lineage.runID
        )
        let state = try await fixture.engine.wait(for: handle)

        XCTAssertEqual(state.phase, .completed)
        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 0)
        XCTAssertEqual(state.modelItems.last, answer)
    }

    func testRecoveryAfterDurableReadCompletionStartsOnlyNextModelRound() async throws {
        let backing = InMemoryAgentEventJournal(
            clock: { AgentInstant(rawValue: 8_200) }
        )
        let transport = EngineFixtureTransport(outcomes: [
            .frames(Self.textFrames("continued after read")),
        ])
        let reads = RecordingReadExecutor(output: .init(
            output: .object(["unexpected": .bool(true)])
        ))
        let fixture = try EngineFixture(
            transport: transport,
            journal: backing,
            readExecutor: reads
        )
        let attemptID: AttemptID = taggedUUID(820)
        let callID: ToolCallID = taggedUUID(821)
        let descriptor = try SandboxToolCatalog.canonicalRegistry()
            .descriptor(named: "read_file")
        let arguments: JSONValue = .object([
            "path": .string("README.md"),
        ])
        let invocation = ToolInvocation(
            callID: callID,
            providerCallID: "provider-read-recovery",
            modelAttemptID: attemptID,
            tool: descriptor.identity,
            arguments: arguments,
            canonicalArgumentDigest: try descriptor
                .canonicalArgumentDigest(for: arguments),
            idempotencyKey: "recovery-read",
            effectClass: .readOnlyLocal,
            locality: .onDevice
        )
        let invocationItem = ModelItem(
            id: taggedUUID(822),
            createdAt: AgentInstant(rawValue: 8_210),
            payload: .toolInvocation(invocation)
        )
        let result = ToolResult(
            modelItemID: taggedUUID(823),
            callID: callID,
            status: .succeeded,
            output: .object(["text": .string("durable")])
        )
        try await seedJournal(fixture: fixture, payloads: [
            .runStarted(.init()),
            .modelRequestStarted(.init(
                attemptID: attemptID,
                route: fixtureRoute,
                providerAttempt: try fixtureAttemptMetadata(
                    ordinal: 1,
                    attemptID: attemptID
                )
            )),
            .modelResponseCommitted(.init(
                attemptID: attemptID,
                items: [invocationItem],
                usage: .init(inputTokens: 5, outputTokens: 1),
                finishReason: .toolCalls
            )),
            .toolProposed(.init(invocation: invocation)),
            .toolScheduled(.init(callID: callID)),
            .toolStarted(.init(callID: callID)),
            .toolCompleted(.init(result: result)),
        ])

        let handle = try await fixture.engine.recover(
            runID: fixture.context.lineage.runID
        )
        let state = try await fixture.engine.wait(for: handle)

        XCTAssertEqual(state.phase, .completed)
        let readCalls = await reads.callCount()
        let transportCalls = await transport.callCount()
        XCTAssertEqual(readCalls, 0)
        XCTAssertEqual(transportCalls, 1)
        XCTAssertEqual(state.modelAttempts.count, 2)
    }

    func testRecoveryOfStartedMutationReconcilesAndNeverReapplies() async throws {
        let backing = InMemoryAgentEventJournal(
            clock: { AgentInstant(rawValue: 8_300) }
        )
        let transport = EngineFixtureTransport(outcomes: [])
        let mutation = ReconciliationMutationExecutor()
        let fixture = try EngineFixture(
            transport: transport,
            journal: backing,
            mutationExecutor: mutation
        )
        let attemptID: AttemptID = taggedUUID(830)
        let callID: ToolCallID = taggedUUID(831)
        let descriptor = try SandboxToolCatalog.canonicalRegistry()
            .descriptor(named: "write_file")
        let arguments: JSONValue = .object([
            "path": .string("note.txt"),
            "contents": .string("ambiguous"),
        ])
        let invocation = ToolInvocation(
            callID: callID,
            providerCallID: "provider-write-recovery",
            modelAttemptID: attemptID,
            tool: descriptor.identity,
            arguments: arguments,
            canonicalArgumentDigest: try descriptor
                .canonicalArgumentDigest(for: arguments),
            idempotencyKey: "recovery-write",
            effectClass: .scopedReversibleWrite,
            locality: .onDevice
        )
        let invocationItem = ModelItem(
            id: taggedUUID(832),
            createdAt: AgentInstant(rawValue: 8_310),
            payload: .toolInvocation(invocation)
        )
        let effect = ToolEffectKeyReference(
            effectKeySHA256: try AgentCanonicalSHA256Digest(Self.digest(1))
        )
        try await seedJournal(fixture: fixture, payloads: [
            .runStarted(.init()),
            .modelRequestStarted(.init(
                attemptID: attemptID,
                route: fixtureRoute,
                providerAttempt: try fixtureAttemptMetadata(
                    ordinal: 1,
                    attemptID: attemptID
                )
            )),
            .modelResponseCommitted(.init(
                attemptID: attemptID,
                items: [invocationItem],
                usage: .init(inputTokens: 5, outputTokens: 1),
                finishReason: .toolCalls
            )),
            .toolProposed(.init(invocation: invocation)),
            .toolScheduled(.init(callID: callID, effect: effect)),
            .toolStarted(.init(callID: callID, effect: effect)),
        ])

        let handle = try await fixture.engine.recover(
            runID: fixture.context.lineage.runID
        )
        let state = try await fixture.engine.wait(for: handle)

        XCTAssertEqual(state.phase, .interrupted)
        let recoveryCalls = await mutation.recoveryCallCount()
        let applyCalls = await mutation.applyCallCount()
        let transportCalls = await transport.callCount()
        XCTAssertEqual(recoveryCalls, 1)
        XCTAssertEqual(applyCalls, 0)
        XCTAssertEqual(transportCalls, 0)
        XCTAssertEqual(state.tools.first?.status, .running)
    }

    func testSuspendedApprovalBrokerAcceptsOnlyExactBoundDecision() async throws {
        let transport = EngineFixtureTransport(outcomes: [
            .frames(Self.toolFrames(
                name: "write_file",
                callID: "provider-call-broker",
                arguments: #"{"path":"note.txt","contents":"approved"}"#
            )),
            .frames(Self.textFrames("Broker-approved")),
        ])
        let broker = BrokerApprovalResolver()
        let mutation = RecordingMutationExecutor(decisionRequired: true)
        let fixture = try EngineFixture(
            transport: transport,
            mutationExecutor: mutation,
            approvalResolver: broker
        )

        let handle = try await fixture.engine.start(fixture.command)
        try await waitUntil { await broker.pendingRequest() != nil }
        let pendingRequest = await broker.pendingRequest()
        let request = try XCTUnwrap(pendingRequest)

        await XCTAssertThrowsErrorAsync {
            try await fixture.engine.deliverApprovalDecision(
                ApprovalDecisionCommand(
                    requestID: request.requestID,
                    callID: taggedUUID(79_999),
                    decision: .approved,
                    decidedAt: AgentInstant(rawValue: 4_002)
                ),
                runID: fixture.context.lineage.runID
            )
        }
        let pendingAfterMismatch = await broker.pendingRequest()
        XCTAssertNotNil(pendingAfterMismatch)

        try await fixture.engine.deliverApprovalDecision(
            ApprovalDecisionCommand(
                requestID: request.requestID,
                callID: request.binding.callID,
                decision: .approved,
                decidedAt: AgentInstant(rawValue: 4_003),
                rationale: "fixture approval"
            ),
            runID: fixture.context.lineage.runID
        )
        let state = try await fixture.engine.wait(for: handle)

        XCTAssertEqual(state.phase, .completed)
        let deliveryCount = await broker.deliveryCount()
        let applyCount = await mutation.applyCount()
        XCTAssertEqual(deliveryCount, 1)
        XCTAssertEqual(applyCount, 1)
        let resolution = try XCTUnwrap(state.approvals.first?.resolution)
        XCTAssertEqual(resolution.requestID, request.requestID)
        XCTAssertEqual(resolution.callID, request.binding.callID)
        XCTAssertEqual(resolution.decision, .approved)
        XCTAssertEqual(resolution.rationale, "fixture approval")
    }

    func testCancellationDuringContextPreparationDrainsBeforeTerminalEvents() async throws {
        let preparer = BlockingContextPreparer()
        let propagator = RecordingCancellationPropagator()
        let transport = EngineFixtureTransport(outcomes: [
            .frames(Self.textFrames("must-not-dispatch")),
        ])
        let fixture = try EngineFixture(
            transport: transport,
            contextPreparer: preparer,
            cancellationPropagator: propagator
        )

        let handle = try await fixture.engine.start(fixture.command)
        try await waitUntil { await preparer.hasEntered() }
        let state = try await fixture.engine.cancel(
            CancelCommand(reason: .userRequested),
            runID: handle.runID
        )

        XCTAssertEqual(state.phase, .cancelled)
        let transportCalls = await transport.callCount()
        let propagationCalls = await propagator.callCount()
        XCTAssertEqual(transportCalls, 0)
        XCTAssertEqual(propagationCalls, 1)
        try await assertCancellationTail(fixture)
    }

    func testCancellationDuringProviderSuppressesLateFrames() async throws {
        let transport = LateReturningProviderTransport(
            frames: Self.textFrames("late-provider-result")
        )
        let fixture = try EngineFixture(transport: transport)

        let handle = try await fixture.engine.start(fixture.command)
        try await waitUntil { await transport.hasEntered() }
        let state = try await fixture.engine.cancel(
            CancelCommand(reason: .userRequested),
            runID: handle.runID
        )

        XCTAssertEqual(state.phase, .cancelled)
        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 1)
        let kinds = try await fixture.events().map(\.event.payload.kind)
        XCTAssertTrue(kinds.contains(.modelRequestStarted))
        XCTAssertFalse(kinds.contains(.modelResponseCommitted))
        try await assertCancellationTail(fixture)
    }

    func testCancellationDuringReadToolSuppressesLateCompletion() async throws {
        let transport = EngineFixtureTransport(outcomes: [
            .frames(Self.toolFrames(
                name: "read_file",
                callID: "provider-call-cancel-read",
                arguments: #"{"path":"README.md"}"#
            )),
        ])
        let reads = LateReturningReadExecutor()
        let fixture = try EngineFixture(
            transport: transport,
            readExecutor: reads
        )

        let handle = try await fixture.engine.start(fixture.command)
        try await waitUntil { await reads.hasEntered() }
        let state = try await fixture.engine.cancel(
            CancelCommand(reason: .userRequested),
            runID: handle.runID
        )

        XCTAssertEqual(state.phase, .cancelled)
        let readCalls = await reads.callCount()
        XCTAssertEqual(readCalls, 1)
        let kinds = try await fixture.events().map(\.event.payload.kind)
        XCTAssertTrue(kinds.contains(.toolStarted))
        XCTAssertFalse(kinds.contains(.toolCompleted))
        try await assertCancellationTail(fixture)
    }

    func testCancellationDuringApprovalWaitLeavesNoResolutionOrEffect() async throws {
        let transport = EngineFixtureTransport(outcomes: [
            .frames(Self.toolFrames(
                name: "write_file",
                callID: "provider-call-cancel-approval",
                arguments: #"{"path":"note.txt","contents":"pending"}"#
            )),
        ])
        let approvals = BlockingApprovalResolver()
        let mutation = RecordingMutationExecutor(decisionRequired: true)
        let fixture = try EngineFixture(
            transport: transport,
            mutationExecutor: mutation,
            approvalResolver: approvals
        )

        let handle = try await fixture.engine.start(fixture.command)
        try await waitUntil { await approvals.hasEntered() }
        let state = try await fixture.engine.cancel(
            CancelCommand(reason: .userRequested),
            runID: handle.runID
        )

        XCTAssertEqual(state.phase, .cancelled)
        let mutationApplies = await mutation.applyCount()
        XCTAssertEqual(mutationApplies, 0)
        let kinds = try await fixture.events().map(\.event.payload.kind)
        XCTAssertTrue(kinds.contains(.approvalRequested))
        XCTAssertFalse(kinds.contains(.approvalResolved))
        XCTAssertFalse(kinds.contains(.toolScheduled))
        XCTAssertFalse(kinds.contains(.toolApplied))
        try await assertCancellationTail(fixture)
    }

    func testCancellationDuringMutationApplySuppressesLateReceipt() async throws {
        let transport = EngineFixtureTransport(outcomes: [
            .frames(Self.toolFrames(
                name: "write_file",
                callID: "provider-call-cancel-mutation",
                arguments: #"{"path":"note.txt","contents":"late"}"#
            )),
        ])
        let mutation = LateReturningMutationExecutor()
        let fixture = try EngineFixture(
            transport: transport,
            mutationExecutor: mutation
        )

        let handle = try await fixture.engine.start(fixture.command)
        try await waitUntil { await mutation.hasEnteredApply() }
        let state = try await fixture.engine.cancel(
            CancelCommand(reason: .userRequested),
            runID: handle.runID
        )

        XCTAssertEqual(state.phase, .cancelled)
        let mutationApplies = await mutation.applyCount()
        XCTAssertEqual(mutationApplies, 1)
        let kinds = try await fixture.events().map(\.event.payload.kind)
        XCTAssertTrue(kinds.contains(.toolStarted))
        XCTAssertFalse(kinds.contains(.toolApplied))
        XCTAssertFalse(kinds.contains(.toolCompleted))
        try await assertCancellationTail(fixture)
    }

    func testDuplicateOwnerAndStaleFenceAreRejected() async throws {
        let index = InMemoryAgentEngineRunIndex()
        let runID: RunID = taggedUUID(1)
        let first = try await index.claim(
            runID: runID,
            ownerID: taggedRawUUID(2),
            mode: .newRun
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await index.claim(
                runID: runID,
                ownerID: taggedRawUUID(3),
                mode: .newRun
            )
        }
        let replacement = try await index.claim(
            runID: runID,
            ownerID: taggedRawUUID(4),
            mode: .recovery
        )
        XCTAssertNotEqual(first, replacement)
        await XCTAssertThrowsErrorAsync {
            try await index.validate(first)
        }
        try await index.validate(replacement)
    }

    private func assertOrdered(
        _ expected: [AgentEventKind],
        in actual: [AgentEventKind],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var cursor = actual.startIndex
        for kind in expected {
            guard let index = actual[cursor...].firstIndex(of: kind) else {
                XCTFail("Missing ordered event \(kind)", file: file, line: line)
                return
            }
            cursor = actual.index(after: index)
        }
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0 ..< 500 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for engine fixture stage", file: file, line: line)
        throw EngineFixtureError.timeout
    }

    private func assertCancellationTail(
        _ fixture: EngineFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let kinds = try await fixture.events().map(\.event.payload.kind)
        XCTAssertGreaterThanOrEqual(kinds.count, 2, file: file, line: line)
        XCTAssertEqual(
            Array(kinds.suffix(2)),
            [.cancellationRequested, .runCancelled],
            file: file,
            line: line
        )
    }

    private static func textFrames(_ text: String) -> [ProviderWireFrame] {
        [
            chatFrame(delta: ["content": .string(text)], finishReason: nil),
            chatFrame(delta: [:], finishReason: "stop"),
            usageFrame(),
            .done,
        ]
    }

    private static func toolFrames(
        name: String,
        callID: String,
        arguments: String
    ) -> [ProviderWireFrame] {
        [
            chatFrame(delta: [
                "tool_calls": .array([.object([
                    "index": .number(.integer(0)),
                    "id": .string(callID),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(name),
                        "arguments": .string(arguments),
                    ]),
                ])]),
            ], finishReason: nil),
            chatFrame(delta: [:], finishReason: "tool_calls"),
            usageFrame(),
            .done,
        ]
    }

    private static func chatFrame(
        delta: [String: JSONValue],
        finishReason: String?
    ) -> ProviderWireFrame {
        .json(.object([
            "id": .string("engine-response"),
            "model": .string("fixture-model"),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object(delta),
                "finish_reason": finishReason.map(JSONValue.string) ?? .null,
            ])]),
        ]))
    }

    private static func usageFrame() -> ProviderWireFrame {
        .json(.object([
            "id": .string("engine-response"),
            "model": .string("fixture-model"),
            "choices": .array([]),
            "usage": .object([
                "prompt_tokens": .number(.integer(4)),
                "completion_tokens": .number(.integer(2)),
            ]),
        ]))
    }

    fileprivate static func digest(_ value: Int) -> String {
        "sha256:" + String(repeating: String(value % 10), count: 64)
    }
}

private struct EngineFixture {
    let journal: any AgentEventJournal
    let context: AgentRunContext
    let command: AgentCommand
    let identities: DeterministicEngineIdentities
    let engine: AgentEngine

    init(
        transport: any ProviderTransport,
        journal: (any AgentEventJournal)? = nil,
        adapters: [any ProviderAdapter]? = nil,
        preferredAdapterIDs: [ProviderAdapterID]? = nil,
        readExecutor: any AgentReadOnlyToolExecuting = RecordingReadExecutor(
            output: .init(output: .object([:]))
        ),
        mutationExecutor: any AgentMutationPolicyExecuting =
            RecordingMutationExecutor(decisionRequired: false),
        approvalResolver: any AgentApprovalResolving =
            ImmediateApprovalResolver(decision: .approved),
        contextPreparer: (any AgentContextPreparing)? = nil,
        cancellationPropagator: any AgentCancellationPropagating =
            NoopAgentCancellationPropagator(),
        liveOutputSink: any AgentLiveOutputSink = NoopAgentLiveOutputSink(),
        configuration: AgentEngineConfiguration = .init()
    ) throws {
        let runID: RunID = taggedUUID(100)
        let acceptedAt = AgentInstant(rawValue: 1_000)
        context = AgentRunContext(
            schemaVersion: .current,
            lineage: .root(runID),
            conversationID: taggedUUID(101),
            projectID: taggedUUID(102),
            workspaceID: taggedUUID(103),
            executionNodeID: taggedUUID(104),
            engineVersion: EngineVersion(rawValue: "hermes-v2-fixture"),
            acceptedAt: acceptedAt,
            features: AgentFeatureSet(["hosted-v2"]),
            cancellation: CancellationLineage(scopeID: taggedUUID(105)),
            initialBudget: AgentBudget(limits: .standard)
        )
        let user = ModelItem(
            id: taggedUUID(106),
            createdAt: acceptedAt,
            payload: .message(ModelMessage(
                role: .user,
                content: [.text("Run the fixture")]
            ))
        )
        command = AgentCommand(
            header: AgentCommandHeader(
                commandID: taggedUUID(107),
                schemaVersion: .current,
                runID: runID,
                issuedAt: acceptedAt,
                correlationID: taggedUUID(108)
            ),
            payload: .send(SendCommand(context: context, userItem: user))
        )
        let backing = journal ?? InMemoryAgentEventJournal(
            clock: { AgentInstant(rawValue: 2_000) }
        )
        self.journal = backing
        identities = DeterministicEngineIdentities(start: 1_000)
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let actualAdapters: [any ProviderAdapter]
        if let adapters {
            actualAdapters = adapters
        } else {
            actualAdapters = [OpenAICompatibleAdapter(configuration: .init(
                providerID: .init(rawValue: "fixture"),
                adapterID: .init(rawValue: "fixture-chat"),
                modelID: .init(rawValue: "fixture-model"),
                capabilities: .openAIChatBaseline
            ))]
        }
        let preferred = preferredAdapterIDs
            ?? actualAdapters.map { $0.descriptor.route.adapterID }
        let preparer = contextPreparer ?? FixtureContextPreparer(
            preferredAdapterIDs: preferred
        )
        engine = AgentEngine(
            journal: backing,
            providerGateway: ModelGateway(
                catalog: try ProviderAdapterCatalog(actualAdapters),
                transport: transport
            ),
            toolRegistry: registry,
            contextPreparer: preparer,
            readOnlyExecutor: readExecutor,
            mutationExecutor: mutationExecutor,
            approvalResolver: approvalResolver,
            clock: DeterministicEngineClock(),
            identities: identities,
            runIndex: InMemoryAgentEngineRunIndex(),
            cancellationPropagator: cancellationPropagator,
            liveOutputSink: liveOutputSink,
            configuration: configuration
        )
    }

    func events() async throws -> [StoredAgentEvent] {
        try await journal.events(for: context.lineage.runID, after: nil)
    }
}

private actor RecordingLiveOutputSink: AgentLiveOutputSink {
    private var deltas: [AgentLiveTextDelta] = []

    func receive(_ delta: AgentLiveTextDelta) {
        deltas.append(delta)
    }

    func snapshot() -> [AgentLiveTextDelta] { deltas }
}

private actor DeterministicEngineIdentities: AgentEngineIdentitySource {
    private var next: Int

    init(start: Int) { next = start }

    func nextUUID() -> UUID {
        defer { next += 1 }
        return taggedRawUUID(next)
    }

    func recoverySeed(runID: RunID, attemptOrdinal: UInt32) -> UInt64 {
        UInt64(attemptOrdinal) &* 1_000_003
            ^ UInt64(runID.rawValue.uuid.15)
    }
}

private actor DeterministicEngineClock: AgentEngineClock {
    private var instant: Int64 = 3_000
    func now() -> AgentInstant {
        defer { instant += 1 }
        return AgentInstant(rawValue: instant)
    }
    func sleep(milliseconds: UInt64) async throws {
        try Task.checkCancellation()
        instant += Int64(clamping: milliseconds)
    }
}

private actor FixtureContextPreparer: AgentContextPreparing {
    private let preferredAdapterIDs: [ProviderAdapterID]
    private var round: Int = 0

    init(preferredAdapterIDs: [ProviderAdapterID]) {
        self.preferredAdapterIDs = preferredAdapterIDs
    }

    func prepareProviderTurn(
        state: AgentRunState,
        tools: [ToolDescriptor]
    ) async throws -> AgentPreparedProviderTurn {
        round += 1
        let definitions = tools.map { descriptor in
            AgentProviders.ProviderToolDefinition(
                name: descriptor.name,
                description: descriptor.description,
                parameters: descriptor.argumentSchema.strictProviderValue,
                strict: true
            )
        }
        return AgentPreparedProviderTurn(
            request: CanonicalProviderRequest(
                requestID: "engine-request",
                model: .init(rawValue: "fixture-model"),
                messages: [.init(
                    role: .user,
                    content: [.text("fixture round \(round)")]
                )],
                tools: definitions,
                options: .init(
                    parallelToolCalls: false,
                    toolChoice: .auto
                )
            ),
            preferredAdapterIDs: preferredAdapterIDs,
            itemIDs: state.modelItems.map(\.id),
            estimatedTokens: UInt64(state.modelItems.count * 4),
            contextDigest: try AgentCanonicalSHA256Digest(
                AgentHostedEngineTests.digest(round)
            )
        )
    }
}

private actor BlockingContextPreparer: AgentContextPreparing {
    private let delegate = FixtureContextPreparer(
        preferredAdapterIDs: [.init(rawValue: "fixture-chat")]
    )
    private var entered = false

    func prepareProviderTurn(
        state: AgentRunState,
        tools: [ToolDescriptor]
    ) async throws -> AgentPreparedProviderTurn {
        entered = true
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return try await delegate.prepareProviderTurn(state: state, tools: tools)
    }

    func hasEntered() -> Bool { entered }
}

private actor RecordingReadExecutor: AgentReadOnlyToolExecuting {
    private let output: AgentReadOnlyToolOutput
    private var calls = 0

    init(output: AgentReadOnlyToolOutput) { self.output = output }

    func executeReadOnly(
        _ request: AgentReadOnlyToolRequest
    ) async throws -> AgentReadOnlyToolOutput {
        XCTAssertEqual(request.invocation.effectClass, .readOnlyLocal)
        calls += 1
        return output
    }

    func callCount() -> Int { calls }
}

private actor LateReturningReadExecutor: AgentReadOnlyToolExecuting {
    private var calls = 0
    private var entered = false

    func executeReadOnly(
        _ request: AgentReadOnlyToolRequest
    ) async throws -> AgentReadOnlyToolOutput {
        calls += 1
        entered = true
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
            // Deliberately simulate a dependency that calls back after cancel.
        }
        return AgentReadOnlyToolOutput(
            output: .object(["late": .bool(true)])
        )
    }

    func hasEntered() -> Bool { entered }
    func callCount() -> Int { calls }
}

private actor RecordingMutationExecutor: AgentMutationPolicyExecuting {
    private let decisionRequired: Bool
    private let tamperReceiptEffectKey: Bool
    private var applies = 0
    private let effect = try! SHA256Digest(AgentHostedEngineTests.digest(1))

    init(
        decisionRequired: Bool,
        tamperReceiptEffectKey: Bool = false
    ) {
        self.decisionRequired = decisionRequired
        self.tamperReceiptEffectKey = tamperReceiptEffectKey
    }

    func prepareMutation(
        context: AgentRunContext,
        invocation: ToolInvocation,
        descriptor: ToolDescriptor,
        sealer: AgentMutationPreparationSealer
    ) async throws -> AgentMutationPreparation {
        let approval: ApprovalRequest?
        if decisionRequired {
            approval = ApprovalRequest(
                requestID: taggedUUID(700),
                binding: ApprovalBinding(
                    runID: context.lineage.runID,
                    callID: invocation.callID,
                    tool: invocation.tool,
                    canonicalArgumentDigest: invocation.canonicalArgumentDigest,
                    workspaceID: context.workspaceID,
                    previewDigest: AgentHostedEngineTests.digest(2),
                    workspaceRevision: "fixture-revision"
                ),
                summary: "Write note.txt",
                requestedAt: AgentInstant(rawValue: 4_000)
            )
        } else {
            approval = nil
        }
        return sealer.seal(
            runID: context.lineage.runID,
            workspaceID: context.workspaceID,
            callID: invocation.callID,
            canonicalArgumentDigest: invocation.canonicalArgumentDigest,
            authorityToken: "fixture-authority:\(invocation.callID.description)",
            effectKeySHA256: effect,
            approvalRequest: approval
        )
    }

    func applyMutation(
        preparation: AgentMutationPreparation,
        approval: ApprovalResolution?
    ) async throws -> AgentMutationToolOutput {
        if decisionRequired { XCTAssertEqual(approval?.decision, .approved) }
        applies += 1
        let returnedEffect = tamperReceiptEffectKey
            ? try SHA256Digest(AgentHostedEngineTests.digest(9))
            : effect
        return Self.output(effect: returnedEffect)
    }

    func recoverMutation(
        context: AgentRunContext,
        invocation: ToolInvocation,
        effectKeySHA256: SHA256Digest
    ) async throws -> AgentMutationRecoveryDisposition {
        .settled(Self.output(effect: effectKeySHA256))
    }

    func applyCount() -> Int { applies }

    private static func output(effect: SHA256Digest) -> AgentMutationToolOutput {
        AgentMutationToolOutput(
            receipt: AgentMutationReceipt(
                effectKeySHA256: effect,
                applicationSHA256: try! SHA256Digest(
                    AgentHostedEngineTests.digest(3)
                ),
                evidenceSHA256: try! SHA256Digest(
                    AgentHostedEngineTests.digest(4)
                ),
                finalRecordSHA256: try! SHA256Digest(
                    AgentHostedEngineTests.digest(5)
                ),
                receiptSHA256: try! SHA256Digest(
                    AgentHostedEngineTests.digest(6)
                )
            ),
            output: .object(["status": .string("written")]),
            evidence: [.init(
                kind: "changed_path",
                digest: AgentHostedEngineTests.digest(7)
            )]
        )
    }
}

private actor LateReturningMutationExecutor: AgentMutationPolicyExecuting {
    private let effect = try! SHA256Digest(AgentHostedEngineTests.digest(1))
    private var applies = 0
    private var enteredApply = false

    func prepareMutation(
        context: AgentRunContext,
        invocation: ToolInvocation,
        descriptor: ToolDescriptor,
        sealer: AgentMutationPreparationSealer
    ) async throws -> AgentMutationPreparation {
        sealer.seal(
            runID: context.lineage.runID,
            workspaceID: context.workspaceID,
            callID: invocation.callID,
            canonicalArgumentDigest: invocation.canonicalArgumentDigest,
            authorityToken: "late-authority:\(invocation.callID.description)",
            effectKeySHA256: effect
        )
    }

    func applyMutation(
        preparation: AgentMutationPreparation,
        approval: ApprovalResolution?
    ) async throws -> AgentMutationToolOutput {
        applies += 1
        enteredApply = true
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
            // Deliberately return a valid but late M6 receipt after cancel.
        }
        return AgentMutationToolOutput(
            receipt: AgentMutationReceipt(
                effectKeySHA256: effect,
                applicationSHA256: try! SHA256Digest(
                    AgentHostedEngineTests.digest(3)
                ),
                evidenceSHA256: try! SHA256Digest(
                    AgentHostedEngineTests.digest(4)
                ),
                finalRecordSHA256: try! SHA256Digest(
                    AgentHostedEngineTests.digest(5)
                ),
                receiptSHA256: try! SHA256Digest(
                    AgentHostedEngineTests.digest(6)
                )
            ),
            output: .object(["late": .bool(true)])
        )
    }

    func recoverMutation(
        context: AgentRunContext,
        invocation: ToolInvocation,
        effectKeySHA256: SHA256Digest
    ) async throws -> AgentMutationRecoveryDisposition {
        .noDurableRecord
    }

    func hasEnteredApply() -> Bool { enteredApply }
    func applyCount() -> Int { applies }
}

private actor ReconciliationMutationExecutor: AgentMutationPolicyExecuting {
    private var recoveries = 0
    private var applies = 0

    func prepareMutation(
        context: AgentRunContext,
        invocation: ToolInvocation,
        descriptor: ToolDescriptor,
        sealer: AgentMutationPreparationSealer
    ) async throws -> AgentMutationPreparation {
        throw EngineFixtureError.unexpectedMutationPreparation
    }

    func applyMutation(
        preparation: AgentMutationPreparation,
        approval: ApprovalResolution?
    ) async throws -> AgentMutationToolOutput {
        applies += 1
        throw EngineFixtureError.unexpectedMutationApply
    }

    func recoverMutation(
        context: AgentRunContext,
        invocation: ToolInvocation,
        effectKeySHA256: SHA256Digest
    ) async throws -> AgentMutationRecoveryDisposition {
        recoveries += 1
        return .reconciliationRequired(effectKeySHA256)
    }

    func recoveryCallCount() -> Int { recoveries }
    func applyCallCount() -> Int { applies }
}

private actor ImmediateApprovalResolver: AgentApprovalResolving {
    private let decision: ApprovalDecision

    init(decision: ApprovalDecision) { self.decision = decision }

    func resolveApproval(_ request: ApprovalRequest) async throws -> ApprovalResolution {
        ApprovalResolution(
            requestID: request.requestID,
            callID: request.binding.callID,
            decision: decision,
            resolvedAt: AgentInstant(rawValue: 4_001)
        )
    }

    func deliverApprovalDecision(
        _ command: ApprovalDecisionCommand,
        for request: ApprovalRequest
    ) async throws {
        guard command.requestID == request.requestID,
              command.callID == request.binding.callID
        else { throw EngineFixtureError.invalidApproval }
    }
}

private actor BrokerApprovalResolver: AgentApprovalResolving {
    private var pending: ApprovalRequest?
    private var continuation: CheckedContinuation<ApprovalResolution, Never>?
    private var deliveries = 0

    func resolveApproval(_ request: ApprovalRequest) async throws -> ApprovalResolution {
        guard pending == nil, continuation == nil else {
            throw EngineFixtureError.invalidApproval
        }
        pending = request
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func deliverApprovalDecision(
        _ command: ApprovalDecisionCommand,
        for request: ApprovalRequest
    ) async throws {
        guard pending == request,
              command.requestID == request.requestID,
              command.callID == request.binding.callID,
              let continuation
        else { throw EngineFixtureError.invalidApproval }
        let resolution = ApprovalResolution(
            requestID: command.requestID,
            callID: command.callID,
            decision: command.decision,
            resolvedAt: command.decidedAt,
            rationale: command.rationale
        )
        pending = nil
        self.continuation = nil
        deliveries += 1
        continuation.resume(returning: resolution)
    }

    func pendingRequest() -> ApprovalRequest? { pending }
    func deliveryCount() -> Int { deliveries }
}

private actor BlockingApprovalResolver: AgentApprovalResolving {
    private var entered = false

    func resolveApproval(_ request: ApprovalRequest) async throws -> ApprovalResolution {
        entered = true
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return ApprovalResolution(
            requestID: request.requestID,
            callID: request.binding.callID,
            decision: .approved,
            resolvedAt: AgentInstant(rawValue: 4_004)
        )
    }

    func deliverApprovalDecision(
        _ command: ApprovalDecisionCommand,
        for request: ApprovalRequest
    ) async throws {
        throw EngineFixtureError.invalidApproval
    }

    func hasEntered() -> Bool { entered }
}

private actor EngineFixtureTransport: ProviderTransport {
    enum Outcome: Sendable {
        case frames([ProviderWireFrame])
        case failure(ProviderFailure)
    }

    private let outcomes: [Outcome]
    private var calls = 0
    private var observedScopes: [ProviderAttemptScope] = []

    init(outcomes: [Outcome]) { self.outcomes = outcomes }

    func stream(
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        let index = calls
        calls += 1
        observedScopes.append(scope)
        guard outcomes.indices.contains(index) else {
            throw ProviderFailureMapper.transportFailure(
                providerID: descriptor.route.providerID,
                adapterID: descriptor.route.adapterID
            )
        }
        switch outcomes[index] {
        case let .frames(frames):
            return AsyncThrowingStream { continuation in
                for frame in frames { continuation.yield(frame) }
                continuation.finish()
            }
        case let .failure(failure):
            throw failure
        }
    }

    func callCount() -> Int { calls }
    func scopes() -> [ProviderAttemptScope] { observedScopes }
}

private actor LateReturningProviderTransport: ProviderTransport {
    private let frames: [ProviderWireFrame]
    private var calls = 0
    private var entered = false

    init(frames: [ProviderWireFrame]) { self.frames = frames }

    func stream(
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        calls += 1
        entered = true
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
            // Deliberately publish frames after the consumer cancelled.
        }
        return AsyncThrowingStream { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
    }

    func hasEntered() -> Bool { entered }
    func callCount() -> Int { calls }
}

private actor RecordingCancellationPropagator: AgentCancellationPropagating {
    private var calls = 0

    func propagateCancellation(
        runID: RunID,
        lineage: CancellationLineage,
        reason: AgentCancellationReason,
        toDescendants: Bool
    ) async {
        calls += 1
    }

    func callCount() -> Int { calls }
}

private actor DispatchFailingJournal: AgentEventJournal {
    private let backing: InMemoryAgentEventJournal

    init(backing: InMemoryAgentEventJournal) { self.backing = backing }

    func accept(_ acceptance: AgentRunAcceptance) async throws -> AgentJournalCommit {
        try await backing.accept(acceptance)
    }

    func append(_ envelope: AgentEventEnvelope) async throws -> AgentJournalCommit {
        if envelope.event.payload.kind == .modelRequestStarted {
            throw EngineFixtureError.dispatchPersistence
        }
        return try await backing.append(envelope)
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
}

private enum EngineFixtureError: Error, Sendable {
    case dispatchPersistence
    case invalidApproval
    case unexpectedMutationPreparation
    case unexpectedMutationApply
    case timeout
}

private let fixtureRoute = ModelRoute(
    provider: "fixture",
    model: "fixture-model",
    adapter: "fixture-chat"
)

private func fixtureAttemptMetadata(
    ordinal: UInt32,
    attemptID: AttemptID
) throws -> ProviderAttemptJournalMetadata {
    .recordedV1_1(
        requestDigest: try AgentCanonicalSHA256Digest(
            AgentHostedEngineTests.digest(Int(ordinal))
        ),
        scope: try ProviderAttemptScopeReference(
            requestID: "engine-request",
            attemptID: attemptID.description
        ),
        ordinal: ordinal,
        recoverySeed: UInt64(ordinal) * 99
    )
}

private func seedJournal(
    fixture: EngineFixture,
    payloads: [AgentEventPayload]
) async throws {
    guard case let .send(send) = fixture.command.payload else {
        throw EngineFixtureError.unexpectedMutationPreparation
    }
    let context = send.context
    let writerID = AgentEventWriterID(runID: context.lineage.runID)
    let acceptanceEventID: EventID = taggedUUID(9_001)
    let acceptanceEvent = AgentEvent(
        header: AgentEventHeader(
            eventID: acceptanceEventID,
            schemaVersion: context.schemaVersion,
            context: context,
            sequence: .first,
            timestamp: context.acceptedAt,
            causationID: fixture.command.header.causationID,
            correlationID: fixture.command.header.correlationID
        ),
        payload: .runAccepted(.init(
            context: context,
            acceptedEngineVersion: context.engineVersion,
            initialItems: [send.userItem]
        ))
    )
    let acceptanceEnvelope = AgentEventEnvelope(
        writerID: writerID,
        writerSequence: .first,
        idempotencyKey: "seed-acceptance",
        event: acceptanceEvent
    )
    _ = try await fixture.journal.accept(AgentRunAcceptance(
        metadata: AgentRunMetadataRecord(
            context: context,
            acceptedEngineVersion: context.engineVersion,
            writerID: writerID,
            acceptanceCommandID: fixture.command.header.commandID,
            acceptanceEventID: acceptanceEventID
        ),
        envelope: acceptanceEnvelope
    ))

    for (index, payload) in payloads.enumerated() {
        let rawSequence = UInt64(index + 2)
        let sequence = EventSequence(rawValue: rawSequence)
        let event = AgentEvent(
            header: AgentEventHeader(
                eventID: taggedUUID(9_001 + index + 1),
                schemaVersion: context.schemaVersion,
                context: context,
                sequence: sequence,
                timestamp: AgentInstant(
                    rawValue: context.acceptedAt.rawValue + Int64(index + 1)
                ),
                causationID: nil,
                correlationID: fixture.command.header.correlationID
            ),
            payload: payload
        )
        _ = try await fixture.journal.append(AgentEventEnvelope(
            writerID: writerID,
            writerSequence: sequence,
            idempotencyKey: "seed-event-\(rawSequence)",
            event: event
        ))
    }
}

private func taggedRawUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
}

private func taggedUUID<Tag: AgentIdentifierTag>(_ value: Int) -> AgentIdentifier<Tag> {
    AgentIdentifier(rawValue: taggedRawUUID(value))
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {}
}

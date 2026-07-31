#if DEBUG
import AgentDomain
import AgentProviders
import AgentStore
import Foundation
import XCTest
@testable import NovaForge

final class AgentHostedTextCanaryRunExecutorTests: XCTestCase {
    func testSuccessAcceptsBeforeNetworkCompletesAndProjectsOnce() async throws {
        let fixture = makeRunExecutorFixture(seed: 1)
        let store = InMemoryAgentEventJournal()
        let transport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let order = RunExecutorOrderProbe()
        await transport.setOrderProbe(order)
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: store,
            transport: transport,
            projection: projection
        )

        let result = try await executor.execute(
            acceptance: fixture.acceptance,
            request: fixture.request,
            didAccept: {
                let metadata = try? await store.metadata(for: fixture.runID)
                await order.record(
                    metadata == fixture.acceptance.metadata
                        ? "didAccept"
                        : "didAcceptBeforeCommit"
                )
            }
        )

        XCTAssertEqual(result.providerResult.items.count, 1)
        XCTAssertEqual(result.terminalCommit.disposition, .committed)
        let events = try await store.events(for: fixture.runID, after: nil)
        XCTAssertEqual(events.map(\.event.header.sequence.rawValue), [1, 2, 3, 4, 5])
        XCTAssertEqual(events.last?.event.payload.kind, .runCompleted)
        XCTAssertEqual(
            events[4].event.header.causationID?.rawValue,
            events[3].event.header.eventID.rawValue
        )
        let state = try AgentJournalReplay.replay(
            events,
            metadata: fixture.acceptance.metadata
        )
        let transportCalls = await transport.callCount()
        let observedOrder = await order.values()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(state.phase, .completed)
        XCTAssertEqual(transportCalls, 1)
        XCTAssertEqual(observedOrder, ["didAccept", "transport"])
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testProviderFailurePreservesAttemptErrorAndCommitsRunFailure() async throws {
        let fixture = makeRunExecutorFixture(seed: 2)
        let store = InMemoryAgentEventJournal()
        let transport = RunExecutorControlledTransport(
            mode: .partialThenFail,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let callback = RunExecutorOrderProbe()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: store,
            transport: transport,
            projection: projection
        )

        let surfaced: AgentErrorInfo
        do {
            _ = try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request,
                didAccept: { await callback.record("didAccept") }
            )
            return XCTFail("A failed provider attempt completed its run")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            guard case let .runFailed(info) = error else {
                return XCTFail("Unexpected executor error: \(error)")
            }
            surfaced = info
        }

        let events = try await store.events(for: fixture.runID, after: nil)
        XCTAssertEqual(events.map(\.event.header.sequence.rawValue), [1, 2, 3, 4, 5])
        guard case let .modelRequestFailed(attemptFailure) = events[3].event.payload,
              case let .runFailed(runFailure) = events[4].event.payload else {
            return XCTFail("Expected an attempt failure followed by run failure")
        }
        XCTAssertEqual(attemptFailure.error.category, .transport)
        XCTAssertFalse(attemptFailure.outputWasCommitted)
        XCTAssertEqual(runFailure.error, attemptFailure.error)
        XCTAssertEqual(surfaced, attemptFailure.error)
        XCTAssertEqual(
            events[4].event.header.causationID?.rawValue,
            events[3].event.header.eventID.rawValue
        )
        XCTAssertFalse(events.contains {
            $0.event.payload.kind == .modelResponseCommitted
        })
        let state = try AgentJournalReplay.replay(
            events,
            metadata: fixture.acceptance.metadata
        )
        let transportCalls = await transport.callCount()
        let callbacks = await callback.values()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(transportCalls, 1)
        XCTAssertEqual(callbacks, ["didAccept"])
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testCancellationSettlesAttemptThenCanonicalCancellationDetached() async throws {
        let fixture = makeRunExecutorFixture(seed: 3)
        let store = InMemoryAgentEventJournal()
        let transport = RunExecutorControlledTransport(
            mode: .waitForCancellation,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: store,
            transport: transport,
            projection: projection
        )
        let execution = Task {
            try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request
            )
        }

        try await waitForRunExecutorTransport(transport)
        execution.cancel()
        let surfaced: AgentErrorInfo
        do {
            _ = try await execution.value
            return XCTFail("A cancelled provider attempt completed its run")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            guard case let .runCancelled(info) = error else {
                return XCTFail("Unexpected executor error: \(error)")
            }
            surfaced = info
        }

        let events = try await store.events(for: fixture.runID, after: nil)
        XCTAssertEqual(
            events.map(\.event.header.sequence.rawValue),
            [1, 2, 3, 4, 5, 6]
        )
        guard case let .modelRequestFailed(attemptFailure) = events[3].event.payload,
              case let .cancellationRequested(request) = events[4].event.payload,
              case let .runCancelled(cancelled) = events[5].event.payload else {
            return XCTFail("Expected attempt, request, and cancellation settlement")
        }
        XCTAssertEqual(attemptFailure.error.category, .cancelled)
        XCTAssertEqual(surfaced, attemptFailure.error)
        XCTAssertEqual(request.reason, .userRequested)
        XCTAssertTrue(request.propagateToDescendants)
        XCTAssertEqual(cancelled.reason, .userRequested)
        XCTAssertEqual(
            events[4].event.header.causationID?.rawValue,
            events[3].event.header.eventID.rawValue
        )
        XCTAssertEqual(
            events[5].event.header.causationID?.rawValue,
            events[4].event.header.eventID.rawValue
        )
        let state = try AgentJournalReplay.replay(
            events,
            metadata: fixture.acceptance.metadata
        )
        let transportCalls = await transport.callCount()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertEqual(transportCalls, 1)
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testValidationFailureSettlesAtNextSequenceWithoutNetwork() async throws {
        let fixture = makeRunExecutorFixture(seed: 4)
        let store = InMemoryAgentEventJournal()
        let transport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: store,
            transport: transport,
            projection: projection
        )
        let mismatched = CanonicalProviderRequest(
            requestID: fixture.request.requestID,
            model: ProviderModelID(rawValue: "untrusted-model"),
            messages: fixture.request.messages,
            options: ProviderGenerationOptions(toolChoice: .none)
        )

        do {
            _ = try await executor.execute(
                acceptance: fixture.acceptance,
                request: mismatched
            )
            XCTFail("A mismatched request entered the provider")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            guard case let .runFailed(info) = error else {
                return XCTFail("Unexpected executor error: \(error)")
            }
            XCTAssertEqual(info.category, .invariantViolation)
            XCTAssertEqual(info.code, "hosted_text_canary_execution_rejected")
        }

        let events = try await store.events(for: fixture.runID, after: nil)
        let transportCalls = await transport.callCount()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(events.map(\.event.header.sequence.rawValue), [1, 2])
        XCTAssertEqual(events.last?.event.payload.kind, .runFailed)
        XCTAssertEqual(transportCalls, 0)
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testDarkReplayReadFailureSettlesWithoutNetwork() async throws {
        let fixture = makeRunExecutorFixture(seed: 5)
        let journal = RunExecutorFaultJournal(mode: .failFirstReplayRead)
        let transport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: journal,
            transport: transport,
            projection: projection
        )

        do {
            _ = try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request
            )
            XCTFail("A failed replay entered the provider")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            guard case .runFailed = error else {
                return XCTFail("Unexpected executor error: \(error)")
            }
        }

        let events = try await journal.events(for: fixture.runID, after: nil)
        let transportCalls = await transport.callCount()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(events.map(\.event.header.sequence.rawValue), [1, 2])
        XCTAssertEqual(events.last?.event.payload.kind, .runFailed)
        XCTAssertEqual(transportCalls, 0)
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testDuplicateAcceptanceRestartDoesNotDispatchOrProject() async throws {
        let fixture = makeRunExecutorFixture(seed: 6)
        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(fixture.acceptance)
        let transport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let callback = RunExecutorOrderProbe()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: store,
            transport: transport,
            projection: projection
        )

        do {
            _ = try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request,
                didAccept: { await callback.record("didAccept") }
            )
            XCTFail("A duplicate acceptance restarted provider work")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            XCTAssertEqual(error, .duplicateAcceptance)
        }

        let events = try await store.events(for: fixture.runID, after: nil)
        let transportCalls = await transport.callCount()
        let callbacks = await callback.values()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(events.map(\.event.header.sequence.rawValue), [1])
        XCTAssertEqual(transportCalls, 0)
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertTrue(projectedRuns.isEmpty)
    }

    func testAcceptanceFailureDoesNotAppendDispatchOrProject() async throws {
        let fixture = makeRunExecutorFixture(seed: 7)
        let store = InMemoryAgentEventJournal()
        await store.failNext(.acceptanceSave, code: "acceptance_fixture")
        let transport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let callback = RunExecutorOrderProbe()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: store,
            transport: transport,
            projection: projection
        )

        do {
            _ = try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request,
                didAccept: { await callback.record("didAccept") }
            )
            XCTFail("A failed acceptance started work")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            XCTAssertEqual(error, .acceptanceFailed)
        }

        let events = try await store.events(for: fixture.runID, after: nil)
        let transportCalls = await transport.callCount()
        let callbacks = await callback.values()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(transportCalls, 0)
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertTrue(projectedRuns.isEmpty)
    }

    func testCompletionAppendFailureFallsBackToOneDurableRunFailure() async throws {
        let fixture = makeRunExecutorFixture(seed: 8)
        let journal = RunExecutorFaultJournal(mode: .failCompletionAppend)
        let transport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: journal,
            transport: transport,
            projection: projection
        )

        do {
            _ = try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request
            )
            XCTFail("A run completed without a durable completion terminal")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            guard case let .runFailed(info) = error else {
                return XCTFail("Unexpected executor error: \(error)")
            }
            XCTAssertEqual(info.category, .persistence)
            XCTAssertEqual(info.code, "hosted_text_run_completion_not_committed")
        }

        let events = try await journal.events(for: fixture.runID, after: nil)
        XCTAssertEqual(events.map(\.event.header.sequence.rawValue), [1, 2, 3, 4, 5])
        XCTAssertEqual(events.filter {
            $0.event.payload.kind == .runCompleted ||
                $0.event.payload.kind == .runFailed ||
                $0.event.payload.kind == .runCancelled
        }.map(\.event.payload.kind), [.runFailed])
        let state = try AgentJournalReplay.replay(
            events,
            metadata: fixture.acceptance.metadata
        )
        let transportCalls = await transport.callCount()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(transportCalls, 1)
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testProjectionFailureLeavesCompletedTerminalUntouched() async throws {
        let fixture = makeRunExecutorFixture(seed: 9)
        let store = InMemoryAgentEventJournal()
        let transport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe(shouldFail: true)
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: store,
            transport: transport,
            projection: projection
        )

        do {
            _ = try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request
            )
            XCTFail("A failed projection was reported as successful")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            XCTAssertEqual(error, .projectionFailed(.completed))
        }

        let events = try await store.events(for: fixture.runID, after: nil)
        XCTAssertEqual(events.map(\.event.header.sequence.rawValue), [1, 2, 3, 4, 5])
        XCTAssertEqual(events.last?.event.payload.kind, .runCompleted)
        XCTAssertEqual(events.filter { $0.event.payload.kind == .runCompleted }.count, 1)
        XCTAssertFalse(events.contains {
            $0.event.payload.kind == .runFailed ||
                $0.event.payload.kind == .runCancelled
        })
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testMismatchedCommittedAcceptanceIdentityStopsBeforeCallbackOrNetwork() async throws {
        let fixture = makeRunExecutorFixture(seed: 10)
        let mismatch = makeRunExecutorFixture(seed: 11)
        let journal = RunExecutorAdversarialJournal(
            acceptance: fixture.acceptance,
            mode: .mismatchedAcceptance(mismatch.acceptance.envelope)
        )
        let transport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let callback = RunExecutorOrderProbe()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: journal,
            transport: transport,
            projection: projection
        )

        do {
            _ = try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request,
                didAccept: { await callback.record("didAccept") }
            )
            XCTFail("A mismatched acceptance receipt authorized work")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            XCTAssertEqual(error, .acceptanceFailed)
        }

        let transportCalls = await transport.callCount()
        let callbacks = await callback.values()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(transportCalls, 0)
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertTrue(projectedRuns.isEmpty)
    }

    func testExistingFailedTerminalAfterProviderSuccessIsSurfacedAndProjectedOnce() async throws {
        let fixture = makeRunExecutorFixture(seed: 12)
        let journal = RunExecutorAdversarialJournal(
            acceptance: fixture.acceptance,
            mode: .revealFailedTerminal
        )
        let transport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: journal,
            transport: transport,
            projection: projection
        )

        do {
            _ = try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request
            )
            XCTFail("An existing failed terminal was reported as success")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            XCTAssertEqual(error, .runFailed(runExecutorExistingFailureInfo))
        }

        let events = try await journal.events(for: fixture.runID, after: nil)
        let terminalKinds = events.compactMap { event -> AgentEventKind? in
            switch event.event.payload.kind {
            case .runCompleted, .runFailed, .runCancelled, .runInterrupted:
                event.event.payload.kind
            default:
                nil
            }
        }
        let transportCalls = await transport.callCount()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(terminalKinds, [.runFailed])
        XCTAssertTrue(events.contains {
            $0.event.payload.kind == .modelResponseCommitted
        })
        XCTAssertEqual(transportCalls, 1)
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testExistingCancelledTerminalAfterProviderSuccessIsSurfacedAndProjectedOnce() async throws {
        let fixture = makeRunExecutorFixture(seed: 13)
        let journal = RunExecutorAdversarialJournal(
            acceptance: fixture.acceptance,
            mode: .revealCancelledTerminal
        )
        let transport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: journal,
            transport: transport,
            projection: projection
        )

        do {
            _ = try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request
            )
            XCTFail("An existing cancelled terminal was reported as success")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            XCTAssertEqual(error, .runCancelled(runExecutorCancellationInfo))
        }

        let events = try await journal.events(for: fixture.runID, after: nil)
        let terminalKinds = events.compactMap { event -> AgentEventKind? in
            switch event.event.payload.kind {
            case .runCompleted, .runFailed, .runCancelled, .runInterrupted:
                event.event.payload.kind
            default:
                nil
            }
        }
        let transportCalls = await transport.callCount()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(terminalKinds, [.runCancelled])
        XCTAssertTrue(events.contains {
            $0.event.payload.kind == .modelResponseCommitted
        })
        XCTAssertEqual(transportCalls, 1)
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testLateCallerCancellationCannotCancelFailureSettlementRead() async throws {
        let fixture = makeRunExecutorFixture(seed: 14)
        let journal = RunExecutorAdversarialJournal(
            acceptance: fixture.acceptance,
            mode: .gateFailureSettlementRead
        )
        let transport = RunExecutorControlledTransport(
            mode: .partialThenFail,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: journal,
            transport: transport,
            projection: projection
        )
        let execution = Task {
            try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request
            )
        }

        try await waitForRunExecutorSettlementRead(journal)
        execution.cancel()
        await journal.releaseSettlementRead()

        do {
            _ = try await execution.value
            XCTFail("A failed attempt completed after late cancellation")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            guard case let .runFailed(info) = error else {
                return XCTFail("Unexpected executor error: \(error)")
            }
            XCTAssertEqual(info.category, .transport)
        }

        let events = try await journal.events(for: fixture.runID, after: nil)
        let cancelledRead = await journal.observedCancelledSettlementRead()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertFalse(cancelledRead)
        XCTAssertEqual(events.last?.event.payload.kind, .runFailed)
        XCTAssertEqual(events.filter {
            $0.event.payload.kind == .runCompleted ||
                $0.event.payload.kind == .runFailed ||
                $0.event.payload.kind == .runCancelled
        }.count, 1)
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testFailedProjectionFailureLeavesFailedTerminalUntouched() async throws {
        let fixture = makeRunExecutorFixture(seed: 15)
        let store = InMemoryAgentEventJournal()
        let transport = RunExecutorControlledTransport(
            mode: .partialThenFail,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe(shouldFail: true)
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: store,
            transport: transport,
            projection: projection
        )

        do {
            _ = try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request
            )
            XCTFail("A failed projection was reported as a run result")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            guard case let .projectionFailed(.failed(info)) = error else {
                return XCTFail("Unexpected executor error: \(error)")
            }
            XCTAssertEqual(info.category, .transport)
        }

        let events = try await store.events(for: fixture.runID, after: nil)
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(events.last?.event.payload.kind, .runFailed)
        XCTAssertEqual(events.filter { $0.event.payload.kind == .runFailed }.count, 1)
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testCancelledProjectionFailureLeavesCancelledTerminalUntouched() async throws {
        let fixture = makeRunExecutorFixture(seed: 16)
        let store = InMemoryAgentEventJournal()
        let transport = RunExecutorControlledTransport(
            mode: .waitForCancellation,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe(shouldFail: true)
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: store,
            transport: transport,
            projection: projection
        )
        let execution = Task {
            try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request
            )
        }

        try await waitForRunExecutorTransport(transport)
        execution.cancel()
        do {
            _ = try await execution.value
            XCTFail("A failed cancellation projection was reported as success")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            guard case let .projectionFailed(.cancelled(info)) = error else {
                return XCTFail("Unexpected executor error: \(error)")
            }
            XCTAssertEqual(info.category, .cancelled)
        }

        let events = try await store.events(for: fixture.runID, after: nil)
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(events.last?.event.payload.kind, .runCancelled)
        XCTAssertEqual(events.filter {
            $0.event.payload.kind == .runCancelled
        }.count, 1)
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testPredispatchCancellationAcceptsThenCancelsWithoutNetwork() async throws {
        let fixture = makeRunExecutorFixture(seed: 17)
        let store = InMemoryAgentEventJournal()
        let transport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let callback = RunExecutorOrderProbe()
        let startGate = RunExecutorAsyncGate()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: store,
            transport: transport,
            projection: projection
        )
        let execution = Task {
            await startGate.wait()
            return try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request,
                didAccept: { await callback.record("didAccept") }
            )
        }
        execution.cancel()
        await startGate.open()

        do {
            _ = try await execution.value
            XCTFail("A predispatch cancellation completed")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            XCTAssertEqual(error, .runCancelled(runExecutorCancellationInfo))
        }

        let events = try await store.events(for: fixture.runID, after: nil)
        let transportCalls = await transport.callCount()
        let callbacks = await callback.values()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(events.map(\.event.payload.kind), [
            .runAccepted,
            .cancellationRequested,
            .runCancelled,
        ])
        XCTAssertEqual(transportCalls, 0)
        XCTAssertEqual(callbacks, ["didAccept"])
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testCancellationDuringDidAcceptSettlesBeforeProviderDispatch() async throws {
        let fixture = makeRunExecutorFixture(seed: 18)
        let store = InMemoryAgentEventJournal()
        let transport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let callback = RunExecutorOrderProbe()
        let callbackGate = RunExecutorAsyncGate()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: store,
            transport: transport,
            projection: projection
        )
        let execution = Task {
            try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request,
                didAccept: {
                    await callback.record("didAccept")
                    await callbackGate.wait()
                }
            )
        }

        try await waitForRunExecutorOrder("didAccept", probe: callback)
        execution.cancel()
        await callbackGate.open()
        do {
            _ = try await execution.value
            XCTFail("Cancellation during didAccept completed")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            XCTAssertEqual(error, .runCancelled(runExecutorCancellationInfo))
        }

        let events = try await store.events(for: fixture.runID, after: nil)
        let transportCalls = await transport.callCount()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(events.map(\.event.payload.kind), [
            .runAccepted,
            .cancellationRequested,
            .runCancelled,
        ])
        XCTAssertEqual(transportCalls, 0)
        XCTAssertEqual(projectedRuns, [fixture.runID])
    }

    func testRunCancelledWriteFailureLeavesRecoverableCancellingPrefix() async throws {
        let fixture = makeRunExecutorFixture(seed: 19)
        let journal = RunExecutorAdversarialJournal(
            acceptance: fixture.acceptance,
            mode: .failRunCancelledAppend
        )
        let transport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let projection = RunExecutorProjectionProbe()
        let startGate = RunExecutorAsyncGate()
        let executor = makeRunExecutor(
            fixture: fixture,
            journal: journal,
            transport: transport,
            projection: projection
        )
        let execution = Task {
            await startGate.wait()
            return try await executor.execute(
                acceptance: fixture.acceptance,
                request: fixture.request
            )
        }
        execution.cancel()
        await startGate.open()

        do {
            _ = try await execution.value
            XCTFail("A missing runCancelled write reported a terminal")
        } catch let error as AgentHostedTextCanaryRunExecutorError {
            XCTAssertEqual(error, .settlementFailed)
        }

        let events = try await journal.events(for: fixture.runID, after: nil)
        let state = try AgentJournalReplay.replay(
            events,
            metadata: fixture.acceptance.metadata
        )
        let transportCalls = await transport.callCount()
        let projectedRuns = await projection.projectedRuns()
        XCTAssertEqual(events.map(\.event.payload.kind), [
            .runAccepted,
            .cancellationRequested,
        ])
        XCTAssertEqual(state.phase, .cancelling)
        XCTAssertEqual(transportCalls, 0)
        XCTAssertTrue(projectedRuns.isEmpty)
    }

    func testEquivalentExecutionsMintIdenticalTerminalIdentity() async throws {
        let fixture = makeRunExecutorFixture(seed: 20)
        let firstStore = InMemoryAgentEventJournal()
        let secondStore = InMemoryAgentEventJournal()
        let firstTransport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let secondTransport = RunExecutorControlledTransport(
            mode: .success,
            model: fixture.model
        )
        let first = makeRunExecutor(
            fixture: fixture,
            journal: firstStore,
            transport: firstTransport,
            projection: RunExecutorProjectionProbe()
        )
        let second = makeRunExecutor(
            fixture: fixture,
            journal: secondStore,
            transport: secondTransport,
            projection: RunExecutorProjectionProbe()
        )

        let firstResult = try await first.execute(
            acceptance: fixture.acceptance,
            request: fixture.request
        )
        let secondResult = try await second.execute(
            acceptance: fixture.acceptance,
            request: fixture.request
        )

        XCTAssertEqual(
            firstResult.terminalCommit.record.envelope,
            secondResult.terminalCommit.record.envelope
        )
        XCTAssertEqual(
            firstResult.terminalCommit.record.event.header.causationID,
            secondResult.terminalCommit.record.event.header.causationID
        )
    }
}

private struct RunExecutorFixture {
    let acceptance: AgentRunAcceptance
    let provider: AgentHostedTextCanaryProvider
    let request: CanonicalProviderRequest
    let model: ProviderModelID

    var runID: RunID { acceptance.metadata.runID }
}

private func makeRunExecutor(
    fixture: RunExecutorFixture,
    journal: any AgentEventJournal,
    transport: any ProviderTransport,
    projection: RunExecutorProjectionProbe
) -> AgentHostedTextCanaryRunExecutor {
    AgentHostedTextCanaryRunExecutor(
        journal: journal,
        provider: fixture.provider,
        transport: transport,
        projection: { runID in
            try await projection.project(runID)
        }
    )
}

private func makeRunExecutorFixture(seed: UInt64) -> RunExecutorFixture {
    let acceptedAt = AgentInstant(rawValue: 2_200_000_000_000 + Int64(seed))
    let runID: RunID = runExecutorTestID(seed * 100 + 1)
    let context = AgentRunContext(
        schemaVersion: .v1_1,
        lineage: .root(runID),
        conversationID: runExecutorTestID(seed * 100 + 2),
        projectID: runExecutorTestID(seed * 100 + 3),
        workspaceID: runExecutorTestID(seed * 100 + 4),
        executionNodeID: runExecutorTestID(seed * 100 + 5),
        engineVersion: AgentHostedTextCanaryCoordinator.engineVersion,
        acceptedAt: acceptedAt,
        features: AgentHostedTextCanaryCoordinator.featureSet,
        cancellation: CancellationLineage(
            scopeID: runExecutorTestID(seed * 100 + 6)
        ),
        initialBudget: AgentBudget(limits: .standard)
    )
    let userItem = ModelItem(
        id: runExecutorTestID(seed * 100 + 7),
        createdAt: acceptedAt,
        payload: .message(ModelMessage(
            role: .user,
            content: [.text("Hello")]
        ))
    )
    let acceptanceEventID: EventID = runExecutorTestID(seed * 100 + 8)
    let writerID = AgentEventWriterID(runID: runID)
    let acceptance = AgentRunAcceptance(
        metadata: AgentRunMetadataRecord(
            context: context,
            acceptedEngineVersion: context.engineVersion,
            writerID: writerID,
            acceptanceCommandID: runExecutorTestID(seed * 100 + 9),
            acceptanceEventID: acceptanceEventID
        ),
        envelope: AgentEventEnvelope(
            writerID: writerID,
            writerSequence: .first,
            idempotencyKey: "run-executor-accept-\(seed)",
            event: AgentEvent(
                header: AgentEventHeader(
                    eventID: acceptanceEventID,
                    schemaVersion: context.schemaVersion,
                    context: context,
                    sequence: .first,
                    timestamp: acceptedAt,
                    causationID: nil,
                    correlationID: runExecutorTestID(seed * 100 + 10)
                ),
                payload: .runAccepted(RunAcceptedEvent(
                    context: context,
                    acceptedEngineVersion: context.engineVersion,
                    initialItems: [userItem]
                ))
            )
        )
    )
    let model = ProviderModelID(rawValue: "fixture-model")
    return RunExecutorFixture(
        acceptance: acceptance,
        provider: try! .openAIChatCompletions(model: model),
        request: CanonicalProviderRequest(
            requestID: "run-executor-request-\(seed)",
            model: model,
            messages: [ProviderMessage(
                role: .user,
                content: [.text("Hello")]
            )],
            options: ProviderGenerationOptions(toolChoice: .none)
        ),
        model: model
    )
}

private actor RunExecutorControlledTransport: ProviderTransport {
    enum Mode: Sendable {
        case success
        case partialThenFail
        case waitForCancellation
    }

    private let mode: Mode
    private let model: ProviderModelID
    private var calls = 0
    private var orderProbe: RunExecutorOrderProbe?

    init(mode: Mode, model: ProviderModelID) {
        self.mode = mode
        self.model = model
    }

    func stream(
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        calls += 1
        await orderProbe?.record("transport")
        switch mode {
        case .success:
            let frames = runExecutorSuccessFrames(model: model)
            return AsyncThrowingStream { continuation in
                for frame in frames { continuation.yield(frame) }
                continuation.finish()
            }
        case .partialThenFail:
            let frames = Array(runExecutorSuccessFrames(model: model).prefix(2))
            return AsyncThrowingStream { continuation in
                for frame in frames { continuation.yield(frame) }
                continuation.finish(throwing: RunExecutorFixtureError.transport)
            }
        case .waitForCancellation:
            while true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    func callCount() -> Int { calls }

    func setOrderProbe(_ probe: RunExecutorOrderProbe) {
        orderProbe = probe
    }
}

private actor RunExecutorProjectionProbe {
    private let shouldFail: Bool
    private var runs: [RunID] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func project(_ runID: RunID) throws {
        runs.append(runID)
        if shouldFail { throw RunExecutorFixtureError.projection }
    }

    func projectedRuns() -> [RunID] { runs }
}

private actor RunExecutorOrderProbe {
    private var entries: [String] = []

    func record(_ value: String) {
        entries.append(value)
    }

    func values() -> [String] { entries }
}

private actor RunExecutorFaultJournal: AgentEventJournal {
    enum Mode: Sendable, Equatable {
        case failCompletionAppend
        case failFirstReplayRead
    }

    private let backing = InMemoryAgentEventJournal()
    private let mode: Mode
    private var accepted = false
    private var didFail = false

    init(mode: Mode) {
        self.mode = mode
    }

    func accept(_ acceptance: AgentRunAcceptance) async throws -> AgentJournalCommit {
        let commit = try await backing.accept(acceptance)
        accepted = true
        return commit
    }

    func append(_ envelope: AgentEventEnvelope) async throws -> AgentJournalCommit {
        if mode == .failCompletionAppend, !didFail,
           case .runCompleted = envelope.event.payload {
            didFail = true
            throw RunExecutorFixtureError.persistence
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
        if mode == .failFirstReplayRead, accepted, !didFail {
            didFail = true
            throw RunExecutorFixtureError.replay
        }
        return try await backing.events(for: runID, after: sequence)
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

private let runExecutorExistingFailureInfo = AgentErrorInfo(
    category: .provider,
    code: "fixture_existing_terminal",
    publicMessage: "The run had already failed.",
    retryable: false
)

private let runExecutorCancellationInfo = AgentErrorInfo(
    category: .cancelled,
    code: "hosted_text_attempt_cancelled",
    publicMessage: "The hosted text attempt was cancelled.",
    retryable: false
)

private actor RunExecutorAdversarialJournal: AgentEventJournal {
    enum Mode: Sendable {
        case mismatchedAcceptance(AgentEventEnvelope)
        case revealFailedTerminal
        case revealCancelledTerminal
        case gateFailureSettlementRead
        case failRunCancelledAppend
    }

    private let backing = InMemoryAgentEventJournal()
    private let acceptance: AgentRunAcceptance
    private let mode: Mode
    private var didInjectTerminal = false
    private var didEnterSettlementRead = false
    private var didObserveCancelledSettlementRead = false
    private var settlementReadIsReleased = false
    private var settlementReadWaiters: [CheckedContinuation<Void, Never>] = []

    init(acceptance: AgentRunAcceptance, mode: Mode) {
        self.acceptance = acceptance
        self.mode = mode
    }

    func accept(_ acceptance: AgentRunAcceptance) async throws -> AgentJournalCommit {
        let commit = try await backing.accept(acceptance)
        guard case let .mismatchedAcceptance(envelope) = mode else {
            return commit
        }
        return AgentJournalCommit(
            disposition: .committed,
            record: StoredAgentEvent(
                offset: commit.record.offset,
                committedAt: commit.record.committedAt,
                envelope: envelope
            )
        )
    }

    func append(_ envelope: AgentEventEnvelope) async throws -> AgentJournalCommit {
        if case .failRunCancelledAppend = mode,
           case .runCancelled = envelope.event.payload {
            throw RunExecutorFixtureError.persistence
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
        var records = try await backing.events(for: runID, after: sequence)
        if sequence == nil,
           !didInjectTerminal,
           records.last?.event.payload.kind == .modelResponseCommitted {
            switch mode {
            case .revealFailedTerminal:
                try await injectFailedTerminal(after: records[records.count - 1])
                didInjectTerminal = true
                records = try await backing.events(for: runID, after: nil)
            case .revealCancelledTerminal:
                try await injectCancelledTerminal(after: records[records.count - 1])
                didInjectTerminal = true
                records = try await backing.events(for: runID, after: nil)
            default:
                break
            }
        }

        if sequence == nil,
           !didEnterSettlementRead,
           records.last?.event.payload.kind == .modelRequestFailed,
           case .gateFailureSettlementRead = mode {
            didEnterSettlementRead = true
            await waitForSettlementReadRelease()
            didObserveCancelledSettlementRead = Task.isCancelled
            if Task.isCancelled { throw CancellationError() }
        }
        return records
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

    func settlementReadHasEntered() -> Bool {
        didEnterSettlementRead
    }

    func observedCancelledSettlementRead() -> Bool {
        didObserveCancelledSettlementRead
    }

    func releaseSettlementRead() {
        guard !settlementReadIsReleased else { return }
        settlementReadIsReleased = true
        let waiters = settlementReadWaiters
        settlementReadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForSettlementReadRelease() async {
        guard !settlementReadIsReleased else { return }
        await withCheckedContinuation { continuation in
            settlementReadWaiters.append(continuation)
        }
    }

    private func injectFailedTerminal(
        after record: StoredAgentEvent
    ) async throws {
        guard let sequence = record.event.header.sequence.successor else {
            throw RunExecutorFixtureError.persistence
        }
        _ = try await backing.append(injectedEnvelope(
            sequence: sequence,
            idempotencyKey: "fixture-existing-run-failed",
            eventIDSeed: 910_001,
            causation: record.event.header.eventID,
            payload: .runFailed(RunFailedEvent(
                error: runExecutorExistingFailureInfo
            ))
        ))
    }

    private func injectCancelledTerminal(
        after record: StoredAgentEvent
    ) async throws {
        guard let requestSequence = record.event.header.sequence.successor,
              let terminalSequence = requestSequence.successor else {
            throw RunExecutorFixtureError.persistence
        }
        let request = try await backing.append(injectedEnvelope(
            sequence: requestSequence,
            idempotencyKey: "fixture-existing-cancellation-requested",
            eventIDSeed: 920_001,
            causation: record.event.header.eventID,
            payload: .cancellationRequested(CancellationRequestedEvent(
                reason: .userRequested,
                propagateToDescendants: true
            ))
        ))
        _ = try await backing.append(injectedEnvelope(
            sequence: terminalSequence,
            idempotencyKey: "fixture-existing-run-cancelled",
            eventIDSeed: 920_002,
            causation: request.record.event.header.eventID,
            payload: .runCancelled(RunCancelledEvent(reason: .userRequested))
        ))
    }

    private func injectedEnvelope(
        sequence: EventSequence,
        idempotencyKey: String,
        eventIDSeed: UInt64,
        causation: EventID,
        payload: AgentEventPayload
    ) -> AgentEventEnvelope {
        let eventID: EventID = runExecutorTestID(eventIDSeed)
        return AgentEventEnvelope(
            writerID: acceptance.metadata.writerID,
            writerSequence: sequence,
            idempotencyKey: idempotencyKey,
            event: AgentEvent(
                header: AgentEventHeader(
                    eventID: eventID,
                    schemaVersion: acceptance.metadata.context.schemaVersion,
                    context: acceptance.metadata.context,
                    sequence: sequence,
                    timestamp: AgentInstant(rawValue:
                        acceptance.metadata.context.acceptedAt.rawValue +
                            Int64(sequence.rawValue)
                    ),
                    causationID: CausationID(rawValue: causation.rawValue),
                    correlationID: acceptance.envelope.event.header.correlationID
                ),
                payload: payload
            )
        )
    }
}

private actor RunExecutorAsyncGate {
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
        for waiter in pending { waiter.resume() }
    }
}

private enum RunExecutorFixtureError: Error {
    case transport
    case projection
    case persistence
    case replay
    case timedOut
}

private func runExecutorSuccessFrames(
    model: ProviderModelID
) -> [ProviderWireFrame] {
    [
        .json(.object([
            "id": .string("chat-run-executor-1"),
            "model": .string(model.rawValue),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object(["content": .string("Hel")]),
                "finish_reason": .null,
            ])]),
        ])),
        .json(.object([
            "id": .string("chat-run-executor-1"),
            "model": .string(model.rawValue),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object(["content": .string("lo")]),
                "finish_reason": .null,
            ])]),
        ])),
        .json(.object([
            "id": .string("chat-run-executor-1"),
            "model": .string(model.rawValue),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object([:]),
                "finish_reason": .string("stop"),
            ])]),
        ])),
        .json(.object([
            "id": .string("chat-run-executor-1"),
            "model": .string(model.rawValue),
            "choices": .array([]),
            "usage": .object([
                "prompt_tokens": .number(.integer(10)),
                "prompt_tokens_details": .object([
                    "cached_tokens": .number(.integer(3)),
                ]),
                "completion_tokens": .number(.integer(2)),
            ]),
        ])),
        .done,
    ]
}

private func waitForRunExecutorTransport(
    _ transport: RunExecutorControlledTransport
) async throws {
    for _ in 0 ..< 200 {
        if await transport.callCount() > 0 { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw RunExecutorFixtureError.timedOut
}

private func waitForRunExecutorSettlementRead(
    _ journal: RunExecutorAdversarialJournal
) async throws {
    for _ in 0 ..< 200 {
        if await journal.settlementReadHasEntered() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw RunExecutorFixtureError.timedOut
}

private func waitForRunExecutorOrder(
    _ expected: String,
    probe: RunExecutorOrderProbe
) async throws {
    for _ in 0 ..< 200 {
        if await probe.values().contains(expected) { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw RunExecutorFixtureError.timedOut
}

private func runExecutorTestID<Tag: AgentIdentifierTag>(
    _ value: UInt64
) -> AgentIdentifier<Tag> {
    let suffix = String(format: "%012llX", value)
    return AgentIdentifier(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-\(suffix)"
    )!)
}
#endif

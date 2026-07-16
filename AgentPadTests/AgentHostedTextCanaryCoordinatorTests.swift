#if DEBUG
import AgentDomain
import AgentProviders
import AgentShadow
import AgentStore
import Foundation
import XCTest
@testable import NovaForge

final class AgentHostedTextCanaryCoordinatorTests: XCTestCase {
    func testSuccessRemainsProvisionalUntilEOFAndCommitsOneAttempt() async throws {
        let fixture = try await makeCanaryFixture(seed: 1)
        let transport = EOFControlledCanaryTransport(model: fixture.model)
        let coordinator = AgentHostedTextCanaryCoordinator(
            journal: fixture.store,
            provider: fixture.provider,
            transport: transport
        )

        let execution = Task {
            try await coordinator.execute(
                acceptedRun: fixture.acceptance,
                request: fixture.request
            )
        }
        try await waitForTransportCalls(1, transport: transport)
        try await waitForEventCount(
            3,
            store: fixture.store,
            runID: fixture.runID
        )

        let beforeEOF = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        )
        XCTAssertEqual(beforeEOF.map(\.event.header.sequence.rawValue), [1, 2, 3])
        XCTAssertFalse(beforeEOF.contains {
            $0.event.payload.kind == .modelResponseCommitted
        })

        await transport.releaseEOF()
        let result = try await execution.value

        let expectedWireRequestID = AgentHostedTextCanaryCoordinator
            .runBoundRequestID(
                fixture.request.requestID,
                runID: fixture.runID
            )
        XCTAssertEqual(result.scope.requestID, expectedWireRequestID)
        XCTAssertEqual(
            result.scope.attemptID.rawValue,
            "\(expectedWireRequestID):provider-attempt:1"
        )
        XCTAssertEqual(
            result.attemptID,
            AgentHostedTextCanaryCoordinator.attemptID(
                for: result.scope,
                runID: fixture.runID
            )
        )
        XCTAssertEqual(result.finishReason, .completed)
        XCTAssertEqual(result.usage, ModelUsage(
            inputTokens: 10,
            cachedInputTokens: 3,
            outputTokens: 2
        ))
        XCTAssertEqual(result.items.count, 1)
        guard case let .message(message) = result.items[0].payload else {
            return XCTFail("Expected one committed assistant message")
        }
        XCTAssertEqual(message, ModelMessage(
            role: .assistant,
            content: [.text("Hello")]
        ))

        let events = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        )
        assertSingleAttemptLedger(events)
        XCTAssertEqual(
            fixture.acceptance.metadata.context.schemaVersion,
            .v1_1
        )
        XCTAssertEqual(
            fixture.acceptance.metadata.acceptedEngineVersion,
            AgentHostedTextCanaryCoordinator.engineVersion
        )
        guard case let .runAccepted(accepted) = events[0].event.payload,
              case let .modelRequestStarted(started) = events[2].event.payload,
              case let .recordedV1_1(
                  requestDigest,
                  scopeReference,
                  ordinal,
                  recoverySeed
              ) = started.providerAttempt else {
            return XCTFail("Expected complete v1.1 acceptance and dispatch metadata")
        }
        XCTAssertEqual(accepted.acceptedEngineVersion, accepted.context.engineVersion)
        XCTAssertEqual(events[2].event.header.schemaVersion, .v1_1)
        XCTAssertEqual(ordinal, 1)
        XCTAssertTrue(requestDigest.rawValue.hasPrefix("sha256:"))
        let recordedScope = ProviderAttemptScope(
            requestID: scopeReference.requestID,
            attemptID: ProviderAttemptID(rawValue: scopeReference.attemptID)
        )
        XCTAssertEqual(recordedScope, result.scope)
        XCTAssertEqual(
            recoverySeed,
            AgentHostedTextCanaryCoordinator.providerRecoverySeed(
                runID: fixture.runID,
                scope: recordedScope,
                ordinal: ordinal
            )
        )
        XCTAssertFalse(started.providerAttempt.isLegacyV1)
        guard case let .modelResponseCommitted(committed) = events[3].event.payload else {
            return XCTFail("Expected the fourth event to commit the response")
        }
        XCTAssertEqual(committed.attemptID, result.attemptID)
        XCTAssertEqual(committed.items, result.items)
        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 1)
    }

    func testTransportFailureDiscardsProvisionalTextAndDoesNotRetry() async throws {
        let fixture = try await makeCanaryFixture(seed: 2)
        let transport = ScriptedCanaryTransport(
            mode: .partialThenFail,
            model: fixture.model
        )
        let coordinator = AgentHostedTextCanaryCoordinator(
            journal: fixture.store,
            provider: fixture.provider,
            transport: transport
        )

        do {
            _ = try await coordinator.execute(
                acceptedRun: fixture.acceptance,
                request: fixture.request
            )
            XCTFail("A failed wire attempt unexpectedly succeeded")
        } catch let error as AgentHostedTextCanaryCoordinatorError {
            guard case let .attemptFailed(info) = error else {
                return XCTFail("Unexpected coordinator error: \(error)")
            }
            XCTAssertEqual(info.category, .transport)
        }

        let events = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        )
        assertSingleAttemptLedger(events)
        guard case let .modelRequestFailed(failed) = events[3].event.payload else {
            return XCTFail("Expected a durable failed-attempt boundary")
        }
        XCTAssertFalse(failed.outputWasCommitted)
        XCTAssertEqual(failed.error.category, .transport)
        XCTAssertFalse(events.contains {
            $0.event.payload.kind == .modelResponseCommitted
        })
        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 1)
    }

    func testCancellationPersistsUncommittedFailureAndDoesNotRetry() async throws {
        let fixture = try await makeCanaryFixture(seed: 3)
        let transport = ScriptedCanaryTransport(
            mode: .waitForCancellation,
            model: fixture.model
        )
        let coordinator = AgentHostedTextCanaryCoordinator(
            journal: fixture.store,
            provider: fixture.provider,
            transport: transport
        )
        let execution = Task {
            try await coordinator.execute(
                acceptedRun: fixture.acceptance,
                request: fixture.request
            )
        }

        try await waitForTransportCalls(1, transport: transport)
        execution.cancel()
        do {
            _ = try await execution.value
            XCTFail("A cancelled wire attempt unexpectedly succeeded")
        } catch let error as AgentHostedTextCanaryCoordinatorError {
            guard case let .attemptFailed(info) = error else {
                return XCTFail("Unexpected coordinator error: \(error)")
            }
            XCTAssertEqual(info.category, .cancelled)
            XCTAssertFalse(info.retryable)
        }

        let events = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        )
        assertSingleAttemptLedger(events)
        guard case let .modelRequestFailed(failed) = events[3].event.payload else {
            return XCTFail("Expected cancellation to settle the active attempt")
        }
        XCTAssertEqual(failed.error.category, .cancelled)
        XCTAssertFalse(failed.outputWasCommitted)
        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 1)
    }

    func testRestartRejectsAlreadyClaimedBarrierBeforeSecondDispatch() async throws {
        let fixture = try await makeCanaryFixture(seed: 4)
        let transport = EOFControlledCanaryTransport(model: fixture.model)
        let firstCoordinator = AgentHostedTextCanaryCoordinator(
            journal: fixture.store,
            provider: fixture.provider,
            transport: transport
        )
        let first = Task {
            try await firstCoordinator.execute(
                acceptedRun: fixture.acceptance,
                request: fixture.request
            )
        }
        try await waitForTransportCalls(1, transport: transport)
        try await waitForEventCount(
            3,
            store: fixture.store,
            runID: fixture.runID
        )

        // A fresh gateway sees the crash-critical durable state [accepted,
        // started, request-started] while the first stream has no EOF and no
        // committed output. Only the journal barrier can reject redispatch.
        let restartedCoordinator = AgentHostedTextCanaryCoordinator(
            journal: fixture.store,
            provider: fixture.provider,
            transport: transport
        )
        do {
            _ = try await restartedCoordinator.execute(
                acceptedRun: fixture.acceptance,
                request: fixture.request
            )
            XCTFail("A claimed provider scope was dispatched twice")
        } catch let error as AgentHostedTextCanaryCoordinatorError {
            XCTAssertEqual(error, .duplicateProviderDispatch)
        }

        let activeEvents = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        )
        guard case let .modelRequestStarted(beforeRestart) =
                activeEvents[2].event.payload else {
            return XCTFail("Expected the durable dispatch claim")
        }
        let callsBeforeEOF = await transport.callCount()
        XCTAssertEqual(activeEvents.count, 3)
        XCTAssertEqual(callsBeforeEOF, 1)

        await transport.releaseEOF()
        let firstResult = try await first.value

        let expectedWireRequestID = AgentHostedTextCanaryCoordinator
            .runBoundRequestID(
                fixture.request.requestID,
                runID: fixture.runID
            )
        let exactScope = ProviderAttemptScope(
            requestID: expectedWireRequestID,
            attemptID: ProviderAttemptID(
                rawValue: "\(expectedWireRequestID):provider-attempt:1"
            )
        )
        XCTAssertEqual(firstResult.attemptID, AgentHostedTextCanaryCoordinator
            .attemptID(for: exactScope, runID: fixture.runID))
        let transportCalls = await transport.callCount()
        let events = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        )
        XCTAssertEqual(transportCalls, 1)
        XCTAssertEqual(events.count, 4)
        guard case let .modelRequestStarted(afterRestart) =
                events[2].event.payload,
              case let .recordedV1_1(_, scopeReference, ordinal, seed) =
                afterRestart.providerAttempt else {
            return XCTFail("Expected the original v1.1 dispatch claim")
        }
        XCTAssertEqual(afterRestart.providerAttempt, beforeRestart.providerAttempt)
        let relaunchedScope = ProviderAttemptScope(
            requestID: scopeReference.requestID,
            attemptID: ProviderAttemptID(rawValue: scopeReference.attemptID)
        )
        XCTAssertEqual(
            seed,
            AgentHostedTextCanaryCoordinator.providerRecoverySeed(
                runID: fixture.runID,
                scope: relaunchedScope,
                ordinal: ordinal
            ),
            "A relaunch must reconstruct the exact recovery seed"
        )
    }

    func testV11BarrierRejectsMissingDispatchMetadataBeforeTransport() async throws {
        let fixture = try await makeCanaryFixture(seed: 41)
        let journal = CanaryAdversarialJournal(
            backing: fixture.store,
            mode: .stripProviderAttemptMetadata
        )
        let transport = ScriptedCanaryTransport(
            mode: .success,
            model: fixture.model
        )

        do {
            _ = try await AgentHostedTextCanaryCoordinator(
                journal: journal,
                provider: fixture.provider,
                transport: transport
            ).execute(
                acceptedRun: fixture.acceptance,
                request: fixture.request
            )
            XCTFail("A v1.1 dispatch without journal metadata reached transport")
        } catch {
            // The app-owned append barrier must reject the stripped event.
        }

        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 0)
        let events = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        )
        XCTAssertEqual(events.map(\.event.payload.kind), [
            .runAccepted,
            .runStarted,
        ])
    }

    func testDarkReplayFailurePreventsRunStartAndNetwork() async throws {
        let fixture = makeUnacceptedCanaryFixture(seed: 5)
        let transport = ScriptedCanaryTransport(
            mode: .partialThenFail,
            model: fixture.model
        )
        let coordinator = AgentHostedTextCanaryCoordinator(
            journal: fixture.store,
            provider: fixture.provider,
            transport: transport
        )

        do {
            _ = try await coordinator.execute(
                acceptedRun: fixture.acceptance,
                request: fixture.request
            )
            XCTFail("Missing canonical replay unexpectedly authorized a canary")
        } catch let error as DarkReplayError {
            XCTAssertEqual(error, .runNotFound(fixture.runID))
        }

        let transportCalls = await transport.callCount()
        let events = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        )
        XCTAssertEqual(transportCalls, 0)
        XCTAssertTrue(events.isEmpty)
    }

    func testToolBearingHistoryIsRejectedBeforeReplayOrDispatch() async throws {
        let fixture = try await makeCanaryFixture(seed: 6)
        let transport = ScriptedCanaryTransport(
            mode: .partialThenFail,
            model: fixture.model
        )
        let coordinator = AgentHostedTextCanaryCoordinator(
            journal: fixture.store,
            provider: fixture.provider,
            transport: transport
        )
        let toolHistory = CanonicalProviderRequest(
            requestID: fixture.request.requestID,
            model: fixture.model,
            messages: [
                ProviderMessage(role: .user, content: [.text("Hello")]),
                ProviderMessage(
                    role: .assistant,
                    content: [.toolCall(ProviderToolCallInput(
                        callID: "call-1",
                        name: "read_file",
                        arguments: .object([:])
                    ))]
                ),
            ],
            options: ProviderGenerationOptions(toolChoice: .none)
        )

        do {
            _ = try await coordinator.execute(
                acceptedRun: fixture.acceptance,
                request: toolHistory
            )
            XCTFail("Tool-bearing history unexpectedly entered the canary")
        } catch let error as AgentHostedTextCanaryCoordinatorError {
            XCTAssertEqual(error, .toolBearingHistory)
        }

        let transportCalls = await transport.callCount()
        let eventCount = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        ).count
        XCTAssertEqual(transportCalls, 0)
        XCTAssertEqual(eventCount, 1)
    }

    func testCapturedTextContextBindsHistoryAndAcceptedCurrentUser() async throws {
        let fixture = try await makeCanaryFixture(seed: 60)
        guard case let .runAccepted(accepted) =
                fixture.acceptance.envelope.event.payload,
              let acceptedItem = accepted.initialItems.first else {
            return XCTFail("Expected one accepted user item")
        }
        let messages = [
            ProviderMessage(role: .system, content: [.text("System context")]),
            ProviderMessage(role: .user, content: [.text("Earlier question")]),
            ProviderMessage(role: .assistant, content: [.text("Earlier answer")]),
            ProviderMessage(role: .user, content: [.text("Hello")]),
        ]
        let request = CanonicalProviderRequest(
            requestID: fixture.request.requestID,
            model: fixture.model,
            messages: messages,
            options: ProviderGenerationOptions(toolChoice: .none)
        )
        let capturedContext = try AgentHostedTextCanaryCapturedContext
            .acceptanceOnly(
                providerMessages: messages,
                acceptedUserItemID: acceptedItem.id.rawValue,
                acceptedUserOriginalText: "Hello"
            )
        let transport = ScriptedCanaryTransport(
            mode: .success,
            model: fixture.model
        )

        _ = try await AgentHostedTextCanaryCoordinator(
            journal: fixture.store,
            provider: fixture.provider,
            transport: transport
        ).execute(
            acceptedRun: fixture.acceptance,
            request: request,
            capturedContext: capturedContext
        )

        let transportCalls = await transport.callCount()
        XCTAssertEqual(transportCalls, 1)
    }

    func testCapturedContextTamperIsRejectedBeforeReplayOrDispatch() async throws {
        let fixture = try await makeCanaryFixture(seed: 61)
        guard case let .runAccepted(accepted) =
                fixture.acceptance.envelope.event.payload,
              let acceptedItem = accepted.initialItems.first else {
            return XCTFail("Expected one accepted user item")
        }
        let capturedMessages = [
            ProviderMessage(role: .system, content: [.text("System context")]),
            ProviderMessage(role: .assistant, content: [.text("Original history")]),
            ProviderMessage(role: .user, content: [.text("Hello")]),
        ]
        let capturedContext = try AgentHostedTextCanaryCapturedContext
            .acceptanceOnly(
                providerMessages: capturedMessages,
                acceptedUserItemID: acceptedItem.id.rawValue,
                acceptedUserOriginalText: "Hello"
            )
        let tamperedRequest = CanonicalProviderRequest(
            requestID: fixture.request.requestID,
            model: fixture.model,
            messages: [
                capturedMessages[0],
                ProviderMessage(
                    role: .assistant,
                    content: [.text("Tampered history")]
                ),
                capturedMessages[2],
            ],
            options: ProviderGenerationOptions(toolChoice: .none)
        )
        let transport = ScriptedCanaryTransport(
            mode: .success,
            model: fixture.model
        )

        do {
            _ = try await AgentHostedTextCanaryCoordinator(
                journal: fixture.store,
                provider: fixture.provider,
                transport: transport
            ).execute(
                acceptedRun: fixture.acceptance,
                request: tamperedRequest,
                capturedContext: capturedContext
            )
            XCTFail("A request that changed after capture reached dispatch")
        } catch let error as AgentHostedTextCanaryCoordinatorError {
            XCTAssertEqual(error, .nonCanonicalTextHistory)
        }

        let transportCalls = await transport.callCount()
        let eventCount = try await fixture.store.events(
            for: fixture.runID,
            after: nil
        ).count
        XCTAssertEqual(transportCalls, 0)
        XCTAssertEqual(eventCount, 1)
    }

    func testSameLogicalRequestIDAcrossRunsMintsDisjointAttemptAndEventIdentity() async throws {
        let first = try await makeCanaryFixture(seed: 20)
        let secondFixture = try await makeCanaryFixture(seed: 21)
        let secondRequest = CanonicalProviderRequest(
            requestID: first.request.requestID,
            model: secondFixture.request.model,
            messages: secondFixture.request.messages,
            tools: secondFixture.request.tools,
            options: secondFixture.request.options,
            metadata: secondFixture.request.metadata
        )
        let transport = ScriptedCanaryTransport(
            mode: .success,
            model: first.model
        )
        let firstResult = try await AgentHostedTextCanaryCoordinator(
            journal: first.store,
            provider: first.provider,
            transport: transport
        ).execute(acceptedRun: first.acceptance, request: first.request)
        let secondResult = try await AgentHostedTextCanaryCoordinator(
            journal: secondFixture.store,
            provider: secondFixture.provider,
            transport: transport
        ).execute(
            acceptedRun: secondFixture.acceptance,
            request: secondRequest
        )

        XCTAssertNotEqual(firstResult.scope, secondResult.scope)
        XCTAssertNotEqual(firstResult.attemptID, secondResult.attemptID)
        XCTAssertNotEqual(firstResult.items.map(\.id), secondResult.items.map(\.id))
        let firstEvents = try await first.store.events(
            for: first.runID,
            after: nil
        )
        let secondEvents = try await secondFixture.store.events(
            for: secondFixture.runID,
            after: nil
        )
        XCTAssertTrue(Set(firstEvents.map(\.event.header.eventID)).isDisjoint(
            with: Set(secondEvents.map(\.event.header.eventID))
        ))
        let transportCallCount = await transport.callCount()
        let observedScopes = await transport.observedScopes()
        XCTAssertEqual(transportCallCount, 2)
        XCTAssertEqual(Set(observedScopes).count, 2)
    }

    func testMaliciousProviderFailureIsMappedToFixedBoundedDurableMetadata() async throws {
        let fixture = try await makeCanaryFixture(seed: 22)
        let secret = "sk-hostile-do-not-persist"
        let transport = ScriptedCanaryTransport(
            mode: .maliciousFailure(secret: secret),
            model: fixture.model
        )
        let coordinator = AgentHostedTextCanaryCoordinator(
            journal: fixture.store,
            provider: fixture.provider,
            transport: transport
        )

        do {
            _ = try await coordinator.execute(
                acceptedRun: fixture.acceptance,
                request: fixture.request
            )
            XCTFail("A malicious provider failure completed")
        } catch let error as AgentHostedTextCanaryCoordinatorError {
            guard case let .attemptFailed(info) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(info.category, .transport)
            XCTAssertEqual(info.code, "hosted_text_provider_transport")
            XCTAssertEqual(
                info.publicMessage,
                "The hosted provider could not be reached safely."
            )
            XCTAssertFalse(info.retryable)
            XCTAssertFalse(info.code.contains(secret))
            XCTAssertFalse(info.publicMessage.contains(secret))
        }

        let encoded = try JSONEncoder().encode(
            await fixture.store.durableSnapshot()
        )
        XCTAssertNil(String(decoding: encoded, as: UTF8.self).range(of: secret))
    }

    func testResponseTerminalCommitThenThrowRecoversExactEnvelope() async throws {
        let fixture = try await makeCanaryFixture(seed: 23)
        let journal = CanaryAdversarialJournal(
            backing: fixture.store,
            mode: .commitThenThrow(.modelResponseCommitted)
        )
        let transport = ScriptedCanaryTransport(
            mode: .success,
            model: fixture.model
        )

        let result = try await AgentHostedTextCanaryCoordinator(
            journal: journal,
            provider: fixture.provider,
            transport: transport
        ).execute(acceptedRun: fixture.acceptance, request: fixture.request)

        XCTAssertEqual(result.terminalCommit.disposition, .alreadyCommitted)
        let events = try await journal.events(for: fixture.runID, after: nil)
        assertSingleAttemptLedger(events)
        XCTAssertEqual(events.last?.event.payload.kind, .modelResponseCommitted)
    }

    func testFailureTerminalCommitThenThrowRecoversWithoutContradictoryTerminal() async throws {
        let fixture = try await makeCanaryFixture(seed: 24)
        let journal = CanaryAdversarialJournal(
            backing: fixture.store,
            mode: .commitThenThrow(.modelRequestFailed)
        )
        let transport = ScriptedCanaryTransport(
            mode: .partialThenFail,
            model: fixture.model
        )

        do {
            _ = try await AgentHostedTextCanaryCoordinator(
                journal: journal,
                provider: fixture.provider,
                transport: transport
            ).execute(acceptedRun: fixture.acceptance, request: fixture.request)
            XCTFail("A failed attempt completed")
        } catch let error as AgentHostedTextCanaryCoordinatorError {
            guard case .attemptFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let events = try await journal.events(for: fixture.runID, after: nil)
        assertSingleAttemptLedger(events)
        XCTAssertEqual(events.last?.event.payload.kind, .modelRequestFailed)
    }

    func testExactAlreadyCommittedResponseIsRecoveredButMismatchedReceiptFailsClosed() async throws {
        let exactFixture = try await makeCanaryFixture(seed: 25)
        let exactJournal = CanaryAdversarialJournal(
            backing: exactFixture.store,
            mode: .returnAlreadyCommitted(.modelResponseCommitted)
        )
        let exactResult = try await AgentHostedTextCanaryCoordinator(
            journal: exactJournal,
            provider: exactFixture.provider,
            transport: ScriptedCanaryTransport(
                mode: .success,
                model: exactFixture.model
            )
        ).execute(
            acceptedRun: exactFixture.acceptance,
            request: exactFixture.request
        )
        XCTAssertEqual(exactResult.terminalCommit.disposition, .alreadyCommitted)

        let mismatchFixture = try await makeCanaryFixture(seed: 26)
        let mismatchJournal = CanaryAdversarialJournal(
            backing: mismatchFixture.store,
            mode: .mismatchedAlreadyCommitted(.modelResponseCommitted)
        )
        do {
            _ = try await AgentHostedTextCanaryCoordinator(
                journal: mismatchJournal,
                provider: mismatchFixture.provider,
                transport: ScriptedCanaryTransport(
                    mode: .success,
                    model: mismatchFixture.model
                )
            ).execute(
                acceptedRun: mismatchFixture.acceptance,
                request: mismatchFixture.request
            )
            XCTFail("A mismatched response receipt completed")
        } catch let error as AgentHostedTextCanaryCoordinatorError {
            guard case let .attemptFailed(info) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(info.category, .invariantViolation)
        }
        let mismatchEvents = try await mismatchJournal.events(
            for: mismatchFixture.runID,
            after: nil
        )
        assertSingleAttemptLedger(mismatchEvents)
        XCTAssertEqual(mismatchEvents.last?.event.payload.kind, .modelRequestFailed)
    }

    func testLateCallerCancellationCannotCancelDetachedFailureTerminal() async throws {
        let fixture = try await makeCanaryFixture(seed: 27)
        let journal = CanaryAdversarialJournal(
            backing: fixture.store,
            mode: .gateFailureAppend
        )
        let transport = ScriptedCanaryTransport(
            mode: .partialThenFail,
            model: fixture.model
        )
        let execution = Task {
            try await AgentHostedTextCanaryCoordinator(
                journal: journal,
                provider: fixture.provider,
                transport: transport
            ).execute(acceptedRun: fixture.acceptance, request: fixture.request)
        }

        try await waitForFailureAppend(journal)
        execution.cancel()
        await journal.releaseFailureAppend()
        do {
            _ = try await execution.value
            XCTFail("A failed attempt completed")
        } catch let error as AgentHostedTextCanaryCoordinatorError {
            guard case .attemptFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let appendObservedCancellation = await journal
            .observedCancelledFailureAppend()
        XCTAssertFalse(appendObservedCancellation)
        let events = try await journal.events(for: fixture.runID, after: nil)
        assertSingleAttemptLedger(events)
        XCTAssertEqual(events.last?.event.payload.kind, .modelRequestFailed)
    }

    func testCallerConfiguredNonOpenAIRouteCannotBorrowTrustedCapability() throws {
        let model = ProviderModelID(rawValue: "fixture-model")
        let trusted = TrustedHostedProviderCatalog.openAIChatCompletions(
            model: model
        )
        let customRoute = ProviderRoute(
            providerID: ProviderID(rawValue: "custom-openai-compatible"),
            modelID: model,
            adapterID: ProviderAdapterID(rawValue: "custom-chat"),
            capabilities: .hostedChatTextOnlyBaseline,
            deployment: .callerManaged,
            provenance: .callerConfigured
        )

        XCTAssertThrowsError(try AgentHostedTextCanaryProvider(
            trustedCatalog: trusted,
            declaredRoute: customRoute
        )) { error in
            XCTAssertEqual(
                error as? AgentHostedTextCanaryCoordinatorError,
                .nonOpenAIRoute
            )
        }
    }
}

private struct CanaryFixture {
    let store: InMemoryAgentEventJournal
    let acceptance: AgentRunAcceptance
    let provider: AgentHostedTextCanaryProvider
    let request: CanonicalProviderRequest
    let model: ProviderModelID

    var runID: RunID { acceptance.metadata.runID }
}

private func makeCanaryFixture(seed: UInt64) async throws -> CanaryFixture {
    let fixture = makeUnacceptedCanaryFixture(seed: seed)
    _ = try await fixture.store.accept(fixture.acceptance)
    return fixture
}

private func makeUnacceptedCanaryFixture(seed: UInt64) -> CanaryFixture {
    let acceptedAt = AgentInstant(rawValue: 2_100_000_000_000 + Int64(seed))
    let runID: RunID = canaryTestID(seed * 100 + 1)
    let context = AgentRunContext(
        schemaVersion: .v1_1,
        lineage: .root(runID),
        conversationID: canaryTestID(seed * 100 + 2),
        projectID: canaryTestID(seed * 100 + 3),
        workspaceID: canaryTestID(seed * 100 + 4),
        executionNodeID: canaryTestID(seed * 100 + 5),
        engineVersion: AgentHostedTextCanaryCoordinator.engineVersion,
        acceptedAt: acceptedAt,
        features: AgentHostedTextCanaryCoordinator.featureSet,
        cancellation: CancellationLineage(
            scopeID: canaryTestID(seed * 100 + 6)
        ),
        initialBudget: AgentBudget(limits: .standard)
    )
    let userItem = ModelItem(
        id: canaryTestID(seed * 100 + 7),
        createdAt: acceptedAt,
        payload: .message(ModelMessage(
            role: .user,
            content: [.text("Hello")]
        ))
    )
    let eventID: EventID = canaryTestID(seed * 100 + 8)
    let writerID = AgentEventWriterID(runID: runID)
    let envelope = AgentEventEnvelope(
        writerID: writerID,
        writerSequence: .first,
        idempotencyKey: "canary-test-accept-\(seed)",
        event: AgentEvent(
            header: AgentEventHeader(
                eventID: eventID,
                schemaVersion: context.schemaVersion,
                context: context,
                sequence: .first,
                timestamp: acceptedAt,
                causationID: nil,
                correlationID: canaryTestID(seed * 100 + 9)
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
            acceptanceCommandID: canaryTestID(seed * 100 + 10),
            acceptanceEventID: eventID
        ),
        envelope: envelope
    )
    let model = ProviderModelID(rawValue: "fixture-model")
    return CanaryFixture(
        store: InMemoryAgentEventJournal(clock: {
            AgentInstant(rawValue: 2_100_000_001_000 + Int64(seed))
        }),
        acceptance: acceptance,
        provider: try! AgentHostedTextCanaryProvider
            .openAIChatCompletions(model: model),
        request: CanonicalProviderRequest(
            requestID: "canary-request-\(seed)",
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

private actor EOFControlledCanaryTransport: ProviderTransport {
    private let model: ProviderModelID
    private let gate = CanaryAsyncGate()
    private var calls = 0

    init(model: ProviderModelID) {
        self.model = model
    }

    func stream(
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        calls += 1
        let frames = successfulChatFrames(model: model, includeDone: false)
        let gate = gate
        return AsyncThrowingStream { continuation in
            Task {
                for frame in frames { continuation.yield(frame) }
                await gate.wait()
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    func releaseEOF() async { await gate.open() }
    func callCount() -> Int { calls }
}

private actor ScriptedCanaryTransport: ProviderTransport {
    enum Mode: Sendable {
        case success
        case partialThenFail
        case waitForCancellation
        case maliciousFailure(secret: String)
    }

    private let mode: Mode
    private let model: ProviderModelID
    private var calls = 0
    private var scopes: [ProviderAttemptScope] = []

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
        scopes.append(scope)
        switch mode {
        case .success:
            let frames = successfulChatFrames(model: model, includeDone: true)
            return AsyncThrowingStream { continuation in
                for frame in frames { continuation.yield(frame) }
                continuation.finish()
            }
        case .partialThenFail:
            let frames = Array(successfulChatFrames(
                model: model,
                includeDone: false
            ).prefix(2))
            return AsyncThrowingStream { continuation in
                for frame in frames { continuation.yield(frame) }
                continuation.finish(throwing: CanaryTransportTestError.failed)
            }
        case .waitForCancellation:
            while true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        case let .maliciousFailure(secret):
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ProviderFailure(
                    category: .transport,
                    code: "hostile-\(secret)",
                    publicMessage: "raw \(secret)",
                    providerID: ProviderID(rawValue: "openai"),
                    adapterID: ProviderAdapterID(
                        rawValue: "openai-chat-completions"
                    )
                ))
            }
        }
    }

    func callCount() -> Int { calls }
    func observedScopes() -> [ProviderAttemptScope] { scopes }
}

private actor CanaryAdversarialJournal: AgentEventJournal {
    enum Mode: Sendable {
        case commitThenThrow(AgentEventKind)
        case returnAlreadyCommitted(AgentEventKind)
        case mismatchedAlreadyCommitted(AgentEventKind)
        case gateFailureAppend
        case stripProviderAttemptMetadata
    }

    private let backing: InMemoryAgentEventJournal
    private let mode: Mode
    private let failureAppendGate = CanaryAsyncGate()
    private var didInject = false
    private var failureAppendEntered = false
    private var failureAppendWasCancelled = false

    init(backing: InMemoryAgentEventJournal, mode: Mode) {
        self.backing = backing
        self.mode = mode
    }

    func accept(
        _ acceptance: AgentRunAcceptance
    ) async throws -> AgentJournalCommit {
        try await backing.accept(acceptance)
    }

    func append(
        _ envelope: AgentEventEnvelope
    ) async throws -> AgentJournalCommit {
        if !didInject {
            switch mode {
            case let .commitThenThrow(kind)
                where envelope.event.payload.kind == kind:
                didInject = true
                _ = try await backing.append(envelope)
                throw CanaryAdversarialJournalError.committedThenThrew

            case let .returnAlreadyCommitted(kind)
                where envelope.event.payload.kind == kind:
                didInject = true
                let committed = try await backing.append(envelope)
                return AgentJournalCommit(
                    disposition: .alreadyCommitted,
                    record: committed.record
                )

            case let .mismatchedAlreadyCommitted(kind)
                where envelope.event.payload.kind == kind:
                didInject = true
                let records = try await backing.events(
                    for: envelope.runID,
                    after: nil
                )
                guard let mismatched = records.first else {
                    throw CanaryAdversarialJournalError.missingMismatchRecord
                }
                return AgentJournalCommit(
                    disposition: .alreadyCommitted,
                    record: mismatched
                )

            case .gateFailureAppend
                where envelope.event.payload.kind == .modelRequestFailed:
                didInject = true
                failureAppendEntered = true
                failureAppendWasCancelled = Task.isCancelled
                await failureAppendGate.wait()
                failureAppendWasCancelled =
                    failureAppendWasCancelled || Task.isCancelled

            case .stripProviderAttemptMetadata:
                guard case let .modelRequestStarted(started) =
                        envelope.event.payload else { break }
                didInject = true
                let stripped = AgentEventEnvelope(
                    writerID: envelope.writerID,
                    writerSequence: envelope.writerSequence,
                    idempotencyKey: envelope.idempotencyKey,
                    event: AgentEvent(
                        header: envelope.event.header,
                        payload: .modelRequestStarted(ModelRequestStartedEvent(
                            attemptID: started.attemptID,
                            route: started.route,
                            providerAttempt: .legacyV1
                        ))
                    )
                )
                return try await backing.append(stripped)

            default:
                break
            }
        }
        return try await backing.append(envelope)
    }

    func metadata(
        for runID: RunID
    ) async throws -> AgentRunMetadataRecord? {
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

    func hasEnteredFailureAppend() -> Bool { failureAppendEntered }

    func observedCancelledFailureAppend() -> Bool {
        failureAppendWasCancelled
    }

    func releaseFailureAppend() async {
        await failureAppendGate.open()
    }
}

private enum CanaryAdversarialJournalError: Error {
    case committedThenThrew
    case missingMismatchRecord
}

private actor CanaryAsyncGate {
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

private enum CanaryTransportTestError: Error {
    case failed
    case timedOut
}

private func successfulChatFrames(
    model: ProviderModelID,
    includeDone: Bool
) -> [ProviderWireFrame] {
    var frames: [ProviderWireFrame] = [
        .json(.object([
            "id": .string("chat-canary-1"),
            "model": .string(model.rawValue),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object(["content": .string("Hel")]),
                "finish_reason": .null,
            ])]),
        ])),
        .json(.object([
            "id": .string("chat-canary-1"),
            "model": .string(model.rawValue),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object(["content": .string("lo")]),
                "finish_reason": .null,
            ])]),
        ])),
        .json(.object([
            "id": .string("chat-canary-1"),
            "model": .string(model.rawValue),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object([:]),
                "finish_reason": .string("stop"),
            ])]),
        ])),
        .json(.object([
            "id": .string("chat-canary-1"),
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
    ]
    if includeDone { frames.append(.done) }
    return frames
}

private func waitForTransportCalls(
    _ expected: Int,
    transport: some CanaryTransportCallCounting
) async throws {
    for _ in 0 ..< 200 {
        if await transport.callCount() >= expected { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw CanaryTransportTestError.timedOut
}

private func waitForEventCount(
    _ expected: Int,
    store: InMemoryAgentEventJournal,
    runID: RunID
) async throws {
    for _ in 0 ..< 200 {
        if try await store.events(for: runID, after: nil).count >= expected {
            return
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw CanaryTransportTestError.timedOut
}

private func waitForFailureAppend(
    _ journal: CanaryAdversarialJournal
) async throws {
    for _ in 0 ..< 200 {
        if await journal.hasEnteredFailureAppend() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw CanaryTransportTestError.timedOut
}

private protocol CanaryTransportCallCounting: Actor {
    func callCount() -> Int
}

extension EOFControlledCanaryTransport: CanaryTransportCallCounting {}
extension ScriptedCanaryTransport: CanaryTransportCallCounting {}

private func assertSingleAttemptLedger(
    _ events: [StoredAgentEvent],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        events.map(\.event.header.sequence.rawValue),
        [1, 2, 3, 4],
        file: file,
        line: line
    )
    XCTAssertEqual(
        events.filter { $0.event.payload.kind == .runStarted }.count,
        1,
        file: file,
        line: line
    )
    XCTAssertEqual(
        events.filter { $0.event.payload.kind == .modelRequestStarted }.count,
        1,
        file: file,
        line: line
    )
    XCTAssertEqual(
        events.filter {
            $0.event.payload.kind == .modelResponseCommitted ||
                $0.event.payload.kind == .modelRequestFailed
        }.count,
        1,
        file: file,
        line: line
    )
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

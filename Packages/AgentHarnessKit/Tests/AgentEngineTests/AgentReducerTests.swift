import AgentDomain
import AgentEngine
import Foundation
import XCTest

final class AgentReducerTests: XCTestCase {
    func testLegalModelLifecycleSettlesOnceWithMonotonicSequenceAndUsage() throws {
        let fixture = ReducerFixture()
        let attemptID: AttemptID = tagged(30)
        let assistantItem = fixture.assistantItem(id: tagged(31), text: "Done")
        var state = AgentRunState.initial

        state = try reduced(state, fixture.event(1, .runAccepted(
            RunAcceptedEvent(context: fixture.context, initialItems: [fixture.userItem])
        )))
        state = try reduced(state, fixture.event(2, .runQueued(RunQueuedEvent())))
        state = try reduced(state, fixture.event(3, .runStarted(RunStartedEvent())))
        state = try reduced(state, fixture.event(4, .modelRequestStarted(
            ModelRequestStartedEvent(attemptID: attemptID, route: fixture.route)
        )))
        state = try reduced(state, fixture.event(5, .modelResponseCommitted(
            ModelResponseCommittedEvent(
                attemptID: attemptID,
                items: [assistantItem],
                usage: ModelUsage(inputTokens: 100, cachedInputTokens: 25, outputTokens: 12, costMicrounits: 400),
                finishReason: .completed
            )
        )))
        state = try reduced(state, fixture.event(6, .runCompleted(RunCompletedEvent())))

        XCTAssertEqual(state.phase, .completed)
        XCTAssertEqual(state.lastSequence, EventSequence(rawValue: 6))
        XCTAssertEqual(state.terminalEventID, fixture.eventID(6))
        XCTAssertEqual(state.modelItems, [fixture.userItem, assistantItem])
        XCTAssertEqual(state.budget?.usage.iterations, 1)
        XCTAssertEqual(state.budget?.usage.providerAttempts, 1)
        XCTAssertEqual(state.budget?.usage.inputTokens, 100)
        XCTAssertEqual(state.budget?.usage.outputTokens, 12)
        XCTAssertEqual(state.budget?.usage.costMicrounits, 400)
    }

    func testIllegalTransitionReturnsFailureWithoutMutatingInput() throws {
        let fixture = ReducerFixture()
        var state = try reduced(.initial, fixture.acceptanceEvent)
        let before = state
        let illegal = fixture.event(2, .modelResponseCommitted(
            ModelResponseCommittedEvent(
                attemptID: tagged(40),
                items: [],
                usage: ModelUsage(inputTokens: 1, outputTokens: 1),
                finishReason: .completed
            )
        ))

        switch AgentReducer.reduce(state, event: illegal) {
        case .success:
            XCTFail("Illegal transition unexpectedly succeeded")
        case let .failure(failure):
            XCTAssertEqual(
                failure,
                .invalidTransition(phase: .accepted, event: .modelResponseCommitted)
            )
        }
        XCTAssertEqual(state, before)

        state = try reduced(state, fixture.event(2, .runStarted(RunStartedEvent())))
        XCTAssertEqual(state.phase, .running)
    }

    func testSequenceMustBeContiguousAndRejectedEventDoesNotAdvanceState() throws {
        let fixture = ReducerFixture()
        let state = try reduced(.initial, fixture.acceptanceEvent)
        let before = state
        let skipped = fixture.event(3, .runStarted(RunStartedEvent()))

        switch AgentReducer.reduce(state, event: skipped) {
        case .success:
            XCTFail("Sequence gap unexpectedly succeeded")
        case let .failure(failure):
            XCTAssertEqual(
                failure,
                .nonMonotonicSequence(
                    expected: EventSequence(rawValue: 2),
                    actual: EventSequence(rawValue: 3)
                )
            )
        }
        XCTAssertEqual(state, before)
    }

    func testReplayingTheSameLedgerProducesByteIdenticalState() throws {
        let fixture = ReducerFixture()
        let attemptID: AttemptID = tagged(45)
        let events: [AgentEvent] = [
            fixture.acceptanceEvent,
            fixture.event(2, .runStarted(RunStartedEvent())),
            fixture.event(3, .modelRequestStarted(
                ModelRequestStartedEvent(attemptID: attemptID, route: fixture.route)
            )),
            fixture.event(4, .modelResponseCommitted(
                ModelResponseCommittedEvent(
                    attemptID: attemptID,
                    items: [fixture.assistantItem(id: tagged(46), text: "Stable")],
                    usage: ModelUsage(inputTokens: 10, outputTokens: 2),
                    finishReason: .completed
                )
            )),
            fixture.event(5, .runCompleted(RunCompletedEvent())),
        ]

        let first = try events.reduce(AgentRunState.initial) { state, event in
            try reduced(state, event)
        }
        let second = try events.reduce(AgentRunState.initial) { state, event in
            try reduced(state, event)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        XCTAssertEqual(first, second)
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
    }

    func testTerminalTransitionCanHappenAtMostOnce() throws {
        let fixture = ReducerFixture()
        var state = try reduced(.initial, fixture.acceptanceEvent)
        state = try reduced(state, fixture.event(2, .runStarted(RunStartedEvent())))
        state = try reduced(state, fixture.event(3, .runCompleted(RunCompletedEvent())))
        let terminal = state
        let laterFailure = fixture.event(4, .runFailed(
            RunFailedEvent(error: fixture.error(code: "late_failure"))
        ))

        switch AgentReducer.reduce(state, event: laterFailure) {
        case .success:
            XCTFail("Second terminal event unexpectedly succeeded")
        case let .failure(failure):
            XCTAssertEqual(
                failure,
                .alreadyTerminal(terminalEventID: fixture.eventID(3))
            )
        }
        XCTAssertEqual(state, terminal)
    }

    func testProviderRetryOnlyFollowsUncommittedFailureAndPreservesAttemptLineage() throws {
        let fixture = ReducerFixture()
        let firstAttempt: AttemptID = tagged(50)
        let secondAttempt: AttemptID = tagged(51)
        var state = try reduced(.initial, fixture.acceptanceEvent)
        state = try reduced(state, fixture.event(2, .runStarted(RunStartedEvent())))
        state = try reduced(state, fixture.event(3, .modelRequestStarted(
            ModelRequestStartedEvent(attemptID: firstAttempt, route: fixture.route)
        )))
        state = try reduced(state, fixture.event(4, .modelRequestFailed(
            ModelRequestFailedEvent(
                attemptID: firstAttempt,
                error: fixture.error(code: "temporary", retryable: true),
                outputWasCommitted: false
            )
        )))
        state = try reduced(state, fixture.event(5, .retryScheduled(
            RetryScheduledEvent(
                failedAttemptID: firstAttempt,
                nextAttemptID: secondAttempt,
                reason: "fallback"
            )
        )))
        state = try reduced(state, fixture.event(6, .modelRequestStarted(
            ModelRequestStartedEvent(attemptID: secondAttempt, route: fixture.fallbackRoute)
        )))
        state = try reduced(state, fixture.event(7, .modelResponseCommitted(
            ModelResponseCommittedEvent(
                attemptID: secondAttempt,
                items: [fixture.assistantItem(id: tagged(52), text: "Recovered")],
                usage: ModelUsage(inputTokens: 80, outputTokens: 9),
                finishReason: .completed
            )
        )))
        state = try reduced(state, fixture.event(8, .runCompleted(RunCompletedEvent())))

        XCTAssertEqual(
            state.retryLineage,
            [AttemptRetryLineage(
                failedAttemptID: firstAttempt,
                nextAttemptID: secondAttempt,
                reason: "fallback"
            )]
        )
        XCTAssertEqual(state.budget?.usage.providerAttempts, 2)
        XCTAssertEqual(state.budget?.usage.retries, 1)

        var committedFailureState = try reduced(.initial, fixture.acceptanceEvent)
        committedFailureState = try reduced(
            committedFailureState,
            fixture.event(2, .runStarted(RunStartedEvent()))
        )
        committedFailureState = try reduced(
            committedFailureState,
            fixture.event(3, .modelRequestStarted(
                ModelRequestStartedEvent(attemptID: firstAttempt, route: fixture.route)
            ))
        )
        committedFailureState = try reduced(
            committedFailureState,
            fixture.event(4, .modelRequestFailed(
                ModelRequestFailedEvent(
                    attemptID: firstAttempt,
                    error: fixture.error(code: "partial"),
                    outputWasCommitted: true
                )
            ))
        )
        let retry = fixture.event(5, .retryScheduled(
            RetryScheduledEvent(
                failedAttemptID: firstAttempt,
                nextAttemptID: secondAttempt,
                reason: "unsafe retry"
            )
        ))
        assertReductionFailure(
            AgentReducer.reduce(committedFailureState, event: retry),
            equals: .retryNotAllowed(firstAttempt)
        )
    }

    func testV11ProviderDispatchUsageAndFinishFactsSurviveStateRoundTrip() throws {
        let fixture = ReducerFixture(schemaVersion: .v1_1)
        let attemptID: AttemptID = tagged(54)
        let providerAttempt = try fixture.providerAttempt(
            attemptID: attemptID,
            ordinal: 3,
            recoverySeed: 0xFEED_FACE
        )
        let usage = ModelUsage(
            inputTokens: 81,
            cachedInputTokens: 21,
            outputTokens: 13,
            costMicrounits: 610
        )
        var state = try reduced(.initial, fixture.acceptanceEvent)
        state = try reduced(state, fixture.event(2, .runStarted(RunStartedEvent())))
        state = try reduced(state, fixture.event(3, .modelRequestStarted(
            ModelRequestStartedEvent(
                attemptID: attemptID,
                route: fixture.route,
                providerAttempt: providerAttempt
            )
        )))
        state = try reduced(state, fixture.event(4, .modelResponseCommitted(
            ModelResponseCommittedEvent(
                attemptID: attemptID,
                items: [fixture.assistantItem(id: tagged(55), text: "Recorded")],
                usage: usage,
                finishReason: .completed
            )
        )))

        let attempt = try XCTUnwrap(state.modelAttempts.first)
        XCTAssertEqual(attempt.providerAttempt, providerAttempt)
        XCTAssertEqual(attempt.usage, usage)
        XCTAssertEqual(attempt.finishReason, .completed)
        XCTAssertEqual(
            try JSONDecoder().decode(
                AgentRunState.self,
                from: JSONEncoder().encode(state)
            ),
            state
        )
    }

    func testV11AcceptanceRejectsEngineVersionSubstitution() {
        let fixture = ReducerFixture(schemaVersion: .v1_1)
        let substituted = fixture.event(1, .runAccepted(RunAcceptedEvent(
            context: fixture.context,
            acceptedEngineVersion: .agentHarnessV1,
            initialItems: [fixture.userItem]
        )))

        assertReductionFailure(
            AgentReducer.reduce(.initial, event: substituted),
            equals: .acceptedEngineVersionMismatch
        )
        XCTAssertEqual(AgentRunState.initial, .initial)
    }

    func testV11RejectsMissingOrReusedProviderDispatchFactsWithoutMutation() throws {
        let fixture = ReducerFixture(schemaVersion: .v1_1)
        let firstAttempt: AttemptID = tagged(56)
        var state = try reduced(.initial, fixture.acceptanceEvent)
        state = try reduced(state, fixture.event(2, .runStarted(RunStartedEvent())))

        let missing = fixture.event(3, .modelRequestStarted(
            ModelRequestStartedEvent(attemptID: firstAttempt, route: fixture.route)
        ))
        let beforeMissing = state
        assertReductionFailure(
            AgentReducer.reduce(state, event: missing),
            equals: .missingProviderAttemptMetadata(firstAttempt)
        )
        XCTAssertEqual(state, beforeMissing)

        let firstMetadata = try fixture.providerAttempt(
            attemptID: firstAttempt,
            ordinal: 0,
            recoverySeed: 1,
            requestID: "same-request",
            providerAttemptID: "same-provider-attempt"
        )
        state = try reduced(state, fixture.event(3, .modelRequestStarted(
            ModelRequestStartedEvent(
                attemptID: firstAttempt,
                route: fixture.route,
                providerAttempt: firstMetadata
            )
        )))
        state = try reduced(state, fixture.event(4, .modelRequestFailed(
            ModelRequestFailedEvent(
                attemptID: firstAttempt,
                error: fixture.error(code: "retry", retryable: true),
                outputWasCommitted: false
            )
        )))
        let secondAttempt: AttemptID = tagged(57)
        state = try reduced(state, fixture.event(5, .retryScheduled(
            RetryScheduledEvent(
                failedAttemptID: firstAttempt,
                nextAttemptID: secondAttempt,
                reason: "retry"
            )
        )))
        let duplicateScope = try fixture.providerAttempt(
            attemptID: secondAttempt,
            ordinal: 1,
            recoverySeed: 2,
            requestID: "same-request",
            providerAttemptID: "same-provider-attempt"
        )
        let duplicate = fixture.event(6, .modelRequestStarted(
            ModelRequestStartedEvent(
                attemptID: secondAttempt,
                route: fixture.route,
                providerAttempt: duplicateScope
            )
        ))
        let beforeDuplicate = state
        assertReductionFailure(
            AgentReducer.reduce(state, event: duplicate),
            equals: .duplicateProviderAttemptScope
        )
        XCTAssertEqual(state, beforeDuplicate)
    }

    func testV11RequiresRawProviderToolCallIdentity() throws {
        let fixture = ReducerFixture(schemaVersion: .v1_1)
        let attemptID: AttemptID = tagged(58)
        let invocation = fixture.invocation(attemptID: attemptID)
        var state = try reduced(.initial, fixture.acceptanceEvent)
        state = try reduced(state, fixture.event(2, .runStarted(RunStartedEvent())))
        state = try reduced(state, fixture.event(3, .modelRequestStarted(
            ModelRequestStartedEvent(
                attemptID: attemptID,
                route: fixture.route,
                providerAttempt: try fixture.providerAttempt(
                    attemptID: attemptID,
                    ordinal: 0,
                    recoverySeed: 3
                )
            )
        )))
        let committed = fixture.event(4, .modelResponseCommitted(
            ModelResponseCommittedEvent(
                attemptID: attemptID,
                items: [ModelItem(
                    id: tagged(59),
                    createdAt: fixture.instant(4),
                    payload: .toolInvocation(invocation)
                )],
                usage: ModelUsage(inputTokens: 2, outputTokens: 1),
                finishReason: .toolCalls
            )
        ))
        let before = state
        assertReductionFailure(
            AgentReducer.reduce(state, event: committed),
            equals: .invalidProviderToolCallID(invocation.callID)
        )
        XCTAssertEqual(state, before)
    }

    func testV11RejectsDuplicateRawProviderToolCallIdentity() throws {
        let fixture = ReducerFixture(schemaVersion: .v1_1)
        let attemptID: AttemptID = tagged(68)
        let first = fixture.invocation(
            attemptID: attemptID,
            providerCallID: "duplicate-provider-call"
        )
        let second = ToolInvocation(
            callID: tagged(69),
            providerCallID: first.providerCallID,
            modelAttemptID: attemptID,
            tool: first.tool,
            arguments: first.arguments,
            canonicalArgumentDigest: first.canonicalArgumentDigest,
            idempotencyKey: "operation-duplicate-provider-id",
            effectClass: first.effectClass,
            locality: first.locality
        )
        var state = try reduced(.initial, fixture.acceptanceEvent)
        state = try reduced(state, fixture.event(2, .runStarted(RunStartedEvent())))
        state = try reduced(state, fixture.event(3, .modelRequestStarted(
            ModelRequestStartedEvent(
                attemptID: attemptID,
                route: fixture.route,
                providerAttempt: try fixture.providerAttempt(
                    attemptID: attemptID,
                    ordinal: 0,
                    recoverySeed: 4
                )
            )
        )))
        let duplicate = fixture.event(4, .modelResponseCommitted(
            ModelResponseCommittedEvent(
                attemptID: attemptID,
                items: [
                    ModelItem(
                        id: tagged(680),
                        createdAt: fixture.instant(4),
                        payload: .toolInvocation(first)
                    ),
                    ModelItem(
                        id: tagged(681),
                        createdAt: fixture.instant(4),
                        payload: .toolInvocation(second)
                    ),
                ],
                usage: ModelUsage(inputTokens: 3, outputTokens: 2),
                finishReason: .toolCalls
            )
        ))

        assertReductionFailure(
            AgentReducer.reduce(state, event: duplicate),
            equals: .duplicateProviderToolCallID("duplicate-provider-call")
        )
    }

    func testV11RejectsProviderToolCallIdentityReusedAcrossCommittedRounds() throws {
        let fixture = ReducerFixture(schemaVersion: .v1_1)
        let firstAttempt: AttemptID = tagged(74)
        let secondAttempt: AttemptID = tagged(75)
        let first = fixture.invocation(
            attemptID: firstAttempt,
            providerCallID: "cross-round-provider-call"
        )
        let second = ToolInvocation(
            callID: tagged(76),
            providerCallID: first.providerCallID,
            modelAttemptID: secondAttempt,
            tool: first.tool,
            arguments: first.arguments,
            canonicalArgumentDigest: first.canonicalArgumentDigest,
            idempotencyKey: "cross-round-second-operation",
            effectClass: first.effectClass,
            locality: first.locality
        )
        var state = try reduced(.initial, fixture.acceptanceEvent)
        state = try reduced(state, fixture.event(2, .runStarted(RunStartedEvent())))
        state = try reduced(state, fixture.event(3, .modelRequestStarted(
            ModelRequestStartedEvent(
                attemptID: firstAttempt,
                route: fixture.route,
                providerAttempt: try fixture.providerAttempt(
                    attemptID: firstAttempt,
                    ordinal: 0,
                    recoverySeed: 5,
                    requestID: "round-one"
                )
            )
        )))
        state = try reduced(state, fixture.event(4, .modelResponseCommitted(
            ModelResponseCommittedEvent(
                attemptID: firstAttempt,
                items: [ModelItem(
                    id: tagged(740),
                    createdAt: fixture.instant(4),
                    payload: .toolInvocation(first)
                )],
                usage: ModelUsage(inputTokens: 3, outputTokens: 1),
                finishReason: .toolCalls
            )
        )))
        state = try reduced(state, fixture.event(5, .modelRequestStarted(
            ModelRequestStartedEvent(
                attemptID: secondAttempt,
                route: fixture.route,
                providerAttempt: try fixture.providerAttempt(
                    attemptID: secondAttempt,
                    ordinal: 1,
                    recoverySeed: 6,
                    requestID: "round-two"
                )
            )
        )))
        let duplicate = fixture.event(6, .modelResponseCommitted(
            ModelResponseCommittedEvent(
                attemptID: secondAttempt,
                items: [ModelItem(
                    id: tagged(750),
                    createdAt: fixture.instant(6),
                    payload: .toolInvocation(second)
                )],
                usage: ModelUsage(inputTokens: 4, outputTokens: 1),
                finishReason: .toolCalls
            )
        ))
        let before = state

        assertReductionFailure(
            AgentReducer.reduce(state, event: duplicate),
            equals: .duplicateProviderToolCallID("cross-round-provider-call")
        )
        XCTAssertEqual(state, before)
    }

    func testV11MutationEffectDigestsAreStageBoundAndTamperEvident() throws {
        let fixture = ReducerFixture(schemaVersion: .v1_1)
        let attemptID: AttemptID = tagged(70)
        let invocation = fixture.invocation(
            attemptID: attemptID,
            providerCallID: "provider-call-70"
        )
        let request = fixture.approval(for: invocation)
        let firstEffect = try fixture.effectReferences(seed: "11")
        let secondEffect = try fixture.effectReferences(seed: "22")
        let result = ToolResult(
            modelItemID: tagged(71),
            callID: invocation.callID,
            status: .succeeded,
            output: .object(["changed": .bool(true)])
        )
        var state = try fixture.v11StateAwaitingApproval(
            attemptID: attemptID,
            invocation: invocation,
            request: request
        )
        state = try reduced(state, fixture.event(7, .approvalResolved(
            ApprovalResolvedEvent(resolution: ApprovalResolution(
                requestID: request.requestID,
                callID: invocation.callID,
                decision: .approved,
                resolvedAt: fixture.instant(7)
            ))
        )))
        state = try reduced(state, fixture.event(8, .toolScheduled(
            ToolScheduledEvent(callID: invocation.callID, effect: firstEffect.key)
        )))

        assertReductionFailure(
            AgentReducer.reduce(state, event: fixture.event(9, .toolStarted(
                ToolStartedEvent(callID: invocation.callID, effect: secondEffect.key)
            ))),
            equals: .toolEffectMismatch(invocation.callID)
        )
        state = try reduced(state, fixture.event(9, .toolStarted(
            ToolStartedEvent(callID: invocation.callID, effect: firstEffect.key)
        )))
        assertReductionFailure(
            AgentReducer.reduce(state, event: fixture.event(10, .toolCompleted(
                ToolCompletedEvent(result: result)
            ))),
            equals: .missingToolEffect(invocation.callID)
        )
        state = try reduced(state, fixture.event(10, .toolApplied(
            ToolAppliedEvent(
                callID: invocation.callID,
                effect: firstEffect.receipt,
                evidence: [ToolEvidence(kind: "post_hash", digest: "post-hash")]
            )
        )))
        assertReductionFailure(
            AgentReducer.reduce(state, event: fixture.event(11, .toolCompleted(
                ToolCompletedEvent(result: result, effect: secondEffect.receipt)
            ))),
            equals: .toolEffectMismatch(invocation.callID)
        )
        state = try reduced(state, fixture.event(11, .toolCompleted(
            ToolCompletedEvent(result: result, effect: firstEffect.receipt)
        )))

        XCTAssertEqual(state.tools.first?.effectKey, firstEffect.key)
        XCTAssertEqual(state.tools.first?.effectReceipt, firstEffect.receipt)
        XCTAssertEqual(state.tools.first?.status, .completed)
    }

    func testV11ApprovalRejectionAddsOnlyCanonicalNonEffectResult() throws {
        let fixture = ReducerFixture(schemaVersion: .v1_1)
        let attemptID: AttemptID = tagged(72)
        let invocation = fixture.invocation(
            attemptID: attemptID,
            providerCallID: "provider-call-72"
        )
        let request = fixture.approval(for: invocation)
        var state = try fixture.v11StateAwaitingApproval(
            attemptID: attemptID,
            invocation: invocation,
            request: request
        )
        state = try reduced(state, fixture.event(7, .approvalResolved(
            ApprovalResolvedEvent(resolution: ApprovalResolution(
                requestID: request.requestID,
                callID: invocation.callID,
                decision: .rejected,
                resolvedAt: fixture.instant(7)
            ))
        )))
        let effect = try fixture.effectReferences(seed: "33")
        assertReductionFailure(
            AgentReducer.reduce(state, event: fixture.event(8, .toolScheduled(
                ToolScheduledEvent(callID: invocation.callID, effect: effect.key)
            ))),
            equals: .invalidToolTransition(
                callID: invocation.callID,
                from: .rejected,
                event: .toolScheduled
            )
        )

        let canonical = ToolResult.approvalRejected(
            modelItemID: tagged(73),
            callID: invocation.callID
        )
        let noncanonical = ToolResult(
            modelItemID: canonical.modelItemID,
            callID: canonical.callID,
            status: canonical.status,
            output: canonical.output,
            warnings: ["not canonical"],
            error: canonical.error
        )
        assertReductionFailure(
            AgentReducer.reduce(state, event: fixture.event(8, .toolCompleted(
                ToolCompletedEvent(result: noncanonical)
            ))),
            equals: .invalidApprovalRejectionResult(invocation.callID)
        )
        state = try reduced(state, fixture.event(8, .toolCompleted(
            ToolCompletedEvent(result: canonical)
        )))
        state = try reduced(state, fixture.event(9, .runCompleted(RunCompletedEvent())))

        XCTAssertEqual(state.phase, .completed)
        XCTAssertEqual(state.tools.first?.status, .rejected)
        XCTAssertEqual(state.tools.first?.result, canonical)
        XCTAssertNil(state.tools.first?.effectKey)
        XCTAssertNil(state.tools.first?.effectReceipt)
        XCTAssertTrue(state.tools.first?.applicationEvidence.isEmpty == true)
        XCTAssertTrue(state.artifacts.isEmpty)
    }

    func testCancellationPropagatesAndRetryRunKeepsRootLineage() throws {
        let original = ReducerFixture()
        var state = try reduced(.initial, original.acceptanceEvent)
        state = try reduced(state, original.event(2, .cancellationRequested(
            CancellationRequestedEvent(reason: .userRequested, propagateToDescendants: true)
        )))
        state = try reduced(state, original.event(3, .runCancelled(
            RunCancelledEvent(reason: .userRequested)
        )))

        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertEqual(state.cancellation?.propagateToDescendants, true)
        XCTAssertEqual(state.context?.cancellation.scopeID, original.context.cancellation.scopeID)

        let retry = ReducerFixture(retrying: original)
        let retryState = try reduced(.initial, retry.acceptanceEvent)
        XCTAssertEqual(retryState.context?.lineage.rootRunID, original.context.lineage.rootRunID)
        XCTAssertEqual(retryState.context?.lineage.retryOfRunID, original.context.lineage.runID)
        XCTAssertEqual(
            retryState.context?.cancellation.parentScopeID,
            original.context.cancellation.scopeID
        )
    }

    func testToolApprovalAndMutationLifecycleIsExplicit() throws {
        let fixture = ReducerFixture()
        let attemptID: AttemptID = tagged(60)
        let invocation = fixture.invocation(attemptID: attemptID)
        let request = fixture.approval(for: invocation)
        let result = ToolResult(
            modelItemID: tagged(65),
            callID: invocation.callID,
            status: .succeeded,
            output: .object(["changed": .bool(true)])
        )
        var state = try reduced(.initial, fixture.acceptanceEvent)
        state = try reduced(state, fixture.event(2, .runStarted(RunStartedEvent())))
        state = try reduced(state, fixture.event(3, .modelRequestStarted(
            ModelRequestStartedEvent(attemptID: attemptID, route: fixture.route)
        )))
        state = try reduced(state, fixture.event(4, .modelResponseCommitted(
            ModelResponseCommittedEvent(
                attemptID: attemptID,
                items: [ModelItem(
                    id: tagged(61),
                    createdAt: fixture.instant(4),
                    payload: .toolInvocation(invocation)
                )],
                usage: ModelUsage(inputTokens: 70, outputTokens: 15),
                finishReason: .toolCalls
            )
        )))
        state = try reduced(state, fixture.event(5, .toolProposed(
            ToolProposedEvent(invocation: invocation)
        )))

        let beforeIllegalStart = state
        assertReductionFailure(
            AgentReducer.reduce(
                state,
                event: fixture.event(6, .toolStarted(ToolStartedEvent(callID: invocation.callID)))
            ),
            equals: .invalidToolTransition(
                callID: invocation.callID,
                from: .proposed,
                event: .toolStarted
            )
        )
        XCTAssertEqual(state, beforeIllegalStart)

        state = try reduced(state, fixture.event(6, .approvalRequested(
            ApprovalRequestedEvent(request: request)
        )))
        XCTAssertEqual(state.phase, .awaitingApproval)
        state = try reduced(state, fixture.event(7, .approvalResolved(
            ApprovalResolvedEvent(resolution: ApprovalResolution(
                requestID: request.requestID,
                callID: invocation.callID,
                decision: .approved,
                resolvedAt: fixture.instant(7)
            ))
        )))
        state = try reduced(state, fixture.event(8, .toolScheduled(
            ToolScheduledEvent(callID: invocation.callID)
        )))
        state = try reduced(state, fixture.event(9, .toolStarted(
            ToolStartedEvent(callID: invocation.callID)
        )))
        state = try reduced(state, fixture.event(10, .toolApplied(
            ToolAppliedEvent(
                callID: invocation.callID,
                evidence: [ToolEvidence(kind: "post_hash", digest: "hash-after")]
            )
        )))
        state = try reduced(state, fixture.event(11, .toolCompleted(
            ToolCompletedEvent(result: result)
        )))
        state = try reduced(state, fixture.event(12, .runCompleted(RunCompletedEvent())))

        XCTAssertEqual(state.phase, .completed)
        XCTAssertEqual(state.tools.first?.status, .completed)
        XCTAssertEqual(state.tools.first?.result, result)
        XCTAssertEqual(state.approvals.first?.status, .approved)
        XCTAssertEqual(state.budget?.usage.toolInvocations, 1)
    }

    func testInterruptedRunIsTerminalAndCanOnlyContinueAsNewLineage() throws {
        let fixture = ReducerFixture()
        var state = try reduced(.initial, fixture.acceptanceEvent)
        state = try reduced(state, fixture.event(2, .runStarted(RunStartedEvent())))
        state = try reduced(state, fixture.event(3, .runInterrupted(
            RunInterruptedEvent(
                error: fixture.error(code: "process_crash", retryable: true),
                safeToResume: false
            )
        )))

        XCTAssertEqual(state.phase, .interrupted)
        assertReductionFailure(
            AgentReducer.reduce(
                state,
                event: fixture.event(4, .runStarted(RunStartedEvent(resumed: true)))
            ),
            equals: .alreadyTerminal(terminalEventID: fixture.eventID(3))
        )

        let replacement = ReducerFixture(retrying: fixture)
        let replacementState = try reduced(.initial, replacement.acceptanceEvent)
        XCTAssertEqual(replacementState.phase, .accepted)
        XCTAssertEqual(
            replacementState.context?.lineage.retryOfRunID,
            fixture.context.lineage.runID
        )
    }

    func testTenThousandSeededRetryCancellationAndCrashSequencesPreserveInvariants() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        for campaignIndex in 0..<10_000 {
            let seed = 0xC0DE_C0DE_F00D_FACE &+ UInt64(campaignIndex)
            var random = SplitMix64(seed: seed)
            let fixture = ReducerFixture()
            var events = [fixture.acceptanceEvent]

            func append(_ payload: AgentEventPayload) {
                events.append(fixture.event(UInt64(events.count + 1), payload))
            }

            if random.next() & 1 == 0 {
                append(.runQueued(RunQueuedEvent(reason: "seeded")))
            }

            let path = random.next() % 8
            let firstAttempt: AttemptID = tagged(100_000 + UInt64(campaignIndex) * 10)
            let secondAttempt: AttemptID = tagged(100_001 + UInt64(campaignIndex) * 10)

            switch path {
            case 0:
                append(.runStarted(RunStartedEvent()))
                append(.modelRequestStarted(ModelRequestStartedEvent(
                    attemptID: firstAttempt,
                    route: fixture.route
                )))
                append(.modelResponseCommitted(ModelResponseCommittedEvent(
                    attemptID: firstAttempt,
                    items: [fixture.assistantItem(
                        id: tagged(400_000 + UInt64(campaignIndex) * 10),
                        text: "seeded-success"
                    )],
                    usage: ModelUsage(inputTokens: 32, outputTokens: 8),
                    finishReason: .completed
                )))
                append(.runCompleted(RunCompletedEvent(summary: "done")))

            case 1:
                append(.runStarted(RunStartedEvent()))
                append(.modelRequestStarted(ModelRequestStartedEvent(
                    attemptID: firstAttempt,
                    route: fixture.route
                )))
                append(.modelRequestFailed(ModelRequestFailedEvent(
                    attemptID: firstAttempt,
                    error: fixture.error(code: "seeded_transport", retryable: true),
                    outputWasCommitted: false
                )))
                append(.providerRouteChanged(ProviderRouteChangedEvent(
                    from: fixture.route,
                    to: fixture.fallbackRoute,
                    reason: "seeded-fallback"
                )))
                append(.retryScheduled(RetryScheduledEvent(
                    failedAttemptID: firstAttempt,
                    nextAttemptID: secondAttempt,
                    reason: "seeded-retry"
                )))
                append(.modelRequestStarted(ModelRequestStartedEvent(
                    attemptID: secondAttempt,
                    route: fixture.fallbackRoute
                )))
                append(.modelResponseCommitted(ModelResponseCommittedEvent(
                    attemptID: secondAttempt,
                    items: [fixture.assistantItem(
                        id: tagged(400_001 + UInt64(campaignIndex) * 10),
                        text: "seeded-recovery"
                    )],
                    usage: ModelUsage(inputTokens: 48, outputTokens: 12),
                    finishReason: .completed
                )))
                append(.runCompleted(RunCompletedEvent(summary: "recovered")))

            case 2:
                append(.cancellationRequested(CancellationRequestedEvent(
                    reason: .userRequested,
                    propagateToDescendants: random.next() & 1 == 0
                )))
                append(.runCancelled(RunCancelledEvent(reason: .userRequested)))

            case 3:
                append(.runStarted(RunStartedEvent()))
                append(.modelRequestStarted(ModelRequestStartedEvent(
                    attemptID: firstAttempt,
                    route: fixture.route
                )))
                append(.cancellationRequested(CancellationRequestedEvent(
                    reason: .userRequested,
                    propagateToDescendants: true
                )))
                append(.runCancelled(RunCancelledEvent(reason: .userRequested)))

            case 4:
                append(.runStarted(RunStartedEvent()))
                append(.modelRequestStarted(ModelRequestStartedEvent(
                    attemptID: firstAttempt,
                    route: fixture.route
                )))
                append(.runInterrupted(RunInterruptedEvent(
                    error: fixture.error(code: "seeded_process_loss", retryable: true),
                    safeToResume: false
                )))

            case 5:
                append(.runStarted(RunStartedEvent()))
                append(.modelRequestStarted(ModelRequestStartedEvent(
                    attemptID: firstAttempt,
                    route: fixture.route
                )))
                append(.modelRequestFailed(ModelRequestFailedEvent(
                    attemptID: firstAttempt,
                    error: fixture.error(code: "seeded_partial"),
                    outputWasCommitted: true
                )))
                append(.runFailed(RunFailedEvent(
                    error: fixture.error(code: "seeded_failed_after_commit")
                )))

            case 6:
                append(.runStarted(RunStartedEvent()))
                append(.contextPrepared(ContextPreparedEvent(
                    itemIDs: [fixture.userItem.id],
                    estimatedTokens: 16,
                    contextDigest: "seeded-context"
                )))
                append(.planUpdated(PlanUpdatedEvent(revision: 1, summary: "seeded-plan")))
                let roundCount = Int(random.next() % 3) + 1
                for round in 0..<roundCount {
                    let attempt: AttemptID = tagged(
                        200_000 + UInt64(campaignIndex) * 10 + UInt64(round)
                    )
                    append(.modelRequestStarted(ModelRequestStartedEvent(
                        attemptID: attempt,
                        route: fixture.route
                    )))
                    append(.modelResponseCommitted(ModelResponseCommittedEvent(
                        attemptID: attempt,
                        items: [fixture.assistantItem(
                            id: tagged(
                                500_000 + UInt64(campaignIndex) * 10 + UInt64(round)
                            ),
                            text: "seeded-round-\(round)"
                        )],
                        usage: ModelUsage(inputTokens: 24, outputTokens: 6),
                        finishReason: .completed
                    )))
                }
                append(.runCompleted(RunCompletedEvent(summary: "multi-round")))

            default:
                append(.runFailed(RunFailedEvent(
                    error: fixture.error(code: "seeded_early_failure", retryable: true)
                )))
            }

            let crashBoundary = Int(random.next() % UInt64(events.count)) + 1
            var state = AgentRunState.initial

            for (eventIndex, event) in events.enumerated() {
                if random.next() % 3 == 0 {
                    let invalid = fixture.event(
                        event.header.sequence.rawValue + 1,
                        event.payload
                    )
                    let before = state
                    guard case .failure = AgentReducer.reduce(state, event: invalid) else {
                        throw SeededReducerPropertyFailure(
                            seed: seed,
                            detail: "sequence gap committed at event \(eventIndex)"
                        )
                    }
                    try requireSeededProperty(
                        state == before,
                        seed: seed,
                        "rejected sequence gap mutated state"
                    )
                }

                state = try reduceSeeded(state, event: event, seed: seed)

                let beforeDuplicate = state
                guard case .failure = AgentReducer.reduce(state, event: event) else {
                    throw SeededReducerPropertyFailure(
                        seed: seed,
                        detail: "duplicate event committed at event \(eventIndex)"
                    )
                }
                try requireSeededProperty(
                    state == beforeDuplicate,
                    seed: seed,
                    "rejected duplicate mutated state"
                )

                if eventIndex + 1 == crashBoundary {
                    let persistedEvents = try encoder.encode(Array(events.prefix(crashBoundary)))
                    let restoredEvents = try decoder.decode([AgentEvent].self, from: persistedEvents)
                    let replayedPrefix = try restoredEvents.reduce(AgentRunState.initial) {
                        try reduceSeeded($0, event: $1, seed: seed)
                    }
                    try requireSeededProperty(
                        replayedPrefix == state,
                        seed: seed,
                        "event replay diverged at crash boundary \(crashBoundary)"
                    )

                    state = try decoder.decode(
                        AgentRunState.self,
                        from: encoder.encode(state)
                    )
                    try requireSeededProperty(
                        state == replayedPrefix,
                        seed: seed,
                        "state snapshot diverged at crash boundary \(crashBoundary)"
                    )
                }
            }

            let replayed = try events.reduce(AgentRunState.initial) {
                try reduceSeeded($0, event: $1, seed: seed)
            }
            try requireSeededProperty(replayed == state, seed: seed, "full replay diverged")
            try requireSeededProperty(state.phase.isTerminal, seed: seed, "run did not settle")
            try requireSeededProperty(
                state.lastSequence?.rawValue == UInt64(events.count),
                seed: seed,
                "last sequence was not contiguous"
            )
            try requireSeededProperty(
                state.appliedEventIDs.count == Set(state.appliedEventIDs).count,
                seed: seed,
                "applied event IDs were not unique"
            )
            try requireSeededProperty(
                state.terminalEventID == state.lastEventID,
                seed: seed,
                "terminal event was not the last committed event"
            )
            try requireSeededProperty(
                state.activeAttemptID == nil && state.scheduledAttemptID == nil,
                seed: seed,
                "terminal run retained provider work"
            )
            try requireSeededProperty(
                state.budget?.exceededDimensions.isEmpty == true,
                seed: seed,
                "budget exceeded without rejection"
            )
        }
    }
}

private struct ReducerFixture {
    let context: AgentRunContext
    let userItem: ModelItem
    let correlationID: CorrelationID
    let route = ModelRoute(provider: "openai", model: "model-a", adapter: "responses")
    let fallbackRoute = ModelRoute(provider: "other", model: "model-b", adapter: "native")

    init(schemaVersion: AgentSchemaVersion = .v1) {
        let runID: RunID = tagged(1)
        let acceptedAt = AgentInstant(rawValue: 1_750_000_000_000)
        context = AgentRunContext(
            schemaVersion: schemaVersion,
            lineage: .root(runID),
            conversationID: tagged(2),
            projectID: tagged(3),
            workspaceID: tagged(4),
            executionNodeID: tagged(5),
            engineVersion: schemaVersion >= .v1_1
                ? .agentHarnessV2
                : .agentHarnessV1,
            acceptedAt: acceptedAt,
            features: AgentFeatureSet(["pure-reducer"]),
            cancellation: CancellationLineage(scopeID: tagged(6)),
            initialBudget: AgentBudget(limits: .standard)
        )
        userItem = ModelItem(
            id: tagged(7),
            createdAt: acceptedAt,
            payload: .message(ModelMessage(role: .user, content: [.text("Do the work")]))
        )
        correlationID = tagged(8)
    }

    init(retrying previous: Self) {
        let runID: RunID = tagged(previous.context.lineage.generation == 0 ? 100 : 101)
        let acceptedAt = AgentInstant(rawValue: previous.context.acceptedAt.rawValue + 10_000)
        context = AgentRunContext(
            schemaVersion: previous.context.schemaVersion,
            lineage: .retry(runID, of: previous.context.lineage),
            conversationID: previous.context.conversationID,
            projectID: previous.context.projectID,
            workspaceID: previous.context.workspaceID,
            executionNodeID: previous.context.executionNodeID,
            engineVersion: previous.context.engineVersion,
            acceptedAt: acceptedAt,
            features: previous.context.features,
            cancellation: CancellationLineage(
                scopeID: tagged(previous.context.lineage.generation == 0 ? 106 : 107),
                parentScopeID: previous.context.cancellation.scopeID
            ),
            initialBudget: AgentBudget(limits: .standard)
        )
        userItem = ModelItem(
            id: tagged(previous.context.lineage.generation == 0 ? 107 : 108),
            createdAt: acceptedAt,
            payload: .message(ModelMessage(role: .user, content: [.text("Retry safely")]))
        )
        correlationID = tagged(previous.context.lineage.generation == 0 ? 108 : 109)
    }

    var acceptanceEvent: AgentEvent {
        event(1, .runAccepted(RunAcceptedEvent(context: context, initialItems: [userItem])))
    }

    func event(_ sequence: UInt64, _ payload: AgentEventPayload) -> AgentEvent {
        AgentEvent(
            header: AgentEventHeader(
                eventID: eventID(sequence),
                schemaVersion: context.schemaVersion,
                context: context,
                sequence: EventSequence(rawValue: sequence),
                timestamp: instant(sequence),
                causationID: tagged(9),
                correlationID: correlationID
            ),
            payload: payload
        )
    }

    func eventID(_ sequence: UInt64) -> EventID {
        tagged(1_000 + sequence + UInt64(context.lineage.generation) * 100)
    }

    func instant(_ sequence: UInt64) -> AgentInstant {
        if sequence == 1 { return context.acceptedAt }
        return AgentInstant(rawValue: context.acceptedAt.rawValue + Int64(sequence))
    }

    func assistantItem(id: ModelItemID, text: String) -> ModelItem {
        ModelItem(
            id: id,
            createdAt: instant(5),
            payload: .message(ModelMessage(role: .assistant, content: [.text(text)]))
        )
    }

    func error(code: String, retryable: Bool = false) -> AgentErrorInfo {
        AgentErrorInfo(
            category: .provider,
            code: code,
            publicMessage: "Operation failed",
            retryable: retryable
        )
    }

    func invocation(
        attemptID: AttemptID,
        providerCallID: String? = nil
    ) -> ToolInvocation {
        ToolInvocation(
            callID: tagged(62),
            providerCallID: providerCallID,
            modelAttemptID: attemptID,
            tool: ToolIdentity(name: "workspace.write", version: "1"),
            arguments: .object([
                "path": .string("Sources/File.swift"),
                "replace": .bool(true),
            ]),
            canonicalArgumentDigest: "args-hash",
            idempotencyKey: "operation-1",
            effectClass: .scopedReversibleWrite,
            locality: .either
        )
    }

    func providerAttempt(
        attemptID: AttemptID,
        ordinal: UInt32,
        recoverySeed: UInt64,
        requestID: String = "provider-request",
        providerAttemptID: String? = nil
    ) throws -> ProviderAttemptJournalMetadata {
        .recordedV1_1(
            requestDigest: try AgentCanonicalSHA256Digest(
                "sha256:" + String(repeating: "ab", count: 32)
            ),
            scope: try ProviderAttemptScopeReference(
                requestID: requestID,
                attemptID: providerAttemptID ?? "provider-\(attemptID)"
            ),
            ordinal: ordinal,
            recoverySeed: recoverySeed
        )
    }

    func effectReferences(seed: String) throws -> EffectReferences {
        func digest(_ pair: String) throws -> AgentCanonicalSHA256Digest {
            try AgentCanonicalSHA256Digest(
                "sha256:" + String(repeating: pair, count: 32)
            )
        }
        let key = ToolEffectKeyReference(effectKeySHA256: try digest(seed))
        return EffectReferences(
            key: key,
            receipt: ToolEffectReceiptReference(
                effectKeySHA256: key.effectKeySHA256,
                applicationSHA256: try digest("aa"),
                evidenceSHA256: try digest("bb"),
                finalRecordSHA256: try digest("cc")
            )
        )
    }

    func v11StateAwaitingApproval(
        attemptID: AttemptID,
        invocation: ToolInvocation,
        request: ApprovalRequest
    ) throws -> AgentRunState {
        var state = try reduced(.initial, acceptanceEvent)
        state = try reduced(state, event(2, .runStarted(RunStartedEvent())))
        state = try reduced(state, event(3, .modelRequestStarted(
            ModelRequestStartedEvent(
                attemptID: attemptID,
                route: route,
                providerAttempt: try providerAttempt(
                    attemptID: attemptID,
                    ordinal: 0,
                    recoverySeed: 0xC0DE
                )
            )
        )))
        state = try reduced(state, event(4, .modelResponseCommitted(
            ModelResponseCommittedEvent(
                attemptID: attemptID,
                items: [ModelItem(
                    id: tagged(600),
                    createdAt: instant(4),
                    payload: .toolInvocation(invocation)
                )],
                usage: ModelUsage(inputTokens: 12, outputTokens: 4),
                finishReason: .toolCalls
            )
        )))
        state = try reduced(state, event(5, .toolProposed(
            ToolProposedEvent(invocation: invocation)
        )))
        return try reduced(state, event(6, .approvalRequested(
            ApprovalRequestedEvent(request: request)
        )))
    }

    func approval(for invocation: ToolInvocation) -> ApprovalRequest {
        ApprovalRequest(
            requestID: tagged(63),
            binding: ApprovalBinding(
                runID: context.lineage.runID,
                callID: invocation.callID,
                tool: invocation.tool,
                canonicalArgumentDigest: invocation.canonicalArgumentDigest,
                workspaceID: context.workspaceID,
                previewDigest: "preview-hash",
                workspaceRevision: "revision-1"
            ),
            summary: "Write one file",
            requestedAt: instant(6)
        )
    }
}

private struct EffectReferences {
    let key: ToolEffectKeyReference
    let receipt: ToolEffectReceiptReference
}

private func reduced(
    _ state: AgentRunState,
    _ event: AgentEvent,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> AgentRunState {
    switch AgentReducer.reduce(state, event: event) {
    case let .success(next):
        return next
    case let .failure(failure):
        XCTFail("Unexpected reduction failure: \(failure)", file: file, line: line)
        throw failure
    }
}

private func assertReductionFailure(
    _ result: Result<AgentRunState, AgentInvariantFailure>,
    equals expected: AgentInvariantFailure,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch result {
    case .success:
        XCTFail("Reduction unexpectedly succeeded", file: file, line: line)
    case let .failure(actual):
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

private func tagged<Tag: AgentIdentifierTag>(_ value: UInt64) -> AgentIdentifier<Tag> {
    let suffix = String(format: "%012llX", value)
    return AgentIdentifier(rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!)
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private struct SeededReducerPropertyFailure: Error, CustomStringConvertible {
    let seed: UInt64
    let detail: String

    var description: String {
        "Reducer property failure at seed \(seed): \(detail)"
    }
}

private func reduceSeeded(
    _ state: AgentRunState,
    event: AgentEvent,
    seed: UInt64
) throws -> AgentRunState {
    switch AgentReducer.reduce(state, event: event) {
    case let .success(next):
        return next
    case let .failure(failure):
        throw SeededReducerPropertyFailure(
            seed: seed,
            detail: "legal event \(event.payload.kind) was rejected: \(failure)"
        )
    }
}

private func requireSeededProperty(
    _ condition: @autoclosure () -> Bool,
    seed: UInt64,
    _ detail: String
) throws {
    guard condition() else {
        throw SeededReducerPropertyFailure(seed: seed, detail: detail)
    }
}

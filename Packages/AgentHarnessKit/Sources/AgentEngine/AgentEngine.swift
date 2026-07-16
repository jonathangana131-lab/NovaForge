import AgentDomain
import AgentPolicy
import AgentProviders
import AgentStore
import AgentTools
import Foundation

/// Hosted V2 run engine. One instance owns at most one run, and all semantic
/// writes pass through its reducer-checked append lane.
public actor AgentEngine {
    fileprivate struct ProviderAttemptPlan: Sendable {
        let attemptID: AttemptID
        let scope: ProviderAttemptScope
        let route: ProviderRoute
        let ordinal: UInt32
        let recoverySeed: UInt64
    }

    private struct ProviderAttemptOutput: Sendable {
        let items: [ModelItem]
        let usage: ModelUsage
        let finishReason: ModelFinishReason
    }

    private enum AppendOutcome: Sendable {
        case newlyCommitted(AgentJournalCommit)
        case verifiedAfterThrownCommit(StoredAgentEvent)
    }

    private let journal: any AgentEventJournal
    private let providerGateway: ModelGateway
    private let toolRegistry: ToolRegistry
    private let contextPreparer: any AgentContextPreparing
    private let readOnlyExecutor: any AgentReadOnlyToolExecuting
    private let mutationExecutor: any AgentMutationPolicyExecuting
    private let approvalResolver: any AgentApprovalResolving
    private let clock: any AgentEngineClock
    private let identities: any AgentEngineIdentitySource
    private let runIndex: any AgentEngineRunIndexing
    private let cancellationPropagator: any AgentCancellationPropagating
    private let liveOutputSink: any AgentLiveOutputSink
    private let configuration: AgentEngineConfiguration
    private let mutationPreparationSealer: AgentMutationPreparationSealer

    private var state: AgentRunState?
    private var fence: AgentEngineOwnerFence?
    private var writerID: AgentEventWriterID?
    private var correlationID: CorrelationID?
    private var lastCausationID: CausationID?
    private var driver: Task<AgentRunState, any Error>?
    private var cancellationIntent: CancelCommand?
    private var recoveredScheduledRoute: ModelRoute?
    private var recoveredRetryDelayMilliseconds: UInt64?
    private var isRecoveryOwner = false

    // Actor reentrancy can otherwise interleave two appends while the first is
    // awaiting storage. This hand-off keeps sequence projection single-file.
    private var appendLaneBusy = false
    private var appendLaneWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        journal: any AgentEventJournal,
        providerGateway: ModelGateway,
        toolRegistry: ToolRegistry,
        contextPreparer: any AgentContextPreparing,
        readOnlyExecutor: any AgentReadOnlyToolExecuting,
        mutationExecutor: any AgentMutationPolicyExecuting,
        approvalResolver: any AgentApprovalResolving,
        clock: any AgentEngineClock = SystemAgentEngineClock(),
        identities: any AgentEngineIdentitySource = SystemAgentEngineIdentitySource(),
        runIndex: any AgentEngineRunIndexing = InMemoryAgentEngineRunIndex(),
        cancellationPropagator: any AgentCancellationPropagating =
            NoopAgentCancellationPropagator(),
        liveOutputSink: any AgentLiveOutputSink = NoopAgentLiveOutputSink(),
        configuration: AgentEngineConfiguration = AgentEngineConfiguration()
    ) {
        self.journal = journal
        self.providerGateway = providerGateway
        self.toolRegistry = toolRegistry
        self.contextPreparer = contextPreparer
        self.readOnlyExecutor = readOnlyExecutor
        self.mutationExecutor = mutationExecutor
        self.approvalResolver = approvalResolver
        self.clock = clock
        self.identities = identities
        self.runIndex = runIndex
        self.cancellationPropagator = cancellationPropagator
        self.liveOutputSink = liveOutputSink
        self.configuration = configuration
        mutationPreparationSealer = AgentMutationPreparationSealer(seal: UUID())
    }

    /// Atomically accepts a new run, verifies that exact acceptance is durable,
    /// then starts hosted work. No provider/tool authority is called first.
    public func start(_ command: AgentCommand) async throws -> AgentEngineRunHandle {
        guard state == nil, fence == nil else {
            throw AgentEngineError.engineAlreadyOwnsRun(
                state?.context?.lineage.runID ?? command.header.runID
            )
        }
        guard case let .send(send) = command.payload,
              command.header.runID == send.context.lineage.runID,
              command.header.schemaVersion == send.context.schemaVersion,
              send.context.schemaVersion == .current,
              send.context.schemaVersion >= .v1_1
        else {
            if case let .send(send) = command.payload,
               send.context.schemaVersion != .current {
                throw AgentEngineError.unsupportedSchema(send.context.schemaVersion)
            }
            throw AgentEngineError.invalidCommand
        }

        let ownerID = try await identities.nextUUID()
        let claimed = try await runIndex.claim(
            runID: send.context.lineage.runID,
            ownerID: ownerID,
            mode: .newRun
        )
        fence = claimed
        isRecoveryOwner = false
        writerID = AgentEventWriterID(runID: send.context.lineage.runID)
        correlationID = command.header.correlationID
        lastCausationID = CausationID(rawValue: command.header.commandID.rawValue)

        do {
            let eventID = EventID(rawValue: try await identities.nextUUID())
            let event = AgentEvent(
                header: AgentEventHeader(
                    eventID: eventID,
                    schemaVersion: send.context.schemaVersion,
                    context: send.context,
                    sequence: .first,
                    timestamp: send.context.acceptedAt,
                    causationID: command.header.causationID,
                    correlationID: command.header.correlationID
                ),
                payload: .runAccepted(RunAcceptedEvent(
                    context: send.context,
                    acceptedEngineVersion: send.context.engineVersion,
                    initialItems: [send.userItem]
                ))
            )
            let envelope = AgentEventEnvelope(
                writerID: AgentEventWriterID(runID: send.context.lineage.runID),
                writerSequence: .first,
                idempotencyKey: "accept:\(command.header.commandID.description)",
                event: event
            )
            let acceptance = AgentRunAcceptance(
                metadata: AgentRunMetadataRecord(
                    context: send.context,
                    acceptedEngineVersion: send.context.engineVersion,
                    writerID: envelope.writerID,
                    acceptanceCommandID: command.header.commandID,
                    acceptanceEventID: eventID
                ),
                envelope: envelope
            )
            try await persistFreshAcceptance(acceptance, fence: claimed)
            guard case let .success(accepted) = AgentReducer.reduce(.initial, event: event) else {
                throw AgentEngineError.reducerRejected(.internalReducerError)
            }
            state = accepted
            lastCausationID = CausationID(rawValue: eventID.rawValue)
            try await runIndex.validate(claimed)
        } catch {
            state = nil
            fence = nil
            writerID = nil
            correlationID = nil
            lastCausationID = nil
            await runIndex.abandon(claimed)
            throw error
        }

        let handle = AgentEngineRunHandle(
            runID: send.context.lineage.runID,
            ownerFence: claimed
        )
        launchDriver(for: handle)
        return handle
    }

    /// Claims an accepted nonterminal journal after host recovery election.
    /// Ambiguous provider/mutation boundaries are fenced and never replayed.
    public func recover(runID: RunID) async throws -> AgentEngineRunHandle {
        guard state == nil, fence == nil else {
            throw AgentEngineError.engineAlreadyOwnsRun(
                state?.context?.lineage.runID ?? runID
            )
        }
        guard let recovered = try await AgentJournalRecovery(store: journal).recover(runID)
        else { throw AgentStoreError.runNotFound(runID) }
        guard recovered.state.schemaVersion == .current,
              recovered.state.schemaVersion >= .v1_1
        else { throw AgentEngineError.unsupportedSchema(recovered.state.schemaVersion) }

        let records = try await journal.events(for: runID, after: nil)
        guard let first = records.first, let last = records.last else {
            throw AgentEngineError.persistence("recovery_empty_ledger")
        }
        let ownerID = try await identities.nextUUID()
        let claimed = try await runIndex.claim(
            runID: runID,
            ownerID: ownerID,
            mode: .recovery
        )
        state = recovered.state
        fence = claimed
        isRecoveryOwner = true
        writerID = recovered.metadata.writerID
        correlationID = first.event.header.correlationID
        lastCausationID = CausationID(rawValue: last.event.header.eventID.rawValue)
        recoveredScheduledRoute = records.reversed().compactMap { record -> ModelRoute? in
            guard case let .providerRouteChanged(change) = record.event.payload else {
                return nil
            }
            return change.to
        }.first
        recoveredRetryDelayMilliseconds = records.reversed().compactMap { record -> UInt64? in
            guard case let .retryScheduled(retry) = record.event.payload else {
                return nil
            }
            return Self.retryDelay(from: retry.reason)
        }.first

        let handle = AgentEngineRunHandle(runID: runID, ownerFence: claimed)
        if recovered.state.phase.isTerminal {
            if let terminalEventID = recovered.state.terminalEventID {
                try await runIndex.settle(AgentEngineTerminalRecord(
                    runID: runID,
                    fence: claimed,
                    phase: recovered.state.phase,
                    terminalEventID: terminalEventID
                ))
            }
        } else {
            launchDriver(for: handle)
        }
        return handle
    }

    public func execute(_ command: AgentCommand) async throws -> AgentRunState {
        let handle = try await start(command)
        return try await wait(for: handle)
    }

    public func wait(for handle: AgentEngineRunHandle) async throws -> AgentRunState {
        try requireCurrent(handle)
        if let driver {
            return try await driver.value
        }
        guard let state else { throw AgentEngineError.noOwnedRun }
        return state
    }

    public func snapshot(for handle: AgentEngineRunHandle) throws -> AgentRunState {
        try requireCurrent(handle)
        guard let state else { throw AgentEngineError.noOwnedRun }
        return state
    }

    /// Cancels the live driver, waits for provider/tool cancellation to drain,
    /// durably records propagation intent, then settles the run once.
    public func cancel(
        _ command: CancelCommand,
        runID: RunID
    ) async throws -> AgentRunState {
        guard let context = state?.context else { throw AgentEngineError.noOwnedRun }
        guard context.lineage.runID == runID else {
            throw AgentEngineError.runMismatch(
                expected: context.lineage.runID,
                actual: runID
            )
        }
        if let state, state.phase.isTerminal { return state }
        cancellationIntent = command
        if let driver {
            driver.cancel()
            do { return try await driver.value }
            catch is CancellationError {
                return try await settleCancellation(command)
            }
        }
        return try await settleCancellation(command)
    }

    /// Delivers a command to the request-bound approval broker while the run
    /// worker is suspended in `resolveApproval`. The worker—not this method—
    /// appends the authoritative returned resolution.
    public func deliverApprovalDecision(
        _ command: ApprovalDecisionCommand,
        runID: RunID
    ) async throws {
        guard let context = state?.context else { throw AgentEngineError.noOwnedRun }
        guard context.lineage.runID == runID else {
            throw AgentEngineError.runMismatch(
                expected: context.lineage.runID,
                actual: runID
            )
        }
        guard let pending = state?.approvals.first(where: {
            $0.status == .pending
                && $0.request.requestID == command.requestID
                && $0.request.binding.callID == command.callID
        }) else {
            throw AgentEngineError.approvalBindingMismatch(command.requestID)
        }
        try await approvalResolver.deliverApprovalDecision(
            command,
            for: pending.request
        )
    }

    // MARK: Driver

    private func launchDriver(for handle: AgentEngineRunHandle) {
        driver = Task { [weak self] in
            guard let self else { throw AgentEngineError.noOwnedRun }
            return try await self.drive(handle)
        }
    }

    private func drive(_ handle: AgentEngineRunHandle) async throws -> AgentRunState {
        do {
            let result = try await driveStateMachine(handle)
            driver = nil
            return result
        } catch is CancellationError {
            let command = cancellationIntent ?? CancelCommand(reason: .shutdown)
            let result = try await settleCancellation(command)
            driver = nil
            return result
        } catch AgentEngineError.staleOwner {
            driver = nil
            throw AgentEngineError.staleOwner
        } catch let error as AgentEngineError {
            let result: AgentRunState
            switch error {
            case .unsafeRecovery, .mutationReceiptMismatch:
                result = try await interruptRun(
                    code: "unsafe_recovery_boundary",
                    message: "The run stopped at an ambiguous effect boundary.",
                    safeToResume: false
                )
            case .persistence:
                driver = nil
                throw error
            case .cancelled:
                result = try await settleCancellation(
                    cancellationIntent ?? CancelCommand(reason: .shutdown)
                )
            default:
                result = try await failRun(Self.errorInfo(for: error))
            }
            driver = nil
            return result
        } catch {
            let result = try await failRun(AgentErrorInfo(
                category: .unknown,
                code: "engine_unexpected_failure",
                publicMessage: "The agent run could not continue.",
                retryable: false
            ))
            driver = nil
            return result
        }
    }

    private func driveStateMachine(
        _ handle: AgentEngineRunHandle
    ) async throws -> AgentRunState {
        try requireCurrent(handle)
        try await requireFence(handle.ownerFence)
        guard var current = state else { throw AgentEngineError.noOwnedRun }

        if current.phase == .accepted || current.phase == .queued {
            _ = try await append(.runStarted(RunStartedEvent(
                resumed: isRecoveryOwner
                    || current.phase != .accepted
                    || current.lastSequence != .first
            )))
        }

        while true {
            try Task.checkCancellation()
            try await requireFence(handle.ownerFence)
            guard let snapshot = state else { throw AgentEngineError.noOwnedRun }
            current = snapshot
            if current.phase.isTerminal { return current }
            guard current.phase == .running else {
                throw AgentEngineError.unsafeRecovery("unexpected_phase_\(current.phase.rawValue)")
            }

            // A persisted provider dispatch without a semantic response is
            // ambiguous after relaunch. Never issue a second wire request.
            if current.activeAttemptID != nil {
                return try await interruptRun(
                    code: "provider_attempt_ambiguous_after_recovery",
                    message: "A provider attempt needs reconciliation.",
                    safeToResume: false
                )
            }

            if let invocation = nextUnproposedInvocation(in: current) {
                _ = try await append(.toolProposed(ToolProposedEvent(
                    invocation: invocation
                )))
                try await driveTool(callID: invocation.callID)
                continue
            }
            if let tool = current.tools.first(where: { !$0.status.isSettled }) {
                try await driveTool(callID: tool.invocation.callID)
                continue
            }

            guard let lastAttempt = current.modelAttempts.last else {
                _ = try await performProviderTurn()
                continue
            }
            switch lastAttempt.status {
            case .responseCommitted:
                switch lastAttempt.finishReason {
                case .completed:
                    return try await completeRun()
                case .toolCalls:
                    let calls = current.modelItems.compactMap { item -> ToolInvocation? in
                        guard case let .toolInvocation(invocation) = item.payload,
                              invocation.modelAttemptID == lastAttempt.attemptID
                        else { return nil }
                        return invocation
                    }
                    guard !calls.isEmpty,
                          calls.allSatisfy({ call in
                              current.tools.first(where: {
                                  $0.invocation.callID == call.callID
                              })?.status.isSettled == true
                          })
                    else {
                        throw AgentEngineError.providerContract(
                            "provider_tool_finish_without_settled_calls"
                        )
                    }
                    _ = try await performProviderTurn()
                case .length, .contentFilter, .cancelled, .unknown, .none:
                    throw AgentEngineError.providerFailed(AgentErrorInfo(
                        category: lastAttempt.finishReason == .cancelled
                            ? .cancelled : .provider,
                        code: "provider_noncompletion_\(lastAttempt.finishReason?.rawValue ?? "missing")",
                        publicMessage: "The model did not complete the response.",
                        retryable: lastAttempt.finishReason == .length
                    ))
                }
            case .failedBeforeCommit:
                _ = try await performProviderTurn()
            case .retryScheduled:
                _ = try await performProviderTurn()
            case .active:
                throw AgentEngineError.unsafeRecovery("active_provider_attempt")
            case .failedAfterCommit:
                throw AgentEngineError.unsafeRecovery("provider_failed_after_commit")
            }
        }
    }

    // MARK: Provider loop

    @discardableResult
    private func performProviderTurn() async throws -> ModelFinishReason {
        guard let state, let context = state.context else {
            throw AgentEngineError.noOwnedRun
        }
        let committedRounds = state.modelAttempts.filter {
            $0.status == .responseCommitted
        }.count
        guard committedRounds < Int(configuration.maximumModelRounds) else {
            throw AgentEngineError.providerContract("maximum_model_rounds_exceeded")
        }

        let prepared = try await contextPreparer.prepareProviderTurn(
            state: state,
            tools: toolRegistry.descriptors
        )
        try Task.checkCancellation()
        try validate(prepared: prepared, state: state)
        _ = try await append(.contextPrepared(ContextPreparedEvent(
            itemIDs: prepared.itemIDs,
            estimatedTokens: prepared.estimatedTokens,
            contextDigest: prepared.contextDigest.rawValue
        )))

        let candidates = try await providerGateway.negotiateRoutes(
            preferredAdapterIDs: prepared.preferredAdapterIDs,
            requirements: prepared.request.capabilityRequirements
        )
        guard !candidates.isEmpty else { throw AgentEngineError.noProviderRoute }

        var currentRoute = routeForScheduledAttempt(in: candidates)
            ?? candidates[0]
        var attemptOnRoute = consecutiveAttemptCount(on: currentRoute)
        if attemptOnRoute == 0 { attemptOnRoute = 1 }
        var fallbacksUsed = fallbackCountInCurrentTurn()
        var nextAttemptID = self.state?.scheduledAttemptID
        if let delay = recoveredRetryDelayMilliseconds, nextAttemptID != nil {
            try await clock.sleep(milliseconds: delay)
        }
        recoveredRetryDelayMilliseconds = nil
        recoveredScheduledRoute = nil

        while true {
            try Task.checkCancellation()
            let attemptID: AttemptID
            if let scheduled = nextAttemptID {
                attemptID = scheduled
            } else {
                attemptID = AttemptID(
                    rawValue: try await identities.nextUUID()
                )
            }
            nextAttemptID = nil
            let ordinal = try nextAttemptOrdinal()
            let seed = try await identities.recoverySeed(
                runID: context.lineage.runID,
                attemptOrdinal: ordinal
            )
            let scope = ProviderAttemptScope(
                requestID: prepared.request.requestID,
                attemptID: ProviderAttemptID(rawValue: attemptID.description)
            )
            let plan = ProviderAttemptPlan(
                attemptID: attemptID,
                scope: scope,
                route: currentRoute,
                ordinal: ordinal,
                recoverySeed: seed
            )

            do {
                let output = try await executeProviderAttempt(
                    plan: plan,
                    prepared: prepared
                )
                _ = try await append(.modelResponseCommitted(
                    ModelResponseCommittedEvent(
                        attemptID: attemptID,
                        items: output.items,
                        usage: output.usage,
                        finishReason: output.finishReason
                    )
                ))
                return output.finishReason
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as ProviderFailure {
                let info = Self.errorInfo(for: failure)
                guard self.state?.activeAttemptID == attemptID else {
                    throw AgentEngineError.providerFailed(info)
                }
                _ = try await append(.modelRequestFailed(
                    ModelRequestFailedEvent(
                        attemptID: attemptID,
                        error: info,
                        outputWasCommitted: false
                    )
                ))
                let remaining = candidates.filter { candidate in
                    candidate.adapterID != currentRoute.adapterID
                }
                let decision = ProviderRecoveryPlanner.decide(
                    context: ProviderRecoveryContext(
                        currentRoute: currentRoute,
                        fallbackRoutes: remaining,
                        requiredCapabilities: prepared.request.requiredCapabilities,
                        attemptOnCurrentRoute: attemptOnRoute,
                        fallbacksAlreadyUsed: fallbacksUsed,
                        failure: failure,
                        outputCommitState: .none,
                        toolDispatchState: .none,
                        deterministicSeed: seed
                    ),
                    policy: configuration.recoveryPolicy
                )
                switch decision {
                case let .retrySameRoute(delay):
                    let replacement = AttemptID(
                        rawValue: try await identities.nextUUID()
                    )
                    _ = try await append(.retryScheduled(RetryScheduledEvent(
                        failedAttemptID: attemptID,
                        nextAttemptID: replacement,
                        reason: Self.retryReason(kind: "same_route", delay: delay)
                    )))
                    try await clock.sleep(milliseconds: delay)
                    nextAttemptID = replacement
                    attemptOnRoute &+= 1
                case let .fallback(route, delay):
                    _ = try await append(.providerRouteChanged(
                        ProviderRouteChangedEvent(
                            from: Self.domainRoute(currentRoute),
                            to: Self.domainRoute(route),
                            reason: Self.retryReason(kind: "fallback", delay: delay)
                        )
                    ))
                    let replacement = AttemptID(
                        rawValue: try await identities.nextUUID()
                    )
                    _ = try await append(.retryScheduled(RetryScheduledEvent(
                        failedAttemptID: attemptID,
                        nextAttemptID: replacement,
                        reason: Self.retryReason(kind: "fallback", delay: delay)
                    )))
                    try await clock.sleep(milliseconds: delay)
                    currentRoute = route
                    nextAttemptID = replacement
                    attemptOnRoute = 1
                    fallbacksUsed &+= 1
                case .stop:
                    throw AgentEngineError.providerFailed(info)
                }
            } catch let error as AgentEngineError {
                throw error
            } catch {
                // Barrier/store/adapter contract failures are never retried as
                // provider failures. In particular, no transport runs after a
                // failed or idempotently replayed dispatch barrier.
                throw AgentEngineError.providerContract(
                    Self.stableErrorCode(error, fallback: "provider_attempt_contract_failed")
                )
            }
        }
    }

    private func executeProviderAttempt(
        plan: ProviderAttemptPlan,
        prepared: AgentPreparedProviderTurn
    ) async throws -> ProviderAttemptOutput {
        guard let fence,
              let runID = state?.context?.lineage.runID
        else { throw AgentEngineError.noOwnedRun }
        let barrier = EngineProviderDispatchBarrier(
            engine: self,
            fence: fence,
            plan: plan
        )
        let stream = await providerGateway.streamAttempt(
            ProviderSingleAttemptInvocation(
                request: prepared.request,
                adapterID: plan.route.adapterID,
                scope: plan.scope,
                barrier: barrier
            )
        )
        var events: [ProviderAttemptEvent] = []
        var expectedSequence: UInt64 = 0
        for try await event in stream {
            try Task.checkCancellation()
            let eventSequence = expectedSequence
            guard event.scope == plan.scope,
                  event.sequence == eventSequence
            else {
                throw AgentEngineError.providerContract(
                    "provider_attempt_event_scope_or_sequence_mismatch"
                )
            }
            guard expectedSequence < UInt64.max else {
                throw AgentEngineError.providerContract(
                    "provider_attempt_sequence_exhausted"
                )
            }
            expectedSequence += 1
            events.append(event)
            if case let .textDelta(delta) = event.event,
               !delta.text.isEmpty {
                await liveOutputSink.receive(AgentLiveTextDelta(
                    runID: runID,
                    attemptID: plan.attemptID,
                    eventSequence: eventSequence,
                    outputIndex: delta.outputIndex,
                    text: delta.text
                ))
            }
        }
        try Task.checkCancellation()
        try await requireFence(fence)
        return try await materializeProviderOutput(
            events: events,
            plan: plan,
            prepared: prepared
        )
    }

    fileprivate func commitProviderDispatch(
        _ dispatch: ProviderAttemptDispatch,
        fence expectedFence: AgentEngineOwnerFence,
        plan: ProviderAttemptPlan
    ) async throws {
        try Task.checkCancellation()
        try await requireFence(expectedFence)
        guard dispatch.scope == plan.scope,
              dispatch.route == plan.route,
              state?.activeAttemptID == nil
        else {
            throw AgentEngineError.providerContract("provider_dispatch_plan_mismatch")
        }
        let metadata = try dispatch.journalMetadata(
            ordinal: plan.ordinal,
            recoverySeed: plan.recoverySeed
        )
        let outcome = try await append(
            .modelRequestStarted(ModelRequestStartedEvent(
                attemptID: plan.attemptID,
                route: Self.domainRoute(plan.route),
                providerAttempt: metadata
            )),
            requireFreshCommit: true
        )
        guard case .newlyCommitted = outcome else {
            // A verified post-throw commit belongs to this exact call and is
            // safe. `append` never maps `.alreadyCommitted` to this outcome.
            if case .verifiedAfterThrownCommit = outcome { return }
            throw AgentEngineError.providerContract(
                "provider_dispatch_not_freshly_committed"
            )
        }
    }

    private func materializeProviderOutput(
        events: [ProviderAttemptEvent],
        plan: ProviderAttemptPlan,
        prepared: AgentPreparedProviderTurn
    ) async throws -> ProviderAttemptOutput {
        var responseID: String?
        var textByIndex: [Int: String] = [:]
        var textOrder: [Int] = []
        var reasoningByIndex: [Int: String] = [:]
        var reasoningOrder: [Int] = []
        var toolCalls: [ProviderToolCallCompletion] = []
        var usage: ProviderUsage?
        var finishReason: ModelFinishReason?

        for attemptEvent in events {
            switch attemptEvent.event {
            case let .responseStarted(start):
                responseID = start.responseID
            case let .textDelta(delta):
                if textByIndex[delta.outputIndex] == nil {
                    textOrder.append(delta.outputIndex)
                }
                textByIndex[delta.outputIndex, default: ""] += delta.text
            case let .reasoningDelta(delta):
                if reasoningByIndex[delta.outputIndex] == nil {
                    reasoningOrder.append(delta.outputIndex)
                }
                reasoningByIndex[delta.outputIndex, default: ""] += delta.text
            case .toolCallStarted, .toolCallArgumentsDelta:
                break
            case let .toolCallCompleted(call):
                toolCalls.append(call)
            case let .usage(value):
                usage = value
            case let .responseCompleted(completion):
                guard finishReason == nil else {
                    throw AgentEngineError.providerContract(
                        "duplicate_provider_completion"
                    )
                }
                finishReason = completion.finishReason
                responseID = responseID ?? completion.responseID
            case .cancelled:
                throw CancellationError()
            }
        }
        guard let finishReason, let usage else {
            throw AgentEngineError.providerContract(
                "provider_attempt_missing_completion_or_usage"
            )
        }
        guard (finishReason == .toolCalls) == !toolCalls.isEmpty else {
            throw AgentEngineError.providerContract(
                "provider_finish_reason_tool_mismatch"
            )
        }

        var items: [ModelItem] = []
        let now = try await clock.now()
        let text = textOrder.compactMap { textByIndex[$0] }.joined()
        if !text.isEmpty {
            items.append(ModelItem(
                id: ModelItemID(rawValue: try await identities.nextUUID()),
                createdAt: now,
                payload: .message(ModelMessage(
                    role: .assistant,
                    content: [.text(text)]
                ))
            ))
        }
        let reasoning = reasoningOrder.compactMap {
            reasoningByIndex[$0]
        }.joined()
        if !reasoning.isEmpty {
            items.append(ModelItem(
                id: ModelItemID(rawValue: try await identities.nextUUID()),
                createdAt: now,
                payload: .reasoningSummary(ReasoningSummary(
                    text: reasoning,
                    providerReference: responseID
                ))
            ))
        }

        var providerCallIDs: Set<String> = []
        for call in toolCalls {
            guard providerCallIDs.insert(call.callID).inserted else {
                throw AgentEngineError.toolContract(
                    "duplicate_provider_tool_call_id"
                )
            }
            let tool = try toolRegistry.resolve(call.name)
            _ = try toolRegistry.decode(
                name: tool.descriptor.name,
                version: tool.descriptor.version.description,
                arguments: call.arguments
            )
            let callID = ToolCallID(rawValue: try await identities.nextUUID())
            let invocation = ToolInvocation(
                callID: callID,
                providerCallID: call.callID,
                modelAttemptID: plan.attemptID,
                tool: tool.descriptor.identity,
                arguments: call.arguments,
                canonicalArgumentDigest: try tool.descriptor
                    .canonicalArgumentDigest(for: call.arguments),
                idempotencyKey: Self.toolIdempotencyKey(
                    runID: state?.context?.lineage.runID,
                    attemptID: plan.attemptID,
                    providerCallID: call.callID
                ),
                effectClass: tool.descriptor.effectClass,
                locality: prepared.toolLocalities[tool.descriptor.name]
                    ?? .onDevice
            )
            items.append(ModelItem(
                id: ModelItemID(rawValue: try await identities.nextUUID()),
                createdAt: now,
                payload: .toolInvocation(invocation)
            ))
        }
        return ProviderAttemptOutput(
            items: items,
            usage: usage.modelUsage,
            finishReason: finishReason
        )
    }

    // MARK: Tool loop

    private func driveTool(callID: ToolCallID) async throws {
        guard let state, let context = state.context,
              let toolState = state.tools.first(where: {
                  $0.invocation.callID == callID
              })
        else { throw AgentEngineError.toolContract("unknown_tool_call") }
        let invocation = toolState.invocation
        let descriptor = try toolRegistry.descriptor(named: invocation.tool.name)
        guard descriptor.identity == invocation.tool,
              descriptor.effectClass == invocation.effectClass
        else { throw AgentEngineError.toolContract("tool_identity_changed") }
        let decoded = try toolRegistry.decode(
            name: invocation.tool.name,
            version: invocation.tool.version,
            arguments: invocation.arguments
        )

        if invocation.effectClass == .readOnlyLocal {
            try await driveReadOnlyTool(
                context: context,
                descriptor: descriptor,
                decoded: decoded,
                toolState: toolState
            )
        } else {
            try await driveMutationTool(
                context: context,
                descriptor: descriptor,
                toolState: toolState
            )
        }
    }

    private func driveReadOnlyTool(
        context: AgentRunContext,
        descriptor: ToolDescriptor,
        decoded: DecodedToolArguments,
        toolState: ToolExecutionState
    ) async throws {
        let invocation = toolState.invocation
        switch toolState.status {
        case .proposed, .approved:
            _ = try await append(.toolScheduled(ToolScheduledEvent(
                callID: invocation.callID,
                effect: nil
            )))
            _ = try await append(.toolStarted(ToolStartedEvent(
                callID: invocation.callID,
                effect: nil
            )))
        case .scheduled:
            _ = try await append(.toolStarted(ToolStartedEvent(
                callID: invocation.callID,
                effect: nil
            )))
        case .running:
            break // A read can safely be repeated after recovery.
        case .awaitingApproval, .rejected, .applied, .completed:
            throw AgentEngineError.toolContract(
                "invalid_read_tool_state_\(toolState.status.rawValue)"
            )
        }

        do {
            let output = try await readOnlyExecutor.executeReadOnly(
                AgentReadOnlyToolRequest(
                    context: context,
                    invocation: invocation,
                    descriptor: descriptor,
                    decodedArguments: decoded
                )
            )
            try Task.checkCancellation()
            let result = ToolResult(
                modelItemID: ModelItemID(rawValue: try await identities.nextUUID()),
                callID: invocation.callID,
                status: .succeeded,
                output: output.output,
                artifacts: output.artifacts,
                evidence: output.evidence,
                warnings: output.warnings,
                error: nil
            )
            _ = try await append(.toolCompleted(ToolCompletedEvent(
                result: result,
                effect: nil
            )))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = AgentErrorInfo(
                category: .tool,
                code: Self.stableErrorCode(error, fallback: "read_tool_failed"),
                publicMessage: "The read-only tool could not complete.",
                retryable: true
            )
            let result = ToolResult(
                modelItemID: ModelItemID(rawValue: try await identities.nextUUID()),
                callID: invocation.callID,
                status: .failed,
                output: .object(["status": .string("failed")]),
                error: failure
            )
            _ = try await append(.toolCompleted(ToolCompletedEvent(
                result: result,
                effect: nil
            )))
        }
    }

    private func driveMutationTool(
        context: AgentRunContext,
        descriptor: ToolDescriptor,
        toolState: ToolExecutionState
    ) async throws {
        let invocation = toolState.invocation

        if toolState.status == .running || toolState.status == .applied {
            guard let effectKey = toolState.effectKey else {
                throw AgentEngineError.mutationBindingMismatch(invocation.callID)
            }
            let digest = try SHA256Digest(effectKey.effectKeySHA256.rawValue)
            let disposition = try await mutationExecutor.recoverMutation(
                context: context,
                invocation: invocation,
                effectKeySHA256: digest
            )
            switch disposition {
            case let .settled(output):
                try validateMutationOutput(
                    output,
                    expectedEffectKey: digest,
                    callID: invocation.callID
                )
                let receipt = try Self.domainReceipt(output.receipt)
                if toolState.status == .running {
                    _ = try await append(.toolApplied(ToolAppliedEvent(
                        callID: invocation.callID,
                        effect: receipt,
                        evidence: Self.mutationEvidence(output)
                    )))
                } else if toolState.effectReceipt != receipt {
                    throw AgentEngineError.mutationReceiptMismatch(invocation.callID)
                }
                try await completeMutationTool(
                    invocation: invocation,
                    output: output,
                    receipt: receipt
                )
                return
            case .reconciliationRequired, .noDurableRecord:
                throw AgentEngineError.unsafeRecovery(
                    "mutation_started_without_settled_receipt"
                )
            }
        }

        let preparation = try await mutationExecutor.prepareMutation(
            context: context,
            invocation: invocation,
            descriptor: descriptor,
            sealer: mutationPreparationSealer
        )
        try validate(
            preparation: preparation,
            context: context,
            invocation: invocation
        )

        var approval: ApprovalResolution?
        if let request = preparation.approvalRequest {
            try validate(
                approvalRequest: request,
                context: context,
                invocation: invocation
            )
            let existing = state?.approvals.first(where: {
                $0.request.requestID == request.requestID
            })
            if let existing {
                guard existing.request == request else {
                    throw AgentEngineError.approvalBindingMismatch(
                        request.requestID
                    )
                }
                switch existing.status {
                case .pending:
                    let resolved = try await approvalResolver.resolveApproval(request)
                    try validate(resolution: resolved, request: request)
                    _ = try await append(.approvalResolved(
                        ApprovalResolvedEvent(resolution: resolved)
                    ))
                    approval = resolved
                case .approved, .rejected:
                    approval = existing.resolution
                }
            } else {
                guard toolState.status == .proposed else {
                    throw AgentEngineError.approvalBindingMismatch(
                        request.requestID
                    )
                }
                _ = try await append(.approvalRequested(
                    ApprovalRequestedEvent(request: request)
                ))
                let resolved = try await approvalResolver.resolveApproval(request)
                try validate(resolution: resolved, request: request)
                _ = try await append(.approvalResolved(
                    ApprovalResolvedEvent(resolution: resolved)
                ))
                approval = resolved
            }
            if approval?.decision == .rejected {
                let result = ToolResult.approvalRejected(
                    modelItemID: ModelItemID(
                        rawValue: try await identities.nextUUID()
                    ),
                    callID: invocation.callID
                )
                _ = try await append(.toolCompleted(ToolCompletedEvent(
                    result: result,
                    effect: nil
                )))
                return
            }
            guard approval?.decision == .approved else {
                throw AgentEngineError.approvalBindingMismatch(request.requestID)
            }
        } else if state?.approvals.contains(where: {
            $0.request.binding.callID == invocation.callID
        }) == true {
            throw AgentEngineError.mutationBindingMismatch(invocation.callID)
        }

        let effect = try Self.domainEffectKey(preparation.effectKeySHA256)
        switch state?.tools.first(where: {
            $0.invocation.callID == invocation.callID
        })?.status {
        case .proposed, .approved:
            _ = try await append(.toolScheduled(ToolScheduledEvent(
                callID: invocation.callID,
                effect: effect
            )))
            _ = try await append(.toolStarted(ToolStartedEvent(
                callID: invocation.callID,
                effect: effect
            )))
        case .scheduled:
            guard state?.tools.first(where: {
                $0.invocation.callID == invocation.callID
            })?.effectKey == effect else {
                throw AgentEngineError.mutationBindingMismatch(invocation.callID)
            }
            _ = try await append(.toolStarted(ToolStartedEvent(
                callID: invocation.callID,
                effect: effect
            )))
        default:
            throw AgentEngineError.toolContract("invalid_mutation_schedule_state")
        }

        let output = try await mutationExecutor.applyMutation(
            preparation: preparation,
            approval: approval
        )
        try Task.checkCancellation()
        try validateMutationOutput(
            output,
            expectedEffectKey: preparation.effectKeySHA256,
            callID: invocation.callID
        )
        let receipt = try Self.domainReceipt(output.receipt)
        _ = try await append(.toolApplied(ToolAppliedEvent(
            callID: invocation.callID,
            effect: receipt,
            evidence: Self.mutationEvidence(output)
        )))
        try await completeMutationTool(
            invocation: invocation,
            output: output,
            receipt: receipt
        )
    }

    private func completeMutationTool(
        invocation: ToolInvocation,
        output: AgentMutationToolOutput,
        receipt: ToolEffectReceiptReference
    ) async throws {
        let result = ToolResult(
            modelItemID: ModelItemID(rawValue: try await identities.nextUUID()),
            callID: invocation.callID,
            status: .succeeded,
            output: output.output,
            artifacts: output.artifacts,
            evidence: Self.mutationEvidence(output),
            warnings: output.warnings,
            error: nil
        )
        _ = try await append(.toolCompleted(ToolCompletedEvent(
            result: result,
            effect: receipt
        )))
    }

    // MARK: Journal append lane

    @discardableResult
    private func append(
        _ payload: AgentEventPayload,
        requireFreshCommit: Bool = false
    ) async throws -> AppendOutcome {
        await acquireAppendLane()
        defer { releaseAppendLane() }

        guard let current = state,
              let context = current.context,
              let fence,
              let writerID,
              let correlationID,
              let sequence = current.lastSequence?.successor
        else { throw AgentEngineError.noOwnedRun }
        try await requireFence(fence)
        let eventID = EventID(rawValue: try await identities.nextUUID())
        let event = AgentEvent(
            header: AgentEventHeader(
                eventID: eventID,
                schemaVersion: context.schemaVersion,
                context: context,
                sequence: sequence,
                timestamp: try await clock.now(),
                causationID: lastCausationID,
                correlationID: correlationID
            ),
            payload: payload
        )
        let projected: AgentRunState
        switch AgentReducer.reduce(current, event: event) {
        case let .success(next): projected = next
        case let .failure(failure):
            throw AgentEngineError.reducerRejected(failure)
        }
        let envelope = AgentEventEnvelope(
            writerID: writerID,
            writerSequence: sequence,
            idempotencyKey: Self.eventIdempotencyKey(event),
            event: event
        )

        let outcome: AppendOutcome
        do {
            let commit = try await journal.append(envelope)
            guard commit.record.envelope == envelope else {
                throw AgentEngineError.persistence("append_receipt_mismatch")
            }
            guard commit.disposition == .committed else {
                // Never let an old dispatch barrier open transport.
                if requireFreshCommit {
                    throw AgentEngineError.providerContract(
                        "provider_dispatch_already_committed"
                    )
                }
                throw AgentEngineError.persistence("unexpected_idempotent_append")
            }
            outcome = .newlyCommitted(commit)
        } catch let engineError as AgentEngineError {
            throw engineError
        } catch {
            let records = try? await journal.events(
                for: context.lineage.runID,
                after: current.lastSequence
            )
            guard let exact = records?.first(where: {
                $0.envelope == envelope
            }) else {
                throw AgentEngineError.persistence(
                    Self.stableErrorCode(error, fallback: "append_failed")
                )
            }
            outcome = .verifiedAfterThrownCommit(exact)
        }

        // Projection follows—not precedes—the durable commit.
        state = projected
        lastCausationID = CausationID(rawValue: eventID.rawValue)
        try await requireFence(fence)
        return outcome
    }

    private func persistFreshAcceptance(
        _ acceptance: AgentRunAcceptance,
        fence: AgentEngineOwnerFence
    ) async throws {
        try await requireFence(fence)
        do {
            let commit = try await journal.accept(acceptance)
            guard commit.disposition == .committed,
                  commit.record.envelope == acceptance.envelope
            else {
                throw AgentEngineError.persistence(
                    "acceptance_not_freshly_committed"
                )
            }
        } catch let engineError as AgentEngineError {
            throw engineError
        } catch {
            let metadata = try? await journal.metadata(
                for: acceptance.metadata.runID
            )
            let records = try? await journal.events(
                for: acceptance.metadata.runID,
                after: nil
            )
            guard metadata == acceptance.metadata,
                  records?.first?.envelope == acceptance.envelope
            else {
                throw AgentEngineError.persistence(
                    Self.stableErrorCode(error, fallback: "acceptance_failed")
                )
            }
        }
        try await requireFence(fence)
    }

    private func acquireAppendLane() async {
        if !appendLaneBusy {
            appendLaneBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            appendLaneWaiters.append(continuation)
        }
    }

    private func releaseAppendLane() {
        if appendLaneWaiters.isEmpty {
            appendLaneBusy = false
        } else {
            appendLaneWaiters.removeFirst().resume()
        }
    }

    // MARK: Terminal settlement

    private func completeRun() async throws -> AgentRunState {
        _ = try await append(.runCompleted(RunCompletedEvent()))
        return try await settleTerminalIndex()
    }

    private func failRun(_ error: AgentErrorInfo) async throws -> AgentRunState {
        if let state, state.phase.isTerminal { return state }
        _ = try await append(.runFailed(RunFailedEvent(error: error)))
        return try await settleTerminalIndex()
    }

    private func interruptRun(
        code: String,
        message: String,
        safeToResume: Bool
    ) async throws -> AgentRunState {
        if let state, state.phase.isTerminal { return state }
        _ = try await append(.runInterrupted(RunInterruptedEvent(
            error: AgentErrorInfo(
                category: .invariantViolation,
                code: code,
                publicMessage: message,
                retryable: false
            ),
            safeToResume: safeToResume
        )))
        return try await settleTerminalIndex()
    }

    private func settleCancellation(
        _ command: CancelCommand
    ) async throws -> AgentRunState {
        if let state, state.phase.isTerminal { return state }
        guard let context = state?.context else { throw AgentEngineError.noOwnedRun }
        if state?.phase != .cancelling {
            _ = try await append(.cancellationRequested(
                CancellationRequestedEvent(
                    reason: command.reason,
                    propagateToDescendants: command.propagateToDescendants
                )
            ))
        }
        await cancellationPropagator.propagateCancellation(
            runID: context.lineage.runID,
            lineage: context.cancellation,
            reason: command.reason,
            toDescendants: command.propagateToDescendants
        )
        _ = try await append(.runCancelled(RunCancelledEvent(
            reason: command.reason
        )))
        return try await settleTerminalIndex()
    }

    private func settleTerminalIndex() async throws -> AgentRunState {
        guard let state,
              let context = state.context,
              let fence,
              let terminalEventID = state.terminalEventID
        else { throw AgentEngineError.noOwnedRun }
        try await runIndex.settle(AgentEngineTerminalRecord(
            runID: context.lineage.runID,
            fence: fence,
            phase: state.phase,
            terminalEventID: terminalEventID
        ))
        return state
    }

    // MARK: Validation and helpers

    private func requireCurrent(_ handle: AgentEngineRunHandle) throws {
        guard let context = state?.context else { throw AgentEngineError.noOwnedRun }
        guard context.lineage.runID == handle.runID else {
            throw AgentEngineError.runMismatch(
                expected: context.lineage.runID,
                actual: handle.runID
            )
        }
        guard fence == handle.ownerFence else { throw AgentEngineError.staleOwner }
    }

    private func requireFence(_ expected: AgentEngineOwnerFence) async throws {
        guard fence == expected else { throw AgentEngineError.staleOwner }
        do { try await runIndex.validate(expected) }
        catch { throw AgentEngineError.staleOwner }
    }

    private func validate(
        prepared: AgentPreparedProviderTurn,
        state: AgentRunState
    ) throws {
        guard !prepared.request.requestID.isEmpty,
              prepared.request.requestID.utf8.count <= 512,
              !prepared.preferredAdapterIDs.isEmpty,
              Set(prepared.itemIDs).count == prepared.itemIDs.count,
              Set(prepared.itemIDs).isSubset(of: Set(state.modelItems.map(\.id)))
        else { throw AgentEngineError.invalidPreparedContext }
    }

    private func validate(
        preparation: AgentMutationPreparation,
        context: AgentRunContext,
        invocation: ToolInvocation
    ) throws {
        guard preparation.runID == context.lineage.runID,
              preparation.workspaceID == context.workspaceID,
              preparation.callID == invocation.callID,
              preparation.canonicalArgumentDigest
                == invocation.canonicalArgumentDigest,
              preparation.engineSeal == mutationPreparationSealer.seal,
              !preparation.authorityToken.isEmpty,
              preparation.authorityToken.utf8.count <= 512,
              preparation.authorityToken.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw AgentEngineError.mutationBindingMismatch(invocation.callID)
        }
    }

    private func validate(
        approvalRequest: ApprovalRequest,
        context: AgentRunContext,
        invocation: ToolInvocation
    ) throws {
        let binding = approvalRequest.binding
        guard binding.runID == context.lineage.runID,
              binding.workspaceID == context.workspaceID,
              binding.callID == invocation.callID,
              binding.tool == invocation.tool,
              binding.canonicalArgumentDigest
                == invocation.canonicalArgumentDigest
        else {
            throw AgentEngineError.approvalBindingMismatch(
                approvalRequest.requestID
            )
        }
    }

    private func validate(
        resolution: ApprovalResolution,
        request: ApprovalRequest
    ) throws {
        guard resolution.requestID == request.requestID,
              resolution.callID == request.binding.callID
        else {
            throw AgentEngineError.approvalBindingMismatch(request.requestID)
        }
    }

    private func validateMutationOutput(
        _ output: AgentMutationToolOutput,
        expectedEffectKey: SHA256Digest,
        callID: ToolCallID
    ) throws {
        guard output.receipt.effectKeySHA256 == expectedEffectKey else {
            throw AgentEngineError.mutationReceiptMismatch(callID)
        }
    }

    private func nextUnproposedInvocation(
        in state: AgentRunState
    ) -> ToolInvocation? {
        state.modelItems.lazy.compactMap { item -> ToolInvocation? in
            guard case let .toolInvocation(invocation) = item.payload else {
                return nil
            }
            return invocation
        }.first { invocation in
            !state.tools.contains(where: {
                $0.invocation.callID == invocation.callID
            })
        }
    }

    private func nextAttemptOrdinal() throws -> UInt32 {
        let ordinals = state?.modelAttempts.compactMap { attempt -> UInt32? in
            guard case let .recordedV1_1(_, _, ordinal, _) =
                    attempt.providerAttempt
            else { return nil }
            return ordinal
        } ?? []
        let last = ordinals.max() ?? 0
        guard last < UInt32.max else {
            throw AgentEngineError.providerContract("attempt_ordinal_exhausted")
        }
        return last + 1
    }

    private func routeForScheduledAttempt(
        in candidates: [ProviderRoute]
    ) -> ProviderRoute? {
        let desired = recoveredScheduledRoute
            ?? state?.modelAttempts.last.map { $0.route }
        guard let desired else { return nil }
        return candidates.first { Self.domainRoute($0) == desired }
    }

    private func consecutiveAttemptCount(on route: ProviderRoute) -> UInt32 {
        var count: UInt32 = 0
        for attempt in (state?.modelAttempts ?? []).reversed() {
            if attempt.status == .responseCommitted { break }
            guard attempt.route == Self.domainRoute(route) else { break }
            count &+= 1
        }
        return count
    }

    private func fallbackCountInCurrentTurn() -> UInt32 {
        var routes: [ModelRoute] = []
        for attempt in (state?.modelAttempts ?? []).reversed() {
            if attempt.status == .responseCommitted { break }
            routes.append(attempt.route)
        }
        var unique: [ModelRoute] = []
        for route in routes where !unique.contains(route) {
            unique.append(route)
        }
        return UInt32(clamping: max(0, unique.count - 1))
    }

    private static func domainRoute(_ route: ProviderRoute) -> ModelRoute {
        ModelRoute(
            provider: route.providerID.rawValue,
            model: route.modelID.rawValue,
            adapter: route.adapterID.rawValue
        )
    }

    private static func domainEffectKey(
        _ digest: SHA256Digest
    ) throws -> ToolEffectKeyReference {
        ToolEffectKeyReference(
            effectKeySHA256: try AgentCanonicalSHA256Digest(digest.rawValue)
        )
    }

    private static func domainReceipt(
        _ receipt: AgentMutationReceipt
    ) throws -> ToolEffectReceiptReference {
        ToolEffectReceiptReference(
            effectKeySHA256: try AgentCanonicalSHA256Digest(
                receipt.effectKeySHA256.rawValue
            ),
            applicationSHA256: try AgentCanonicalSHA256Digest(
                receipt.applicationSHA256.rawValue
            ),
            evidenceSHA256: try AgentCanonicalSHA256Digest(
                receipt.evidenceSHA256.rawValue
            ),
            finalRecordSHA256: try AgentCanonicalSHA256Digest(
                receipt.finalRecordSHA256.rawValue
            )
        )
    }

    private static func mutationEvidence(
        _ output: AgentMutationToolOutput
    ) -> [ToolEvidence] {
        output.evidence + [ToolEvidence(
            kind: "mutation_receipt",
            digest: output.receipt.receiptSHA256.rawValue,
            metadata: .object([
                "application_sha256": .string(
                    output.receipt.applicationSHA256.rawValue
                ),
                "evidence_sha256": .string(
                    output.receipt.evidenceSHA256.rawValue
                ),
                "final_record_sha256": .string(
                    output.receipt.finalRecordSHA256.rawValue
                ),
            ])
        )]
    }

    private static func eventIdempotencyKey(_ event: AgentEvent) -> String {
        "event:\(event.header.sequence.rawValue):\(event.header.eventID.description)"
    }

    private static func toolIdempotencyKey(
        runID: RunID?,
        attemptID: AttemptID,
        providerCallID: String
    ) -> String {
        let raw = "tool:\(runID?.description ?? "unknown"):\(attemptID.description):\(providerCallID)"
        if raw.utf8.count <= 512 { return raw }
        return "tool:\(attemptID.description):\(providerCallID.prefix(420))"
    }

    private static func retryReason(kind: String, delay: UInt64) -> String {
        "provider_\(kind);delay_ms=\(delay)"
    }

    private static func retryDelay(from reason: String) -> UInt64? {
        guard let range = reason.range(of: "delay_ms=") else { return nil }
        return UInt64(reason[range.upperBound...])
    }

    private static func stableErrorCode(
        _ error: any Error,
        fallback: String
    ) -> String {
        if let engine = error as? AgentEngineError {
            switch engine {
            case let .providerContract(code), let .toolContract(code),
                 let .persistence(code), let .unsafeRecovery(code):
                return code
            default: return fallback
            }
        }
        return fallback
    }

    private static func errorInfo(for failure: ProviderFailure) -> AgentErrorInfo {
        let category: AgentErrorCategory = switch failure.category {
        case .cancelled: .cancelled
        case .timeout: .timeout
        case .authentication: .authentication
        case .authorization: .authorization
        case .invalidRequest: .invalidInput
        case .rateLimited: .rateLimited
        case .contextLimit: .contextLimit
        case .unavailable: .unavailable
        case .transport: .transport
        case .malformedEvent, .protocolViolation, .contentFiltered,
             .providerInternal, .unknown: .provider
        }
        return AgentErrorInfo(
            category: category,
            code: failure.code,
            publicMessage: failure.publicMessage,
            retryable: failure.retryableOnSameRoute
                || failure.recoverableByFallback
        )
    }

    private static func errorInfo(for error: AgentEngineError) -> AgentErrorInfo {
        switch error {
        case let .providerFailed(info): return info
        case .cancelled:
            return AgentErrorInfo(
                category: .cancelled,
                code: "engine_cancelled",
                publicMessage: "The run was cancelled.",
                retryable: true
            )
        case let .persistence(code):
            return AgentErrorInfo(
                category: .persistence,
                code: code,
                publicMessage: "The run could not be saved.",
                retryable: true
            )
        case let .toolContract(code):
            return AgentErrorInfo(
                category: .tool,
                code: code,
                publicMessage: "A tool request was invalid.",
                retryable: false
            )
        case let .providerContract(code):
            return AgentErrorInfo(
                category: .provider,
                code: code,
                publicMessage: "The provider contract was not satisfied.",
                retryable: false
            )
        default:
            return AgentErrorInfo(
                category: .invariantViolation,
                code: "engine_invariant_failure",
                publicMessage: "The agent run violated a safety invariant.",
                retryable: false
            )
        }
    }
}

private struct EngineProviderDispatchBarrier: ProviderAttemptDispatchBarrier {
    let engine: AgentEngine
    let fence: AgentEngineOwnerFence
    let plan: AgentEngine.ProviderAttemptPlan

    func beforeDispatch(_ attempt: ProviderAttemptDispatch) async throws {
        try await engine.commitProviderDispatch(
            attempt,
            fence: fence,
            plan: plan
        )
    }
}

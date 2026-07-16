#if DEBUG
import AgentDomain
import AgentProviders
import AgentShadow
import AgentStore
import CryptoKit
import Foundation

enum AgentHostedTextCanaryTerminalOutcome: Equatable, Sendable {
    case completed
    case failed(AgentErrorInfo)
    case cancelled(AgentErrorInfo)
}

enum AgentHostedTextCanaryRunExecutorError: Error, Equatable, Sendable {
    case acceptanceFailed
    case duplicateAcceptance
    case runFailed(AgentErrorInfo)
    case runCancelled(AgentErrorInfo)
    case settlementFailed
    case projectionFailed(AgentHostedTextCanaryTerminalOutcome)
}

struct AgentHostedTextCanaryRunExecution: Equatable, Sendable {
    let providerResult: AgentHostedTextCanaryResult
    let terminalCommit: AgentJournalCommit
}

/// Owns the complete accepted-run lifetime around the deliberately narrower
/// provider coordinator. The caller supplies an unaccepted acceptance unit;
/// no replay or provider work can start until that exact unit is durable.
struct AgentHostedTextCanaryRunExecutor: Sendable {
    typealias Projection = @Sendable (RunID) async throws -> Void
    typealias DidAccept = @Sendable () async -> Void
    typealias ProviderOperation = @Sendable (
        _ acceptance: AgentRunAcceptance,
        _ request: CanonicalProviderRequest,
        _ capturedContext: AgentHostedTextCanaryCapturedContext?
    ) async throws -> AgentHostedTextCanaryResult

    private let journal: any AgentEventJournal
    private let providerOperation: ProviderOperation
    private let projection: Projection

    init(
        journal: any AgentEventJournal,
        provider: AgentHostedTextCanaryProvider,
        transport: any ProviderTransport,
        projection: @escaping Projection
    ) {
        self.journal = journal
        let coordinator = AgentHostedTextCanaryCoordinator(
            journal: journal,
            provider: provider,
            transport: transport
        )
        providerOperation = { acceptance, request, capturedContext in
            try await coordinator.execute(
                acceptedRun: acceptance,
                request: request,
                capturedContext: capturedContext
            )
        }
        self.projection = projection
    }

    init(
        journal: any AgentEventJournal,
        readOnlyProvider provider: AgentHostedReadOnlyCanaryProvider,
        transport: any ProviderTransport,
        backend: any DeveloperReadOnlyCanaryToolBackend,
        boundWorkspaceID: WorkspaceID,
        projection: @escaping Projection
    ) throws {
        self.journal = journal
        let coordinator = try AgentHostedReadOnlyCanaryCoordinator(
            journal: journal,
            provider: provider,
            transport: transport,
            backend: backend,
            boundWorkspaceID: boundWorkspaceID
        )
        providerOperation = { acceptance, request, capturedContext in
            try await coordinator.execute(
                acceptedRun: acceptance,
                request: request,
                capturedContext: capturedContext
            )
        }
        self.projection = projection
    }

    func execute(
        acceptance: AgentRunAcceptance,
        request: CanonicalProviderRequest,
        capturedContext: AgentHostedTextCanaryCapturedContext? = nil,
        didAccept: @escaping DidAccept = {}
    ) async throws -> AgentHostedTextCanaryRunExecution {
        let acceptanceCommit: AgentJournalCommit
        do {
            acceptanceCommit = try await journal.accept(acceptance)
        } catch {
            throw AgentHostedTextCanaryRunExecutorError.acceptanceFailed
        }
        guard acceptanceCommit.disposition == .committed else {
            throw AgentHostedTextCanaryRunExecutorError.duplicateAcceptance
        }
        guard acceptanceCommit.record.envelope == acceptance.envelope else {
            throw AgentHostedTextCanaryRunExecutorError.acceptanceFailed
        }
        await didAccept()

        let providerResult: AgentHostedTextCanaryResult
        do {
            providerResult = try await providerOperation(
                acceptance,
                request,
                capturedContext
            )
        } catch {
            let info = Self.executionFailureInfo(error)
            let terminal = try await settleAndProject(
                acceptance: acceptance,
                failure: info
            )
            throw Self.error(for: terminal.outcome)
        }

        let terminal: DurableCanaryTerminal
        do {
            try Task.checkCancellation()
            terminal = try await appendCompletion(for: acceptance)
        } catch {
            let info = Self.completionFailureInfo(error)
            let recovered = try await settleAndProject(
                acceptance: acceptance,
                failure: info
            )
            if recovered.outcome == .completed {
                return AgentHostedTextCanaryRunExecution(
                    providerResult: providerResult,
                    terminalCommit: recovered.commit
                )
            }
            throw Self.error(for: recovered.outcome)
        }

        guard terminal.outcome == .completed else {
            try await projectDetached(terminal)
            throw Self.error(for: terminal.outcome)
        }
        try await project(terminal)
        return AgentHostedTextCanaryRunExecution(
            providerResult: providerResult,
            terminalCommit: terminal.commit
        )
    }

    private func appendCompletion(
        for acceptance: AgentRunAcceptance
    ) async throws -> DurableCanaryTerminal {
        let ledger = try await loadLedger(for: acceptance)
        if let terminal = Self.existingTerminal(in: ledger.records) {
            return terminal
        }
        guard ledger.state.phase == .running,
              let sequence = ledger.state.lastSequence?.successor,
              let causation = ledger.state.lastEventID
        else {
            throw CanarySettlementInternalError.invalidDurablePrefix
        }

        let envelope = Self.envelope(
            acceptance: acceptance,
            sequence: sequence,
            idempotencyKey: "m5-canary:run-completed:v1",
            eventDomain: "m5-hosted-text-run-completed",
            eventMaterial: acceptance.metadata.runID.description,
            causationEventID: causation,
            payload: .runCompleted(RunCompletedEvent())
        )
        let commit = try await appendOrRecover(envelope)
        return DurableCanaryTerminal(outcome: .completed, commit: commit)
    }

    private func settleAndProject(
        acceptance: AgentRunAcceptance,
        failure: AgentErrorInfo
    ) async throws -> DurableCanaryTerminal {
        let operation: @Sendable () async throws -> DurableCanaryTerminal = {
            let terminal: DurableCanaryTerminal
            do {
                terminal = try await self.settle(
                    acceptance: acceptance,
                    failure: failure
                )
            } catch {
                throw AgentHostedTextCanaryRunExecutorError.settlementFailed
            }
            try await self.project(terminal)
            return terminal
        }
        return try await Task.detached(operation: operation).value
    }

    private func settle(
        acceptance: AgentRunAcceptance,
        failure: AgentErrorInfo
    ) async throws -> DurableCanaryTerminal {
        var ledger = try await loadLedger(for: acceptance)
        if let terminal = Self.existingTerminal(in: ledger.records) {
            return terminal
        }

        if failure.category == .cancelled {
            if ledger.state.phase != .cancelling {
                guard let sequence = ledger.state.lastSequence?.successor,
                      let causation = ledger.state.lastEventID
                else {
                    throw CanarySettlementInternalError.invalidDurablePrefix
                }
                let request = Self.envelope(
                    acceptance: acceptance,
                    sequence: sequence,
                    idempotencyKey: "m5-canary:cancellation-requested:v1",
                    eventDomain: "m5-hosted-text-cancellation-requested",
                    eventMaterial: acceptance.metadata.runID.description,
                    causationEventID: causation,
                    payload: .cancellationRequested(CancellationRequestedEvent(
                        reason: .userRequested,
                        propagateToDescendants: true
                    ))
                )
                _ = try await appendOrRecover(request)
                ledger = try await loadLedger(for: acceptance)
            }

            guard ledger.state.phase == .cancelling,
                  let cancellation = ledger.state.cancellation,
                  let sequence = ledger.state.lastSequence?.successor,
                  let causation = ledger.state.lastEventID
            else {
                throw CanarySettlementInternalError.invalidDurablePrefix
            }
            let cancelled = Self.envelope(
                acceptance: acceptance,
                sequence: sequence,
                idempotencyKey: "m5-canary:run-cancelled:v1",
                eventDomain: "m5-hosted-text-run-cancelled",
                eventMaterial: acceptance.metadata.runID.description,
                causationEventID: causation,
                payload: .runCancelled(RunCancelledEvent(
                    reason: cancellation.reason
                ))
            )
            let commit = try await appendOrRecover(cancelled)
            return DurableCanaryTerminal(
                outcome: .cancelled(failure),
                commit: commit
            )
        }

        guard let sequence = ledger.state.lastSequence?.successor,
              let causation = ledger.state.lastEventID
        else {
            throw CanarySettlementInternalError.invalidDurablePrefix
        }
        let failureDigest = Self.failureDigest(failure)
        let failed = Self.envelope(
            acceptance: acceptance,
            sequence: sequence,
            idempotencyKey: "m5-canary:run-failed:v1:\(failureDigest)",
            eventDomain: "m5-hosted-text-run-failed",
            eventMaterial: acceptance.metadata.runID.description + "|" +
                failureDigest,
            causationEventID: causation,
            payload: .runFailed(RunFailedEvent(error: failure))
        )
        let commit = try await appendOrRecover(failed)
        return DurableCanaryTerminal(
            outcome: .failed(failure),
            commit: commit
        )
    }

    private func project(_ terminal: DurableCanaryTerminal) async throws {
        do {
            try await projection(terminal.commit.record.runID)
        } catch {
            throw AgentHostedTextCanaryRunExecutorError.projectionFailed(
                terminal.outcome
            )
        }
    }

    /// Failure and cancellation projections must not inherit caller
    /// cancellation. A terminal may have been committed by another writer
    /// while this executor was finishing a successful provider attempt.
    private func projectDetached(
        _ terminal: DurableCanaryTerminal
    ) async throws {
        try await Task.detached {
            try await self.project(terminal)
        }.value
    }

    private func appendOrRecover(
        _ envelope: AgentEventEnvelope
    ) async throws -> AgentJournalCommit {
        do {
            let commit = try await journal.append(envelope)
            guard commit.record.envelope == envelope else {
                throw CanarySettlementInternalError.eventIdentityMismatch
            }
            return commit
        } catch {
            let records = try await journal.events(
                for: envelope.runID,
                after: nil
            )
            guard let existing = records.first(where: {
                $0.event.header.eventID == envelope.event.header.eventID
            }), existing.envelope == envelope else {
                throw error
            }
            return AgentJournalCommit(
                disposition: .alreadyCommitted,
                record: existing
            )
        }
    }

    private func loadLedger(
        for acceptance: AgentRunAcceptance
    ) async throws -> CanaryLedger {
        guard let metadata = try await journal.metadata(
            for: acceptance.metadata.runID
        ), metadata == acceptance.metadata else {
            throw CanarySettlementInternalError.invalidDurablePrefix
        }
        let records = try await journal.events(
            for: acceptance.metadata.runID,
            after: nil
        )
        guard records.first?.envelope == acceptance.envelope else {
            throw CanarySettlementInternalError.invalidDurablePrefix
        }
        return CanaryLedger(
            records: records,
            state: try AgentJournalReplay.replay(records, metadata: metadata)
        )
    }

    private static func existingTerminal(
        in records: [StoredAgentEvent]
    ) -> DurableCanaryTerminal? {
        guard let record = records.last else { return nil }
        let outcome: AgentHostedTextCanaryTerminalOutcome
        switch record.event.payload {
        case .runCompleted:
            outcome = .completed
        case let .runFailed(payload):
            outcome = .failed(payload.error)
        case .runCancelled:
            let priorCancellation = records.reversed().compactMap {
                item -> AgentErrorInfo? in
                guard case let .modelRequestFailed(value) = item.event.payload,
                      value.error.category == .cancelled else { return nil }
                return value.error
            }.first
            outcome = .cancelled(priorCancellation ?? AgentErrorInfo(
                category: .cancelled,
                code: "hosted_text_attempt_cancelled",
                publicMessage: "The hosted text attempt was cancelled.",
                retryable: false
            ))
        case let .runInterrupted(payload):
            outcome = .failed(payload.error)
        default:
            return nil
        }
        return DurableCanaryTerminal(
            outcome: outcome,
            commit: AgentJournalCommit(
                disposition: .alreadyCommitted,
                record: record
            )
        )
    }

    private static func error(
        for outcome: AgentHostedTextCanaryTerminalOutcome
    ) -> AgentHostedTextCanaryRunExecutorError {
        switch outcome {
        case .completed:
            .settlementFailed
        case let .failed(info):
            .runFailed(info)
        case let .cancelled(info):
            .runCancelled(info)
        }
    }

    private static func executionFailureInfo(_ error: Error) -> AgentErrorInfo {
        if let coordinatorError = error as? AgentHostedTextCanaryCoordinatorError,
           case let .attemptFailed(info) = coordinatorError {
            return info
        }
        if let coordinatorError = error as? AgentHostedReadOnlyCanaryCoordinatorError,
           case let .attemptFailed(info) = coordinatorError {
            return info
        }
        if let coordinatorError = error as? AgentHostedReadOnlyCanaryCoordinatorError {
            switch coordinatorError {
            case .toolFailed, .toolOutputTooLarge:
                return AgentErrorInfo(
                    category: .tool,
                    code: "hosted_read_tool_failed",
                    publicMessage: "The read-only tool failed safely.",
                    retryable: false
                )
            default:
                break
            }
        }
        if Task.isCancelled || error is CancellationError {
            return cancellationFailureInfo
        }
        return AgentErrorInfo(
            category: .invariantViolation,
            code: "hosted_text_canary_execution_rejected",
            publicMessage: "The hosted text canary failed a safety contract.",
            retryable: false
        )
    }

    private static func completionFailureInfo(_ error: Error) -> AgentErrorInfo {
        if Task.isCancelled || error is CancellationError {
            return cancellationFailureInfo
        }
        return AgentErrorInfo(
            category: .persistence,
            code: "hosted_text_run_completion_not_committed",
            publicMessage: "The hosted text run could not be completed safely.",
            retryable: false
        )
    }

    private static let cancellationFailureInfo = AgentErrorInfo(
        category: .cancelled,
        code: "hosted_text_attempt_cancelled",
        publicMessage: "The hosted text attempt was cancelled.",
        retryable: false
    )

    private static func envelope(
        acceptance: AgentRunAcceptance,
        sequence: EventSequence,
        idempotencyKey: String,
        eventDomain: String,
        eventMaterial: String,
        causationEventID: EventID,
        payload: AgentEventPayload
    ) -> AgentEventEnvelope {
        AgentEventEnvelope(
            writerID: acceptance.metadata.writerID,
            writerSequence: sequence,
            idempotencyKey: idempotencyKey,
            event: AgentEvent(
                header: AgentEventHeader(
                    eventID: EventID(rawValue: stableUUID(
                        domain: eventDomain,
                        material: eventMaterial
                    )),
                    schemaVersion: acceptance.metadata.context.schemaVersion,
                    context: acceptance.metadata.context,
                    sequence: sequence,
                    timestamp: eventTimestamp(
                        acceptance,
                        sequence: sequence
                    ),
                    causationID: CausationID(
                        rawValue: causationEventID.rawValue
                    ),
                    correlationID: acceptance.envelope.event.header
                        .correlationID
                ),
                payload: payload
            )
        )
    }

    private static func eventTimestamp(
        _ acceptance: AgentRunAcceptance,
        sequence: EventSequence
    ) -> AgentInstant {
        let delta = Int64(clamping: sequence.rawValue - 1)
        let addition = acceptance.metadata.context.acceptedAt.rawValue
            .addingReportingOverflow(delta)
        return AgentInstant(
            rawValue: addition.overflow ? Int64.max : addition.partialValue
        )
    }

    private static func failureDigest(_ failure: AgentErrorInfo) -> String {
        SHA256.hash(data: Data((failure.category.rawValue + "\u{0}" +
            failure.code).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func stableUUID(domain: String, material: String) -> UUID {
        var bytes = Array(SHA256.hash(
            data: Data((domain + "\u{0}" + material).utf8)
        ).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private struct CanaryLedger: Sendable {
    let records: [StoredAgentEvent]
    let state: AgentDomain.AgentRunState
}

private struct DurableCanaryTerminal: Sendable {
    let outcome: AgentHostedTextCanaryTerminalOutcome
    let commit: AgentJournalCommit
}

private enum CanarySettlementInternalError: Error {
    case invalidDurablePrefix
    case eventIdentityMismatch
}
#endif

import AgentDomain
import AgentReducerCore
import Foundation

/// Shared validation used by every event-store implementation. Persistent
/// adapters should call these functions inside their transaction before save.
public enum AgentJournalValidation {
    public static let maximumIdempotencyKeyByteCount = 512

    public static func validateEnvelope(
        _ envelope: AgentEventEnvelope
    ) throws {
        let keyByteCount = envelope.idempotencyKey.utf8.count
        guard keyByteCount > 0,
              !envelope.idempotencyKey.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            throw AgentStoreError.invalidEnvelope(.emptyIdempotencyKey)
        }
        guard keyByteCount <= maximumIdempotencyKeyByteCount else {
            throw AgentStoreError.invalidEnvelope(
                .idempotencyKeyTooLong(
                    actual: keyByteCount,
                    maximum: maximumIdempotencyKeyByteCount
                )
            )
        }
        guard envelope.writerSequence == envelope.event.header.sequence else {
            throw AgentStoreError.invalidEnvelope(
                .writerEventSequenceMismatch(
                    writerSequence: envelope.writerSequence,
                    eventSequence: envelope.event.header.sequence
                )
            )
        }
    }

    /// Validates the complete atomic-acceptance unit and returns the first
    /// reducer projection. Nothing should be persisted if this function fails.
    public static func validateAcceptance(
        _ acceptance: AgentRunAcceptance
    ) throws -> AgentRunState {
        try validateEnvelope(acceptance.envelope)

        let metadata = acceptance.metadata
        let envelope = acceptance.envelope
        let event = envelope.event

        guard metadata.runID == envelope.runID else {
            throw AgentStoreError.invalidAcceptance(.metadataRunMismatch)
        }
        guard metadata.writerID == envelope.writerID else {
            throw AgentStoreError.invalidAcceptance(.metadataWriterMismatch)
        }
        guard metadata.writerID == AgentEventWriterID(runID: metadata.runID) else {
            throw AgentStoreError.invalidAcceptance(.runWriterMismatch)
        }
        guard metadata.acceptanceEventID == event.header.eventID else {
            throw AgentStoreError.invalidAcceptance(.metadataEventMismatch)
        }
        guard metadata.acceptedEngineVersion == metadata.context.engineVersion else {
            throw AgentStoreError.invalidAcceptance(.metadataEngineVersionMismatch)
        }
        guard envelope.writerSequence == .first else {
            throw AgentStoreError.invalidAcceptance(
                .invalidFirstSequence(envelope.writerSequence)
            )
        }
        guard case let .runAccepted(payload) = event.payload else {
            throw AgentStoreError.invalidAcceptance(
                .unexpectedPayload(event.payload.kind)
            )
        }
        guard payload.context == metadata.context else {
            throw AgentStoreError.invalidAcceptance(.payloadContextMismatch)
        }
        guard payload.acceptedEngineVersion == metadata.acceptedEngineVersion else {
            throw AgentStoreError.invalidAcceptance(.payloadEngineVersionMismatch)
        }

        switch AgentReducer.reduce(.initial, event: event) {
        case let .success(state):
            return state
        case let .failure(failure):
            throw AgentStoreError.reducerRejected(
                runID: metadata.runID,
                sequence: envelope.writerSequence,
                failure: failure
            )
        }
    }

    /// Validates one new event against the durable ledger. The caller must run
    /// duplicate/idempotency checks first so a retry of an older commit remains
    /// a successful no-op instead of appearing non-monotonic.
    public static func validateAppend(
        _ envelope: AgentEventEnvelope,
        metadata: AgentRunMetadataRecord,
        existingRecords: [StoredAgentEvent]
    ) throws -> AgentRunState {
        try validateEnvelope(envelope)
        guard envelope.runID == metadata.runID else {
            throw AgentStoreError.runNotFound(envelope.runID)
        }
        guard envelope.writerID == metadata.writerID else {
            throw AgentStoreError.writerMismatch(
                runID: metadata.runID,
                expected: metadata.writerID,
                actual: envelope.writerID
            )
        }

        let current = try AgentJournalReplay.replay(
            existingRecords,
            metadata: metadata
        )
        guard let expected = current.lastSequence?.successor else {
            throw AgentStoreError.sequenceExhausted(
                runID: metadata.runID,
                writerID: metadata.writerID
            )
        }
        guard envelope.writerSequence == expected else {
            throw AgentStoreError.nonMonotonicSequence(
                runID: metadata.runID,
                writerID: metadata.writerID,
                expected: expected,
                actual: envelope.writerSequence
            )
        }

        switch AgentReducer.reduce(current, event: envelope.event) {
        case let .success(next):
            return next
        case let .failure(failure):
            throw AgentStoreError.reducerRejected(
                runID: metadata.runID,
                sequence: envelope.writerSequence,
                failure: failure
            )
        }
    }
}

/// Pure reducer-backed journal reconstruction. It fails closed on malformed
/// order, mixed runs/writers, envelope corruption, or semantic transitions.
public enum AgentJournalReplay {
    public static func replay(
        _ records: [StoredAgentEvent],
        metadata: AgentRunMetadataRecord? = nil
    ) throws -> AgentRunState {
        guard let first = records.first else {
            if let metadata {
                throw AgentStoreError.corruptJournal(
                    runID: metadata.runID,
                    reason: .emptyLedger
                )
            }
            throw AgentStoreError.emptyJournal
        }

        let runID = first.runID
        let expectedWriter = metadata?.writerID ?? first.envelope.writerID
        if let metadata, metadata.runID != runID {
            throw AgentStoreError.corruptJournal(
                runID: runID,
                reason: .metadataContextMismatch
            )
        }

        let canonicalWriter = AgentEventWriterID(runID: runID)
        guard expectedWriter == canonicalWriter else {
            throw AgentStoreError.corruptJournal(
                runID: runID,
                reason: .writerMismatch(
                    expected: canonicalWriter,
                    actual: expectedWriter
                )
            )
        }

        if let metadata {
            do {
                _ = try AgentJournalValidation.validateAcceptance(
                    AgentRunAcceptance(
                        metadata: metadata,
                        envelope: first.envelope
                    )
                )
            } catch let AgentStoreError.invalidAcceptance(failure) {
                throw AgentStoreError.corruptJournal(
                    runID: runID,
                    reason: .invalidAcceptance(failure)
                )
            } catch let AgentStoreError.invalidEnvelope(failure) {
                throw AgentStoreError.corruptJournal(
                    runID: runID,
                    reason: .invalidEnvelope(failure)
                )
            } catch let AgentStoreError.reducerRejected(_, sequence, failure) {
                throw AgentStoreError.corruptJournal(
                    runID: runID,
                    reason: .reducerRejected(
                        sequence: sequence,
                        failure: failure
                    )
                )
            }
        }

        var state = AgentRunState.initial
        var previousOffset: AgentJournalOffset?

        for record in records {
            guard record.offset > .origin else {
                throw AgentStoreError.corruptJournal(
                    runID: runID,
                    reason: .invalidOffset(record.offset)
                )
            }
            if let previousOffset, record.offset <= previousOffset {
                throw AgentStoreError.corruptJournal(
                    runID: runID,
                    reason: .nonMonotonicOffset(
                        previous: previousOffset,
                        actual: record.offset
                    )
                )
            }
            previousOffset = record.offset

            guard record.runID == runID else {
                throw AgentStoreError.corruptJournal(
                    runID: runID,
                    reason: .runMismatch(expected: runID, actual: record.runID)
                )
            }
            guard record.envelope.writerID == expectedWriter else {
                throw AgentStoreError.corruptJournal(
                    runID: runID,
                    reason: .writerMismatch(
                        expected: expectedWriter,
                        actual: record.envelope.writerID
                    )
                )
            }
            do {
                try AgentJournalValidation.validateEnvelope(record.envelope)
            } catch let AgentStoreError.invalidEnvelope(failure) {
                throw AgentStoreError.corruptJournal(
                    runID: runID,
                    reason: .invalidEnvelope(failure)
                )
            }

            switch AgentReducer.reduce(state, event: record.event) {
            case let .success(next):
                state = next
            case let .failure(failure):
                throw AgentStoreError.corruptJournal(
                    runID: runID,
                    reason: .reducerRejected(
                        sequence: record.envelope.writerSequence,
                        failure: failure
                    )
                )
            }
        }

        if let metadata, state.context != metadata.context {
            throw AgentStoreError.corruptJournal(
                runID: runID,
                reason: .metadataContextMismatch
            )
        }
        return state
    }
}

public struct RecoveredAgentRun: Equatable, Sendable {
    public let metadata: AgentRunMetadataRecord
    public let state: AgentRunState
    public let eventCount: Int
    public let lastOffset: AgentJournalOffset

    public init(
        metadata: AgentRunMetadataRecord,
        state: AgentRunState,
        eventCount: Int,
        lastOffset: AgentJournalOffset
    ) {
        self.metadata = metadata
        self.state = state
        self.eventCount = eventCount
        self.lastOffset = lastOffset
    }
}

/// Read-only recovery service. It never starts provider/tool work; callers can
/// make an explicit resume/inspection decision from the reconstructed state.
public struct AgentJournalRecovery: Sendable {
    private let store: any AgentEventReading

    public init(store: any AgentEventReading) {
        self.store = store
    }

    public func recover(_ runID: RunID) async throws -> RecoveredAgentRun? {
        var loadedMetadata = try await store.metadata(for: runID)
        var records = try await store.events(for: runID, after: nil)

        // Acceptance is atomic, but these are intentionally separate protocol
        // reads. If the commit lands between them, re-read the missing side
        // before diagnosing corruption. Returning nil when both first reads
        // predate the commit is safe; a later recovery pass will see the run.
        if loadedMetadata == nil, !records.isEmpty {
            loadedMetadata = try await store.metadata(for: runID)
        } else if loadedMetadata != nil, records.isEmpty {
            records = try await store.events(for: runID, after: nil)
        }

        guard let loadedMetadata else {
            guard records.isEmpty else {
                throw AgentStoreError.corruptJournal(
                    runID: runID,
                    reason: .metadataMissing
                )
            }
            return nil
        }
        guard let lastOffset = records.last?.offset else {
            throw AgentStoreError.corruptJournal(
                runID: runID,
                reason: .emptyLedger
            )
        }
        let state = try AgentJournalReplay.replay(
            records,
            metadata: loadedMetadata
        )
        return RecoveredAgentRun(
            metadata: loadedMetadata,
            state: state,
            eventCount: records.count,
            lastOffset: lastOffset
        )
    }
}

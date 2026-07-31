import AgentDomain
import Foundation

public enum InMemoryAgentStoreFaultPoint: String, Codable, Hashable, Sendable {
    /// Fails after acceptance validation/staging but before metadata or event
    /// state changes become visible.
    case acceptanceSave
    /// Fails after append validation/staging but before the event is visible.
    case appendSave
    /// Fails after cursor validation/staging but before the cursor is visible.
    case projectionCursorSave
}

/// Codable image of committed state only. Constructing a new journal from an
/// image models process death/relaunch without carrying volatile actor state or
/// fault schedules across the boundary.
public struct InMemoryAgentEventJournalSnapshot: Codable, Equatable, Sendable {
    public let metadata: [AgentRunMetadataRecord]
    public let records: [StoredAgentEvent]
    public let cursors: [AgentProjectionCursor]
    public let highWaterMark: AgentJournalOffset

    public init(
        metadata: [AgentRunMetadataRecord],
        records: [StoredAgentEvent],
        cursors: [AgentProjectionCursor],
        highWaterMark: AgentJournalOffset
    ) {
        self.metadata = metadata
        self.records = records
        self.cursors = cursors
        self.highWaterMark = highWaterMark
    }
}

/// Deterministic reference implementation for contract and fault tests.
/// Production code should use a persistent adapter with the same transaction
/// boundaries; this actor intentionally exposes no delete/update event APIs.
public actor InMemoryAgentEventJournal: AgentEventJournal {
    private var metadataByRunID: [RunID: AgentRunMetadataRecord]
    private var committedRecords: [StoredAgentEvent]
    private var cursorByProjectionID: [AgentProjectionID: AgentProjectionCursor]
    private var highWaterMark: AgentJournalOffset
    private var injectedFaults: [InMemoryAgentStoreFaultPoint: [String]] = [:]
    private let clock: @Sendable () -> AgentInstant

    public init(
        clock: @escaping @Sendable () -> AgentInstant = {
            AgentInstant(Date())
        }
    ) {
        metadataByRunID = [:]
        committedRecords = []
        cursorByProjectionID = [:]
        highWaterMark = .origin
        self.clock = clock
    }

    public init(
        restoring snapshot: InMemoryAgentEventJournalSnapshot,
        clock: @escaping @Sendable () -> AgentInstant = {
            AgentInstant(Date())
        }
    ) throws {
        try Self.validate(snapshot)
        metadataByRunID = Dictionary(
            uniqueKeysWithValues: snapshot.metadata.map { ($0.runID, $0) }
        )
        committedRecords = snapshot.records
        cursorByProjectionID = Dictionary(
            uniqueKeysWithValues: snapshot.cursors.map { ($0.projectionID, $0) }
        )
        highWaterMark = snapshot.highWaterMark
        self.clock = clock
    }

    /// Injects a bounded failure. Multiple calls queue failures FIFO.
    public func failNext(
        _ point: InMemoryAgentStoreFaultPoint,
        code: String = "injected_failure"
    ) {
        injectedFaults[point, default: []].append(code)
    }

    public func durableSnapshot() -> InMemoryAgentEventJournalSnapshot {
        InMemoryAgentEventJournalSnapshot(
            metadata: metadataByRunID.values.sorted {
                $0.runID.description < $1.runID.description
            },
            records: committedRecords,
            cursors: cursorByProjectionID.values.sorted {
                $0.projectionID.rawValue < $1.projectionID.rawValue
            },
            highWaterMark: highWaterMark
        )
    }

    public func accept(
        _ acceptance: AgentRunAcceptance
    ) async throws -> AgentJournalCommit {
        _ = try AgentJournalValidation.validateAcceptance(acceptance)

        let metadata = acceptance.metadata
        let envelope = acceptance.envelope

        if let existingMetadata = metadataByRunID[metadata.runID] {
            guard existingMetadata == metadata,
                  let existing = committedRecords.first(where: {
                      $0.runID == metadata.runID &&
                          $0.envelope.writerSequence == .first
                  }),
                  existing.envelope == envelope
            else {
                throw AgentStoreError.runConflict(metadata.runID)
            }
            return AgentJournalCommit(
                disposition: .alreadyCommitted,
                record: existing
            )
        }

        if let existingMetadata = metadataByRunID.values.first(where: {
            $0.acceptanceCommandID == metadata.acceptanceCommandID
        }) {
            throw AgentStoreError.acceptanceCommandConflict(
                commandID: metadata.acceptanceCommandID,
                existingRunID: existingMetadata.runID,
                incomingRunID: metadata.runID
            )
        }

        try validateNoDuplicate(for: envelope)
        let offset = try nextJournalOffset()
        let staged = StoredAgentEvent(
            offset: offset,
            committedAt: clock(),
            envelope: envelope
        )

        // This is the simulated durable-save boundary. Both assignments below
        // occur only if it succeeds and have no suspension points between them.
        try consumeFault(at: .acceptanceSave, operation: .acceptRun)
        metadataByRunID[metadata.runID] = metadata
        committedRecords.append(staged)
        highWaterMark = offset

        return AgentJournalCommit(disposition: .committed, record: staged)
    }

    public func append(
        _ envelope: AgentEventEnvelope
    ) async throws -> AgentJournalCommit {
        try AgentJournalValidation.validateEnvelope(envelope)
        guard let metadata = metadataByRunID[envelope.runID] else {
            throw AgentStoreError.runNotFound(envelope.runID)
        }
        guard envelope.writerID == metadata.writerID else {
            throw AgentStoreError.writerMismatch(
                runID: envelope.runID,
                expected: metadata.writerID,
                actual: envelope.writerID
            )
        }

        if let existing = idempotencyRecord(for: envelope) {
            guard existing.envelope == envelope else {
                throw AgentStoreError.idempotencyConflict(
                    runID: envelope.runID,
                    writerID: envelope.writerID,
                    key: envelope.idempotencyKey,
                    existingEventID: existing.event.header.eventID,
                    incomingEventID: envelope.event.header.eventID
                )
            }
            return AgentJournalCommit(
                disposition: .alreadyCommitted,
                record: existing
            )
        }

        try validateNoDuplicate(for: envelope)
        let runRecords = committedRecords.filter { $0.runID == envelope.runID }
        _ = try AgentJournalValidation.validateAppend(
            envelope,
            metadata: metadata,
            existingRecords: runRecords
        )

        let offset = try nextJournalOffset()
        let staged = StoredAgentEvent(
            offset: offset,
            committedAt: clock(),
            envelope: envelope
        )

        try consumeFault(at: .appendSave, operation: .appendEvent)
        committedRecords.append(staged)
        highWaterMark = offset

        return AgentJournalCommit(disposition: .committed, record: staged)
    }

    public func metadata(
        for runID: RunID
    ) async throws -> AgentRunMetadataRecord? {
        metadataByRunID[runID]
    }

    public func events(
        for runID: RunID,
        after sequence: EventSequence?
    ) async throws -> [StoredAgentEvent] {
        committedRecords.filter { record in
            guard record.runID == runID else { return false }
            guard let sequence else { return true }
            return record.envelope.writerSequence > sequence
        }
    }

    public func projectionBatch(
        after offset: AgentJournalOffset,
        limit: Int
    ) async throws -> AgentProjectionBatch {
        guard limit > 0 else {
            throw AgentStoreError.invalidBatchLimit(limit)
        }
        guard offset <= highWaterMark else {
            throw AgentStoreError.offsetBeyondHighWaterMark(
                requested: offset,
                highWaterMark: highWaterMark
            )
        }
        let records = Array(
            committedRecords.lazy
                .filter { $0.offset > offset }
                .prefix(limit)
        )
        return AgentProjectionBatch(
            afterOffset: offset,
            highWaterMark: highWaterMark,
            records: records
        )
    }

    public func loadCursor(
        for projectionID: AgentProjectionID
    ) async throws -> AgentProjectionCursor? {
        try validate(projectionID)
        return cursorByProjectionID[projectionID]
    }

    public func saveCursor(
        _ cursor: AgentProjectionCursor,
        expectedPreviousOffset: AgentJournalOffset
    ) async throws -> AgentProjectionCursorCommit {
        try validate(cursor.projectionID)
        guard cursor.throughOffset <= highWaterMark else {
            throw AgentStoreError.cursorBeyondHighWaterMark(
                projectionID: cursor.projectionID,
                requested: cursor.throughOffset,
                highWaterMark: highWaterMark
            )
        }

        let existing = cursorByProjectionID[cursor.projectionID]
        let actualPrevious = existing?.throughOffset ?? .origin
        guard actualPrevious == expectedPreviousOffset else {
            throw AgentStoreError.cursorConflict(
                projectionID: cursor.projectionID,
                expected: expectedPreviousOffset,
                actual: actualPrevious
            )
        }
        if let existing, existing.throughOffset == cursor.throughOffset {
            return AgentProjectionCursorCommit(
                disposition: .alreadyCommitted,
                cursor: existing
            )
        }
        guard cursor.throughOffset >= actualPrevious else {
            throw AgentStoreError.cursorRegression(
                projectionID: cursor.projectionID,
                current: actualPrevious,
                requested: cursor.throughOffset
            )
        }

        try consumeFault(
            at: .projectionCursorSave,
            operation: .saveProjectionCursor
        )
        cursorByProjectionID[cursor.projectionID] = cursor
        return AgentProjectionCursorCommit(
            disposition: .committed,
            cursor: cursor
        )
    }

    private func idempotencyRecord(
        for envelope: AgentEventEnvelope
    ) -> StoredAgentEvent? {
        committedRecords.first {
            $0.runID == envelope.runID &&
                $0.envelope.writerID == envelope.writerID &&
                $0.envelope.idempotencyKey == envelope.idempotencyKey
        }
    }

    private func validateNoDuplicate(
        for envelope: AgentEventEnvelope
    ) throws {
        if let existing = idempotencyRecord(for: envelope) {
            throw AgentStoreError.idempotencyConflict(
                runID: envelope.runID,
                writerID: envelope.writerID,
                key: envelope.idempotencyKey,
                existingEventID: existing.event.header.eventID,
                incomingEventID: envelope.event.header.eventID
            )
        }
        if let existing = committedRecords.first(where: {
            $0.event.header.eventID == envelope.event.header.eventID
        }) {
            throw AgentStoreError.eventIDConflict(
                eventID: envelope.event.header.eventID,
                existingRunID: existing.runID,
                incomingRunID: envelope.runID
            )
        }
        if let existing = committedRecords.first(where: {
            $0.runID == envelope.runID &&
                $0.envelope.writerID == envelope.writerID &&
                $0.envelope.writerSequence == envelope.writerSequence
        }) {
            throw AgentStoreError.sequenceConflict(
                runID: envelope.runID,
                sequence: envelope.writerSequence,
                existingEventID: existing.event.header.eventID,
                incomingEventID: envelope.event.header.eventID
            )
        }
    }

    private func nextJournalOffset() throws -> AgentJournalOffset {
        guard let next = highWaterMark.successor else {
            throw AgentStoreError.journalOffsetExhausted
        }
        return next
    }

    private func consumeFault(
        at point: InMemoryAgentStoreFaultPoint,
        operation: AgentStoreOperation
    ) throws {
        guard var queued = injectedFaults[point], !queued.isEmpty else {
            return
        }
        let code = queued.removeFirst()
        injectedFaults[point] = queued
        throw AgentStoreError.persistenceFailure(
            operation: operation,
            code: code
        )
    }

    private func validate(_ projectionID: AgentProjectionID) throws {
        guard !projectionID.rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw AgentStoreError.invalidProjectionID
        }
    }

    private static func validate(
        _ snapshot: InMemoryAgentEventJournalSnapshot
    ) throws {
        var metadataByRunID: [RunID: AgentRunMetadataRecord] = [:]
        var runIDByAcceptanceCommand: [CommandID: RunID] = [:]
        for metadata in snapshot.metadata {
            guard metadataByRunID.updateValue(metadata, forKey: metadata.runID) == nil else {
                throw AgentStoreError.runConflict(metadata.runID)
            }
            if runIDByAcceptanceCommand.updateValue(
                metadata.runID,
                forKey: metadata.acceptanceCommandID
            ) != nil {
                throw AgentStoreError.corruptJournal(
                    runID: metadata.runID,
                    reason: .duplicateAcceptanceCommand(
                        metadata.acceptanceCommandID
                    )
                )
            }
        }

        var expectedOffset = AgentJournalOffset.origin
        for record in snapshot.records {
            guard let next = expectedOffset.successor,
                  record.offset == next
            else {
                throw AgentStoreError.persistenceFailure(
                    operation: .restoreSnapshot,
                    code: "non_contiguous_offsets"
                )
            }
            expectedOffset = record.offset
        }
        guard expectedOffset == snapshot.highWaterMark else {
            throw AgentStoreError.persistenceFailure(
                operation: .restoreSnapshot,
                code: "invalid_high_water_mark"
            )
        }

        var eventIDs = Set<EventID>()
        var idempotencyKeys = Set<SnapshotIdempotencyKey>()
        for record in snapshot.records {
            guard eventIDs.insert(record.event.header.eventID).inserted else {
                throw AgentStoreError.corruptJournal(
                    runID: record.runID,
                    reason: .duplicateEventID(record.event.header.eventID)
                )
            }
            let key = SnapshotIdempotencyKey(
                runID: record.runID,
                writerID: record.envelope.writerID,
                value: record.envelope.idempotencyKey
            )
            guard idempotencyKeys.insert(key).inserted else {
                throw AgentStoreError.corruptJournal(
                    runID: record.runID,
                    reason: .duplicateIdempotencyKey(
                        writerID: record.envelope.writerID,
                        key: record.envelope.idempotencyKey
                    )
                )
            }
        }

        let recordsByRunID = Dictionary(grouping: snapshot.records, by: \.runID)
        for (runID, records) in recordsByRunID {
            guard let metadata = metadataByRunID[runID] else {
                throw AgentStoreError.corruptJournal(
                    runID: runID,
                    reason: .metadataMissing
                )
            }
            _ = try AgentJournalReplay.replay(records, metadata: metadata)
        }
        for (runID, _) in metadataByRunID where recordsByRunID[runID] == nil {
            throw AgentStoreError.corruptJournal(
                runID: runID,
                reason: .emptyLedger
            )
        }

        var cursorIDs = Set<AgentProjectionID>()
        for cursor in snapshot.cursors {
            guard !cursor.projectionID.rawValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw AgentStoreError.invalidProjectionID
            }
            guard cursorIDs.insert(cursor.projectionID).inserted else {
                throw AgentStoreError.persistenceFailure(
                    operation: .restoreSnapshot,
                    code: "duplicate_projection_cursor"
                )
            }
            guard cursor.throughOffset <= snapshot.highWaterMark else {
                throw AgentStoreError.cursorBeyondHighWaterMark(
                    projectionID: cursor.projectionID,
                    requested: cursor.throughOffset,
                    highWaterMark: snapshot.highWaterMark
                )
            }
        }
    }
}

private struct SnapshotIdempotencyKey: Hashable {
    let runID: RunID
    let writerID: AgentEventWriterID
    let value: String
}

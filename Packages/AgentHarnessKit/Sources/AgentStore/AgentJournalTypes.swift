import AgentDomain
import AgentReducerCore
import Foundation

/// Stable identity of the sole canonical event writer assigned to a run.
///
/// Writer identity is intentionally separate from an event ID. It scopes the
/// append sequence and idempotency namespace. Its canonical value is scoped
/// to the accepted run, while execution-node ownership remains in run context.
public struct AgentEventWriterID:
    RawRepresentable,
    Codable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Canonical run-scoped writer identity. Reusing an execution node for
    /// another run cannot collide at writer sequence one.
    public init(runID: RunID) {
        self.init(rawValue: runID.rawValue)
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

/// Monotonic, store-wide position assigned only when an event commit succeeds.
public struct AgentJournalOffset:
    RawRepresentable,
    Codable,
    Hashable,
    Sendable,
    Comparable
{
    public static let origin = AgentJournalOffset(rawValue: 0)

    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var successor: Self? {
        guard rawValue < UInt64.max else { return nil }
        return Self(rawValue: rawValue + 1)
    }
}

/// Canonical append unit. `writerSequence` and the embedded event sequence
/// must agree; keeping both fields makes the durable writer contract explicit
/// and lets stores index headers without decoding event payloads.
public struct AgentEventEnvelope: Codable, Equatable, Sendable {
    public let writerID: AgentEventWriterID
    public let writerSequence: EventSequence
    public let idempotencyKey: String
    public let event: AgentEvent

    public init(
        writerID: AgentEventWriterID,
        writerSequence: EventSequence,
        idempotencyKey: String,
        event: AgentEvent
    ) {
        self.writerID = writerID
        self.writerSequence = writerSequence
        self.idempotencyKey = idempotencyKey
        self.event = event
    }

    public var runID: RunID { event.header.runID }
}

/// Companion metadata committed atomically with a run's `runAccepted` event.
/// The full context remains immutable for the lifetime of the run.
public struct AgentRunMetadataRecord: Codable, Equatable, Sendable {
    public let context: AgentRunContext
    public let acceptedEngineVersion: EngineVersion
    public let writerID: AgentEventWriterID
    public let acceptanceCommandID: CommandID
    public let acceptanceEventID: EventID

    public init(
        context: AgentRunContext,
        acceptedEngineVersion: EngineVersion? = nil,
        writerID: AgentEventWriterID,
        acceptanceCommandID: CommandID,
        acceptanceEventID: EventID
    ) {
        self.context = context
        self.acceptedEngineVersion = acceptedEngineVersion ?? context.engineVersion
        self.writerID = writerID
        self.acceptanceCommandID = acceptanceCommandID
        self.acceptanceEventID = acceptanceEventID
    }

    private enum CodingKeys: String, CodingKey {
        case context
        case acceptedEngineVersion
        case writerID
        case acceptanceCommandID
        case acceptanceEventID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let context = try container.decode(AgentRunContext.self, forKey: .context)
        let acceptedEngineVersion: EngineVersion
        if context.schemaVersion >= .v1_1 {
            acceptedEngineVersion = try container.decode(
                EngineVersion.self,
                forKey: .acceptedEngineVersion
            )
        } else {
            acceptedEngineVersion = try container.decodeIfPresent(
                EngineVersion.self,
                forKey: .acceptedEngineVersion
            ) ?? context.engineVersion
        }
        self.init(
            context: context,
            acceptedEngineVersion: acceptedEngineVersion,
            writerID: try container.decode(AgentEventWriterID.self, forKey: .writerID),
            acceptanceCommandID: try container.decode(
                CommandID.self,
                forKey: .acceptanceCommandID
            ),
            acceptanceEventID: try container.decode(
                EventID.self,
                forKey: .acceptanceEventID
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(context, forKey: .context)
        if context.schemaVersion >= .v1_1 {
            try container.encode(acceptedEngineVersion, forKey: .acceptedEngineVersion)
        }
        try container.encode(writerID, forKey: .writerID)
        try container.encode(acceptanceCommandID, forKey: .acceptanceCommandID)
        try container.encode(acceptanceEventID, forKey: .acceptanceEventID)
    }

    public var runID: RunID { context.lineage.runID }
}

/// All canonical V2 records that must become durable in one acceptance save.
/// An app adapter may join legacy message/run rows to the same transaction.
public struct AgentRunAcceptance: Codable, Equatable, Sendable {
    public let metadata: AgentRunMetadataRecord
    public let envelope: AgentEventEnvelope

    public init(
        metadata: AgentRunMetadataRecord,
        envelope: AgentEventEnvelope
    ) {
        self.metadata = metadata
        self.envelope = envelope
    }
}

/// Event plus the commit facts assigned by the durable store.
public struct StoredAgentEvent: Codable, Equatable, Sendable {
    public let offset: AgentJournalOffset
    public let committedAt: AgentInstant
    public let envelope: AgentEventEnvelope

    public init(
        offset: AgentJournalOffset,
        committedAt: AgentInstant,
        envelope: AgentEventEnvelope
    ) {
        self.offset = offset
        self.committedAt = committedAt
        self.envelope = envelope
    }

    public var event: AgentEvent { envelope.event }
    public var runID: RunID { envelope.runID }
}

public enum AgentJournalCommitDisposition: String, Codable, Hashable, Sendable {
    /// This call created the durable record.
    case committed
    /// An identical request was already durable; no new record was written.
    case alreadyCommitted
}

public struct AgentJournalCommit: Codable, Equatable, Sendable {
    public let disposition: AgentJournalCommitDisposition
    public let record: StoredAgentEvent

    public init(
        disposition: AgentJournalCommitDisposition,
        record: StoredAgentEvent
    ) {
        self.disposition = disposition
        self.record = record
    }
}

public struct AgentProjectionID:
    RawRepresentable,
    Codable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Durable global replay cursor for one named projection.
public struct AgentProjectionCursor: Codable, Equatable, Sendable {
    public let projectionID: AgentProjectionID
    public let throughOffset: AgentJournalOffset
    public let updatedAt: AgentInstant

    public init(
        projectionID: AgentProjectionID,
        throughOffset: AgentJournalOffset,
        updatedAt: AgentInstant
    ) {
        self.projectionID = projectionID
        self.throughOffset = throughOffset
        self.updatedAt = updatedAt
    }
}

public enum AgentProjectionCursorCommitDisposition: String, Codable, Hashable, Sendable {
    case committed
    case alreadyCommitted
}

public struct AgentProjectionCursorCommit: Codable, Equatable, Sendable {
    public let disposition: AgentProjectionCursorCommitDisposition
    public let cursor: AgentProjectionCursor

    public init(
        disposition: AgentProjectionCursorCommitDisposition,
        cursor: AgentProjectionCursor
    ) {
        self.disposition = disposition
        self.cursor = cursor
    }
}

/// One bounded, stable view of journal work available to a projector.
public struct AgentProjectionBatch: Codable, Equatable, Sendable {
    public let afterOffset: AgentJournalOffset
    public let highWaterMark: AgentJournalOffset
    public let records: [StoredAgentEvent]

    public init(
        afterOffset: AgentJournalOffset,
        highWaterMark: AgentJournalOffset,
        records: [StoredAgentEvent]
    ) {
        self.afterOffset = afterOffset
        self.highWaterMark = highWaterMark
        self.records = records
    }

    public var throughOffset: AgentJournalOffset {
        records.last?.offset ?? afterOffset
    }

    public var hasMore: Bool { throughOffset < highWaterMark }
}

public enum AgentStoreOperation: String, Codable, Hashable, Sendable {
    case acceptRun
    case appendEvent
    case readMetadata
    case readEvents
    case readProjection
    case loadProjectionCursor
    case saveProjectionCursor
    case restoreSnapshot
}

public enum AgentAcceptanceValidationFailure: Error, Equatable, Sendable {
    case metadataRunMismatch
    case metadataWriterMismatch
    case metadataEventMismatch
    case metadataEngineVersionMismatch
    case runWriterMismatch
    case unexpectedPayload(AgentEventKind)
    case payloadContextMismatch
    case payloadEngineVersionMismatch
    case invalidFirstSequence(EventSequence)
}

public enum AgentEnvelopeValidationFailure: Error, Equatable, Sendable {
    case emptyIdempotencyKey
    case idempotencyKeyTooLong(actual: Int, maximum: Int)
    case writerEventSequenceMismatch(
        writerSequence: EventSequence,
        eventSequence: EventSequence
    )
}

public enum AgentJournalCorruption: Error, Equatable, Sendable {
    case emptyLedger
    case metadataMissing
    case metadataContextMismatch
    case invalidAcceptance(AgentAcceptanceValidationFailure)
    case invalidEnvelope(AgentEnvelopeValidationFailure)
    case invalidOffset(AgentJournalOffset)
    case duplicateEventID(EventID)
    case duplicateIdempotencyKey(
        writerID: AgentEventWriterID,
        key: String
    )
    case duplicateAcceptanceCommand(CommandID)
    case writerMismatch(expected: AgentEventWriterID, actual: AgentEventWriterID)
    case nonMonotonicOffset(previous: AgentJournalOffset, actual: AgentJournalOffset)
    case runMismatch(expected: RunID, actual: RunID)
    case reducerRejected(sequence: EventSequence, failure: AgentInvariantFailure)
}

/// Stable, inspectable failures shared by persistent and in-memory stores.
public enum AgentStoreError: Error, Equatable, Sendable {
    case emptyJournal
    case invalidAcceptance(AgentAcceptanceValidationFailure)
    case invalidEnvelope(AgentEnvelopeValidationFailure)
    case runNotFound(RunID)
    case runConflict(RunID)
    case acceptanceCommandConflict(
        commandID: CommandID,
        existingRunID: RunID,
        incomingRunID: RunID
    )
    case writerMismatch(
        runID: RunID,
        expected: AgentEventWriterID,
        actual: AgentEventWriterID
    )
    case sequenceExhausted(runID: RunID, writerID: AgentEventWriterID)
    case journalOffsetExhausted
    case nonMonotonicSequence(
        runID: RunID,
        writerID: AgentEventWriterID,
        expected: EventSequence,
        actual: EventSequence
    )
    case idempotencyConflict(
        runID: RunID,
        writerID: AgentEventWriterID,
        key: String,
        existingEventID: EventID,
        incomingEventID: EventID
    )
    case eventIDConflict(
        eventID: EventID,
        existingRunID: RunID,
        incomingRunID: RunID
    )
    case sequenceConflict(
        runID: RunID,
        sequence: EventSequence,
        existingEventID: EventID,
        incomingEventID: EventID
    )
    case reducerRejected(
        runID: RunID,
        sequence: EventSequence,
        failure: AgentInvariantFailure
    )
    case invalidProjectionID
    case invalidBatchLimit(Int)
    case offsetBeyondHighWaterMark(
        requested: AgentJournalOffset,
        highWaterMark: AgentJournalOffset
    )
    case cursorBeyondHighWaterMark(
        projectionID: AgentProjectionID,
        requested: AgentJournalOffset,
        highWaterMark: AgentJournalOffset
    )
    case cursorRegression(
        projectionID: AgentProjectionID,
        current: AgentJournalOffset,
        requested: AgentJournalOffset
    )
    case cursorConflict(
        projectionID: AgentProjectionID,
        expected: AgentJournalOffset,
        actual: AgentJournalOffset
    )
    case corruptJournal(runID: RunID, reason: AgentJournalCorruption)
    case persistenceFailure(operation: AgentStoreOperation, code: String)
}

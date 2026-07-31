import AgentDomain
import AgentStore
import Foundation

enum AgentAcceptedRunRecoveryScannerError: Error, Equatable, Sendable {
    case invalidConfiguration
    case inconsistentBatch
    case nonContiguousOffset(expected: AgentJournalOffset, actual: AgentJournalOffset)
    case eventLimitExceeded
    case runLimitExceeded
    case missingMetadata(RunID)
    case metadataRunMismatch(expected: RunID, actual: RunID)
}

protocol AgentAcceptedNonterminalRunScanning: Sendable {
    func acceptedNonterminalRunIDs() async throws -> [RunID]
}

struct AgentAcceptedRunRecoveryRecord: Equatable, Sendable {
    let runID: RunID
    let acceptanceOffset: AgentJournalOffset
    let state: AgentDomain.AgentRunState
}

/// Rich startup view used to reconcile durable ownership for both terminal
/// and nonterminal accepted runs before any engine is resumed.
protocol AgentAcceptedRunRecoveryScanning:
    AgentAcceptedNonterminalRunScanning,
    Sendable
{
    func acceptedRunRecoveryRecords() async throws -> [AgentAcceptedRunRecoveryRecord]
}

/// One actor-isolated, reducer-validated recovery snapshot. Production uses
/// this capability so startup does not revalidate the complete SwiftData
/// ledger once per page (or once per run metadata lookup).
struct AgentAcceptedRunRecoverySnapshot: Sendable {
    let batch: AgentProjectionBatch
    let metadataByRunID: [RunID: AgentRunMetadataRecord]
}

protocol AgentAcceptedRunRecoverySnapshotReading: AgentEventReading {
    func acceptedRunRecoverySnapshot(
        limit: Int
    ) async throws -> AgentAcceptedRunRecoverySnapshot
}

/// Global read-only capability over the production SwiftData journal. The
/// existing projected-run wrapper intentionally restricts metadata reads to
/// one run, so it must not be used for a process-wide recovery scan.
struct SwiftDataAgentRecoveryJournalReader:
    AgentAcceptedRunRecoverySnapshotReading,
    Sendable
{
    let store: SwiftDataAgentStore

    func metadata(for runID: RunID) async throws -> AgentRunMetadataRecord? {
        try await store.metadata(for: runID)
    }

    func events(
        for runID: RunID,
        after sequence: EventSequence?
    ) async throws -> [StoredAgentEvent] {
        try await store.events(for: runID, after: sequence)
    }

    func projectionBatch(
        after offset: AgentJournalOffset,
        limit: Int
    ) async throws -> AgentProjectionBatch {
        try await store.projectionBatch(after: offset, limit: limit)
    }

    func acceptedRunRecoverySnapshot(
        limit: Int
    ) async throws -> AgentAcceptedRunRecoverySnapshot {
        try await store.acceptedRunRecoverySnapshot(limit: limit)
    }
}

/// Stable FIFO recovery scan over one captured journal high-water mark.
///
/// `SwiftDataAgentStore.projectionBatch` already validates the complete
/// canonical ledger before returning. This scanner additionally pins the
/// first returned high-water mark, verifies global offset progress, replays
/// each accepted run prefix through the package reducer, and returns only the
/// runs that were nonterminal at that exact snapshot.
struct AgentAcceptedRunRecoveryScanner: AgentAcceptedRunRecoveryScanning {
    private let journal: any AgentEventReading
    private let maximumEventCount: Int
    private let maximumRunCount: Int

    init(
        journal: any AgentEventReading,
        batchSize: Int = 256,
        maximumEventCount: Int = 250_000,
        maximumRunCount: Int = 65_536
    ) throws {
        guard (1 ... 4_096).contains(batchSize),
              maximumEventCount > 0,
              maximumEventCount < Int.max,
              maximumRunCount > 0
        else { throw AgentAcceptedRunRecoveryScannerError.invalidConfiguration }
        self.journal = journal
        self.maximumEventCount = maximumEventCount
        self.maximumRunCount = maximumRunCount
    }

    init(
        swiftDataStore: SwiftDataAgentStore,
        batchSize: Int = 256,
        maximumEventCount: Int = 250_000,
        maximumRunCount: Int = 65_536
    ) throws {
        try self.init(
            journal: SwiftDataAgentRecoveryJournalReader(store: swiftDataStore),
            batchSize: batchSize,
            maximumEventCount: maximumEventCount,
            maximumRunCount: maximumRunCount
        )
    }

    func acceptedNonterminalRunIDs() async throws -> [RunID] {
        try await acceptedRunRecoveryRecords().compactMap { record in
            record.state.phase.isTerminal ? nil : record.runID
        }
    }

    func acceptedRunRecoveryRecords() async throws -> [AgentAcceptedRunRecoveryRecord] {
        // `batchSize` remains an initializer compatibility/validation input,
        // but recovery intentionally requests one bounded snapshot. The
        // SwiftData batch API validates the complete ledger on every call, so
        // pagination here would turn startup recovery quadratic.
        let requestedLimit = maximumEventCount + 1
        let snapshot: AgentAcceptedRunRecoverySnapshot?
        let batch: AgentProjectionBatch
        if let snapshotReader = journal as? any AgentAcceptedRunRecoverySnapshotReading {
            let loaded = try await snapshotReader.acceptedRunRecoverySnapshot(
                limit: requestedLimit
            )
            snapshot = loaded
            batch = loaded.batch
        } else {
            snapshot = nil
            batch = try await journal.projectionBatch(
                after: .origin,
                limit: requestedLimit
            )
        }

        guard batch.afterOffset == .origin else {
            throw AgentAcceptedRunRecoveryScannerError.inconsistentBatch
        }
        guard batch.records.count <= maximumEventCount,
              batch.highWaterMark.rawValue <= UInt64(maximumEventCount)
        else {
            throw AgentAcceptedRunRecoveryScannerError.eventLimitExceeded
        }
        var cursor = AgentJournalOffset.origin
        var recordsByRunID: [RunID: [StoredAgentEvent]] = [:]
        var acceptedFIFO: [RunID] = []

        for record in batch.records {
            guard let expected = cursor.successor else {
                throw AgentAcceptedRunRecoveryScannerError.eventLimitExceeded
            }
            guard record.offset == expected else {
                throw AgentAcceptedRunRecoveryScannerError.nonContiguousOffset(
                    expected: expected,
                    actual: record.offset
                )
            }
            cursor = record.offset
            if recordsByRunID[record.runID] == nil {
                guard acceptedFIFO.count < maximumRunCount else {
                    throw AgentAcceptedRunRecoveryScannerError.runLimitExceeded
                }
                guard case .runAccepted = record.event.payload else {
                    throw AgentAcceptedRunRecoveryScannerError.inconsistentBatch
                }
                acceptedFIFO.append(record.runID)
            }
            recordsByRunID[record.runID, default: []].append(record)
        }
        guard cursor == batch.highWaterMark else {
            throw AgentAcceptedRunRecoveryScannerError.inconsistentBatch
        }

        var result: [AgentAcceptedRunRecoveryRecord] = []
        result.reserveCapacity(acceptedFIFO.count)
        for runID in acceptedFIFO {
            let metadata: AgentRunMetadataRecord?
            if let snapshot {
                metadata = snapshot.metadataByRunID[runID]
            } else {
                metadata = try await journal.metadata(for: runID)
            }
            guard let metadata else {
                throw AgentAcceptedRunRecoveryScannerError.missingMetadata(runID)
            }
            guard metadata.runID == runID else {
                throw AgentAcceptedRunRecoveryScannerError.metadataRunMismatch(
                    expected: runID,
                    actual: metadata.runID
                )
            }
            let records = recordsByRunID[runID] ?? []
            let state = try AgentJournalReplay.replay(records, metadata: metadata)
            guard let acceptanceOffset = records.first?.offset else {
                throw AgentAcceptedRunRecoveryScannerError.inconsistentBatch
            }
            result.append(AgentAcceptedRunRecoveryRecord(
                runID: runID,
                acceptanceOffset: acceptanceOffset,
                state: state
            ))
        }
        return result
    }
}

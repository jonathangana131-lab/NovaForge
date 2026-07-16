import AgentDomain
import AgentEngine
import AgentStore
import Foundation

enum AgentRunRecoveryReconcilerError: Error, Equatable, Sendable {
    case leadershipUnavailable
    case duplicateJournalRunID(RunID)
    case duplicateIndexRunID(RunID)
    case unstableJournalFIFO(
        previous: AgentJournalOffset,
        actual: AgentJournalOffset
    )
    case invalidJournalState(RunID)
    case journalStateRunMismatch(expected: RunID, actual: RunID?)
    case missingTerminalEventID(RunID)
    case nonterminalHasTerminalEventID(RunID)
    case invalidIndexSnapshot
    case invalidIndexEntry(RunID)
    case indexTerminalWithoutAcceptedJournal(RunID)
    case indexedTerminalConflictsWithNonterminalJournal(RunID)
    case terminalRecordMismatch(RunID)
    case capacityExhausted(required: Int, remaining: Int)
    case durableCapacityExhausted(RunID)
    case unexpectedMutationResult(RunID)
    case postMutationVerificationUnavailable(RunID)
}

/// A process-lifetime recovery election lease.
///
/// A production implementation must keep a distinct fcntl descriptor locked
/// for this object's complete lifetime and must validate nofollow, hard-link,
/// ownership, permissions, and fd/path identity. The run-index transaction
/// lock is intentionally not accepted as evidence that an earlier owner died.
protocol AgentRecoveryLeadershipLease: AnyObject, Sendable {}

protocol AgentRecoveryLeadershipLeaseAcquiring: Sendable {
    func acquireProcessLifetimeLease() async throws
        -> any AgentRecoveryLeadershipLease
}

/// Explicit fail-closed fallback for unconfigured composition and tests.
/// Production uses the separate identity-checked lifetime lease acquirer.
struct UnavailableAgentRecoveryLeadershipLeaseAcquirer:
    AgentRecoveryLeadershipLeaseAcquiring,
    Sendable
{
    func acquireProcessLifetimeLease() async throws
        -> any AgentRecoveryLeadershipLease
    {
        throw AgentRunRecoveryReconcilerError.leadershipUnavailable
    }
}

/// Narrow bootstrap seam consumed by `AgentSystem`. The returned IDs contain
/// only accepted, nonterminal runs and retain journal acceptance FIFO.
protocol AgentRecoveryQueuePreparing: Sendable {
    func prepareRecoveryQueue() async throws -> [RunID]
}

/// Mockable durable-index capability used by startup reconciliation.
protocol AgentRunRecoveryIndexing: Sendable {
    func snapshot() async throws -> DurableAgentEngineRunIndexSnapshot

    func claim(
        runID: RunID,
        ownerID: UUID,
        mode: AgentEngineRunClaimMode
    ) async throws -> AgentEngineOwnerFence

    func abandonDurably(_ fence: AgentEngineOwnerFence) async throws
    func settle(_ record: AgentEngineTerminalRecord) async throws
}

extension DurableAgentEngineRunIndex: AgentRunRecoveryIndexing {}

/// Reconciles the journal's accepted-run FIFO with durable engine ownership
/// before `AgentSystem` constructs or resumes any package engine.
///
/// The retained leadership lease is the authority boundary for superseding a
/// prior process. Reconciliation itself never executes model or tool work.
actor AgentRunRecoveryReconciler: AgentRecoveryQueuePreparing {
    private let scanner: any AgentAcceptedRunRecoveryScanning
    private let index: any AgentRunRecoveryIndexing
    private let recoveryOwnerID: UUID
    private let leadershipLease: any AgentRecoveryLeadershipLease

    init(
        scanner: any AgentAcceptedRunRecoveryScanning,
        index: any AgentRunRecoveryIndexing,
        recoveryOwnerID: UUID,
        leadershipLease: any AgentRecoveryLeadershipLease
    ) {
        self.scanner = scanner
        self.index = index
        self.recoveryOwnerID = recoveryOwnerID
        self.leadershipLease = leadershipLease
    }

    func prepareRecoveryQueue() async throws -> [RunID] {
        // Accessing the retained object makes the lifetime dependency explicit:
        // the lease cannot be released while this reconciler remains injected.
        withExtendedLifetime(leadershipLease) {}

        let journalRecords = try await scanner.acceptedRunRecoveryRecords()
        let initialSnapshot = try await index.snapshot()
        let journal = try Self.validatedJournal(journalRecords)
        let initialIndex = try Self.validatedIndex(initialSnapshot)
        try Self.validateCrossStoreState(journal: journal, index: initialIndex)

        let missingJournalEntryCount = journalRecords.reduce(into: 0) {
            count, record in
            if initialIndex[record.runID] == nil { count += 1 }
        }
        guard missingJournalEntryCount
                <= initialSnapshot.capacity.remainingEntryCount
        else {
            throw AgentRunRecoveryReconcilerError.capacityExhausted(
                required: missingJournalEntryCount,
                remaining: initialSnapshot.capacity.remainingEntryCount
            )
        }

        let journalRunIDs = Set(journal.keys)
        for entry in initialSnapshot.entries where !journalRunIDs.contains(entry.runID) {
            if case .active = entry.state {
                try await abandonAcceptingCommittedThrow(entry.fence)
            }
        }

        var recoveryQueue: [RunID] = []
        recoveryQueue.reserveCapacity(journalRecords.count)
        for record in journalRecords {
            if record.state.phase.isTerminal {
                let terminalEventID = try Self.terminalEventID(for: record)
                try await reconcileTerminal(
                    record,
                    terminalEventID: terminalEventID,
                    indexed: initialIndex[record.runID]
                )
            } else {
                recoveryQueue.append(record.runID)
            }
        }

        let finalSnapshot = try await index.snapshot()
        let finalIndex = try Self.validatedIndex(finalSnapshot)
        try Self.validateFinalState(
            journalRecords: journalRecords,
            initialIndex: initialIndex,
            finalIndex: finalIndex
        )
        return recoveryQueue
    }

    private func reconcileTerminal(
        _ journal: AgentAcceptedRunRecoveryRecord,
        terminalEventID: EventID,
        indexed: DurableAgentEngineRunIndexEntrySnapshot?
    ) async throws {
        switch indexed?.state {
        case let .terminal(record):
            guard Self.matchesJournalTerminal(
                record,
                journal: journal,
                terminalEventID: terminalEventID
            ) else {
                throw AgentRunRecoveryReconcilerError.terminalRecordMismatch(
                    journal.runID
                )
            }
        case .active:
            guard let indexed else {
                throw AgentRunRecoveryReconcilerError.invalidIndexEntry(
                    journal.runID
                )
            }
            let terminal = AgentEngineTerminalRecord(
                runID: journal.runID,
                fence: indexed.fence,
                phase: journal.state.phase,
                terminalEventID: terminalEventID
            )
            try await settleAcceptingCommittedThrow(terminal)
        case .abandoned:
            guard let indexed else {
                throw AgentRunRecoveryReconcilerError.invalidIndexEntry(
                    journal.runID
                )
            }
            guard indexed.fence.generation < UInt64.max else {
                throw AgentEngineRunIndexError.generationExhausted(journal.runID)
            }
            let expectedFence = AgentEngineOwnerFence(
                runID: journal.runID,
                ownerID: recoveryOwnerID,
                generation: indexed.fence.generation + 1
            )
            let fence = try await claimAcceptingCommittedThrow(
                runID: journal.runID,
                expectedFence: expectedFence
            )
            try await settleAcceptingCommittedThrow(AgentEngineTerminalRecord(
                runID: journal.runID,
                fence: fence,
                phase: journal.state.phase,
                terminalEventID: terminalEventID
            ))
        case nil:
            let expectedFence = AgentEngineOwnerFence(
                runID: journal.runID,
                ownerID: recoveryOwnerID,
                generation: 1
            )
            let fence = try await claimAcceptingCommittedThrow(
                runID: journal.runID,
                expectedFence: expectedFence
            )
            try await settleAcceptingCommittedThrow(AgentEngineTerminalRecord(
                runID: journal.runID,
                fence: fence,
                phase: journal.state.phase,
                terminalEventID: terminalEventID
            ))
        }
    }

    private func abandonAcceptingCommittedThrow(
        _ fence: AgentEngineOwnerFence
    ) async throws {
        do {
            try await index.abandonDurably(fence)
        } catch {
            let snapshot = try await postMutationSnapshot(for: fence.runID)
            if let entry = snapshot[fence.runID],
               entry.fence == fence,
               entry.state == .abandoned
            {
                return
            }
            throw error
        }
    }

    private func claimAcceptingCommittedThrow(
        runID: RunID,
        expectedFence: AgentEngineOwnerFence
    ) async throws -> AgentEngineOwnerFence {
        let claimed: AgentEngineOwnerFence
        do {
            claimed = try await index.claim(
                runID: runID,
                ownerID: recoveryOwnerID,
                mode: .recovery
            )
        } catch {
            let snapshot = try await postMutationSnapshot(for: runID)
            if let entry = snapshot[runID],
               entry.fence == expectedFence,
               entry.state == .active
            {
                return expectedFence
            }
            if case DurableAgentEngineRunIndexError.capacityExceeded = error {
                throw AgentRunRecoveryReconcilerError
                    .durableCapacityExhausted(runID)
            }
            throw error
        }
        guard claimed == expectedFence else {
            throw AgentRunRecoveryReconcilerError.unexpectedMutationResult(runID)
        }
        return claimed
    }

    private func settleAcceptingCommittedThrow(
        _ terminal: AgentEngineTerminalRecord
    ) async throws {
        do {
            try await index.settle(terminal)
        } catch {
            let snapshot = try await postMutationSnapshot(for: terminal.runID)
            if let entry = snapshot[terminal.runID],
               entry.fence == terminal.fence,
               entry.state == .terminal(terminal)
            {
                return
            }
            throw error
        }
    }

    private func postMutationSnapshot(
        for runID: RunID
    ) async throws -> [RunID: DurableAgentEngineRunIndexEntrySnapshot] {
        do {
            return try Self.validatedIndex(try await index.snapshot())
        } catch let error as AgentRunRecoveryReconcilerError {
            throw error
        } catch {
            throw AgentRunRecoveryReconcilerError
                .postMutationVerificationUnavailable(runID)
        }
    }

    private static func validatedJournal(
        _ records: [AgentAcceptedRunRecoveryRecord]
    ) throws -> [RunID: AgentAcceptedRunRecoveryRecord] {
        var result: [RunID: AgentAcceptedRunRecoveryRecord] = [:]
        var previousOffset = AgentJournalOffset.origin
        for record in records {
            guard record.acceptanceOffset > previousOffset else {
                throw AgentRunRecoveryReconcilerError.unstableJournalFIFO(
                    previous: previousOffset,
                    actual: record.acceptanceOffset
                )
            }
            previousOffset = record.acceptanceOffset
            guard result.updateValue(record, forKey: record.runID) == nil else {
                throw AgentRunRecoveryReconcilerError.duplicateJournalRunID(
                    record.runID
                )
            }
            guard record.state.phase != .uninitialized else {
                throw AgentRunRecoveryReconcilerError.invalidJournalState(
                    record.runID
                )
            }
            let actualRunID = record.state.context?.lineage.runID
            guard actualRunID == record.runID else {
                throw AgentRunRecoveryReconcilerError.journalStateRunMismatch(
                    expected: record.runID,
                    actual: actualRunID
                )
            }
            if record.state.phase.isTerminal {
                guard record.state.terminalEventID != nil else {
                    throw AgentRunRecoveryReconcilerError
                        .missingTerminalEventID(record.runID)
                }
            } else if record.state.terminalEventID != nil {
                throw AgentRunRecoveryReconcilerError
                    .nonterminalHasTerminalEventID(record.runID)
            }
        }
        return result
    }

    private static func validatedIndex(
        _ snapshot: DurableAgentEngineRunIndexSnapshot
    ) throws -> [RunID: DurableAgentEngineRunIndexEntrySnapshot] {
        guard snapshot.capacity.usedEntryCount == snapshot.entries.count,
              snapshot.capacity.maximumEntryCount >= snapshot.entries.count
        else {
            throw AgentRunRecoveryReconcilerError.invalidIndexSnapshot
        }
        var result: [RunID: DurableAgentEngineRunIndexEntrySnapshot] = [:]
        for entry in snapshot.entries {
            guard entry.runID == entry.fence.runID else {
                throw AgentRunRecoveryReconcilerError.invalidIndexEntry(
                    entry.runID
                )
            }
            if case let .terminal(terminal) = entry.state {
                guard terminal.runID == entry.runID,
                      terminal.fence == entry.fence,
                      terminal.phase.isTerminal
                else {
                    throw AgentRunRecoveryReconcilerError.invalidIndexEntry(
                        entry.runID
                    )
                }
            }
            guard result.updateValue(entry, forKey: entry.runID) == nil else {
                throw AgentRunRecoveryReconcilerError.duplicateIndexRunID(
                    entry.runID
                )
            }
        }
        return result
    }

    private static func validateCrossStoreState(
        journal: [RunID: AgentAcceptedRunRecoveryRecord],
        index: [RunID: DurableAgentEngineRunIndexEntrySnapshot]
    ) throws {
        for entry in index.values {
            guard let accepted = journal[entry.runID] else {
                if case .terminal = entry.state {
                    throw AgentRunRecoveryReconcilerError
                        .indexTerminalWithoutAcceptedJournal(entry.runID)
                }
                continue
            }

            if accepted.state.phase.isTerminal {
                let terminalEventID = try terminalEventID(for: accepted)
                if case let .terminal(terminal) = entry.state,
                   !matchesJournalTerminal(
                       terminal,
                       journal: accepted,
                       terminalEventID: terminalEventID
                   )
                {
                    throw AgentRunRecoveryReconcilerError
                        .terminalRecordMismatch(entry.runID)
                }
            } else if case .terminal = entry.state {
                throw AgentRunRecoveryReconcilerError
                    .indexedTerminalConflictsWithNonterminalJournal(entry.runID)
            }
        }
    }

    private static func validateFinalState(
        journalRecords: [AgentAcceptedRunRecoveryRecord],
        initialIndex: [RunID: DurableAgentEngineRunIndexEntrySnapshot],
        finalIndex: [RunID: DurableAgentEngineRunIndexEntrySnapshot]
    ) throws {
        let journalRunIDs = Set(journalRecords.map(\.runID))
        for initial in initialIndex.values where !journalRunIDs.contains(initial.runID) {
            if case .active = initial.state {
                guard let final = finalIndex[initial.runID],
                      final.fence == initial.fence,
                      final.state == .abandoned
                else {
                    throw AgentRunRecoveryReconcilerError
                        .unexpectedMutationResult(initial.runID)
                }
            }
        }

        for journal in journalRecords {
            if journal.state.phase.isTerminal {
                let terminalEventID = try terminalEventID(for: journal)
                guard let final = finalIndex[journal.runID],
                      case let .terminal(terminal) = final.state,
                      matchesJournalTerminal(
                          terminal,
                          journal: journal,
                          terminalEventID: terminalEventID
                      )
                else {
                    throw AgentRunRecoveryReconcilerError
                        .unexpectedMutationResult(journal.runID)
                }
            } else if let final = finalIndex[journal.runID],
                      case .terminal = final.state
            {
                throw AgentRunRecoveryReconcilerError
                    .indexedTerminalConflictsWithNonterminalJournal(journal.runID)
            }
        }
    }

    private static func terminalEventID(
        for record: AgentAcceptedRunRecoveryRecord
    ) throws -> EventID {
        guard record.state.phase.isTerminal,
              let terminalEventID = record.state.terminalEventID
        else {
            throw AgentRunRecoveryReconcilerError
                .missingTerminalEventID(record.runID)
        }
        return terminalEventID
    }

    private static func matchesJournalTerminal(
        _ terminal: AgentEngineTerminalRecord,
        journal: AgentAcceptedRunRecoveryRecord,
        terminalEventID: EventID
    ) -> Bool {
        terminal.runID == journal.runID
            && terminal.phase == journal.state.phase
            && terminal.terminalEventID == terminalEventID
    }
}

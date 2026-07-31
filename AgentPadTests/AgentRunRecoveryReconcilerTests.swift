import AgentDomain
import AgentEngine
import AgentStore
import Foundation
import XCTest
@testable import NovaForge

final class AgentRunRecoveryReconcilerTests: XCTestCase {
    func testMixedCrashWindowsReconcileInFIFOAndRepeatIdempotently() async throws {
        let nonterminalActive = recoveryReconcileRecord(
            seed: 1,
            offset: 1,
            phase: .running
        )
        let terminalActive = recoveryReconcileRecord(
            seed: 2,
            offset: 2,
            phase: .completed,
            terminalEventID: recoveryReconcileTagged(2_001)
        )
        let terminalAbandoned = recoveryReconcileRecord(
            seed: 3,
            offset: 3,
            phase: .failed,
            terminalEventID: recoveryReconcileTagged(3_001)
        )
        let terminalMissing = recoveryReconcileRecord(
            seed: 4,
            offset: 4,
            phase: .cancelled,
            terminalEventID: recoveryReconcileTagged(4_001)
        )
        let nonterminalMissing = recoveryReconcileRecord(
            seed: 5,
            offset: 5,
            phase: .awaitingApproval
        )
        let terminalExact = recoveryReconcileRecord(
            seed: 6,
            offset: 6,
            phase: .interrupted,
            terminalEventID: recoveryReconcileTagged(6_001)
        )
        let indexOnlyRunID: RunID = recoveryReconcileTagged(9_001)
        let indexOnlyFence = recoveryReconcileFence(
            runID: indexOnlyRunID,
            owner: 9_002,
            generation: 5
        )
        let activeFence = recoveryReconcileFence(
            runID: nonterminalActive.runID,
            owner: 101,
            generation: 1
        )
        let terminalActiveFence = recoveryReconcileFence(
            runID: terminalActive.runID,
            owner: 201,
            generation: 1
        )
        let terminalAbandonedFence = recoveryReconcileFence(
            runID: terminalAbandoned.runID,
            owner: 301,
            generation: 3
        )
        let terminalExactFence = recoveryReconcileFence(
            runID: terminalExact.runID,
            owner: 601,
            generation: 2
        )
        let exactTerminal = recoveryReconcileTerminal(
            terminalExact,
            fence: terminalExactFence
        )
        let index = RecoveryReconcileIndex(
            entries: [
                recoveryReconcileEntry(activeFence, state: .active),
                recoveryReconcileEntry(terminalActiveFence, state: .active),
                recoveryReconcileEntry(terminalAbandonedFence, state: .abandoned),
                recoveryReconcileEntry(
                    terminalExactFence,
                    state: .terminal(exactTerminal)
                ),
                recoveryReconcileEntry(indexOnlyFence, state: .active),
            ],
            maximumEntryCount: 10
        )
        let reconciler = AgentRunRecoveryReconciler(
            scanner: RecoveryReconcileScanner(records: [
                nonterminalActive,
                terminalActive,
                terminalAbandoned,
                terminalMissing,
                nonterminalMissing,
                terminalExact,
            ]),
            index: index,
            recoveryOwnerID: recoveryReconcileUUID(42),
            leadershipLease: RecoveryReconcileLeadershipLease()
        )

        let firstQueue = try await reconciler.prepareRecoveryQueue()
        let firstOperations = await index.operations()
        let secondQueue = try await reconciler.prepareRecoveryQueue()
        let secondOperations = await index.operations()
        let final = try await index.snapshot()
        let finalByRun = Dictionary(uniqueKeysWithValues: final.entries.map {
            ($0.runID, $0)
        })

        XCTAssertEqual(firstQueue, [nonterminalActive.runID, nonterminalMissing.runID])
        XCTAssertEqual(secondQueue, firstQueue)
        XCTAssertEqual(secondOperations, firstOperations)
        XCTAssertEqual(firstOperations, [
            .abandon(indexOnlyRunID),
            .settle(terminalActive.runID),
            .claim(terminalAbandoned.runID),
            .settle(terminalAbandoned.runID),
            .claim(terminalMissing.runID),
            .settle(terminalMissing.runID),
        ])
        XCTAssertEqual(finalByRun[indexOnlyRunID]?.state, .abandoned)
        XCTAssertEqual(
            finalByRun[terminalActive.runID]?.state,
            .terminal(recoveryReconcileTerminal(
                terminalActive,
                fence: terminalActiveFence
            ))
        )
        XCTAssertEqual(
            finalByRun[terminalAbandoned.runID]?.fence.generation,
            terminalAbandonedFence.generation + 1
        )
        XCTAssertEqual(
            finalByRun[terminalMissing.runID]?.fence.generation,
            1
        )
        XCTAssertNil(finalByRun[nonterminalMissing.runID])
        XCTAssertEqual(finalByRun[terminalExact.runID]?.state, .terminal(exactTerminal))
    }

    func testAllPostRenameMutatorThrowsAcceptExactCommittedState() async throws {
        let activeTerminal = recoveryReconcileRecord(
            seed: 10,
            offset: 1,
            phase: .completed,
            terminalEventID: recoveryReconcileTagged(10_001)
        )
        let abandonedTerminal = recoveryReconcileRecord(
            seed: 11,
            offset: 2,
            phase: .failed,
            terminalEventID: recoveryReconcileTagged(11_001)
        )
        let activeFence = recoveryReconcileFence(
            runID: activeTerminal.runID,
            owner: 10_101,
            generation: 2
        )
        let abandonedFence = recoveryReconcileFence(
            runID: abandonedTerminal.runID,
            owner: 11_101,
            generation: 4
        )
        let orphanRunID: RunID = recoveryReconcileTagged(12_001)
        let orphanFence = recoveryReconcileFence(
            runID: orphanRunID,
            owner: 12_101,
            generation: 1
        )
        let index = RecoveryReconcileIndex(
            entries: [
                recoveryReconcileEntry(activeFence, state: .active),
                recoveryReconcileEntry(abandonedFence, state: .abandoned),
                recoveryReconcileEntry(orphanFence, state: .active),
            ],
            faults: [
                .abandon(orphanRunID): .afterCommit,
                .settle(activeTerminal.runID): .afterCommit,
                .claim(abandonedTerminal.runID): .afterCommit,
                .settle(abandonedTerminal.runID): .afterCommit,
            ]
        )
        let reconciler = AgentRunRecoveryReconciler(
            scanner: RecoveryReconcileScanner(records: [
                activeTerminal,
                abandonedTerminal,
            ]),
            index: index,
            recoveryOwnerID: recoveryReconcileUUID(77),
            leadershipLease: RecoveryReconcileLeadershipLease()
        )

        let queue = try await reconciler.prepareRecoveryQueue()
        let snapshot = try await index.snapshot()
        let byRun = Dictionary(uniqueKeysWithValues: snapshot.entries.map {
            ($0.runID, $0)
        })

        XCTAssertEqual(queue, [])
        XCTAssertEqual(byRun[orphanRunID]?.state, .abandoned)
        XCTAssertEqual(
            byRun[activeTerminal.runID]?.state,
            .terminal(recoveryReconcileTerminal(activeTerminal, fence: activeFence))
        )
        XCTAssertEqual(
            byRun[abandonedTerminal.runID]?.fence.generation,
            abandonedFence.generation + 1
        )
        let snapshotReadCount = await index.snapshotReadCount()
        XCTAssertEqual(snapshotReadCount, 7)
    }

    func testPreCommitThrowFailsClosedWhenClaimPostconditionIsAbsent() async throws {
        let terminal = recoveryReconcileRecord(
            seed: 20,
            offset: 1,
            phase: .completed,
            terminalEventID: recoveryReconcileTagged(20_001)
        )
        let fence = recoveryReconcileFence(
            runID: terminal.runID,
            owner: 20_101,
            generation: 3
        )
        let index = RecoveryReconcileIndex(
            entries: [recoveryReconcileEntry(fence, state: .abandoned)],
            faults: [.claim(terminal.runID): .beforeCommit]
        )
        let reconciler = recoveryReconciler(records: [terminal], index: index)

        do {
            _ = try await reconciler.prepareRecoveryQueue()
            XCTFail("Pre-commit claim failure unexpectedly reconciled")
        } catch let error as RecoveryReconcileInjectedError {
            XCTAssertEqual(error, .claim(terminal.runID))
        }
        let remainingState = try await index.snapshot().entries.first?.state
        XCTAssertEqual(remainingState, .abandoned)
    }

    func testPostCommitThrowFailsClosedWhenVerificationCannotReadIndex() async throws {
        let terminal = recoveryReconcileRecord(
            seed: 21,
            offset: 1,
            phase: .completed,
            terminalEventID: recoveryReconcileTagged(21_001)
        )
        let fence = recoveryReconcileFence(
            runID: terminal.runID,
            owner: 21_101,
            generation: 2
        )
        let index = RecoveryReconcileIndex(
            entries: [recoveryReconcileEntry(fence, state: .abandoned)],
            faults: [.claim(terminal.runID): .afterCommitSnapshotUnavailable]
        )
        let reconciler = recoveryReconciler(records: [terminal], index: index)

        await assertRecoveryReconcileError(
            .postMutationVerificationUnavailable(terminal.runID)
        ) {
            try await reconciler.prepareRecoveryQueue()
        }
    }

    func testTerminalMismatchFailsBeforeAnyMutation() async throws {
        let terminal = recoveryReconcileRecord(
            seed: 30,
            offset: 1,
            phase: .completed,
            terminalEventID: recoveryReconcileTagged(30_001)
        )
        let fence = recoveryReconcileFence(
            runID: terminal.runID,
            owner: 30_101,
            generation: 1
        )
        let conflicting = AgentEngineTerminalRecord(
            runID: terminal.runID,
            fence: fence,
            phase: .completed,
            terminalEventID: recoveryReconcileTagged(30_002)
        )
        let index = RecoveryReconcileIndex(entries: [
            recoveryReconcileEntry(fence, state: .terminal(conflicting)),
        ])
        let reconciler = recoveryReconciler(records: [terminal], index: index)

        await assertRecoveryReconcileError(.terminalRecordMismatch(terminal.runID)) {
            try await reconciler.prepareRecoveryQueue()
        }
        let operations = await index.operations()
        XCTAssertEqual(operations, [])
    }

    func testIndexedTerminalCannotExistWithoutJournalAcceptance() async throws {
        let runID: RunID = recoveryReconcileTagged(31_001)
        let fence = recoveryReconcileFence(
            runID: runID,
            owner: 31_101,
            generation: 1
        )
        let terminal = AgentEngineTerminalRecord(
            runID: runID,
            fence: fence,
            phase: .cancelled,
            terminalEventID: recoveryReconcileTagged(31_102)
        )
        let index = RecoveryReconcileIndex(entries: [
            recoveryReconcileEntry(fence, state: .terminal(terminal)),
        ])
        let reconciler = recoveryReconciler(records: [], index: index)

        await assertRecoveryReconcileError(.indexTerminalWithoutAcceptedJournal(runID)) {
            try await reconciler.prepareRecoveryQueue()
        }
        let operations = await index.operations()
        XCTAssertEqual(operations, [])
    }

    func testNonterminalJournalCannotConflictWithIndexedTerminal() async throws {
        let record = recoveryReconcileRecord(
            seed: 32,
            offset: 1,
            phase: .running
        )
        let fence = recoveryReconcileFence(
            runID: record.runID,
            owner: 32_101,
            generation: 1
        )
        let terminal = AgentEngineTerminalRecord(
            runID: record.runID,
            fence: fence,
            phase: .completed,
            terminalEventID: recoveryReconcileTagged(32_102)
        )
        let index = RecoveryReconcileIndex(entries: [
            recoveryReconcileEntry(fence, state: .terminal(terminal)),
        ])
        let reconciler = recoveryReconciler(records: [record], index: index)

        await assertRecoveryReconcileError(
            .indexedTerminalConflictsWithNonterminalJournal(record.runID)
        ) {
            try await reconciler.prepareRecoveryQueue()
        }
        let operations = await index.operations()
        XCTAssertEqual(operations, [])
    }

    func testDuplicateAndUnstableJournalFIFOFailClosed() async throws {
        let first = recoveryReconcileRecord(seed: 40, offset: 1, phase: .accepted)
        let duplicate = AgentAcceptedRunRecoveryRecord(
            runID: first.runID,
            acceptanceOffset: AgentJournalOffset(rawValue: 2),
            state: first.state
        )
        let duplicateIndex = RecoveryReconcileIndex(entries: [])
        let duplicateReconciler = recoveryReconciler(
            records: [first, duplicate],
            index: duplicateIndex
        )
        await assertRecoveryReconcileError(.duplicateJournalRunID(first.runID)) {
            try await duplicateReconciler.prepareRecoveryQueue()
        }

        let later = recoveryReconcileRecord(seed: 41, offset: 3, phase: .accepted)
        let earlier = recoveryReconcileRecord(seed: 42, offset: 2, phase: .accepted)
        let orderIndex = RecoveryReconcileIndex(entries: [])
        let orderReconciler = recoveryReconciler(
            records: [later, earlier],
            index: orderIndex
        )
        await assertRecoveryReconcileError(
            .unstableJournalFIFO(
                previous: later.acceptanceOffset,
                actual: earlier.acceptanceOffset
            )
        ) {
            try await orderReconciler.prepareRecoveryQueue()
        }
        let duplicateOperations = await duplicateIndex.operations()
        let orderOperations = await orderIndex.operations()
        XCTAssertEqual(duplicateOperations, [])
        XCTAssertEqual(orderOperations, [])
    }

    func testDuplicateIndexEntriesFailClosedBeforeMutation() async throws {
        let record = recoveryReconcileRecord(seed: 43, offset: 1, phase: .accepted)
        let fence = recoveryReconcileFence(
            runID: record.runID,
            owner: 43_101,
            generation: 1
        )
        let duplicate = recoveryReconcileEntry(fence, state: .active)
        let index = RecoveryReconcileIndex(entries: [duplicate, duplicate])
        let reconciler = recoveryReconciler(records: [record], index: index)

        await assertRecoveryReconcileError(.duplicateIndexRunID(record.runID)) {
            try await reconciler.prepareRecoveryQueue()
        }
        let operations = await index.operations()
        XCTAssertEqual(operations, [])
    }

    func testTerminalEventAndNonterminalStateContradictionsFailClosed() async throws {
        let missingTerminal = recoveryReconcileRecord(
            seed: 50,
            offset: 1,
            phase: .completed,
            terminalEventID: nil
        )
        let missingIndex = RecoveryReconcileIndex(entries: [])
        let missingReconciler = recoveryReconciler(
            records: [missingTerminal],
            index: missingIndex
        )
        await assertRecoveryReconcileError(
            .missingTerminalEventID(missingTerminal.runID)
        ) {
            try await missingReconciler.prepareRecoveryQueue()
        }

        var invalidState = recoveryReconcileRecord(
            seed: 51,
            offset: 1,
            phase: .running
        ).state
        invalidState.terminalEventID = recoveryReconcileTagged(51_001)
        let invalid = AgentAcceptedRunRecoveryRecord(
            runID: invalidState.context!.lineage.runID,
            acceptanceOffset: AgentJournalOffset(rawValue: 1),
            state: invalidState
        )
        let invalidIndex = RecoveryReconcileIndex(entries: [])
        let invalidReconciler = recoveryReconciler(
            records: [invalid],
            index: invalidIndex
        )
        await assertRecoveryReconcileError(
            .nonterminalHasTerminalEventID(invalid.runID)
        ) {
            try await invalidReconciler.prepareRecoveryQueue()
        }
        let missingOperations = await missingIndex.operations()
        let invalidOperations = await invalidIndex.operations()
        XCTAssertEqual(missingOperations, [])
        XCTAssertEqual(invalidOperations, [])
    }

    func testCapacityExhaustionAccountsForFutureNonterminalClaims() async throws {
        let terminalMissing = recoveryReconcileRecord(
            seed: 60,
            offset: 1,
            phase: .completed,
            terminalEventID: recoveryReconcileTagged(60_001)
        )
        let nonterminalMissing = recoveryReconcileRecord(
            seed: 61,
            offset: 2,
            phase: .running
        )
        let tombstoneRunID: RunID = recoveryReconcileTagged(60_900)
        let tombstone = recoveryReconcileEntry(
            recoveryReconcileFence(
                runID: tombstoneRunID,
                owner: 60_901,
                generation: 1
            ),
            state: .abandoned
        )
        let index = RecoveryReconcileIndex(
            entries: [tombstone],
            maximumEntryCount: 1
        )
        let reconciler = recoveryReconciler(
            records: [terminalMissing, nonterminalMissing],
            index: index
        )

        await assertRecoveryReconcileError(
            .capacityExhausted(required: 2, remaining: 0)
        ) {
            try await reconciler.prepareRecoveryQueue()
        }
        let operations = await index.operations()
        XCTAssertEqual(operations, [])
    }

    func testUnavailableLeadershipAcquirerNeverClaimsElection() async {
        let acquirer = UnavailableAgentRecoveryLeadershipLeaseAcquirer()
        await assertRecoveryReconcileError(.leadershipUnavailable) {
            try await acquirer.acquireProcessLifetimeLease()
        }
    }
}

private final class RecoveryReconcileLeadershipLease:
    AgentRecoveryLeadershipLease,
    @unchecked Sendable
{}

private struct RecoveryReconcileScanner:
    AgentAcceptedRunRecoveryScanning,
    Sendable
{
    let records: [AgentAcceptedRunRecoveryRecord]

    func acceptedNonterminalRunIDs() -> [RunID] {
        records.compactMap { $0.state.phase.isTerminal ? nil : $0.runID }
    }

    func acceptedRunRecoveryRecords() -> [AgentAcceptedRunRecoveryRecord] {
        records
    }
}

private enum RecoveryReconcileIndexOperation: Equatable, Hashable, Sendable {
    case claim(RunID)
    case abandon(RunID)
    case settle(RunID)
}

private enum RecoveryReconcileFaultTiming: Sendable {
    case beforeCommit
    case afterCommit
    case afterCommitSnapshotUnavailable
}

private enum RecoveryReconcileInjectedError: Error, Equatable, Sendable {
    case claim(RunID)
    case abandon(RunID)
    case settle(RunID)
    case snapshot
}

private actor RecoveryReconcileIndex: AgentRunRecoveryIndexing {
    private let storeID = recoveryReconcileUUID(999_001)
    private let maximumEntryCount: Int
    private var entries: [DurableAgentEngineRunIndexEntrySnapshot]
    private var ledgerGeneration: UInt64 = 1
    private var faults: [RecoveryReconcileIndexOperation: RecoveryReconcileFaultTiming]
    private var operationLog: [RecoveryReconcileIndexOperation] = []
    private var snapshotReads = 0
    private var snapshotFailuresRemaining = 0

    init(
        entries: [DurableAgentEngineRunIndexEntrySnapshot],
        maximumEntryCount: Int = 64,
        faults: [RecoveryReconcileIndexOperation: RecoveryReconcileFaultTiming] = [:]
    ) {
        self.entries = entries
        self.maximumEntryCount = maximumEntryCount
        self.faults = faults
    }

    func snapshot() throws -> DurableAgentEngineRunIndexSnapshot {
        snapshotReads += 1
        if snapshotFailuresRemaining > 0 {
            snapshotFailuresRemaining -= 1
            throw RecoveryReconcileInjectedError.snapshot
        }
        return DurableAgentEngineRunIndexSnapshot(
            storeID: storeID,
            ledgerGeneration: ledgerGeneration,
            entries: entries,
            capacity: DurableAgentEngineRunIndexCapacity(
                usedEntryCount: entries.count,
                maximumEntryCount: maximumEntryCount
            )
        )
    }

    func claim(
        runID: RunID,
        ownerID: UUID,
        mode: AgentEngineRunClaimMode
    ) throws -> AgentEngineOwnerFence {
        let operation = RecoveryReconcileIndexOperation.claim(runID)
        operationLog.append(operation)
        let fault = faults.removeValue(forKey: operation)
        if fault == .beforeCommit {
            throw RecoveryReconcileInjectedError.claim(runID)
        }
        let fence: AgentEngineOwnerFence
        if let position = entries.firstIndex(where: { $0.runID == runID }) {
            let current = entries[position]
            if case .terminal = current.state {
                throw AgentEngineRunIndexError.runAlreadyTerminal(runID)
            }
            guard current.fence.generation < UInt64.max else {
                throw AgentEngineRunIndexError.generationExhausted(runID)
            }
            fence = AgentEngineOwnerFence(
                runID: runID,
                ownerID: ownerID,
                generation: current.fence.generation + 1
            )
            entries[position] = recoveryReconcileEntry(fence, state: .active)
        } else {
            guard entries.count < maximumEntryCount else {
                throw DurableAgentEngineRunIndexError.capacityExceeded
            }
            fence = AgentEngineOwnerFence(
                runID: runID,
                ownerID: ownerID,
                generation: 1
            )
            entries.append(recoveryReconcileEntry(fence, state: .active))
        }
        ledgerGeneration += 1
        try throwAfterCommitIfNeeded(fault, operation: operation)
        return fence
    }

    func abandonDurably(_ fence: AgentEngineOwnerFence) throws {
        let operation = RecoveryReconcileIndexOperation.abandon(fence.runID)
        operationLog.append(operation)
        let fault = faults.removeValue(forKey: operation)
        if fault == .beforeCommit {
            throw RecoveryReconcileInjectedError.abandon(fence.runID)
        }
        guard let position = entries.firstIndex(where: {
            $0.runID == fence.runID && $0.fence == fence && $0.state == .active
        }) else { return }
        entries[position] = recoveryReconcileEntry(fence, state: .abandoned)
        ledgerGeneration += 1
        try throwAfterCommitIfNeeded(fault, operation: operation)
    }

    func settle(_ record: AgentEngineTerminalRecord) throws {
        let operation = RecoveryReconcileIndexOperation.settle(record.runID)
        operationLog.append(operation)
        let fault = faults.removeValue(forKey: operation)
        if fault == .beforeCommit {
            throw RecoveryReconcileInjectedError.settle(record.runID)
        }
        guard let position = entries.firstIndex(where: {
            $0.runID == record.runID && $0.fence == record.fence
        }) else {
            throw AgentEngineRunIndexError.staleOwner(record.fence)
        }
        if case let .terminal(existing) = entries[position].state {
            guard existing == record else {
                throw AgentEngineRunIndexError.runAlreadyTerminal(record.runID)
            }
            return
        }
        guard entries[position].state == .active else {
            throw AgentEngineRunIndexError.staleOwner(record.fence)
        }
        entries[position] = recoveryReconcileEntry(
            record.fence,
            state: .terminal(record)
        )
        ledgerGeneration += 1
        try throwAfterCommitIfNeeded(fault, operation: operation)
    }

    func operations() -> [RecoveryReconcileIndexOperation] {
        operationLog
    }

    func snapshotReadCount() -> Int {
        snapshotReads
    }

    private func throwAfterCommitIfNeeded(
        _ timing: RecoveryReconcileFaultTiming?,
        operation: RecoveryReconcileIndexOperation
    ) throws {
        if timing == .afterCommitSnapshotUnavailable {
            snapshotFailuresRemaining += 1
        }
        guard timing == .afterCommit || timing == .afterCommitSnapshotUnavailable else {
            return
        }
        switch operation {
        case let .claim(runID): throw RecoveryReconcileInjectedError.claim(runID)
        case let .abandon(runID): throw RecoveryReconcileInjectedError.abandon(runID)
        case let .settle(runID): throw RecoveryReconcileInjectedError.settle(runID)
        }
    }
}

private func recoveryReconciler(
    records: [AgentAcceptedRunRecoveryRecord],
    index: RecoveryReconcileIndex
) -> AgentRunRecoveryReconciler {
    AgentRunRecoveryReconciler(
        scanner: RecoveryReconcileScanner(records: records),
        index: index,
        recoveryOwnerID: recoveryReconcileUUID(777),
        leadershipLease: RecoveryReconcileLeadershipLease()
    )
}

private func recoveryReconcileRecord(
    seed: UInt64,
    offset: UInt64,
    phase: AgentRunPhase,
    terminalEventID: EventID? = nil
) -> AgentAcceptedRunRecoveryRecord {
    let runID: RunID = recoveryReconcileTagged(seed * 100 + 1)
    let context = AgentRunContext(
        schemaVersion: .current,
        lineage: .root(runID),
        conversationID: recoveryReconcileTagged(seed * 100 + 2),
        projectID: recoveryReconcileTagged(seed * 100 + 3),
        workspaceID: recoveryReconcileTagged(seed * 100 + 4),
        executionNodeID: recoveryReconcileTagged(seed * 100 + 5),
        engineVersion: .agentHarnessV2,
        acceptedAt: AgentInstant(rawValue: 3_000_000_000_000 + Int64(seed)),
        features: AgentFeatureSet(["reconciliation-test"]),
        cancellation: CancellationLineage(
            scopeID: recoveryReconcileTagged(seed * 100 + 6)
        ),
        initialBudget: AgentBudget(limits: .standard)
    )
    return AgentAcceptedRunRecoveryRecord(
        runID: runID,
        acceptanceOffset: AgentJournalOffset(rawValue: offset),
        state: AgentDomain.AgentRunState(
            context: context,
            phase: phase,
            lastEventID: terminalEventID,
            terminalEventID: terminalEventID
        )
    )
}

private func recoveryReconcileEntry(
    _ fence: AgentEngineOwnerFence,
    state: DurableAgentEngineRunIndexEntryState
) -> DurableAgentEngineRunIndexEntrySnapshot {
    DurableAgentEngineRunIndexEntrySnapshot(
        runID: fence.runID,
        fence: fence,
        state: state
    )
}

private func recoveryReconcileFence(
    runID: RunID,
    owner: UInt64,
    generation: UInt64
) -> AgentEngineOwnerFence {
    AgentEngineOwnerFence(
        runID: runID,
        ownerID: recoveryReconcileUUID(owner),
        generation: generation
    )
}

private func recoveryReconcileTerminal(
    _ record: AgentAcceptedRunRecoveryRecord,
    fence: AgentEngineOwnerFence
) -> AgentEngineTerminalRecord {
    AgentEngineTerminalRecord(
        runID: record.runID,
        fence: fence,
        phase: record.state.phase,
        terminalEventID: record.state.terminalEventID!
    )
}

private func recoveryReconcileUUID(_ value: UInt64) -> UUID {
    UUID(
        uuidString: String(
            format: "00000000-0000-0000-0000-%012llX",
            value
        )
    )!
}

private func recoveryReconcileTagged<Tag: AgentIdentifierTag>(
    _ value: UInt64
) -> AgentIdentifier<Tag> {
    AgentIdentifier(rawValue: recoveryReconcileUUID(value))
}

private func assertRecoveryReconcileError<T: Sendable>(
    _ expected: AgentRunRecoveryReconcilerError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected reconciliation error", file: file, line: line)
    } catch let error as AgentRunRecoveryReconcilerError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

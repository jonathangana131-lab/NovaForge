import AgentDomain
import AgentStore
import Foundation
import XCTest
@testable import NovaForge

final class AgentAcceptedRunRecoveryScannerTests: XCTestCase {
    func testStableFIFOScanReturnsOnlyAcceptedNonterminalRuns() async throws {
        let journal = InMemoryAgentEventJournal(
            clock: { AgentInstant(rawValue: 2_000_000_000_000) }
        )
        let first = RecoveryScanFixture(seed: 1)
        let terminal = RecoveryScanFixture(seed: 2)
        let running = RecoveryScanFixture(seed: 3)
        _ = try await journal.accept(first.acceptance)
        _ = try await journal.accept(terminal.acceptance)
        _ = try await journal.accept(running.acceptance)
        _ = try await journal.append(terminal.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "terminal-start"
        ))
        _ = try await journal.append(running.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "running-start"
        ))
        _ = try await journal.append(terminal.envelope(
            3,
            payload: .runCompleted(RunCompletedEvent(summary: "done")),
            key: "terminal-complete"
        ))

        let oneAtATime = try AgentAcceptedRunRecoveryScanner(
            journal: journal,
            batchSize: 1
        )
        let wide = try AgentAcceptedRunRecoveryScanner(
            journal: journal,
            batchSize: 64
        )

        let narrowResult = try await oneAtATime.acceptedNonterminalRunIDs()
        let wideResult = try await wide.acceptedNonterminalRunIDs()
        XCTAssertEqual(narrowResult, [first.runID, running.runID])
        XCTAssertEqual(wideResult, [first.runID, running.runID])

        let records = try await wide.acceptedRunRecoveryRecords()
        XCTAssertEqual(records.map(\.runID), [first.runID, terminal.runID, running.runID])
        XCTAssertEqual(records.map(\.acceptanceOffset.rawValue), [1, 2, 3])
        XCTAssertEqual(records.map(\.state.phase), [.accepted, .completed, .running])
        XCTAssertEqual(
            records[1].state.terminalEventID,
            terminal.envelope(
                3,
                payload: .runCompleted(RunCompletedEvent(summary: "done")),
                key: "terminal-complete"
            ).event.header.eventID
        )
    }

    func testEmptyJournalProducesAnEmptyRecoveryQueue() async throws {
        let journal = InMemoryAgentEventJournal()
        let scanner = try AgentAcceptedRunRecoveryScanner(journal: journal)
        let result = try await scanner.acceptedNonterminalRunIDs()
        XCTAssertEqual(result, [])
    }

    func testEventAndRunLimitsFailClosed() async throws {
        let journal = InMemoryAgentEventJournal()
        let first = RecoveryScanFixture(seed: 10)
        let second = RecoveryScanFixture(seed: 11)
        _ = try await journal.accept(first.acceptance)
        _ = try await journal.accept(second.acceptance)

        let eventBound = try AgentAcceptedRunRecoveryScanner(
            journal: journal,
            batchSize: 2,
            maximumEventCount: 1
        )
        await assertRecoveryScannerError(.eventLimitExceeded) {
            try await eventBound.acceptedNonterminalRunIDs()
        }

        let runBound = try AgentAcceptedRunRecoveryScanner(
            journal: journal,
            batchSize: 2,
            maximumRunCount: 1
        )
        await assertRecoveryScannerError(.runLimitExceeded) {
            try await runBound.acceptedNonterminalRunIDs()
        }
    }

    func testNoProgressProjectionBatchIsRejected() async throws {
        let scanner = try AgentAcceptedRunRecoveryScanner(
            journal: StalledRecoveryJournal(),
            batchSize: 1
        )
        await assertRecoveryScannerError(.inconsistentBatch) {
            try await scanner.acceptedNonterminalRunIDs()
        }
    }

    func testMissingMetadataIsRejectedInsteadOfDroppingAcceptedRun() async throws {
        let journal = InMemoryAgentEventJournal()
        let fixture = RecoveryScanFixture(seed: 20)
        _ = try await journal.accept(fixture.acceptance)
        let scanner = try AgentAcceptedRunRecoveryScanner(
            journal: MissingMetadataRecoveryJournal(backing: journal)
        )

        await assertRecoveryScannerError(.missingMetadata(fixture.runID)) {
            try await scanner.acceptedNonterminalRunIDs()
        }
    }

    func testRecoveryReadsOneBoundedProjectionSnapshot() async throws {
        let backing = InMemoryAgentEventJournal()
        for seed in 30 ..< 42 {
            let fixture = RecoveryScanFixture(seed: UInt64(seed))
            _ = try await backing.accept(fixture.acceptance)
            _ = try await backing.append(fixture.envelope(
                2,
                payload: .runStarted(RunStartedEvent()),
                key: "scale-start-\(seed)"
            ))
        }
        let journal = ProjectionCountingRecoveryJournal(backing: backing)
        let scanner = try AgentAcceptedRunRecoveryScanner(
            journal: journal,
            batchSize: 1
        )

        let recovered = try await scanner.acceptedNonterminalRunIDs()
        let projectionReads = await journal.projectionReadCount()

        XCTAssertEqual(recovered.count, 12)
        XCTAssertEqual(projectionReads, 1)
    }
}

private struct RecoveryScanFixture: Sendable {
    let context: AgentRunContext
    let writerID: AgentEventWriterID
    let commandID: CommandID
    let correlationID: CorrelationID
    let userItem: ModelItem
    let seed: UInt64

    init(seed: UInt64) {
        self.seed = seed
        let runID: RunID = recoveryScanTagged(seed * 100 + 1)
        let acceptedAt = AgentInstant(
            rawValue: 2_100_000_000_000 + Int64(seed * 1_000)
        )
        context = AgentRunContext(
            schemaVersion: .current,
            lineage: .root(runID),
            conversationID: recoveryScanTagged(seed * 100 + 2),
            projectID: recoveryScanTagged(seed * 100 + 3),
            workspaceID: recoveryScanTagged(seed * 100 + 4),
            executionNodeID: recoveryScanTagged(seed * 100 + 5),
            engineVersion: .agentHarnessV2,
            acceptedAt: acceptedAt,
            features: AgentFeatureSet(["recovery-scan"]),
            cancellation: CancellationLineage(
                scopeID: recoveryScanTagged(seed * 100 + 6)
            ),
            initialBudget: AgentBudget(limits: .standard)
        )
        writerID = AgentEventWriterID(runID: runID)
        commandID = recoveryScanTagged(seed * 100 + 7)
        correlationID = recoveryScanTagged(seed * 100 + 8)
        userItem = ModelItem(
            id: recoveryScanTagged(seed * 100 + 9),
            createdAt: acceptedAt,
            payload: .message(ModelMessage(
                role: .user,
                content: [.text("Recover fixture \(seed)")]
            ))
        )
    }

    var runID: RunID { context.lineage.runID }

    var acceptance: AgentRunAcceptance {
        let accepted = envelope(
            1,
            payload: .runAccepted(RunAcceptedEvent(
                context: context,
                acceptedEngineVersion: context.engineVersion,
                initialItems: [userItem]
            )),
            key: "accept-\(runID.description)"
        )
        return AgentRunAcceptance(
            metadata: AgentRunMetadataRecord(
                context: context,
                acceptedEngineVersion: context.engineVersion,
                writerID: writerID,
                acceptanceCommandID: commandID,
                acceptanceEventID: accepted.event.header.eventID
            ),
            envelope: accepted
        )
    }

    func envelope(
        _ sequenceValue: UInt64,
        payload: AgentEventPayload,
        key: String
    ) -> AgentEventEnvelope {
        let sequence = EventSequence(rawValue: sequenceValue)
        return AgentEventEnvelope(
            writerID: writerID,
            writerSequence: sequence,
            idempotencyKey: key,
            event: AgentEvent(
                header: AgentEventHeader(
                    eventID: recoveryScanTagged(
                        seed * 10_000 + 1_000 + sequenceValue
                    ),
                    schemaVersion: context.schemaVersion,
                    context: context,
                    sequence: sequence,
                    timestamp: sequenceValue == 1
                        ? context.acceptedAt
                        : AgentInstant(
                            rawValue: context.acceptedAt.rawValue
                                + Int64(sequenceValue)
                        ),
                    causationID: recoveryScanTagged(seed * 100 + 10),
                    correlationID: correlationID
                ),
                payload: payload
            )
        )
    }
}

private actor StalledRecoveryJournal: AgentEventReading {
    func metadata(for runID: RunID) -> AgentRunMetadataRecord? { nil }

    func events(
        for runID: RunID,
        after sequence: EventSequence?
    ) -> [StoredAgentEvent] { [] }

    func projectionBatch(
        after offset: AgentJournalOffset,
        limit: Int
    ) -> AgentProjectionBatch {
        AgentProjectionBatch(
            afterOffset: offset,
            highWaterMark: AgentJournalOffset(rawValue: 1),
            records: []
        )
    }
}

private struct MissingMetadataRecoveryJournal: AgentEventReading, Sendable {
    let backing: InMemoryAgentEventJournal

    func metadata(for runID: RunID) async throws -> AgentRunMetadataRecord? {
        nil
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
}

private actor ProjectionCountingRecoveryJournal: AgentEventReading {
    let backing: InMemoryAgentEventJournal
    private var projectionReads = 0

    init(backing: InMemoryAgentEventJournal) {
        self.backing = backing
    }

    func metadata(for runID: RunID) async throws -> AgentRunMetadataRecord? {
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
        projectionReads += 1
        return try await backing.projectionBatch(after: offset, limit: limit)
    }

    func projectionReadCount() -> Int { projectionReads }
}

private func recoveryScanUUID(_ value: UInt64) -> UUID {
    UUID(
        uuidString: String(
            format: "00000000-0000-0000-0000-%012llX",
            value
        )
    )!
}

private func recoveryScanTagged<Tag: AgentIdentifierTag>(
    _ value: UInt64
) -> AgentIdentifier<Tag> {
    AgentIdentifier(rawValue: recoveryScanUUID(value))
}

private func assertRecoveryScannerError<T: Sendable>(
    _ expected: AgentAcceptedRunRecoveryScannerError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected recovery scanner error", file: file, line: line)
    } catch let error as AgentAcceptedRunRecoveryScannerError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

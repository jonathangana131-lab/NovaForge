import AgentDomain
@testable import AgentShadow
import AgentStore
import AgentTools
import Foundation
import XCTest

final class DarkReplayEngineTests: XCTestCase {
    func testReplayUsesOnlyReadCapabilityAndReconstructsExactCanonicalViews() async throws {
        let fixture = ShadowTestFixture()
        let source = try await fixture.makeStore()
        let snapshot = await source.durableSnapshot()
        let tripwire = ShadowJournalTripwire(
            metadata: snapshot.metadata.first,
            records: snapshot.records
        )

        let report = try await DarkReplayEngine(reader: tripwire)
            .replay(fixture.runID)

        XCTAssertEqual(report.state.phase, .completed)
        XCTAssertTrue(report.parity.isExact)
        XCTAssertEqual(report.parity.eventCount, 14)
        XCTAssertEqual(report.transcript.items, report.state.modelItems)
        XCTAssertEqual(report.toolEvidence.count, 1)
        XCTAssertEqual(report.toolEvidence[0].invocation, fixture.invocation)
        XCTAssertEqual(
            report.toolEvidence[0].transitions.map(\.status),
            [.proposed, .scheduled, .running, .applied, .completed]
        )
        XCTAssertEqual(report.toolEvidence[0].result?.callID, fixture.invocation.callID)
        XCTAssertEqual(
            report.toolEvidence[0].applicationEvidence,
            [ToolEvidence(kind: "post_hash", digest: "sha256:applied")]
        )
        XCTAssertEqual(
            report.toolEvidence[0].resultEvidence,
            [ToolEvidence(kind: "result_hash", digest: "sha256:result")]
        )
        XCTAssertEqual(report.capturedArtifacts, [fixture.artifact])
        XCTAssertEqual(report.latency.recordedRunDurationMilliseconds, 13)
        XCTAssertEqual(report.latency.recordedCommitSpanMilliseconds, 0)
        XCTAssertEqual(report.latency.attempts.count, 2)
        XCTAssertEqual(report.latency.attempts[0].outcome, .failedBeforeCommit)
        XCTAssertTrue(report.latency.attempts[0].retryScheduled)
        XCTAssertEqual(report.latency.attempts[0].durationMilliseconds, 1)
        XCTAssertEqual(report.latency.attempts[1].outcome, .responseCommitted)
        XCTAssertEqual(report.latency.attempts[1].durationMilliseconds, 1)
        XCTAssertTrue(report.digests.ledgerSHA256.hasPrefix("sha256:"))
        XCTAssertTrue(report.digests.reportSHA256.hasPrefix("sha256:"))

        let tripwireCounts = await tripwire.counts
        XCTAssertEqual(
            tripwireCounts,
            ShadowTripwireCounts(
                acceptCalls: 0,
                appendCalls: 0,
                projectionReadCalls: 0,
                cursorReadCalls: 0,
                cursorWriteCalls: 0,
                effectCalls: 0
            )
        )
    }

    func testRestartProducesByteIdenticalReportAndDigests() async throws {
        let fixture = ShadowTestFixture(seed: 8)
        let store = try await fixture.makeStore()
        let beforeRestart = try await DarkReplayEngine(reader: store)
            .replay(fixture.runID)

        let snapshotData = try JSONEncoder().encode(
            await store.durableSnapshot()
        )
        let restoredSnapshot = try JSONDecoder().decode(
            InMemoryAgentEventJournalSnapshot.self,
            from: snapshotData
        )
        let restored = try InMemoryAgentEventJournal(
            restoring: restoredSnapshot,
            clock: { AgentInstant(rawValue: 2_000_000_000_000) }
        )
        let afterRestart = try await DarkReplayEngine(reader: restored)
            .replay(fixture.runID)

        XCTAssertEqual(afterRestart, beforeRestart)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(
            try encoder.encode(afterRestart),
            try encoder.encode(beforeRestart)
        )
    }

    func testFailedAttemptCannotContaminateCommittedTranscript() async throws {
        let fixture = ShadowTestFixture(seed: 9)
        let store = try await fixture.makeStore()
        let report = try await DarkReplayEngine(reader: store)
            .replay(fixture.runID)

        let assistantText = report.transcript.items.flatMap { item -> [String] in
            guard case let .message(message) = item.payload,
                  message.role == .assistant
            else { return [] }
            return message.content.compactMap { part in
                guard case let .text(text) = part else { return nil }
                return text
            }
        }
        XCTAssertEqual(assistantText, ["Clean committed response"])
        XCTAssertEqual(report.state.modelAttempts.count, 2)
        XCTAssertEqual(report.state.modelAttempts[0].status, .retryScheduled)
        XCTAssertEqual(report.state.modelAttempts[1].status, .responseCommitted)
    }

    func testMalformedEnvelopeFailsClosedThroughJournalRecovery() async throws {
        let fixture = ShadowTestFixture(seed: 10)
        let store = try await fixture.makeStore()
        let snapshot = await store.durableSnapshot()
        let original = snapshot.records[5]
        let malformedEnvelope = AgentEventEnvelope(
            writerID: original.envelope.writerID,
            writerSequence: EventSequence(
                rawValue: original.envelope.writerSequence.rawValue + 1
            ),
            idempotencyKey: original.envelope.idempotencyKey,
            event: original.event
        )
        var records = snapshot.records
        records[5] = StoredAgentEvent(
            offset: original.offset,
            committedAt: original.committedAt,
            envelope: malformedEnvelope
        )
        let reader = ShadowJournalTripwire(
            metadata: snapshot.metadata.first,
            records: records
        )

        do {
            _ = try await DarkReplayEngine(reader: reader).replay(fixture.runID)
            XCTFail("Malformed ledger unexpectedly produced a shadow report")
        } catch let error as AgentStoreError {
            guard case .corruptJournal = error else {
                return XCTFail("Unexpected store error: \(error)")
            }
        }
    }

    func testNonMonotonicRecordedLatencyFailsClosed() async throws {
        let fixture = ShadowTestFixture(seed: 11)
        let store = try await fixture.makeStore()
        let snapshot = await store.durableSnapshot()
        var records = snapshot.records
        let original = records[3]
        let header = original.event.header
        let regressedHeader = AgentEventHeader(
            eventID: header.eventID,
            schemaVersion: header.schemaVersion,
            runID: header.runID,
            rootRunID: header.rootRunID,
            parentRunID: header.parentRunID,
            sequence: header.sequence,
            timestamp: fixture.instant(2),
            executionNodeID: header.executionNodeID,
            conversationID: header.conversationID,
            projectID: header.projectID,
            workspaceID: header.workspaceID,
            causationID: header.causationID,
            correlationID: header.correlationID,
            engineVersion: header.engineVersion
        )
        records[3] = StoredAgentEvent(
            offset: original.offset,
            committedAt: original.committedAt,
            envelope: AgentEventEnvelope(
                writerID: original.envelope.writerID,
                writerSequence: original.envelope.writerSequence,
                idempotencyKey: original.envelope.idempotencyKey,
                event: AgentEvent(
                    header: regressedHeader,
                    payload: original.event.payload
                )
            )
        )
        let reader = ShadowJournalTripwire(
            metadata: snapshot.metadata.first,
            records: records
        )

        do {
            _ = try await DarkReplayEngine(reader: reader).replay(fixture.runID)
            XCTFail("Regressed latency unexpectedly produced a shadow report")
        } catch let error as DarkReplayError {
            guard case .nonMonotonicEventTimestamp = error else {
                return XCTFail("Unexpected replay error: \(error)")
            }
        }
    }

    func testMissingRunFailsClosedWithoutCreatingState() async throws {
        let missingRunID: RunID = shadowID(800_000)
        let reader = ShadowJournalTripwire(metadata: nil, records: [])
        do {
            _ = try await DarkReplayEngine(reader: reader).replay(missingRunID)
            XCTFail("Missing run unexpectedly produced a report")
        } catch let error as DarkReplayError {
            XCTAssertEqual(error, .runNotFound(missingRunID))
        }
    }

    func testAcceptanceAppearingInsideAbsentBracketIsNotReportedMissing() async throws {
        let fixture = ShadowTestFixture(seed: 16)
        let source = InMemoryAgentEventJournal(
            clock: { AgentInstant(rawValue: 2_000_000_000_000) }
        )
        _ = try await source.accept(fixture.acceptance)
        let snapshot = await source.durableSnapshot()
        let racing = AcceptanceAppearsReader(
            metadata: try XCTUnwrap(snapshot.metadata.first),
            records: snapshot.records
        )

        do {
            _ = try await DarkReplayEngine(reader: racing).replay(fixture.runID)
            XCTFail("Acceptance race unexpectedly reported a stable replay")
        } catch {
            XCTAssertEqual(
                error as? DarkReplayError,
                .ledgerChangedDuringReplay(runID: fixture.runID)
            )
        }
    }

    func testVersionedCanonicalDigestGoldenVectors() async throws {
        let fixture = ShadowTestFixture(seed: 17)
        let report = try await DarkReplayEngine(reader: try await fixture.makeStore())
            .replay(fixture.runID)
        let numeric: JSONValue = .object([
            "integer": .number(.integer(-7)),
            "unsigned": .number(.unsignedInteger(9)),
            "float": .number(.floatingPoint(1.25)),
            "nested": .array([.bool(true), .null]),
        ])

        XCTAssertEqual(CanonicalShadowDigest.scheme, "novaforge-shadow-canonical-json-v2")
        let domainDigests = try CanonicalShadowDigest.Domain.allCases.map {
            try CanonicalShadowDigest.sha256(domain: $0, numeric)
        }
        XCTAssertEqual(
            Set(domainDigests).count,
            CanonicalShadowDigest.Domain.allCases.count,
            "Identical bytes must never collide across semantic digest domains"
        )
        XCTAssertEqual(
            try CanonicalShadowDigest.sha256(
                domain: .canonicalFixture,
                numeric
            ),
            "sha256:685e27eaf7c8af64f4bf0289fee0302cb4ae0e22f6eeb7bc4dc6ccf93bbf1473"
        )
        XCTAssertEqual(
            report.digests.ledgerSHA256,
            "sha256:d5825c3dccef8fdcb8bfee9b08c4b7da974270aa2435b38d58b4b1423758b1f6"
        )
        XCTAssertEqual(
            report.digests.stateSHA256,
            "sha256:a15ad0ccfb67a7e83b93f6ae5a7b87f165d88f798e06ebc286e6726894ea4454"
        )
        XCTAssertEqual(
            report.digests.transcriptSHA256,
            "sha256:dd1a68340b0c059866380aeff21df742440a6d311f4d309427ffe33c51a8f7f2"
        )
        XCTAssertEqual(
            report.digests.evidenceSHA256,
            "sha256:ad81739e09fe7071b2797e749c313590bc6251d41ddb3a519d1aba1f23614faf"
        )
        XCTAssertEqual(
            report.digests.reportSHA256,
            "sha256:5ce4bec338a9cb1642bd461191b8a94960b53a3f44b20c0835be365983660a08"
        )
        XCTAssertEqual(
            try CanonicalToolContract.sha256(ReadFileTool.descriptor),
            "sha256:53dd06adf729f0897134399317beca447b23ed77c1ee5142193f740cc956e3ff"
        )
    }
}

private actor AcceptanceAppearsReader: AgentEventReading {
    private let storedMetadata: AgentRunMetadataRecord
    private let storedRecords: [StoredAgentEvent]
    private var eventReadCount = 0
    private var visible = false

    init(metadata: AgentRunMetadataRecord, records: [StoredAgentEvent]) {
        storedMetadata = metadata
        storedRecords = records
    }

    func metadata(for runID: RunID) async throws -> AgentRunMetadataRecord? {
        visible && storedMetadata.runID == runID ? storedMetadata : nil
    }

    func events(
        for runID: RunID,
        after sequence: EventSequence?
    ) async throws -> [StoredAgentEvent] {
        eventReadCount += 1
        if eventReadCount == 2 {
            visible = true
            return []
        }
        guard visible else { return [] }
        return storedRecords.filter { record in
            guard record.runID == runID else { return false }
            guard let sequence else { return true }
            return record.envelope.writerSequence > sequence
        }
    }

    func projectionBatch(
        after offset: AgentJournalOffset,
        limit: Int
    ) async throws -> AgentProjectionBatch {
        AgentProjectionBatch(
            afterOffset: offset,
            highWaterMark: storedRecords.last?.offset ?? .origin,
            records: []
        )
    }
}

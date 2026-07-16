import AgentDomain
import AgentStore
import Foundation
import XCTest

final class AgentProjectionRecoveryTests: XCTestCase {
    func testKillRelaunchReplaysDurableLedgerAndContinuesFromNextSequence() async throws {
        let fixture = AgentStoreFixture(seed: 20)
        let store = InMemoryAgentEventJournal(
            clock: { AgentInstant(rawValue: 2_000_000_000_000) }
        )
        _ = try await store.accept(fixture.acceptance)
        _ = try await store.append(fixture.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "start"
        ))

        let beforeDeath = try await AgentJournalRecovery(store: store)
            .recover(fixture.runID)
        let encodedSnapshot = try JSONEncoder().encode(
            await store.durableSnapshot()
        )
        let decodedSnapshot = try JSONDecoder().decode(
            InMemoryAgentEventJournalSnapshot.self,
            from: encodedSnapshot
        )
        let relaunched = try InMemoryAgentEventJournal(
            restoring: decodedSnapshot,
            clock: { AgentInstant(rawValue: 2_000_000_000_100) }
        )

        let recovered = try await AgentJournalRecovery(store: relaunched)
            .recover(fixture.runID)
        XCTAssertEqual(recovered, beforeDeath)
        XCTAssertEqual(recovered?.state.phase, .running)
        XCTAssertEqual(recovered?.eventCount, 2)

        let next = try await relaunched.append(fixture.envelope(
            3,
            payload: .contextPrepared(
                ContextPreparedEvent(
                    itemIDs: [fixture.userItem.id],
                    estimatedTokens: 12,
                    contextDigest: "after-relaunch"
                )
            ),
            key: "context"
        ))
        XCTAssertEqual(next.record.offset, AgentJournalOffset(rawValue: 3))
        let afterRelaunch = try await AgentJournalRecovery(store: relaunched)
            .recover(fixture.runID)
        XCTAssertEqual(
            afterRelaunch?.state.lastSequence,
            EventSequence(rawValue: 3)
        )
    }

    func testProjectionCursorReplaysGlobalJournalInBoundedBatches() async throws {
        let first = AgentStoreFixture(seed: 30)
        let second = AgentStoreFixture(seed: 31)
        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(first.acceptance) // offset 1
        _ = try await store.accept(second.acceptance) // offset 2
        _ = try await store.append(first.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "first-start"
        )) // offset 3
        _ = try await store.append(second.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "second-start"
        )) // offset 4

        let projectionID = AgentProjectionID(rawValue: "legacy-run-projector")
        let firstBatch = try await store.projectionBatch(
            after: .origin,
            limit: 2
        )
        XCTAssertEqual(firstBatch.records.map(\.offset), [
            AgentJournalOffset(rawValue: 1),
            AgentJournalOffset(rawValue: 2),
        ])
        XCTAssertEqual(firstBatch.highWaterMark, AgentJournalOffset(rawValue: 4))
        XCTAssertTrue(firstBatch.hasMore)

        let firstCursor = AgentProjectionCursor(
            projectionID: projectionID,
            throughOffset: firstBatch.throughOffset,
            updatedAt: AgentInstant(rawValue: 10)
        )
        let firstCursorCommit = try await store.saveCursor(
            firstCursor,
            expectedPreviousOffset: .origin
        )
        XCTAssertEqual(firstCursorCommit.disposition, .committed)

        let secondBatch = try await store.projectionBatch(
            after: firstCursor.throughOffset,
            limit: 10
        )
        XCTAssertEqual(secondBatch.records.map(\.offset), [
            AgentJournalOffset(rawValue: 3),
            AgentJournalOffset(rawValue: 4),
        ])
        XCTAssertFalse(secondBatch.hasMore)
        let secondCursor = AgentProjectionCursor(
            projectionID: projectionID,
            throughOffset: secondBatch.throughOffset,
            updatedAt: AgentInstant(rawValue: 20)
        )
        _ = try await store.saveCursor(
            secondCursor,
            expectedPreviousOffset: firstCursor.throughOffset
        )

        _ = try await store.append(first.envelope(
            3,
            payload: .contextPrepared(
                ContextPreparedEvent(
                    itemIDs: [first.userItem.id],
                    estimatedTokens: 9,
                    contextDigest: "new-work"
                )
            ),
            key: "first-context"
        )) // offset 5

        let loadedCursor = try await store.loadCursor(for: projectionID)
        let resumedCursor = try XCTUnwrap(loadedCursor)
        let resumedBatch = try await store.projectionBatch(
            after: resumedCursor.throughOffset,
            limit: 10
        )
        XCTAssertEqual(
            resumedBatch.records.map(\.offset),
            [AgentJournalOffset(rawValue: 5)]
        )
        XCTAssertEqual(resumedBatch.records.first?.runID, first.runID)
    }

    func testCursorSaveFailureIsAtomicAndCASRejectsStaleOrRegressingWriters() async throws {
        let fixture = AgentStoreFixture(seed: 40)
        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(fixture.acceptance)
        let projectionID = AgentProjectionID(rawValue: "project-os-projector")
        let cursor = AgentProjectionCursor(
            projectionID: projectionID,
            throughOffset: AgentJournalOffset(rawValue: 1),
            updatedAt: AgentInstant(rawValue: 100)
        )
        await store.failNext(.projectionCursorSave, code: "cursor_save_failed")

        let saveError = await caughtError {
            try await store.saveCursor(
                cursor,
                expectedPreviousOffset: .origin
            )
        }
        XCTAssertEqual(
            saveError as? AgentStoreError,
            .persistenceFailure(
                operation: .saveProjectionCursor,
                code: "cursor_save_failed"
            )
        )
        let missingCursor = try await store.loadCursor(for: projectionID)
        XCTAssertNil(missingCursor)

        let committed = try await store.saveCursor(
            cursor,
            expectedPreviousOffset: .origin
        )
        XCTAssertEqual(committed.disposition, .committed)
        let staleDuplicateError = await caughtError {
            try await store.saveCursor(
                AgentProjectionCursor(
                    projectionID: projectionID,
                    throughOffset: cursor.throughOffset,
                    updatedAt: AgentInstant(rawValue: 101)
                ),
                expectedPreviousOffset: .origin
            )
        }
        XCTAssertEqual(
            staleDuplicateError as? AgentStoreError,
            .cursorConflict(
                projectionID: projectionID,
                expected: .origin,
                actual: cursor.throughOffset
            )
        )
        let duplicate = try await store.saveCursor(
            AgentProjectionCursor(
                projectionID: projectionID,
                throughOffset: cursor.throughOffset,
                updatedAt: AgentInstant(rawValue: 101)
            ),
            expectedPreviousOffset: cursor.throughOffset
        )
        XCTAssertEqual(duplicate.disposition, .alreadyCommitted)

        _ = try await store.append(fixture.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "start"
        ))
        let advanced = AgentProjectionCursor(
            projectionID: projectionID,
            throughOffset: AgentJournalOffset(rawValue: 2),
            updatedAt: AgentInstant(rawValue: 102)
        )
        let staleError = await caughtError {
            try await store.saveCursor(
                advanced,
                expectedPreviousOffset: .origin
            )
        }
        XCTAssertEqual(
            staleError as? AgentStoreError,
            .cursorConflict(
                projectionID: projectionID,
                expected: .origin,
                actual: AgentJournalOffset(rawValue: 1)
            )
        )

        let regression = AgentProjectionCursor(
            projectionID: projectionID,
            throughOffset: .origin,
            updatedAt: AgentInstant(rawValue: 103)
        )
        let regressionError = await caughtError {
            try await store.saveCursor(
                regression,
                expectedPreviousOffset: AgentJournalOffset(rawValue: 1)
            )
        }
        XCTAssertEqual(
            regressionError as? AgentStoreError,
            .cursorRegression(
                projectionID: projectionID,
                current: AgentJournalOffset(rawValue: 1),
                requested: .origin
            )
        )
    }

    func testCodecIsDeterministicRoundTrippableAndRejectsMalformedBytes() throws {
        let fixture = AgentStoreFixture(seed: 50)
        let event = fixture.acceptance.envelope.event
        let codec = JSONAgentEventCodec()

        let first = try codec.encode(event)
        let second = try codec.encode(event)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try codec.decode(first), event)
        XCTAssertThrowsError(try codec.decode(Data("not-json".utf8))) { error in
            XCTAssertEqual(error as? AgentEventCodecError, .decodingFailed)
        }
    }

    func testV10JournalReplayUsesExplicitLegacyDefaultsWithoutReinterpretation() async throws {
        let fixture = AgentStoreFixture(seed: 51)
        XCTAssertEqual(fixture.context.schemaVersion, .v1)
        let attemptID: AttemptID = storeTagged(51_777)
        let started = fixture.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "start"
        )
        let request = fixture.envelope(
            3,
            payload: .modelRequestStarted(ModelRequestStartedEvent(
                attemptID: attemptID,
                route: ModelRoute(
                    provider: "legacy-provider",
                    model: "legacy-model",
                    adapter: "legacy-adapter"
                )
            )),
            key: "legacy-request"
        )
        let response = fixture.envelope(
            4,
            payload: .modelResponseCommitted(ModelResponseCommittedEvent(
                attemptID: attemptID,
                items: [],
                usage: ModelUsage(inputTokens: 5, outputTokens: 2),
                finishReason: .completed
            )),
            key: "legacy-response"
        )
        let completed = fixture.envelope(
            5,
            payload: .runCompleted(RunCompletedEvent()),
            key: "complete"
        )
        let codec = JSONAgentEventCodec()
        let metadataBytes = try JSONEncoder().encode(fixture.acceptance.metadata)
        let metadataObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: metadataBytes) as? [String: Any]
        )
        XCTAssertNil(metadataObject["acceptedEngineVersion"])
        XCTAssertEqual(
            try JSONDecoder().decode(
                AgentRunMetadataRecord.self,
                from: metadataBytes
            ),
            fixture.acceptance.metadata
        )
        let bytes = try codec.encode(request.event)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        let body = try XCTUnwrap(payload["body"] as? [String: Any])
        XCTAssertNil(body["providerAttempt"])

        let decoded = try codec.decode(bytes)
        guard case let .modelRequestStarted(decodedRequest) = decoded.payload else {
            return XCTFail("Expected legacy model request")
        }
        XCTAssertEqual(decodedRequest.providerAttempt, .legacyV1)

        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(fixture.acceptance)
        _ = try await store.append(started)
        _ = try await store.append(AgentEventEnvelope(
            writerID: request.writerID,
            writerSequence: request.writerSequence,
            idempotencyKey: request.idempotencyKey,
            event: decoded
        ))
        _ = try await store.append(response)
        _ = try await store.append(completed)
        let records = try await store.events(for: fixture.runID, after: nil)
        let state = try AgentJournalReplay.replay(
            records,
            metadata: fixture.acceptance.metadata
        )

        XCTAssertEqual(state.phase, .completed)
        XCTAssertEqual(state.modelAttempts.first?.providerAttempt, .legacyV1)
        XCTAssertNil(state.modelAttempts.first?.usage)
        XCTAssertNil(state.modelAttempts.first?.finishReason)
    }

    func testV11JournalReplayRestoresExactProviderDispatchAndResponseFacts() async throws {
        let fixture = AgentStoreFixture(seed: 52, schemaVersion: .v1_1)
        let attemptID: AttemptID = storeTagged(52_777)
        let providerAttempt: ProviderAttemptJournalMetadata = .recordedV1_1(
            requestDigest: try AgentCanonicalSHA256Digest(
                "sha256:" + String(repeating: "de", count: 32)
            ),
            scope: try ProviderAttemptScopeReference(
                requestID: "v11-request",
                attemptID: "v11-attempt"
            ),
            ordinal: 4,
            recoverySeed: 0xBEEF
        )
        let usage = ModelUsage(
            inputTokens: 9,
            cachedInputTokens: 3,
            outputTokens: 4,
            costMicrounits: 77
        )
        let envelopes = [
            fixture.envelope(
                2,
                payload: .runStarted(RunStartedEvent()),
                key: "start"
            ),
            fixture.envelope(
                3,
                payload: .modelRequestStarted(ModelRequestStartedEvent(
                    attemptID: attemptID,
                    route: ModelRoute(
                        provider: "provider",
                        model: "model",
                        adapter: "adapter"
                    ),
                    providerAttempt: providerAttempt
                )),
                key: "request"
            ),
            fixture.envelope(
                4,
                payload: .modelResponseCommitted(ModelResponseCommittedEvent(
                    attemptID: attemptID,
                    items: [],
                    usage: usage,
                    finishReason: .length
                )),
                key: "response"
            ),
            fixture.envelope(
                5,
                payload: .runCompleted(RunCompletedEvent()),
                key: "complete"
            ),
        ]
        let codec = JSONAgentEventCodec()
        let requestBytes = try codec.encode(envelopes[1].event)
        let requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestBytes) as? [String: Any]
        )
        let payload = try XCTUnwrap(requestObject["payload"] as? [String: Any])
        let body = try XCTUnwrap(payload["body"] as? [String: Any])
        XCTAssertNotNil(body["providerAttempt"])

        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(fixture.acceptance)
        for envelope in envelopes {
            _ = try await store.append(envelope)
        }
        let recovered = try await AgentJournalRecovery(store: store)
            .recover(fixture.runID)
        let attempt = try XCTUnwrap(recovered?.state.modelAttempts.first)

        XCTAssertEqual(recovered?.state.phase, .completed)
        XCTAssertEqual(attempt.providerAttempt, providerAttempt)
        XCTAssertEqual(attempt.usage, usage)
        XCTAssertEqual(attempt.finishReason, .length)
        XCTAssertEqual(
            recovered?.metadata.acceptedEngineVersion,
            .agentHarnessV2
        )
    }

    func testReplayRejectsCorruptWriterSequenceInsteadOfRepairingIt() async throws {
        let fixture = AgentStoreFixture(seed: 60)
        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(fixture.acceptance)
        let started = fixture.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "start"
        )
        _ = try await store.append(started)
        var snapshot = await store.durableSnapshot()
        let corruptEnvelope = AgentEventEnvelope(
            writerID: started.writerID,
            writerSequence: EventSequence(rawValue: 3),
            idempotencyKey: started.idempotencyKey,
            event: started.event
        )
        let corruptRecord = StoredAgentEvent(
            offset: snapshot.records[1].offset,
            committedAt: snapshot.records[1].committedAt,
            envelope: corruptEnvelope
        )
        snapshot = InMemoryAgentEventJournalSnapshot(
            metadata: snapshot.metadata,
            records: [snapshot.records[0], corruptRecord],
            cursors: snapshot.cursors,
            highWaterMark: snapshot.highWaterMark
        )

        let error: (any Error)?
        do {
            _ = try InMemoryAgentEventJournal(restoring: snapshot)
            error = nil
        } catch let caught {
            error = caught
        }
        XCTAssertEqual(
            error as? AgentStoreError,
            .corruptJournal(
                runID: fixture.runID,
                reason: .invalidEnvelope(
                    .writerEventSequenceMismatch(
                        writerSequence: EventSequence(rawValue: 3),
                        eventSequence: EventSequence(rawValue: 2)
                    )
                )
            )
        )
    }

    func testReplayRejectsOriginOffsetAndRevalidatesAcceptanceMetadata() async throws {
        let fixture = AgentStoreFixture(seed: 61)
        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(fixture.acceptance)
        let snapshot = await store.durableSnapshot()
        let committed = snapshot.records[0]
        let originRecord = StoredAgentEvent(
            offset: .origin,
            committedAt: committed.committedAt,
            envelope: committed.envelope
        )

        XCTAssertEqual(
            caughtReplayError(
                records: [originRecord],
                metadata: fixture.acceptance.metadata
            ),
            .corruptJournal(
                runID: fixture.runID,
                reason: .invalidOffset(.origin)
            )
        )

        let wrongEventID: EventID = storeTagged(88_001)
        let tamperedMetadata = AgentRunMetadataRecord(
            context: fixture.context,
            writerID: fixture.writerID,
            acceptanceCommandID: fixture.commandID,
            acceptanceEventID: wrongEventID
        )
        XCTAssertEqual(
            caughtReplayError(
                records: snapshot.records,
                metadata: tamperedMetadata
            ),
            .corruptJournal(
                runID: fixture.runID,
                reason: .invalidAcceptance(.metadataEventMismatch)
            )
        )
    }

    func testSnapshotRestoreRejectsGlobalDuplicateEventIDIdempotencyAndCommand() async throws {
        let first = AgentStoreFixture(seed: 62)
        let second = AgentStoreFixture(seed: 63)
        let firstStore = InMemoryAgentEventJournal()
        let secondStore = InMemoryAgentEventJournal()
        _ = try await firstStore.accept(first.acceptance)
        _ = try await secondStore.accept(second.acceptance)
        let firstSnapshot = await firstStore.durableSnapshot()
        let secondSnapshot = await secondStore.durableSnapshot()

        let duplicateEventEnvelope = replacingEventID(
            in: secondSnapshot.records[0].envelope,
            with: firstSnapshot.records[0].event.header.eventID
        )
        let duplicateEventMetadata = AgentRunMetadataRecord(
            context: second.context,
            writerID: second.writerID,
            acceptanceCommandID: second.commandID,
            acceptanceEventID: firstSnapshot.records[0].event.header.eventID
        )
        let duplicateEventRecord = StoredAgentEvent(
            offset: AgentJournalOffset(rawValue: 2),
            committedAt: secondSnapshot.records[0].committedAt,
            envelope: duplicateEventEnvelope
        )
        let duplicateEventSnapshot = InMemoryAgentEventJournalSnapshot(
            metadata: [first.acceptance.metadata, duplicateEventMetadata],
            records: [firstSnapshot.records[0], duplicateEventRecord],
            cursors: [],
            highWaterMark: AgentJournalOffset(rawValue: 2)
        )
        XCTAssertEqual(
            caughtRestoreError(duplicateEventSnapshot),
            .corruptJournal(
                runID: second.runID,
                reason: .duplicateEventID(
                    firstSnapshot.records[0].event.header.eventID
                )
            )
        )

        let idempotencyStore = InMemoryAgentEventJournal()
        _ = try await idempotencyStore.accept(first.acceptance)
        _ = try await idempotencyStore.append(first.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "start"
        ))
        let idempotencySnapshot = await idempotencyStore.durableSnapshot()
        let duplicateKeyEnvelope = AgentEventEnvelope(
            writerID: idempotencySnapshot.records[1].envelope.writerID,
            writerSequence: idempotencySnapshot.records[1].envelope.writerSequence,
            idempotencyKey: idempotencySnapshot.records[0].envelope.idempotencyKey,
            event: idempotencySnapshot.records[1].event
        )
        let duplicateKeyRecord = StoredAgentEvent(
            offset: idempotencySnapshot.records[1].offset,
            committedAt: idempotencySnapshot.records[1].committedAt,
            envelope: duplicateKeyEnvelope
        )
        let duplicateKeySnapshot = InMemoryAgentEventJournalSnapshot(
            metadata: idempotencySnapshot.metadata,
            records: [idempotencySnapshot.records[0], duplicateKeyRecord],
            cursors: [],
            highWaterMark: idempotencySnapshot.highWaterMark
        )
        XCTAssertEqual(
            caughtRestoreError(duplicateKeySnapshot),
            .corruptJournal(
                runID: first.runID,
                reason: .duplicateIdempotencyKey(
                    writerID: first.writerID,
                    key: first.acceptance.envelope.idempotencyKey
                )
            )
        )

        let duplicateCommandMetadata = AgentRunMetadataRecord(
            context: second.context,
            writerID: second.writerID,
            acceptanceCommandID: first.commandID,
            acceptanceEventID: second.acceptance.envelope.event.header.eventID
        )
        let secondRecord = StoredAgentEvent(
            offset: AgentJournalOffset(rawValue: 2),
            committedAt: secondSnapshot.records[0].committedAt,
            envelope: secondSnapshot.records[0].envelope
        )
        let duplicateCommandSnapshot = InMemoryAgentEventJournalSnapshot(
            metadata: [first.acceptance.metadata, duplicateCommandMetadata],
            records: [firstSnapshot.records[0], secondRecord],
            cursors: [],
            highWaterMark: AgentJournalOffset(rawValue: 2)
        )
        XCTAssertEqual(
            caughtRestoreError(duplicateCommandSnapshot),
            .corruptJournal(
                runID: second.runID,
                reason: .duplicateAcceptanceCommand(first.commandID)
            )
        )
    }

    func testRecoveryRechecksMetadataWhenAcceptanceCommitsBetweenReads() async throws {
        let fixture = AgentStoreFixture(seed: 64)
        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(fixture.acceptance)
        let snapshot = await store.durableSnapshot()
        let racingStore = AcceptanceRaceReadStore(
            metadata: fixture.acceptance.metadata,
            records: snapshot.records
        )

        let recovered = try await AgentJournalRecovery(store: racingStore)
            .recover(fixture.runID)
        let metadataReadCount = await racingStore.metadataReadCount

        XCTAssertEqual(recovered?.state.phase, .accepted)
        XCTAssertEqual(metadataReadCount, 2)
    }
}

private actor AcceptanceRaceReadStore: AgentEventReading {
    private let storedMetadata: AgentRunMetadataRecord
    private let storedRecords: [StoredAgentEvent]
    private(set) var metadataReadCount = 0

    init(
        metadata: AgentRunMetadataRecord,
        records: [StoredAgentEvent]
    ) {
        storedMetadata = metadata
        storedRecords = records
    }

    func metadata(for runID: RunID) async throws -> AgentRunMetadataRecord? {
        metadataReadCount += 1
        return metadataReadCount == 1 ? nil : storedMetadata
    }

    func events(
        for runID: RunID,
        after sequence: EventSequence?
    ) async throws -> [StoredAgentEvent] {
        storedRecords
    }

    func projectionBatch(
        after offset: AgentJournalOffset,
        limit: Int
    ) async throws -> AgentProjectionBatch {
        AgentProjectionBatch(
            afterOffset: offset,
            highWaterMark: storedRecords.last?.offset ?? .origin,
            records: storedRecords.filter { $0.offset > offset }
        )
    }
}

private func caughtReplayError(
    records: [StoredAgentEvent],
    metadata: AgentRunMetadataRecord
) -> AgentStoreError? {
    do {
        _ = try AgentJournalReplay.replay(records, metadata: metadata)
        return nil
    } catch let error as AgentStoreError {
        return error
    } catch {
        return .persistenceFailure(
            operation: .restoreSnapshot,
            code: "unexpected_replay_error"
        )
    }
}

private func caughtRestoreError(
    _ snapshot: InMemoryAgentEventJournalSnapshot
) -> AgentStoreError? {
    do {
        _ = try InMemoryAgentEventJournal(restoring: snapshot)
        return nil
    } catch let error as AgentStoreError {
        return error
    } catch {
        return .persistenceFailure(
            operation: .restoreSnapshot,
            code: "unexpected_restore_error"
        )
    }
}

private func replacingEventID(
    in envelope: AgentEventEnvelope,
    with eventID: EventID
) -> AgentEventEnvelope {
    let header = envelope.event.header
    let event = AgentEvent(
        header: AgentEventHeader(
            eventID: eventID,
            schemaVersion: header.schemaVersion,
            runID: header.runID,
            rootRunID: header.rootRunID,
            parentRunID: header.parentRunID,
            sequence: header.sequence,
            timestamp: header.timestamp,
            executionNodeID: header.executionNodeID,
            conversationID: header.conversationID,
            projectID: header.projectID,
            workspaceID: header.workspaceID,
            causationID: header.causationID,
            correlationID: header.correlationID,
            engineVersion: header.engineVersion
        ),
        payload: envelope.event.payload
    )
    return AgentEventEnvelope(
        writerID: envelope.writerID,
        writerSequence: envelope.writerSequence,
        idempotencyKey: envelope.idempotencyKey,
        event: event
    )
}

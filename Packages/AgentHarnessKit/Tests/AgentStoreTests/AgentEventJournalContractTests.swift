import AgentDomain
import AgentStore
import Foundation
import XCTest

final class AgentEventJournalContractTests: XCTestCase {
    func testAcceptanceAtomicallyCommitsMetadataAndFirstEvent() async throws {
        let fixture = AgentStoreFixture()
        let store = InMemoryAgentEventJournal(
            clock: { AgentInstant(rawValue: 1_900_000_000_000) }
        )

        let commit = try await store.accept(fixture.acceptance)

        XCTAssertEqual(commit.disposition, .committed)
        XCTAssertEqual(commit.record.offset, AgentJournalOffset(rawValue: 1))
        XCTAssertEqual(commit.record.envelope, fixture.acceptance.envelope)
        let metadata = try await store.metadata(for: fixture.runID)
        let records = try await store.events(for: fixture.runID, after: nil)
        XCTAssertEqual(metadata, fixture.acceptance.metadata)
        XCTAssertEqual(records, [commit.record])

        let recovered = try await AgentJournalRecovery(store: store)
            .recover(fixture.runID)
        XCTAssertEqual(recovered?.state.phase, .accepted)
        XCTAssertEqual(recovered?.eventCount, 1)
    }

    func testAcceptanceRejectsMetadataOrPayloadEngineSubstitution() async throws {
        let fixture = AgentStoreFixture(seed: 2)
        let metadataSubstitution = AgentRunAcceptance(
            metadata: AgentRunMetadataRecord(
                context: fixture.context,
                acceptedEngineVersion: .agentHarnessV2,
                writerID: fixture.writerID,
                acceptanceCommandID: fixture.commandID,
                acceptanceEventID: fixture.acceptance.envelope.event.header.eventID
            ),
            envelope: fixture.acceptance.envelope
        )
        let metadataError = await caughtError {
            try await InMemoryAgentEventJournal().accept(metadataSubstitution)
        }
        XCTAssertEqual(
            metadataError as? AgentStoreError,
            .invalidAcceptance(.metadataEngineVersionMismatch)
        )

        let original = fixture.acceptance.envelope
        let payloadSubstitution = AgentRunAcceptance(
            metadata: fixture.acceptance.metadata,
            envelope: AgentEventEnvelope(
                writerID: original.writerID,
                writerSequence: original.writerSequence,
                idempotencyKey: original.idempotencyKey,
                event: AgentEvent(
                    header: original.event.header,
                    payload: .runAccepted(RunAcceptedEvent(
                        context: fixture.context,
                        acceptedEngineVersion: .agentHarnessV2,
                        initialItems: [fixture.userItem]
                    ))
                )
            )
        )
        let payloadError = await caughtError {
            try await InMemoryAgentEventJournal().accept(payloadSubstitution)
        }
        XCTAssertEqual(
            payloadError as? AgentStoreError,
            .invalidAcceptance(.payloadEngineVersionMismatch)
        )
    }

    func testNoWorkIsEnqueuedBeforeAcceptanceCommit() async throws {
        let fixture = AgentStoreFixture()
        let store = InMemoryAgentEventJournal()
        let queue = AgentWorkQueueSpy()
        let coordinator = AgentRunAcceptanceCoordinator(store: store)
        await store.failNext(.acceptanceSave, code: "accept_save_failed")

        let error = await caughtError {
            try await coordinator.acceptAndEnqueue(
                fixture.acceptance,
                workQueue: queue
            )
        }

        XCTAssertEqual(
            error as? AgentStoreError,
            .persistenceFailure(
                operation: .acceptRun,
                code: "accept_save_failed"
            )
        )
        let queuedAfterFailure = await queue.count
        let metadataAfterFailure = try await store.metadata(for: fixture.runID)
        let eventsAfterFailure = try await store.events(
            for: fixture.runID,
            after: nil
        )
        XCTAssertEqual(queuedAfterFailure, 0)
        XCTAssertNil(metadataAfterFailure)
        XCTAssertEqual(eventsAfterFailure, [])

        let committed = try await coordinator.acceptAndEnqueue(
            fixture.acceptance,
            workQueue: queue
        )
        XCTAssertEqual(committed.disposition, .committed)
        let queuedAfterCommit = await queue.count
        XCTAssertEqual(queuedAfterCommit, 1)

        let duplicate = try await coordinator.acceptAndEnqueue(
            fixture.acceptance,
            workQueue: queue
        )
        XCTAssertEqual(duplicate.disposition, .alreadyCommitted)
        let queuedAfterDuplicate = await queue.count
        XCTAssertEqual(queuedAfterDuplicate, 1)
    }

    func testAppendSaveFailureLeavesNoGhostEventOrIdempotencyReservation() async throws {
        let fixture = AgentStoreFixture()
        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(fixture.acceptance)
        let started = fixture.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "start"
        )
        await store.failNext(.appendSave, code: "event_save_failed")

        let error = await caughtError { try await store.append(started) }

        XCTAssertEqual(
            error as? AgentStoreError,
            .persistenceFailure(
                operation: .appendEvent,
                code: "event_save_failed"
            )
        )
        let recordsAfterFailure = try await store.events(
            for: fixture.runID,
            after: nil
        )
        let recoveredAfterFailure = try await AgentJournalRecovery(store: store)
            .recover(fixture.runID)
        XCTAssertEqual(recordsAfterFailure.count, 1)
        XCTAssertEqual(recoveredAfterFailure?.state.phase, .accepted)

        let retry = try await store.append(started)
        XCTAssertEqual(retry.disposition, .committed)
        XCTAssertEqual(retry.record.offset, AgentJournalOffset(rawValue: 2))
        let recoveredAfterRetry = try await AgentJournalRecovery(store: store)
            .recover(fixture.runID)
        XCTAssertEqual(recoveredAfterRetry?.state.phase, .running)
    }

    func testExactDuplicateIsIdempotentUnderConcurrentRetries() async throws {
        let fixture = AgentStoreFixture()
        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(fixture.acceptance)
        let started = fixture.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "same-start"
        )

        let dispositions = try await withThrowingTaskGroup(
            of: AgentJournalCommitDisposition.self
        ) { group in
            for _ in 0..<24 {
                group.addTask {
                    try await store.append(started).disposition
                }
            }
            var values: [AgentJournalCommitDisposition] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(dispositions.filter { $0 == .committed }.count, 1)
        XCTAssertEqual(
            dispositions.filter { $0 == .alreadyCommitted }.count,
            23
        )
        let records = try await store.events(for: fixture.runID, after: nil)
        XCTAssertEqual(records.count, 2)
    }

    func testConflictingDuplicateKeyEventIDAndSequenceFailClosed() async throws {
        let fixture = AgentStoreFixture()
        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(fixture.acceptance)
        let started = fixture.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "start"
        )
        _ = try await store.append(started)

        let keyConflict = fixture.envelope(
            2,
            payload: .runQueued(RunQueuedEvent(reason: "different")),
            key: "start",
            eventID: storeTagged(99_001)
        )
        let keyError = await caughtError {
            try await store.append(keyConflict)
        }
        XCTAssertEqual(
            keyError as? AgentStoreError,
            .idempotencyConflict(
                runID: fixture.runID,
                writerID: fixture.writerID,
                key: "start",
                existingEventID: started.event.header.eventID,
                incomingEventID: keyConflict.event.header.eventID
            )
        )

        let eventIDConflict = fixture.envelope(
            3,
            payload: .contextPrepared(
                ContextPreparedEvent(
                    itemIDs: [fixture.userItem.id],
                    estimatedTokens: 8,
                    contextDigest: "context"
                )
            ),
            key: "new-key",
            eventID: started.event.header.eventID
        )
        let eventError = await caughtError {
            try await store.append(eventIDConflict)
        }
        XCTAssertEqual(
            eventError as? AgentStoreError,
            .eventIDConflict(
                eventID: started.event.header.eventID,
                existingRunID: fixture.runID,
                incomingRunID: fixture.runID
            )
        )

        let sequenceConflict = fixture.envelope(
            2,
            payload: .runStarted(RunStartedEvent(resumed: true)),
            key: "other-key",
            eventID: storeTagged(99_002)
        )
        let sequenceError = await caughtError {
            try await store.append(sequenceConflict)
        }
        XCTAssertEqual(
            sequenceError as? AgentStoreError,
            .sequenceConflict(
                runID: fixture.runID,
                sequence: EventSequence(rawValue: 2),
                existingEventID: started.event.header.eventID,
                incomingEventID: sequenceConflict.event.header.eventID
            )
        )
        let records = try await store.events(for: fixture.runID, after: nil)
        XCTAssertEqual(records.count, 2)
    }

    func testSequenceGapAndNoncanonicalWriterAreRejected() async throws {
        let fixture = AgentStoreFixture()
        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(fixture.acceptance)
        let skipped = fixture.envelope(
            3,
            payload: .runStarted(RunStartedEvent()),
            key: "skipped"
        )

        let skippedError = await caughtError {
            try await store.append(skipped)
        }
        XCTAssertEqual(
            skippedError as? AgentStoreError,
            .nonMonotonicSequence(
                runID: fixture.runID,
                writerID: fixture.writerID,
                expected: EventSequence(rawValue: 2),
                actual: EventSequence(rawValue: 3)
            )
        )

        let wrongWriter = AgentEventWriterID(rawValue: storeTaggedRunUUID(90_000))
        let malformed = AgentRunAcceptance(
            metadata: AgentRunMetadataRecord(
                context: fixture.context,
                writerID: wrongWriter,
                acceptanceCommandID: fixture.commandID,
                acceptanceEventID: fixture.acceptance.envelope.event.header.eventID
            ),
            envelope: AgentEventEnvelope(
                writerID: wrongWriter,
                writerSequence: .first,
                idempotencyKey: fixture.acceptance.envelope.idempotencyKey,
                event: fixture.acceptance.envelope.event
            )
        )
        let otherStore = InMemoryAgentEventJournal()
        let malformedError = await caughtError {
            try await otherStore.accept(malformed)
        }
        XCTAssertEqual(
            malformedError as? AgentStoreError,
            .invalidAcceptance(.runWriterMismatch)
        )
    }

    func testDistinctRunsOnSameExecutionNodeHaveIndependentWriterSequences() async throws {
        let sharedNode: ExecutionNodeID = storeTagged(70_000)
        let first = AgentStoreFixture(seed: 10, executionNodeID: sharedNode)
        let second = AgentStoreFixture(seed: 11, executionNodeID: sharedNode)
        let store = InMemoryAgentEventJournal()

        let firstAcceptance = try await store.accept(first.acceptance)
        let secondAcceptance = try await store.accept(second.acceptance)

        XCTAssertNotEqual(first.writerID, second.writerID)
        XCTAssertEqual(firstAcceptance.record.envelope.writerSequence, .first)
        XCTAssertEqual(secondAcceptance.record.envelope.writerSequence, .first)
        XCTAssertEqual(first.context.executionNodeID, second.context.executionNodeID)

        _ = try await store.append(first.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "first-start"
        ))
        _ = try await store.append(second.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "second-start"
        ))

        let firstRecovered = try await AgentJournalRecovery(store: store)
            .recover(first.runID)
        let secondRecovered = try await AgentJournalRecovery(store: store)
            .recover(second.runID)
        let firstSequences = try await store.events(
            for: first.runID,
            after: nil
        ).map(\.envelope.writerSequence)
        let secondSequences = try await store.events(
            for: second.runID,
            after: nil
        ).map(\.envelope.writerSequence)
        XCTAssertEqual(firstRecovered?.state.phase, .running)
        XCTAssertEqual(secondRecovered?.state.phase, .running)
        XCTAssertEqual(
            firstSequences,
            [.first, EventSequence(rawValue: 2)]
        )
        XCTAssertEqual(
            secondSequences,
            [.first, EventSequence(rawValue: 2)]
        )
    }

    func testAcceptanceCommandCanCreateAtMostOneRun() async throws {
        let first = AgentStoreFixture(seed: 12)
        let second = AgentStoreFixture(seed: 13)
        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(first.acceptance)
        let duplicateCommandAcceptance = AgentRunAcceptance(
            metadata: AgentRunMetadataRecord(
                context: second.context,
                writerID: second.writerID,
                acceptanceCommandID: first.commandID,
                acceptanceEventID: second.acceptance.envelope.event.header.eventID
            ),
            envelope: second.acceptance.envelope
        )

        let error = await caughtError {
            try await store.accept(duplicateCommandAcceptance)
        }

        XCTAssertEqual(
            error as? AgentStoreError,
            .acceptanceCommandConflict(
                commandID: first.commandID,
                existingRunID: first.runID,
                incomingRunID: second.runID
            )
        )
        let secondMetadata = try await store.metadata(for: second.runID)
        XCTAssertNil(secondMetadata)
    }

    func testWhitespaceAndOversizedIdempotencyKeysFailClosed() async throws {
        let fixture = AgentStoreFixture(seed: 14)
        let cases: [(String, AgentEnvelopeValidationFailure)] = [
            (" \n\t ", .emptyIdempotencyKey),
            (
                String(
                    repeating: "x",
                    count: AgentJournalValidation.maximumIdempotencyKeyByteCount + 1
                ),
                .idempotencyKeyTooLong(
                    actual: AgentJournalValidation.maximumIdempotencyKeyByteCount + 1,
                    maximum: AgentJournalValidation.maximumIdempotencyKeyByteCount
                )
            ),
        ]

        for (key, expected) in cases {
            let malformed = AgentRunAcceptance(
                metadata: fixture.acceptance.metadata,
                envelope: AgentEventEnvelope(
                    writerID: fixture.writerID,
                    writerSequence: .first,
                    idempotencyKey: key,
                    event: fixture.acceptance.envelope.event
                )
            )
            let store = InMemoryAgentEventJournal()

            let error = await caughtError { try await store.accept(malformed) }
            let storedMetadata = try await store.metadata(for: fixture.runID)
            let storedEvents = try await store.events(for: fixture.runID, after: nil)

            XCTAssertEqual(error as? AgentStoreError, .invalidEnvelope(expected))
            XCTAssertNil(storedMetadata)
            XCTAssertTrue(storedEvents.isEmpty)
        }
    }

    func testInvalidProjectionAndBatchInputsFailClosed() async throws {
        let store = InMemoryAgentEventJournal()
        let invalidProjection = AgentProjectionID(rawValue: "  \n")

        let projectionError = await caughtError {
            try await store.loadCursor(for: invalidProjection)
        }
        let batchError = await caughtError {
            try await store.projectionBatch(after: .origin, limit: 0)
        }
        let futureOffsetError = await caughtError {
            try await store.projectionBatch(
                after: AgentJournalOffset(rawValue: 1),
                limit: 1
            )
        }

        XCTAssertEqual(projectionError as? AgentStoreError, .invalidProjectionID)
        XCTAssertEqual(batchError as? AgentStoreError, .invalidBatchLimit(0))
        XCTAssertEqual(
            futureOffsetError as? AgentStoreError,
            .offsetBeyondHighWaterMark(
                requested: AgentJournalOffset(rawValue: 1),
                highWaterMark: .origin
            )
        )
    }

    func testCompetingDifferentEventsAtOneSequenceHaveExactlyOneWinner() async throws {
        let fixture = AgentStoreFixture(seed: 15)
        let store = InMemoryAgentEventJournal()
        _ = try await store.accept(fixture.acceptance)
        let first = fixture.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "competing-a",
            eventID: storeTagged(150_001)
        )
        let second = fixture.envelope(
            2,
            payload: .runStarted(RunStartedEvent(resumed: true)),
            key: "competing-b",
            eventID: storeTagged(150_002)
        )

        async let firstResult = captureStoreResult { try await store.append(first) }
        async let secondResult = captureStoreResult { try await store.append(second) }
        let pair = await (firstResult, secondResult)
        let outcomes = [pair.0, pair.1]
        let commits = outcomes.compactMap { outcome -> AgentJournalCommit? in
            guard case let .success(commit) = outcome else { return nil }
            return commit
        }
        let failures = outcomes.compactMap { outcome -> AgentStoreError? in
            guard case let .failure(error) = outcome else { return nil }
            return error
        }

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(failures.count, 1)
        let winnerID = try XCTUnwrap(commits.first?.record.event.header.eventID)
        let loserID = winnerID == first.event.header.eventID
            ? second.event.header.eventID
            : first.event.header.eventID
        XCTAssertEqual(
            failures.first,
            .sequenceConflict(
                runID: fixture.runID,
                sequence: EventSequence(rawValue: 2),
                existingEventID: winnerID,
                incomingEventID: loserID
            )
        )
        let storedEvents = try await store.events(for: fixture.runID, after: nil)
        XCTAssertEqual(storedEvents.count, 2)
    }
}

private func storeTaggedRunUUID(_ value: UInt64) -> UUID {
    let runID: RunID = storeTagged(value)
    return runID.rawValue
}

private func captureStoreResult<T: Sendable>(
    _ operation: @Sendable () async throws -> T
) async -> Result<T, AgentStoreError> {
    do {
        return .success(try await operation())
    } catch let error as AgentStoreError {
        return .failure(error)
    } catch {
        return .failure(
            .persistenceFailure(
                operation: .appendEvent,
                code: "unexpected_test_error"
            )
        )
    }
}

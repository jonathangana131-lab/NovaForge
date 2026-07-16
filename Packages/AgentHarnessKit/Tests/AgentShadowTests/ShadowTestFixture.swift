import AgentDomain
import AgentStore
import Foundation

struct ShadowTestFixture: Sendable {
    let context: AgentRunContext
    let writerID: AgentEventWriterID
    let commandID: CommandID
    let correlationID: CorrelationID
    let userItem: ModelItem
    let firstAttemptID: AttemptID
    let secondAttemptID: AttemptID
    let invocation: ToolInvocation
    let assistantItem: ModelItem
    let artifact: ArtifactReference

    init(seed: UInt64 = 7) {
        let runID: RunID = shadowID(seed * 1_000 + 1)
        let acceptedAt = AgentInstant(rawValue: 1_900_000_000_000)
        context = AgentRunContext(
            schemaVersion: .v1,
            lineage: .root(runID),
            conversationID: shadowID(seed * 1_000 + 2),
            projectID: shadowID(seed * 1_000 + 3),
            workspaceID: shadowID(seed * 1_000 + 4),
            executionNodeID: shadowID(seed * 1_000 + 5),
            engineVersion: .agentHarnessV1,
            acceptedAt: acceptedAt,
            features: AgentFeatureSet(["developer-canary", "shadow-replay"]),
            cancellation: CancellationLineage(
                scopeID: shadowID(seed * 1_000 + 6)
            ),
            initialBudget: AgentBudget(limits: .standard)
        )
        writerID = AgentEventWriterID(runID: runID)
        commandID = shadowID(seed * 1_000 + 7)
        correlationID = shadowID(seed * 1_000 + 8)
        userItem = ModelItem(
            id: shadowID(seed * 1_000 + 9),
            createdAt: acceptedAt,
            payload: .message(ModelMessage(
                role: .user,
                content: [.text("Inspect the workspace and report the result.")]
            ))
        )
        firstAttemptID = shadowID(seed * 1_000 + 10)
        secondAttemptID = shadowID(seed * 1_000 + 11)
        artifact = ArtifactReference(
            artifactID: shadowID(seed * 1_000 + 12),
            mediaType: "text/plain",
            contentDigest: "sha256:artifact",
            displayName: "inspection.txt"
        )
        invocation = ToolInvocation(
            callID: shadowID(seed * 1_000 + 13),
            modelAttemptID: secondAttemptID,
            tool: ToolIdentity(name: "write_file", version: "1.0.0"),
            arguments: .object([
                "path": .string("inspection.txt"),
                "contents": .string("recorded historical effect"),
            ]),
            canonicalArgumentDigest: "sha256:arguments",
            idempotencyKey: "shadow-tool-effect",
            effectClass: .scopedReversibleWrite,
            locality: .onDevice
        )
        assistantItem = ModelItem(
            id: shadowID(seed * 1_000 + 14),
            createdAt: AgentInstant(rawValue: acceptedAt.rawValue + 6),
            payload: .message(ModelMessage(
                role: .assistant,
                content: [.text("Clean committed response")]
            ))
        )
    }

    var runID: RunID { context.lineage.runID }

    var acceptance: AgentRunAcceptance {
        let first = envelope(
            1,
            payload: .runAccepted(RunAcceptedEvent(
                context: context,
                initialItems: [userItem]
            )),
            key: "accept"
        )
        return AgentRunAcceptance(
            metadata: AgentRunMetadataRecord(
                context: context,
                writerID: writerID,
                acceptanceCommandID: commandID,
                acceptanceEventID: first.event.header.eventID
            ),
            envelope: first
        )
    }

    var envelopes: [AgentEventEnvelope] {
        let failedError = AgentErrorInfo(
            category: .transport,
            code: "temporary_failure",
            publicMessage: "Temporary hosted transport failure",
            retryable: true
        )
        let route = ModelRoute(
            provider: "hosted-fixture",
            model: "fixture-text-model",
            adapter: "responses"
        )
        let result = ToolResult(
            modelItemID: shadowID(90_001),
            callID: invocation.callID,
            status: .succeeded,
            output: .object(["ok": .bool(true)]),
            artifacts: [artifact],
            evidence: [ToolEvidence(
                kind: "result_hash",
                digest: "sha256:result"
            )]
        )
        return [
            envelope(2, payload: .runStarted(RunStartedEvent()), key: "start"),
            envelope(3, payload: .modelRequestStarted(ModelRequestStartedEvent(
                attemptID: firstAttemptID,
                route: route
            )), key: "attempt-one"),
            envelope(4, payload: .modelRequestFailed(ModelRequestFailedEvent(
                attemptID: firstAttemptID,
                error: failedError,
                outputWasCommitted: false
            )), key: "attempt-one-failed"),
            envelope(5, payload: .retryScheduled(RetryScheduledEvent(
                failedAttemptID: firstAttemptID,
                nextAttemptID: secondAttemptID,
                reason: "clean retry"
            )), key: "retry"),
            envelope(6, payload: .modelRequestStarted(ModelRequestStartedEvent(
                attemptID: secondAttemptID,
                route: route
            )), key: "attempt-two"),
            envelope(7, payload: .modelResponseCommitted(ModelResponseCommittedEvent(
                attemptID: secondAttemptID,
                items: [
                    assistantItem,
                    ModelItem(
                        id: shadowID(90_002),
                        createdAt: instant(7),
                        payload: .toolInvocation(invocation)
                    ),
                ],
                usage: ModelUsage(inputTokens: 40, outputTokens: 8),
                finishReason: .toolCalls
            )), key: "attempt-two-committed"),
            envelope(8, payload: .toolProposed(ToolProposedEvent(
                invocation: invocation
            )), key: "tool-proposed"),
            envelope(9, payload: .toolScheduled(ToolScheduledEvent(
                callID: invocation.callID
            )), key: "tool-scheduled"),
            envelope(10, payload: .toolStarted(ToolStartedEvent(
                callID: invocation.callID
            )), key: "tool-started"),
            envelope(11, payload: .toolApplied(ToolAppliedEvent(
                callID: invocation.callID,
                evidence: [ToolEvidence(
                    kind: "post_hash",
                    digest: "sha256:applied"
                )]
            )), key: "tool-applied"),
            envelope(12, payload: .toolCompleted(ToolCompletedEvent(
                result: result
            )), key: "tool-completed"),
            envelope(13, payload: .artifactCaptured(ArtifactCapturedEvent(
                artifact: artifact
            )), key: "artifact"),
            envelope(14, payload: .runCompleted(RunCompletedEvent(
                summary: "Fixture complete"
            )), key: "complete"),
        ]
    }

    func makeStore() async throws -> InMemoryAgentEventJournal {
        let store = InMemoryAgentEventJournal(
            clock: { AgentInstant(rawValue: 2_000_000_000_000) }
        )
        _ = try await store.accept(acceptance)
        for envelope in envelopes {
            _ = try await store.append(envelope)
        }
        return store
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
                    eventID: shadowID(50_000 + sequenceValue),
                    schemaVersion: context.schemaVersion,
                    context: context,
                    sequence: sequence,
                    timestamp: instant(sequenceValue),
                    causationID: shadowID(60_000 + sequenceValue),
                    correlationID: correlationID
                ),
                payload: payload
            )
        )
    }

    func instant(_ sequence: UInt64) -> AgentInstant {
        AgentInstant(
            rawValue: context.acceptedAt.rawValue + Int64(sequence - 1)
        )
    }
}

func shadowID<Tag: AgentIdentifierTag>(
    _ value: UInt64
) -> AgentIdentifier<Tag> {
    let suffix = String(format: "%012llX", value)
    return AgentIdentifier(
        rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-\(suffix)"
        )!
    )
}

struct ShadowTripwireCounts: Equatable, Sendable {
    let acceptCalls: Int
    let appendCalls: Int
    let projectionReadCalls: Int
    let cursorReadCalls: Int
    let cursorWriteCalls: Int
    let effectCalls: Int
}

enum ShadowTripwireError: Error {
    case forbiddenWrite
}

/// Deliberately conforms to the full journal protocol so the test can prove
/// that erasing it to AgentEventReading never exercises its write capabilities.
actor ShadowJournalTripwire: AgentEventJournal {
    private let metadataRecord: AgentRunMetadataRecord?
    private let storedRecords: [StoredAgentEvent]
    private var acceptCalls = 0
    private var appendCalls = 0
    private var projectionReadCalls = 0
    private var cursorReadCalls = 0
    private var cursorWriteCalls = 0
    private var effectCalls = 0

    init(metadata: AgentRunMetadataRecord?, records: [StoredAgentEvent]) {
        metadataRecord = metadata
        storedRecords = records
    }

    func accept(_ acceptance: AgentRunAcceptance) async throws -> AgentJournalCommit {
        acceptCalls += 1
        throw ShadowTripwireError.forbiddenWrite
    }

    func append(_ envelope: AgentEventEnvelope) async throws -> AgentJournalCommit {
        appendCalls += 1
        throw ShadowTripwireError.forbiddenWrite
    }

    func metadata(for runID: RunID) async throws -> AgentRunMetadataRecord? {
        guard metadataRecord?.runID == runID else { return nil }
        return metadataRecord
    }

    func events(
        for runID: RunID,
        after sequence: EventSequence?
    ) async throws -> [StoredAgentEvent] {
        storedRecords.filter { record in
            guard record.runID == runID else { return false }
            guard let sequence else { return true }
            return record.envelope.writerSequence > sequence
        }
    }

    func projectionBatch(
        after offset: AgentJournalOffset,
        limit: Int
    ) async throws -> AgentProjectionBatch {
        projectionReadCalls += 1
        return AgentProjectionBatch(
            afterOffset: offset,
            highWaterMark: storedRecords.last?.offset ?? .origin,
            records: []
        )
    }

    func loadCursor(
        for projectionID: AgentProjectionID
    ) async throws -> AgentProjectionCursor? {
        cursorReadCalls += 1
        return nil
    }

    func saveCursor(
        _ cursor: AgentProjectionCursor,
        expectedPreviousOffset: AgentJournalOffset
    ) async throws -> AgentProjectionCursorCommit {
        cursorWriteCalls += 1
        throw ShadowTripwireError.forbiddenWrite
    }

    func recordForbiddenEffectIfCalled() {
        effectCalls += 1
    }

    var counts: ShadowTripwireCounts {
        ShadowTripwireCounts(
            acceptCalls: acceptCalls,
            appendCalls: appendCalls,
            projectionReadCalls: projectionReadCalls,
            cursorReadCalls: cursorReadCalls,
            cursorWriteCalls: cursorWriteCalls,
            effectCalls: effectCalls
        )
    }
}

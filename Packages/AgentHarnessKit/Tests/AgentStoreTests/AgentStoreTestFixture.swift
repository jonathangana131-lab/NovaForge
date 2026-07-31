import AgentDomain
import AgentStore
import Foundation

struct AgentStoreFixture: Sendable {
    let context: AgentRunContext
    let writerID: AgentEventWriterID
    let commandID: CommandID
    let correlationID: CorrelationID
    let userItem: ModelItem
    private let seed: UInt64

    init(
        seed: UInt64 = 1,
        executionNodeID: ExecutionNodeID? = nil,
        schemaVersion: AgentSchemaVersion = .v1
    ) {
        self.seed = seed
        let runID: RunID = storeTagged(seed * 100 + 1)
        let acceptedAt = AgentInstant(
            rawValue: 1_800_000_000_000 + Int64(seed * 1_000)
        )
        context = AgentRunContext(
            schemaVersion: schemaVersion,
            lineage: .root(runID),
            conversationID: storeTagged(seed * 100 + 2),
            projectID: storeTagged(seed * 100 + 3),
            workspaceID: storeTagged(seed * 100 + 4),
            executionNodeID: executionNodeID ?? storeTagged(seed * 100 + 5),
            engineVersion: schemaVersion >= .v1_1
                ? .agentHarnessV2
                : .agentHarnessV1,
            acceptedAt: acceptedAt,
            features: AgentFeatureSet(["event-journal", "recovery"]),
            cancellation: CancellationLineage(
                scopeID: storeTagged(seed * 100 + 6)
            ),
            initialBudget: AgentBudget(limits: .standard)
        )
        writerID = AgentEventWriterID(runID: runID)
        commandID = storeTagged(seed * 100 + 7)
        correlationID = storeTagged(seed * 100 + 8)
        userItem = ModelItem(
            id: storeTagged(seed * 100 + 9),
            createdAt: acceptedAt,
            payload: .message(
                ModelMessage(
                    role: .user,
                    content: [.text("Run fixture \(seed)")]
                )
            )
        )
    }

    var runID: RunID { context.lineage.runID }

    var acceptance: AgentRunAcceptance {
        let envelope = envelope(
            1,
            payload: .runAccepted(
                RunAcceptedEvent(
                    context: context,
                    initialItems: [userItem]
                )
            ),
            key: "accept-\(runID)"
        )
        return AgentRunAcceptance(
            metadata: AgentRunMetadataRecord(
                context: context,
                writerID: writerID,
                acceptanceCommandID: commandID,
                acceptanceEventID: envelope.event.header.eventID
            ),
            envelope: envelope
        )
    }

    func envelope(
        _ sequence: UInt64,
        payload: AgentEventPayload,
        key: String,
        eventID: EventID? = nil
    ) -> AgentEventEnvelope {
        let sequence = EventSequence(rawValue: sequence)
        return AgentEventEnvelope(
            writerID: writerID,
            writerSequence: sequence,
            idempotencyKey: key,
            event: AgentEvent(
                header: AgentEventHeader(
                    eventID: eventID ?? self.eventID(sequence.rawValue),
                    schemaVersion: context.schemaVersion,
                    context: context,
                    sequence: sequence,
                    timestamp: instant(sequence.rawValue),
                    causationID: storeTagged(seed * 100 + 10),
                    correlationID: correlationID
                ),
                payload: payload
            )
        )
    }

    func eventID(_ sequence: UInt64) -> EventID {
        storeTagged(seed * 10_000 + 1_000 + sequence)
    }

    func instant(_ sequence: UInt64) -> AgentInstant {
        if sequence == 1 { return context.acceptedAt }
        return AgentInstant(
            rawValue: context.acceptedAt.rawValue + Int64(sequence)
        )
    }
}

func storeTagged<Tag: AgentIdentifierTag>(
    _ value: UInt64
) -> AgentIdentifier<Tag> {
    let suffix = String(format: "%012llX", value)
    return AgentIdentifier(
        rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-\(suffix)"
        )!
    )
}

actor AgentWorkQueueSpy: AgentRunWorkEnqueuing {
    private(set) var acceptedRunIDs: [RunID] = []

    func enqueue(_ acceptance: CommittedAgentRunAcceptance) async {
        acceptedRunIDs.append(acceptance.acceptance.metadata.runID)
    }

    var count: Int { acceptedRunIDs.count }
}

func caughtError<T: Sendable>(
    _ operation: @Sendable () async throws -> T
) async -> (any Error)? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return error
    }
}

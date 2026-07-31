import AgentDomain
import Foundation

/// Durable, atomic acceptance boundary. Implementations must not return a
/// `.committed` receipt until both metadata and the first event are durable.
public protocol AgentRunAcceptancePersisting: Sendable {
    func accept(_ acceptance: AgentRunAcceptance) async throws -> AgentJournalCommit
}

/// Append-only event boundary. Implementations must provide writer/run-scoped
/// contiguous sequencing and idempotent retry semantics.
public protocol AgentEventAppending: Sendable {
    func append(_ envelope: AgentEventEnvelope) async throws -> AgentJournalCommit
}

public protocol AgentEventReading: Sendable {
    func metadata(for runID: RunID) async throws -> AgentRunMetadataRecord?

    func events(
        for runID: RunID,
        after sequence: EventSequence?
    ) async throws -> [StoredAgentEvent]

    func projectionBatch(
        after offset: AgentJournalOffset,
        limit: Int
    ) async throws -> AgentProjectionBatch
}

public protocol AgentProjectionCursorPersisting: Sendable {
    func loadCursor(
        for projectionID: AgentProjectionID
    ) async throws -> AgentProjectionCursor?

    /// Compare-and-set cursor save. For a new projection, pass `.origin` as
    /// `expectedPreviousOffset`. Projection mutations and this cursor save
    /// should share one transaction in persistent adapters.
    func saveCursor(
        _ cursor: AgentProjectionCursor,
        expectedPreviousOffset: AgentJournalOffset
    ) async throws -> AgentProjectionCursorCommit
}

public protocol AgentEventJournal:
    AgentRunAcceptancePersisting,
    AgentEventAppending,
    AgentEventReading,
    AgentProjectionCursorPersisting
{}

/// Capability passed to the work queue only after a new acceptance commit.
/// Its initializer is intentionally internal so engine work cannot fabricate
/// proof that the acceptance transaction completed.
public struct CommittedAgentRunAcceptance: Sendable {
    public let acceptance: AgentRunAcceptance
    public let commit: AgentJournalCommit

    init(acceptance: AgentRunAcceptance, commit: AgentJournalCommit) {
        self.acceptance = acceptance
        self.commit = commit
    }
}

/// The bounded hand-off that starts provider/worker activity. Implementations
/// should enqueue and return; durable recovery owns work accepted before a
/// process interruption.
public protocol AgentRunWorkEnqueuing: Sendable {
    func enqueue(_ acceptance: CommittedAgentRunAcceptance) async
}

/// Enforces the acceptance-before-work ordering in one reusable boundary.
public struct AgentRunAcceptanceCoordinator: Sendable {
    private let store: any AgentRunAcceptancePersisting

    public init(store: any AgentRunAcceptancePersisting) {
        self.store = store
    }

    @discardableResult
    public func acceptAndEnqueue(
        _ acceptance: AgentRunAcceptance,
        workQueue: any AgentRunWorkEnqueuing
    ) async throws -> AgentJournalCommit {
        let commit = try await store.accept(acceptance)
        guard commit.disposition == .committed else { return commit }
        await workQueue.enqueue(
            CommittedAgentRunAcceptance(
                acceptance: acceptance,
                commit: commit
            )
        )
        return commit
    }
}

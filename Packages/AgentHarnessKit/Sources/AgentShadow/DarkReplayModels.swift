import AgentDomain
import AgentStore
import Foundation

/// The canonical conversational projection reconstructed from committed events.
/// Provisional provider output is deliberately absent from this type.
public struct DarkReplayTranscript: Codable, Equatable, Sendable {
    public let items: [ModelItem]

    public init(items: [ModelItem]) {
        self.items = items
    }
}

/// Tool evidence as recorded by the ledger. Dark replay can inspect these facts,
/// but this value has no executor, mutation permit, or dispatch capability.
public struct DarkReplayToolEvidence: Codable, Equatable, Sendable {
    public let invocation: ToolInvocation
    public let transitions: [DarkReplayToolTransition]
    public let approvalRequest: ApprovalRequest?
    public let approvalResolution: ApprovalResolution?
    public let callID: ToolCallID
    public let tool: ToolIdentity
    public let effectClass: ToolEffectClass
    public let status: ToolExecutionStatus
    public let applicationEvidence: [ToolEvidence]
    public let resultStatus: ToolResultStatus?
    public let resultEvidence: [ToolEvidence]
    public let resultArtifacts: [ArtifactReference]
    public let result: ToolResult?

    public init(
        invocation: ToolInvocation,
        transitions: [DarkReplayToolTransition],
        approvalRequest: ApprovalRequest?,
        approvalResolution: ApprovalResolution?,
        status: ToolExecutionStatus,
        applicationEvidence: [ToolEvidence],
        resultStatus: ToolResultStatus?,
        resultEvidence: [ToolEvidence],
        resultArtifacts: [ArtifactReference]
    ) {
        self.invocation = invocation
        self.transitions = transitions
        self.approvalRequest = approvalRequest
        self.approvalResolution = approvalResolution
        callID = invocation.callID
        tool = invocation.tool
        effectClass = invocation.effectClass
        self.status = status
        self.applicationEvidence = applicationEvidence
        self.resultStatus = resultStatus
        self.resultEvidence = resultEvidence
        self.resultArtifacts = resultArtifacts
        result = nil
    }

    init(
        invocation: ToolInvocation,
        transitions: [DarkReplayToolTransition],
        approvalRequest: ApprovalRequest?,
        approvalResolution: ApprovalResolution?,
        status: ToolExecutionStatus,
        applicationEvidence: [ToolEvidence],
        result: ToolResult?
    ) {
        self.invocation = invocation
        self.transitions = transitions
        self.approvalRequest = approvalRequest
        self.approvalResolution = approvalResolution
        callID = invocation.callID
        tool = invocation.tool
        effectClass = invocation.effectClass
        self.status = status
        self.applicationEvidence = applicationEvidence
        resultStatus = result?.status
        resultEvidence = result?.evidence ?? []
        resultArtifacts = result?.artifacts ?? []
        self.result = result
    }
}

public struct DarkReplayToolTransition: Codable, Equatable, Sendable {
    public let status: ToolExecutionStatus
    public let eventID: EventID
    public let sequence: EventSequence
    public let timestamp: AgentInstant

    public init(
        status: ToolExecutionStatus,
        eventID: EventID,
        sequence: EventSequence,
        timestamp: AgentInstant
    ) {
        self.status = status
        self.eventID = eventID
        self.sequence = sequence
        self.timestamp = timestamp
    }
}

public enum DarkReplayAttemptOutcome: String, Codable, Equatable, Sendable {
    case active
    case responseCommitted
    case failedBeforeCommit
    case failedAfterCommit
}

/// Latency derived only from durable event timestamps. It intentionally does
/// not contain wall-clock replay duration, keeping reports stable after restart.
public struct DarkReplayAttemptLatency: Codable, Equatable, Sendable {
    public let attemptID: AttemptID
    public let route: ModelRoute
    public let startedAt: AgentInstant
    public let finishedAt: AgentInstant?
    public let durationMilliseconds: UInt64?
    public let outcome: DarkReplayAttemptOutcome
    public let retryScheduled: Bool

    public init(
        attemptID: AttemptID,
        route: ModelRoute,
        startedAt: AgentInstant,
        finishedAt: AgentInstant?,
        durationMilliseconds: UInt64?,
        outcome: DarkReplayAttemptOutcome,
        retryScheduled: Bool
    ) {
        self.attemptID = attemptID
        self.route = route
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMilliseconds = durationMilliseconds
        self.outcome = outcome
        self.retryScheduled = retryScheduled
    }
}

public struct DarkReplayLatencyReport: Codable, Equatable, Sendable {
    public let firstEventAt: AgentInstant
    public let lastEventAt: AgentInstant
    public let recordedRunDurationMilliseconds: UInt64
    public let firstCommitAt: AgentInstant
    public let lastCommitAt: AgentInstant
    public let recordedCommitSpanMilliseconds: UInt64
    public let attempts: [DarkReplayAttemptLatency]

    public init(
        firstEventAt: AgentInstant,
        lastEventAt: AgentInstant,
        recordedRunDurationMilliseconds: UInt64,
        firstCommitAt: AgentInstant,
        lastCommitAt: AgentInstant,
        recordedCommitSpanMilliseconds: UInt64,
        attempts: [DarkReplayAttemptLatency]
    ) {
        self.firstEventAt = firstEventAt
        self.lastEventAt = lastEventAt
        self.recordedRunDurationMilliseconds = recordedRunDurationMilliseconds
        self.firstCommitAt = firstCommitAt
        self.lastCommitAt = lastCommitAt
        self.recordedCommitSpanMilliseconds = recordedCommitSpanMilliseconds
        self.attempts = attempts
    }
}

/// Explicit agreement between independent event-derived projections and the
/// reducer-owned canonical state.
public struct DarkReplayParityReport: Codable, Equatable, Sendable {
    public let transcriptMatchesCanonicalState: Bool
    public let evidenceMatchesCanonicalState: Bool
    public let artifactsMatchCanonicalState: Bool
    public let toolLifecycleMatchesCanonicalState: Bool
    public let approvalLifecycleMatchesCanonicalState: Bool
    public let eventCount: Int
    public let transcriptItemCount: Int
    public let toolCount: Int
    public let evidenceFactCount: Int

    public init(
        transcriptMatchesCanonicalState: Bool,
        evidenceMatchesCanonicalState: Bool,
        artifactsMatchesCanonicalState: Bool,
        toolLifecycleMatchesCanonicalState: Bool = true,
        approvalLifecycleMatchesCanonicalState: Bool = true,
        eventCount: Int,
        transcriptItemCount: Int,
        toolCount: Int,
        evidenceFactCount: Int
    ) {
        self.transcriptMatchesCanonicalState = transcriptMatchesCanonicalState
        self.evidenceMatchesCanonicalState = evidenceMatchesCanonicalState
        self.artifactsMatchCanonicalState = artifactsMatchesCanonicalState
        self.toolLifecycleMatchesCanonicalState = toolLifecycleMatchesCanonicalState
        self.approvalLifecycleMatchesCanonicalState = approvalLifecycleMatchesCanonicalState
        self.eventCount = eventCount
        self.transcriptItemCount = transcriptItemCount
        self.toolCount = toolCount
        self.evidenceFactCount = evidenceFactCount
    }

    public var isExact: Bool {
        transcriptMatchesCanonicalState
            && evidenceMatchesCanonicalState
            && artifactsMatchCanonicalState
            && toolLifecycleMatchesCanonicalState
            && approvalLifecycleMatchesCanonicalState
    }
}

public struct DarkReplayDigests: Codable, Equatable, Sendable {
    public let ledgerSHA256: String
    public let stateSHA256: String
    public let transcriptSHA256: String
    public let evidenceSHA256: String
    public let reportSHA256: String

    public init(
        ledgerSHA256: String,
        stateSHA256: String,
        transcriptSHA256: String,
        evidenceSHA256: String,
        reportSHA256: String
    ) {
        self.ledgerSHA256 = ledgerSHA256
        self.stateSHA256 = stateSHA256
        self.transcriptSHA256 = transcriptSHA256
        self.evidenceSHA256 = evidenceSHA256
        self.reportSHA256 = reportSHA256
    }
}

public struct DarkReplayReport: Codable, Equatable, Sendable {
    public let runID: RunID
    public let state: AgentRunState
    public let transcript: DarkReplayTranscript
    public let toolEvidence: [DarkReplayToolEvidence]
    public let capturedArtifacts: [ArtifactReference]
    public let parity: DarkReplayParityReport
    public let latency: DarkReplayLatencyReport
    public let digests: DarkReplayDigests
    public let lastOffset: AgentJournalOffset

    init(
        runID: RunID,
        state: AgentRunState,
        transcript: DarkReplayTranscript,
        toolEvidence: [DarkReplayToolEvidence],
        capturedArtifacts: [ArtifactReference],
        parity: DarkReplayParityReport,
        latency: DarkReplayLatencyReport,
        digests: DarkReplayDigests,
        lastOffset: AgentJournalOffset
    ) {
        self.runID = runID
        self.state = state
        self.transcript = transcript
        self.toolEvidence = toolEvidence
        self.capturedArtifacts = capturedArtifacts
        self.parity = parity
        self.latency = latency
        self.digests = digests
        self.lastOffset = lastOffset
    }
}

public enum DarkReplayError: Error, Equatable, Sendable {
    case runNotFound(RunID)
    case ledgerChangedDuringReplay(runID: RunID)
    case canonicalParityViolation(runID: RunID)
    case staleReplayAttestation(runID: RunID)
    case nonMonotonicEventTimestamp(
        previous: AgentInstant,
        actual: AgentInstant,
        eventID: EventID
    )
    case nonMonotonicCommitTimestamp(
        previous: AgentInstant,
        actual: AgentInstant,
        eventID: EventID
    )
    case timestampDistanceOverflow(start: AgentInstant, end: AgentInstant)
}

import AgentDomain
import Foundation

/// Exact journal scope consumed by the Forge activity projection.
///
/// A `nil` project means the General workspace. It is not a wildcard.
struct AgentActivityProjectionScope: Equatable, Sendable {
    let projectID: ProjectID?
    let conversationID: ConversationID
    let runID: RunID?

    init(
        projectID: ProjectID?,
        conversationID: ConversationID,
        runID: RunID? = nil
    ) {
        self.projectID = projectID
        self.conversationID = conversationID
        self.runID = runID
    }

    func contains(_ identity: AgentActivityRunIdentity) -> Bool {
        identity.projectID == projectID &&
            identity.conversationID == conversationID &&
            (runID == nil || identity.runID == runID)
    }
}

/// Fully qualified identity for every command leaving an activity surface.
struct AgentActivityRunIdentity: Hashable, Sendable {
    let projectID: ProjectID?
    let conversationID: ConversationID
    let workspaceID: WorkspaceID
    let runID: RunID
    let rootRunID: RunID
}

enum AgentActivityState: String, Equatable, Sendable {
    case pending
    case queued
    case running
    case awaitingApproval
    case retrying
    case succeeded
    case failed
    case rejected
    case cancelling
    case cancelled
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .rejected, .cancelled, .interrupted:
            true
        default:
            false
        }
    }
}

enum AgentActivitySemanticKind: String, Equatable, Sendable {
    case modelAttempt
    case plan
    case tool
    case approval
    case retry
    case routeChange
    case checkpoint
    case cancellation
    case failure
}

enum AgentActivityItemID: Hashable, Sendable {
    case modelAttempt(AttemptID)
    case plan(runID: RunID, revision: UInt64)
    case tool(ToolCallID)
    case approval(ApprovalRequestID)
    case retry(failedAttemptID: AttemptID, nextAttemptID: AttemptID)
    case routeChange(EventID)
    case checkpoint(ContextCheckpointID)
    case cancellation(EventID)
    case failure(EventID)
}

struct AgentActivityEventSpan: Equatable, Sendable {
    let firstSequence: EventSequence
    let lastSequence: EventSequence
    let startedAt: AgentInstant
    let endedAt: AgentInstant

    var durationMilliseconds: Int64 {
        max(0, endedAt.rawValue - startedAt.rawValue)
    }
}

struct AgentActivityEvidenceID: Hashable, Sendable {
    let kind: String
    let digest: String
}

/// Content-addressed proof. Raw evidence metadata is deliberately excluded.
struct AgentActivityEvidence: Identifiable, Equatable, Sendable {
    let id: AgentActivityEvidenceID
    let firstSequence: EventSequence
    let sourceToolCallIDs: [ToolCallID]
}

/// A single stable activity row. Arguments, provider frames, and raw tool output
/// are not presentation values and therefore cannot leak through this type.
struct AgentActivityItem: Identifiable, Equatable, Sendable {
    let id: AgentActivityItemID
    let kind: AgentActivitySemanticKind
    let state: AgentActivityState
    let summary: String
    let target: String?
    let attemptID: AttemptID?
    let toolCallID: ToolCallID?
    let span: AgentActivityEventSpan
    let errorMessage: String?
    let evidenceIDs: [AgentActivityEvidenceID]
    let artifactIDs: [ArtifactID]
}

struct AgentActivityRoute: Equatable, Sendable {
    let provider: String
    let model: String
    let adapter: String
}

struct AgentActivityAttempt: Identifiable, Equatable, Sendable {
    let id: AttemptID
    let state: AgentActivityState
    let route: AgentActivityRoute
    let span: AgentActivityEventSpan
    let itemIDs: [AgentActivityItemID]
    let retryOfAttemptID: AttemptID?
    let nextAttemptID: AttemptID?
    let errorMessage: String?
}

struct AgentActivityApproval: Identifiable, Equatable, Sendable {
    let id: ApprovalRequestID
    let run: AgentActivityRunIdentity
    let callID: ToolCallID
    let state: AgentActivityState
    /// Projection-owned public copy. This is never inferred from arguments or
    /// copied from an unclassified engine string.
    let publicSummary: String
    let requestedAt: AgentInstant
    let resolvedAt: AgentInstant?

    func command(decision: ApprovalDecision) -> AgentActivityCommand {
        .resolveApproval(
            AgentActivityApprovalCommand(
                run: run,
                requestID: id,
                callID: callID,
                decision: decision
            )
        )
    }
}

/// One content handoff. Identical content is represented once while every
/// canonical ID that referred to it remains available for audit/replay.
struct AgentActivityArtifact: Identifiable, Equatable, Sendable {
    let id: ArtifactID
    let run: AgentActivityRunIdentity
    let equivalentArtifactIDs: [ArtifactID]
    let contentDigest: String
    let mediaType: String
    let displayName: String
    let firstSequence: EventSequence
    let sourceToolCallIDs: [ToolCallID]

    var openCommand: AgentActivityCommand {
        .openArtifact(
            AgentActivityArtifactCommand(
                run: run,
                artifactID: id,
                contentDigest: contentDigest
            )
        )
    }
}

struct AgentActivityReplayIdentity: Equatable, Sendable {
    let orderedEventIDs: [EventID]
    let orderedSequences: [EventSequence]
}

struct AgentActivityGroup: Identifiable, Equatable, Sendable {
    var id: RunID { identity.runID }

    let identity: AgentActivityRunIdentity
    let state: AgentActivityState
    let summary: String
    let span: AgentActivityEventSpan
    let items: [AgentActivityItem]
    let attempts: [AgentActivityAttempt]
    let approvals: [AgentActivityApproval]
    let artifacts: [AgentActivityArtifact]
    let evidence: [AgentActivityEvidence]
    let errorMessage: String?
    let replayIdentity: AgentActivityReplayIdentity

    var pendingApproval: AgentActivityApproval? {
        approvals.first { $0.state == .awaitingApproval }
    }

    var cancelCommand: AgentActivityCommand {
        .cancel(AgentActivityRunCommand(run: identity))
    }

    var retryCommand: AgentActivityCommand {
        .retry(
            AgentActivityRetryCommand(
                run: identity,
                failedAttemptID: attempts.reversed().first(where: {
                    $0.state == .failed
                })?.id
            )
        )
    }

    var openReceiptCommand: AgentActivityCommand {
        .openReceipt(AgentActivityRunCommand(run: identity))
    }

    /// Rejects commands captured from another run or from an earlier lifecycle
    /// revision, including approval decisions after durable resolution.
    func accepts(_ command: AgentActivityCommand) -> Bool {
        guard command.run == identity else { return false }

        switch command {
        case let .resolveApproval(value):
            return approvals.contains {
                $0.id == value.requestID &&
                    $0.callID == value.callID &&
                    $0.state == .awaitingApproval
            }
        case .cancel:
            return !state.isTerminal && state != .cancelling
        case let .retry(value):
            guard state == .failed || state == .cancelled || state == .interrupted else {
                return false
            }
            return value.failedAttemptID == nil || attempts.contains {
                $0.id == value.failedAttemptID && $0.state == .failed
            }
        case .openReceipt:
            return true
        case let .openArtifact(value):
            return artifacts.contains {
                $0.id == value.artifactID && $0.contentDigest == value.contentDigest
            }
        }
    }
}

struct AgentActivityRunCommand: Equatable, Sendable {
    let run: AgentActivityRunIdentity
}

struct AgentActivityApprovalCommand: Equatable, Sendable {
    let run: AgentActivityRunIdentity
    let requestID: ApprovalRequestID
    let callID: ToolCallID
    let decision: ApprovalDecision
}

struct AgentActivityRetryCommand: Equatable, Sendable {
    let run: AgentActivityRunIdentity
    let failedAttemptID: AttemptID?
}

struct AgentActivityArtifactCommand: Equatable, Sendable {
    let run: AgentActivityRunIdentity
    let artifactID: ArtifactID
    let contentDigest: String
}

enum AgentActivityCommand: Equatable, Sendable {
    case resolveApproval(AgentActivityApprovalCommand)
    case cancel(AgentActivityRunCommand)
    case retry(AgentActivityRetryCommand)
    case openReceipt(AgentActivityRunCommand)
    case openArtifact(AgentActivityArtifactCommand)

    var run: AgentActivityRunIdentity {
        switch self {
        case let .resolveApproval(value): value.run
        case let .cancel(value): value.run
        case let .retry(value): value.run
        case let .openReceipt(value): value.run
        case let .openArtifact(value): value.run
        }
    }
}

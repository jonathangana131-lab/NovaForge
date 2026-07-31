import AgentDomain
import AgentStore
import Foundation

/// A read-only replay boundary used for shadow evaluation and developer canaries.
/// Its sole capability is `AgentEventReading`; it cannot append events, advance
/// projection cursors, call providers, dispatch tools, or mutate a workspace.
public struct DarkReplayEngine: Sendable {
    private let reader: any AgentEventReading

    public init(reader: any AgentEventReading) {
        self.reader = reader
    }

    public func replay(_ runID: RunID) async throws -> DarkReplayReport {
        // Bracket recovery with identical ledger reads. A run may continue in
        // parallel, but a report is emitted only for one stable durable view.
        let metadataBefore = try await reader.metadata(for: runID)
        let recordsBefore = try await reader.events(for: runID, after: nil)
        let recovered = try await AgentJournalRecovery(store: reader).recover(runID)
        let recordsAfter = try await reader.events(for: runID, after: nil)
        let metadataAfter = try await reader.metadata(for: runID)

        guard recordsBefore == recordsAfter,
              metadataBefore == metadataAfter
        else {
            throw DarkReplayError.ledgerChangedDuringReplay(runID: runID)
        }
        guard let recovered else {
            guard metadataBefore == nil,
                  metadataAfter == nil,
                  recordsBefore.isEmpty,
                  recordsAfter.isEmpty
            else {
                throw DarkReplayError.ledgerChangedDuringReplay(runID: runID)
            }
            throw DarkReplayError.runNotFound(runID)
        }
        guard metadataBefore == recovered.metadata,
              metadataAfter == recovered.metadata,
              recordsBefore.count == recovered.eventCount,
              recordsBefore.last?.offset == recovered.lastOffset
        else {
            throw DarkReplayError.ledgerChangedDuringReplay(runID: runID)
        }

        // Revalidate the exact bracketed records instead of trusting a cached
        // projection. Journal corruption therefore remains a hard failure.
        let state = try AgentJournalReplay.replay(
            recordsBefore,
            metadata: recovered.metadata
        )
        guard state == recovered.state else {
            throw DarkReplayError.ledgerChangedDuringReplay(runID: runID)
        }

        let transcript = DarkReplayTranscript(
            items: Self.transcriptItems(from: recordsBefore)
        )
        let lifecycleProjection = try Self.toolLifecycle(from: recordsBefore)
        let toolEvidence = lifecycleProjection.tools.map(\.evidence)
        let capturedArtifacts: [ArtifactReference] = recordsBefore.compactMap { record in
            guard case let .artifactCaptured(payload) = record.event.payload else {
                return nil
            }
            return payload.artifact
        }
        let projectedToolStates = lifecycleProjection.tools.map(\.state)
        let toolLifecycleIsExact = projectedToolStates == state.tools
        let approvalLifecycleIsExact = lifecycleProjection.approvals == state.approvals
        let parity = DarkReplayParityReport(
            transcriptMatchesCanonicalState: transcript.items == state.modelItems,
            evidenceMatchesCanonicalState: toolLifecycleIsExact,
            artifactsMatchesCanonicalState: capturedArtifacts == state.artifacts,
            toolLifecycleMatchesCanonicalState: toolLifecycleIsExact,
            approvalLifecycleMatchesCanonicalState: approvalLifecycleIsExact,
            eventCount: recordsBefore.count,
            transcriptItemCount: transcript.items.count,
            toolCount: toolEvidence.count,
            evidenceFactCount: toolEvidence.reduce(0) {
                $0 + $1.applicationEvidence.count
                    + $1.resultEvidence.count
                    + $1.resultArtifacts.count
            }
        )
        guard parity.isExact else {
            throw DarkReplayError.canonicalParityViolation(runID: runID)
        }

        let latency = try Self.latencyReport(from: recordsBefore)
        let ledgerDigest = try CanonicalShadowDigest.sha256(
            domain: .ledger,
            recordsBefore
        )
        let stateDigest = try CanonicalShadowDigest.sha256(
            domain: .state,
            state
        )
        let transcriptDigest = try CanonicalShadowDigest.sha256(
            domain: .transcript,
            transcript
        )
        let evidenceDigest = try CanonicalShadowDigest.sha256(
            domain: .evidence,
            toolEvidence
        )
        let material = DarkReplayDigestMaterial(
            runID: runID,
            ledgerSHA256: ledgerDigest,
            stateSHA256: stateDigest,
            transcriptSHA256: transcriptDigest,
            evidenceSHA256: evidenceDigest,
            parity: parity,
            latency: latency,
            lastOffset: recovered.lastOffset
        )
        let digests = DarkReplayDigests(
            ledgerSHA256: ledgerDigest,
            stateSHA256: stateDigest,
            transcriptSHA256: transcriptDigest,
            evidenceSHA256: evidenceDigest,
            reportSHA256: try CanonicalShadowDigest.sha256(
                domain: .report,
                material
            )
        )

        return DarkReplayReport(
            runID: runID,
            state: state,
            transcript: transcript,
            toolEvidence: toolEvidence,
            capturedArtifacts: capturedArtifacts,
            parity: parity,
            latency: latency,
            digests: digests,
            lastOffset: recovered.lastOffset
        )
    }

    /// Produces an opaque authority that can only be minted after a successful
    /// stable replay. Canary policy replays it again before use.
    public func attest(_ runID: RunID) async throws -> DarkReplayAttestation {
        DarkReplayAttestation(
            reader: reader,
            acceptedReport: try await replay(runID)
        )
    }

    private static func transcriptItems(
        from records: [StoredAgentEvent]
    ) -> [ModelItem] {
        var items: [ModelItem] = []
        for record in records {
            switch record.event.payload {
            case let .runAccepted(payload):
                items.append(contentsOf: payload.initialItems)
            case let .modelResponseCommitted(payload):
                items.append(contentsOf: payload.items)
            case let .toolCompleted(payload):
                items.append(ModelItem(
                    id: payload.result.modelItemID,
                    createdAt: record.event.header.timestamp,
                    payload: .toolResult(payload.result)
                ))
            default:
                break
            }
        }
        return items
    }

    private static func toolLifecycle(
        from records: [StoredAgentEvent]
    ) throws -> ToolLifecycleProjection {
        var tools: [ProjectedToolLifecycle] = []
        var toolIndexByCallID: [ToolCallID: Int] = [:]
        var approvals: [ApprovalRequestState] = []
        var approvalIndexByRequestID: [ApprovalRequestID: Int] = [:]

        for record in records {
            switch record.event.payload {
            case let .toolProposed(payload):
                let callID = payload.invocation.callID
                guard toolIndexByCallID[callID] == nil else {
                    throw DarkReplayError.canonicalParityViolation(
                        runID: record.runID
                    )
                }
                toolIndexByCallID[callID] = tools.count
                tools.append(ProjectedToolLifecycle(
                    invocation: payload.invocation,
                    status: .proposed,
                    transitions: [transition(.proposed, record: record)]
                ))

            case let .approvalRequested(payload):
                let request = payload.request
                guard let toolIndex = toolIndexByCallID[request.binding.callID],
                      approvalIndexByRequestID[request.requestID] == nil
                else {
                    throw DarkReplayError.canonicalParityViolation(
                        runID: record.runID
                    )
                }
                tools[toolIndex].status = .awaitingApproval
                tools[toolIndex].approvalRequest = request
                tools[toolIndex].transitions.append(
                    transition(.awaitingApproval, record: record)
                )
                approvalIndexByRequestID[request.requestID] = approvals.count
                approvals.append(ApprovalRequestState(request: request))

            case let .approvalResolved(payload):
                let resolution = payload.resolution
                guard let toolIndex = toolIndexByCallID[resolution.callID],
                      let approvalIndex = approvalIndexByRequestID[resolution.requestID]
                else {
                    throw DarkReplayError.canonicalParityViolation(
                        runID: record.runID
                    )
                }
                tools[toolIndex].approvalResolution = resolution
                approvals[approvalIndex].resolution = resolution
                switch resolution.decision {
                case .approved:
                    tools[toolIndex].status = .approved
                    approvals[approvalIndex].status = .approved
                    tools[toolIndex].transitions.append(
                        transition(.approved, record: record)
                    )
                case .rejected:
                    tools[toolIndex].status = .rejected
                    approvals[approvalIndex].status = .rejected
                    tools[toolIndex].transitions.append(
                        transition(.rejected, record: record)
                    )
                }

            case let .toolScheduled(payload):
                try updateTool(
                    payload.callID,
                    status: .scheduled,
                    record: record,
                    tools: &tools,
                    indexes: toolIndexByCallID
                )

            case let .toolStarted(payload):
                try updateTool(
                    payload.callID,
                    status: .running,
                    record: record,
                    tools: &tools,
                    indexes: toolIndexByCallID
                )

            case let .toolApplied(payload):
                guard let index = toolIndexByCallID[payload.callID] else {
                    throw DarkReplayError.canonicalParityViolation(
                        runID: record.runID
                    )
                }
                tools[index].status = .applied
                tools[index].applicationEvidence = payload.evidence
                tools[index].transitions.append(
                    transition(.applied, record: record)
                )

            case let .toolCompleted(payload):
                guard let index = toolIndexByCallID[payload.result.callID] else {
                    throw DarkReplayError.canonicalParityViolation(
                        runID: record.runID
                    )
                }
                tools[index].status = .completed
                tools[index].result = payload.result
                tools[index].transitions.append(
                    transition(.completed, record: record)
                )

            default:
                break
            }
        }
        return ToolLifecycleProjection(tools: tools, approvals: approvals)
    }

    private static func updateTool(
        _ callID: ToolCallID,
        status: ToolExecutionStatus,
        record: StoredAgentEvent,
        tools: inout [ProjectedToolLifecycle],
        indexes: [ToolCallID: Int]
    ) throws {
        guard let index = indexes[callID] else {
            throw DarkReplayError.canonicalParityViolation(runID: record.runID)
        }
        tools[index].status = status
        tools[index].transitions.append(transition(status, record: record))
    }

    private static func transition(
        _ status: ToolExecutionStatus,
        record: StoredAgentEvent
    ) -> DarkReplayToolTransition {
        DarkReplayToolTransition(
            status: status,
            eventID: record.event.header.eventID,
            sequence: record.event.header.sequence,
            timestamp: record.event.header.timestamp
        )
    }

    private static func latencyReport(
        from records: [StoredAgentEvent]
    ) throws -> DarkReplayLatencyReport {
        guard let first = records.first, let last = records.last else {
            // Recovery rejects an empty ledger before this helper is reached.
            preconditionFailure("Dark replay latency requires a recovered ledger")
        }

        var previousEventAt = first.event.header.timestamp
        var previousCommitAt = first.committedAt
        for record in records.dropFirst() {
            let eventAt = record.event.header.timestamp
            guard eventAt >= previousEventAt else {
                throw DarkReplayError.nonMonotonicEventTimestamp(
                    previous: previousEventAt,
                    actual: eventAt,
                    eventID: record.event.header.eventID
                )
            }
            let commitAt = record.committedAt
            guard commitAt >= previousCommitAt else {
                throw DarkReplayError.nonMonotonicCommitTimestamp(
                    previous: previousCommitAt,
                    actual: commitAt,
                    eventID: record.event.header.eventID
                )
            }
            previousEventAt = eventAt
            previousCommitAt = commitAt
        }

        var builders: [AttemptLatencyBuilder] = []
        var indexByAttempt: [AttemptID: Int] = [:]
        for record in records {
            switch record.event.payload {
            case let .modelRequestStarted(payload):
                indexByAttempt[payload.attemptID] = builders.count
                builders.append(AttemptLatencyBuilder(
                    attemptID: payload.attemptID,
                    route: payload.route,
                    startedAt: record.event.header.timestamp
                ))
            case let .modelResponseCommitted(payload):
                if let index = indexByAttempt[payload.attemptID] {
                    builders[index].finishedAt = record.event.header.timestamp
                    builders[index].outcome = .responseCommitted
                }
            case let .modelRequestFailed(payload):
                if let index = indexByAttempt[payload.attemptID] {
                    builders[index].finishedAt = record.event.header.timestamp
                    builders[index].outcome = payload.outputWasCommitted
                        ? .failedAfterCommit
                        : .failedBeforeCommit
                }
            case let .retryScheduled(payload):
                if let index = indexByAttempt[payload.failedAttemptID] {
                    builders[index].retryScheduled = true
                }
            default:
                break
            }
        }

        let attempts = try builders.map { builder in
            DarkReplayAttemptLatency(
                attemptID: builder.attemptID,
                route: builder.route,
                startedAt: builder.startedAt,
                finishedAt: builder.finishedAt,
                durationMilliseconds: try builder.finishedAt.map {
                    try duration(from: builder.startedAt, through: $0)
                },
                outcome: builder.outcome,
                retryScheduled: builder.retryScheduled
            )
        }
        return DarkReplayLatencyReport(
            firstEventAt: first.event.header.timestamp,
            lastEventAt: last.event.header.timestamp,
            recordedRunDurationMilliseconds: try duration(
                from: first.event.header.timestamp,
                through: last.event.header.timestamp
            ),
            firstCommitAt: first.committedAt,
            lastCommitAt: last.committedAt,
            recordedCommitSpanMilliseconds: try duration(
                from: first.committedAt,
                through: last.committedAt
            ),
            attempts: attempts
        )
    }

    private static func duration(
        from start: AgentInstant,
        through end: AgentInstant
    ) throws -> UInt64 {
        let (difference, overflow) = end.rawValue.subtractingReportingOverflow(
            start.rawValue
        )
        guard !overflow, difference >= 0 else {
            throw DarkReplayError.timestampDistanceOverflow(start: start, end: end)
        }
        return UInt64(difference)
    }
}

private struct AttemptLatencyBuilder {
    let attemptID: AttemptID
    let route: ModelRoute
    let startedAt: AgentInstant
    var finishedAt: AgentInstant?
    var outcome: DarkReplayAttemptOutcome = .active
    var retryScheduled = false
}

private struct ToolLifecycleProjection {
    let tools: [ProjectedToolLifecycle]
    let approvals: [ApprovalRequestState]
}

private struct ProjectedToolLifecycle {
    let invocation: ToolInvocation
    var status: ToolExecutionStatus
    var transitions: [DarkReplayToolTransition]
    var approvalRequest: ApprovalRequest?
    var approvalResolution: ApprovalResolution?
    var applicationEvidence: [ToolEvidence] = []
    var result: ToolResult?

    var state: ToolExecutionState {
        ToolExecutionState(
            invocation: invocation,
            status: status,
            result: result,
            applicationEvidence: applicationEvidence
        )
    }

    var evidence: DarkReplayToolEvidence {
        DarkReplayToolEvidence(
            invocation: invocation,
            transitions: transitions,
            approvalRequest: approvalRequest,
            approvalResolution: approvalResolution,
            status: status,
            applicationEvidence: applicationEvidence,
            result: result
        )
    }
}

private struct DarkReplayDigestMaterial: Codable {
    let runID: RunID
    let ledgerSHA256: String
    let stateSHA256: String
    let transcriptSHA256: String
    let evidenceSHA256: String
    let parity: DarkReplayParityReport
    let latency: DarkReplayLatencyReport
    let lastOffset: AgentJournalOffset
}

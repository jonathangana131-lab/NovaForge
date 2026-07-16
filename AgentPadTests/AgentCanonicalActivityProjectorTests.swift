import AgentDomain
import Foundation
import XCTest
@testable import NovaForge

final class AgentCanonicalActivityProjectorTests: XCTestCase {
    func testProjectionStrictlyIsolatesTwoConversationsAndProviderCallReuse() throws {
        let fixture = CanonicalActivityFixture()
        let firstGroups = try AgentCanonicalActivityProjector.project(
            orderedEvents: fixture.interleavedEvents,
            scope: fixture.firstScope
        )
        let secondGroups = try AgentCanonicalActivityProjector.project(
            orderedEvents: fixture.interleavedEvents,
            scope: fixture.secondScope
        )

        let first = try XCTUnwrap(firstGroups.first)
        let second = try XCTUnwrap(secondGroups.first)
        XCTAssertEqual(firstGroups.count, 1)
        XCTAssertEqual(secondGroups.count, 1)
        XCTAssertEqual(first.id, fixture.firstRunID)
        XCTAssertEqual(second.id, fixture.secondRunID)
        XCTAssertEqual(first.identity.conversationID, fixture.firstConversationID)
        XCTAssertEqual(second.identity.conversationID, fixture.secondConversationID)
        XCTAssertEqual(
            fixture.firstInvocation.providerCallID,
            fixture.thirdInvocation.providerCallID
        )

        let firstTools = first.items.filter { $0.kind == .tool }
        let secondTools = second.items.filter { $0.kind == .tool }
        XCTAssertEqual(
            firstTools.compactMap(\.toolCallID),
            [fixture.firstCallID, fixture.secondCallID]
        )
        XCTAssertEqual(secondTools.compactMap(\.toolCallID), [fixture.thirdCallID])
        XCTAssertFalse(firstTools.contains { $0.toolCallID == fixture.thirdCallID })
        XCTAssertFalse(secondTools.contains { $0.toolCallID == fixture.firstCallID })

        let exactRun = try AgentCanonicalActivityProjector.project(
            orderedEvents: fixture.interleavedEvents,
            scope: AgentActivityProjectionScope(
                projectID: fixture.projectID,
                conversationID: fixture.firstConversationID,
                runID: fixture.firstRunID
            )
        )
        let wrongRun = try AgentCanonicalActivityProjector.project(
            orderedEvents: fixture.interleavedEvents,
            scope: AgentActivityProjectionScope(
                projectID: fixture.projectID,
                conversationID: fixture.firstConversationID,
                runID: fixture.secondRunID
            )
        )
        XCTAssertEqual(exactRun.map(\.id), [fixture.firstRunID])
        XCTAssertTrue(wrongRun.isEmpty)
    }

    func testRepeatedIdenticalToolsKeepCanonicalIdentityAndSequenceOrder() throws {
        let fixture = CanonicalActivityFixture()
        let group = try XCTUnwrap(
            AgentCanonicalActivityProjector.project(
                orderedEvents: fixture.firstEvents,
                scope: fixture.firstScope
            ).first
        )
        let tools = group.items.filter { $0.kind == .tool }

        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(fixture.firstInvocation.tool, fixture.secondInvocation.tool)
        XCTAssertEqual(fixture.firstInvocation.arguments, fixture.secondInvocation.arguments)
        XCTAssertEqual(
            fixture.firstInvocation.canonicalArgumentDigest,
            fixture.secondInvocation.canonicalArgumentDigest
        )
        XCTAssertEqual(tools[0].id, .tool(fixture.firstCallID))
        XCTAssertEqual(tools[1].id, .tool(fixture.secondCallID))
        XCTAssertEqual(tools[0].summary, tools[1].summary)
        XCTAssertEqual(tools[0].summary, "File written")
        XCTAssertLessThan(
            tools[0].span.firstSequence.rawValue,
            tools[1].span.firstSequence.rawValue
        )
        XCTAssertEqual(
            try XCTUnwrap(group.attempts.first).itemIDs,
            [
                .modelAttempt(fixture.firstAttemptID),
                .tool(fixture.firstCallID),
                .tool(fixture.secondCallID),
                .approval(fixture.approvalID)
            ]
        )
        XCTAssertEqual(group.attempts.map(\.id), [fixture.firstAttemptID])
        XCTAssertEqual(
            group.approvals.map(\.id),
            [fixture.approvalID]
        )
    }

    func testReplayPreservesGroupItemAndEventIdentityExactly() throws {
        let fixture = CanonicalActivityFixture()
        let first = try AgentCanonicalActivityProjector.project(
            orderedEvents: fixture.interleavedEvents,
            scope: fixture.firstScope
        )
        let replay = try AgentCanonicalActivityProjector.project(
            orderedEvents: fixture.interleavedEvents,
            scope: fixture.firstScope
        )

        XCTAssertEqual(replay, first)
        let group = try XCTUnwrap(first.first)
        XCTAssertEqual(
            group.replayIdentity.orderedEventIDs,
            fixture.firstEvents.map(\.header.eventID)
        )
        XCTAssertEqual(
            group.replayIdentity.orderedSequences.map(\.rawValue),
            Array(1 ... UInt64(fixture.firstEvents.count))
        )
        XCTAssertEqual(group.items.map(\.id), try XCTUnwrap(replay.first).items.map(\.id))
    }

    func testArtifactAndEvidenceDedupeIsContentStableAndDeterministic() throws {
        let fixture = CanonicalActivityFixture()
        let group = try XCTUnwrap(
            AgentCanonicalActivityProjector.project(
                orderedEvents: fixture.firstEvents,
                scope: fixture.firstScope
            ).first
        )

        let artifact = try XCTUnwrap(group.artifacts.first)
        XCTAssertEqual(group.artifacts.count, 1)
        XCTAssertEqual(artifact.id, fixture.firstArtifact.artifactID)
        XCTAssertEqual(
            artifact.equivalentArtifactIDs,
            [
                fixture.firstArtifact.artifactID,
                fixture.secondArtifact.artifactID,
                fixture.thirdArtifact.artifactID
            ]
        )
        XCTAssertEqual(
            artifact.sourceToolCallIDs,
            [fixture.firstCallID, fixture.secondCallID]
        )

        let evidence = try XCTUnwrap(group.evidence.first)
        XCTAssertEqual(group.evidence.count, 1)
        XCTAssertEqual(evidence.id, fixture.sharedEvidenceID)
        XCTAssertEqual(
            evidence.sourceToolCallIDs,
            [fixture.firstCallID, fixture.secondCallID]
        )
        let tools = group.items.filter { $0.kind == .tool }
        XCTAssertEqual(tools[0].evidenceIDs, [fixture.sharedEvidenceID])
        XCTAssertEqual(tools[1].evidenceIDs, [fixture.sharedEvidenceID])
        XCTAssertEqual(tools[0].artifactIDs, [fixture.firstArtifact.artifactID])
        XCTAssertEqual(tools[1].artifactIDs, [fixture.firstArtifact.artifactID])
    }

    func testStaleAndCrossRunCommandsAreRejectedByExactIdentity() throws {
        let fixture = CanonicalActivityFixture()
        let pendingEvents = Array(fixture.firstEvents.prefix(10))
        let pending = try XCTUnwrap(
            AgentCanonicalActivityProjector.project(
                orderedEvents: pendingEvents,
                scope: fixture.firstScope
            ).first
        )
        let resolved = try XCTUnwrap(
            AgentCanonicalActivityProjector.project(
                orderedEvents: fixture.firstEvents,
                scope: fixture.firstScope
            ).first
        )
        let otherRun = try XCTUnwrap(
            AgentCanonicalActivityProjector.project(
                orderedEvents: fixture.secondEvents,
                scope: fixture.secondScope
            ).first
        )
        let approval = try XCTUnwrap(pending.pendingApproval)
        let approve = approval.command(decision: .approved)

        XCTAssertTrue(pending.accepts(approve))
        XCTAssertFalse(resolved.accepts(approve))
        XCTAssertFalse(otherRun.accepts(approve))
        XCTAssertTrue(pending.accepts(pending.cancelCommand))
        XCTAssertFalse(resolved.accepts(resolved.cancelCommand))
        XCTAssertTrue(otherRun.accepts(otherRun.retryCommand))

        let receipt = resolved.openReceiptCommand
        XCTAssertTrue(resolved.accepts(receipt))
        XCTAssertFalse(otherRun.accepts(receipt))

        let openArtifact = try XCTUnwrap(resolved.artifacts.first).openCommand
        XCTAssertTrue(resolved.accepts(openArtifact))
        XCTAssertFalse(otherRun.accepts(openArtifact))
    }

    func testRawArgumentsProviderIDsOutputMetadataAndPrivateErrorsNeverProject() throws {
        let fixture = CanonicalActivityFixture()
        let first = try XCTUnwrap(
            AgentCanonicalActivityProjector.project(
                orderedEvents: fixture.firstEvents,
                scope: fixture.firstScope
            ).first
        )
        let second = try XCTUnwrap(
            AgentCanonicalActivityProjector.project(
                orderedEvents: fixture.secondEvents,
                scope: fixture.secondScope
            ).first
        )
        let firstDescription = String(reflecting: first)
        let secondDescription = String(reflecting: second)

        for forbidden in CanonicalActivityFixture.forbiddenPresentationStrings {
            XCTAssertFalse(firstDescription.contains(forbidden), forbidden)
            XCTAssertFalse(secondDescription.contains(forbidden), forbidden)
        }
        XCTAssertEqual(second.errorMessage, fixture.runFailure.publicMessage)
        XCTAssertEqual(
            second.items.last(where: { $0.kind == .failure })?.summary,
            fixture.runFailure.publicMessage
        )
        XCTAssertTrue(first.items.allSatisfy { $0.target == nil })
        XCTAssertTrue(second.items.allSatisfy { $0.target == nil })
    }

    func testToolReceiptMetadataRequiresExactCanonicalVersion() throws {
        let fixture = CanonicalActivityFixture()
        var events = Array(fixture.firstEvents.prefix(5))
        events[4] = fixture.event(
            context: fixture.firstContext,
            sequence: 5,
            payload: .toolProposed(
                ToolProposedEvent(invocation: fixture.versionMismatchedInvocation)
            ),
            eventSeed: 1_005
        )
        let group = try XCTUnwrap(
            AgentCanonicalActivityProjector.project(
                orderedEvents: events,
                scope: fixture.firstScope
            ).first
        )
        let tool = try XCTUnwrap(group.items.first(where: { $0.kind == .tool }))

        XCTAssertEqual(tool.summary, "Updated workspace")
        XCTAssertNotEqual(tool.summary, "File written")
    }

    func testMatchingReducerStateValidatesAndMismatchedStateFailsClosed() throws {
        let fixture = CanonicalActivityFixture()
        let group = try XCTUnwrap(
            AgentCanonicalActivityProjector.project(
                orderedEvents: fixture.firstEvents,
                states: [fixture.firstRunID: fixture.firstState],
                scope: fixture.firstScope
            ).first
        )
        XCTAssertEqual(group.state, .succeeded)

        var wrongState = fixture.firstState
        wrongState.context = fixture.secondContext
        XCTAssertThrowsError(
            try AgentCanonicalActivityProjector.project(
                orderedEvents: fixture.firstEvents,
                states: [fixture.firstRunID: wrongState],
                scope: fixture.firstScope
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentActivityProjectionError,
                .stateIdentityMismatch(fixture.firstRunID)
            )
        }
    }

    func testOutOfOrderSequenceAndCrossConversationRunReuseFailClosed() throws {
        let fixture = CanonicalActivityFixture()
        var outOfOrder = fixture.firstEvents
        outOfOrder.swapAt(4, 5)
        XCTAssertThrowsError(
            try AgentCanonicalActivityProjector.project(
                orderedEvents: outOfOrder,
                scope: fixture.firstScope
            )
        ) { error in
            guard let projectionError = error as? AgentActivityProjectionError,
                  case .sequenceNotIncreasing = projectionError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let conflicting = fixture.event(
            context: fixture.secondContext,
            sequence: 18,
            payload: .runCompleted(RunCompletedEvent()),
            eventSeed: 9_999,
            overridingRunID: fixture.firstRunID
        )
        XCTAssertThrowsError(
            try AgentCanonicalActivityProjector.project(
                orderedEvents: fixture.firstEvents + [conflicting],
                scope: fixture.firstScope
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentActivityProjectionError,
                .runIdentityConflict(fixture.firstRunID)
            )
        }
    }
}

private struct CanonicalActivityFixture {
    static let reusedProviderCallID = "provider-call-secret-reused"
    static let secretArgument = "raw-argument-secret"
    static let secretOutput = "raw-output-secret"
    static let secretEvidenceMetadata = "evidence-metadata-secret"
    static let secretProviderFrame = "provider-frame-secret"
    static let secretCompletionSummary = "completion-summary-secret"
    static let secretApprovalSummary = "approval-summary-secret"
    static let secretErrorCode = "private-error-code-secret"
    static let secretToolErrorCode = "private-tool-error-secret"
    static let forbiddenPresentationStrings = [
        reusedProviderCallID,
        secretArgument,
        secretOutput,
        secretEvidenceMetadata,
        secretProviderFrame,
        secretCompletionSummary,
        secretApprovalSummary,
        secretErrorCode,
        secretToolErrorCode
    ]

    let projectID: ProjectID = fixtureID(10)
    let workspaceID: WorkspaceID = fixtureID(11)
    let firstConversationID: ConversationID = fixtureID(20)
    let secondConversationID: ConversationID = fixtureID(21)
    let firstRunID: RunID = fixtureID(30)
    let secondRunID: RunID = fixtureID(31)
    let firstAttemptID: AttemptID = fixtureID(40)
    let secondAttemptID: AttemptID = fixtureID(41)
    let firstCallID: ToolCallID = fixtureID(50)
    let secondCallID: ToolCallID = fixtureID(51)
    let thirdCallID: ToolCallID = fixtureID(52)
    let approvalID: ApprovalRequestID = fixtureID(60)
    let firstArtifact = ArtifactReference(
        artifactID: fixtureID(70),
        mediaType: "text/plain",
        contentDigest: "sha256:shared-artifact",
        displayName: "Proof.txt"
    )
    let secondArtifact = ArtifactReference(
        artifactID: fixtureID(71),
        mediaType: "text/plain",
        contentDigest: "sha256:shared-artifact",
        displayName: "Proof duplicate.txt"
    )
    let thirdArtifact = ArtifactReference(
        artifactID: fixtureID(72),
        mediaType: "text/plain",
        contentDigest: "sha256:shared-artifact",
        displayName: "Proof capture.txt"
    )
    let sharedEvidenceID = AgentActivityEvidenceID(
        kind: "workspace-proof",
        digest: "sha256:shared-evidence"
    )
    let toolFailure = AgentErrorInfo(
        category: .tool,
        code: CanonicalActivityFixture.secretToolErrorCode,
        publicMessage: "The file could not be inspected.",
        retryable: false
    )
    let runFailure = AgentErrorInfo(
        category: .provider,
        code: CanonicalActivityFixture.secretErrorCode,
        publicMessage: "The run did not finish.",
        retryable: true
    )

    var firstContext: AgentRunContext {
        context(runID: firstRunID, conversationID: firstConversationID, seed: 100)
    }

    var secondContext: AgentRunContext {
        context(runID: secondRunID, conversationID: secondConversationID, seed: 200)
    }

    var firstScope: AgentActivityProjectionScope {
        AgentActivityProjectionScope(
            projectID: projectID,
            conversationID: firstConversationID
        )
    }

    var secondScope: AgentActivityProjectionScope {
        AgentActivityProjectionScope(
            projectID: projectID,
            conversationID: secondConversationID
        )
    }

    var sharedEvidence: ToolEvidence {
        ToolEvidence(
            kind: sharedEvidenceID.kind,
            digest: sharedEvidenceID.digest,
            metadata: .object([
                "private": .string(CanonicalActivityFixture.secretEvidenceMetadata)
            ])
        )
    }

    var firstInvocation: ToolInvocation {
        invocation(callID: firstCallID, attemptID: firstAttemptID, idempotency: "one")
    }

    var secondInvocation: ToolInvocation {
        invocation(callID: secondCallID, attemptID: firstAttemptID, idempotency: "two")
    }

    var thirdInvocation: ToolInvocation {
        invocation(callID: thirdCallID, attemptID: secondAttemptID, idempotency: "three")
    }

    var versionMismatchedInvocation: ToolInvocation {
        ToolInvocation(
            callID: firstCallID,
            providerCallID: CanonicalActivityFixture.reusedProviderCallID,
            modelAttemptID: firstAttemptID,
            tool: ToolIdentity(name: "write_file", version: "1"),
            arguments: firstInvocation.arguments,
            canonicalArgumentDigest: firstInvocation.canonicalArgumentDigest,
            idempotencyKey: firstInvocation.idempotencyKey,
            effectClass: firstInvocation.effectClass,
            locality: firstInvocation.locality
        )
    }

    var firstResult: ToolResult {
        ToolResult(
            modelItemID: fixtureID(80),
            callID: firstCallID,
            status: .succeeded,
            output: .object([
                "private": .string(CanonicalActivityFixture.secretOutput)
            ]),
            artifacts: [firstArtifact],
            evidence: [sharedEvidence]
        )
    }

    var secondResult: ToolResult {
        ToolResult(
            modelItemID: fixtureID(81),
            callID: secondCallID,
            status: .succeeded,
            output: .string(CanonicalActivityFixture.secretOutput),
            artifacts: [secondArtifact],
            evidence: [sharedEvidence]
        )
    }

    var thirdResult: ToolResult {
        ToolResult(
            modelItemID: fixtureID(82),
            callID: thirdCallID,
            status: .failed,
            output: .string(CanonicalActivityFixture.secretOutput),
            evidence: [sharedEvidence],
            error: toolFailure
        )
    }

    var approvalRequest: ApprovalRequest {
        ApprovalRequest(
            requestID: approvalID,
            binding: ApprovalBinding(
                runID: firstRunID,
                callID: secondCallID,
                tool: secondInvocation.tool,
                canonicalArgumentDigest: secondInvocation.canonicalArgumentDigest,
                workspaceID: workspaceID,
                previewDigest: "sha256:preview",
                workspaceRevision: "revision-1"
            ),
            summary: CanonicalActivityFixture.secretApprovalSummary,
            requestedAt: AgentInstant(rawValue: 10_010)
        )
    }

    var approvalResolution: ApprovalResolution {
        ApprovalResolution(
            requestID: approvalID,
            callID: secondCallID,
            decision: .approved,
            resolvedAt: AgentInstant(rawValue: 10_011)
        )
    }

    var firstEvents: [AgentEvent] {
        let context = firstContext
        return [
            event(
                context: context,
                sequence: 1,
                payload: .runAccepted(
                    RunAcceptedEvent(
                        context: context,
                        initialItems: [secretUserItem(seed: 100)]
                    )
                ),
                eventSeed: 1_001
            ),
            event(
                context: context,
                sequence: 2,
                payload: .runStarted(RunStartedEvent()),
                eventSeed: 1_002
            ),
            event(
                context: context,
                sequence: 3,
                payload: .modelRequestStarted(
                    ModelRequestStartedEvent(
                        attemptID: firstAttemptID,
                        route: route,
                        providerAttempt: .legacyV1
                    )
                ),
                eventSeed: 1_003
            ),
            event(
                context: context,
                sequence: 4,
                payload: .modelResponseCommitted(
                    ModelResponseCommittedEvent(
                        attemptID: firstAttemptID,
                        items: [
                            ModelItem(
                                id: fixtureID(83),
                                createdAt: AgentInstant(rawValue: 10_004),
                                payload: .message(
                                    ModelMessage(
                                        role: .assistant,
                                        content: [
                                            .text(CanonicalActivityFixture.secretProviderFrame),
                                            .structured(.object([
                                                "private": .string(
                                                    CanonicalActivityFixture.secretOutput
                                                )
                                            ]))
                                        ]
                                    )
                                )
                            ),
                            invocationItem(firstInvocation, seed: 84),
                            invocationItem(secondInvocation, seed: 85)
                        ],
                        usage: ModelUsage(inputTokens: 5, outputTokens: 3),
                        finishReason: .toolCalls
                    )
                ),
                eventSeed: 1_004
            ),
            event(
                context: context,
                sequence: 5,
                payload: .toolProposed(ToolProposedEvent(invocation: firstInvocation)),
                eventSeed: 1_005
            ),
            event(
                context: context,
                sequence: 6,
                payload: .toolScheduled(ToolScheduledEvent(callID: firstCallID)),
                eventSeed: 1_006
            ),
            event(
                context: context,
                sequence: 7,
                payload: .toolStarted(ToolStartedEvent(callID: firstCallID)),
                eventSeed: 1_007
            ),
            event(
                context: context,
                sequence: 8,
                payload: .toolCompleted(ToolCompletedEvent(result: firstResult)),
                eventSeed: 1_008
            ),
            event(
                context: context,
                sequence: 9,
                payload: .toolProposed(ToolProposedEvent(invocation: secondInvocation)),
                eventSeed: 1_009
            ),
            event(
                context: context,
                sequence: 10,
                payload: .approvalRequested(ApprovalRequestedEvent(request: approvalRequest)),
                eventSeed: 1_010
            ),
            event(
                context: context,
                sequence: 11,
                payload: .approvalResolved(
                    ApprovalResolvedEvent(resolution: approvalResolution)
                ),
                eventSeed: 1_011
            ),
            event(
                context: context,
                sequence: 12,
                payload: .toolScheduled(ToolScheduledEvent(callID: secondCallID)),
                eventSeed: 1_012
            ),
            event(
                context: context,
                sequence: 13,
                payload: .toolStarted(ToolStartedEvent(callID: secondCallID)),
                eventSeed: 1_013
            ),
            event(
                context: context,
                sequence: 14,
                payload: .toolApplied(
                    ToolAppliedEvent(callID: secondCallID, evidence: [sharedEvidence])
                ),
                eventSeed: 1_014
            ),
            event(
                context: context,
                sequence: 15,
                payload: .toolCompleted(ToolCompletedEvent(result: secondResult)),
                eventSeed: 1_015
            ),
            event(
                context: context,
                sequence: 16,
                payload: .artifactCaptured(ArtifactCapturedEvent(artifact: thirdArtifact)),
                eventSeed: 1_016
            ),
            event(
                context: context,
                sequence: 17,
                payload: .runCompleted(
                    RunCompletedEvent(
                        summary: CanonicalActivityFixture.secretCompletionSummary
                    )
                ),
                eventSeed: 1_017
            )
        ]
    }

    var secondEvents: [AgentEvent] {
        let context = secondContext
        return [
            event(
                context: context,
                sequence: 1,
                payload: .runAccepted(
                    RunAcceptedEvent(
                        context: context,
                        initialItems: [secretUserItem(seed: 200)]
                    )
                ),
                eventSeed: 2_001
            ),
            event(
                context: context,
                sequence: 2,
                payload: .runStarted(RunStartedEvent()),
                eventSeed: 2_002
            ),
            event(
                context: context,
                sequence: 3,
                payload: .modelRequestStarted(
                    ModelRequestStartedEvent(
                        attemptID: secondAttemptID,
                        route: route,
                        providerAttempt: .legacyV1
                    )
                ),
                eventSeed: 2_003
            ),
            event(
                context: context,
                sequence: 4,
                payload: .modelResponseCommitted(
                    ModelResponseCommittedEvent(
                        attemptID: secondAttemptID,
                        items: [invocationItem(thirdInvocation, seed: 201)],
                        usage: ModelUsage(inputTokens: 5, outputTokens: 3),
                        finishReason: .toolCalls
                    )
                ),
                eventSeed: 2_004
            ),
            event(
                context: context,
                sequence: 5,
                payload: .toolProposed(ToolProposedEvent(invocation: thirdInvocation)),
                eventSeed: 2_005
            ),
            event(
                context: context,
                sequence: 6,
                payload: .toolScheduled(ToolScheduledEvent(callID: thirdCallID)),
                eventSeed: 2_006
            ),
            event(
                context: context,
                sequence: 7,
                payload: .toolStarted(ToolStartedEvent(callID: thirdCallID)),
                eventSeed: 2_007
            ),
            event(
                context: context,
                sequence: 8,
                payload: .toolCompleted(ToolCompletedEvent(result: thirdResult)),
                eventSeed: 2_008
            ),
            event(
                context: context,
                sequence: 9,
                payload: .runFailed(RunFailedEvent(error: runFailure)),
                eventSeed: 2_009
            )
        ]
    }

    var interleavedEvents: [AgentEvent] {
        let first = firstEvents
        let second = secondEvents
        var result: [AgentEvent] = []
        for index in 0 ..< max(first.count, second.count) {
            if first.indices.contains(index) { result.append(first[index]) }
            if second.indices.contains(index) { result.append(second[index]) }
        }
        return result
    }

    var firstState: AgentDomain.AgentRunState {
        AgentDomain.AgentRunState(
            context: firstContext,
            phase: .completed,
            lastSequence: EventSequence(rawValue: 17),
            modelAttempts: [
                ModelAttemptState(
                    attemptID: firstAttemptID,
                    route: route,
                    status: .responseCommitted
                )
            ],
            tools: [
                ToolExecutionState(
                    invocation: firstInvocation,
                    status: .completed,
                    result: firstResult
                ),
                ToolExecutionState(
                    invocation: secondInvocation,
                    status: .completed,
                    result: secondResult,
                    applicationEvidence: [sharedEvidence]
                )
            ],
            approvals: [
                ApprovalRequestState(
                    request: approvalRequest,
                    status: .approved,
                    resolution: approvalResolution
                )
            ],
            artifacts: [thirdArtifact]
        )
    }

    private var route: ModelRoute {
        ModelRoute(provider: "openai", model: "hermes-baseline", adapter: "responses")
    }

    private func context(
        runID: RunID,
        conversationID: ConversationID,
        seed: Int
    ) -> AgentRunContext {
        AgentRunContext(
            schemaVersion: .v1,
            lineage: .root(runID),
            conversationID: conversationID,
            projectID: projectID,
            workspaceID: workspaceID,
            executionNodeID: fixtureID(seed + 1),
            engineVersion: .agentHarnessV1,
            acceptedAt: AgentInstant(rawValue: Int64(seed * 100)),
            features: AgentFeatureSet(["canonical-activity"]),
            cancellation: CancellationLineage(scopeID: fixtureID(seed + 2)),
            initialBudget: AgentBudget(limits: .standard)
        )
    }

    private func invocation(
        callID: ToolCallID,
        attemptID: AttemptID,
        idempotency: String
    ) -> ToolInvocation {
        ToolInvocation(
            callID: callID,
            providerCallID: CanonicalActivityFixture.reusedProviderCallID,
            modelAttemptID: attemptID,
            tool: ToolIdentity(name: "write_file", version: "1.0.0"),
            arguments: .object([
                "path": .string(CanonicalActivityFixture.secretArgument),
                "content": .string(CanonicalActivityFixture.secretOutput)
            ]),
            canonicalArgumentDigest: "sha256:identical-arguments",
            idempotencyKey: idempotency,
            effectClass: .scopedReversibleWrite,
            locality: .onDevice
        )
    }

    private func secretUserItem(seed: Int) -> ModelItem {
        ModelItem(
            id: fixtureID(seed + 10),
            createdAt: AgentInstant(rawValue: Int64(seed * 100)),
            payload: .message(
                ModelMessage(
                    role: .user,
                    content: [.text(CanonicalActivityFixture.secretArgument)]
                )
            )
        )
    }

    private func invocationItem(
        _ invocation: ToolInvocation,
        seed: Int
    ) -> ModelItem {
        ModelItem(
            id: fixtureID(seed),
            createdAt: AgentInstant(rawValue: Int64(seed * 100)),
            payload: .toolInvocation(invocation)
        )
    }

    func event(
        context: AgentRunContext,
        sequence: UInt64,
        payload: AgentEventPayload,
        eventSeed: Int,
        overridingRunID: RunID? = nil
    ) -> AgentEvent {
        let runID = overridingRunID ?? context.lineage.runID
        return AgentEvent(
            header: AgentEventHeader(
                eventID: fixtureID(eventSeed),
                schemaVersion: context.schemaVersion,
                runID: runID,
                rootRunID: context.lineage.rootRunID,
                parentRunID: context.lineage.parentRunID,
                sequence: EventSequence(rawValue: sequence),
                timestamp: AgentInstant(rawValue: Int64(eventSeed * 10)),
                executionNodeID: context.executionNodeID,
                conversationID: context.conversationID,
                projectID: context.projectID,
                workspaceID: context.workspaceID,
                causationID: nil,
                correlationID: fixtureID(eventSeed + 30_000),
                engineVersion: context.engineVersion
            ),
            payload: payload
        )
    }
}

private func fixtureID<Tag: AgentIdentifierTag>(_ value: Int) -> AgentIdentifier<Tag> {
    let suffix = String(format: "%012d", value)
    return AgentIdentifier(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    )
}

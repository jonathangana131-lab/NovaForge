import AgentDomain
import Foundation
import XCTest
@testable import NovaForge

final class AgentCanonicalActivityPresentationTests: XCTestCase {
    func testCompletedGroupCollapsesToSummaryAndCapsArtifactHandoffs() {
        let items = (1 ... 5).map {
            Fixture.item(ordinal: $0, state: .succeeded)
        }
        let group = Fixture.group(
            state: .succeeded,
            items: items,
            artifacts: (1 ... 3).map(Fixture.artifact),
            durationMilliseconds: 18_000
        )

        let presentation = AgentCanonicalActivityPresentation(
            group: group,
            isExpanded: false
        )

        XCTAssertEqual(presentation.stateLabel, "Complete")
        XCTAssertEqual(presentation.durationLabel, "18s")
        XCTAssertEqual(presentation.primarySummary, "Worked for 18s")
        XCTAssertTrue(presentation.visibleItems.isEmpty)
        XCTAssertEqual(presentation.hiddenItemCount, 5)
        XCTAssertEqual(presentation.coalescedSuccessfulItemCount, 5)
        XCTAssertEqual(
            presentation.visibleArtifacts.map(\.id),
            Array(group.artifacts.prefix(2)).map(\.id)
        )
        XCTAssertEqual(presentation.hiddenArtifactCount, 1)
        XCTAssertFalse(presentation.showsModelWork)
    }

    func testRunningGroupShowsOnlyCurrentItemAndImmediateContext() {
        let items = [
            Fixture.item(ordinal: 1, state: .succeeded),
            Fixture.item(ordinal: 2, state: .succeeded),
            Fixture.item(ordinal: 3, state: .succeeded),
            Fixture.item(ordinal: 4, state: .running),
        ]
        let group = Fixture.group(state: .running, items: items)

        let presentation = AgentCanonicalActivityPresentation(
            group: group,
            isExpanded: false
        )

        XCTAssertEqual(presentation.visibleItems.map(\.id), items.suffix(2).map(\.id))
        XCTAssertEqual(presentation.hiddenItemCount, 2)
        XCTAssertEqual(presentation.coalescedSuccessfulItemCount, 2)
    }

    func testExpandedDetailsKeepNewestTwelveStableCanonicalItems() {
        let items = (1 ... 15).map {
            Fixture.item(ordinal: $0, state: .succeeded)
        }
        let group = Fixture.group(state: .succeeded, items: items)

        let presentation = AgentCanonicalActivityPresentation(
            group: group,
            isExpanded: true
        )

        XCTAssertEqual(
            presentation.visibleItems.map(\.id),
            Array(items.suffix(AgentCanonicalActivityPresentation.expandedItemLimit)).map(\.id)
        )
        XCTAssertEqual(presentation.hiddenItemCount, 3)
        XCTAssertEqual(presentation.coalescedSuccessfulItemCount, 3)
    }

    func testRetriesAndRoutesFoldIntoOneBoundedModelWorkSection() {
        let firstAttemptID = Fixture.attemptID(1)
        let secondAttemptID = Fixture.attemptID(2)
        let infrastructure = [
            Fixture.item(
                id: .modelAttempt(firstAttemptID),
                kind: .modelAttempt,
                state: .failed,
                ordinal: 1
            ),
            Fixture.item(
                id: .retry(
                    failedAttemptID: firstAttemptID,
                    nextAttemptID: secondAttemptID
                ),
                kind: .retry,
                state: .retrying,
                ordinal: 2
            ),
            Fixture.item(
                id: .routeChange(Fixture.eventID(3)),
                kind: .routeChange,
                state: .succeeded,
                ordinal: 3
            ),
        ]
        let tool = Fixture.item(ordinal: 4, state: .running)
        let attempts = (1 ... 6).map(Fixture.attempt)
        let group = Fixture.group(
            state: .running,
            items: infrastructure + [tool],
            attempts: attempts
        )

        let presentation = AgentCanonicalActivityPresentation(
            group: group,
            isExpanded: true
        )

        XCTAssertEqual(presentation.visibleItems.map(\.id), [tool.id])
        XCTAssertTrue(presentation.showsModelWork)
        XCTAssertEqual(
            presentation.visibleAttempts.map(\.id),
            Array(attempts.suffix(AgentCanonicalActivityPresentation.expandedAttemptLimit)).map(\.id)
        )
        XCTAssertEqual(presentation.hiddenAttemptCount, 2)
        XCTAssertEqual(
            AgentCanonicalActivityPresentation.attemptSummary(count: 6),
            "Model work · 6 attempts"
        )
    }

    func testFailedGroupKeepsFailedItemUnderstandableWhileCollapsed() {
        let succeeded = Fixture.item(ordinal: 1, state: .succeeded)
        let failed = Fixture.item(
            id: .failure(Fixture.eventID(2)),
            kind: .failure,
            state: .failed,
            ordinal: 2,
            errorMessage: "The workspace check failed."
        )
        let group = Fixture.group(
            state: .failed,
            items: [succeeded, failed],
            errorMessage: "The workspace check failed."
        )

        let presentation = AgentCanonicalActivityPresentation(
            group: group,
            isExpanded: false
        )

        XCTAssertEqual(presentation.stateLabel, "Failed")
        XCTAssertEqual(presentation.visibleItems.map(\.id), [failed.id])
        XCTAssertEqual(presentation.hiddenItemCount, 1)
    }

    func testApprovalActionUsesExactCanonicalCallIdentityNotVisibleCopy() throws {
        let first = Fixture.item(
            ordinal: 1,
            state: .awaitingApproval,
            summary: "Updated workspace"
        )
        let second = Fixture.item(
            ordinal: 2,
            state: .awaitingApproval,
            summary: "Updated workspace"
        )
        let approval = Fixture.approval(callID: try XCTUnwrap(second.toolCallID))
        let group = Fixture.group(
            state: .awaitingApproval,
            items: [first, second],
            approvals: [approval]
        )

        let action = AgentCanonicalActivityPresentation.approvalAction(
            in: group,
            approval: approval
        )

        XCTAssertEqual(action?.id, second.id)
        XCTAssertNotEqual(action?.id, first.id)
    }

    func testUserFacingPresentationNeverIncludesRouteOrCanonicalIdentifiers() {
        let attempt = Fixture.attempt(1)
        let group = Fixture.group(
            state: .running,
            items: [],
            attempts: [attempt],
            durationMilliseconds: 61_000
        )
        let text = [
            AgentCanonicalActivityPresentation.accessibilitySummary(for: group),
            AgentCanonicalActivityPresentation.attemptSummary(count: 1),
        ].joined(separator: " ")

        XCTAssertEqual(
            AgentCanonicalActivityPresentation.durationLabel(milliseconds: 61_000),
            "1m 1s"
        )
        XCTAssertFalse(text.contains(attempt.route.provider))
        XCTAssertFalse(text.contains(attempt.route.model))
        XCTAssertFalse(text.contains(attempt.route.adapter))
        XCTAssertFalse(text.contains(group.identity.runID.description))
        XCTAssertFalse(text.contains(attempt.id.description))
    }

    func testEveryStateHasExplicitNonColorPresentation() {
        let states: [AgentActivityState] = [
            .pending, .queued, .running, .awaitingApproval, .retrying,
            .succeeded, .failed, .rejected, .cancelling, .cancelled, .interrupted,
        ]

        XCTAssertEqual(
            states.map {
                AgentCanonicalActivityPresentation.stateLabel(for: $0)
            },
            [
                "Preparing", "Queued", "Running", "Awaiting approval", "Retrying",
                "Complete", "Failed", "Rejected", "Stopping", "Stopped", "Interrupted",
            ]
        )
    }

    func testActiveToolReceiptsBecomeGranularLiveVerbs() {
        let expectations = [
            ("Workspace searched", "Searching files"),
            ("File read", "Reading file"),
            ("File written", "Creating file"),
            ("Text replaced", "Editing file"),
            ("HTML validated", "Checking HTML"),
            ("Sandbox command completed", "Running command"),
        ]

        for (receipt, expected) in expectations {
            let item = Fixture.item(
                ordinal: 1,
                state: .running,
                summary: receipt
            )
            XCTAssertEqual(
                AgentCanonicalActivityPresentation.activityLabel(for: item),
                expected
            )
            XCTAssertEqual(
                AgentCanonicalActivityPresentation(
                    group: Fixture.group(state: .running, items: [item]),
                    isExpanded: false
                ).primarySummary,
                expected
            )
        }
    }
}

final class LegacyToolActivityBatchPresentationTests: XCTestCase {
    func testUnresolvedBatchStartsAsOneCompactProgressSummary() {
        let presentation = LegacyToolActivityBatchPresentation(
            totalCount: 4,
            completedCount: 1,
            failedCount: 0,
            pendingApprovalCount: 0,
            primaryTarget: "App.swift"
        )

        XCTAssertEqual(presentation.phase, .running)
        XCTAssertEqual(
            presentation.summary,
            "Working on 4 actions · 1/4 complete · App.swift"
        )
        XCTAssertEqual(presentation.symbol, "waveform")
    }

    func testApprovalSummaryTakesPriorityOverGenericRunningState() {
        let presentation = LegacyToolActivityBatchPresentation(
            totalCount: 2,
            completedCount: 0,
            failedCount: 0,
            pendingApprovalCount: 1,
            primaryTarget: "Settings.swift"
        )

        XCTAssertEqual(presentation.phase, .awaitingApproval)
        XCTAssertEqual(
            presentation.summary,
            "Approval needed · Settings.swift"
        )
        XCTAssertEqual(presentation.symbol, "checkmark.shield.fill")
    }

    func testFailureSummaryWinsAndKeepsCompletedSiblingCount() {
        let presentation = LegacyToolActivityBatchPresentation(
            totalCount: 5,
            completedCount: 3,
            failedCount: 1,
            pendingApprovalCount: 1,
            primaryTarget: nil
        )

        XCTAssertEqual(presentation.phase, .failed)
        XCTAssertEqual(presentation.summary, "1 failed · 3 completed")
        XCTAssertEqual(presentation.symbol, "exclamationmark.triangle.fill")
    }

    func testCompletedBatchUsesSingularAndPluralHumanCopy() {
        let single = LegacyToolActivityBatchPresentation(
            totalCount: 1,
            completedCount: 1,
            failedCount: 0,
            pendingApprovalCount: 0,
            primaryTarget: nil
        )
        let multiple = LegacyToolActivityBatchPresentation(
            totalCount: 3,
            completedCount: 3,
            failedCount: 0,
            pendingApprovalCount: 0,
            primaryTarget: nil
        )

        XCTAssertEqual(single.summary, "1 action completed")
        XCTAssertEqual(multiple.summary, "3 actions completed")
        XCTAssertEqual(single.phase, .succeeded)
        XCTAssertEqual(multiple.phase, .succeeded)
    }

    func testLegacyApprovalPolicyUsesExactToolIdentity() {
        XCTAssertTrue(LegacyToolActivityPolicy.requiresApproval("write_file"))
        XCTAssertTrue(LegacyToolActivityPolicy.requiresApproval("run_command"))
        XCTAssertFalse(LegacyToolActivityPolicy.requiresApproval("read_file"))
        XCTAssertFalse(LegacyToolActivityPolicy.requiresApproval("write_file_backup"))
    }

    func testLegacyDurableTraceUsesQuietReceiptCopyInsteadOfPayloads() {
        XCTAssertEqual(
            ChatDurableRunSnapshot.legacyTraceDetail(for: .pendingApproval),
            "Decision required before this action runs."
        )
        XCTAssertEqual(
            ChatDurableRunSnapshot.legacyTraceDetail(for: .completed),
            "Receipt saved in History."
        )
        XCTAssertEqual(
            ChatDurableRunSnapshot.legacyTraceDetail(for: .failed),
            "Action failed. Open History for diagnostics."
        )

        for status in ToolRunStatus.allCases {
            let detail = ChatDurableRunSnapshot.legacyTraceDetail(for: status)
            XCTAssertFalse(detail.contains("{"))
            XCTAssertFalse(detail.contains("command"))
            XCTAssertFalse(detail.contains("contents"))
        }
    }

    func testCanonicalCutoverSuppressesOnlyToolRowsAndKeepsProse() {
        XCTAssertTrue(
            ChatToolActivityCutoverPolicy.shouldRenderMessage(
                role: .assistant,
                hasToolCalls: true,
                canonicalOwnsToolPresentation: true,
                allowsLegacyV1DebugFallback: false
            )
        )
        XCTAssertFalse(
            ChatToolActivityCutoverPolicy.shouldRenderMessage(
                role: .tool,
                hasToolCalls: false,
                canonicalOwnsToolPresentation: true
            )
        )
        XCTAssertFalse(
            ChatToolActivityCutoverPolicy.shouldRenderMessage(
                role: .assistant,
                hasToolCalls: true,
                canonicalOwnsToolPresentation: true,
                allowsLegacyV1DebugFallback: true
            ),
            "Migration inspection must not duplicate canonical activity"
        )
        XCTAssertTrue(
            ChatToolActivityCutoverPolicy.shouldRenderMessage(
                role: .assistant,
                hasToolCalls: false,
                canonicalOwnsToolPresentation: true
            )
        )
        XCTAssertTrue(
            ChatToolActivityCutoverPolicy.shouldRenderMessage(
                role: .user,
                hasToolCalls: false,
                canonicalOwnsToolPresentation: true
            )
        )
    }

    func testV1ConversationRequiresExplicitDebugIntentForLegacyToolFallback() {
        XCTAssertTrue(
            ChatToolActivityCutoverPolicy.shouldRenderMessage(
                role: .assistant,
                hasToolCalls: true,
                canonicalOwnsToolPresentation: false,
                allowsLegacyV1DebugFallback: true
            )
        )
        XCTAssertTrue(
            ChatToolActivityCutoverPolicy.shouldRenderMessage(
                role: .tool,
                hasToolCalls: false,
                canonicalOwnsToolPresentation: false,
                allowsLegacyV1DebugFallback: true
            )
        )
    }

    func testProductionV1KeepsAssistantProseButSuppressesToolPayload() {
        XCTAssertTrue(
            ChatToolActivityCutoverPolicy.shouldRenderMessage(
                role: .assistant,
                hasToolCalls: true,
                canonicalOwnsToolPresentation: false,
                allowsLegacyV1DebugFallback: false
            )
        )
        XCTAssertFalse(
            ChatToolActivityCutoverPolicy.shouldRenderMessage(
                role: .tool,
                hasToolCalls: false,
                canonicalOwnsToolPresentation: false,
                allowsLegacyV1DebugFallback: false
            )
        )
    }

    func testReleaseChatSourceCannotRenderLegacyGiantSurfacesOrRawPayloads()
        throws
    {
        let messages = releaseSource(
            try source(named: "ChatMessages.swift")
        )
        let live = releaseSource(
            try source(named: "ChatLiveAndToolViews.swift")
        )
        let releaseChat = messages + "\n" + live

        for forbidden in [
            "AssistantToolCallBubble(",
            "ToolMessageBubble(",
            "struct ApprovalSheet",
            "request.argumentsJSON",
            "Text(call.resultDetail)",
            "Text(message.toolDetail)",
        ] {
            XCTAssertFalse(
                releaseChat.contains(forbidden),
                "Release chat still contains legacy/raw surface: \(forbidden)"
            )
        }
        XCTAssertTrue(
            releaseChat.contains("return role != .tool"),
            "Release policy must retain prose while dropping provider tool rows"
        )
    }

    private func source(named name: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("AgentPad/Views", isDirectory: true)
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }

    /// Evaluates the files' DEBUG conditionals as a Release compile would.
    /// These files use only simple `#if DEBUG` branches around the legacy UI.
    private func releaseSource(_ source: String) -> String {
        struct Frame {
            let parentIncluded: Bool
            let debugCondition: Bool
        }

        var frames: [Frame] = []
        var isIncluded = true
        var includedLines: [Substring] = []

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            switch String(line).trimmingCharacters(in: .whitespaces) {
            case "#if DEBUG":
                frames.append(Frame(
                    parentIncluded: isIncluded,
                    debugCondition: true
                ))
                isIncluded = false
            case "#else":
                guard let frame = frames.last else { continue }
                isIncluded = frame.parentIncluded && frame.debugCondition
            case "#endif":
                guard let frame = frames.popLast() else { continue }
                isIncluded = frame.parentIncluded
            default:
                if isIncluded {
                    includedLines.append(line)
                }
            }
        }
        return includedLines.joined(separator: "\n")
    }
}

private enum Fixture {
    static let identity = AgentActivityRunIdentity(
        projectID: ProjectID(rawValue: uuid(10)),
        conversationID: ConversationID(rawValue: uuid(11)),
        workspaceID: WorkspaceID(rawValue: uuid(12)),
        runID: RunID(rawValue: uuid(13)),
        rootRunID: RunID(rawValue: uuid(14))
    )

    static func group(
        state: AgentActivityState,
        items: [AgentActivityItem],
        attempts: [AgentActivityAttempt] = [],
        approvals: [AgentActivityApproval] = [],
        artifacts: [AgentActivityArtifact] = [],
        durationMilliseconds: Int64 = 4_000,
        errorMessage: String? = nil
    ) -> AgentActivityGroup {
        AgentActivityGroup(
            identity: identity,
            state: state,
            summary: state == .failed ? (errorMessage ?? "Run failed") : "Worked on the request",
            span: span(ordinal: 0, durationMilliseconds: durationMilliseconds),
            items: items,
            attempts: attempts,
            approvals: approvals,
            artifacts: artifacts,
            evidence: [],
            errorMessage: errorMessage,
            replayIdentity: AgentActivityReplayIdentity(
                orderedEventIDs: [eventID(99)],
                orderedSequences: [.first]
            )
        )
    }

    static func item(
        ordinal: Int,
        state: AgentActivityState,
        summary: String = "Inspected workspace"
    ) -> AgentActivityItem {
        let callID = toolCallID(ordinal)
        return item(
            id: .tool(callID),
            kind: .tool,
            state: state,
            ordinal: ordinal,
            summary: summary,
            toolCallID: callID
        )
    }

    static func item(
        id: AgentActivityItemID,
        kind: AgentActivitySemanticKind,
        state: AgentActivityState,
        ordinal: Int,
        summary: String = "Canonical activity",
        toolCallID: ToolCallID? = nil,
        errorMessage: String? = nil
    ) -> AgentActivityItem {
        AgentActivityItem(
            id: id,
            kind: kind,
            state: state,
            summary: summary,
            target: nil,
            attemptID: nil,
            toolCallID: toolCallID,
            span: span(ordinal: ordinal, durationMilliseconds: 1_000),
            errorMessage: errorMessage,
            evidenceIDs: [],
            artifactIDs: []
        )
    }

    static func attempt(_ ordinal: Int) -> AgentActivityAttempt {
        AgentActivityAttempt(
            id: attemptID(ordinal),
            state: ordinal == 6 ? .running : .failed,
            route: AgentActivityRoute(
                provider: "provider-secret-id",
                model: "model-secret-id",
                adapter: "adapter-secret-id"
            ),
            span: span(ordinal: ordinal, durationMilliseconds: 750),
            itemIDs: [],
            retryOfAttemptID: ordinal > 1 ? attemptID(ordinal - 1) : nil,
            nextAttemptID: ordinal < 6 ? attemptID(ordinal + 1) : nil,
            errorMessage: ordinal == 6 ? nil : "Public retry reason"
        )
    }

    static func approval(callID: ToolCallID) -> AgentActivityApproval {
        AgentActivityApproval(
            id: ApprovalRequestID(rawValue: uuid(80)),
            run: identity,
            callID: callID,
            state: .awaitingApproval,
            publicSummary: "Review this action before it runs.",
            requestedAt: AgentInstant(rawValue: 9_000),
            resolvedAt: nil
        )
    }

    static func artifact(_ ordinal: Int) -> AgentActivityArtifact {
        let id = ArtifactID(rawValue: uuid(100 + ordinal))
        return AgentActivityArtifact(
            id: id,
            run: identity,
            equivalentArtifactIDs: [id],
            contentDigest: "digest-\(ordinal)",
            mediaType: "application/octet-stream",
            displayName: "Artifact \(ordinal)",
            firstSequence: EventSequence(rawValue: UInt64(ordinal)),
            sourceToolCallIDs: []
        )
    }

    static func span(
        ordinal: Int,
        durationMilliseconds: Int64
    ) -> AgentActivityEventSpan {
        let started = Int64(ordinal) * 10_000
        return AgentActivityEventSpan(
            firstSequence: EventSequence(rawValue: UInt64(ordinal + 1)),
            lastSequence: EventSequence(rawValue: UInt64(ordinal + 1)),
            startedAt: AgentInstant(rawValue: started),
            endedAt: AgentInstant(rawValue: started + durationMilliseconds)
        )
    }

    static func attemptID(_ ordinal: Int) -> AttemptID {
        AttemptID(rawValue: uuid(200 + ordinal))
    }

    static func toolCallID(_ ordinal: Int) -> ToolCallID {
        ToolCallID(rawValue: uuid(300 + ordinal))
    }

    static func eventID(_ ordinal: Int) -> EventID {
        EventID(rawValue: uuid(400 + ordinal))
    }

    static func uuid(_ value: Int) -> UUID {
        let suffix = String(format: "%012llx", UInt64(value))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}
